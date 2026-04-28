#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="queue"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

queue_lifecycle() {
  local body_file create_out task_id body_path show_out events_json event_types

  body_file="$SMOKE_TMP_ROOT/request-body.md"
  printf 'queue smoke body\n' >"$body_file"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from requester \
      --priority high \
      --title "queue smoke task" \
      --body-file "$body_file" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  body_path="$(smoke_shell_field TASK_BODY_PATH "$create_out")"

  smoke_assert_match "$task_id" '^[0-9]+$' "queue create returned task id"
  smoke_assert_contains "$body_path" "$BRIDGE_STATE_DIR/queue/bodies/" "ephemeral body-file stabilization"
  smoke_assert_file_exists "$body_path" "stabilized queue body"
  smoke_assert_eq "queue smoke body" "$(tr -d '\n' <"$body_path")" "stabilized body content"

  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=queued" "created task status"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$task_id" --agent worker-a --lease-seconds 60 >/dev/null
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=claimed" "claimed task status"
  smoke_assert_contains "$show_out" "TASK_CLAIMED_BY=worker-a" "claimed task owner"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" done "$task_id" --agent worker-a --note "queue smoke complete" >/dev/null
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=done" "completed task status"

  events_json="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" events --format json)"
  event_types="$(python3 - "$events_json" "$task_id" <<'PY'
import json
import sys

events = json.loads(sys.argv[1])
task_id = int(sys.argv[2])
print(",".join(event["event_type"] for event in events if event["task_id"] == task_id))
PY
)"
  smoke_assert_eq "created,claimed,done" "$event_types" "queue lifecycle event sequence"
}

queue_daemon_step_contract() {
  local create_out task_id now_ts activity_ts snapshot nudge_out same_out new_out second_id

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to daemon-worker \
      --from requester \
      --title "daemon nudge smoke" \
      --body "daemon nudge body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  now_ts="$(date +%s)"
  activity_ts="$((now_ts - 300))"
  snapshot="$SMOKE_TMP_ROOT/agent-summary.tsv"
  cat >"$snapshot" <<EOF
agent	queued	claimed	blocked	active	idle	last_seen	last_nudge	session	engine	workdir	session_activity_ts
daemon-worker	1	0	0	1	300	$now_ts	0	daemon-session	claude	$SMOKE_TMP_ROOT/daemon-worker	$activity_ts
EOF

  nudge_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_contains "$nudge_out" $'daemon-worker	daemon-session	1	0' "daemon-step nudge candidate"
  smoke_assert_contains "$nudge_out" "$task_id" "daemon-step nudge key"

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" note-nudge --agent daemon-worker --key "$task_id" >/dev/null
  same_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_eq "" "$same_out" "daemon-step suppresses duplicate nudge during cooldown"

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to daemon-worker \
      --from requester \
      --title "daemon nudge smoke second" \
      --body "second body" \
      --format shell
  )"
  second_id="$(smoke_shell_field TASK_ID "$create_out")"
  new_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
      --snapshot "$snapshot" \
      --idle-threshold 120 \
      --nudge-cooldown 900 \
      --format tsv
  )"
  smoke_assert_contains "$new_out" "$task_id,$second_id" "daemon-step retries when a new queued task arrives"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "queue"
  smoke_run "queue lifecycle with stabilized body files" queue_lifecycle
  smoke_run "queue daemon-step nudge selection" queue_daemon_step_contract
  smoke_log "passed"
}

main "$@"
