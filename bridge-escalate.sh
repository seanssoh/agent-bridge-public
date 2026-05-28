#!/usr/bin/env bash
# bridge-escalate.sh — escalation helpers for external follow-up and admin routing

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-escalate.sh question --agent <agent> --question "<text>" [--context "<text>" | --context-file <path>] [--session <session>] [--wait-seconds <seconds>] [--json] [--dry-run]
EOF
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

write_question_body() {
  local path="$1"
  local agent="$2"
  local admin_agent="$3"
  local session="$4"
  local question="$5"
  local context="$6"
  local wait_seconds="$7"
  local now_iso="$8"

  cat >"$path" <<EOF
# External Question Escalation

- agent: $agent
- admin_agent: $admin_agent
- session: ${session:--}
- detected_at: $now_iso
- wait_seconds: ${wait_seconds:--}

## Question

$question
EOF

  if [[ -n "$context" ]]; then
    cat >>"$path" <<EOF

## Context

$context
EOF
  fi

  cat >>"$path" <<EOF

## Requested Action

Please send this question to the connected human-facing channel, collect the reply there, and route the answer back to \`$agent\`.
EOF
}

cmd_question() {
  local agent=""
  local question=""
  local context=""
  local context_file=""
  local session=""
  local wait_seconds=""
  local dry_run=0
  local json_mode=0
  local force_admin_relay=0
  local agent_source=""
  local admin_agent=""
  local title=""
  local now_iso=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local body_file=""
  local create_output=""
  local task_id=""
  local notify_status="skipped"
  local notify_reason=""
  local notify_message=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 값을 지정하세요."
        agent="$2"
        shift 2
        ;;
      --question)
        [[ $# -lt 2 ]] && bridge_die "--question 뒤에 값을 지정하세요."
        question="$2"
        shift 2
        ;;
      --context)
        [[ $# -lt 2 ]] && bridge_die "--context 뒤에 값을 지정하세요."
        context="$2"
        shift 2
        ;;
      --context-file)
        [[ $# -lt 2 ]] && bridge_die "--context-file 뒤에 값을 지정하세요."
        context_file="$2"
        shift 2
        ;;
      --session)
        [[ $# -lt 2 ]] && bridge_die "--session 뒤에 값을 지정하세요."
        session="$2"
        shift 2
        ;;
      --wait-seconds)
        [[ $# -lt 2 ]] && bridge_die "--wait-seconds 뒤에 값을 지정하세요."
        wait_seconds="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      --force-admin-relay)
        # Explicit opt-in: relay through admin even when the calling agent is
        # dynamic. Default off so a dynamic agent whose operator is in its TUI
        # does not produce a wasted admin nudge (#343 Track A).
        force_admin_relay=1
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

  [[ -n "$agent" ]] || bridge_die "--agent는 필수입니다."
  [[ -n "$question" ]] || bridge_die "--question은 필수입니다."
  bridge_require_agent "$agent"

  agent_source="$(bridge_agent_source "$agent")"
  if [[ "$agent_source" == "dynamic" && "$force_admin_relay" -ne 1 ]]; then
    # Dynamic agents have direct operator attachment in their own TUI; the
    # agent's own conversation is the human-facing channel for this question.
    # Refuse to escalate (exit 0 — the call succeeded by deciding "no
    # escalation needed"). Use --force-admin-relay to override.
    printf 'agent-bridge: skipping admin escalation — "%s" is a dynamic agent. The operator should answer in the agent'\''s TUI directly. No queue task created. Use --force-admin-relay to override.\n' "$agent" >&2
    exit 0
  fi

  admin_agent="$(bridge_require_admin_agent)"
  [[ "$admin_agent" != "$agent" ]] || bridge_die "질문 에스컬레이션은 관리자 자신이 아닌 다른 에이전트에서만 사용하세요."
  [[ -n "$session" ]] || session="$(bridge_agent_session "$agent")"
  if [[ -n "$context_file" ]]; then
    [[ -f "$context_file" ]] || bridge_die "context file을 찾을 수 없습니다: $context_file"
    context="$(cat "$context_file")"
  fi
  if [[ -n "$wait_seconds" && ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
    bridge_die "--wait-seconds는 숫자여야 합니다."
  fi

  now_iso="$(bridge_now_iso)"
  title="[question-escalation] ${agent} needs user reply"
  body_file="$(mktemp "${TMPDIR:-/tmp}/bridge-escalate.XXXXXX")"
  trap 'rm -f "$body_file"' RETURN
  write_question_body "$body_file" "$agent" "$admin_agent" "$session" "$question" "$context" "$wait_seconds" "$now_iso"

  notify_kind="$(bridge_agent_notify_kind "$admin_agent")"
  notify_target="$(bridge_agent_notify_target "$admin_agent")"
  notify_account="$(bridge_agent_notify_account "$admin_agent")"
  notify_message="Question from ${agent}: ${question}"
  if [[ -n "$wait_seconds" ]]; then
    notify_message+=$'\n'"Waited: ${wait_seconds}s"
  fi
  if [[ -n "$session" ]]; then
    notify_message+=$'\n'"Session: ${session}"
  fi

  if [[ $dry_run -eq 0 ]]; then
    # Issue #1318 part A (v0.14.5-beta5-2 Lane ξ): urgent escalations to a
    # stopped admin must still enqueue — the escalation IS the signal
    # that prompts the operator to start the admin. Without --force,
    # `agb task create` refuses against stopped agents by default.
    create_output="$(bash "$SCRIPT_DIR/bridge-task.sh" create --to "$admin_agent" --from "$agent" --priority urgent --title "$title" --body-file "$body_file" --force)"
    if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
      task_id="${BASH_REMATCH[1]}"
    else
      bridge_die "질문 에스컬레이션 task 생성에 실패했습니다: $create_output"
    fi

    if [[ -n "$notify_kind" && -n "$notify_target" ]]; then
      if bash "$SCRIPT_DIR/bridge-notify.sh" send --agent "$admin_agent" --title "$title" --message "$notify_message" --task-id "$task_id" --priority urgent >/dev/null; then
        notify_status="sent"
      else
        notify_status="failed"
        notify_reason="external notify failed"
      fi
    else
      notify_reason="admin notify target is not configured"
    fi
  fi

  if [[ $json_mode -eq 1 ]]; then
    cat <<EOF
{
  "agent": $(printf '%s' "$agent" | json_escape),
  "admin_agent": $(printf '%s' "$admin_agent" | json_escape),
  "session": $(printf '%s' "$session" | json_escape),
  "title": $(printf '%s' "$title" | json_escape),
  "question": $(printf '%s' "$question" | json_escape),
  "task_id": $(printf '%s' "$task_id" | json_escape),
  "notify": {
    "kind": $(printf '%s' "$notify_kind" | json_escape),
    "target": $(printf '%s' "$notify_target" | json_escape),
    "account": $(printf '%s' "$notify_account" | json_escape),
    "status": $(printf '%s' "$notify_status" | json_escape),
    "reason": $(printf '%s' "$notify_reason" | json_escape)
  },
  "dry_run": $( [[ $dry_run -eq 1 ]] && printf 'true' || printf 'false' )
}
EOF
    return 0
  fi

  printf 'agent: %s\n' "$agent"
  printf 'admin_agent: %s\n' "$admin_agent"
  printf 'session: %s\n' "${session:--}"
  printf 'title: %s\n' "$title"
  printf 'question: %s\n' "$question"
  printf 'task_id: %s\n' "${task_id:--}"
  printf 'notify_status: %s\n' "$notify_status"
  [[ -n "$notify_reason" ]] && printf 'notify_reason: %s\n' "$notify_reason"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  question)
    cmd_question "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 escalate 명령입니다: $subcommand"
    ;;
esac
