#!/usr/bin/env bash
# bridge-send.sh — roster 기반 tmux 에이전트 메시지 전송

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-send.sh --urgent <agent> \"<message>\" [--wait <seconds>]"
  echo "       bash $SCRIPT_DIR/bridge-send.sh --list"
  echo "활성 로스터: $BRIDGE_ACTIVE_ROSTER_MD"
  echo ""
  echo "일반 작업 전달은 task queue를 사용하세요:"
  echo "  $BRIDGE_HOME/agent-bridge task create --to tester --title \"재테스트\" --body-file $BRIDGE_SHARED_DIR/report.md"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

infer_actor_if_possible() {
  local actor="${1:-}"

  if [[ -n "$actor" ]]; then
    printf '%s' "$actor"
    return 0
  fi

  if actor="$(bridge_infer_current_agent 2>/dev/null)"; then
    printf '%s' "$actor"
    return 0
  fi

  printf '%s' "${USER:-unknown}"
}

trim_line() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

urgent_task_title() {
  local message="$1"
  local first_line="${message%%$'\n'*}"
  local title=""

  title="$(trim_line "$(bridge_sanitize_text "${first_line//$'\r'/ }")")"
  if [[ -z "$title" ]]; then
    title="urgent task"
  fi
  if (( ${#title} > 120 )); then
    title="${title:0:117}..."
  fi
  printf '%s' "$title"
}

urgent_task_body() {
  local message="$1"
  local title="$2"
  local compact_message=""

  compact_message="$(trim_line "$(bridge_sanitize_text "$message")")"
  if [[ "$compact_message" == "$title" && "$message" != *$'\n'* ]]; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "$message"
}

LIST_ONLY=0
URGENT_ONLY=0
TARGET=""
MESSAGE=""
WAIT_SECONDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --urgent)
      URGENT_ONLY=1
      shift
      ;;
    --wait)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
        bridge_die "--wait 뒤에 숫자(초)를 지정하세요. 예: --wait 30"
      fi
      WAIT_SECONDS="$2"
      shift 2
      ;;
    -h|--help|help)
      # Issue #1114: print usage and exit 0 instead of dying with
      # "알 수 없는 옵션: --help" via the -*) catch-all.
      usage
      exit 0
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ -z "$MESSAGE" ]]; then
        MESSAGE="$1"
      else
        bridge_die "메시지는 하나의 인자로 감싸서 전달하세요."
      fi
      shift
      ;;
  esac
done

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$TARGET" || -z "$MESSAGE" ]]; then
  usage
  exit 1
fi

if [[ $URGENT_ONLY -ne 1 ]]; then
  bridge_die "직접 메시지는 --urgent일 때만 허용합니다. 일반 작업은 'agent-bridge task create'를 사용하세요."
fi

bridge_require_agent "$TARGET"

MSG_LEN=${#MESSAGE}
if [[ $MSG_LEN -gt $BRIDGE_MAX_MESSAGE_LEN ]]; then
  bridge_warn "메시지가 ${MSG_LEN}자입니다. 길면 $BRIDGE_SHARED_DIR 아래 파일에 저장하고 경로만 전달하세요."
fi

ACTOR="$(infer_actor_if_possible "")"
TASK_ID=""
TASK_TITLE=""
TITLE="$(urgent_task_title "$MESSAGE")"
BODY="$(urgent_task_body "$MESSAGE" "$TITLE")"

CREATE_ARGS=(create --to "$TARGET" --title "$TITLE" --from "$ACTOR" --priority urgent --format shell)
if [[ -n "$BODY" ]]; then
  CREATE_ARGS+=(--body "$BODY")
fi
bridge_queue_source_shell "${CREATE_ARGS[@]}"

SESSION="$(bridge_agent_session "$TARGET")"
NOTICE_MESSAGE="agb inbox ${TARGET}"

mkdir -p "$BRIDGE_LOG_DIR"
TIMESTAMP="$(date '+%H:%M:%S')"
LOGFILE="$BRIDGE_LOG_DIR/bridge-$(date '+%Y%m%d').log"
SAFE_MSG="$(bridge_sanitize_text "$MESSAGE")"

echo "[${TIMESTAMP}] !URGENT ${TARGET}/${SESSION:-none} task=${TASK_ID}: ${SAFE_MSG}" >> "$LOGFILE"

if ! bridge_dispatch_notification "$TARGET" "$TASK_TITLE" "$NOTICE_MESSAGE" "$TASK_ID" "urgent"; then
  case "$?" in
    2)
      bridge_info "urgent task #${TASK_ID} queued for ${TARGET}; direct wake deferred until the session is idle"
      ;;
    *)
      bridge_warn "urgent attention signal was not delivered; task #${TASK_ID} remains queued for ${TARGET}"
      ;;
  esac
fi

echo -e "${GREEN}[${TIMESTAMP}] !URGENT ${TARGET}: task #${TASK_ID} queued (${MSG_LEN}자)${NC}"

if [[ $WAIT_SECONDS -gt 0 ]]; then
  if [[ -z "$SESSION" ]] || ! bridge_tmux_session_exists "$SESSION"; then
    bridge_warn "세션이 없어 응답 캡처를 건너뜁니다: ${TARGET}"
    exit 0
  fi
  bridge_info "[대기] ${WAIT_SECONDS}초 후 응답 캡처..."
  sleep "$WAIT_SECONDS"
  bridge_info "--- ${TARGET} 세션 최근 출력 (마지막 30줄) ---"
  bridge_capture_recent "$SESSION" 30
  bridge_info "--- 캡처 끝 ---"
fi
