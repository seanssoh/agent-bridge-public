#!/usr/bin/env bash
# bridge-bundle.sh — queue-first structured handoff bundle helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

BRIDGE_BUNDLE_ROSTER_LOADED=0

ensure_roster_loaded() {
  if [[ "${BRIDGE_BUNDLE_ROSTER_LOADED:-0}" -eq 0 ]]; then
    bridge_load_roster
    BRIDGE_BUNDLE_ROSTER_LOADED=1
  fi
}

infer_actor_if_possible() {
  local actor="${1:-}"

  if [[ -n "$actor" ]]; then
    printf '%s' "$actor"
    return 0
  fi

  ensure_roster_loaded
  if actor="$(bridge_infer_current_agent 2>/dev/null)"; then
    printf '%s' "$actor"
    return 0
  fi

  printf '%s' "${USER:-unknown}"
}

emit_inferred_actor_hint() {
  local explicit_actor="${1:-}"
  local inferred_actor="${2:-}"

  [[ -z "$explicit_actor" ]] || return 0
  [[ -n "$inferred_actor" ]] || return 0

  echo "[hint] --from omitted; inferred sender: ${inferred_actor}. Use --from <agent> to override." >&2
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") create --to <agent> --title <title> --summary <text> --action <text> [--artifact <path[::purpose]>]... [--expected-output <text>] [--human-followup <text> | --human-followup-file <path>] [--from <agent>] [--priority low|normal|high|urgent] [--dry-run] [--json]
  $(basename "$0") show <bundle-id> [--json]

Examples:
  $(basename "$0") create --to reviewer --title "QA handoff" --summary "Review attached draft" --action "Read the draft and return blockers" --artifact ~/agent-bridge/shared/report.md::draft
  $(basename "$0") show 20260411T130000+0900-qa-handoff --json
EOF
}

run_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-bundle.py" "$@"
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
# reached when the dispatcher's "지원하지 않는 bundle 명령" arm fires
# first.
case "$command" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

case "$command" in
  create)
    target=""
    title=""
    summary=""
    required_action=""
    expected_output=""
    human_followup=""
    human_followup_file=""
    actor=""
    explicit_actor=""
    priority="normal"
    artifacts=()
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
        --to)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          target="$2"
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
        --action)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          required_action="$2"
          shift 2
          ;;
        --artifact)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          artifacts+=("$2")
          shift 2
          ;;
        --expected-output)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          expected_output="$2"
          shift 2
          ;;
        --human-followup)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          human_followup="$2"
          shift 2
          ;;
        --human-followup-file)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          human_followup_file="$2"
          shift 2
          ;;
        --from)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          actor="$2"
          shift 2
          ;;
        --priority)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          priority="$2"
          shift 2
          ;;
        *)
          bridge_die "지원하지 않는 bundle create 옵션입니다: $1"
          ;;
      esac
    done

    [[ -n "$target" ]] || bridge_die "--to is required"
    [[ -n "$title" ]] || bridge_die "--title is required"
    [[ -n "$summary" ]] || bridge_die "--summary is required"
    [[ -n "$required_action" ]] || bridge_die "--action is required"
    if [[ -n "$human_followup" && -n "$human_followup_file" ]]; then
      bridge_die "--human-followup and --human-followup-file are mutually exclusive"
    fi
    if [[ -n "$human_followup_file" ]]; then
      [[ -f "$human_followup_file" ]] || bridge_die "human follow-up file not found: $human_followup_file"
      human_followup="$(<"$human_followup_file")"
    fi

    ensure_roster_loaded
    bridge_require_agent "$target"
    explicit_actor="$actor"
    actor="$(infer_actor_if_possible "$actor")"
    emit_inferred_actor_hint "$explicit_actor" "$actor"

    py_args=(create --shared-root "$shared_root" --from-agent "$actor" --to-agent "$target" --title "$title" --summary "$summary" --required-action "$required_action" --priority "$priority")
    [[ -n "$expected_output" ]] && py_args+=(--expected-output "$expected_output")
    [[ -n "$human_followup" ]] && py_args+=(--human-followup "$human_followup")
    for artifact in "${artifacts[@]}"; do
      py_args+=(--artifact "$artifact")
    done
    [[ $dry_run -eq 1 ]] && py_args+=(--dry-run)

    bundle_json="$(run_python "${py_args[@]}")"
    bundle_id="$(python3 - "$bundle_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["bundle_id"])
PY
)"
    task_body_path="$(python3 - "$bundle_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["paths"]["task_body"])
PY
)"

    if [[ $dry_run -eq 1 ]]; then
      if [[ $json_mode -eq 1 ]]; then
        printf '%s\n' "$bundle_json"
      else
        printf 'created dry-run bundle %s -> %s\n' "$bundle_id" "$task_body_path"
      fi
      exit 0
    fi

    bridge_queue_source_shell create --to "$target" --title "[handoff] $title" --from "$actor" --priority "$priority" --body-file "$task_body_path" --format shell
    run_python attach-task --shared-root "$shared_root" --bundle-id "$bundle_id" --task-id "$TASK_ID" --task-title "$TASK_TITLE" --task-priority "$TASK_PRIORITY" >/dev/null

    if [[ "$target" != "$actor" ]]; then
      bridge_dispatch_notification "$target" "$TASK_TITLE" "agb inbox ${target}" "$TASK_ID" "$priority" >/dev/null 2>&1 || true
    fi

    if [[ $json_mode -eq 1 ]]; then
      run_python show --shared-root "$shared_root" --bundle-id "$bundle_id"
    else
      printf 'created handoff bundle %s -> task #%s for %s [%s]\n' "$bundle_id" "$TASK_ID" "$TASK_ASSIGNED_TO" "$TASK_PRIORITY"
      printf 'bundle: %s\n' "$task_body_path"
    fi
    ;;
  show)
    bundle_id="${1:-}"
    [[ -n "$bundle_id" ]] || bridge_die "bundle id가 필요합니다."
    shift || true
    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      bridge_die "지원하지 않는 bundle show 옵션입니다: $1"
    done
    bundle_json="$(run_python show --shared-root "$shared_root" --bundle-id "$bundle_id")"
    if [[ $json_mode -eq 1 ]]; then
      printf '%s\n' "$bundle_json"
    else
      python3 - "$bundle_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(f"bundle_id: {payload['bundle_id']}")
print(f"from: {payload['from_agent']}")
print(f"to: {payload['to_agent']}")
task = payload.get("task") or {}
print(f"task: #{task.get('id') or 'pending'} {task.get('title', '')}".rstrip())
print(f"bundle: {payload['paths']['task_body']}")
print(f"artifacts: {len(payload.get('artifacts') or [])}")
PY
    fi
    ;;
  *)
    bridge_die "지원하지 않는 bundle 명령입니다: $command"
    ;;
esac
