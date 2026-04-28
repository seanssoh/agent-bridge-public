#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="hooks"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

codex_hooks_contract() {
  local hooks_file ensure_out status_out payload

  hooks_file="$SMOKE_TMP_ROOT/codex-home/.codex/hooks.json"
  ensure_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)" \
      --codex-hooks-file "$hooks_file"
  )"
  smoke_assert_contains "$ensure_out" "hooks_file:" "codex hook ensure output"
  smoke_assert_file_exists "$hooks_file" "codex hooks file"

  payload="$(cat "$hooks_file")"
  smoke_assert_contains "$payload" "\"SessionStart\"" "codex hooks include SessionStart"
  smoke_assert_contains "$payload" "session-start.py --format codex" "codex hooks launch session-start helper"

  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-codex-hooks --codex-hooks-file "$hooks_file")"
  smoke_assert_contains "$status_out" "ok" "codex hook status"
}

claude_hooks_contract() {
  local workdir status_out payload

  workdir="$SMOKE_TMP_ROOT/claude-workdir"
  mkdir -p "$workdir"

  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-session-start-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --python-bin "$(command -v python3)" >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-stop-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bash-bin bash >/dev/null
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-prompt-hook \
    --workdir "$workdir" \
    --bridge-home "$BRIDGE_HOME" \
    --bash-bin bash \
    --python-bin "$(command -v python3)" >/dev/null

  payload="$(cat "$workdir/.claude/settings.json")"
  smoke_assert_contains "$payload" "\"SessionStart\"" "Claude settings include SessionStart hook"
  smoke_assert_contains "$payload" "session-start.py" "Claude SessionStart hook command"
  smoke_assert_contains "$payload" "mark-idle.sh" "Claude Stop hook command"
  smoke_assert_contains "$payload" "clear-idle.sh" "Claude prompt hook command"

  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
  smoke_assert_contains "$status_out" "ok" "Claude SessionStart hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude Stop hook status"
  status_out="$(python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
  smoke_assert_contains "$status_out" "ok" "Claude prompt hook status"
}

hook_runtime_helpers() {
  local hook_workdir prompt_output session_output

  prompt_output="$(BRIDGE_AGENT_ID=hook-agent BRIDGE_HOME="$BRIDGE_HOME" python3 "$SMOKE_REPO_ROOT/hooks/prompt_timestamp.py")"
  smoke_assert_contains "$prompt_output" "hook-agent" "prompt timestamp helper includes agent id"

  hook_workdir="$BRIDGE_AGENT_HOME_ROOT/hook-agent"
  mkdir -p "$hook_workdir"
  session_output="$(
    BRIDGE_AGENT_ID=hook-agent \
      BRIDGE_AGENT_WORKDIR="$hook_workdir" \
      BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
      BRIDGE_HOME="$BRIDGE_HOME" \
      python3 "$SMOKE_REPO_ROOT/hooks/session_start.py"
  )"
  smoke_assert_contains "$session_output" "Agent Bridge queue protocol applies to hook-agent" "session_start helper emits queue protocol context"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "hooks"
  smoke_run "Codex hooks ensure/status" codex_hooks_contract
  smoke_run "Claude hooks ensure/status" claude_hooks_contract
  smoke_run "hook runtime helper output" hook_runtime_helpers
  smoke_log "passed"
}

main "$@"
