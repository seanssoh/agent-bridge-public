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
# Extended by CODEX-PROV (#1067, Batch 2) to also assert full provisioning:
#   * bridge_scaffold_codex_entrypoint places AGENTS.md in the identity
#     source after scaffold (S03),
#   * bridge-hooks.py ensure-codex-hooks renders the Codex hook surface at
#     the descriptor-owned per-agent path (S08),
#   * materialization delivers AGENTS.md into the workspace (S02 via D1).
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
    'declare -F bridge_scaffold_codex_entrypoint >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_scaffold_codex_entrypoint not loaded (#1067 CODEX-PROV)"; exit 93; }' \
    'declare -F bridge_ensure_codex_agent_hooks >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_ensure_codex_agent_hooks not loaded (#1067 CODEX-PROV)"; exit 94; }' \
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
    'CODEX_HOOK_CONFIG="$(bridge_engine_hook_config_path "$AGENT_ID" codex 2>/dev/null || echo UNRESOLVED)"' \
    'echo "CODEX_HOOK_CONFIG: $CODEX_HOOK_CONFIG"' \
    'echo "CODEX_HOOK_RENDERER: $(bridge_engine_hook_renderer_profile codex)"' \
    '# Author a template-shaped identity source: CLAUDE.md + common files.' \
    '# CODEX-PROV (#1067) adds AGENTS.md via bridge_scaffold_codex_entrypoint' \
    '# (S03) and renders hooks via bridge_ensure_codex_agent_hooks (S08).' \
    'mkdir -p "$IDENTITY_HOME"' \
    'printf "%s\n" "# probe-codex agent (claude-compat copy)" > "$IDENTITY_HOME/CLAUDE.md"' \
    'printf "%s\n" "# soul" > "$IDENTITY_HOME/SOUL.md"' \
    '# S03: bridge_scaffold_codex_entrypoint copies CLAUDE.md -> AGENTS.md in identity source.' \
    'bridge_scaffold_codex_entrypoint "$IDENTITY_HOME" codex 2>/dev/null || true' \
    'if [[ -f "$IDENTITY_HOME/AGENTS.md" ]]; then echo "IDENTITY_AGENTS_MD: present"; else echo "IDENTITY_AGENTS_MD: missing"; fi' \
    'MAT_TARGET="$(bridge_engine_materialization_target "$AGENT_ID" codex 2>/dev/null || echo UNRESOLVED)"' \
    'echo "CODEX_MATERIALIZATION_TARGET: $MAT_TARGET"' \
    '# Deliver identity into workspace (D1). AGENTS.md is present in identity_home now,' \
    '# so materialization will deliver it into the workspace (descriptor engine_entry).' \
    'bridge_layout_materialize_identity "$AGENT_ID" codex "$WORKSPACE_DIR"' \
    'if [[ -f "$WORKSPACE_DIR/AGENTS.md" ]]; then echo "WORKSPACE_AGENTS_MD: present"; else echo "WORKSPACE_AGENTS_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/CLAUDE.md" ]]; then echo "WORKSPACE_CLAUDE_MD: present"; else echo "WORKSPACE_CLAUDE_MD: missing"; fi' \
    'if [[ -f "$WORKSPACE_DIR/SOUL.md" ]]; then echo "WORKSPACE_SOUL_MD: present"; else echo "WORKSPACE_SOUL_MD: missing"; fi' \
    '# S08: bridge_ensure_codex_agent_hooks renders .codex/hooks.json at the descriptor path.' \
    'bridge_ensure_codex_agent_hooks "$AGENT_ID" "$IDENTITY_HOME" 2>/dev/null || true' \
    'if [[ -f "$CODEX_HOOK_CONFIG" ]]; then echo "CODEX_HOOKS_FILE: present"; else echo "CODEX_HOOKS_FILE: missing"; fi' \
    'if [[ -f "$CODEX_HOOK_CONFIG" ]] && grep -q "SessionStart" "$CODEX_HOOK_CONFIG" 2>/dev/null; then echo "CODEX_HOOKS_SESSION_START: present"; else echo "CODEX_HOOKS_SESSION_START: missing"; fi'
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

# S03 (CODEX-PROV #1067): AGENTS.md must be present in the identity source
# after bridge_scaffold_codex_entrypoint runs (copied from CLAUDE.md).
smoke_assert_eq "present" "$(extract_line "$OUT" "IDENTITY_AGENTS_MD")" \
  "T1: AGENTS.md present in identity source after bridge_scaffold_codex_entrypoint (S03, #1067)"

# S02 (via D1 materialization): AGENTS.md delivered into workspace once it
# exists in the identity source — CODEX-PROV + LAYOUT together close this gap.
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_AGENTS_MD")" \
  "T1: materialization delivered AGENTS.md into the Codex workspace (S02 via D1, #1067+#1060)"

# Codex r1 BLOCKING 2: descriptor flags Codex as wants_claude_compat_copy →
# materialization must deliver CLAUDE.md to the workspace as a Claude-shaped
# compat copy alongside the native AGENTS.md.
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_CLAUDE_MD")" \
  "T1: materialization delivered the CLAUDE.md compat copy into the Codex workspace (descriptor wants_claude_compat_copy)"
smoke_assert_eq "present" "$(extract_line "$OUT" "WORKSPACE_SOUL_MD")" \
  "T1: materialization delivered the authored SOUL.md into the descriptor-resolved target"

# S08 (CODEX-PROV #1067): Codex hook surface rendered at descriptor-owned path.
smoke_assert_eq "present" "$(extract_line "$OUT" "CODEX_HOOKS_FILE")" \
  "T1: Codex hooks.json rendered at descriptor-owned per-agent path (S08, #1067)"
smoke_assert_eq "present" "$(extract_line "$OUT" "CODEX_HOOKS_SESSION_START")" \
  "T1: Codex hooks.json contains SessionStart entry (S08, #1067)"

smoke_log "all tests PASS — issue #1060 D5 smoke 2 + #1067 CODEX-PROV: fresh v2 static Codex full provisioning verified"
