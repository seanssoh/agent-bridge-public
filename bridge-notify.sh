#!/usr/bin/env bash
# bridge-notify.sh — send short external channel notifications for bridge tasks

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-notify.sh send --agent <agent> [--title <title>] --message <text> [--task-id <id>] [--priority <priority>] [--dry-run]
  bash $SCRIPT_DIR/bridge-notify.sh send --kind <discord|telegram> --target <id> [--account <account>] [--title <title>] --message <text> [--task-id <id>] [--priority <priority>] [--dry-run]
EOF
}

cmd_send() {
  local agent=""
  local kind=""
  local target=""
  local account=""
  local title=""
  local message=""
  local task_id=""
  local priority="normal"
  local dry_run=0
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 값을 지정하세요."
        agent="$2"
        shift 2
        ;;
      --kind)
        [[ $# -lt 2 ]] && bridge_die "--kind 뒤에 값을 지정하세요."
        kind="$2"
        shift 2
        ;;
      --target)
        [[ $# -lt 2 ]] && bridge_die "--target 뒤에 값을 지정하세요."
        target="$2"
        shift 2
        ;;
      --account)
        [[ $# -lt 2 ]] && bridge_die "--account 뒤에 값을 지정하세요."
        account="$2"
        shift 2
        ;;
      --title)
        [[ $# -lt 2 ]] && bridge_die "--title 뒤에 값을 지정하세요."
        title="$2"
        shift 2
        ;;
      --message)
        [[ $# -lt 2 ]] && bridge_die "--message 뒤에 값을 지정하세요."
        message="$2"
        shift 2
        ;;
      --task-id)
        [[ $# -lt 2 ]] && bridge_die "--task-id 뒤에 값을 지정하세요."
        task_id="$2"
        shift 2
        ;;
      --priority)
        [[ $# -lt 2 ]] && bridge_die "--priority 뒤에 값을 지정하세요."
        priority="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
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

  [[ -n "$message" || -n "$title" ]] || bridge_die "--message 또는 --title 중 하나는 필요합니다."

  if [[ -n "$agent" ]]; then
    bridge_require_agent "$agent"
    if [[ -z "$kind" ]]; then
      kind="$(bridge_agent_notify_kind "$agent")"
    fi
    if [[ -z "$target" ]]; then
      target="$(bridge_agent_notify_target "$agent")"
    fi
    if [[ -z "$account" ]]; then
      account="$(bridge_agent_notify_account "$agent")"
    fi
  fi

  [[ -n "$kind" ]] || bridge_die "notify kind이 필요합니다."
  [[ -n "$target" ]] || bridge_die "notify target이 필요합니다."

  # #1996: bridge-notify.py has no teams sender (account-token HTTP only).
  # A teams-channel agent's notify_kind now resolves to teams, so a
  # bridge-notify.sh send (e.g. the question-escalation path in
  # bridge-escalate.sh, which omits --kind and lets it derive) must fail
  # closed with a clear message rather than hand `--kind teams` to
  # bridge-notify.py for a cryptic argparse rejection. Teams proactive push
  # is the managed-send adapter's job (bridge-channels.py send-managed-message).
  if [[ "$kind" == "teams" ]]; then
    bridge_warn "notify kind 'teams' routes through managed-send (PreCompact notify), not bridge-notify; skipping push."
    return 3
  fi

  args=(
    send
    --kind "$kind"
    --target "$target"
    --runtime-config "$(bridge_compat_config_file)"
    --priority "$priority"
  )
  if [[ -n "$agent" ]]; then
    args+=(--agent "$agent")
  fi
  if [[ -n "$account" ]]; then
    args+=(--account "$account")
  fi
  if [[ -n "$title" ]]; then
    args+=(--title "$title")
  fi
  if [[ -n "$message" ]]; then
    args+=(--message "$message")
  fi
  if [[ -n "$task_id" ]]; then
    args+=(--task-id "$task_id")
  fi
  if [[ $dry_run -eq 1 ]]; then
    args+=(--dry-run)
  fi

  bridge_notify_python "${args[@]}"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  send)
    cmd_send "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 notify 명령입니다: $subcommand"
    ;;
esac
