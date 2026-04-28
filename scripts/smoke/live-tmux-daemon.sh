#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="live-tmux-daemon"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

LIVE_SESSION=""

tmux_target() {
  printf '=%s' "$1"
}

cleanup() {
  if [[ -n "$LIVE_SESSION" ]]; then
    tmux kill-session -t "$(tmux_target "$LIVE_SESSION")" >/dev/null 2>&1 || true
  fi
  env BRIDGE_HOME="${BRIDGE_HOME:-}" bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

wait_for_session() {
  local session="$1"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if tmux has-session -t "$(tmux_target "$session")" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  smoke_fail "live tmux launch: expected session '$session' to exist after bridge-start"
}

write_live_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/live-agent"
  LIVE_SESSION="live-smoke-$RANDOM-$$"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="live-agent"
bridge_add_agent_id_if_missing "live-agent"
BRIDGE_AGENT_DESC["live-agent"]="Live tmux daemon smoke"
BRIDGE_AGENT_ENGINE["live-agent"]="shell"
BRIDGE_AGENT_SESSION["live-agent"]="$LIVE_SESSION"
BRIDGE_AGENT_WORKDIR["live-agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["live-agent"]="bash -lc 'while true; do sleep 1; done'"
BRIDGE_AGENT_LOOP["live-agent"]=1
BRIDGE_AGENT_CONTINUE["live-agent"]=0
EOF
}

live_launch_sync_and_stop() {
  local status_out

  bash "$SMOKE_REPO_ROOT/bridge-start.sh" live-agent --no-attach >/dev/null
  wait_for_session "$LIVE_SESSION"

  bash "$SMOKE_REPO_ROOT/bridge-sync.sh" >/dev/null
  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" --skip-plugin-liveness sync >/dev/null

  status_out="$("$SMOKE_REPO_ROOT/agent-bridge" status)"
  smoke_assert_contains "$status_out" "live-agent" "live daemon status includes launched agent"
  smoke_assert_contains "$status_out" "live-smoke" "live daemon status includes tmux session name"

  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" stop --force >/dev/null
}

main() {
  smoke_require_cmd tmux
  smoke_require_cmd python3
  smoke_setup_bridge_home "live-tmux-daemon"
  write_live_roster
  smoke_run "bridge-start live tmux session plus daemon sync" live_launch_sync_and_stop
  smoke_log "passed"
}

main "$@"
