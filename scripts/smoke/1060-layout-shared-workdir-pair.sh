#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1060-layout-shared-workdir-pair.sh — Issue #1060 D5 smoke 3.
#
# Pins the #1060 shared-workspace rule. Two agents (an admin Claude + its
# Codex pair) share ONE workspace project tree (the `--allow-shared-workdir`
# case), but each must keep a DISTINCT identity / memory / hook context.
# This smoke asserts:
#
#   * the two agents resolve to the SAME workspace (layer 3) but DISTINCT
#     identity sources (layer 2 — `agent_home`) and DISTINCT memory dirs
#     (`bridge_layout_memory_dir` = `agent_home/memory`),
#   * the two agents resolve DISTINCT engine hook-config paths,
#   * `bridge_layout_materialize_identity` does NOT stamp per-agent
#     identity into the shared workspace — when the workspace is shared
#     (its CLAUDE.md/AGENTS.md flags it shared, or the
#     BRIDGE_LAYOUT_WORKSPACE_SHARED guard is set), per-agent identity
#     stays in `agent_home` and the shared project file is left
#     untouched.
#
# This is the rule that keeps a shared-workdir pair from clobbering each
# other's SOUL/SESSION-TYPE — the materialization step is workspace-aware,
# not a blind copy.
#
# Footgun #11: driver emitted via printf-to-file, no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1060-layout-shared-workdir-pair"
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
    'declare -F bridge_layout_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: layout resolver not loaded"; exit 91; }' \
    'declare -F bridge_layout_memory_dir >/dev/null 2>&1 || { echo "DRIVER_FAIL: memory resolver not loaded"; exit 92; }' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_SOURCE 2>/dev/null || true' \
    '# Two agents, one shared workspace project tree.' \
    'SHARED_WS="$BRIDGE_DATA_ROOT/shared-project"' \
    'mkdir -p "$SHARED_WS"' \
    '# Mark the shared workspace as a shared project tree so the' \
    '# materialization guard recognizes it.' \
    'printf "%s\n" "# shared project — shared-workdir pair" > "$SHARED_WS/CLAUDE.md"' \
    'BRIDGE_AGENT_SOURCE["$ADMIN_ID"]="static"' \
    'BRIDGE_AGENT_SOURCE["$CODEX_ID"]="static"' \
    'BRIDGE_AGENT_WORKDIR["$ADMIN_ID"]="$SHARED_WS"' \
    'BRIDGE_AGENT_WORKDIR["$CODEX_ID"]="$SHARED_WS"' \
    'ADMIN_HOME="$(bridge_layout_agent_home "$ADMIN_ID")"' \
    'CODEX_HOME="$(bridge_layout_agent_home "$CODEX_ID")"' \
    'ADMIN_WS="$(bridge_layout_workspace_dir "$ADMIN_ID")"' \
    'CODEX_WS="$(bridge_layout_workspace_dir "$CODEX_ID")"' \
    'ADMIN_MEM="$(bridge_layout_memory_dir "$ADMIN_ID")"' \
    'CODEX_MEM="$(bridge_layout_memory_dir "$CODEX_ID")"' \
    'ADMIN_HOOK="$(bridge_engine_hook_config_path "$ADMIN_ID" claude 2>/dev/null || echo UNRESOLVED)"' \
    'CODEX_HOOK="$(bridge_engine_hook_config_path "$CODEX_ID" codex 2>/dev/null || echo UNRESOLVED)"' \
    'echo "ADMIN_HOME: $ADMIN_HOME"' \
    'echo "CODEX_HOME: $CODEX_HOME"' \
    'echo "ADMIN_WS: $ADMIN_WS"' \
    'echo "CODEX_WS: $CODEX_WS"' \
    'echo "ADMIN_MEM: $ADMIN_MEM"' \
    'echo "CODEX_MEM: $CODEX_MEM"' \
    'echo "ADMIN_HOOK: $ADMIN_HOOK"' \
    'echo "CODEX_HOOK: $CODEX_HOOK"' \
    '# Author distinct identity sources for the pair.' \
    'mkdir -p "$ADMIN_HOME" "$CODEX_HOME"' \
    'printf "%s\n" "# admin soul" > "$ADMIN_HOME/SOUL.md"' \
    'printf "%s\n" "# codex soul" > "$CODEX_HOME/SOUL.md"' \
    'printf "%s\n" "# admin claude" > "$ADMIN_HOME/CLAUDE.md"' \
    '# Snapshot the shared workspace CLAUDE.md before materialization.' \
    'WS_BEFORE="$(cat "$SHARED_WS/CLAUDE.md")"' \
    'bridge_layout_materialize_identity "$ADMIN_ID" claude "$SHARED_WS"' \
    'bridge_layout_materialize_identity "$CODEX_ID" codex "$SHARED_WS"' \
    'WS_AFTER="$(cat "$SHARED_WS/CLAUDE.md")"' \
    'if [[ "$WS_BEFORE" == "$WS_AFTER" ]]; then echo "SHARED_WS_CLAUDE_UNTOUCHED: yes"; else echo "SHARED_WS_CLAUDE_UNTOUCHED: no"; fi' \
    'if [[ -f "$SHARED_WS/SOUL.md" ]]; then echo "SHARED_WS_HAS_SOUL: yes"; else echo "SHARED_WS_HAS_SOUL: no"; fi'
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

ADMIN_ID="probe_admin"
CODEX_ID="probe_admin_dev"

smoke_log "T1: shared-workdir admin+codex pair — distinct identity/memory/hooks, shared workspace untouched"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
  ADMIN_ID="$ADMIN_ID" \
  CODEX_ID="$CODEX_ID" \
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

ADMIN_HOME="$(extract_line "$OUT" "ADMIN_HOME")"
CODEX_HOME="$(extract_line "$OUT" "CODEX_HOME")"
ADMIN_WS="$(extract_line "$OUT" "ADMIN_WS")"
CODEX_WS="$(extract_line "$OUT" "CODEX_WS")"
ADMIN_MEM="$(extract_line "$OUT" "ADMIN_MEM")"
CODEX_MEM="$(extract_line "$OUT" "CODEX_MEM")"
ADMIN_HOOK="$(extract_line "$OUT" "ADMIN_HOOK")"
CODEX_HOOK="$(extract_line "$OUT" "CODEX_HOOK")"

# Same workspace.
smoke_assert_eq "$ADMIN_WS" "$CODEX_WS" \
  "T1: the pair shares ONE workspace project tree"

# Distinct identity sources.
if [[ "$ADMIN_HOME" == "$CODEX_HOME" ]]; then
  smoke_fail "T1: a shared-workdir pair must keep DISTINCT identity sources; both resolved to '$ADMIN_HOME'"
fi

# Distinct memory dirs, each under its own identity source.
if [[ "$ADMIN_MEM" == "$CODEX_MEM" ]]; then
  smoke_fail "T1: a shared-workdir pair must keep DISTINCT memory dirs; both resolved to '$ADMIN_MEM'"
fi
smoke_assert_eq "$ADMIN_HOME/memory" "$ADMIN_MEM" \
  "T1: admin memory dir is its identity source's memory/ (never inferred from the shared cwd)"
smoke_assert_eq "$CODEX_HOME/memory" "$CODEX_MEM" \
  "T1: codex memory dir is its identity source's memory/ (never inferred from the shared cwd)"

# Distinct hook-config paths.
if [[ "$ADMIN_HOOK" == "$CODEX_HOOK" ]]; then
  smoke_fail "T1: a shared-workdir pair must keep DISTINCT hook-config paths; both resolved to '$ADMIN_HOOK'"
fi

# The shared workspace project file is NOT stamped with per-agent identity.
smoke_assert_eq "yes" "$(extract_line "$OUT" "SHARED_WS_CLAUDE_UNTOUCHED")" \
  "T1: materialization left the shared workspace CLAUDE.md untouched (per-agent identity stays in agent_home)"
smoke_assert_eq "no" "$(extract_line "$OUT" "SHARED_WS_HAS_SOUL")" \
  "T1: materialization did not write a per-agent SOUL.md into the shared workspace"

smoke_log "all tests PASS — issue #1060 D5 smoke 3: shared-workdir pair isolation verified"
