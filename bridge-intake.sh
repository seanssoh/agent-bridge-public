#!/usr/bin/env bash
# bridge-intake.sh — structured external intake triage helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

BRIDGE_INTAKE_ROSTER_LOADED=0

ensure_roster_loaded() {
  if [[ "${BRIDGE_INTAKE_ROSTER_LOADED:-0}" -eq 0 ]]; then
    bridge_load_roster
    BRIDGE_INTAKE_ROSTER_LOADED=1
  fi
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") triage --capture <id> --owner <agent> --summary <text> --category <text> [--importance low|normal|high|urgent] [--reply-needed yes|no] [--confidence <text>] [--field <key=value>]... [--followup <text> | --followup-file <path>] [--route] [--json]
  $(basename "$0") show <capture-id> [--json]

Examples:
  $(basename "$0") triage --capture 20260411T130000+0900-mail --owner patch --summary "Customer needs ETA update" --category support --importance high --reply-needed yes --field order_id=SO-123 --route
  $(basename "$0") show 20260411T130000+0900-mail --json
EOF
}

run_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-intake.py" "$@"
}

shared_root="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
dry_run=0
json_mode=0

parse_common_flag() {
  case "$1" in
    --shared-root)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      shared_root="$2"
      return 2
      ;;
    --dry-run)
      dry_run=1
      return 1
      ;;
    --json)
      json_mode=1
      return 1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
  esac
  return 0
}

command="${1:-}"
[[ -n "$command" ]] || { usage; exit 1; }
shift || true

# Issue #1114: -h/--help/help on the top-level dispatcher prints usage
# and exits 0. `parse_common_flag` recognizes --help but is never
# reached when the dispatcher's "지원하지 않는 intake 명령" arm fires
# first.
case "$command" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

case "$command" in
  triage)
    capture_id=""
    owner=""
    title=""
    summary=""
    category=""
    importance="normal"
    reply_needed="no"
    confidence=""
    followup=""
    followup_file=""
    route=0
    fields=()
    TASK_ID=""
    TASK_ASSIGNED_TO=""
    TASK_PRIORITY=""
    TASK_TITLE=""

    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      case "$1" in
        --capture)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          capture_id="$2"
          shift 2
          ;;
        --owner)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          owner="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --summary)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          summary="$2"
          shift 2
          ;;
        --category)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          category="$2"
          shift 2
          ;;
        --importance)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          importance="$2"
          shift 2
          ;;
        --reply-needed)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          reply_needed="$2"
          shift 2
          ;;
        --confidence)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          confidence="$2"
          shift 2
          ;;
        --field)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          fields+=("$2")
          shift 2
          ;;
        --followup)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          followup="$2"
          shift 2
          ;;
        --followup-file)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          followup_file="$2"
          shift 2
          ;;
        --route)
          route=1
          shift
          ;;
        *)
          bridge_die "지원하지 않는 intake triage 옵션입니다: $1"
          ;;
      esac
    done

    [[ -n "$capture_id" ]] || bridge_die "--capture is required"
    [[ -n "$owner" ]] || bridge_die "--owner is required"
    [[ -n "$summary" ]] || bridge_die "--summary is required"
    [[ -n "$category" ]] || bridge_die "--category is required"
    if [[ -n "$followup" && -n "$followup_file" ]]; then
      bridge_die "--followup and --followup-file are mutually exclusive"
    fi
    if [[ -n "$followup_file" ]]; then
      [[ -f "$followup_file" ]] || bridge_die "follow-up file not found: $followup_file"
      followup="$(<"$followup_file")"
    fi

    ensure_roster_loaded
    bridge_require_agent "$owner"

    py_args=(triage --shared-root "$shared_root" --capture "$capture_id" --owner "$owner" --summary "$summary" --category "$category" --importance "$importance" --reply-needed "$reply_needed")
    [[ -n "$title" ]] && py_args+=(--title "$title")
    [[ -n "$confidence" ]] && py_args+=(--confidence "$confidence")
    [[ -n "$followup" ]] && py_args+=(--followup "$followup")
    for field in "${fields[@]}"; do
      py_args+=(--field "$field")
    done
    [[ $dry_run -eq 1 ]] && py_args+=(--dry-run)

    triage_json="$(run_python "${py_args[@]}")"
    triage_markdown_path="$(python3 - "$triage_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["paths"]["triage_markdown"])
PY
)"
    route_blocked="$(python3 - "$triage_json" <<'PY'
import json
import sys
print("1" if json.loads(sys.argv[1]).get("route_blocked") else "0")
PY
)"

    if [[ $route -eq 1 && $dry_run -eq 0 ]]; then
      if [[ "$route_blocked" == "1" ]]; then
        echo "[intake] prompt guard blocked auto-route for capture $capture_id" >&2
      else
        bridge_queue_source_shell create --to "$owner" --title "[intake] $summary" --from bridge --priority "$importance" --body-file "$triage_markdown_path" --format shell
        run_python attach-task --shared-root "$shared_root" --capture "$capture_id" --task-id "$TASK_ID" --task-title "$TASK_TITLE" --task-priority "$TASK_PRIORITY" >/dev/null
        bridge_dispatch_notification "$owner" "$TASK_TITLE" "agb inbox ${owner}" "$TASK_ID" "$importance" >/dev/null 2>&1 || true
        triage_json="$(run_python show --shared-root "$shared_root" --capture "$capture_id")"
      fi
    fi

    if [[ $json_mode -eq 1 ]]; then
      printf '%s\n' "$triage_json"
    else
      python3 - "$triage_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(f"capture_id: {payload['capture_id']}")
print(f"owner: {payload['suggested_owner']}")
print(f"category: {payload['category']}")
print(f"importance: {payload['importance']}")
task = payload.get("task") or {}
print(f"task: #{task.get('id') or 'pending'} {task.get('title', '')}".rstrip())
print(f"triage: {payload['paths']['triage_markdown']}")
PY
    fi
    ;;
  show)
    capture_id="${1:-}"
    [[ -n "$capture_id" ]] || bridge_die "capture id가 필요합니다."
    shift || true
    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      bridge_die "지원하지 않는 intake show 옵션입니다: $1"
    done
    triage_json="$(run_python show --shared-root "$shared_root" --capture "$capture_id")"
    if [[ $json_mode -eq 1 ]]; then
      printf '%s\n' "$triage_json"
    else
      python3 - "$triage_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(f"capture_id: {payload['capture_id']}")
print(f"owner: {payload['suggested_owner']}")
print(f"category: {payload['category']}")
print(f"importance: {payload['importance']}")
task = payload.get("task") or {}
print(f"task: #{task.get('id') or 'pending'} {task.get('title', '')}".rstrip())
print(f"triage: {payload['paths']['triage_markdown']}")
PY
    fi
    ;;
  *)
    bridge_die "지원하지 않는 intake 명령입니다: $command"
    ;;
esac
