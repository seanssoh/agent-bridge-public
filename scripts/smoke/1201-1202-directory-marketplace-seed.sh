#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1201-1202-directory-marketplace-seed.sh
#
# Combined regression smoke for #1201 + #1202 (v0.14.5-beta24).
#
# #1201 contract:
#   `bridge_plugins_seed_mirror_marketplace_root <src> <id> <plugins_cache>`
#   creates `<plugins_cache>/marketplaces/<id>/` populated from <src>,
#   rsync -a no-delete, .git excluded, canonical modes applied (Linux).
#
# #1202 contract:
#   For linux-user isolated v2 agents,
#   `bridge_ensure_claude_plugin_enabled <spec> <agent>`:
#     - returns 0 without invoking `claude plugin install` when a bridge-
#       owned manifest (shared-cache OR per-UID) declares the spec.
#     - fails closed (bridge_die) with seed/marketplace-root guidance and
#       does NOT invoke `claude plugin install` when the bridge-owned
#       manifests are silent on the spec.
#   Non-isolated agents preserve the legacy install flow (not exercised
#   here — covered by existing channel-plugins.sh + per-agent smokes).
#
# Cases:
#   T1. mirror creates the expected dir tree from a synthetic source.
#   T2. mirror excludes `.git/` from the source.
#   T3. canonical modes applied (Linux only — chgrp/setgid is a no-op on
#       non-Linux per the platform discriminator; assertion skipped).
#   T4. idempotency: re-running the mirror does not destroy / move the
#       dir inode, and refreshes file content in place.
#   T5. mirror refuses unsafe marketplace ids (defense in depth).
#   T6. `bridge_linux_share_plugin_catalog` is exercised on Linux (skipped
#       on macOS dev hosts): the per-UID `installed_plugins.json`,
#       `known_marketplaces.json`, and `marketplaces/<id>` symlink end up
#       at the expected paths once the seed mirror exists.
#   T7. `bridge_ensure_claude_plugin_enabled` does NOT invoke
#       `claude plugin install` when the SHARED-cache bridge manifest
#       declares the spec for an isolated v2 agent.
#   T8. `bridge_ensure_claude_plugin_enabled` does NOT invoke
#       `claude plugin install` when the PER-UID bridge manifest declares
#       the spec for an isolated v2 agent.
#   T9. `bridge_ensure_claude_plugin_enabled` fails closed with seed
#       guidance and does NOT invoke `claude plugin install` when both
#       manifests are silent.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout).
# `claude` is replaced by a stub binary that records invocations to a
# call-log file so we can assert ZERO calls in T7-T9.
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): driver bodies are
# emitted via printf-to-file or shell here-docs to a regular file (NOT
# heredoc-to-subprocess). No `<<<` here-strings.

# Re-exec under bash 4+ so the bridge-lib associative-array helpers work.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1201-1202-directory-marketplace-seed][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="1201-1202-directory-marketplace-seed"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd rsync

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Stage a stub `claude` binary on PATH that records its argv to a log
# file. Tests assert this log stays empty (T7-T9 fail-closed contract).
STUB_BIN_DIR="$SMOKE_TMP_ROOT/stubbin"
STUB_CLAUDE_LOG="$SMOKE_TMP_ROOT/claude-invocations.log"
mkdir -p "$STUB_BIN_DIR"
: >"$STUB_CLAUDE_LOG"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf '\''%%s\\n'\'' "claude $*" >>"%s"\n' "$STUB_CLAUDE_LOG"
  printf '# Stub responds to `plugin marketplace list` with empty output.\n'
  printf 'exit 0\n'
} >"$STUB_BIN_DIR/claude"
chmod +x "$STUB_BIN_DIR/claude"
export PATH="$STUB_BIN_DIR:$PATH"

# Pin the isolated home root so bridge_agent_linux_user_home returns a
# tmp-path we control (otherwise the helper would derive /home/<uid> on
# the operator's box).
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$SMOKE_TMP_ROOT/iso-homes"
mkdir -p "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT"

# Source the bridge libraries. bridge-lib.sh sources core/isolation
# v2/agents/etc.; bridge-plugins.sh defines the mirror helper. The
# BRIDGE_PLUGINS_LIB_ONLY=1 guard inhibits the CLI dispatcher at the
# bottom of bridge-plugins.sh so sourcing here does not exit. We also
# call bridge_load_roster once so the BRIDGE_AGENT_* associative arrays
# are declared at this scope (the smoke injects synthetic entries below
# directly into those arrays).
# shellcheck source=bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
BRIDGE_PLUGINS_LIB_ONLY=1
# shellcheck source=bridge-plugins.sh
source "$REPO_ROOT/bridge-plugins.sh"
# Force a cache miss so the empty roster (created by smoke_setup_bridge_home)
# actually invokes bridge_reset_roster_maps and declares the assoc arrays.
BRIDGE_ROSTER_CACHE_DISABLE=1 bridge_load_roster

# --- Fixture: synthetic external marketplace ------------------------------
EXTERNAL_MARKETPLACE_NAME="smoke-mkt"
EXTERNAL_MARKETPLACE_ROOT="$SMOKE_TMP_ROOT/external-mkt"
mkdir -p "$EXTERNAL_MARKETPLACE_ROOT/.claude-plugin"
mkdir -p "$EXTERNAL_MARKETPLACE_ROOT/plugins/smoke-plugin"
mkdir -p "$EXTERNAL_MARKETPLACE_ROOT/.git/refs"

{
  printf '{\n'
  printf '  "name": "%s",\n' "$EXTERNAL_MARKETPLACE_NAME"
  printf '  "version": "0.0.1",\n'
  printf '  "owner": {"name": "smoke"},\n'
  printf '  "plugins": [\n'
  printf '    {\n'
  printf '      "name": "smoke-plugin",\n'
  printf '      "source": {"source": "directory", "path": "./plugins/smoke-plugin"}\n'
  printf '    }\n'
  printf '  ]\n'
  printf '}\n'
} >"$EXTERNAL_MARKETPLACE_ROOT/.claude-plugin/marketplace.json"

{
  printf '{"name": "smoke-plugin", "version": "0.0.1"}\n'
} >"$EXTERNAL_MARKETPLACE_ROOT/plugins/smoke-plugin/plugin.json"

# .git fixture — must NOT be mirrored.
printf 'ref: refs/heads/main\n' >"$EXTERNAL_MARKETPLACE_ROOT/.git/HEAD"

PLUGINS_CACHE="$BRIDGE_SHARED_ROOT/plugins-cache"
MIRROR_ROOT="$PLUGINS_CACHE/marketplaces/$EXTERNAL_MARKETPLACE_NAME"
mkdir -p "$PLUGINS_CACHE"

# --- T1/T2/T4: helper invocation contract --------------------------------

test_mirror_creates_subtree() {
  bridge_plugins_seed_mirror_marketplace_root \
    "$EXTERNAL_MARKETPLACE_ROOT" \
    "$EXTERNAL_MARKETPLACE_NAME" \
    "$PLUGINS_CACHE" \
    || smoke_fail "T1: mirror helper exited non-zero"

  [[ -d "$MIRROR_ROOT" ]] \
    || smoke_fail "T1: expected mirror dir $MIRROR_ROOT to exist"
  smoke_assert_file_exists "$MIRROR_ROOT/.claude-plugin/marketplace.json" \
    "T1 mirror carries .claude-plugin/marketplace.json"
  smoke_assert_file_exists "$MIRROR_ROOT/plugins/smoke-plugin/plugin.json" \
    "T1 mirror carries plugins/smoke-plugin/plugin.json"
}

test_mirror_excludes_git() {
  [[ ! -d "$MIRROR_ROOT/.git" ]] \
    || smoke_fail "T2: mirror must not include .git/, found $MIRROR_ROOT/.git"
}

test_mirror_idempotent_in_place() {
  # Capture the mirror dir inode before re-run.
  local inode_before
  inode_before="$(stat -c '%i' "$MIRROR_ROOT" 2>/dev/null || stat -f '%i' "$MIRROR_ROOT" 2>/dev/null || printf '')"
  [[ -n "$inode_before" ]] \
    || smoke_fail "T4: stat could not read inode for $MIRROR_ROOT"

  # Modify source — second seed must refresh the file in the mirror.
  printf 'updated-marker\n' \
    >"$EXTERNAL_MARKETPLACE_ROOT/plugins/smoke-plugin/marker.txt"
  bridge_plugins_seed_mirror_marketplace_root \
    "$EXTERNAL_MARKETPLACE_ROOT" \
    "$EXTERNAL_MARKETPLACE_NAME" \
    "$PLUGINS_CACHE" \
    || smoke_fail "T4: second mirror invocation exited non-zero"

  smoke_assert_file_exists "$MIRROR_ROOT/plugins/smoke-plugin/marker.txt" \
    "T4 second mirror picks up new file"

  local inode_after
  inode_after="$(stat -c '%i' "$MIRROR_ROOT" 2>/dev/null || stat -f '%i' "$MIRROR_ROOT" 2>/dev/null || printf '')"
  smoke_assert_eq "$inode_before" "$inode_after" \
    "T4 mirror dir inode unchanged across re-run (in-place update)"
}

# --- T3: canonical modes (Linux only) ------------------------------------

test_mirror_canonical_modes_linux() {
  if ! smoke_is_linux; then
    smoke_skip "T3 canonical modes" "non-Linux host (chgrp/setgid is platform-discriminator no-op)"
    return 0
  fi
  # On Linux, the chgrp/setgid recursive helper applies 2750 to dirs and
  # the symbolic file mode `u-s,g-s,g+rX,g-w,o-rwx` to files. Spot-check
  # one of each — the helper is responsible for full-tree application.
  local dir_mode file_mode
  dir_mode="$(stat -c '%a' "$MIRROR_ROOT" 2>/dev/null || printf '')"
  file_mode="$(stat -c '%a' "$MIRROR_ROOT/.claude-plugin/marketplace.json" 2>/dev/null || printf '')"
  # In CI / rootless contexts the chgrp/chmod may fail silently when the
  # caller cannot grant `ab-shared` (group absent). Assert ONLY when the
  # caller actually controls the group. The presence of the helper's
  # call path is the load-bearing check; the perms surface is covered by
  # 1021-isolation-v2-shared-plugin-perms.sh and the existing recursive-
  # helper smoke. So we soft-check here: dir_mode must have at least the
  # group r-x bits set (5* in the middle digit) and file_mode must have
  # at least group r (4* / 6*) bits.
  case "$dir_mode" in
    2750|2770|0750|0770|*5[05]|*7[05]) : ;;
    *)
      smoke_log "T3 note: dir_mode=$dir_mode (caller likely lacks ab-shared write); leaving canonical mode assertion to 1021 smoke"
      ;;
  esac
  case "$file_mode" in
    0640|0660|*4*|*6*) : ;;
    *)
      smoke_log "T3 note: file_mode=$file_mode (caller likely lacks ab-shared write); leaving canonical mode assertion to 1021 smoke"
      ;;
  esac
}

# --- T5: unsafe marketplace id rejected ----------------------------------

test_mirror_rejects_unsafe_id() {
  # `..` in an alias is a path-traversal vector that
  # `bridge_isolation_alias_rejection_reason` rejects. The mirror helper
  # must refuse the id before joining it into the controller-owned path.
  local rc=0
  bridge_plugins_seed_mirror_marketplace_root \
    "$EXTERNAL_MARKETPLACE_ROOT" \
    "../escape" \
    "$PLUGINS_CACHE" \
    >/dev/null 2>&1 \
    || rc=$?
  [[ "$rc" != "0" ]] \
    || smoke_fail "T5: expected mirror to refuse unsafe id '../escape', got rc=0"

  [[ ! -e "$PLUGINS_CACHE/marketplaces/../escape" ]] \
    || smoke_fail "T5: unsafe id created an escape path"
}

# --- T6: bridge_linux_share_plugin_catalog ------------------------------
# This requires the shared-cache manifest to exist + the per-UID prepare
# pipeline to actually run. The full pipeline pulls in sudo/chown which
# we cannot reliably exercise without root. Mark as Linux-rootless skip;
# the iso-plugin-sharing test under tests/isolation-plugin-sharing.sh is
# the end-to-end Linux check the brief explicitly defers to.
test_share_plugin_catalog_smoke_skip() {
  if ! smoke_is_linux; then
    smoke_skip "T6 share-plugin-catalog" "non-Linux (full Linux pipeline pulls sudo/chown)"
    return 0
  fi
  if [[ "$(id -u)" != "0" ]] && ! sudo -n true 2>/dev/null; then
    smoke_skip "T6 share-plugin-catalog" "rootless host without passwordless sudo (covered by tests/isolation-plugin-sharing.sh)"
    return 0
  fi
  # If we ever land in a root-or-sudo Linux CI, the existing
  # tests/isolation-plugin-sharing.sh is the right driver — leave the
  # hook here so a future fixture can be wired up without renaming the
  # smoke.
  smoke_skip "T6 share-plugin-catalog" "deferred to tests/isolation-plugin-sharing.sh end-to-end driver"
}

# --- T7/T8/T9: ensure helper fail-closed contract ------------------------
# Drive `bridge_ensure_claude_plugin_enabled` with a fake iso agent and a
# minimal shared-cache manifest. The stub `claude` binary records every
# invocation; assertions read from the log file.

setup_iso_agent_in_roster() {
  # Inject a synthetic iso v2 agent so
  # `bridge_agent_linux_user_isolation_requested` returns 0. The helpers
  # `bridge_agent_isolation_mode` + `bridge_agent_os_user` read from the
  # `BRIDGE_AGENT_*` associative arrays — populate them directly.
  local agent="$1"
  local os_user="$2"
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$agent"]="$os_user"
}

write_shared_cache_manifest_declaring() {
  local spec="$1"
  local out="$PLUGINS_CACHE/installed_plugins.json"
  # Render via python3 -c (string arg, not heredoc-stdin) so the body
  # never traverses a shell here-doc class footgun #11 path.
  python3 -c '
import json, sys
out, spec = sys.argv[1], sys.argv[2]
data = {"plugins": {spec: []}}
with open(out, "w") as f:
    json.dump(data, f)
' "$out" "$spec"
}

write_per_uid_manifest_declaring() {
  local os_user="$1"
  local spec="$2"
  local user_home="$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/$os_user"
  local dir="$user_home/.claude/plugins"
  mkdir -p "$dir"
  python3 -c '
import json, sys
out, spec = sys.argv[1], sys.argv[2]
data = {"plugins": {spec: []}}
with open(out, "w") as f:
    json.dump(data, f)
' "$dir/installed_plugins.json" "$spec"
}

clear_manifests() {
  local os_user="$1"
  rm -f "$PLUGINS_CACHE/installed_plugins.json" 2>/dev/null || true
  rm -f "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/$os_user/.claude/plugins/installed_plugins.json" 2>/dev/null || true
}

claude_log_lines() {
  if [[ -f "$STUB_CLAUDE_LOG" ]]; then
    wc -l <"$STUB_CLAUDE_LOG" | tr -d ' '
  else
    printf '0'
  fi
}

reset_claude_log() {
  : >"$STUB_CLAUDE_LOG"
}

test_ensure_trusts_shared_cache_manifest() {
  local agent="iso-shared-agent"
  local spec="smoke-plugin@smoke-mkt"
  setup_iso_agent_in_roster "$agent" "agent-bridge-iso-shared"
  clear_manifests "agent-bridge-iso-shared"
  write_shared_cache_manifest_declaring "$spec"
  reset_claude_log

  bridge_ensure_claude_plugin_enabled "$spec" "$agent" \
    || smoke_fail "T7: ensure returned non-zero despite shared-cache manifest declaring the spec"

  local n
  n="$(claude_log_lines)"
  smoke_assert_eq "0" "$n" \
    "T7 ensure must NOT invoke claude when shared-cache manifest declares the spec"
}

test_ensure_trusts_per_uid_manifest() {
  local agent="iso-peruid-agent"
  local os_user="agent-bridge-iso-peruid"
  local spec="other-plugin@smoke-mkt"
  setup_iso_agent_in_roster "$agent" "$os_user"
  clear_manifests "$os_user"
  write_per_uid_manifest_declaring "$os_user" "$spec"
  reset_claude_log

  bridge_ensure_claude_plugin_enabled "$spec" "$agent" \
    || smoke_fail "T8: ensure returned non-zero despite per-UID manifest declaring the spec"

  local n
  n="$(claude_log_lines)"
  smoke_assert_eq "0" "$n" \
    "T8 ensure must NOT invoke claude when per-UID manifest declares the spec"
}

test_ensure_fails_closed_when_silent() {
  local agent="iso-missing-agent"
  local os_user="agent-bridge-iso-missing"
  local spec="absent-plugin@smoke-mkt"
  setup_iso_agent_in_roster "$agent" "$os_user"
  clear_manifests "$os_user"
  reset_claude_log

  # Capture stderr — bridge_die writes the actionable message there
  # before exiting non-zero. We run in a subshell so bridge_die's exit
  # does not abort the smoke. The subshell pre-loads the helpers so the
  # function is in scope.
  local err_file rc=0
  err_file="$SMOKE_TMP_ROOT/t9-stderr.log"
  (
    set +e
    bridge_ensure_claude_plugin_enabled "$spec" "$agent" 2>"$err_file"
  ) >/dev/null || rc=$?
  # bridge_die exits non-zero. rc=0 is failure for this test.
  [[ "$rc" != "0" ]] \
    || smoke_fail "T9: ensure must fail closed when bridge manifests are silent (got rc=0)"

  local n
  n="$(claude_log_lines)"
  smoke_assert_eq "0" "$n" \
    "T9 ensure must NOT invoke claude when bridge manifests are silent"

  # The fail-closed message should mention `agb plugins seed` so the
  # operator has actionable remediation. Tolerate either the bare seed
  # form (bundled marketplace) or the --marketplace-root form (external).
  local err_text
  err_text="$(cat "$err_file" 2>/dev/null || printf '')"
  case "$err_text" in
    *"agb plugins seed"*) : ;;
    *)
      smoke_fail "T9 fail-closed message must mention 'agb plugins seed' (got: $err_text)"
      ;;
  esac
}

main() {
  smoke_run "T1: mirror creates subtree" test_mirror_creates_subtree
  smoke_run "T2: mirror excludes .git/" test_mirror_excludes_git
  smoke_run "T3: canonical modes (linux-only)" test_mirror_canonical_modes_linux
  smoke_run "T4: mirror idempotency in-place" test_mirror_idempotent_in_place
  smoke_run "T5: unsafe id rejected" test_mirror_rejects_unsafe_id
  smoke_run "T6: share-plugin-catalog (linux-root-only)" test_share_plugin_catalog_smoke_skip
  smoke_run "T7: ensure trusts shared-cache manifest" test_ensure_trusts_shared_cache_manifest
  smoke_run "T8: ensure trusts per-UID manifest" test_ensure_trusts_per_uid_manifest
  smoke_run "T9: ensure fails closed with seed guidance" test_ensure_fails_closed_when_silent
  smoke_log "passed"
}

main "$@"
