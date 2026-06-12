#!/usr/bin/env bash

# This smoke depends on Bash 4+ behavior in bridge-lib.sh and in helpers
# extracted from bridge-daemon.sh. macOS ships Bash 3.2 by default, so
# `./scripts/smoke/daemon.sh` direct invocation through `/usr/bin/env bash`
# may resolve to /bin/bash. Re-exec into a Bash 4+ candidate when needed
# so the resulting subshells (and the bridge-lib.sh re-exec guard, which
# sees $0 as the smoke script path) all run on Bash 4+. Capture
# BASH_SOURCE[0] before any re-exec — $0 is unreliable under macOS
# /bin/bash invocations like `bash -lc '...' _` where it expands to `_`.
# (#576 r4 Finding 3)
_SMOKE_DAEMON_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_DAEMON_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_DAEMON_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:daemon] requires Bash 4+; install homebrew bash or set BASH4_BIN to a Bash 4+ binary." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  if [[ -n "${DAEMON_SOCKET_PID:-}" ]]; then
    kill "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
  fi
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

# required-vars guard: empty file passes bash -n + source but must be
# rejected when caller declares a required variable. This is the
# isolated-UID partial-flush case the round-1 review flagged.
: >"$state_file"
unset STATE_NEXT_TS
if daemon_source_state_file "$state_file" "unit" 1 "STATE_NEXT_TS"; then
  echo "empty state with required var unexpectedly sourced"
  exit 1
fi
[[ ! -e "$state_file" ]] || {
  echo "empty state with required var was not cleared"
  exit 1
}

# required-vars guard: a file populated only with unrelated vars must be
# rejected when the caller declares a different required var.
printf "OTHER_VAR=1\n" >"$state_file"
unset STATE_NEXT_TS
if daemon_source_state_file "$state_file" "unit" 1 "STATE_NEXT_TS"; then
  echo "missing required var unexpectedly sourced"
  exit 1
fi
[[ ! -e "$state_file" ]] || {
  echo "state with missing required var was not cleared"
  exit 1
}

# required-vars guard: when the required var is present, the source
# call must succeed and the var must be exported into the caller scope.
printf "STATE_NEXT_TS=999\n" >"$state_file"
unset STATE_NEXT_TS
daemon_source_state_file "$state_file" "unit" 1 "STATE_NEXT_TS"
[[ "${STATE_NEXT_TS:-}" == "999" ]] || {
  echo "required var present did not source"
  exit 1
}

# Finding 1 (#576 r3) regression: a successful source from agent A must
# not leak vars into agent B when agent B'\''s file fails to source.
# Mirrors the per-loop scan pattern in bridge_scan_stall_state /
# bridge_scan_context_pressure where the post-call read happens
# unconditionally regardless of source rc.
agent_a="$root/agent-a.env"
agent_b="$root/agent-b.env"
printf "STALL_LAST_SCAN_TS=111\nSTALL_ACTIVE_CLASSIFICATION=foo\n" >"$agent_a"
unset STALL_LAST_SCAN_TS STALL_ACTIVE_CLASSIFICATION
daemon_source_state_file "$agent_a" "stall/A" 1 "STALL_LAST_SCAN_TS" "STALL_ACTIVE_CLASSIFICATION"
[[ "${STALL_LAST_SCAN_TS:-}" == "111" ]] || { echo "agent-A scan-ts did not source"; exit 1; }
[[ "${STALL_ACTIVE_CLASSIFICATION:-}" == "foo" ]] || { echo "agent-A classification did not source"; exit 1; }

# Agent B does not exist. The helper must fail AND clear all sanitize_vars
# so the post-call read does not see agent A'\''s "foo".
if daemon_source_state_file "$agent_b" "stall/B" 0 "STALL_LAST_SCAN_TS" "STALL_ACTIVE_CLASSIFICATION"; then
  echo "missing state file unexpectedly sourced"
  exit 1
fi
[[ -z "${STALL_LAST_SCAN_TS:-}" ]] || { echo "STALL_LAST_SCAN_TS leaked from agent-A: ${STALL_LAST_SCAN_TS}"; exit 1; }
[[ -z "${STALL_ACTIVE_CLASSIFICATION:-}" ]] || { echo "STALL_ACTIVE_CLASSIFICATION leaked from agent-A: ${STALL_ACTIVE_CLASSIFICATION}"; exit 1; }

# Same pattern but with an unreadable file (the actual reproduction of
# the live bug — isolated UID writes a 0600 file, controller cannot read).
printf "STALL_LAST_SCAN_TS=111\nSTALL_ACTIVE_CLASSIFICATION=bar\n" >"$agent_a"
chmod 600 "$agent_a"
unset STALL_LAST_SCAN_TS STALL_ACTIVE_CLASSIFICATION
daemon_source_state_file "$agent_a" "stall/A" 0 "STALL_LAST_SCAN_TS" "STALL_ACTIVE_CLASSIFICATION"
[[ "${STALL_ACTIVE_CLASSIFICATION:-}" == "bar" ]] || { echo "agent-A re-source did not pick up bar"; exit 1; }

agent_c="$root/agent-c.env"
: >"$agent_c"
chmod 000 "$agent_c"
if daemon_source_state_file "$agent_c" "stall/C" 0 "STALL_LAST_SCAN_TS" "STALL_ACTIVE_CLASSIFICATION"; then
  echo "unreadable state unexpectedly sourced (cross-agent leak case)"
  exit 1
fi
[[ -z "${STALL_LAST_SCAN_TS:-}" ]] || { echo "STALL_LAST_SCAN_TS leaked across unreadable boundary: ${STALL_LAST_SCAN_TS}"; exit 1; }
[[ -z "${STALL_ACTIVE_CLASSIFICATION:-}" ]] || { echo "STALL_ACTIVE_CLASSIFICATION leaked across unreadable boundary: ${STALL_ACTIVE_CLASSIFICATION}"; exit 1; }
chmod 600 "$agent_c" 2>/dev/null || true

echo ok
' _ "$root" "$helper" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || smoke_fail "source state file guard failed: $output"
}

daemon_acl_default_inheritance() {
  # Verifies the core correctness claim of this PR: when the controller
  # installs a default ACL on a runtime_state_dir / log_dir-style
  # directory, files subsequently created inside that directory by an
  # isolated UID inherit the default ACL and remain controller-readable.
  # Without the default ACL, controller reads return EACCES (the bug
  # this PR is meant to prevent).
  #
  # The boundary this test must demonstrate is:
  #   non-root controller UID  --read-->  isolated-UID-owned 0700 file
  # Root MUST NOT play either role: root bypasses POSIX ACLs entirely,
  # which makes any negative-case `cat` succeed regardless of the ACL
  # state and renders the positive case vacuous. Two distinct non-root
  # UIDs are therefore required, and we need privilege (root or a
  # passwordless sudo grant) to switch into both. Skip cleanly otherwise
  # so the test runs on platforms that support it (linux server install)
  # without breaking dev-box smoke runs (macOS, unprivileged CI). (#576 r3
  # Finding 2)
  local isolated_user="" controller_user="" root="" target_dir=""
  local positive_file="" negative_dir="" negative_file=""
  local rc cleanup_users=()

  if ! command -v setfacl >/dev/null 2>&1; then
    smoke_log "skipped acl default inheritance: setfacl not available (requires Linux + acl pkg)"
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    smoke_log "skipped acl default inheritance: requires root (or equivalent) to switch into two non-root UIDs"
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    smoke_log "skipped acl default inheritance: sudo not available — cannot switch UIDs without bypassing the ACL"
    return 0
  fi

  # Allow the operator to pin specific test UIDs via env (e.g. on hosts
  # where `nobody`/`daemon` are unusable). Both must be non-root, distinct,
  # and `sudo -n -u` must be able to switch into them.
  local controller_candidate isolated_candidate
  controller_candidate="${BRIDGE_ACL_SMOKE_CONTROLLER:-}"
  isolated_candidate="${BRIDGE_ACL_SMOKE_ISOLATED:-}"

  # Auto-discover from a small whitelist of unprivileged accounts that
  # exist on most Linux distros. Avoid creating users implicitly — the
  # round-3 brief permits creation but it's a side effect a smoke run
  # should not leave on the host.
  local user_candidate
  for user_candidate in "$isolated_candidate" nobody daemon bin _unknown nfsnobody mail; do
    [[ -n "$user_candidate" ]] || continue
    [[ "$user_candidate" == root ]] && continue
    id -u "$user_candidate" >/dev/null 2>&1 || continue
    if [[ -z "$isolated_user" ]]; then
      isolated_user="$user_candidate"
      continue
    fi
    if [[ -z "$controller_user" && "$user_candidate" != "$isolated_user" ]]; then
      controller_user="$user_candidate"
      break
    fi
  done

  # Operator override for the controller role takes precedence over the
  # auto-discovered choice (lets a host pin its actual bridge admin UID).
  if [[ -n "$controller_candidate" ]] && id -u "$controller_candidate" >/dev/null 2>&1; then
    controller_user="$controller_candidate"
  fi

  if [[ -z "$isolated_user" || -z "$controller_user" || "$isolated_user" == "$controller_user" ]]; then
    smoke_log "skipped acl default inheritance: need two distinct non-root UIDs (set BRIDGE_ACL_SMOKE_ISOLATED + BRIDGE_ACL_SMOKE_CONTROLLER, or ensure two of nobody/daemon/bin/_unknown exist)"
    return 0
  fi
  if [[ "$isolated_user" == root || "$controller_user" == root ]]; then
    smoke_log "skipped acl default inheritance: refusing to use root as either role (root bypasses POSIX ACLs)"
    return 0
  fi

  # Verify both UIDs are reachable via passwordless sudo. Without this
  # the rest of the test would prompt or hang.
  if ! sudo -n -u "$isolated_user" /bin/true >/dev/null 2>&1; then
    smoke_log "skipped acl default inheritance: sudo -n -u $isolated_user failed (no passwordless grant)"
    return 0
  fi
  if ! sudo -n -u "$controller_user" /bin/true >/dev/null 2>&1; then
    smoke_log "skipped acl default inheritance: sudo -n -u $controller_user failed (no passwordless grant)"
    return 0
  fi

  root="$(mktemp -d "$SMOKE_TMP_ROOT/acl-default.XXXXXX")"
  target_dir="$root/with-default-acl"
  negative_dir="$root/without-default-acl"
  mkdir -p "$target_dir" "$negative_dir"
  # Mimic isolated-UID-only ownership: the isolated agent owns the
  # directory and group/other have no access. Default ACLs are the only
  # path by which the controller can ever read the contents.
  chown "$isolated_user":"$isolated_user" "$target_dir" "$negative_dir"
  chmod 700 "$target_dir" "$negative_dir"
  # The controller UID must be able to traverse $root to reach
  # $target_dir; mktemp -d defaults to 0700 owned by the smoke runner
  # (root here). Add an ACL grant so traversal works without flipping
  # the parent dir to 0755.
  setfacl -m "u:${controller_user}:x" "$root" "$target_dir" "$negative_dir" \
    || smoke_fail "acl default inheritance: setfacl traversal grant failed on $root"

  # Install the default ACL on the positive-case directory. This is the
  # exact shape lib/bridge-agents.sh::bridge_linux_acl_add_default_dirs_recursive
  # applies (setfacl -d -m u:<controller>:rwX), narrowed to one dir.
  setfacl -d -m "u:${controller_user}:rwX" "$target_dir" \
    || smoke_fail "acl default inheritance: setfacl -d failed on $target_dir"

  # Simulated isolated-UID write into both directories.
  positive_file="$target_dir/idle-since"
  negative_file="$negative_dir/idle-since"
  sudo -n -u "$isolated_user" /bin/sh -c "printf '%s' \"123\" >'$positive_file'" \
    || smoke_fail "acl default inheritance: isolated UID could not write positive file"
  sudo -n -u "$isolated_user" /bin/sh -c "printf '%s' \"123\" >'$negative_file'" \
    || smoke_fail "acl default inheritance: isolated UID could not write negative file"

  # Positive case: controller (NON-root) must be able to read the file
  # the isolated UID just created. This is the inheritance guarantee. We
  # MUST run the read as $controller_user — running as root would bypass
  # the ACL and make this assertion vacuous.
  set +e
  sudo -n -u "$controller_user" /bin/sh -c "cat '$positive_file' >/dev/null 2>&1"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] \
    || smoke_fail "acl default inheritance: controller (${controller_user}) could not read isolated-UID file under default ACL (rc=$rc)"

  # Negative case: same setup WITHOUT the default ACL must reject the
  # non-root controller. If this passes silently, the positive case is
  # not actually exercising the ACL. (Running as root here would always
  # succeed — this is exactly the vacuous-test class the round-3 review
  # called out.)
  set +e
  sudo -n -u "$controller_user" /bin/sh -c "cat '$negative_file' >/dev/null 2>&1"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] \
    || smoke_fail "acl default inheritance: controller (${controller_user}) unexpectedly read file without default ACL (test setup is not exercising the ACL boundary)"

  : "${cleanup_users[@]:-}"  # silence unused-var warning when cleanup empty
  smoke_log "ok: acl default inheritance positive+negative confirmed (controller=$controller_user, isolated=$isolated_user)"
}

daemon_socket_listener_contract() {
  local bridge_id socket_path pid_file daemon_log create_out task_id show_out

  export BRIDGE_GATEWAY_TRANSPORT=file
  export BRIDGE_GATEWAY_LISTENER=auto
  export BRIDGE_AGENT_ID=""
  export BRIDGE_AGENT_ENV_FILE=""
  export BRIDGE_QUEUE_GATEWAY_PEERS="$(id -u):worker-a"
  export BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT="$SMOKE_TMP_ROOT/daemon-socket-runtime"
  export BRIDGE_TMPFILES_DIR="$SMOKE_TMP_ROOT/tmpfiles.d"
  export BRIDGE_TMPFILES_DRIVER=shim
  export BRIDGE_QUEUE_GATEWAY_SOCKET_START_WAIT_SECONDS=2
  export BRIDGE_DAEMON_INTERVAL=60

  bridge_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$BRIDGE_HOME")"
  socket_path="$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT/$bridge_id/queue-gateway.sock"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket.pid"
  daemon_log="$SMOKE_TMP_ROOT/daemon-run.log"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "worker-a"
BRIDGE_AGENT_ENGINE["worker-a"]="claude"
BRIDGE_AGENT_SESSION["worker-a"]="worker-a"
BRIDGE_AGENT_WORKDIR["worker-a"]="$SMOKE_TMP_ROOT/worker-a"
BRIDGE_AGENT_LAUNCH_CMD["worker-a"]="BRIDGE_GATEWAY_TRANSPORT=socket claude"
BRIDGE_AGENT_ISOLATION_MODE["worker-a"]="linux-user"
BRIDGE_AGENT_OS_USER["worker-a"]="agent-bridge-worker-a"
EOF
  mkdir -p "$SMOKE_TMP_ROOT/worker-a"
  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" run >"$daemon_log" 2>&1 &
  DAEMON_SOCKET_PID="$!"

  # Same bounded poll as the loop-restart test (the old fixed 50*0.1=5s
  # window was the same cold-boot cliff — a passing CI run was observed
  # taking 4.0s of it). The socket assertion below is unchanged.
  _daemon_wait_for_socket_listener_pid "$socket_path" "$pid_file" "$DAEMON_SOCKET_PID" >/dev/null || true
  [[ -S "$socket_path" ]] || smoke_fail "daemon did not start queue socket listener; $(_daemon_socket_listener_diag "$DAEMON_SOCKET_PID" "$daemon_log")"

  create_out="$(
    BRIDGE_GATEWAY_PROXY=1 BRIDGE_AGENT_ID=worker-a BRIDGE_GATEWAY_TRANSPORT=socket python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from forged \
      --title "daemon socket listener smoke" \
      --body "daemon socket body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_CREATED_BY=worker-a" "daemon socket listener proxies as peer"

  kill "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
  wait "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
  DAEMON_SOCKET_PID=""
  [[ ! -S "$socket_path" ]] || smoke_fail "daemon exit should remove queue socket"
}

# Poll, with a bounded budget, for the queue-gateway socket listener to be
# live AND for its pid file to hold a numeric pid distinct from an optional
# excluded pid (the restart case passes the killed listener's pid so it waits
# for the *replacement*). Re-reads the pid file every iteration so a daemon
# that writes the pid late is tolerated. The `kill -0 $daemon_pid` conjunct
# gates ACCEPTANCE on the daemon still being alive — it does not fail fast
# (a crashed-but-unreaped daemon is a zombie and zombies still pass kill -0);
# the bounded budget is what terminates the wait. Echoes the discovered pid
# on success (nothing on timeout) and returns non-zero on timeout, so the
# caller's strict numeric assertion still fires when the listener never
# comes up.
#
# Budget rationale (v0.16.10 wave CI flake, PR #1848 run 27401016284): the
# daemon writes NOTHING to its own stdout/stderr on a healthy boot, so the
# old failure message's empty `log=` was normal, not evidence of a hang.
# What actually burns the budget on a congested runner is gateway-listener
# cold start: each attempt is a python3 spawn with a 2s in-daemon wait
# (BRIDGE_QUEUE_GATEWAY_SOCKET_START_WAIT_SECONDS), retried once per daemon
# tick — so a couple of slow spawns already eat most of a fixed 10s window.
# A healthy daemon breaks this poll the instant the socket binds, so a high
# ceiling costs nothing on a green run; 300*0.1=30s absorbs that cold-boot
# latency without masking a real never-start.
_daemon_wait_for_socket_listener_pid() {
  local socket_path="$1" pid_file="$2" daemon_pid="$3" exclude_pid="${4:-}"
  local attempts="${DAEMON_SOCKET_LISTENER_WAIT_ATTEMPTS:-300}"
  local found="" i
  for ((i = 0; i < attempts; i++)); do
    if [[ -S "$socket_path" && -f "$pid_file" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
      found="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
      if [[ "$found" =~ ^[0-9]+$ && "$found" != "$exclude_pid" ]]; then
        printf '%s\n' "$found"
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

# Failure diagnostics for the socket-listener tests. The daemon's own log is
# empty on a healthy boot, so on timeout we also need: is the daemon process
# still alive, and what did the gateway listener spawn actually say (its
# errors land in state/queue-gateway-socket.log, not the daemon log).
_daemon_socket_listener_diag() {
  local daemon_pid="$1" daemon_log="$2"
  local alive="no"
  kill -0 "$daemon_pid" 2>/dev/null && alive="yes"
  printf 'daemon_alive=%s daemon_log=[%s] gateway_socket_log=[%s]' \
    "$alive" \
    "$(cat "$daemon_log" 2>/dev/null || true)" \
    "$(tail -n 20 "$BRIDGE_STATE_DIR/queue-gateway-socket.log" 2>/dev/null || true)"
}

daemon_socket_listener_loop_restart() {
  local bridge_id socket_path pid_file daemon_log first_pid second_pid create_out task_id show_out

  export BRIDGE_GATEWAY_TRANSPORT=file
  export BRIDGE_GATEWAY_LISTENER=auto
  export BRIDGE_AGENT_ID=""
  export BRIDGE_AGENT_ENV_FILE=""
  export BRIDGE_QUEUE_GATEWAY_PEERS="$(id -u):worker-a"
  export BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT="$SMOKE_TMP_ROOT/daemon-socket-runtime-loop"
  export BRIDGE_TMPFILES_DIR="$SMOKE_TMP_ROOT/tmpfiles-loop.d"
  export BRIDGE_TMPFILES_DRIVER=shim
  export BRIDGE_QUEUE_GATEWAY_SOCKET_START_WAIT_SECONDS=2
  export BRIDGE_DAEMON_INTERVAL=1

  bridge_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$BRIDGE_HOME")"
  socket_path="$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT/$bridge_id/queue-gateway.sock"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket.pid"
  daemon_log="$SMOKE_TMP_ROOT/daemon-loop-restart.log"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "worker-a"
BRIDGE_AGENT_ENGINE["worker-a"]="claude"
BRIDGE_AGENT_SESSION["worker-a"]="worker-a"
BRIDGE_AGENT_WORKDIR["worker-a"]="$SMOKE_TMP_ROOT/worker-a"
BRIDGE_AGENT_LAUNCH_CMD["worker-a"]="BRIDGE_GATEWAY_TRANSPORT=socket claude"
BRIDGE_AGENT_ISOLATION_MODE["worker-a"]="linux-user"
BRIDGE_AGENT_OS_USER["worker-a"]="agent-bridge-worker-a"
EOF
  mkdir -p "$SMOKE_TMP_ROOT/worker-a"
  # Isolation from the preceding lifecycle test: it shares BRIDGE_STATE_DIR,
  # so a pid file left by a partially-run daemon exit trap would hand this
  # test the OLD listener's pid as first_pid (and kill the wrong process).
  # The daemon's stop path normally removes it; this makes it deterministic.
  rm -f "$pid_file"
  bash "$SMOKE_REPO_ROOT/bridge-daemon.sh" run >"$daemon_log" 2>&1 &
  DAEMON_SOCKET_PID="$!"

  # Wait for the initial listener to come up. first_pid is "" on timeout so
  # the strict smoke_fail below fires (not a `set -u` "unbound variable"
  # abort — issue #1644's original CI symptom). See
  # _daemon_wait_for_socket_listener_pid for the bounded-poll + budget
  # rationale (the prior fixed 10s window was still too tight under the
  # v0.16.10 wave job: PR #1848 run 27401016284).
  first_pid="$(_daemon_wait_for_socket_listener_pid "$socket_path" "$pid_file" "$DAEMON_SOCKET_PID" || true)"
  [[ "$first_pid" =~ ^[0-9]+$ ]] || smoke_fail "loop-restart: daemon did not start initial listener; $(_daemon_socket_listener_diag "$DAEMON_SOCKET_PID" "$daemon_log")"

  kill "$first_pid" >/dev/null 2>&1 || true

  # Wait for the daemon to restart the killed listener: same bounded poll, but
  # exclude first_pid so we only accept a genuinely new listener process.
  second_pid="$(_daemon_wait_for_socket_listener_pid "$socket_path" "$pid_file" "$DAEMON_SOCKET_PID" "$first_pid" || true)"
  [[ "$second_pid" =~ ^[0-9]+$ && "$second_pid" != "$first_pid" ]] \
    || smoke_fail "loop-restart: daemon did not restart dead queue socket listener (first=$first_pid second=${second_pid:-}); $(_daemon_socket_listener_diag "$DAEMON_SOCKET_PID" "$daemon_log")"

  create_out="$(
    BRIDGE_GATEWAY_PROXY=1 BRIDGE_AGENT_ID=worker-a BRIDGE_GATEWAY_TRANSPORT=socket python3 "$SMOKE_REPO_ROOT/bridge-queue.py" create \
      --to worker-a \
      --from forged \
      --title "daemon socket restart smoke" \
      --body "daemon socket restart body" \
      --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$create_out")"
  show_out="$(BRIDGE_GATEWAY_PROXY=0 python3 "$SMOKE_REPO_ROOT/bridge-queue.py" show "$task_id" --format shell)"
  smoke_assert_contains "$show_out" "TASK_CREATED_BY=worker-a" "loop-restarted socket listener proxies as peer"

  kill "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
  wait "$DAEMON_SOCKET_PID" >/dev/null 2>&1 || true
  DAEMON_SOCKET_PID=""
}

# r2 finding 4: daemon listener lifecycle joint pid+socket validation.
# A stale pid file (process gone, no socket) plus a stale socket file
# (no owning pid) must both be cleaned up before the next start, so the
# `is_running` decision is honest and `stop` does not signal an
# unrelated recycled pid. This test simulates both halves and asserts
# that bridge_queue_gateway_socket_is_running returns false and that
# bridge_queue_gateway_socket_clean_stale removes the leftover artifacts.
daemon_socket_listener_stale_recovery() {
  local pid_file socket_path stale_pid bridge_id helper helper_out

  : "${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:=$SMOKE_TMP_ROOT/daemon-socket-runtime}"
  export BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT
  bridge_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$BRIDGE_HOME")"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket.pid"
  socket_path="$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT/$bridge_id/queue-gateway.sock"
  mkdir -p "$BRIDGE_STATE_DIR" "$(dirname "$socket_path")"

  # Definitely-dead pid: fork a process that exits immediately, then wait.
  ( exec true ) &
  stale_pid="$!"
  wait "$stale_pid" >/dev/null 2>&1 || true
  printf '%s\n' "$stale_pid" >"$pid_file"

  # Real bound socket file, then close it (file remains on disk until cleanup).
  python3 - "$socket_path" <<'PY' >/dev/null
import os, socket, sys
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.bind(p)
s.close()
PY
  [[ -S "$socket_path" ]] || smoke_fail "stale-recovery: pre-condition — bound socket should exist on disk"

  # Drive the helpers via an extracted-functions helper script. This
  # avoids sourcing the whole bridge-daemon.sh (which has top-level
  # command parsing) — we just pull the functions we need. The
  # connect-probe helper (r3) is required because is_running and
  # clean_stale both call it.
  helper="$SMOKE_TMP_ROOT/stale-recovery-driver.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nPID_FILE="$1"\nSOCKET_PATH="$2"\n'
    awk '/^bridge_queue_gateway_socket_pid_file\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_pid\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_connect_probe\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_probe_persistently_dead\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_is_running\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_clean_stale\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    cat <<'BASH'
bridge_queue_gateway_socket_pid_file() { printf "%s" "$PID_FILE"; }
bridge_queue_gateway_socket_path() { printf "%s" "$SOCKET_PATH"; }
if bridge_queue_gateway_socket_is_running; then
  echo "running-before-clean"
  exit 1
fi
bridge_queue_gateway_socket_clean_stale
if [[ -f "$PID_FILE" ]]; then
  echo "pid file not removed"
  exit 1
fi
if [[ -e "$SOCKET_PATH" ]]; then
  echo "socket not removed"
  exit 1
fi
echo "ok"
BASH
  } >"$helper"
  chmod +x "$helper"
  helper_out="$(bash "$helper" "$pid_file" "$socket_path" 2>&1 || true)"
  smoke_assert_contains "$helper_out" "ok" "stale-recovery: clean_stale removes pid+socket when listener is gone"
}

# r3 finding 4: false-positive liveness defense. Under r2's file-only
# liveness check, a fixture where (a) the recorded pid is alive but
# unrelated and (b) a leftover socket file exists on disk would pass
# `is_running` even though no listener is actually serving the socket.
# The r3 connect-probe rejects this combination because connect() to
# an unbound socket file raises ECONNREFUSED. This smoke writes the
# smoke runner's own pid (definitely alive, definitely NOT a queue
# gateway listener) into the pid file, materializes a real-but-closed
# socket file, and asserts:
#   * is_running returns false (probe refuses the unbound socket).
#   * clean_stale removes both artifacts so the next start is fresh.
daemon_socket_listener_false_positive_liveness() {
  local pid_file socket_path bridge_id helper helper_out alive_pid

  : "${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:=$SMOKE_TMP_ROOT/daemon-socket-runtime-fp}"
  export BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT
  bridge_id="$(python3 "$SMOKE_REPO_ROOT/bridge-queue-gateway.py" print-runtime-id --bridge-home "$BRIDGE_HOME")"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket-fp.pid"
  socket_path="$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT/$bridge_id/queue-gateway-fp.sock"
  mkdir -p "$BRIDGE_STATE_DIR" "$(dirname "$socket_path")"

  # The smoke runner's own pid: indisputably alive, indisputably not
  # the queue gateway listener. This is the "recycled-pid" fixture.
  alive_pid="$$"
  printf '%s\n' "$alive_pid" >"$pid_file"

  # Materialize a real Unix socket file with NO listener (bind+close
  # leaves the file on disk; connect() will return ECONNREFUSED).
  python3 - "$socket_path" <<'PY' >/dev/null
import os, socket, sys
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.bind(p)
s.close()
PY
  [[ -S "$socket_path" ]] || smoke_fail "false-positive liveness: pre-condition — bound socket should exist on disk"
  kill -0 "$alive_pid" 2>/dev/null || smoke_fail "false-positive liveness: pre-condition — fixture pid must be alive"

  helper="$SMOKE_TMP_ROOT/false-positive-liveness-driver.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nPID_FILE="$1"\nSOCKET_PATH="$2"\n'
    awk '/^bridge_queue_gateway_socket_pid_file\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_pid\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_connect_probe\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_probe_persistently_dead\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_is_running\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_clean_stale\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    cat <<'BASH'
bridge_queue_gateway_socket_pid_file() { printf "%s" "$PID_FILE"; }
bridge_queue_gateway_socket_path() { printf "%s" "$SOCKET_PATH"; }
# r3: with alive pid + leftover socket but NO bound listener, the
# connect-probe must refuse and is_running must return false.
if bridge_queue_gateway_socket_is_running; then
  echo "false-positive: is_running incorrectly returned true"
  exit 1
fi
# clean_stale must drop both artifacts (alive pid is unrelated; we do
# NOT signal it).
bridge_queue_gateway_socket_clean_stale
if [[ -f "$PID_FILE" ]]; then
  echo "false-positive: pid file not removed"
  exit 1
fi
if [[ -e "$SOCKET_PATH" ]]; then
  echo "false-positive: socket file not removed"
  exit 1
fi
echo "ok"
BASH
  } >"$helper"
  chmod +x "$helper"
  helper_out="$(bash "$helper" "$pid_file" "$socket_path" 2>&1 || true)"
  smoke_assert_contains "$helper_out" "ok" "false-positive liveness: connect-probe rejects alive-but-unrelated pid + leftover socket"

  # The unrelated alive pid (the smoke runner) MUST still be alive —
  # confirms clean_stale did not signal it.
  kill -0 "$alive_pid" 2>/dev/null || smoke_fail "false-positive liveness: clean_stale must NOT signal an unrelated alive pid"
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
  smoke_run "acl default inheritance" daemon_acl_default_inheritance
  # Socket listener is Linux-only fail-closed (SO_PEERCRED). Skip on
  # non-Linux so the daemon smoke stays green on operator workstations.
  if smoke_is_linux; then
    smoke_run "queue gateway socket listener lifecycle" daemon_socket_listener_contract
    smoke_run "queue gateway socket listener loop restart" daemon_socket_listener_loop_restart
    smoke_run "queue gateway socket listener stale recovery" daemon_socket_listener_stale_recovery
    smoke_run "queue gateway socket listener false-positive liveness" daemon_socket_listener_false_positive_liveness
  else
    smoke_skip "queue gateway socket listener lifecycle" "non-Linux"
    smoke_skip "queue gateway socket listener loop restart" "non-Linux"
    smoke_skip "queue gateway socket listener stale recovery" "non-Linux"
    smoke_skip "queue gateway socket listener false-positive liveness" "non-Linux"
  fi
  smoke_log "passed"
}

main "$@"
