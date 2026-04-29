#!/usr/bin/env bash
# bridge-status.sh — compact dashboard for queue and roster state

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
BRIDGE_FAST_ROSTER_LOAD=1
bridge_load_roster

usage() {
  cat <<EOF
Usage: bash $SCRIPT_DIR/bridge-status.sh [--watch] [--refresh <seconds>] [--open-limit <count>] [--all-agents] [--json]
EOF
}

WATCH_MODE=0
REFRESH_SECONDS=2
OPEN_LIMIT=8
ALL_AGENTS=0
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --watch|--tui)
      WATCH_MODE=1
      shift
      ;;
    --refresh)
      [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]] && bridge_die "--refresh 뒤에 숫자(초)를 지정하세요."
      REFRESH_SECONDS="$2"
      shift 2
      ;;
    --open-limit)
      [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]] && bridge_die "--open-limit 뒤에 숫자를 지정하세요."
      OPEN_LIMIT="$2"
      shift 2
      ;;
    --all-agents)
      ALL_AGENTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      bridge_die "알 수 없는 옵션: $1"
      ;;
  esac
done

render_once() {
  local roster_snapshot footer
  local -a status_args

  roster_snapshot="$(mktemp)"
  bridge_write_roster_status_snapshot "$roster_snapshot"
  footer="commands: agent-bridge list | agent-bridge summary | agent-bridge inbox <agent> | agent-bridge show <task-id>"
  if [[ $WATCH_MODE -eq 1 ]]; then
    footer+=" | Ctrl-C to exit"
  fi

  status_args=(
    --roster-snapshot "$roster_snapshot"
    --db "$BRIDGE_TASK_DB"
    --daemon-pid-file "$BRIDGE_DAEMON_PID_FILE"
    --bridge-state-dir "$BRIDGE_STATE_DIR"
    --audit-log "$BRIDGE_AUDIT_LOG"
    --version "$(bridge_version)"
    --open-limit "$OPEN_LIMIT"
    --stale-warn-seconds "$BRIDGE_HEALTH_WARN_SECONDS"
    --stale-critical-seconds "$BRIDGE_HEALTH_CRITICAL_SECONDS"
    --footer "$footer"
  )
  if [[ $ALL_AGENTS -eq 1 ]]; then
    status_args+=(--all-agents)
  fi
  if [[ $JSON_MODE -eq 1 ]]; then
    status_args+=(--json)
  fi

  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-status.py" "${status_args[@]}"
  rm -f "$roster_snapshot"
}

if [[ $WATCH_MODE -eq 1 && $JSON_MODE -eq 1 ]]; then
  bridge_die "--json cannot be combined with --watch"
fi

if [[ $WATCH_MODE -eq 1 ]]; then
  while true; do
    printf '\033[H\033[2J'
    render_once
    sleep "$REFRESH_SECONDS"
  done
else
  render_once
fi
