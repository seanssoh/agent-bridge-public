#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1060-layout-fresh-v2-static-claude.sh — Issue #1060 D5 smoke 1.
#
# Pins the #1060 three-layer agent-layout contract for a fresh v2 static
# Claude agent: after the scaffold + materialization step,
#
#   * `bridge_layout_agent_home` (identity source, layer 2) holds the
#     authored canonical identity (CLAUDE.md + SOUL/MEMORY/SESSION-TYPE),
#   * the engine materialization target (the workspace `workdir/`, layer
#     3, which the runtime reads + launches in — `bridge_agent_workdir`)
#     is POPULATED with the same current identity (not the empty/stale
#     sibling that caused the #1046/#1060 re-onboarding loop),
#   * the onboarding-state file (`SESSION-TYPE.md`) agrees between the
#     two trees — both say `complete` for a static-claude create,
#   * `agent_home` and `workdir` are distinct paths on a v2 install.
#
# The smoke drives `bridge_scaffold_agent_home` (into the identity
# source) + `bridge_layout_materialize_identity` directly rather than the
# full `bridge-agent.sh create` wrapper: that wrapper exercises channel
# setup / hooks / bridge-start dry-run, which have platform-dependent
# hangs / sudo prompts on a fresh BRIDGE_HOME and would mask the specific
# layer contract this smoke pins (same rationale as
# v2-scaffold-home-and-workdir.sh). `bridge_render_template_string` is
# kept REAL here (unlike #686's smoke) — smoke 1 must verify the
# materialized files have real identity content, so the template loop
# runs and emits CLAUDE.md / SESSION-TYPE.md with the onboarding state.
#
# Footgun #11: the driver is emitted via printf-to-file (no heredoc-stdin
# into a subprocess, no `<<<`, no `< <(...)`).
#
# Regression bite: FAILS if a future change reverts the D1 inversion so
# `agent create` scaffolds straight into `workdir/` without authoring the
# identity source, or drops the materialization step so the workspace
# read target comes up empty.

set -uo pipefail

SMOKE_NAME="1060-layout-fresh-v2-static-claude"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Emit a driver that sources the full bridge-lib.sh (so the layout
# resolver + engine descriptor + scaffold are all wired the same way the
# live runtime wires them), scaffolds into the identity source, runs the
# materialization step, then prints the resulting layer paths + key file
# states for the assertions below.
DRIVER_DIR="$SMOKE_TMP_ROOT/driver"
mkdir -p "$DRIVER_DIR"
DRIVER="$DRIVER_DIR/driver.sh"

write_driver() {
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
    '  sed -n "385,640p" "$REPO_ROOT/bridge-agent.sh"' \
    '} > "$FUNC_TMP"' \
    'source "$FUNC_TMP"' \
    'declare -F bridge_scaffold_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: scaffold not loaded"; exit 91; }' \
    'declare -F bridge_layout_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: layout resolver not loaded"; exit 92; }' \
    'declare -F bridge_layout_materialize_identity >/dev/null 2>&1 || { echo "DRIVER_FAIL: materialize not loaded"; exit 93; }' \
    'declare -F bridge_engine_materialization_target >/dev/null 2>&1 || { echo "DRIVER_FAIL: engine descriptor not loaded"; exit 94; }' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'IDENTITY_HOME="$(bridge_layout_agent_home "$AGENT_ID")"' \
    'WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/workdir"' \
    'echo "IDENTITY_HOME: $IDENTITY_HOME"' \
    'echo "WORKSPACE_DIR: $WORKSPACE_DIR"' \
    'echo "=== scaffold (into identity source) ==="' \
    'bridge_scaffold_agent_home "$AGENT_ID" "$IDENTITY_HOME" "Probe Agent" "probe role" claude static-claude "" ""' \
    'echo "=== materialize (identity -> workspace) ==="' \
    'bridge_layout_materialize_identity "$AGENT_ID" claude "$WORKSPACE_DIR"' \
    'echo "=== done ==="' \
    'if [[ -f "$IDENTITY_HOME/CLAUDE.md" ]]; then echo "IDENTITY_CLAUDE_MD: present"; else echo "IDENTITY_CLAUDE_MD: missing"; fi' \
    'if [[ -f "$IDENTITY_HOME/SOUL.md" ]]; then echo "IDENTITY_SOUL_MD: present"; else echo "IDENTITY_SOUL_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/CLAUDE.md" ]]; then echo "WORKSPACE_CLAUDE_MD: present"; else echo "WORKSPACE_CLAUDE_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/SOUL.md" ]]; then echo "WORKSPACE_SOUL_MD: present"; else echo "WORKSPACE_SOUL_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/SESSION-TYPE.md" ]]; then echo "WORKSPACE_SESSION_TYPE: present"; else echo "WORKSPACE_SESSION_TYPE: missing"; fi' \
    'id_state="$(grep -E "Onboarding State:" "$IDENTITY_HOME/SESSION-TYPE.md" 2>/dev/null | head -n1 | sed -E "s/.*Onboarding State:[[:space:]]*//")"' \
    'ws_state="$(grep -E "Onboarding State:" "$WORKSPACE_DIR/SESSION-TYPE.md" 2>/dev/null | head -n1 | sed -E "s/.*Onboarding State:[[:space:]]*//")"' \
    'echo "IDENTITY_ONBOARDING_STATE: $id_state"' \
    'echo "WORKSPACE_ONBOARDING_STATE: $ws_state"' \
    'mt="$(bridge_engine_materialization_target "$AGENT_ID" claude 2>/dev/null || true)"' \
    'echo "DESCRIPTOR_ENTRYPOINT: $(bridge_engine_entrypoint_filename claude)"' \
    'rm -f "$FUNC_TMP" >/dev/null 2>&1 || true'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

write_driver "$DRIVER"

AGENT_ID="probe-claude"

smoke_log "T1: fresh v2 static Claude — scaffold authors identity source, materialization populates workspace"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
  AGENT_ID="$AGENT_ID" \
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
  "$BRIDGE_BASH" "$DRIVER" 2>&1
)"
RC=$?

if [[ $RC -ne 0 ]]; then
  smoke_fail "driver exited rc=$RC. output:
$OUT"
fi

IDENTITY_HOME="$(extract_line "$OUT" "IDENTITY_HOME")"
WORKSPACE_DIR="$(extract_line "$OUT" "WORKSPACE_DIR")"

# Three-layer model: identity source and workspace must be distinct paths.
if [[ "$IDENTITY_HOME" == "$WORKSPACE_DIR" ]]; then
  smoke_fail "T1: identity source and workspace must be distinct on a v2 install; both resolved to '$IDENTITY_HOME'"
fi
smoke_assert_match "$IDENTITY_HOME" '/home$' "T1: identity source resolves to <agent-root>/home"
smoke_assert_match "$WORKSPACE_DIR" '/workdir$' "T1: workspace resolves to <agent-root>/workdir"

# The identity source holds the authored identity.
smoke_assert_eq "present" "$(extract_line "$OUT" "IDENTITY_CLAUDE_MD")" \
  "T1: identity source holds the authored CLAUDE.md"
smoke_assert_eq "present" "$(extract_line "$OUT" "IDENTITY_SOUL_MD")" \
  "T1: identity source holds the authored SOUL.md"

# The materialization target (workspace) is POPULATED — the #1046/#1060
# bug was an empty/stale workspace sibling.
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_CLAUDE_MD")" \
  "T1: workspace read target is populated with CLAUDE.md (no empty-sibling re-onboarding loop)"
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_SOUL_MD")" \
  "T1: workspace read target is populated with SOUL.md"
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_SESSION_TYPE")" \
  "T1: workspace read target is populated with SESSION-TYPE.md"

# Onboarding state agrees between identity source and workspace — the
# divergence was the literal #1060 re-onboarding-loop root cause.
ID_STATE="$(extract_line "$OUT" "IDENTITY_ONBOARDING_STATE")"
WS_STATE="$(extract_line "$OUT" "WORKSPACE_ONBOARDING_STATE")"
smoke_assert_eq "complete" "$ID_STATE" \
  "T1: identity source SESSION-TYPE.md onboarding state is complete (static-claude)"
smoke_assert_eq "complete" "$WS_STATE" \
  "T1: workspace SESSION-TYPE.md onboarding state agrees (complete) — no re-onboarding loop"

# The engine descriptor names CLAUDE.md as the Claude entrypoint.
smoke_assert_eq "CLAUDE.md" "$(extract_line "$OUT" "DESCRIPTOR_ENTRYPOINT")" \
  "T1: engine descriptor resolves CLAUDE.md as the Claude instruction entrypoint"

smoke_log "all tests PASS — issue #1060 D5 smoke 1: fresh v2 static Claude three-layer agreement verified"
