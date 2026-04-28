#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="integration-minimal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

write_integration_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/integration-agent"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="integration-agent"
bridge_add_agent_id_if_missing "integration-agent"
BRIDGE_AGENT_DESC["integration-agent"]="Integration smoke"
BRIDGE_AGENT_ENGINE["integration-agent"]="shell"
BRIDGE_AGENT_SESSION["integration-agent"]="integration-smoke-session"
BRIDGE_AGENT_WORKDIR["integration-agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["integration-agent"]="bash -lc 'echo integration-agent'"
BRIDGE_AGENT_LOOP["integration-agent"]=0
BRIDGE_AGENT_CONTINUE["integration-agent"]=0
EOF
}

queue_cli_wrappers_and_daemon_sync() {
  local task_out task_id inbox_out status_out

  task_out="$(
    bash "$SMOKE_REPO_ROOT/bridge-task.sh" create \
      --to integration-agent \
      --from integration-agent \
      --title "integration smoke task" \
      --body "integration body"
  )"
  smoke_assert_contains "$task_out" "created task #" "bridge-task create output"
  task_id="$(printf '%s\n' "$task_out" | sed -n 's/.*created task #\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  smoke_assert_match "$task_id" '^[0-9]+$' "bridge-task create task id"

  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox integration-agent)"
  smoke_assert_contains "$inbox_out" "integration smoke task" "agent-bridge inbox sees wrapper-created task"

  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" --skip-plugin-liveness sync >/dev/null
  status_out="$("$SMOKE_REPO_ROOT/agent-bridge" status)"
  smoke_assert_contains "$status_out" "integration-agent" "agent-bridge status includes integration agent"

  bash "$SMOKE_REPO_ROOT/bridge-task.sh" claim "$task_id" --agent integration-agent >/dev/null
  bash "$SMOKE_REPO_ROOT/bridge-task.sh" done "$task_id" --agent integration-agent --note "integration complete" >/dev/null
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox integration-agent)"
  smoke_assert_not_contains "$inbox_out" "integration smoke task" "completed integration task leaves default inbox"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "integration-minimal"
  write_integration_roster
  smoke_run "queue wrappers plus daemon sync/status" queue_cli_wrappers_and_daemon_sync
  smoke_log "passed"
}

main "$@"
