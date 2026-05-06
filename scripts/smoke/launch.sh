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
  local isolated_workdir="$BRIDGE_AGENT_HOME_ROOT/launch-isolated-agent"
  mkdir -p "$workdir" "$isolated_workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "launch-agent"
BRIDGE_AGENT_DESC["launch-agent"]="Launch static smoke"
BRIDGE_AGENT_ENGINE["launch-agent"]="shell"
BRIDGE_AGENT_SESSION["launch-agent"]="launch-smoke-session"
BRIDGE_AGENT_WORKDIR["launch-agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["launch-agent"]="bash -lc 'echo launch-agent'"
BRIDGE_AGENT_LOOP["launch-agent"]=0
BRIDGE_AGENT_CONTINUE["launch-agent"]=0

bridge_add_agent_id_if_missing "launch-isolated-agent"
BRIDGE_AGENT_DESC["launch-isolated-agent"]="Launch isolated umask smoke"
BRIDGE_AGENT_ENGINE["launch-isolated-agent"]="shell"
BRIDGE_AGENT_SESSION["launch-isolated-agent"]="launch-isolated-smoke-session"
BRIDGE_AGENT_WORKDIR["launch-isolated-agent"]="$isolated_workdir"
BRIDGE_AGENT_LAUNCH_CMD["launch-isolated-agent"]="bash -lc 'echo launch-isolated-agent'"
BRIDGE_AGENT_LOOP["launch-isolated-agent"]=0
BRIDGE_AGENT_CONTINUE["launch-isolated-agent"]=0
BRIDGE_AGENT_ISOLATION_MODE["launch-isolated-agent"]="linux-user"
BRIDGE_AGENT_OS_USER["launch-isolated-agent"]="agent-bridge-launch-smoke"
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

launch_umask_probe_contract() {
  local shared_probe isolated_probe v2_probe
  local shared_recorded isolated_recorded v2_recorded
  local v2_data_root

  shared_probe="$SMOKE_TMP_ROOT/launch-shared-umask.probe"
  isolated_probe="$SMOKE_TMP_ROOT/launch-isolated-legacy-umask.probe"
  v2_probe="$SMOKE_TMP_ROOT/launch-isolated-v2-umask.probe"
  v2_data_root="$SMOKE_TMP_ROOT/v2-data"
  mkdir -p "$v2_data_root/agents" "$v2_data_root/shared" "$v2_data_root/state"

  BRIDGE_LAYOUT=legacy \
  BRIDGE_DATA_ROOT= \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_RUN_UMASK_PROBE_FILE="$shared_probe" \
    bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-agent --dry-run >/dev/null
  shared_recorded="$(cat "$shared_probe" 2>/dev/null || true)"
  smoke_assert_eq "0077" "$shared_recorded" "legacy shared bridge-run umask remains private"

  BRIDGE_LAYOUT=legacy \
  BRIDGE_DATA_ROOT= \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_RUN_UMASK_PROBE_FILE="$isolated_probe" \
    bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-isolated-agent --dry-run >/dev/null
  isolated_recorded="$(cat "$isolated_probe" 2>/dev/null || true)"
  smoke_assert_eq "0007" "$isolated_recorded" "legacy linux-user bridge-run umask preserves ACL mask"

  BRIDGE_LAYOUT=v2 \
  BRIDGE_DATA_ROOT="$v2_data_root" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_RUN_UMASK_PROBE_FILE="$v2_probe" \
    bash "$SMOKE_REPO_ROOT/bridge-run.sh" launch-isolated-agent --dry-run >/dev/null
  v2_recorded="$(cat "$v2_probe" 2>/dev/null || true)"
  smoke_assert_eq "0007" "$v2_recorded" "v2 linux-user bridge-run umask remains 0007"
}

main() {
  smoke_setup_bridge_home "launch"
  write_launch_roster
  smoke_run "bridge-start/bridge-run dry-run launch contract" launch_dry_run_contract
  smoke_run "bridge-run linux-user umask probe contract" launch_umask_probe_contract
  smoke_log "passed"
}

main "$@"
