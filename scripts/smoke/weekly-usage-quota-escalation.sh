#!/usr/bin/env bash
# Regression smoke for weekly Claude usage no-alternate escalation.

set -euo pipefail

SMOKE_NAME="weekly-usage-quota-escalation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

FUNC_FILE="$SMOKE_TMP_ROOT/weekly-quota-functions.sh"
python3 "$SMOKE_REPO_ROOT/scripts/smoke/helpers/extract-shell-fn.py" \
  "$SMOKE_REPO_ROOT/bridge-daemon.sh" \
  bridge_claude_weekly_quota_task_body \
  bridge_file_claude_weekly_quota_task \
  >"$FUNC_FILE"
# shellcheck source=/dev/null
source "$FUNC_FILE"

QUEUE_ARGS="$SMOKE_TMP_ROOT/queue-args.txt"
QUEUE_BODY="$SMOKE_TMP_ROOT/queue-body.md"
AUDIT_ARGS="$SMOKE_TMP_ROOT/audit-args.txt"
: >"$QUEUE_ARGS"
: >"$AUDIT_ARGS"

bridge_queue_cli() {
  local body_file="" title="" title_prefix="" to="" priority="" from=""
  printf '%s\n' "$*" >>"$QUEUE_ARGS"
  while (($#)); do
    case "$1" in
      --body-file)
        body_file="${2:-}"
        shift 2
        ;;
      --title)
        title="${2:-}"
        shift 2
        ;;
      --title-prefix)
        title_prefix="${2:-}"
        shift 2
        ;;
      --to)
        to="${2:-}"
        shift 2
        ;;
      --priority)
        priority="${2:-}"
        shift 2
        ;;
      --from)
        from="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "$body_file" && -f "$body_file" ]] || smoke_fail "queue stub did not receive a body file"
  cp "$body_file" "$QUEUE_BODY"
  printf 'to=%s\nfrom=%s\npriority=%s\ntitle_prefix=%s\ntitle=%s\n' \
    "$to" "$from" "$priority" "$title_prefix" "$title" >>"$QUEUE_ARGS"
  printf 'TASK_ID=123\nTASK_CREATED=1\n'
}

bridge_audit_log() {
  printf '%s\n' "$*" >>"$AUDIT_ARGS"
}

smoke_log "T1: weekly no_alternate creates one actionable admin task"
bridge_file_claude_weekly_quota_task \
  "admin" "claude" "account-a" "weekly" "96" \
  "2026-06-15T00:00:00+00:00" "usage-cache" "agent-a" "no_alternate_token"

smoke_assert_file_exists "$QUEUE_BODY" "T1 queue body"
BODY_TEXT="$(cat "$QUEUE_BODY")"
ARGS_TEXT="$(cat "$QUEUE_ARGS")"
AUDIT_TEXT="$(cat "$AUDIT_ARGS")"

smoke_assert_contains "$ARGS_TEXT" "upsert-open" "T1 uses upsert-open"
smoke_assert_contains "$ARGS_TEXT" "[claude-quota] weekly usage" "T1 uses stable title prefix"
smoke_assert_contains "$ARGS_TEXT" "priority=high" "T1 priority high"
smoke_assert_contains "$BODY_TEXT" "used_percent: 96" "T1 body carries usage percent"
smoke_assert_contains "$BODY_TEXT" "reset_at: 2026-06-15T00:00:00+00:00" "T1 body carries reset"
smoke_assert_contains "$BODY_TEXT" "agb auth claude-token add --id <new-token-id> --stdin --activate --sync" "T1 body has exact operator command"
smoke_assert_contains "$BODY_TEXT" "no alternate token" "T1 body explains root cause"
smoke_assert_contains "$AUDIT_TEXT" "claude_weekly_quota_no_alternate" "T1 audit emitted"

smoke_log "T2: empty admin agent does not create a task"
before_lines="$(wc -l <"$QUEUE_ARGS" | tr -d ' ')"
if bridge_file_claude_weekly_quota_task \
  "" "claude" "account-a" "weekly" "96" \
  "2026-06-15T00:00:00+00:00" "usage-cache" "agent-a" "no_alternate_token"; then
  smoke_fail "T2 empty admin_agent should not create a task"
fi
after_lines="$(wc -l <"$QUEUE_ARGS" | tr -d ' ')"
smoke_assert_eq "$before_lines" "$after_lines" "T2 queue call count unchanged"

smoke_log "T3: non-weekly candidate does not create a task"
before_lines="$after_lines"
if bridge_file_claude_weekly_quota_task \
  "admin" "claude" "account-a" "5h" "99" \
  "2026-06-09T13:00:00+00:00" "usage-cache" "agent-a" "no_alternate_token"; then
  smoke_fail "T3 non-weekly candidate should not create a task"
fi
after_lines="$(wc -l <"$QUEUE_ARGS" | tr -d ' ')"
smoke_assert_eq "$before_lines" "$after_lines" "T3 queue call count unchanged"

smoke_log "T4: weekly non-no-alternate result does not create a task"
before_lines="$after_lines"
if bridge_file_claude_weekly_quota_task \
  "admin" "claude" "account-a" "weekly" "96" \
  "2026-06-15T00:00:00+00:00" "usage-cache" "agent-a" "auto_rotate_disabled"; then
  smoke_fail "T4 non-no-alternate reason should not create a task"
fi
after_lines="$(wc -l <"$QUEUE_ARGS" | tr -d ' ')"
smoke_assert_eq "$before_lines" "$after_lines" "T4 queue call count unchanged"

smoke_log "ok"
