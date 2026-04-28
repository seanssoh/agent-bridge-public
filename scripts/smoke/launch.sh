#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="launch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

write_launch_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/launch-agent"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "launch-agent"
BRIDGE_AGENT_DESC["launch-agent"]="Launch static smoke"
BRIDGE_AGENT_ENGINE["launch-agent"]="shell"
BRIDGE_AGENT_SESSION["launch-agent"]="launch-smoke-session"
BRIDGE_AGENT_WORKDIR["launch-agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["launch-agent"]="bash -lc 'echo launch-agent'"
BRIDGE_AGENT_LOOP["launch-agent"]=0
BRIDGE_AGENT_CONTINUE["launch-agent"]=0
EOF
}

launch_dry_run_contract() {
  local start_out run_out list_out

  list_out="$(bash "$SMOKE_REPO_ROOT/bridge-start.sh" --list)"
  smoke_assert_contains "$list_out" "launch-agent" "bridge-start --list includes smoke agent"

  start_out="$(bash "$SMOKE_REPO_ROOT/bridge-start.sh" launch-agent --dry-run)"
  smoke_assert_contains "$start_out" "agent=launch-agent" "bridge-start dry-run agent"
  smoke_assert_contains "$start_out" "session=launch-smoke-session" "bridge-start dry-run session"
  smoke_assert_contains "$start_out" "tmux_command=" "bridge-start dry-run tmux command"
  smoke_assert_contains "$start_out" "bridge-run.sh launch-agent --no-continue --once" "bridge-start dry-run run command"

  run_out="$(bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-agent --dry-run)"
  smoke_assert_contains "$run_out" "agent=launch-agent" "bridge-run dry-run agent"
  smoke_assert_contains "$run_out" "engine=shell" "bridge-run dry-run engine"
  smoke_assert_contains "$run_out" "launch=bash -lc 'echo launch-agent'" "bridge-run dry-run launch command"
}

main() {
  smoke_setup_bridge_home "launch"
  write_launch_roster
  smoke_run "bridge-start/bridge-run dry-run launch contract" launch_dry_run_contract
  smoke_log "passed"
}

main "$@"
