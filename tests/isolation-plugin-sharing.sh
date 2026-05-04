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
