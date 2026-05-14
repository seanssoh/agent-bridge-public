#!/usr/bin/env bash
# tests/isolation-plugin-sharing.sh
#
# Regression test for the channel-ownership-aware plugin sharing fix.
#
# Verifies, against a fully synthetic controller plugin tree (driven via
# the BRIDGE_CONTROLLER_HOME_OVERRIDE seam in
# bridge_linux_share_plugin_catalog) so the operator's real
# ~/.claude/plugins/ is never touched:
#
#   1. After isolate, the per-UID installed_plugins.json contains only
#      the plugin declared in BRIDGE_AGENT_CHANNELS, with installPath
#      rewritten to the actually-existing on-disk location.
#   2. Per-UID installed_plugins.json is root-owned 0640 and the
#      isolated UID has u:<uid>:r--; the agent cannot tamper with it.
#   3. plugins/ root is root-owned 0750 with isolated UID r-x;
#      plugins/data/ is isolated UID-owned 0700 and writable.
#   4. The declared plugin's directory-source install path receives a
#      u:<os_user>:r-X recursive ACL (r-- on files, r-x on directories);
#      the undeclared plugin's install path has NO u:<os_user> ACL
#      entry — the isolated UID cannot read sources for plugins it did
#      not declare in its channel set.
#   5. Catalog symlinks (known_marketplaces.json, install-counts-cache.json,
#      blocklist.json) under <isolated>/.claude/plugins/ exist and resolve
#      to the controller's copies.
#   6. After bridge_migration_unisolate, every u:<os_user> ACL on the
#      controller-side plugin tree is gone, the per-UID manifest is
#      removed, the catalog symlinks under the isolated home are gone,
#      and the legacy $BRIDGE_HOME/plugins recursive ACL strip leaves no
#      residue (regression guard for the backward-compat cleanup).
#
# Skip preconditions: Linux, passwordless sudo, setfacl, useradd available.
# Creates a temporary system user and tears it down at the end.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

log() { printf '[isolate-plugin] %s\n' "$*"; }
die() { printf '[isolate-plugin][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[isolate-plugin][skip] %s\n' "$*"; exit 0; }

[[ "$(uname -s)" == "Linux" ]] || skip "Linux-only test"
command -v sudo >/dev/null 2>&1 || skip "sudo required"
sudo -n true >/dev/null 2>&1 || skip "passwordless sudo required"
command -v setfacl >/dev/null 2>&1 || skip "setfacl (acl package) required"
command -v getfacl >/dev/null 2>&1 || skip "getfacl (acl package) required"
command -v useradd >/dev/null 2>&1 || skip "useradd required"
command -v userdel >/dev/null 2>&1 || skip "userdel required"

TMP_ROOT="$(mktemp -d -t isolate-plugin-test.XXXXXX)"
SAFE_TMP_PREFIX=""
for _candidate in "${TMPDIR:-}" "/tmp" "/var/tmp"; do
  _candidate="${_candidate%/}"
  [[ -n "$_candidate" ]] || continue
  case "$TMP_ROOT" in
    "$_candidate"|"$_candidate"/*) SAFE_TMP_PREFIX="$_candidate"; break ;;
  esac
done
[[ -n "$SAFE_TMP_PREFIX" ]] || die "TMP_ROOT did not land under a recognised tempdir prefix: $TMP_ROOT"

# Temp BRIDGE_HOME with a tiny directory marketplace ("td-mkt") containing
# both a declared plugin (declared-plugin) and an undeclared plugin
# (undeclared-plugin). BRIDGE_HOME must live under SAFE_TMP_PREFIX so the
# bridge_linux_share_plugin_catalog seam guard accepts our override.
export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$BRIDGE_ACTIVE_AGENT_DIR"
: > "$BRIDGE_ROSTER_FILE"
: > "$BRIDGE_ROSTER_LOCAL_FILE"

# Set up a fake controller .claude/plugins/ tree so the helper has a
# realistic surface to share. This stays under a fake controller home
# that the helper picks up via BRIDGE_CONTROLLER_HOME_OVERRIDE — the
# operator's real $HOME is never touched.
CONTROLLER_HOME_FAKE="$TMP_ROOT/controller-home"
CONTROLLER_PLUGINS="$CONTROLLER_HOME_FAKE/.claude/plugins"
mkdir -p "$CONTROLLER_PLUGINS/cache/td-mkt/declared-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/cache/td-mkt/undeclared-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/data" \
         "$CONTROLLER_PLUGINS/marketplaces/td-mkt"
echo 'declared plugin source' > "$CONTROLLER_PLUGINS/cache/td-mkt/declared-plugin/0.1.0/index.js"
echo 'undeclared plugin source' > "$CONTROLLER_PLUGINS/cache/td-mkt/undeclared-plugin/0.1.0/index.js"
echo '{"name":"td-mkt","plugins":["declared-plugin","undeclared-plugin"]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/td-mkt/marketplace.json"
cat > "$CONTROLLER_PLUGINS/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "declared-plugin@td-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$BRIDGE_HOME/plugins/declared-plugin"}
    ],
    "undeclared-plugin@td-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$BRIDGE_HOME/plugins/undeclared-plugin"}
    ]
  }
}
JSON
cat > "$CONTROLLER_PLUGINS/known_marketplaces.json" <<JSON
{
  "td-mkt": {
    "source": {"source": "directory", "path": "$BRIDGE_HOME"},
    "installLocation": "$BRIDGE_HOME"
  }
}
JSON
echo '{}' > "$CONTROLLER_PLUGINS/install-counts-cache.json"
echo '{}' > "$CONTROLLER_PLUGINS/blocklist.json"

# Directory-marketplace shape: $BRIDGE_HOME/plugins/{declared,undeclared}.
# These are the actual install paths bridge_resolve_plugin_install_path
# will land on for the directory-source marketplace.
mkdir -p "$BRIDGE_HOME/plugins/declared-plugin" "$BRIDGE_HOME/plugins/undeclared-plugin"
echo 'declared plugin (dir-marketplace)' > "$BRIDGE_HOME/plugins/declared-plugin/server.ts"
echo 'undeclared plugin (dir-marketplace)' > "$BRIDGE_HOME/plugins/undeclared-plugin/server.ts"

# Make controller-side catalog fixtures readable while keeping the synthetic
# plugin install tree private. The isolated UID gets parent traverse via a
# named ACL after the temp user exists; per-plugin read comes only from the
# bridge helper under test.
chmod o+x "$TMP_ROOT" "$BRIDGE_HOME"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"
chmod -R go-rwx "$BRIDGE_HOME/plugins"

TEST_AGENT="qpa-test"
TEST_OS_USER="agent-bridge-${TEST_AGENT}"
TEST_OS_HOME="/home/${TEST_OS_USER}"

cleanup_test_user_locked=0
cleanup() {
  set +e
  # Belt-and-suspenders: strip every u:<TEST_OS_USER> ACL we might have
  # left on the controller plugin tree so the host doesn't end up with
  # poisoned ACLs if a step blew up between grant and revoke.
  if id "$TEST_OS_USER" >/dev/null 2>&1; then
    sudo -n setfacl -Rx "u:${TEST_OS_USER}" "$CONTROLLER_HOME_FAKE" >/dev/null 2>&1 || true
    sudo -n setfacl -Rx "u:${TEST_OS_USER}" "$BRIDGE_HOME/plugins" >/dev/null 2>&1 || true
    # Strip the temporary repo-traverse ACL granted for the
    # trust-controller-manifest assertion (#346 r2 fixture).
    sudo -n setfacl -Rx "u:${TEST_OS_USER}" "$REPO_ROOT" >/dev/null 2>&1 || true
    _ancestor_cleanup="$REPO_ROOT"
    while [[ "$_ancestor_cleanup" != "/" && "$_ancestor_cleanup" != "/tmp" ]]; do
      _ancestor_cleanup="$(dirname "$_ancestor_cleanup")"
      [[ -d "$_ancestor_cleanup" ]] || break
      sudo -n setfacl -x "u:${TEST_OS_USER}" "$_ancestor_cleanup" >/dev/null 2>&1 || true
    done
  fi
  if [[ "$cleanup_test_user_locked" -eq 0 ]] && id "$TEST_OS_USER" >/dev/null 2>&1; then
    sudo -n userdel "$TEST_OS_USER" >/dev/null 2>&1 || true
    sudo -n rm -rf "$TEST_OS_HOME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if id "$TEST_OS_USER" >/dev/null 2>&1; then
  cleanup_test_user_locked=1
  log "reusing existing OS user $TEST_OS_USER"
else
  sudo -n useradd --system --home-dir "$TEST_OS_HOME" --shell /usr/sbin/nologin "$TEST_OS_USER" >/dev/null \
    || die "useradd failed for $TEST_OS_USER"
fi
sudo -n mkdir -p "$TEST_OS_HOME"
sudo -n chown "$TEST_OS_USER:$TEST_OS_USER" "$TEST_OS_HOME"
sudo -n chmod 0700 "$TEST_OS_HOME"
sudo -n mkdir -p "$TEST_OS_HOME/.claude"
sudo -n chown "$TEST_OS_USER:$TEST_OS_USER" "$TEST_OS_HOME/.claude"
sudo -n chmod 0700 "$TEST_OS_HOME/.claude"
sudo -n setfacl -m "u:${TEST_OS_USER}:--x" "$TMP_ROOT" "$BRIDGE_HOME" "$BRIDGE_HOME/plugins" \
  || die "failed to grant temp plugin parent traverse ACL to $TEST_OS_USER"

TEST_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$TEST_AGENT"
mkdir -p "$TEST_WORKDIR"

# Roster declares declared-plugin@td-mkt only.
cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
bridge_add_agent_id_if_missing() { :; }
declare -gA BRIDGE_AGENT_ENGINE BRIDGE_AGENT_SESSION BRIDGE_AGENT_WORKDIR BRIDGE_AGENT_LAUNCH_CMD
declare -gA BRIDGE_AGENT_ISOLATION_MODE BRIDGE_AGENT_OS_USER BRIDGE_AGENT_CHANNELS
BRIDGE_AGENT_IDS=("$TEST_AGENT")
BRIDGE_AGENT_ENGINE[$TEST_AGENT]=claude
BRIDGE_AGENT_SESSION[$TEST_AGENT]=$TEST_AGENT
BRIDGE_AGENT_WORKDIR[$TEST_AGENT]=$TEST_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$TEST_AGENT]='true'
BRIDGE_AGENT_CHANNELS[$TEST_AGENT]='plugin:declared-plugin@td-mkt'
BRIDGE_AGENT_ISOLATION_MODE[$TEST_AGENT]=linux-user
BRIDGE_AGENT_OS_USER[$TEST_AGENT]=$TEST_OS_USER
ROSTER

# shellcheck source=../bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
bridge_load_roster

# Drive the helper against the fake controller home via the test seam
# (BRIDGE_CONTROLLER_HOME_OVERRIDE). The seam refuses to honor the
# override unless BRIDGE_HOME is under a tempdir prefix; we asserted that
# above. The controller_user passed in is unused once the override is
# active, but we still pass the operator's name so the call-shape
# matches production.
log "running bridge_linux_share_plugin_catalog against fake controller home $CONTROLLER_HOME_FAKE"
CONTROLLER_USER="$(id -un)"
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

ISOLATED_PLUGINS="$TEST_OS_HOME/.claude/plugins"

log "verifying plugins/ root is root-owned with isolated UID r-x"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS" | grep -Fq "root:root 750" \
  || die "expected $ISOLATED_PLUGINS to be root:root 0750"
sudo -n getfacl --no-effective "$ISOLATED_PLUGINS" 2>/dev/null | grep -Fq "user:${TEST_OS_USER}:r-x" \
  || die "expected u:${TEST_OS_USER}:r-x ACL on $ISOLATED_PLUGINS"

log "verifying plugins/data is isolated UID-owned and writable"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS/data" | grep -Fq "${TEST_OS_USER}:${TEST_OS_USER} 700" \
  || die "expected $ISOLATED_PLUGINS/data to be ${TEST_OS_USER}:${TEST_OS_USER} 0700"
sudo -n -u "$TEST_OS_USER" bash -c "echo probe > '$ISOLATED_PLUGINS/data/x' && cat '$ISOLATED_PLUGINS/data/x' >/dev/null" \
  || die "isolated UID should be able to write+read its own plugins/data/"
sudo -n -u "$TEST_OS_USER" rm -f "$ISOLATED_PLUGINS/data/x"

log "verifying per-UID installed_plugins.json is root-owned r-- to isolated UID"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS/installed_plugins.json" | grep -Fq "root:root 640" \
  || die "expected per-UID installed_plugins.json to be root:root 0640"
sudo -n getfacl --no-effective "$ISOLATED_PLUGINS/installed_plugins.json" 2>/dev/null | grep -Fq "user:${TEST_OS_USER}:r--" \
  || die "expected u:${TEST_OS_USER}:r-- ACL on per-UID installed_plugins.json"

log "verifying isolated UID cannot tamper with its own manifest"
if sudo -n -u "$TEST_OS_USER" bash -c "echo broken > '$ISOLATED_PLUGINS/installed_plugins.json'" 2>/dev/null; then
  die "isolated UID should not be able to write its own installed_plugins.json"
fi
if sudo -n -u "$TEST_OS_USER" rm -f "$ISOLATED_PLUGINS/installed_plugins.json" 2>/dev/null; then
  if [[ ! -e "$ISOLATED_PLUGINS/installed_plugins.json" ]]; then
    die "isolated UID was able to unlink its own installed_plugins.json"
  fi
fi

log "verifying per-UID manifest contents only list the declared plugin"
manifest_dump="$(sudo -n cat "$ISOLATED_PLUGINS/installed_plugins.json")"
echo "$manifest_dump" | python3 -c '
import json, sys
m = json.load(sys.stdin)
plugins = list(m.get("plugins", {}).keys())
assert plugins == ["declared-plugin@td-mkt"], f"unexpected manifest plugins: {plugins!r}"
entry = m["plugins"]["declared-plugin@td-mkt"][0]
assert "installPath" in entry and entry["installPath"], "missing installPath"
' || die "per-UID manifest contents do not match the channel boundary"

log "verifying generated known_marketplaces.json is per-UID filtered"
sudo -n python3 - "$ISOLATED_PLUGINS/known_marketplaces.json" "$ISOLATED_PLUGINS" <<'PY'
import json
import sys

path, isolated_plugins = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
assert sorted(data) == ["td-mkt"], data
entry = data["td-mkt"]
expected = f"{isolated_plugins}/marketplaces/td-mkt"
assert entry.get("installLocation") == expected, entry
assert entry.get("source", {}).get("path") == expected, entry
PY

log "verifying non-marketplace catalog symlinks resolve to controller copies"
for catalog in install-counts-cache.json blocklist.json; do
  link="$ISOLATED_PLUGINS/$catalog"
  sudo -n test -L "$link" || die "expected $link to be a symlink"
  resolved="$(sudo -n readlink -f "$link" 2>/dev/null || true)"
  expected="$CONTROLLER_PLUGINS/$catalog"
  [[ "$resolved" == "$expected" ]] || die "catalog symlink $link resolved to $resolved (expected $expected)"
done

log "verifying declared plugin's install path has u:${TEST_OS_USER}:r-X recursively"
declared_path="$BRIDGE_HOME/plugins/declared-plugin"
sudo -n getfacl --no-effective "$declared_path" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "declared plugin dir missing u:${TEST_OS_USER}:r-x ACL ($declared_path)"
sudo -n getfacl --no-effective "$declared_path/server.ts" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r--" \
  || die "declared plugin file missing u:${TEST_OS_USER}:r-- ACL"

log "verifying isolated UID can read declared plugin sources"
sudo -n -u "$TEST_OS_USER" cat "$declared_path/server.ts" >/dev/null \
  || die "isolated UID should be able to read declared plugin source"

log "verifying undeclared plugin's install path has NO u:${TEST_OS_USER} ACL entry"
undeclared_path="$BRIDGE_HOME/plugins/undeclared-plugin"
undeclared_acl_count="$(sudo -n getfacl --no-effective "$undeclared_path" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$undeclared_acl_count" == "0" ]] \
  || die "undeclared plugin dir has $undeclared_acl_count u:${TEST_OS_USER} ACL entr(ies); expected 0"
undeclared_file_acl_count="$(sudo -n getfacl --no-effective "$undeclared_path/server.ts" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$undeclared_file_acl_count" == "0" ]] \
  || die "undeclared plugin file has $undeclared_file_acl_count u:${TEST_OS_USER} ACL entr(ies); expected 0"

log "verifying isolated UID is denied access to undeclared plugin sources"
if sudo -n -u "$TEST_OS_USER" cat "$undeclared_path/server.ts" >/dev/null 2>&1; then
  die "isolated UID should NOT be able to read undeclared plugin source"
fi

log "verifying persisted grant-set state file recorded the channel"
state_file="$(bridge_isolated_plugin_grants_state_file "$TEST_AGENT")"
legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$TEST_AGENT")"
sudo -n test -e "$state_file" || die "expected persisted grant-set at $state_file"
if sudo -n test -e "$legacy_state_file" 2>/dev/null; then
  die "legacy grant-set path still exists at $legacy_state_file; grant ledger must not harden runtime state dir"
fi
sudo -n cat "$state_file" | python3 -c '
import json, sys
data = json.load(sys.stdin)
chans = data.get("channels", [])
assert chans == ["plugin:declared-plugin@td-mkt"], f"unexpected persisted channels: {chans!r}"
' || die "persisted grant-set contents do not match"

log "BRIDGE_AGENT_PLUGINS allowlist propagates into isolated manifest (#348)"

# Phase: with the channel set already granted (declared-plugin@td-mkt),
# add a non-channel domain plugin via BRIDGE_AGENT_PLUGINS["<agent>"].
# That allowlist (#272) was previously invisible to
# bridge_write_isolated_installed_plugins_manifest /
# bridge_linux_share_plugin_catalog (#348). The reapply below should now:
#   - merge `allowlisted-plugin@allowlist-mkt` into the isolated
#     installed_plugins.json (union with channel-declared plugins),
#   - grant u:<os_user>:r-X to the allowlisted plugin's install path,
#   - symlink marketplaces/allowlist-mkt under the isolated plugins root,
#   - emit an `isolated_plugin_manifest_written` audit row carrying both
#     plugin ids.
mkdir -p "$CONTROLLER_PLUGINS/cache/allowlist-mkt/allowlisted-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/marketplaces/allowlist-mkt"
echo 'allowlisted plugin source (cache)' \
  > "$CONTROLLER_PLUGINS/cache/allowlist-mkt/allowlisted-plugin/0.1.0/index.js"
echo '{"name":"allowlist-mkt","plugins":["allowlisted-plugin"]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/allowlist-mkt/marketplace.json"
mkdir -p "$BRIDGE_HOME/plugins/allowlisted-plugin"
echo 'allowlisted plugin (dir-marketplace)' \
  > "$BRIDGE_HOME/plugins/allowlisted-plugin/server.ts"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"
chmod -R go-rwx "$BRIDGE_HOME/plugins/allowlisted-plugin"

python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$BRIDGE_HOME/plugins/allowlisted-plugin" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["allowlisted-plugin@allowlist-mkt"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY

# known_marketplaces.json needs the allowlist-mkt entry so
# bridge_resolve_plugin_install_path's directory-marketplace fallback
# path is exercised the same way as td-mkt.
python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" "$BRIDGE_HOME" <<'PY'
import json, sys
markets_path, bridge_home = sys.argv[1], sys.argv[2]
with open(markets_path) as f:
    data = json.load(f)
data["allowlist-mkt"] = {
    "source": {"source": "directory", "path": bridge_home},
    "installLocation": bridge_home,
}
with open(markets_path, "w") as f:
    json.dump(data, f, indent=2)
PY

# Roster declares the allowlist alongside the existing channel; both
# tokens should land in the isolated manifest after the reapply.
BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]='allowlisted-plugin@allowlist-mkt'

# Truncate the audit log so the post-reapply assertion does not match
# audit rows produced by the earlier share-call. The default location
# is $BRIDGE_LOG_DIR/audit.jsonl per bridge_load_roster's defaulting.
audit_log_file="${BRIDGE_AUDIT_LOG:-$BRIDGE_LOG_DIR/audit.jsonl}"
mkdir -p "$(dirname "$audit_log_file")"
: > "$audit_log_file"

BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying per-UID manifest now lists union of channel + allowlist plugins"
sudo -n cat "$ISOLATED_PLUGINS/installed_plugins.json" | python3 -c '
import json, sys
m = json.load(sys.stdin)
plugins = sorted(m.get("plugins", {}).keys())
expected = ["allowlisted-plugin@allowlist-mkt", "declared-plugin@td-mkt"]
assert plugins == expected, f"unexpected manifest plugins: {plugins!r} (expected {expected!r})"
for pid in expected:
    entry = m["plugins"][pid][0]
    assert "installPath" in entry and entry["installPath"], f"missing installPath for {pid}"
' || die "per-UID manifest did not include BRIDGE_AGENT_PLUGINS allowlist entry (#348)"

log "verifying allowlisted plugin's install path has u:${TEST_OS_USER}:r-X recursively"
allowlisted_path="$BRIDGE_HOME/plugins/allowlisted-plugin"
sudo -n getfacl --no-effective "$allowlisted_path" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "allowlisted plugin dir missing u:${TEST_OS_USER}:r-x ACL ($allowlisted_path)"
sudo -n getfacl --no-effective "$allowlisted_path/server.ts" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r--" \
  || die "allowlisted plugin file missing u:${TEST_OS_USER}:r-- ACL"

log "verifying isolated UID can read allowlisted plugin sources"
sudo -n -u "$TEST_OS_USER" cat "$allowlisted_path/server.ts" >/dev/null \
  || die "isolated UID should be able to read allowlisted plugin source"

log "verifying marketplaces/allowlist-mkt symlink landed under isolated plugins root"
allowlisted_mkt_link="$ISOLATED_PLUGINS/marketplaces/allowlist-mkt"
sudo -n test -L "$allowlisted_mkt_link" \
  || die "expected $allowlisted_mkt_link to be a symlink"
allowlisted_mkt_resolved="$(sudo -n readlink -f "$allowlisted_mkt_link" 2>/dev/null || true)"
allowlisted_mkt_expected="$CONTROLLER_PLUGINS/marketplaces/allowlist-mkt"
[[ "$allowlisted_mkt_resolved" == "$allowlisted_mkt_expected" ]] \
  || die "marketplace symlink resolved to $allowlisted_mkt_resolved (expected $allowlisted_mkt_expected)"
sudo -n -u "$TEST_OS_USER" cat "$allowlisted_mkt_expected/marketplace.json" >/dev/null \
  || die "isolated UID should be able to read allowlisted marketplace metadata"

log "verifying git-source marketplace also gets Claude repo-slug alias"
mkdir -p "$CONTROLLER_PLUGINS/cache/git-mkt/git-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/marketplaces/git-mkt"
echo 'git marketplace plugin source (cache)' \
  > "$CONTROLLER_PLUGINS/cache/git-mkt/git-plugin/0.1.0/index.js"
echo '{"name":"git-mkt","plugins":["git-plugin"]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/git-mkt/marketplace.json"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"

python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$CONTROLLER_PLUGINS/cache/git-mkt/git-plugin/0.1.0" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["git-plugin@git-mkt"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" "$CONTROLLER_PLUGINS/marketplaces/git-mkt" <<'PY'
import json, sys
markets_path, install_location = sys.argv[1], sys.argv[2]
with open(markets_path) as f:
    data = json.load(f)
data["git-mkt"] = {
    "source": {"source": "git", "repo": "Example-Org/example-marketplace"},
    "installLocation": install_location,
}
with open(markets_path, "w") as f:
    json.dump(data, f, indent=2)
PY
BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]='allowlisted-plugin@allowlist-mkt,git-plugin@git-mkt'
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

git_mkt_link="$ISOLATED_PLUGINS/marketplaces/git-mkt"
git_mkt_slug_link="$ISOLATED_PLUGINS/marketplaces/Example-Org-example-marketplace"
for link in "$git_mkt_link" "$git_mkt_slug_link"; do
  sudo -n test -L "$link" || die "expected git marketplace alias symlink at $link"
  resolved="$(sudo -n readlink -f "$link" 2>/dev/null || true)"
  [[ "$resolved" == "$CONTROLLER_PLUGINS/marketplaces/git-mkt" ]] \
    || die "git marketplace alias $link resolved to $resolved"
done
sudo -n python3 - "$ISOLATED_PLUGINS/known_marketplaces.json" "$ISOLATED_PLUGINS" <<'PY'
import json
import sys

path, isolated_plugins = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
entry = data["git-mkt"]
expected = f"{isolated_plugins}/marketplaces/Example-Org-example-marketplace"
assert entry.get("installLocation") == expected, entry
assert entry.get("source", {}).get("repo") == "Example-Org/example-marketplace", entry
PY

log "verifying persisted grant-set carries union (allowlist promoted to plugin:<id>)"
sudo -n cat "$state_file" | python3 -c '
import json, sys
data = json.load(sys.stdin)
chans = sorted(data.get("channels", []))
expected = ["plugin:allowlisted-plugin@allowlist-mkt", "plugin:declared-plugin@td-mkt", "plugin:git-plugin@git-mkt"]
assert chans == expected, f"unexpected persisted channels: {chans!r} (expected {expected!r})"
' || die "persisted grant-set did not include BRIDGE_AGENT_PLUGINS allowlist entry (#348)"

log "verifying isolated_plugin_manifest_written audit row carries both plugin ids"
python3 - "$audit_log_file" "$TEST_AGENT" "$TEST_OS_USER" <<'PY' \
  || die "isolated_plugin_manifest_written audit row missing or malformed"
import json, sys
path, agent, os_user = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    rows = [json.loads(line) for line in f if line.strip()]
matches = [
    r for r in rows
    if r.get("action") == "isolated_plugin_manifest_written" and r.get("target") == agent
]
assert matches, f"no isolated_plugin_manifest_written rows for {agent} in {path}"
row = matches[-1]
detail = row.get("detail", {})
assert detail.get("os_user") == os_user, f"unexpected os_user: {detail!r}"
plugins_csv = detail.get("plugins") or ""
ids = sorted(filter(None, plugins_csv.split(",")))
expected = sorted([
    "plugin:allowlisted-plugin@allowlist-mkt",
    "plugin:declared-plugin@td-mkt",
    "plugin:git-plugin@git-mkt",
])
assert ids == expected, f"audit plugins mismatch: {ids!r} (expected {expected!r})"
count = detail.get("plugin_count")
# plugin_count is recorded as a string by bridge-audit.py's --detail
# normaliser (everything goes through ensure_ascii=True/json.dumps with
# the value as-is — bash always passes it as a string).
assert str(count) == str(len(expected)), f"plugin_count mismatch: {count!r}"
PY

log "marketplace symlink path now gates on known_marketplaces.json (#348 r2)"

# r2 changed the 5b' marketplace-symlink loop from a directory-existence
# gate (was: `[[ -d "$controller_plugins/marketplaces/$mkt" ]]`) to an
# explicit `known_marketplaces.json` lookup. Exercise that gate by
# adding a BRIDGE_AGENT_PLUGINS entry whose marketplace is *not*
# registered in known_marketplaces.json. The plugin should still land
# in the union manifest + audit row, but no marketplace symlink should
# be created (and no error should bubble up).
mkdir -p "$BRIDGE_HOME/plugins/unregistered-plugin"
echo 'unregistered plugin (no known_marketplaces entry)' \
  > "$BRIDGE_HOME/plugins/unregistered-plugin/server.ts"
# Materialise the on-disk mirror tree so the OLD directory-existence
# gate would have happily symlinked it. The r2 gate must skip it
# anyway because `unregistered-mkt` is missing from the JSON — that's
# the regression this assertion guards against.
mkdir -p "$CONTROLLER_PLUGINS/marketplaces/unregistered-mkt"
echo '{"name":"unregistered-mkt","plugins":["unregistered-plugin"]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/unregistered-mkt/marketplace.json"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"
chmod -R go-rwx "$BRIDGE_HOME/plugins/unregistered-plugin"

python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$BRIDGE_HOME/plugins/unregistered-plugin" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["unregistered-plugin@unregistered-mkt"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY

# Allowlist both the original allowlist-mkt entry (registered with a
# directory source) and the new unregistered-mkt entry — only the
# former should produce a marketplace symlink after the r2 gate.
BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]='allowlisted-plugin@allowlist-mkt,unregistered-plugin@unregistered-mkt'

: > "$audit_log_file"

BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying unregistered-mkt symlink was NOT created (known_marketplaces.json gate)"
unregistered_mkt_link="$ISOLATED_PLUGINS/marketplaces/unregistered-mkt"
if sudo -n test -e "$unregistered_mkt_link" 2>/dev/null; then
  die "expected NO symlink at $unregistered_mkt_link (marketplace absent from known_marketplaces.json)"
fi

log "verifying allowlist-mkt symlink still landed (registered marketplace path)"
sudo -n test -L "$ISOLATED_PLUGINS/marketplaces/allowlist-mkt" \
  || die "expected allowlist-mkt symlink to remain after r2 gate"
if sudo -n test -e "$git_mkt_slug_link" 2>/dev/null || sudo -n test -L "$git_mkt_slug_link" 2>/dev/null; then
  die "expected removed git marketplace alias symlink to be pruned after allowlist change"
fi

log "verifying audit row still carries the unregistered-mkt plugin id"
python3 - "$audit_log_file" "$TEST_AGENT" <<'PY' \
  || die "audit row missing unregistered-mkt plugin after known_marketplaces.json gate"
import json, sys
path, agent = sys.argv[1], sys.argv[2]
with open(path) as f:
    rows = [json.loads(line) for line in f if line.strip()]
matches = [
    r for r in rows
    if r.get("action") == "isolated_plugin_manifest_written" and r.get("target") == agent
]
assert matches, f"no isolated_plugin_manifest_written rows for {agent}"
detail = matches[-1].get("detail", {})
plugins_csv = detail.get("plugins") or ""
ids = set(filter(None, plugins_csv.split(",")))
# The plugin id must still be in the union — only the marketplace
# symlink is gated on known_marketplaces.json; the manifest + audit
# union is independent.
assert "plugin:unregistered-plugin@unregistered-mkt" in ids, (
    f"unregistered plugin missing from audit union: {ids!r}"
)
PY

# Reset BRIDGE_AGENT_PLUGINS so the existing channel-flip phase below
# runs in its original shape (channel-only) and the prior assertions
# stay semantically unchanged.
unset 'BRIDGE_AGENT_PLUGINS[$TEST_AGENT]'

# Re-apply once with the allowlist removed so the persisted grant set
# returns to channel-only state before the channel-flip phase.
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying allowlist removal revoked ACLs on the allowlisted plugin"
post_revoke_count="$(sudo -n getfacl --no-effective "$allowlisted_path" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$post_revoke_count" == "0" ]] \
  || die "expected u:${TEST_OS_USER} ACL gone from allowlisted plugin after allowlist removal; still has $post_revoke_count"

log "trust-controller-manifest short-circuit (#346 regression)"

# Regression coverage for #346: when an isolated agent declares a plugin
# from a third-party marketplace, the controller does not expose that
# marketplace's metadata in known_marketplaces.json under the isolated
# home (only the directory-source 'agent-bridge' marketplace and similar
# vetted entries are passed through). bridge_claude_plugin_status must
# therefore trust the controller-managed per-UID installed_plugins.json
# as authoritative — otherwise bridge-run.sh:451 preflight would invoke
# `claude plugin install`, which crashes inside the isolated UID and
# triggers a tmux respawn loop. Verify the short-circuit fires AND no
# `claude` shell-out happens for the third-party plugin id.

THIRD_PLUGIN_ID="third-party-plugin@third-marketplace"
mkdir -p "$BRIDGE_HOME/plugins/third-party-plugin"
echo 'third-party plugin (dir-marketplace)' \
  > "$BRIDGE_HOME/plugins/third-party-plugin/server.ts"
chmod -R go-rwx "$BRIDGE_HOME/plugins/third-party-plugin"

# Add the third-party plugin entry to the controller's manifest with a
# valid installPath, but DO NOT add 'third-marketplace' to
# known_marketplaces.json — that's the whole point of #346.
python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$BRIDGE_HOME/plugins/third-party-plugin" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["third-party-plugin@third-marketplace"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY

# Sanity: confirm the marketplace metadata is intentionally absent.
python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert "third-marketplace" not in data, \
    f"test setup invariant broken: third-marketplace must not be in known_marketplaces.json"
' "$CONTROLLER_PLUGINS/known_marketplaces.json" \
  || die "test setup: third-marketplace unexpectedly present in known_marketplaces.json"

# Re-issue the share with the augmented channel set so the per-UID
# manifest picks up the third-party plugin.
BRIDGE_AGENT_CHANNELS["$TEST_AGENT"]='plugin:declared-plugin@td-mkt,plugin:third-party-plugin@third-marketplace'
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying per-UID manifest contains the third-party plugin entry"
sudo -n cat "$ISOLATED_PLUGINS/installed_plugins.json" | python3 -c '
import json, sys
m = json.load(sys.stdin)
plugins = m.get("plugins", {})
assert "third-party-plugin@third-marketplace" in plugins, \
    f"per-UID manifest missing third-party plugin: {sorted(plugins)!r}"
entry = plugins["third-party-plugin@third-marketplace"][0]
assert entry.get("installPath", "").endswith("/third-party-plugin"), \
    f"unexpected installPath: {entry!r}"
' || die "per-UID manifest does not include third-party plugin"

log "verifying isolated UID's known_marketplaces.json hides 'third-marketplace'"
sudo -n -u "$TEST_OS_USER" python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert "third-marketplace" not in data, \
    f"isolation boundary broken: third-marketplace leaked into known_marketplaces.json visible to isolated UID"
' "$ISOLATED_PLUGINS/known_marketplaces.json" \
  || die "isolated UID can see third-marketplace metadata; expected hidden"

# Stub `claude` so any accidental shell-out is observable. The short-
# circuit path must NOT touch this stub; the negative case below MUST.
STUB_DIR="$TMP_ROOT/stubs"
STUB_LOG="$TMP_ROOT/claude-stub-calls.log"
mkdir -p "$STUB_DIR"
: > "$STUB_LOG"
chmod 0777 "$STUB_LOG"          # writable by the isolated UID
chmod 0755 "$STUB_DIR" "$TMP_ROOT"
cat > "$STUB_DIR/claude" <<STUB
#!/usr/bin/env bash
echo "stub-claude-invoked: \$*" >> "$STUB_LOG"
exit 0
STUB
chmod 0755 "$STUB_DIR/claude"

# Grant the isolated UID r-x access to the source checkout so it can
# source bridge-lib.sh from the test user's shell. setfacl is already a
# hard prerequisite for this test; the cleanup hook strips the ACL.
sudo -n setfacl -R -m "u:${TEST_OS_USER}:r-X" "$REPO_ROOT" \
  || die "failed to grant r-X ACL on $REPO_ROOT to $TEST_OS_USER"
# Traverse chain up to /tmp so the test user can reach the worktree.
_ancestor="$REPO_ROOT"
while [[ "$_ancestor" != "/" && "$_ancestor" != "/tmp" ]]; do
  _ancestor="$(dirname "$_ancestor")"
  [[ -d "$_ancestor" ]] || break
  sudo -n setfacl -m "u:${TEST_OS_USER}:--x" "$_ancestor" >/dev/null 2>&1 || true
done

log "asserting bridge_ensure_claude_plugin_enabled short-circuits without invoking claude"
sudo -n -u "$TEST_OS_USER" env \
    HOME="$TEST_OS_HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    REPO_ROOT="$REPO_ROOT" \
    PLUGIN_SPEC="$THIRD_PLUGIN_ID" \
    BRIDGE_HOME="$BRIDGE_HOME" \
  bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"
    status="$(bridge_claude_plugin_status "$PLUGIN_SPEC")"
    if [[ "$status" != "enabled" ]]; then
      echo "FAIL: expected enabled, got $status" >&2
      exit 1
    fi
    bridge_ensure_claude_plugin_enabled "$PLUGIN_SPEC" >/dev/null
  ' || die "bridge_ensure_claude_plugin_enabled did not short-circuit on third-party plugin"

if [[ -s "$STUB_LOG" ]]; then
  die "claude stub was invoked during short-circuit path; log: $(cat "$STUB_LOG")"
fi

log "asserting fall-through path still invokes claude when manifest is absent"
# Negative case: when HOME has no per-UID root-owned manifest (shared-mode
# semantics), bridge_claude_plugin_status falls through to `claude plugin
# list`. Stub returns no matching status line so the function reports
# "missing"; the key assertion is that the stub WAS called — proving the
# short-circuit gate is correctly scoped to the isolated-UID/root-owned
# manifest case.
NEG_HOME="$TMP_ROOT/no-manifest-home"
mkdir -p "$NEG_HOME"
chmod 0755 "$NEG_HOME"
: > "$STUB_LOG"
neg_status="$(env HOME="$NEG_HOME" PATH="$STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_claude_plugin_status "'"$THIRD_PLUGIN_ID"'"')"
if [[ "$neg_status" == "enabled" ]]; then
  die "negative case: expected fall-through to report 'missing', got '$neg_status'"
fi
if [[ ! -s "$STUB_LOG" ]]; then
  die "negative case: claude stub was NOT invoked; short-circuit gate is too loose"
fi

# ---------------------------------------------------------------------
# third-party-plugin-trust sub-case (#852 + #853)
# ---------------------------------------------------------------------
# The block above covers the isolated-UID side (#346 regression):
# `bridge_claude_plugin_status` running as the isolated UID against a
# root-owned per-UID manifest. The block below covers the
# controller-side path (#852): the controller's HOME's
# installed_plugins.json holds the third-party plugin spec, but the
# entry's installPath points into the isolated UID's mode-700 home that
# the controller cannot traverse. The os.access probe would false-fail
# and trigger a redundant `claude plugin install`, which on a
# silently-drifted controller marketplace (#853) fails with
# `Plugin "<name>" not found in marketplace "<mkt>"` and aborts the
# launch. The fix trusts the manifest's key set when the agent is
# linux-user-isolated.

log "controller-blind plugin trust + marketplace self-heal (#852 #853)"

# Snapshot of the existing claude stub log for later restoration. The
# self-heal assertions need a fresh log; the broader test below will
# re-arm the stub from scratch when it needs to.
: > "$STUB_LOG"

# Fake controller plugin tree under TMP_ROOT for the controller-side
# tests so the operator's real ~/.claude is never touched. Mirrors the
# CONTROLLER_HOME_FAKE pattern at the top of this script.
CTRL_BLIND_HOME="$TMP_ROOT/controller-blind-home"
CTRL_BLIND_PLUGINS="$CTRL_BLIND_HOME/.claude/plugins"
mkdir -p "$CTRL_BLIND_PLUGINS"
chmod 0755 "$CTRL_BLIND_HOME" "$CTRL_BLIND_HOME/.claude" "$CTRL_BLIND_PLUGINS"

# Sentinel installPath under a mode-700 directory the operator UID
# cannot traverse — mirrors the production shape where the isolated
# UID's home (/home/agent-bridge-<agent>) is mode 700 owned by the
# isolated UID and the controller has no traverse permission. Use the
# real isolated UID's home created earlier so we know controller
# os.access against this path returns False without further setup.
CTRL_BLIND_INSTALL_PATH="$TEST_OS_HOME/.claude/plugins/cache/cosmax-marketplace/cosmax-ep-approval/0.1.14"

# Write the controller's installed_plugins.json with the third-party
# entry. Use python rather than a shell heredoc so the new code added
# in this PR matches the footgun #11 ban on inline heredocs.
python3 -c '
import json, sys
manifest_path = sys.argv[1]
install_path = sys.argv[2]
payload = {
    "version": 2,
    "plugins": {
        "cosmax-ep-approval@cosmax-marketplace": [
            {"scope": "user", "version": "0.1.14", "installPath": install_path}
        ]
    },
}
with open(manifest_path, "w") as f:
    json.dump(payload, f, indent=2)
' "$CTRL_BLIND_PLUGINS/installed_plugins.json" "$CTRL_BLIND_INSTALL_PATH"

# Write a known_marketplaces.json that has the marketplace row with a
# github source — the self-heal helper extracts the repo slug from this
# row when `claude plugin marketplace list` no longer enumerates the
# marketplace.
python3 -c '
import json, sys
path = sys.argv[1]
payload = {
    "cosmax-marketplace": {
        "source": {
            "source": "github",
            "repo": "COSMAX-PI-Dev-Team/claude-plugin-registry",
        },
    },
    "agent-bridge": {
        "source": {"source": "directory", "path": "/opt/agent-bridge"},
    },
}
with open(path, "w") as f:
    json.dump(payload, f, indent=2)
' "$CTRL_BLIND_PLUGINS/known_marketplaces.json"

# Confirm the os.access probe genuinely fails for the operator UID
# against the synthetic installPath. Without this baseline an
# "enabled" result below would not actually prove the trust path —
# os.access could succeed for unrelated reasons.
if python3 -c 'import os, sys; sys.exit(0 if os.access(sys.argv[1], os.R_OK | os.X_OK) else 1)' "$CTRL_BLIND_INSTALL_PATH"; then
  die "test setup invariant broken: operator UID can traverse $CTRL_BLIND_INSTALL_PATH; expected mode-700 home block"
fi

# Re-arm the claude stub log; any `claude` shell-out during the
# isolation-trust short-circuit invalidates the test.
: > "$STUB_LOG"

THIRD_SPEC="cosmax-ep-approval@cosmax-marketplace"

log "Assertion A: bridge_claude_plugin_status trusts manifest without os.access when agent is isolated"
trust_status="$(env HOME="$CTRL_BLIND_HOME" PATH="$STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_load_roster; bridge_claude_plugin_status "'"$THIRD_SPEC"'" "'"$TEST_AGENT"'"')"
if [[ "$trust_status" != "enabled" ]]; then
  die "Assertion A failed: expected 'enabled' from controller-side trust path, got '$trust_status'"
fi
if [[ -s "$STUB_LOG" ]]; then
  die "Assertion A failed: claude stub was invoked during controller-side trust path; log: $(cat "$STUB_LOG")"
fi

log "Assertion A negative: omitting the agent arg falls through to the legacy os.access path"
neg_trust_status="$(env HOME="$CTRL_BLIND_HOME" PATH="$STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_load_roster; bridge_claude_plugin_status "'"$THIRD_SPEC"'"')"
# Without the agent arg the legacy code path either falls through to
# `claude plugin list` (returning "missing" because the stub prints
# nothing matching) or short-circuits via the root-owned manifest gate.
# Either way the new controller-side trust short-circuit MUST NOT fire,
# so an "enabled" result here is a regression.
if [[ "$neg_trust_status" == "enabled" ]]; then
  die "Assertion A negative failed: trust short-circuit fired without an agent arg in scope (legacy callers would have wrong semantics)"
fi

log "Assertion A missing-manifest negative: isolated agent + spec absent from manifest -> 'missing', not 'enabled'"
# codex r1 (#858 checkpoint 6): assert the controller-blind short-circuit
# is strictly key-set-driven. The manifest at $CTRL_BLIND_PLUGINS holds
# only THIRD_SPEC; query with a different spec and confirm the trust
# path does NOT false-positive the result to "enabled". The expected
# fall-through is `claude plugin list` (via $STUB_DIR/claude), which
# logs the call and prints nothing matching — yielding "missing".
: > "$STUB_LOG"
MISSING_SPEC="nonexistent-spec@cosmax-marketplace"
missing_trust_status="$(env HOME="$CTRL_BLIND_HOME" PATH="$STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_load_roster; bridge_claude_plugin_status "'"$MISSING_SPEC"'" "'"$TEST_AGENT"'"')"
if [[ "$missing_trust_status" == "enabled" ]]; then
  die "Assertion A missing-manifest negative failed: trust short-circuit fired for a spec the manifest does NOT list; got '$missing_trust_status' (expected 'missing')"
fi
if [[ "$missing_trust_status" != "missing" ]]; then
  die "Assertion A missing-manifest negative failed: expected 'missing' for absent spec, got '$missing_trust_status'"
fi
# The stub MUST have been invoked — that proves the short-circuit did
# not silently return early. If empty, the controller-blind path
# fabricated a result without consulting either the manifest's key
# set (correctly absent) or the legacy `claude plugin list` fallback.
if [[ ! -s "$STUB_LOG" ]]; then
  die "Assertion A missing-manifest negative failed: claude stub was never invoked; the short-circuit returned a fabricated result for an absent spec"
fi
# Reset the stub log so downstream assertions observe a clean slate.
: > "$STUB_LOG"

log "Assertion B: bridge_claude_marketplace_ensure_present_for_isolated re-adds drifted marketplace"
# Stub `claude plugin marketplace list` so the first row enumerates
# only `agent-bridge` — that simulates the controller-side drift in
# #853 where cosmax-marketplace silently disappeared from the live
# list even though known_marketplaces.json still names it. Re-arm the
# stub to honor `marketplace list` separately from the catch-all log
# behavior used above.
SELFHEAL_STUB_DIR="$TMP_ROOT/selfheal-stubs"
SELFHEAL_STUB_LOG="$TMP_ROOT/selfheal-claude-calls.log"
mkdir -p "$SELFHEAL_STUB_DIR"
: > "$SELFHEAL_STUB_LOG"
chmod 0755 "$SELFHEAL_STUB_DIR"
chmod 0666 "$SELFHEAL_STUB_LOG"
# Build the stub script via printf so the new test code stays free of
# the heredoc patterns the codex review checklist treats as a footgun.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'echo "%s" "$@" >> "%s"\n' 'stub-claude:' "$SELFHEAL_STUB_LOG"
  printf '%s\n' 'if [[ "$1" == "plugin" && "$2" == "marketplace" && "$3" == "list" ]]; then'
  printf '%s\n' '  printf "Configured marketplaces:\n  > agent-bridge\n"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} > "$SELFHEAL_STUB_DIR/claude"
chmod 0755 "$SELFHEAL_STUB_DIR/claude"

env HOME="$CTRL_BLIND_HOME" PATH="$SELFHEAL_STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_load_roster; bridge_claude_marketplace_ensure_present_for_isolated "cosmax-marketplace" "'"$TEST_AGENT"'"' \
  || die "Assertion B: self-heal helper returned non-zero on a marketplace that should be re-addable"

if ! grep -Fq 'plugin marketplace add COSMAX-PI-Dev-Team/claude-plugin-registry' "$SELFHEAL_STUB_LOG"; then
  die "Assertion B failed: expected 'plugin marketplace add COSMAX-PI-Dev-Team/claude-plugin-registry' invocation; got: $(cat "$SELFHEAL_STUB_LOG")"
fi

log "Assertion B negative: helper returns non-zero when known_marketplaces.json has no github source for the marketplace"
# Replace the catalog with a directory-source-only entry so the repo
# extractor returns empty. The self-heal helper must NOT shell out
# `marketplace add` in this case — it should degrade gracefully so the
# caller (bridge_ensure_claude_plugin_enabled) proceeds with the
# legacy install attempt and warns loudly.
python3 -c '
import json, sys
path = sys.argv[1]
payload = {
    "cosmax-marketplace": {"source": {"source": "directory", "path": "/x"}},
}
with open(path, "w") as f:
    json.dump(payload, f, indent=2)
' "$CTRL_BLIND_PLUGINS/known_marketplaces.json"
: > "$SELFHEAL_STUB_LOG"

set +e
env HOME="$CTRL_BLIND_HOME" PATH="$SELFHEAL_STUB_DIR:$PATH" \
  bash -c 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_load_roster; bridge_claude_marketplace_ensure_present_for_isolated "cosmax-marketplace" "'"$TEST_AGENT"'"' \
  >/dev/null 2>&1
neg_rc=$?
set -e
if [[ "$neg_rc" -eq 0 ]]; then
  die "Assertion B negative failed: helper returned 0 when no github source was extractable"
fi
if grep -Fq 'plugin marketplace add' "$SELFHEAL_STUB_LOG"; then
  die "Assertion B negative failed: helper invoked 'plugin marketplace add' despite no extractable repo: $(cat "$SELFHEAL_STUB_LOG")"
fi

log "Assertion B isolation gate: helper is a no-op for non-isolated agents"
# Flip the agent's isolation mode to none transiently and confirm the
# helper short-circuits without consulting known_marketplaces.json or
# the marketplace list. Restore after the assertion so downstream tests
# still see the linux-user isolation expected by the rest of this file.
_orig_iso_mode="${BRIDGE_AGENT_ISOLATION_MODE["$TEST_AGENT"]}"
BRIDGE_AGENT_ISOLATION_MODE["$TEST_AGENT"]=""
: > "$SELFHEAL_STUB_LOG"
set +e
env HOME="$CTRL_BLIND_HOME" PATH="$SELFHEAL_STUB_DIR:$PATH" \
  BRIDGE_AGENT_ISOLATION_MODE_OVERRIDE="" \
  bash -c '
    source "'"$REPO_ROOT"'/bridge-lib.sh"
    bridge_load_roster
    BRIDGE_AGENT_ISOLATION_MODE["'"$TEST_AGENT"'"]=""
    bridge_claude_marketplace_ensure_present_for_isolated "cosmax-marketplace" "'"$TEST_AGENT"'"
  ' >/dev/null 2>&1
gate_rc=$?
set -e
BRIDGE_AGENT_ISOLATION_MODE["$TEST_AGENT"]="$_orig_iso_mode"
if [[ "$gate_rc" -eq 0 ]]; then
  die "Assertion B isolation gate failed: helper returned 0 for a non-isolated agent"
fi
if [[ -s "$SELFHEAL_STUB_LOG" ]]; then
  die "Assertion B isolation gate failed: helper shelled out claude for a non-isolated agent: $(cat "$SELFHEAL_STUB_LOG")"
fi

# Reset the trust-path stub log for the existing post-block assertions
# below so they observe a clean slate.
: > "$STUB_LOG"

# Drop the third-party plugin from the channel set so the existing
# stale-ACL-revoke assertion below operates on the original baseline
# (declared-plugin only -> replacement-plugin only).
BRIDGE_AGENT_CHANNELS["$TEST_AGENT"]='plugin:declared-plugin@td-mkt'
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "stale-ACL revoke on channel change (Blocking 1 regression)"

# At this point declared-plugin@td-mkt has been granted (line ~195 above).
# Confirm the grant landed on the original install path before flipping
# channels — without this baseline we can't tell a true revoke from a
# never-granted state.
sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/declared-plugin" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "expected u:${TEST_OS_USER}:r-x on declared-plugin before channel flip"

# Add a fresh plugin (replacement-plugin) to both the directory marketplace
# tree and the controller's installed_plugins.json, then flip the agent's
# channel to it — drops declared-plugin, adds replacement-plugin.
mkdir -p "$CONTROLLER_PLUGINS/cache/td-mkt/replacement-plugin/0.1.0"
echo 'replacement plugin source (cache)' \
  > "$CONTROLLER_PLUGINS/cache/td-mkt/replacement-plugin/0.1.0/index.js"
mkdir -p "$BRIDGE_HOME/plugins/replacement-plugin"
echo 'replacement plugin (dir-marketplace)' \
  > "$BRIDGE_HOME/plugins/replacement-plugin/server.ts"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"
chmod -R go-rwx "$BRIDGE_HOME/plugins/replacement-plugin"

python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$BRIDGE_HOME/plugins/replacement-plugin" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["replacement-plugin@td-mkt"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY

BRIDGE_AGENT_CHANNELS["$TEST_AGENT"]='plugin:replacement-plugin@td-mkt'

# Re-apply with the new channel set. This is the call shape that
# triggers the stale-revoke path on declared-plugin (prior set) and the
# grant path on replacement-plugin (current set).
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying old plugin's u:${TEST_OS_USER} ACL is gone after channel flip"
stale_count="$(sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/declared-plugin" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$stale_count" == "0" ]] \
  || die "expected u:${TEST_OS_USER} ACL gone from declared-plugin after channel flip; still has $stale_count entr(ies)"

log "verifying new plugin's u:${TEST_OS_USER}:r-x ACL is present after channel flip"
sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/replacement-plugin" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "expected u:${TEST_OS_USER}:r-x on replacement-plugin after channel flip"

log "verifying persisted grant-set reflects the new channel set, not the old"
sudo -n cat "$state_file" | python3 -c '
import json, sys
data = json.load(sys.stdin)
chans = data.get("channels", [])
assert chans == ["plugin:replacement-plugin@td-mkt"], f"unexpected persisted channels after flip: {chans!r}"
' || die "persisted grant-set did not reflect channel flip (expected only replacement-plugin)"

# After the channel flip the saved grant-set persists replacement-plugin
# only, so the upcoming unisolate-cleanup assertions need to target that
# path. Reassign declared_path here rather than introducing a parallel
# variable so the existing assertion loop below stays intact.
declared_path="$BRIDGE_HOME/plugins/replacement-plugin"

# -----------------------------------------------------------------------------
# Adversarial / boundary coverage (PR #557 r2). Each subsection here drives
# the catalog/symlink helpers with hostile inputs and asserts the expected
# fail-loud or precedence behavior. Snapshots of the controller's
# installed_plugins.json + known_marketplaces.json + BRIDGE_AGENT_PLUGINS
# are taken before each adversarial mutation and restored afterwards so the
# linear flow above (and the unisolate teardown below) sees the same state
# it would have seen without these sections.
# -----------------------------------------------------------------------------

log "snapshotting controller catalog state for adversarial cases"
ADV_SNAP_INSTALLED="$TMP_ROOT/installed_plugins.snapshot.json"
ADV_SNAP_KNOWN="$TMP_ROOT/known_marketplaces.snapshot.json"
cp "$CONTROLLER_PLUGINS/installed_plugins.json" "$ADV_SNAP_INSTALLED"
cp "$CONTROLLER_PLUGINS/known_marketplaces.json" "$ADV_SNAP_KNOWN"
ADV_SNAP_AGENT_PLUGINS="${BRIDGE_AGENT_PLUGINS[$TEST_AGENT]:-}"

restore_adv_snapshot() {
  cp "$ADV_SNAP_INSTALLED" "$CONTROLLER_PLUGINS/installed_plugins.json"
  cp "$ADV_SNAP_KNOWN" "$CONTROLLER_PLUGINS/known_marketplaces.json"
  if [[ -n "$ADV_SNAP_AGENT_PLUGINS" ]]; then
    BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]="$ADV_SNAP_AGENT_PLUGINS"
  else
    unset 'BRIDGE_AGENT_PLUGINS[$TEST_AGENT]' 2>/dev/null || true
  fi
}

log "Adv-1: GitHub URL alias parsing (4 forms + bare org/repo)"

# Drive bridge_known_marketplace_info directly with a synthesised
# known_marketplaces.json file per case. Each form must reduce to the
# expected `<org>-<repo>` slug alias regardless of how the operator
# typed `source.repo`.
ADV_PLUGINS_ROOT="$TMP_ROOT/adv-plugins-root"
mkdir -p "$ADV_PLUGINS_ROOT"
ADV_KNOWN="$ADV_PLUGINS_ROOT/known_marketplaces.json"
adv_check_alias() {
  local label="$1" repo_field="$2" expected_slug="$3"
  python3 - "$ADV_KNOWN" "$repo_field" <<'PY'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    json.dump({
        "adv-mkt": {
            "source": {"source": "git", "repo": repo},
            "installLocation": "/nonexistent/adv",
        }
    }, f)
PY
  local out=""
  out="$(bridge_known_marketplace_info "adv-mkt" "$ADV_PLUGINS_ROOT")" \
    || die "Adv-1[$label]: bridge_known_marketplace_info failed for repo=$repo_field"
  # Format: present:<kind>\t<src>\talias1\talias2...
  local aliases=""
  aliases="$(printf '%s\n' "$out" | awk -F'\t' '{for (i=3;i<=NF;i++) printf "%s ",$i}')"
  case " $aliases " in
    *" $expected_slug "*) : ;;
    *) die "Adv-1[$label]: expected alias '$expected_slug' for repo='$repo_field', got aliases: $aliases (raw: $out)" ;;
  esac
}

adv_check_alias "https-no-suffix"  "https://github.com/foo/bar"        "foo-bar"
adv_check_alias "https-dot-git"    "https://github.com/foo/bar.git"    "foo-bar"
adv_check_alias "ssh-form"         "git@github.com:foo/bar.git"        "foo-bar"
adv_check_alias "bare-org-repo"    "foo/bar"                           "foo-bar"
adv_check_alias "bare-dot-git"     "foo/bar.git"                       "foo-bar"
# Defensive: a full URL must NOT round-trip through the naive
# slugifier (regression guard for the original bug — `https://...` →
# `https:--github.com-foo-bar.git`). The presence-of-foo-bar check above
# is necessary; we additionally assert the bad alias is absent.
out_full="$(bridge_known_marketplace_info "adv-mkt" "$ADV_PLUGINS_ROOT")"
case "$out_full" in
  *"https:--"*|*"https---"*)
    die "Adv-1: leaked URL form leaked into alias output: $out_full"
    ;;
esac
log "Adv-1 PASS"

log "Adv-2a: catalog-generator alias collision detection"

# Catalog generator collision shape: two marketplace ids whose
# `marketplace_source_info` returns the same `slug or marketplace`
# value. With both source.repo values reducing to the same `<org>-<repo>`
# slug AND a controller-side mirror tree present at
# `marketplaces/<slug>`, both candidates take that slug as their alias —
# the catalog rewrite would silently land them on the same isolated
# `<isolated>/marketplaces/<slug>` location and the second JSON entry
# would overwrite the first.
COLLISION_PLUGINS_DIR="$BRIDGE_HOME/plugins"
mkdir -p "$COLLISION_PLUGINS_DIR/cg-plugin-a" \
         "$COLLISION_PLUGINS_DIR/cg-plugin-b"
echo 'cg-a' > "$COLLISION_PLUGINS_DIR/cg-plugin-a/server.ts"
echo 'cg-b' > "$COLLISION_PLUGINS_DIR/cg-plugin-b/server.ts"
# Both ids' slug (`shared/repo`) reduces to `shared-repo`. The
# controller-side mirror at `marketplaces/shared-repo` makes both
# `marketplace_source_info` candidate searches resolve to that dir, and
# both `slug or marketplace` evaluations produce `shared-repo`.
mkdir -p "$CONTROLLER_PLUGINS/marketplaces/shared-repo"
echo '{"name":"shared-repo","plugins":[]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/shared-repo/marketplace.json"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"

python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["cg-mkt-1"] = {
    "source": {"source": "git", "repo": "shared/repo"},
    "installLocation": "/nonexistent/cg-1",
}
data["cg-mkt-2"] = {
    "source": {"source": "git", "repo": "https://github.com/shared/repo.git"},
    "installLocation": "/nonexistent/cg-2",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" \
        "$COLLISION_PLUGINS_DIR/cg-plugin-a" \
        "$COLLISION_PLUGINS_DIR/cg-plugin-b" <<'PY'
import json, sys
manifest_path, ip_a, ip_b = sys.argv[1:]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["cg-plugin-a@cg-mkt-1"] = [
    {"scope": "user", "version": "0.1.0", "installPath": ip_a},
]
data.setdefault("plugins", {})["cg-plugin-b@cg-mkt-2"] = [
    {"scope": "user", "version": "0.1.0", "installPath": ip_b},
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]='cg-plugin-a@cg-mkt-1,cg-plugin-b@cg-mkt-2'

set +e
ADV_OUT="$(BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT" 2>&1)"
ADV_RC=$?
set -e
if [[ "$ADV_RC" -eq 0 ]]; then
  die "Adv-2a: expected bridge_linux_share_plugin_catalog to fail on catalog-generator alias collision; rc=0, output: $ADV_OUT"
fi
case "$ADV_OUT" in
  *"alias collision"*|*"alias collision detected"*) : ;;
  *) die "Adv-2a: expected 'alias collision' in error, got: $ADV_OUT" ;;
esac
case "$ADV_OUT" in
  *"cg-mkt-1"*) : ;;
  *) die "Adv-2a: collision error did not name 'cg-mkt-1': $ADV_OUT" ;;
esac
case "$ADV_OUT" in
  *"cg-mkt-2"*) : ;;
  *) die "Adv-2a: collision error did not name 'cg-mkt-2': $ADV_OUT" ;;
esac
log "Adv-2a PASS"

restore_adv_snapshot
sudo -n rm -rf "$CONTROLLER_PLUGINS/marketplaces/shared-repo" >/dev/null 2>&1 || true

log "Adv-2b: symlink-loop alias collision detection (defense-in-depth)"

# Symlink-loop collision shape: the catalog generator passes (its single
# alias per entry doesn't collide), but the symlink loop emits BOTH the
# marketplace id AND the slug for each marketplace, so two different
# marketplaces can still reach the same `marketplaces/<alias>` symlink
# target. Specifically:
#   - mkt id `foo-bar-baz` (slug `another-marketplace` from `another/marketplace`)
#     → symlink-loop aliases: foo-bar-baz, another-marketplace
#   - mkt id `coll-mkt-2`  (slug `foo-bar-baz` from `foo/bar-baz`)
#     → symlink-loop aliases: coll-mkt-2, foo-bar-baz
#   ⇒ collision on `foo-bar-baz`.
mkdir -p "$COLLISION_PLUGINS_DIR/sl-plugin-a" \
         "$COLLISION_PLUGINS_DIR/sl-plugin-b"
echo 'sl-a' > "$COLLISION_PLUGINS_DIR/sl-plugin-a/server.ts"
echo 'sl-b' > "$COLLISION_PLUGINS_DIR/sl-plugin-b/server.ts"
mkdir -p "$CONTROLLER_PLUGINS/marketplaces/foo-bar-baz"
echo '{"name":"foo-bar-baz","plugins":[]}' \
  > "$CONTROLLER_PLUGINS/marketplaces/foo-bar-baz/marketplace.json"
chmod -R o+rX "$CONTROLLER_HOME_FAKE"

python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["foo-bar-baz"] = {
    "source": {"source": "git", "repo": "another/marketplace"},
    "installLocation": "/nonexistent/sl-1",
}
data["coll-mkt-2"] = {
    "source": {"source": "git", "repo": "foo/bar-baz"},
    "installLocation": "/nonexistent/sl-2",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" \
        "$COLLISION_PLUGINS_DIR/sl-plugin-a" \
        "$COLLISION_PLUGINS_DIR/sl-plugin-b" <<'PY'
import json, sys
manifest_path, ip_a, ip_b = sys.argv[1:]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["sl-plugin-a@foo-bar-baz"] = [
    {"scope": "user", "version": "0.1.0", "installPath": ip_a},
]
data.setdefault("plugins", {})["sl-plugin-b@coll-mkt-2"] = [
    {"scope": "user", "version": "0.1.0", "installPath": ip_b},
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]='sl-plugin-a@foo-bar-baz,sl-plugin-b@coll-mkt-2'

set +e
ADV_OUT="$(BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT" 2>&1)"
ADV_RC=$?
set -e
if [[ "$ADV_RC" -eq 0 ]]; then
  die "Adv-2b: expected bridge_linux_share_plugin_catalog to fail on symlink-loop alias collision; rc=0, output: $ADV_OUT"
fi
case "$ADV_OUT" in
  *"alias collision"*|*"alias collision detected"*) : ;;
  *) die "Adv-2b: expected 'alias collision' in error, got: $ADV_OUT" ;;
esac
case "$ADV_OUT" in
  *"foo-bar-baz"*) : ;;
  *) die "Adv-2b: collision error did not name 'foo-bar-baz': $ADV_OUT" ;;
esac
case "$ADV_OUT" in
  *"coll-mkt-2"*) : ;;
  *) die "Adv-2b: collision error did not name 'coll-mkt-2': $ADV_OUT" ;;
esac
log "Adv-2b PASS"

restore_adv_snapshot
# Drop the synthesised marketplace mirror trees so the next adversarial
# pass starts from a clean controller surface.
sudo -n rm -rf "$CONTROLLER_PLUGINS/marketplaces/foo-bar-baz" \
               >/dev/null 2>&1 || true

log "Adv-3: marketplace-id traversal/control-char rejection"

# Subgroup A — CSV-survivable shapes (`..`, leading/trailing slash).
# These pass through `bridge_agent_plugins_csv`'s tokenizer as the literal
# characters and reach the validator inside both the catalog generator
# and `bridge_known_marketplace_info`.
adv_run_unsafe_id() {
  local label="$1" mkt_id="$2"
  # Restore baseline catalog so each unsafe-id case starts clean.
  cp "$ADV_SNAP_INSTALLED" "$CONTROLLER_PLUGINS/installed_plugins.json"
  cp "$ADV_SNAP_KNOWN" "$CONTROLLER_PLUGINS/known_marketplaces.json"
  python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" "$mkt_id" <<'PY'
import json, sys
path, mkt_id = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data[mkt_id] = {
    "source": {"source": "git", "repo": "Example-Org/unsafe-mkt"},
    "installLocation": "/nonexistent/unsafe",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
  python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$mkt_id" <<'PY'
import json, sys
manifest_path, mkt_id = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["unsafe-plugin@" + mkt_id] = [
    {"scope": "user", "version": "0.1.0", "installPath": "/nonexistent/unsafe"}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
  BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]="unsafe-plugin@${mkt_id}"
  set +e
  local out=""
  out="$(BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
    bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT" 2>&1)"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    die "Adv-3[$label]: expected fail-loud rejection of unsafe marketplace id (printf %q form: $(printf '%q' "$mkt_id")); got rc=0, output: $out"
  fi
  case "$out" in
    *rejected*|*unsafe*|*"alias collision"*) : ;;
    *)
      die "Adv-3[$label]: expected 'rejected' or 'unsafe' in error for id $(printf '%q' "$mkt_id"), got: $out"
      ;;
  esac
}

adv_run_unsafe_id "double-dot-prefix" "..foo"
adv_run_unsafe_id "dotdot-mid"        "foo..bar"
adv_run_unsafe_id "leading-slash"     "/foo"
adv_run_unsafe_id "trailing-slash"    "foo/"

# Subgroup B — adversarial inputs that *cannot* enter via BRIDGE_AGENT_PLUGINS
# (the bash tokenizer in `bridge_agent_plugins_csv` splits on `[ \t\n,]`)
# but CAN enter via `known_marketplaces.json` keys/values, which is
# operator-controlled JSON. The end-to-end gate is:
#   BRIDGE_AGENT_PLUGINS  → tokenize  → catalog write  → validator
# so the security boundary that codex r2 finding 4b challenged is whether
# adversarial JSON content reaches the validator and is rejected.
#
# These cases drive `bridge_linux_share_plugin_catalog` end-to-end (the
# real production attack surface) rather than re-implementing the
# validator in inline Python — which was the bypass r2 flagged.
adv_run_unsafe_known_marketplaces_key() {
  # Stage a controller `known_marketplaces.json` whose KEY contains an
  # adversarial sequence (newline, tab, etc.) and a clean plugin ref to
  # ensure the catalog generator iterates the entry. Assert the share
  # helper fails loud.
  #
  # Mechanism:
  #   - The agent declares a *clean* marketplace id via
  #     BRIDGE_AGENT_PLUGINS, but we ALSO inject an unsafe key into the
  #     controller's known_marketplaces.json. The catalog generator
  #     iterates `declared_marketplaces()` (filtered to declared) and
  #     would only validate the clean id — so we additionally seed
  #     installed_plugins.json with a `<plugin>@<unsafe_key>` entry
  #     that the agent declares verbatim. The bash tokenizer's literal-
  #     character split keeps `..` / `foo..bar` / `/foo` intact (these
  #     pass the tokenizer untouched, see Subgroup A), and we use those
  #     same shapes here against the END-to-end catalog writer.
  #
  # NOTE: literal `\n`/`\t` cannot enter via BRIDGE_AGENT_PLUGINS at all
  # because the bash tokenizer eats them. The matching coverage is in
  # the unit assertion at the bottom of this section, which targets the
  # validator's regex/length/empty branches the way an operator would
  # see them in a `bridge_isolate` failure log.
  local label="$1" mkt_id="$2"
  cp "$ADV_SNAP_INSTALLED" "$CONTROLLER_PLUGINS/installed_plugins.json"
  cp "$ADV_SNAP_KNOWN" "$CONTROLLER_PLUGINS/known_marketplaces.json"
  python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" "$mkt_id" <<'PY'
import json, sys
path, mkt_id = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data[mkt_id] = {
    "source": {"source": "git", "repo": "Example-Org/unsafe-mkt"},
    "installLocation": "/nonexistent/unsafe",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
  python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$mkt_id" <<'PY'
import json, sys
manifest_path, mkt_id = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["unsafe-plugin@" + mkt_id] = [
    {"scope": "user", "version": "0.1.0", "installPath": "/nonexistent/unsafe"}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
  BRIDGE_AGENT_PLUGINS["$TEST_AGENT"]="unsafe-plugin@${mkt_id}"
  set +e
  local out=""
  out="$(BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
    bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT" 2>&1)"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    die "Adv-3[$label]: bridge_linux_share_plugin_catalog should have failed loud on adversarial known_marketplaces.json key $(printf '%q' "$mkt_id"); rc=0, output: $out"
  fi
  case "$out" in
    *rejected*|*unsafe*|*"alias collision"*) : ;;
    *)
      die "Adv-3[$label]: expected 'rejected' or 'unsafe' in error for known_marketplaces.json key $(printf '%q' "$mkt_id"), got: $out"
      ;;
  esac
}

# Adversarial JSON-key forms that the bash tokenizer DOES preserve
# verbatim (so the production end-to-end pipeline carries them to the
# validator inside `bridge_write_isolated_known_marketplaces_catalog`).
adv_run_unsafe_known_marketplaces_key "key-dot-only"        "."
adv_run_unsafe_known_marketplaces_key "key-double-dot-only" ".."

# Whitespace-embedded JSON keys (r3 finding 4b end-to-end gap): the bash
# tokenizer in `bridge_agent_plugins_csv` / `bridge_normalize_channels_csv`
# strips space/tab/newline/CR from agent declarations BEFORE the catalog
# generator sees them, so `adv_run_unsafe_known_marketplaces_key` cannot
# carry these shapes through BRIDGE_AGENT_PLUGINS. To exercise the
# validator's whitespace-rejection branch end-to-end against the actual
# JSON-key surface, we invoke `bridge_write_isolated_known_marketplaces_catalog`
# directly with a hand-crafted channels_csv that bypasses the bash
# tokenizer. The catalog writer's inline `declared_marketplaces()` does
# call `token.strip()` on each split element, so leading/trailing
# whitespace (e.g. `\tfoo`, `foo\n`) is collapsed before the validator
# sees the key — those shapes are covered separately by the
# cross-validator parity sweep below (which calls the inline lib
# validator directly with no tokenizer/strip in the way). The cases
# here are the embedded-whitespace shapes that survive `.strip()` and
# reach the validator with their whitespace intact.
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer() {
  # Stage a controller `known_marketplaces.json` whose KEY contains a
  # whitespace-bearing sequence and pass that key verbatim to the
  # catalog writer via channels_csv (no bash-level tokenization). Assert
  # non-zero exit and an error message that names the offending key.
  local label="$1" mkt_id="$2"
  cp "$ADV_SNAP_INSTALLED" "$CONTROLLER_PLUGINS/installed_plugins.json"
  cp "$ADV_SNAP_KNOWN" "$CONTROLLER_PLUGINS/known_marketplaces.json"
  python3 - "$CONTROLLER_PLUGINS/known_marketplaces.json" "$mkt_id" <<'PY'
import json, sys
path, mkt_id = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data[mkt_id] = {
    "source": {"source": "git", "repo": "Example-Org/unsafe-mkt"},
    "installLocation": "/nonexistent/unsafe",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
  # Hand-crafted channels_csv: the catalog writer's `declared_marketplaces()`
  # splits on `,`, calls `token.strip()` on each element (so we MUST use
  # embedded-whitespace shapes — leading/trailing whitespace is stripped
  # off before the `@`-split), then takes everything after `@` as the
  # marketplace id. We deliberately bypass `bridge_agent_channels_csv`
  # (which would also strip embedded whitespace via its tokenizer) so
  # the bad key reaches the validator unmodified.
  local channels_csv="plugin:unsafe-plugin@${mkt_id}"
  set +e
  local out=""
  out="$(BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
    bridge_write_isolated_known_marketplaces_catalog \
      "$TEST_OS_USER" "$ISOLATED_PLUGINS" "$CONTROLLER_PLUGINS" \
      "$channels_csv" "" "$TEST_AGENT" 2>&1)"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    die "Adv-3[$label]: bridge_write_isolated_known_marketplaces_catalog should have failed loud on whitespace-bearing known_marketplaces.json key $(printf '%q' "$mkt_id"); rc=0, output: $out"
  fi
  case "$out" in
    *rejected*|*unsafe*|*"alias collision"*) : ;;
    *)
      die "Adv-3[$label]: expected 'rejected' or 'unsafe' in error for whitespace-bearing known_marketplaces.json key $(printf '%q' "$mkt_id"), got: $out"
      ;;
  esac
}

# Whitespace shapes that survive `.strip()` in `declared_marketplaces()`
# and reach `alias_rejection_reason` with their whitespace bytes intact:
#   - embedded space/tab/newline/CR (whitespace BETWEEN non-whitespace
#     chars is preserved by `.strip()`)
#   - leading whitespace AFTER an `@` (the strip happens before the
#     `@`-split, so a tab between `@` and the rest of the marketplace
#     id stays attached to the marketplace half)
# The trailing-whitespace shape `foo\n` is collapsed to `foo` by
# `token.strip()` (the entire token's trailing newline is stripped
# before the `@`-split), so that case doesn't reach the validator on
# this end-to-end path. It's covered by the cross-validator parity
# sweep below, which calls the inline lib validator directly.
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer "key-embedded-space"   'foo bar'
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer "key-embedded-tab"     $'foo\tbar'
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer "key-embedded-newline" $'foo\nbar'
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer "key-embedded-cr"      $'foo\rbar'
adv_run_unsafe_known_marketplaces_key_bypass_tokenizer "key-leading-tab"      $'\tfoo'

# Tokenizer coverage: confirm `bridge_agent_plugins_csv` strips
# `\n`/`\t`/space from BRIDGE_AGENT_PLUGINS values BEFORE the catalog
# generator sees them. This pins the upstream gate that prevents
# whitespace-bearing entries from reaching the validator end-to-end —
# the design contract that r2 finding 4b asked us to make explicit.
# Implementation: `read -ra` with IFS=$' \t\n,' tokenizes the raw value;
# `<<<` herestring + `read`'s default line-bounded behavior means a
# `\n` truncates the input at the first newline (the rest is dropped),
# while `\t` and ` ` are treated as token separators. Either way: NO
# whitespace byte reaches the emitted CSV. Test runs in a subshell so
# adversarial assignments don't leak into the rest of the suite.
log "Adv-3 tokenizer-rejection: BRIDGE_AGENT_PLUGINS whitespace-bearing entries are stripped by bridge_agent_plugins_csv"
(
  declare -A BRIDGE_AGENT_PLUGINS=()
  # Newline-bearing input: read truncates at the first `\n`; rest dropped.
  BRIDGE_AGENT_PLUGINS["adv_tok"]=$'plugin-a@safe-mkt\nplugin-b@bad-mkt'
  csv="$(bridge_agent_plugins_csv adv_tok)"
  case "$csv" in
    *$'\n'*) printf '[adv-tok] FAIL: tokenizer leaked literal newline: %q\n' "$csv" >&2; exit 1 ;;
  esac
  # Tab-bearing input: tab is treated as a token separator; both halves
  # land in the CSV but each is whitespace-free.
  BRIDGE_AGENT_PLUGINS["adv_tok"]=$'plugin-a@safe-mkt\tplugin-b@bad-mkt'
  csv="$(bridge_agent_plugins_csv adv_tok)"
  case "$csv" in
    *$'\n'*|*$'\t'*) printf '[adv-tok] FAIL: tokenizer leaked tab: %q\n' "$csv" >&2; exit 1 ;;
  esac
  # Space-bearing input: same — space is a separator.
  BRIDGE_AGENT_PLUGINS["adv_tok"]='plugin-a@safe-mkt plugin-b@bad-mkt'
  csv="$(bridge_agent_plugins_csv adv_tok)"
  case "$csv" in
    *' '*) printf '[adv-tok] FAIL: tokenizer leaked space: %q\n' "$csv" >&2; exit 1 ;;
  esac
  # Pathological: trailing newline alone — first token must still be
  # whitespace-free in the emitted CSV (regression for r3 #3a where the
  # *validator* tolerated trailing newline; the tokenizer's strip is
  # the upstream gate that makes this unreachable through this path).
  BRIDGE_AGENT_PLUGINS["adv_tok"]=$'plugin-a@safe-mkt\n'
  csv="$(bridge_agent_plugins_csv adv_tok)"
  case "$csv" in
    *$'\n'*) printf '[adv-tok] FAIL: tokenizer kept trailing newline: %q\n' "$csv" >&2; exit 1 ;;
  esac
  [[ "$csv" == "plugin-a@safe-mkt" ]] \
    || { printf '[adv-tok] FAIL: trailing-newline csv unexpected: %q\n' "$csv" >&2; exit 1; }
  exit 0
) || die "Adv-3 tokenizer rejection: BRIDGE_AGENT_PLUGINS whitespace leaked through bridge_agent_plugins_csv (security gate broken)"

# Validator unit pin: empty/whitespace/length/trailing-newline branches.
# The trailing-newline assertion is the r3 finding 3a regression: the
# old `re.match(... + "$")` form let `foo\n` pass (in default mode, `$`
# matches before a trailing `\n`). `re.fullmatch` rejects it. Both
# Python validators (lib/bridge-agents.sh inline + bridge-dev-plugin-
# cache.py module-level) must agree.
python3 - <<'PY'
import re
# Mirror the production validator. Use `fullmatch`, not `match(... + "$")`.
_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")
def reason(a):
    if not isinstance(a, str): return "not a string"
    if a == "": return "empty"
    if len(a) > 200: return "length exceeds 200"
    if not _SAFE_ALIAS_RE.fullmatch(a): return "regex"
    if ".." in a: return "contains '..'"
    if a in {".", ".."}: return "reserved name"
    if a.startswith(".") and a != ".git": return "leading dot disallowed"
    return ""
assert reason("") == "empty", "empty alias must be rejected"
assert reason(".git") == "", "'.git' is the documented escape hatch and must remain accepted"
assert reason("foo bar") != "", "whitespace must be rejected"
assert reason("a" * 201) != "", "length>200 must be rejected"
# r3 finding 3a regressions: trailing newline / carriage-return must be
# rejected. With the OLD `re.match(... + "$")` form these passed; with
# `re.fullmatch` they're rejected.
assert reason("foo\n") != "", "alias with trailing newline must be rejected (r3 #3a)"
assert reason("bar\n") != "", "alias 'bar\\n' must be rejected (r3 #3a)"
assert reason("baz\r") != "", "alias 'baz\\r' must be rejected (r3 #3a)"
# Sanity: the same prefix without the control char remains accepted.
assert reason("foo") == "", "clean alias 'foo' must remain accepted"
assert reason("baz") == "", "clean alias 'baz' must remain accepted"
PY

# Cross-validator parity check: import BOTH production validators and
# confirm they agree on the trailing-newline regression. This is the
# regression bridge between bridge-dev-plugin-cache.py (where #3a was
# discovered) and the lib/bridge-agents.sh inline mirror — drift here
# would let one path block while the other passes adversarial input.
#
# r3 finding 4b second gap: the previous version of this block only
# imported bridge-dev-plugin-cache.py and never exercised the inline
# `lib/bridge-agents.sh` validator. The inline mirror is text-extracted
# from the .sh file (the canonical block inside
# `bridge_write_isolated_known_marketplaces_catalog`), loaded into a
# fresh module via importlib, and compared accept/reject with the
# dev-cache validator on a fixed input set. Reason strings differ
# between the two (the dev-cache validator interpolates the offending
# alias), so parity is asserted on boolean accept/reject, which is what
# the symlink-plant gate actually keys on.
python3 - "$REPO_ROOT" <<'PY'
import importlib.util, pathlib, sys, tempfile

repo_root = pathlib.Path(sys.argv[1])
dev_cache_path = repo_root / "bridge-dev-plugin-cache.py"
agents_lib_path = repo_root / "lib" / "bridge-agents.sh"

# 1. Standalone validator from bridge-dev-plugin-cache.py.
spec = importlib.util.spec_from_file_location("bridge_dev_plugin_cache", dev_cache_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
dev_cache_fn = mod._alias_rejection_reason

# 2. Extract the inline-lib validator body from lib/bridge-agents.sh by
#    line-based slicing (regex-with-DOTALL across multiple `(...)` paren
#    blocks risks catastrophic backtracking, so we walk lines instead).
#    The .sh file embeds the validator as part of a python heredoc inside
#    `bridge_known_marketplace_info` /
#    `bridge_write_isolated_known_marketplaces_catalog` /
#    `bridge_write_isolated_installed_plugins_manifest`. All three
#    mirrors are kept in sync; we take the first match. Anchor on the
#    `_SAFE_ALIAS_RE` declaration line (canonical), then walk forward
#    through the `def alias_rejection_reason(alias):` header to the
#    first `return ""` line that closes the function body. The block is
#    written to a temp .py file and importlib-loaded so
#    `alias_rejection_reason` becomes a directly-callable Python
#    function in this process.
agents_lib_lines = agents_lib_path.read_text().split("\n")
_safe_alias_marker = '_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")'
start_idx = None
for i, ln in enumerate(agents_lib_lines):
    if ln.strip() == _safe_alias_marker:
        start_idx = i
        break
assert start_idx is not None, (
    "could not locate `_SAFE_ALIAS_RE` declaration in lib/bridge-agents.sh; "
    "the parity test slices the inline validator from that anchor — if you "
    "renamed the constant, update the marker here."
)
def_idx = None
for i in range(start_idx, len(agents_lib_lines)):
    if agents_lib_lines[i].strip() == "def alias_rejection_reason(alias):":
        def_idx = i
        break
assert def_idx is not None, (
    "found `_SAFE_ALIAS_RE` in lib/bridge-agents.sh but no following "
    "`def alias_rejection_reason(alias):` — the inline validator shape "
    "changed; update the parity-test slice anchors here."
)
end_idx = None
for i in range(def_idx + 1, len(agents_lib_lines)):
    if agents_lib_lines[i].strip() == 'return ""':
        end_idx = i
        break
assert end_idx is not None, (
    "found `def alias_rejection_reason` in lib/bridge-agents.sh but no "
    "`return \"\"` line that closes the function — update parity-test "
    "slice here."
)
inline_lib_src = "import re\n" + "\n".join(agents_lib_lines[start_idx:end_idx + 1]) + "\n"
with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as tf:
    tf.write(inline_lib_src)
    inline_lib_tmp = tf.name
inline_spec = importlib.util.spec_from_file_location("bridge_agents_inline_validator", inline_lib_tmp)
inline_mod = importlib.util.module_from_spec(inline_spec)
inline_spec.loader.exec_module(inline_mod)
inline_lib_fn = inline_mod.alias_rejection_reason

# Sanity: both validators must be live callables.
assert callable(dev_cache_fn) and callable(inline_lib_fn)

# 3. Boolean accept/reject parity sweep. Reason strings differ
#    intentionally (the dev-cache validator interpolates the offending
#    alias for operator legibility), so we compare `bool(reason)` only.
parity_inputs = [
    "foo",                  # both accept
    ".git",                 # both accept (documented escape hatch)
    "valid_alias-1.0",      # both accept
    "foo.git",              # both accept (".git" escape only applies when alias == ".git", not as a suffix)
    "",                     # both reject (empty)
    ".",                    # both reject (reserved)
    "..",                   # both reject (contains '..' / reserved)
    "../etc",               # both reject (contains '..')
    "foo..bar",             # both reject (contains '..' mid-string, no slash)
    ".secret",              # both reject (leading dot, not .git)
    "CON",                  # both reject (Windows reserved)
    "com1",                 # both reject (Windows reserved, case-folded)
    "foo bar",              # both reject (whitespace)
    "foo\tbar",             # both reject (whitespace)
    "foo\nbar",             # both reject (whitespace)
    "foo\rbar",             # both reject (whitespace)
    "foo\n",                # both reject (trailing newline — r3 #3a)
    "bar\n",                # both reject (trailing newline)
    "baz\r",                # both reject (trailing CR)
    "foo\r",                # both reject (trailing CR — codex r4 sample)
    "foo\t",                # both reject (trailing TAB — codex r4 sample)
    "alias\x00null",        # both reject (NUL byte)
    "alias\x1fctrl",        # both reject (control byte)
    "a" * 201,              # both reject (length > 200)
    "/etc/passwd",          # both reject (slash outside charset)
    "../../../root",        # both reject (slash + ..)
]
for sample in parity_inputs:
    dev_reason = dev_cache_fn(sample)
    lib_reason = inline_lib_fn(sample)
    dev_rejected = bool(dev_reason)
    lib_rejected = bool(lib_reason)
    assert dev_rejected == lib_rejected, (
        "validator parity drift on %r: dev-cache=%r (rejected=%s), "
        "inline-lib=%r (rejected=%s)"
        % (sample, dev_reason, dev_rejected, lib_reason, lib_rejected)
    )

# 4. Pin known accept set against both validators (regression bridge).
for accept_input in ("foo", ".git", "valid_alias-1.0"):
    assert dev_cache_fn(accept_input) == "", (
        "dev-cache validator unexpectedly rejected %r" % accept_input
    )
    assert inline_lib_fn(accept_input) == "", (
        "inline-lib validator unexpectedly rejected %r" % accept_input
    )

# 5. Pin known reject set with the same trailing-newline / control-byte
#    samples that the original parity block used. Both validators must
#    reject these — that's the security regression bridge for r3 #3a.
for sample in ("foo\n", "bar\n", "baz\r", "alias\x00null", "alias\x1fctrl"):
    dev_reason = dev_cache_fn(sample)
    lib_reason = inline_lib_fn(sample)
    assert dev_reason, "bridge-dev-plugin-cache.py must reject %r (got %r)" % (sample, dev_reason)
    assert lib_reason, "lib/bridge-agents.sh inline validator must reject %r (got %r)" % (sample, lib_reason)
PY
log "Adv-3 PASS"

restore_adv_snapshot

log "Adv-4: catalog write-denial (per-UID known_marketplaces.json is root:root 0640 + isolated UID cannot tamper)"

# Re-run a normal share so the per-UID catalog is in a known-good shape.
# `restore_adv_snapshot` already reverted controller-side files and
# BRIDGE_AGENT_PLUGINS to the pre-adversarial baseline.
BRIDGE_AGENT_CHANNELS["$TEST_AGENT"]='plugin:replacement-plugin@td-mkt'
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

ADV_CATALOG="$ISOLATED_PLUGINS/known_marketplaces.json"
sudo -n stat -c '%U:%G %a' "$ADV_CATALOG" | grep -Fq "root:root 640" \
  || die "Adv-4: expected $ADV_CATALOG to be root:root 0640 (mode), got: $(sudo -n stat -c '%U:%G %a' "$ADV_CATALOG")"
if sudo -n -u "$TEST_OS_USER" bash -c "echo POISON >> '$ADV_CATALOG'" 2>/dev/null; then
  die "Adv-4: isolated UID was able to append to per-UID known_marketplaces.json — write boundary broken"
fi
if sudo -n -u "$TEST_OS_USER" rm -f "$ADV_CATALOG" 2>/dev/null; then
  if [[ ! -e "$ADV_CATALOG" ]]; then
    die "Adv-4: isolated UID was able to unlink per-UID known_marketplaces.json"
  fi
fi
# The isolated UID must still be able to READ the catalog (Claude
# resolves marketplaces by reading it). This is the v1 ACL path.
sudo -n -u "$TEST_OS_USER" cat "$ADV_CATALOG" >/dev/null \
  || die "Adv-4: isolated UID should be able to read its own per-UID known_marketplaces.json"
log "Adv-4 PASS"

log "Adv-5: directory-marketplace installLocation/source.path precedence (agent-bridge variant)"

# bridge_known_marketplace_info's candidate order for `agent-bridge` is:
#   1. <controller>/marketplaces/<id>
#   2. <controller>/marketplaces/<slug>
#   3. installLocation
#   4. source.path
# When both installLocation AND source.path are accessible directories,
# installLocation must win. Drive this by adding an `agent-bridge` entry
# whose marketplaces/agent-bridge tree does NOT exist (so candidates 1+2
# fall through) and whose installLocation + source.path point to two
# different accessible dirs.
ADV_INSTALL_LOC="$TMP_ROOT/adv-installLocation"
ADV_SRC_PATH="$TMP_ROOT/adv-source-path"
mkdir -p "$ADV_INSTALL_LOC/.claude-plugin" "$ADV_SRC_PATH/.claude-plugin"
echo '{"name":"agent-bridge","plugins":[]}' \
  > "$ADV_INSTALL_LOC/.claude-plugin/marketplace.json"
echo '{"name":"agent-bridge","plugins":[]}' \
  > "$ADV_SRC_PATH/.claude-plugin/marketplace.json"
chmod -R o+rX "$ADV_INSTALL_LOC" "$ADV_SRC_PATH"

ADV_KNOWN_AB="$TMP_ROOT/adv-known-ab.json"
python3 - "$ADV_KNOWN_AB" "$ADV_INSTALL_LOC" "$ADV_SRC_PATH" <<'PY'
import json, sys
path, install_loc, src_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    json.dump({
        "agent-bridge": {
            "source": {"source": "directory", "path": src_path},
            "installLocation": install_loc,
        }
    }, f)
PY
ADV_AB_ROOT="$TMP_ROOT/adv-ab-root"
mkdir -p "$ADV_AB_ROOT"
cp "$ADV_KNOWN_AB" "$ADV_AB_ROOT/known_marketplaces.json"
ADV_AB_OUT="$(bridge_known_marketplace_info "agent-bridge" "$ADV_AB_ROOT")" \
  || die "Adv-5: bridge_known_marketplace_info failed for agent-bridge"
ADV_AB_SRC="$(printf '%s\n' "$ADV_AB_OUT" | awk -F'\t' '{print $2}')"
[[ "$ADV_AB_SRC" == "$ADV_INSTALL_LOC" ]] \
  || die "Adv-5: expected installLocation ($ADV_INSTALL_LOC) to win over source.path ($ADV_SRC_PATH); helper resolved $ADV_AB_SRC (raw: $ADV_AB_OUT)"
log "Adv-5 PASS"

# Adv-6: v2 group-membership-based read denial. The PR-E security claim
# is that under BRIDGE_LAYOUT=v2 the per-UID known_marketplaces.json is
# group-readable by `ab-agent-<agent>` (via chgrp + 0640) and a UID NOT
# in that group cannot read it. The Adv-4 path above exercises the v1
# named-user ACL boundary; this section pins the v2 group boundary.
#
# Capability gate: this needs a SECOND non-root UID that is provably
# NOT a member of the agent group. Provisioning a second system user
# from inside this test is a meaningful CI burden (groupdel timing,
# uid collisions) so we gate behind BRIDGE_TEST_PR_C_NONMEMBER_UID and
# explicit-skip otherwise. Silent skip is rejected — that was the gap
# that prompted r3 review finding 4a.
log "Adv-6: v2 group-membership-based read denial (non-member UID cannot read catalog)"
ADV6_NONMEMBER_UID="${BRIDGE_TEST_PR_C_NONMEMBER_UID:-}"
if [[ -z "$ADV6_NONMEMBER_UID" ]]; then
  log "Adv-6 SKIP: requires non-group-member non-root UID via BRIDGE_TEST_PR_C_NONMEMBER_UID=<username>"
  log "Adv-6 SKIP rationale: the v1 named-user ACL path is exercised by Adv-4 above; the v2 group boundary requires a second system UID that is not a member of ab-agent-<agent> — provisioning that here would duplicate v2-pr-c smoke fixture setup."
  log "Adv-6 SKIP NOTE: this is an explicit capability gap, NOT silent coverage. Operator running on a Linux CI lane with two test UIDs MUST set BRIDGE_TEST_PR_C_NONMEMBER_UID to exercise the gate end-to-end before claiming v2 group denial passes."
elif ! bridge_isolation_v2_active 2>/dev/null; then
  log "Adv-6 SKIP: BRIDGE_LAYOUT!=v2 — group ACL contract is v2-only, v1 ACL path covered by Adv-4."
elif ! id "$ADV6_NONMEMBER_UID" >/dev/null 2>&1; then
  die "Adv-6: BRIDGE_TEST_PR_C_NONMEMBER_UID=$ADV6_NONMEMBER_UID does not exist as a system user"
else
  ADV6_GROUP="$(bridge_isolation_v2_agent_group_name "$TEST_AGENT" 2>/dev/null || printf '')"
  [[ -n "$ADV6_GROUP" ]] || die "Adv-6: bridge_isolation_v2_agent_group_name returned empty for $TEST_AGENT"
  if id -nG "$ADV6_NONMEMBER_UID" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$ADV6_GROUP"; then
    die "Adv-6: BRIDGE_TEST_PR_C_NONMEMBER_UID=$ADV6_NONMEMBER_UID is a member of $ADV6_GROUP — must be a non-member to exercise the denial path"
  fi
  ADV6_CATALOG="$ISOLATED_PLUGINS/known_marketplaces.json"
  # Group member (TEST_OS_USER) must be able to read.
  sudo -n -u "$TEST_OS_USER" cat "$ADV6_CATALOG" >/dev/null \
    || die "Adv-6: group-member UID $TEST_OS_USER could not read $ADV6_CATALOG (v2 group ACL broken)"
  # Non-member must NOT be able to read.
  if sudo -n -u "$ADV6_NONMEMBER_UID" cat "$ADV6_CATALOG" >/dev/null 2>&1; then
    die "Adv-6: non-group-member UID $ADV6_NONMEMBER_UID was able to read $ADV6_CATALOG — v2 group boundary broken"
  fi
  log "Adv-6 PASS: non-member UID $ADV6_NONMEMBER_UID denied, group member $TEST_OS_USER allowed"
fi

# Restore baseline state and re-run a normal share so the linear
# unisolate flow below operates against the expected snapshot.
restore_adv_snapshot
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "running bridge_migration_unisolate (dry_run=0) and verifying full ACL strip"
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_migration_unisolate "$TEST_AGENT" 0 \
  || die "bridge_migration_unisolate failed"

log "verifying every controller-side u:${TEST_OS_USER} ACL is gone"
for path in \
  "$declared_path" \
  "$declared_path/server.ts" \
  "$CONTROLLER_PLUGINS/known_marketplaces.json" \
  "$CONTROLLER_PLUGINS/install-counts-cache.json" \
  "$CONTROLLER_PLUGINS/blocklist.json"; do
  [[ -e "$path" ]] || continue
  count="$(sudo -n getfacl --no-effective "$path" 2>/dev/null \
    | grep -cE "^user:${TEST_OS_USER}:" || true)"
  [[ "$count" == "0" ]] \
    || die "post-unisolate u:${TEST_OS_USER} ACL still present on $path ($count entr(ies))"
done

log "verifying legacy \$BRIDGE_HOME/plugins ACL strip leaves no u:${TEST_OS_USER} residue"
residue="$(sudo -n getfacl --no-effective -R "$BRIDGE_HOME/plugins" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$residue" == "0" ]] \
  || die "legacy \$BRIDGE_HOME/plugins still has $residue u:${TEST_OS_USER} ACL entr(ies)"

log "verifying isolated-side cleanup removed catalog symlinks + per-UID manifest"
for catalog in known_marketplaces.json install-counts-cache.json blocklist.json installed_plugins.json; do
  link="$ISOLATED_PLUGINS/$catalog"
  if sudo -n test -e "$link" 2>/dev/null || sudo -n test -L "$link" 2>/dev/null; then
    die "post-unisolate $link still exists; expected isolated-side cleanup to remove it"
  fi
done

log "verifying persisted grant-set state file was removed"
if sudo -n test -e "$state_file" 2>/dev/null; then
  die "post-unisolate $state_file still exists; expected grant-set teardown"
fi

log "isolation plugin sharing test passed"
