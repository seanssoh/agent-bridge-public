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

daemon_context_pressure_audit_state_transitions() {
  local root audit_file state_dir helper output rc bash_bin

  root="$(mktemp -d "$SMOKE_TMP_ROOT/context-pressure-unit.XXXXXX")"
  audit_file="$root/audit.log"
  state_dir="$root/state"
  helper="$root/context-pressure-functions.sh"
  mkdir -p "$state_dir"
  : >"$audit_file"

  awk '
    /^bridge_clear_context_pressure_state\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ {
      done += 1
      if (done == 3) {
        capture=0
      }
    }
  ' "$SMOKE_REPO_ROOT/bridge-daemon.sh" >"$helper"
  [[ -s "$helper" ]] || smoke_fail "context pressure: could not extract daemon functions"

  bash_bin="${BASH4_BIN:-}"
  if [[ -z "$bash_bin" || ! -x "$bash_bin" ]]; then
    bash_bin="$(command -v bash)"
  fi

  set +e
  output="$("$bash_bin" -lc '
set -euo pipefail
state_dir="$1"
audit_file="$2"
helper="$3"
SCRIPT_DIR="$PWD"
export BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1
export BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0
mkdir -p "$state_dir"

analysis_severity=""
analysis_hash=""
analysis_pattern=""
agent_source_mode="static"
capture_empty=0

bridge_agent_context_pressure_state_file() {
  printf "%s/%s.env" "$state_dir" "$1"
}

bridge_audit_log() {
  local actor="$1"
  local action="$2"
  local target="$3"
  shift 3
  {
    printf "%s|%s|%s" "$actor" "$action" "$target"
    for item in "$@"; do
      printf "|%s" "$item"
    done
    printf "\n"
  } >>"$audit_file"
}

bridge_tmux_session_exists() { return 0; }
bridge_capture_recent() {
  (( capture_empty == 1 )) && return 0
  printf "Context remaining 8%%. Please compact soon."
}
bridge_with_timeout() {
  cat >/dev/null || true
  [[ -n "$analysis_severity" ]] || return 0
  printf "CONTEXT_PRESSURE_SEVERITY=%q\n" "$analysis_severity"
  printf "CONTEXT_PRESSURE_MATCHED_PATTERN=%q\n" "$analysis_pattern"
  printf "CONTEXT_PRESSURE_EXCERPT_HASH=%q\n" "$analysis_hash"
}
bridge_agent_source() { printf "%s" "$agent_source_mode"; }
bridge_queue_cli() { echo "bridge_queue_cli should not be called"; exit 99; }
bridge_notify_send() { echo "bridge_notify_send should not be called"; exit 99; }
daemon_info() { :; }
daemon_source_state_file() {
  # shellcheck source=/dev/null
  source "$1" 2>/dev/null
}

# shellcheck disable=SC1090
source "$helper"

summary_static=$'"'"'static-agent\t0\t0\t0\t1\t0\t0\t0\tstatic-session\tclaude\t/tmp'"'"'
summary_dynamic=$'"'"'dynamic-agent\t0\t0\t0\t1\t0\t0\t0\tdynamic-session\tclaude\t/tmp'"'"'

analysis_severity=warning
analysis_hash=hash-static
analysis_pattern=hud:context_pct=72
agent_source_mode=static
process_context_pressure_reports "$summary_static" >/dev/null
static_state="$(cat "$state_dir/static-agent.env")"
[[ "$static_state" == *"CONTEXT_PRESSURE_SEVERITY=warning"* ]] || { echo "static severity missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_EXCERPT_HASH=hash-static"* ]] || { echo "static hash missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_FIRST_DETECTED_TS="* ]] || { echo "static first ts missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_LAST_DETECTED_TS="* ]] || { echo "static last detected ts missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_LAST_SCAN_TS="* ]] || { echo "static scan ts missing"; exit 1; }
[[ "$static_state" != *"CONTEXT_PRESSURE_TASK_ID"* ]] || { echo "static task id persisted"; exit 1; }
grep -q "daemon|context_pressure_detected|static-agent|--detail|severity=warning" "$audit_file" || { echo "static detected audit missing"; exit 1; }
[[ ! -e "$state_dir/context-pressure/static-agent-warning.md" ]] || { echo "static report body created"; exit 1; }

analysis_hash=hash-static-2
process_context_pressure_reports "$summary_static" >/dev/null
grep -q "daemon|context_pressure_detected|static-agent|--detail|severity=warning|--detail|excerpt_hash=hash-static-2|--detail|mode=hash_drift" "$audit_file" || { echo "hash drift audit missing"; exit 1; }

analysis_hash=hash-dynamic
agent_source_mode=dynamic
bridge_note_context_pressure_state "dynamic-agent" "warning" "hash-dynamic" "10" "11" "12" "0" "hud:context_pct=72"
process_context_pressure_reports "$summary_dynamic" >/dev/null
[[ ! -e "$state_dir/dynamic-agent.env" ]] || { echo "dynamic state not cleared"; exit 1; }
grep -q "daemon|context_pressure_suppressed|dynamic-agent|--detail|severity=warning|--detail|reason=dynamic_agent_operator_managed" "$audit_file" || { echo "dynamic suppressed audit missing"; exit 1; }
! grep -q "daemon|context_pressure_detected|dynamic-agent" "$audit_file" || { echo "dynamic same-severity edge should not emit detected audit"; exit 1; }

capture_empty=1
analysis_severity=""
agent_source_mode=static
process_context_pressure_reports "$summary_static" >/dev/null
[[ ! -e "$state_dir/static-agent.env" ]] || { echo "recovered state not cleared"; exit 1; }
grep -q "daemon|context_pressure_recovered|static-agent|--detail|severity=warning|--detail|reason=no_pattern" "$audit_file" || { echo "recovered audit missing"; exit 1; }

echo ok
' _ "$state_dir" "$audit_file" "$helper")"
  rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || smoke_fail "context pressure audit/state transitions failed: $output"
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

daemon_idle_marker_permission_guard() {
  local agent dir idle_file manual_file output rc

  agent="idle-acl-agent"
  dir="$BRIDGE_ACTIVE_AGENT_DIR/$agent"
  idle_file="$dir/idle-since"
  manual_file="$dir/manual-stop"
  mkdir -p "$dir"

  set +e
  output="$("$BASH" -lc '
set -euo pipefail
repo_root="$1"
agent="$2"
idle_file="$3"
manual_file="$4"
# shellcheck disable=SC1090
source "$repo_root/bridge-lib.sh"

BRIDGE_AGENT_IDS=("$agent")
bridge_agent_is_active() { return 0; }

printf "123\n" >"$idle_file"
chmod 000 "$idle_file"
if bridge_agent_idle_since_epoch "$agent"; then
  echo "idle epoch unexpectedly succeeded"
  exit 1
fi
[[ ! -e "$idle_file" ]] || {
  echo "unreadable idle marker was not cleared"
  exit 1
}

mkdir -p "$(dirname "$manual_file")"
printf "123\n" >"$manual_file"
chmod 000 "$manual_file"
if bridge_agent_manual_stop_active "$agent"; then
  echo "manual-stop unexpectedly succeeded"
  exit 1
fi
[[ ! -e "$manual_file" ]] || {
  echo "unreadable manual-stop marker was not cleared"
  exit 1
}

mkdir -p "$(dirname "$idle_file")"
printf "123\n" >"$idle_file"
chmod 000 "$idle_file"
bridge_reconcile_idle_markers
[[ ! -e "$idle_file" ]] || {
  echo "unreadable idle marker survived reconcile"
  exit 1
}

echo ok
' _ "$SMOKE_REPO_ROOT" "$agent" "$idle_file" "$manual_file" 2>&1)"
  rc=$?
  set -e
  chmod 600 "$idle_file" "$manual_file" >/dev/null 2>&1 || true
  rm -f "$idle_file" "$manual_file" >/dev/null 2>&1 || true
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || smoke_fail "idle marker permission guard failed: $output"
}

daemon_source_state_file_guard() {
  local root helper output rc bash_bin

  root="$(mktemp -d "$SMOKE_TMP_ROOT/source-state-unit.XXXXXX")"
  helper="$root/daemon-source-state-file.sh"
  awk '
    /^daemon_source_state_file\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { exit }
  ' "$SMOKE_REPO_ROOT/bridge-daemon.sh" >"$helper"
  [[ -s "$helper" ]] || smoke_fail "source-state: could not extract daemon_source_state_file"

  bash_bin="${BASH4_BIN:-}"
  if [[ -z "$bash_bin" || ! -x "$bash_bin" ]]; then
    bash_bin="$(command -v bash)"
  fi

  set +e
  output="$("$bash_bin" -lc '
set -euo pipefail
root="$1"
helper="$2"
daemon_warn() { printf "warn:%s\n" "$1" >&2; }
# shellcheck disable=SC1090
source "$helper"

state_file="$root/state.env"
printf "STATE_NEXT_TS=123\n" >"$state_file"
STATE_NEXT_TS=0
daemon_source_state_file "$state_file" "unit" 1
[[ "${STATE_NEXT_TS:-}" == "123" ]] || {
  echo "readable state did not source"
  exit 1
}

printf "STATE_NEXT_TS=456\n" >"$state_file"
chmod 000 "$state_file"
if daemon_source_state_file "$state_file" "unit" 1; then
  echo "unreadable state unexpectedly sourced"
  exit 1
fi
[[ ! -e "$state_file" ]] || {
  echo "unreadable state was not cleared"
  exit 1
}

printf "STATE_NEXT_TS=\$(\n" >"$state_file"
if daemon_source_state_file "$state_file" "unit" 1; then
  echo "invalid state unexpectedly sourced"
  exit 1
fi
[[ ! -e "$state_file" ]] || {
  echo "invalid state was not cleared"
  exit 1
}

echo ok
' _ "$root" "$helper" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || smoke_fail "source state file guard failed: $output"
}

main() {
  smoke_require_cmd awk
  smoke_require_cmd python3
  smoke_setup_bridge_home "daemon"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  smoke_run "autostart quarantine gate" daemon_autostart_gate
  smoke_run "context pressure audit/state transitions" daemon_context_pressure_audit_state_transitions
  smoke_run "stale claimed tasks requeue deterministically" daemon_stale_claim_requeue
  smoke_run "blocked task reminder/escalation aging" daemon_blocked_aging
  smoke_run "idle marker permission guard" daemon_idle_marker_permission_guard
  smoke_run "source state file guard" daemon_source_state_file_guard
  smoke_log "passed"
}

main "$@"
