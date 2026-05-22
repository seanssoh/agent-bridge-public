#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1060-layout-fresh-v2-static-codex.sh — Issue #1060 D5 smoke 2.
#
# Pins the #1060 three-layer agent-layout contract for a fresh v2 static
# Codex agent. The Codex engine differs from Claude in its instruction
# entrypoint and hook-config location, and the minimal engine descriptor
# (lib/bridge-engine-descriptor.sh) is the SOLE owner of that branching.
# This smoke asserts:
#
#   * the descriptor resolves `AGENTS.md` as the Codex instruction
#     entrypoint (vs `CLAUDE.md` for Claude),
#   * the descriptor flags a claude-compat copy for Codex (a CLAUDE.md
#     copy alongside AGENTS.md, because some bridge readers still probe
#     CLAUDE.md),
#   * the descriptor's Codex hook-config path is the per-agent
#     `.codex/hooks.json` under the IDENTITY SOURCE (agent_home) — NOT a
#     shared install-wide `$HOME/.codex/hooks.json`,
#   * the materialization step delivers the Codex agent's identity into
#     the descriptor-resolved materialization target (the workspace),
#     not into a shared project file.
#
# Full Codex *provisioning* (rendering AGENTS.md from a Codex template,
# wiring the SessionStart surface) is CODEX-PROV's job (#1067). This
# smoke's scope is the LAYOUT contract CODEX-PROV builds on: the
# descriptor resolves the right per-engine targets, and the
# materialization writes the authored identity there. CODEX-PROV extends
# this smoke when it lands.
#
# Footgun #11: driver emitted via printf-to-file, no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1060-layout-fresh-v2-static-codex"
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
    'declare -F bridge_engine_entrypoint_filename >/dev/null 2>&1 || { echo "DRIVER_FAIL: engine descriptor not loaded"; exit 91; }' \
    'declare -F bridge_layout_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: layout resolver not loaded"; exit 92; }' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_SOURCE 2>/dev/null || true' \
    'IDENTITY_HOME="$(bridge_layout_agent_home "$AGENT_ID")"' \
    'WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/workdir"' \
    '# Mirror the roster state a registered v2 static agent has so' \
    '# bridge_agent_workdir resolves the workspace `workdir/` anchor' \
    '# (its static-shared branch needs source=static + the workdir dir' \
    '# to exist + a default-home-shaped roster workdir — same setup the' \
    '# #686 v2-scaffold smoke documents).' \
    'mkdir -p "$WORKSPACE_DIR"' \
    'BRIDGE_AGENT_SOURCE["$AGENT_ID"]="static"' \
    'BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$IDENTITY_HOME"' \
    'echo "IDENTITY_HOME: $IDENTITY_HOME"' \
    'echo "WORKSPACE_DIR: $WORKSPACE_DIR"' \
    'echo "CODEX_ENTRYPOINT: $(bridge_engine_entrypoint_filename codex)"' \
    'echo "CLAUDE_ENTRYPOINT: $(bridge_engine_entrypoint_filename claude)"' \
    'if bridge_engine_wants_claude_compat_copy codex; then echo "CODEX_COMPAT_COPY: yes"; else echo "CODEX_COMPAT_COPY: no"; fi' \
    'if bridge_engine_wants_claude_compat_copy claude; then echo "CLAUDE_COMPAT_COPY: yes"; else echo "CLAUDE_COMPAT_COPY: no"; fi' \
    'echo "CODEX_HOOK_CONFIG: $(bridge_engine_hook_config_path "$AGENT_ID" codex 2>/dev/null || echo UNRESOLVED)"' \
    'echo "CODEX_HOOK_RENDERER: $(bridge_engine_hook_renderer_profile codex)"' \
    '# Author a minimal identity source by hand (CODEX-PROV owns the' \
    '# real Codex template render). The LAYOUT contract under test is' \
    '# that materialization delivers whatever the identity source holds' \
    '# into the descriptor-resolved target — not a shared project file.' \
    'mkdir -p "$IDENTITY_HOME"' \
    'printf "%s\n" "# probe-codex agent" > "$IDENTITY_HOME/AGENTS.md"' \
    'printf "%s\n" "# soul" > "$IDENTITY_HOME/SOUL.md"' \
    'MAT_TARGET="$(bridge_engine_materialization_target "$AGENT_ID" codex 2>/dev/null || echo UNRESOLVED)"' \
    'echo "CODEX_MATERIALIZATION_TARGET: $MAT_TARGET"' \
    'bridge_layout_materialize_identity "$AGENT_ID" codex "$WORKSPACE_DIR"' \
    'if [[ -f "$WORKSPACE_DIR/AGENTS.md" ]]; then echo "WORKSPACE_AGENTS_MD: present"; else echo "WORKSPACE_AGENTS_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/SOUL.md" ]]; then echo "WORKSPACE_SOUL_MD: present"; else echo "WORKSPACE_SOUL_MD: missing"; fi'
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

AGENT_ID="probe-codex"

smoke_log "T1: fresh v2 static Codex — descriptor resolves Codex targets, materialization delivers identity"

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

# Descriptor: per-engine entrypoint branching.
smoke_assert_eq "AGENTS.md" "$(extract_line "$OUT" "CODEX_ENTRYPOINT")" \
  "T1: descriptor resolves AGENTS.md as the Codex instruction entrypoint"
smoke_assert_eq "CLAUDE.md" "$(extract_line "$OUT" "CLAUDE_ENTRYPOINT")" \
  "T1: descriptor resolves CLAUDE.md as the Claude instruction entrypoint"

# Descriptor: claude-compat copy is Codex-only.
smoke_assert_eq "yes" "$(extract_line "$OUT" "CODEX_COMPAT_COPY")" \
  "T1: descriptor flags a claude-compat CLAUDE.md copy for Codex"
smoke_assert_eq "no" "$(extract_line "$OUT" "CLAUDE_COMPAT_COPY")" \
  "T1: descriptor does not flag a compat copy for Claude (its entrypoint IS CLAUDE.md)"

# Descriptor: Codex hook config is per-agent under the identity source.
CODEX_HOOK="$(extract_line "$OUT" "CODEX_HOOK_CONFIG")"
if [[ "$CODEX_HOOK" != "$IDENTITY_HOME/.codex/hooks.json" ]]; then
  smoke_fail "T1: descriptor must resolve the Codex hook config to the per-agent identity source; expected '$IDENTITY_HOME/.codex/hooks.json', got '$CODEX_HOOK'"
fi
smoke_assert_eq "codex" "$(extract_line "$OUT" "CODEX_HOOK_RENDERER")" \
  "T1: descriptor resolves the codex hook renderer profile for Codex"

# Materialization: target is the workspace, and the identity is delivered there.
smoke_assert_eq "$WORKSPACE_DIR" "$(extract_line "$OUT" "CODEX_MATERIALIZATION_TARGET")" \
  "T1: descriptor resolves the Codex materialization target to the workspace dir"
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_AGENTS_MD")" \
  "T1: materialization delivered the Codex AGENTS.md into the descriptor-resolved target"
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_SOUL_MD")" \
  "T1: materialization delivered the authored SOUL.md into the descriptor-resolved target"

smoke_log "all tests PASS — issue #1060 D5 smoke 2: fresh v2 static Codex descriptor + materialization verified"
