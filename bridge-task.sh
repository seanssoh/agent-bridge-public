#!/usr/bin/env bash
# bridge-task.sh — SQLite-backed task queue operations

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

BRIDGE_TASK_ROSTER_LOADED=0

ensure_roster_loaded() {
  if [[ "${BRIDGE_TASK_ROSTER_LOADED:-0}" -eq 0 ]]; then
    bridge_load_roster
    BRIDGE_TASK_ROSTER_LOADED=1
  fi
}

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-task.sh create --to <agent> --title <title> [--body <text> | --body-file <path>] [--allow-empty-body] [--from <agent>] [--priority low|normal|high|urgent]
  bash $SCRIPT_DIR/bridge-task.sh inbox [agent] [--all]
  bash $SCRIPT_DIR/bridge-task.sh show <task-id>
  bash $SCRIPT_DIR/bridge-task.sh claim <task-id> [--agent <agent>] [--lease <seconds>]
  bash $SCRIPT_DIR/bridge-task.sh done <task-id> [--agent <agent>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh cancel <task-id> [--actor <name>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh update <task-id> [--status queued|claimed|blocked|in_progress] [--priority ...] [--title ...] [--note ...]
  bash $SCRIPT_DIR/bridge-task.sh handoff <task-id> --to <agent> [--from <agent>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh summary [agent...]
EOF
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

emit_context_pressure_false_positive_if_match() {
  # Issue #338 Track C: when an operator marks a [context-pressure]
  # severity=critical task done with a "false-positive" / "HUD says <85%"
  # note, append a `context_pressure_false_positive` audit row so the
  # observability counter rendered in `agent-bridge status` can flag a
  # mis-firing analyzer. Tracks A + B (anchor regex + cache invalidation
  # on /clear) already landed; this is the metrics-surfacing follow-up
  # and intentionally has no behavioral effect on the analyzer or the
  # task itself.
  local task_id="$1"
  local note="$2"
  local note_file="$3"
  local task_shell=""
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_BODY_PATH=""
  local impacted_agent=""
  local matched_pattern=""
  local body_text=""
  local note_text=""
  local note_excerpt=""

  task_shell="$(bridge_queue_cli show "$task_id" --format shell 2>/dev/null || true)"
  [[ -n "$task_shell" ]] || return 0
  # shellcheck disable=SC1091
  source /dev/stdin <<<"$task_shell"

  # Title shape is `[context-pressure] <agent> (<severity>)`; only critical
  # participates per the issue's scope. warning is informational and out of
  # scope for the FP counter.
  [[ "${TASK_TITLE:-}" =~ ^\[context-pressure\]\ (.+)\ \(critical\)$ ]] || return 0
  impacted_agent="${BASH_REMATCH[1]}"

  # The daemon writes the report body to a file; the inline DB body_text is
  # therefore the same content but we read body_path so the existing on-disk
  # representation stays the source of truth.
  if [[ -n "${TASK_BODY_PATH:-}" && -f "$TASK_BODY_PATH" ]]; then
    body_text="$(cat "$TASK_BODY_PATH" 2>/dev/null || true)"
  fi
  [[ -n "$body_text" ]] || return 0

  # Confirm the daemon's HUD pattern actually fired this report. The body
  # carries lines like `- severity: critical` and `- matched_pattern:
  # hud:context_pct=NN`; we only count rows where the matched pattern came
  # from the HUD anchor (issue #338 Track A scope). Other criticals — e.g.
  # "context window exceeded" hard banners — are not the HUD analyzer's
  # output and stay out of the false-positive counter.
  printf '%s' "$body_text" | grep -Eq '^- severity: critical$' || return 0
  # BSD sed (macOS) does not understand `\+`; use ERE so the regex is portable
  # across macOS and Linux.
  matched_pattern="$(printf '%s' "$body_text" | sed -nE 's/^- matched_pattern: (hud:context_pct=[0-9]+)$/\1/p' | head -n1)"
  [[ -n "$matched_pattern" ]] || return 0

  if [[ -n "$note" ]]; then
    note_text="$note"
  elif [[ -n "$note_file" && -f "$note_file" ]]; then
    note_text="$(cat "$note_file" 2>/dev/null || true)"
  fi
  [[ -n "$note_text" ]] || return 0

  note_excerpt="$(NOTE="$note_text" python3 - <<'PY'
import os
import re
import sys

note = os.environ.get("NOTE", "")
if not note:
    sys.exit(1)
fp_phrase = re.search(r"false[-\s]?positive", note, re.IGNORECASE)
hud_claim = re.search(
    r"\b(?:actual|hud says|hud shows|actual hud|hud reports)\b[^0-9]*\b(?:[0-9]|[1-7][0-9]|8[0-4])\s*%",
    note,
    re.IGNORECASE,
)
if not (fp_phrase or hud_claim):
    sys.exit(1)
print(note[:200])
PY
)" || return 0
  [[ -n "$note_excerpt" ]] || return 0

  # `agent` is duplicated as a detail key (in addition to the audit row's
  # `target` field) so FP-rate aggregators that filter purely on detail
  # fields don't have to special-case the target column. (#338 Track C
  # r1 codex review flagged this absence.)
  bridge_audit_log daemon context_pressure_false_positive "$impacted_agent" \
    --detail agent="$impacted_agent" \
    --detail task_id="$task_id" \
    --detail severity=critical \
    --detail matched_pattern="$matched_pattern" \
    --detail done_note_excerpt="$note_excerpt" \
    >/dev/null 2>&1 || true
}

ack_crash_loop_task_if_needed() {
  local task_id="$1"
  local task_shell=""
  local TASK_TITLE=""
  local agent=""

  task_shell="$(bridge_queue_cli show "$task_id" --format shell 2>/dev/null || true)"
  [[ -n "$task_shell" ]] || return 0
  # shellcheck disable=SC1091
  source /dev/stdin <<<"$task_shell"
  [[ "${TASK_TITLE:-}" =~ ^\[crash-loop\]\ ([^[:space:]]+)\ \([0-9]+\ failures\)$ ]] || return 0
  agent="${BASH_REMATCH[1]}"
  bridge_agent_exists "$agent" || return 0
  bridge_agent_ack_crash_report "$agent" >/dev/null 2>&1 || true
}

notify_task_requester() {
  local task_id="$1"
  local actor="$2"
  local note="$3"
  local note_file="$4"
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_CREATED_BY=""
  local TASK_PRIORITY=""
  local creator
  local creator_engine=""
  local completion_title=""
  local completion_body=""
  local notice_message=""
  local ORIG_TASK_ID=""
  local ORIG_TASK_TITLE=""
  local ORIG_TASK_PRIORITY=""

  ensure_roster_loaded
  bridge_queue_source_shell show "$task_id" --format shell

  creator="$TASK_CREATED_BY"
  [[ -n "$creator" ]] || return 0
  [[ "$creator" != "$actor" ]] || return 0
  bridge_agent_exists "$creator" || return 0
  [[ "$TASK_TITLE" == \[task-complete\]* ]] && return 0
  creator_engine="$(bridge_agent_engine "$creator")"

  ORIG_TASK_ID="$TASK_ID"
  ORIG_TASK_TITLE="$TASK_TITLE"
  ORIG_TASK_PRIORITY="$TASK_PRIORITY"
  completion_title="[task-complete] ${ORIG_TASK_TITLE}"
  completion_body="completed_by: ${actor}"
  completion_body+=$'\n'"original_task: #${ORIG_TASK_ID}"
  completion_body+=$'\n'"inspect: agb show ${ORIG_TASK_ID}"
  if [[ -n "$note" ]]; then
    completion_body+=$'\n\n'"completion_note:"$'\n'"${note}"
  elif [[ -n "$note_file" ]]; then
    completion_body+=$'\n'"completion_note_file: ${note_file}"
  fi

  TASK_ID=""
  TASK_TITLE=""
  TASK_PRIORITY=""
  bridge_queue_source_shell create --to "$creator" --title "$completion_title" --from bridge --priority "$ORIG_TASK_PRIORITY" --body "$completion_body" --format shell

  if [[ "$creator_engine" != "claude" ]] && ! bridge_agent_is_active "$creator"; then
    return 0
  fi

  notice_message="agb inbox ${creator}"
  bridge_dispatch_notification "$creator" "$TASK_TITLE" "$notice_message" "$TASK_ID" "$TASK_PRIORITY" || true
}

# notify_task_blocker
#
# Issue #697 — mirror of notify_task_requester for the claimed→blocked
# transition. Inserts a `[task-blocked] task #<id>: <title>` task addressed
# to the original requester so a dispatcher-style agent (e.g. `patch`) sees
# the block in its inbox instead of having to poll the worker's tmux pane.
#
# Idempotency: the title format `[task-blocked] task #<id>:` is unique per
# original task; we query find-open with that prefix and bail if a
# notification already exists, so re-blocking the same task (or repeated
# blocked refresh updates) does not duplicate.
notify_task_blocker() {
  local task_id="$1"
  local actor="$2"
  local note="$3"
  local note_file="$4"
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_CREATED_BY=""
  local TASK_PRIORITY=""
  local creator
  local creator_engine=""
  local blocked_title=""
  local blocked_body=""
  local notice_message=""
  local existing_id=""
  local ORIG_TASK_ID=""
  local ORIG_TASK_TITLE=""
  local ORIG_TASK_PRIORITY=""

  ensure_roster_loaded
  bridge_queue_source_shell show "$task_id" --format shell

  creator="$TASK_CREATED_BY"
  [[ -n "$creator" ]] || return 0
  [[ "$creator" != "$actor" ]] || return 0
  bridge_agent_exists "$creator" || return 0
  # Never auto-notify on a notification task — guards against loops if a
  # requester ever ends up claiming + blocking the [task-blocked] task we
  # just inserted for them.
  [[ "$TASK_TITLE" == \[task-blocked\]* ]] && return 0
  [[ "$TASK_TITLE" == \[task-complete\]* ]] && return 0
  creator_engine="$(bridge_agent_engine "$creator")"

  ORIG_TASK_ID="$TASK_ID"
  ORIG_TASK_TITLE="$TASK_TITLE"
  ORIG_TASK_PRIORITY="$TASK_PRIORITY"

  blocked_title="[task-blocked] task #${ORIG_TASK_ID}: ${ORIG_TASK_TITLE}"

  # Idempotency check — re-blocking the same task (or any subsequent
  # blocked refresh) must not create a duplicate notification. Use the
  # title prefix `[task-blocked] task #<id>:` which is unique per
  # original task.
  existing_id="$(bridge_queue_cli find-open --agent "$creator" --title-prefix "[task-blocked] task #${ORIG_TASK_ID}:" --format id 2>/dev/null || true)"
  if [[ -n "$existing_id" ]]; then
    return 0
  fi

  blocked_body="blocked_by: ${actor}"
  blocked_body+=$'\n'"original_task: #${ORIG_TASK_ID}"
  blocked_body+=$'\n'"inspect: agb show ${ORIG_TASK_ID}"
  if [[ -n "$note" ]]; then
    blocked_body+=$'\n\n'"block_reason:"$'\n'"${note}"
  elif [[ -n "$note_file" ]]; then
    blocked_body+=$'\n'"block_reason_file: ${note_file}"
  fi

  TASK_ID=""
  TASK_TITLE=""
  TASK_PRIORITY=""
  bridge_queue_source_shell create --to "$creator" --title "$blocked_title" --from bridge --priority "$ORIG_TASK_PRIORITY" --body "$blocked_body" --format shell

  if [[ "$creator_engine" != "claude" ]] && ! bridge_agent_is_active "$creator"; then
    return 0
  fi

  notice_message="agb inbox ${creator}"
  bridge_dispatch_notification "$creator" "$TASK_TITLE" "$notice_message" "$TASK_ID" "$TASK_PRIORITY" || true
}

cmd_create() {
  local target=""
  local title=""
  local actor=""
  local explicit_actor=""
  local priority="normal"
  local body=""
  local body_was_set=0
  local body_file=""
  local allow_empty_body=0
  local skip_companion_validate=0
  local guard_threshold=""
  local guard_shell=""
  local severity=""
  local threshold=""
  local blocked=""
  local reasons=""
  local TASK_ID=""
  local TASK_ASSIGNED_TO=""
  local TASK_PRIORITY=""
  local TASK_TITLE=""
  local notice_message=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -lt 2 ]] && bridge_die "--to 뒤에 agent를 지정하세요."
        target="$2"
        shift 2
        ;;
      --title)
        [[ $# -lt 2 ]] && bridge_die "--title 뒤에 제목을 지정하세요."
        title="$2"
        shift 2
        ;;
      --from)
        [[ $# -lt 2 ]] && bridge_die "--from 뒤에 actor를 지정하세요."
        actor="$2"
        shift 2
        ;;
      --priority)
        [[ $# -lt 2 ]] && bridge_die "--priority 뒤에 값을 지정하세요."
        priority="$2"
        shift 2
        ;;
      --body)
        [[ $# -lt 2 ]] && bridge_die "--body 뒤에 본문을 지정하세요."
        body="$2"
        body_was_set=1
        shift 2
        ;;
      --body-file)
        [[ $# -lt 2 ]] && bridge_die "--body-file 뒤에 파일 경로를 지정하세요."
        body_file="$2"
        shift 2
        ;;
      --allow-empty-body)
        allow_empty_body=1
        shift
        ;;
      --skip-companion-validate)
        skip_companion_validate=1
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

  [[ -z "$target" ]] && bridge_die "--to는 필수입니다."
  [[ -z "$title" ]] && bridge_die "--title은 필수입니다."
  ensure_roster_loaded
  bridge_require_agent "$target"
  explicit_actor="$actor"
  actor="$(infer_actor_if_possible "$actor")"
  emit_inferred_actor_hint "$explicit_actor" "$actor"

  # Companion-role validation: when sending a [plan] / [review] task to a
  # codex-engine recipient, require the body to carry a focus checklist and
  # an expected-output mention. The shell layer is the right gate because it
  # already knows roster engine; bridge-queue.py validate-companion-body is
  # a pure helper. Skip via --skip-companion-validate (or env var) when a
  # short brief is intentional. Recipients on non-codex engines, or titles
  # without a companion prefix, are not validated.
  if [[ "${BRIDGE_TASK_SKIP_COMPANION_VALIDATE:-0}" == "1" ]]; then
    skip_companion_validate=1
  fi
  if [[ "$skip_companion_validate" -eq 0 ]]; then
    local recipient_engine=""
    recipient_engine="$(bridge_agent_engine "$target" 2>/dev/null || true)"
    if [[ "$recipient_engine" == "codex" ]]; then
      # Always pass an explicit body source (--body or --body-file).
      # Letting the validator fall through to stdin would let a piped
      # valid brief pass while the actually-enqueued task body is empty
      # (`echo "[plan] valid" | agb task create --to <codex> --title ...`).
      # We must validate exactly what gets stored: when no body shape is
      # provided here, the queue insert below also has no body, so we
      # validate an empty string — the validator will return rc=2 and the
      # operator gets the same structured error as any other empty brief.
      local companion_args=(--title "$title" --format json)
      if [[ "$body_was_set" -eq 1 ]]; then
        companion_args+=(--body "$body")
      elif [[ -n "$body_file" && -f "$body_file" ]]; then
        companion_args+=(--body-file "$body_file")
      else
        companion_args+=(--body "")
      fi
      local companion_result=""
      local companion_rc=0
      companion_result="$(python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" \
        validate-companion-body "${companion_args[@]}" </dev/null 2>/dev/null)" || companion_rc=$?
      if [[ "$companion_rc" -eq 2 ]]; then
        bridge_die "task body validation failed for codex companion-role review:
${companion_result}

Required sections:
- focus checklist (a '## Focus checklist' or '## focus list' section)
- expected output shape (mention 'plan-ok' / 'implement-ok' / 'needs-more', or an 'Expected output:' line)

Bypass with --skip-companion-validate (or BRIDGE_TASK_SKIP_COMPANION_VALIDATE=1) when a short brief is intentional."
      fi
    fi
  fi

  if bridge_agent_prompt_guard_enabled "$target"; then
    guard_threshold="$(bridge_agent_prompt_guard_min_block "$target" task_body)"
    guard_shell=""
    if [[ "$body_was_set" -eq 1 && -n "$body" ]]; then
      guard_shell="$(bridge_guard_python scan --agent "$target" --surface task_body --threshold "$guard_threshold" --format shell --text "$body" || true)"
    elif [[ -n "$body_file" && -f "$body_file" ]]; then
      guard_shell="$(bridge_guard_python scan --agent "$target" --surface task_body --threshold "$guard_threshold" --format shell --file "$body_file" || true)"
    fi
    if [[ -n "$guard_shell" ]]; then
      # shellcheck disable=SC1091
      source /dev/stdin <<<"$guard_shell"
      if [[ "${blocked:-0}" == "1" ]]; then
        bridge_audit_log guard prompt_guard_blocked "$target" \
          --detail surface=task_body \
          --detail severity="${severity:-unknown}" \
          --detail threshold="${threshold:-$guard_threshold}" \
          --detail title="$title"
        bridge_die "Prompt guard blocked task body for '$target' (${severity:-unknown}): ${reasons:-policy match}"
      fi
    fi
  fi

  args=(create --to "$target" --title "$title" --from "$actor" --priority "$priority")
  if [[ "$body_was_set" -eq 1 ]]; then
    args+=(--body "$body")
  fi
  if [[ -n "$body_file" ]]; then
    args+=(--body-file "$body_file")
  fi
  if [[ "$allow_empty_body" -eq 1 ]]; then
    args+=(--allow-empty-body)
  fi

  bridge_queue_source_shell "${args[@]}" --format shell
  printf 'created task #%s for %s [%s] %s\n' "$TASK_ID" "$TASK_ASSIGNED_TO" "$TASK_PRIORITY" "$TASK_TITLE"

  if [[ "$target" != "$actor" ]]; then
    notice_message="agb inbox ${target}"
    bridge_dispatch_notification "$target" "$TASK_TITLE" "$notice_message" "$TASK_ID" "$priority" >/dev/null 2>&1 || true
  fi
}

cmd_inbox() {
  local agent=""
  local all_statuses=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --all)
        all_statuses=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$agent" ]]; then
          bridge_die "agent는 하나만 지정할 수 있습니다."
        fi
        agent="$1"
        shift
        ;;
    esac
  done

  ensure_roster_loaded
  agent="$(bridge_resolve_agent "$agent")"
  args=(inbox --agent "$agent")
  if [[ $all_statuses -eq 1 ]]; then
    args+=(--all)
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_show() {
  [[ $# -ne 1 ]] && bridge_die "Usage: bash $SCRIPT_DIR/bridge-task.sh show <task-id>"
  bridge_queue_cli show "$1"
}

cmd_claim() {
  local task_id=""
  local agent=""
  local lease=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --lease)
        [[ $# -lt 2 ]] && bridge_die "--lease 뒤에 초 단위를 지정하세요."
        lease="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  ensure_roster_loaded
  agent="$(bridge_resolve_agent "$agent")"
  args=(claim "$task_id" --agent "$agent")
  if [[ -n "$lease" ]]; then
    args+=(--lease-seconds "$lease")
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_done() {
  local task_id=""
  local agent=""
  local note=""
  local note_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  ensure_roster_loaded
  agent="$(bridge_resolve_agent "$agent")"
  args=("done" "$task_id" --agent "$agent")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
  emit_context_pressure_false_positive_if_match "$task_id" "$note" "$note_file"
  ack_crash_loop_task_if_needed "$task_id"
  notify_task_requester "$task_id" "$agent" "$note" "$note_file"
}

cmd_update() {
  local task_id=""
  local actor=""
  local new_status=""
  local note_arg=""
  local note_file_arg=""
  local prior_status=""
  local TASK_STATUS=""
  local i

  task_id="${1:-}"
  shift || true
  [[ -n "$task_id" ]] || bridge_die "task_id is required"

  actor="$(infer_actor_if_possible "")"

  # Issue #697 — peek at --status / --note / --note-file / --actor so we
  # can auto-notify the requester on a claimed→blocked transition. We do
  # not consume the args; the queue CLI still receives them unchanged
  # (argparse uses the last --actor when both are present, matching this
  # peek).
  local -a update_args=("$@")
  local total="${#update_args[@]}"
  i=0
  while (( i < total )); do
    case "${update_args[$i]}" in
      --status)
        (( i + 1 < total )) && new_status="${update_args[$((i + 1))]}"
        ;;
      --status=*)
        new_status="${update_args[$i]#--status=}"
        ;;
      --note)
        (( i + 1 < total )) && note_arg="${update_args[$((i + 1))]}"
        ;;
      --note=*)
        note_arg="${update_args[$i]#--note=}"
        ;;
      --note-file)
        (( i + 1 < total )) && note_file_arg="${update_args[$((i + 1))]}"
        ;;
      --note-file=*)
        note_file_arg="${update_args[$i]#--note-file=}"
        ;;
      --actor)
        (( i + 1 < total )) && actor="${update_args[$((i + 1))]}"
        ;;
      --actor=*)
        actor="${update_args[$i]#--actor=}"
        ;;
    esac
    i=$((i + 1))
  done

  # Snapshot prior status only when a blocked-notify is plausible, so the
  # extra `show` round-trip is paid only on the relevant code path.
  if [[ "$new_status" == "blocked" ]] && { [[ -n "$note_arg" ]] || [[ -n "$note_file_arg" ]]; }; then
    if bridge_queue_source_shell show "$task_id" --format shell 2>/dev/null; then
      prior_status="$TASK_STATUS"
    fi
  fi

  bridge_queue_cli update "$task_id" --actor "$actor" "$@"

  if [[ "$new_status" == "blocked" ]] && [[ "$prior_status" == "claimed" ]] && { [[ -n "$note_arg" ]] || [[ -n "$note_file_arg" ]]; }; then
    notify_task_blocker "$task_id" "$actor" "$note_arg" "$note_file_arg"
  fi
}

cmd_cancel() {
  local task_id=""
  local actor=""
  local note=""
  local note_file=""
  local task_shell=""
  local TASK_ID=""
  local TASK_ASSIGNED_TO=""
  local TASK_TITLE=""
  local task_target=""
  local task_title=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --actor)
        [[ $# -lt 2 ]] && bridge_die "--actor 뒤에 이름을 지정하세요."
        actor="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  ensure_roster_loaded
  actor="$(infer_actor_if_possible "$actor")"
  task_shell="$(bridge_queue_cli show "$task_id" --format shell 2>/dev/null || true)"
  if [[ -n "$task_shell" ]]; then
    # shellcheck disable=SC1091
    source /dev/stdin <<<"$task_shell"
    task_target="${TASK_ASSIGNED_TO:-}"
    task_title="${TASK_TITLE:-}"
  fi
  args=("cancel" "$task_id" --actor "$actor")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
  ack_crash_loop_task_if_needed "$task_id"
  if [[ -n "$task_target" ]]; then
    bridge_audit_log queue task_cancelled "$task_target" \
      --detail task_id="$task_id" \
      --detail actor="$actor" \
      --detail title="$task_title"
    if [[ "$task_title" == \[cron-dispatch\]* ]]; then
      bridge_audit_log queue cron_dispatch_cancelled "$task_target" \
        --detail task_id="$task_id" \
        --detail actor="$actor" \
        --detail title="$task_title"
    fi
  fi
}

cmd_handoff() {
  local task_id=""
  local target=""
  local actor=""
  local note=""
  local note_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -lt 2 ]] && bridge_die "--to 뒤에 agent를 지정하세요."
        target="$2"
        shift 2
        ;;
      --from)
        [[ $# -lt 2 ]] && bridge_die "--from 뒤에 actor를 지정하세요."
        actor="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  [[ -z "$target" ]] && bridge_die "--to는 필수입니다."
  ensure_roster_loaded
  bridge_require_agent "$target"
  actor="$(infer_actor_if_possible "$actor")"

  args=(handoff "$task_id" --to "$target" --from "$actor")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_summary() {
  local args=(summary)
  local agent

  ensure_roster_loaded
  for agent in "$@"; do
    bridge_require_agent "$agent"
    args+=(--agent "$agent")
  done

  bridge_queue_cli "${args[@]}"
}

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  usage
  exit 1
fi
shift || true

case "$COMMAND" in
  create)
    cmd_create "$@"
    ;;
  inbox)
    cmd_inbox "$@"
    ;;
  show)
    cmd_show "$@"
    ;;
  claim)
    cmd_claim "$@"
    ;;
  done)
    cmd_done "$@"
    ;;
  cancel)
    cmd_cancel "$@"
    ;;
  handoff)
    cmd_handoff "$@"
    ;;
  update)
    cmd_update "$@"
    ;;
  summary)
    cmd_summary "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    # Issue #163 Phase 2: preserve the dispatcher-specific `task stats`
    # alias from the curated table, then fall back to fuzzy matching
    # against the bare task subcommands for ordinary typos.
    _hint="$(bridge_suggest_subcommand "task $COMMAND" "")"
    if [[ -z "$_hint" ]]; then
      _hint="$(bridge_suggest_subcommand "$COMMAND" \
        "create inbox show claim done cancel handoff update summary")"
    fi
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 명령입니다: $COMMAND"
    ;;
esac
