#!/usr/bin/env bash
# scripts/smoke/v2-scaffold-home-and-workdir.sh — Issue #686 regression smoke.
#
# Pins the v2 layout contract: `bridge_scaffold_agent_home` must
# materialize BOTH `<agent-root>/home/` (the agent's HOME) AND its sibling
# `<agent-root>/workdir/` (the resolver target returned by
# `bridge_agent_workdir`). Issue #686 (v0.8.5 cycle) reported that
# scaffold only created `home/`, so `bridge-start.sh --dry-run` (and any
# resolver-relative tooling — doctor/status/start) bombed with
# `workdir가 없습니다` on every fresh v2 install.
#
# The fix landed in PR #685; this smoke locks it in so a future refactor
# of `bridge_scaffold_agent_home` cannot silently regress the sibling
# mkdir. Coverage:
#
#   T1 — non-isolated v2 scaffold creates BOTH `home/` and `workdir/`
#        siblings under `$BRIDGE_AGENT_ROOT_V2/<agent>/`.
#   T2 — resolver agreement: `bridge_agent_workdir <agent>` returns the
#        same `<agent-root>/workdir` path that scaffold materialized, and
#        that path is a directory on disk (= no `workdir가 없습니다`).
#
# Scope note: v0.8.0+ requires the v2 isolation layout; bridge-lib.sh
# refuses to load with `BRIDGE_LAYOUT=legacy`, so the legacy-fallback
# code path inside `bridge_scaffold_agent_home` is unreachable in any
# current install and is intentionally not covered here.
#
# The smoke drives `bridge_scaffold_agent_home` directly rather than
# going through `bridge-agent.sh create` end-to-end: that wrapper exercises
# many adjacent paths (channel setup, sync_skill_docs, bridge-start dry-run)
# that have their own platform-dependent hangs / sudo prompts on a fresh
# `BRIDGE_HOME` and would mask the specific mkdir contract this smoke is
# trying to pin. `bridge_render_template_string` is stubbed to a no-op for
# the same reason — the unit under test is the v2 sibling mkdir at
# `bridge-agent.sh:547-550` (non-isolated branch), not template rendering.
#
# Regression bite: this smoke FAILS if line 548-550 of bridge-agent.sh
# (the `if [[ -n "$_scaffold_v2_workdir" ]]; then mkdir -p ...; fi`
# block in the non-isolated branch) is reverted, because T1 will observe
# `<agent-root>/workdir/` missing.

set -uo pipefail

SMOKE_NAME="v2-scaffold-home-and-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Build a driver script that:
#   1. exports the same v2 env the live runtime would have,
#   2. sources bridge-lib.sh,
#   3. extracts and sources just `bridge_scaffold_agent_home` (line
#      385..613) + its small `bridge_agent_manage_python` /
#      `bridge_render_template_string` deps from `bridge-agent.sh`,
#   4. stubs `bridge_render_template_string` to a no-op so the template
#      loop does not depend on session-template lookup / python3 / etc.,
#   5. calls scaffold and asserts on the resulting tree.
#
# Driver is emitted via printf-to-file (no heredocs) to stay clear of the
# Bash 5.3.9 heredoc-stdin deadlock class (footgun #11).
write_driver_script() {
  local out="$1"

  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'SCRIPT_DIR="$REPO_ROOT"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'FUNC_TMP="$DRIVER_TMP_DIR/scaffold-funcs.sh"' \
    '{' \
    '  sed -n "128,139p" "$REPO_ROOT/bridge-agent.sh"' \
    '  sed -n "188,257p" "$REPO_ROOT/bridge-agent.sh"' \
    '  sed -n "385,613p" "$REPO_ROOT/bridge-agent.sh"' \
    '} > "$FUNC_TMP"' \
    'source "$FUNC_TMP"' \
    'declare -F bridge_scaffold_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_scaffold_agent_home not loaded"; exit 91; }' \
    '# Stub template renderer to a no-op so scaffold returns immediately' \
    '# after the mkdirs (the unit under test). The template loop still' \
    '# touches the filesystem (creating empty target files) but does not' \
    '# depend on the bundled session-template tree.' \
    'bridge_render_template_string() { :; }' \
    'export -f bridge_render_template_string 2>/dev/null || true' \
    'HOME_DIR="$AGENT_HOME_DIR"' \
    'echo "=== scaffold start ==="' \
    'bridge_scaffold_agent_home "$AGENT_ID" "$HOME_DIR" "Probe Agent" "test role" claude static-claude' \
    'echo "=== scaffold end ==="' \
    'echo "AGENT_ROOT_LISTING:"' \
    'ls -1 "$(dirname "$HOME_DIR")" 2>&1 | sed "s/^/  /"' \
    'echo "RESOLVER_OUTPUT:"' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'resolved="$(bridge_agent_workdir "$AGENT_ID" 2>&1)"' \
    'echo "  $resolved"' \
    'if [[ -d "$HOME_DIR" ]]; then echo "HOME_DIR_STATUS: dir"; else echo "HOME_DIR_STATUS: missing"; fi' \
    'sibling_workdir="$(dirname "$HOME_DIR")/workdir"' \
    'if [[ -d "$sibling_workdir" ]]; then echo "SIBLING_WORKDIR_STATUS: dir"; else echo "SIBLING_WORKDIR_STATUS: missing"; fi' \
    'if [[ "$resolved" == "$sibling_workdir" ]]; then echo "RESOLVER_MATCH: yes"; else echo "RESOLVER_MATCH: no"; fi' \
    'rm -f "$FUNC_TMP" >/dev/null 2>&1 || true'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# Pull a specific suffix from the driver's stdout. Tab-and-colon
# separated for easy grep.
extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

# --- T1 + T2: non-isolated v2 — both home/ and workdir/ created --------------

smoke_log "T1+T2: non-isolated v2 scaffold materializes BOTH home/ and workdir/"

T1_DRIVER_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DRIVER_DIR"
T1_DRIVER="$T1_DRIVER_DIR/driver.sh"
T1_AGENT_ID="probe-v2"
T1_HOME_DIR="$BRIDGE_AGENT_ROOT_V2/$T1_AGENT_ID/home"

write_driver_script "$T1_DRIVER"

T1_OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$T1_DRIVER_DIR" \
  AGENT_ID="$T1_AGENT_ID" \
  AGENT_HOME_DIR="$T1_HOME_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
  BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
  BRIDGE_SHARED_ROOT="$BRIDGE_SHARED_ROOT" \
  BRIDGE_AGENT_ROOT_V2="$BRIDGE_AGENT_ROOT_V2" \
  BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_CONTROLLER_STATE_ROOT" \
  BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
  BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  "$BRIDGE_BASH" "$T1_DRIVER" 2>&1
)"
T1_RC=$?

if [[ $T1_RC -ne 0 ]]; then
  smoke_fail "T1 driver exited rc=$T1_RC. output:
$T1_OUT"
fi

T1_HOME_STATUS="$(extract_line "$T1_OUT" "HOME_DIR_STATUS")"
T1_SIBLING_STATUS="$(extract_line "$T1_OUT" "SIBLING_WORKDIR_STATUS")"
T1_RESOLVER_MATCH="$(extract_line "$T1_OUT" "RESOLVER_MATCH")"
T1_RESOLVED="$(printf '%s\n' "$T1_OUT" | awk '/^RESOLVER_OUTPUT:/{getline; sub(/^  /,""); print; exit}')"

smoke_assert_eq "dir" "$T1_HOME_STATUS" "T1: home/ directory was created"
smoke_assert_eq "dir" "$T1_SIBLING_STATUS" "T1: workdir/ sibling was created (issue #686 fix)"
smoke_assert_eq "yes" "$T1_RESOLVER_MATCH" "T2: bridge_agent_workdir resolved to the sibling workdir/ that scaffold materialized"
# Belt-and-suspenders: the resolver output is exactly the path we expect.
smoke_assert_eq "$BRIDGE_AGENT_ROOT_V2/$T1_AGENT_ID/workdir" "$T1_RESOLVED" \
  "T2: resolver returns canonical v2 path (\$BRIDGE_AGENT_ROOT_V2/<agent>/workdir)"

smoke_log "T1+T2 PASS — issue #686 fix verified at current main"
