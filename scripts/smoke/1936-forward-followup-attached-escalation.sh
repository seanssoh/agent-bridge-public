#!/usr/bin/env bash
# Regression for issue #1936 / gap #4:
# attached live-idle sessions must keep the #1411 raw-inject skip, but
# human-facing cron followups should get a fast refreshable admin escalation.

set -euo pipefail

SMOKE_NAME="1936-forward-followup-attached-escalation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1936-forward-followup.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
QUEUE="$REPO_ROOT/bridge-queue.py"
HELPER="$REPO_ROOT/bridge-daemon-helpers.py"
DAEMON="$REPO_ROOT/bridge-daemon.sh"

export BRIDGE_TASK_DB="$DB"
python3 "$QUEUE" init >/dev/null

failed=0

write_body() {
  local name="$1"
  local path="$TMP_DIR/$name.md"
  shift
  printf '%s\n' "$@" >"$path"
  printf '%s' "$path"
}

create_task() {
  local title="$1"
  local body_file="$2"
  BRIDGE_TASK_DB="$DB" python3 "$QUEUE" create \
    --to alpha --from smoke --priority normal \
    --title "$title" --body-file "$body_file" >/dev/null
}

task_id_for_title() {
  local title="$1"
  sqlite3 "$DB" "SELECT id FROM tasks WHERE title = '$title' ORDER BY id LIMIT 1;"
}

parse_row() {
  local row="$1"
  local tmp="$TMP_DIR/helper-row.tsv"
  printf '%s\n' "$row" >"$tmp"
  COUNT=""
  FIRST_ID=""
  IDS_CSV=""
  FIRST_TITLE=""
  CREATED_TS=""
  INTENT=""
  CHANNEL=""
  TARGET_REF=""
  FORMAT=""
  IFS=$'\t' read -r COUNT FIRST_ID IDS_CSV FIRST_TITLE CREATED_TS INTENT CHANNEL TARGET_REF FORMAT <"$tmp" || true
}

ordinary_body="$(write_body ordinary 'ordinary task')"
main_body="$(write_body main \
  '---' \
  '{' \
  '  "schema_version": 1,' \
  '  "kind": "cron-followup",' \
  '  "delivery_intent": "main_session_only",' \
  '  "forward_target": null' \
  '}' \
  '---' \
  '# main only')"
forward_body="$(write_body forward \
  '---' \
  '{' \
  '  "schema_version": 1,' \
  '  "kind": "cron-followup",' \
  '  "delivery_intent": "forward_to_user",' \
  '  "forward_target": {' \
  '    "channel": "discord",' \
  '    "target_ref": "ops",' \
  '    "format": "markdown"' \
  '  }' \
  '}' \
  '---' \
  '# forward me')"
legacy_body="$(write_body legacy \
  '# legacy cron followup' \
  'needs_human_followup=true')"

create_task '[review] ordinary' "$ordinary_body"
create_task '[cron-followup] main-only' "$main_body"
create_task '[cron-followup] forward' "$forward_body"
create_task '[cron-followup] legacy' "$legacy_body"
missing_ts="$(date +%s)"
sqlite3 "$DB" "INSERT INTO tasks (title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path) VALUES ('[cron-followup] missing-body', 'alpha', 'smoke', 'normal', 'queued', $missing_ts, $missing_ts, NULL, '$TMP_DIR/does-not-exist.md');"

ordinary_id="$(task_id_for_title '[review] ordinary')"
main_id="$(task_id_for_title '[cron-followup] main-only')"
forward_id="$(task_id_for_title '[cron-followup] forward')"
legacy_id="$(task_id_for_title '[cron-followup] legacy')"
missing_id="$(task_id_for_title '[cron-followup] missing-body')"

row="$(python3 "$HELPER" human-followup-queued-state "$DB" alpha)"
parse_row "$row"
if [[ "$COUNT" == "2" && "$FIRST_ID" == "$forward_id" && "$IDS_CSV" == "${forward_id},${legacy_id}" && "$INTENT" == "forward_to_user" && "$CHANNEL" == "discord" && "$TARGET_REF" == "ops" && "$FORMAT" == "markdown" ]]; then
  echo "  PASS  H1: helper detects strict forward_to_user + legacy needs_human_followup"
else
  echo "  FAIL  H1: unexpected helper row: $row" >&2
  failed=1
fi

row="$(python3 "$HELPER" human-followup-queued-state "$DB" alpha "$main_id")"
parse_row "$row"
if [[ "$COUNT" == "0" ]]; then
  echo "  PASS  H2: main_session_only is not human-facing"
else
  echo "  FAIL  H2: main_session_only misclassified: $row" >&2
  failed=1
fi

row="$(python3 "$HELPER" human-followup-queued-state "$DB" alpha "$legacy_id")"
parse_row "$row"
if [[ "$COUNT" == "1" && "$FIRST_ID" == "$legacy_id" && "$INTENT" == "legacy_needs_human_followup" ]]; then
  echo "  PASS  H3: legacy needs_human_followup fallback is detected"
else
  echo "  FAIL  H3: legacy fallback not detected: $row" >&2
  failed=1
fi

row="$(python3 "$HELPER" human-followup-queued-state "$DB" alpha "$ordinary_id,$missing_id")"
parse_row "$row"
if [[ "$COUNT" == "0" ]]; then
  echo "  PASS  H4: ordinary task + missing body path do not crash or misclassify"
else
  echo "  FAIL  H4: ordinary/missing-body misclassified: $row" >&2
  failed=1
fi

if grep -q 'human-followup-queued-state' "$DAEMON" \
   && grep -q 'queue_attention_attached_human_followup' "$DAEMON" \
   && grep -q '\[forward-followup-stranded\]' "$DAEMON" \
   && grep -q 'bridge_queue_cli upsert-open' "$DAEMON"; then
  echo "  PASS  S1: daemon has attached human-followup escalation wiring"
else
  echo "  FAIL  S1: daemon escalation wiring missing" >&2
  failed=1
fi

helper_line="$(grep -n '"$SCRIPT_DIR/bridge-daemon-helpers.py" human-followup-queued-state' "$DAEMON" | head -n1 | cut -d: -f1)"
attached_line="$(grep -n 'bridge_audit_log daemon queue_attention_attached_skip' "$DAEMON" | head -n1 | cut -d: -f1)"
note_nudge_line="$(grep -n 'bridge_task_note_nudge "\$agent"' "$DAEMON" | head -n1 | cut -d: -f1)"
if [[ -n "$helper_line" && -n "$attached_line" && -n "$note_nudge_line" \
      && "$helper_line" -lt "$attached_line" && "$attached_line" -lt "$note_nudge_line" ]]; then
  echo "  PASS  S2: human-followup check runs inside attached skip before note-nudge success path"
else
  echo "  FAIL  S2: attached-skip ordering unexpected (helper=${helper_line}, attached=${attached_line}, note=${note_nudge_line})" >&2
  failed=1
fi

if grep -q 'bridge_daemon_record_nudge "$agent" "$nudge_fingerprint"' "$DAEMON"; then
  echo "  PASS  S3: existing #1411 attached-skip rate-limit remains"
else
  echo "  FAIL  S3: attached-skip nudge fingerprint record missing" >&2
  failed=1
fi

EXTRACTED="$TMP_DIR/extracted-functions.sh"
# Issue #1973 Track B: the escalation now rate-limits its refresh on a
# capped exponential backoff, so it calls bridge_daemon_nudge_backoff_delay
# — extract that helper too or the sourced function aborts at runtime.
python3 "$REPO_ROOT/scripts/smoke/helpers/extract-shell-fn.py" "$DAEMON" \
  bridge_daemon_attached_human_followup_marker_file \
  bridge_daemon_nudge_backoff_delay \
  bridge_daemon_attached_human_followup_escalate >"$EXTRACTED"

BRIDGE_STATE_DIR="$TMP_DIR/state"
BRIDGE_ADMIN_AGENT_ID="admin"
BRIDGE_DAEMON_NOTIFY_DRY_RUN="1"
export BRIDGE_STATE_DIR BRIDGE_ADMIN_AGENT_ID BRIDGE_DAEMON_NOTIFY_DRY_RUN

bridge_agent_exists() {
  [[ "$1" == "admin" || "$1" == "alpha" ]]
}

bridge_queue_cli() {
  BRIDGE_TASK_DB="$DB" python3 "$QUEUE" "$@"
}

bridge_audit_log() {
  printf '%s\n' "$*" >>"$TMP_DIR/audit.log"
}

bridge_notify_send() {
  printf '%s\n' "$*" >>"$TMP_DIR/notify.log"
  return 0
}

daemon_warn() {
  printf 'WARN %s\n' "$*" >&2
}

# shellcheck disable=SC1090
source "$EXTRACTED"

old_ts=$(( $(date +%s) - 180 ))
bridge_daemon_attached_human_followup_escalate \
  alpha alpha-session 1 "$forward_id" "${forward_id},${legacy_id}" \
  '[cron-followup] forward' "$old_ts" forward_to_user discord ops markdown 2 0
bridge_daemon_attached_human_followup_escalate \
  alpha alpha-session 1 "$forward_id" "${forward_id},${legacy_id}" \
  '[cron-followup] forward' "$old_ts" forward_to_user discord ops markdown 2 0

admin_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE assigned_to = 'admin' AND title LIKE '[forward-followup-stranded] #${forward_id} on alpha %';")"
admin_body="$(sqlite3 "$DB" "SELECT body_text FROM tasks WHERE assigned_to = 'admin' AND title LIKE '[forward-followup-stranded] #${forward_id} on alpha %' LIMIT 1;")"
if [[ "$admin_count" == "1" \
      && "$admin_body" == *"agent-bridge urgent alpha"* \
      && "$admin_body" == *"forward target channel: discord"* \
      && -f "$BRIDGE_STATE_DIR/daemon-attached-human-followup/${forward_id}.marker" ]]; then
  echo "  PASS  S4: isolated escalation upserts one admin task with drain instructions + cooldown marker"
else
  echo "  FAIL  S4: isolated escalation result unexpected (count=${admin_count})" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi

echo "[smoke:${SMOKE_NAME}] all checks passed"
