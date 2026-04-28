#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="daemon"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

daemon_autostart_gate() {
  local gate_body state_home output

  state_home="$SMOKE_TMP_ROOT/autostart-home"
  mkdir -p "$state_home/state"
  gate_body="$(awk '/^bridge_daemon_autostart_allowed\(\) \{/,/^}/' "$SMOKE_REPO_ROOT/bridge-daemon.sh")"
  [[ -n "$gate_body" ]] || smoke_fail "daemon autostart gate: could not extract bridge_daemon_autostart_allowed"

  output="$(
    BRIDGE_STATE_DIR="$state_home/state" bash -s <<EOF
set -euo pipefail
bridge_daemon_autostart_state_file() { printf "%s/daemon-autostart/%s.env" "\$BRIDGE_STATE_DIR" "\$1"; }
bridge_agent_broken_launch_file() { printf "%s/broken-launch/%s.env" "\$BRIDGE_STATE_DIR" "\$1"; }
$gate_body
mkdir -p "\$BRIDGE_STATE_DIR/daemon-autostart" "\$BRIDGE_STATE_DIR/broken-launch"
printf 'BROKEN_LAUNCH=1\n' >"\$(bridge_agent_broken_launch_file smoke-agent)"
if bridge_daemon_autostart_allowed smoke-agent; then
  echo "allowed"
else
  echo "blocked"
fi
rm -f "\$(bridge_agent_broken_launch_file smoke-agent)"
if bridge_daemon_autostart_allowed smoke-agent; then
  echo "allowed-after-clear"
else
  echo "blocked-after-clear"
fi
EOF
  )"
  smoke_assert_eq $'blocked\nallowed-after-clear' "$output" "daemon autostart broken-launch gate"
}

daemon_stale_claim_requeue() {
  local create_out task_id snapshot now_ts old_ts show_out

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to stale-agent \
      --from requester \
      --title "stale claim smoke" \
      --body "stale claim body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" claim "$task_id" --agent stale-agent --lease-seconds 3600 >/dev/null

  old_ts="$(( $(date +%s) - 7200 ))"
  python3 - "$BRIDGE_TASK_DB" "$task_id" "$old_ts" <<'PY'
import sqlite3
import sys

db, task_id, old_ts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with sqlite3.connect(db) as conn:
    conn.execute("UPDATE tasks SET claimed_ts = ?, updated_ts = ? WHERE id = ?", (old_ts, old_ts, task_id))
PY

  now_ts="$(date +%s)"
  snapshot="$SMOKE_TMP_ROOT/stale-summary.tsv"
  cat >"$snapshot" <<EOF
agent	queued	claimed	blocked	active	idle	last_seen	last_nudge	session	engine	workdir	session_activity_ts
stale-agent	0	1	0	0	-	0	0	stale-session	claude	$SMOKE_TMP_ROOT/stale-agent	0
EOF

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$snapshot" \
    --max-claim-age 900 \
    --format tsv >/dev/null
  show_out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_STATUS=queued" "daemon stale claim requeue status at $now_ts"
  smoke_assert_contains "$show_out" "TASK_CLAIMED_BY=''" "daemon stale claim clears owner"
}

daemon_blocked_aging() {
  local create_out task_id old_ts snapshot reminder_id

  create_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to blocked-agent \
      --from requester \
      --title "blocked smoke" \
      --body "blocked body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" update "$task_id" --status blocked --note "waiting on smoke fixture" >/dev/null
  old_ts="$(( $(date +%s) - 90000 ))"
  python3 - "$BRIDGE_TASK_DB" "$task_id" "$old_ts" <<'PY'
import sqlite3
import sys

db, task_id, old_ts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with sqlite3.connect(db) as conn:
    conn.execute("UPDATE tasks SET updated_ts = ? WHERE id = ?", (old_ts, task_id))
PY

  snapshot="$SMOKE_TMP_ROOT/blocked-summary.tsv"
  cat >"$snapshot" <<EOF
agent	queued	claimed	blocked	active	idle	last_seen	last_nudge	session	engine	workdir	session_activity_ts
blocked-agent	0	0	1	0	-	0	0	blocked-session	claude	$SMOKE_TMP_ROOT/blocked-agent	0
admin-agent	0	0	0	0	-	0	0	admin-session	claude	$SMOKE_TMP_ROOT/admin-agent	0
EOF

  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$snapshot" \
    --blocked-reminder-seconds 60 \
    --blocked-escalate-seconds 120 \
    --admin-agent admin-agent \
    --format tsv >/dev/null

  reminder_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" find-open --agent blocked-agent --title-prefix "[blocked-aging] task #$task_id " --format id)"
  smoke_assert_match "$reminder_id" '^[0-9]+$' "daemon blocked-aging reminder task"

  reminder_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" find-open --agent admin-agent --title-prefix "[blocked-escalation] task #$task_id " --format id)"
  smoke_assert_match "$reminder_id" '^[0-9]+$' "daemon blocked-aging escalation task"
}

main() {
  smoke_require_cmd awk
  smoke_require_cmd python3
  smoke_setup_bridge_home "daemon"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  smoke_run "autostart quarantine gate" daemon_autostart_gate
  smoke_run "stale claimed tasks requeue deterministically" daemon_stale_claim_requeue
  smoke_run "blocked task reminder/escalation aging" daemon_blocked_aging
  smoke_log "passed"
}

main "$@"
