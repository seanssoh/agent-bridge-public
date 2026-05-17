#!/usr/bin/env bash
# scripts/smoke/daemon-tick-guards-helpers/tick-guard-driver.sh — issue #946 L2+L4 smoke driver.
#
# Standalone driver invoked by scripts/smoke/daemon-tick-guards-l2-l4.sh.
# Extracted to a separate file (rather than written inline via heredoc)
# to dodge the Bash 5.3.9 heredoc-write deadlock class documented in
# CLAUDE.md footgun #11 (cf. lib/upgrade-helpers/ for the bridge-upgrade
# precedent).
#
# Subcommands (selected via argv[1]):
#
#   l2_value_with_timeout <secs> <label> <agent> <default> <fn> [fn-args...]
#       Exercises a carbon-copy of bridge-daemon.sh's
#       _bridge_heartbeat_value_with_timeout helper. Tests pass fn-name +
#       args; the helper bounds execution with a per-call deadline and
#       returns either the function's stdout or the sentinel <default>.
#       On timeout it writes a [L2] line to BRIDGE_DAEMON_CRASH_LOG and a
#       daemon_heartbeat_helper_timeout audit row to BRIDGE_AUDIT_LOG.
#
#   l4_nudge_scan
#       Exercises a carbon-copy of bridge-daemon.sh's nudge_scan branch
#       (the L4 region around line 6022). TEST_WRITER_RC=0 makes the
#       stub bridge_write_idle_ready_agents succeed; non-zero forces the
#       skip path. Prints whatever bridge_task_daemon_step returned
#       (empty string on the skip path).
#
# Environment expected on entry:
#   BRIDGE_REPO_ROOT, BRIDGE_HOME, BRIDGE_STATE_DIR, BRIDGE_LOG_DIR,
#   BRIDGE_SHARED_DIR, BRIDGE_AUDIT_LOG, BRIDGE_SCRIPT_DIR, BRIDGE_LAYOUT,
#   BRIDGE_DATA_ROOT.
# Optional: TEST_WRITER_RC (l4_nudge_scan only).

set -uo pipefail
SCRIPT_DIR="${BRIDGE_REPO_ROOT:?}"
# shellcheck source=/dev/null
source "$BRIDGE_REPO_ROOT/bridge-lib.sh"

# BRIDGE_DAEMON_CRASH_LOG is referenced by daemon_log_event. The smoke
# harness directs it to the per-test BRIDGE_LOG_DIR.
BRIDGE_DAEMON_CRASH_LOG="${BRIDGE_LOG_DIR}/daemon-crash.log"
mkdir -p "$BRIDGE_LOG_DIR"
[[ -f "$BRIDGE_DAEMON_CRASH_LOG" ]] || : >"$BRIDGE_DAEMON_CRASH_LOG"

daemon_log_event() {
  local message="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  mkdir -p "$BRIDGE_STATE_DIR"
  printf '[%s] %s\n' "$timestamp" "$message" >>"$BRIDGE_DAEMON_CRASH_LOG"
}

# --- carbon-copy of bridge-daemon.sh L2 helper -----------------------------
# Keep in sync with bridge-daemon.sh _bridge_heartbeat_value_with_timeout
# (the smoke's step_in_source_wiring_present check asserts the production
# helper exists; this driver mirrors its behavior so the smoke can drive
# it without bringing up the full sync_cycle dependency stack).
_bridge_heartbeat_value_with_timeout() {
  local secs="$1"
  local label="$2"
  local agent="$3"
  local default="$4"
  shift 4
  if [[ ! "$secs" =~ ^[0-9]+$ ]] || (( secs == 0 )); then
    secs=5
  fi
  local stdout_file
  stdout_file="$(mktemp 2>/dev/null)" || stdout_file=""
  if [[ -z "$stdout_file" ]]; then
    daemon_log_event "[L2] heartbeat helper '${label}' for agent '${agent}': mktemp failed; substituting sentinel '${default}' (refs #946)"
    printf '%s' "$default"
    return 0
  fi
  ( "$@" >"$stdout_file" 2>/dev/null ) &
  local pid=$!
  local i=0
  local poll_max=$(( secs * 10 ))
  while (( i < poll_max )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    daemon_log_event "[L2] heartbeat helper '${label}' for agent '${agent}' timed out at ${secs}s; substituting sentinel '${default}' (refs #946)"
    bridge_audit_log daemon daemon_heartbeat_helper_timeout daemon \
      --detail call_site="heartbeat_${label}" \
      --detail agent="$agent" \
      --detail timeout_seconds="$secs" \
      --detail sentinel="$default" \
      2>/dev/null || true
    rm -f -- "$stdout_file"
    printf '%s' "$default"
    return 0
  fi
  local rc=0
  wait "$pid" && rc=0 || rc=$?
  if (( rc != 0 )); then
    daemon_log_event "[L2] heartbeat helper '${label}' for agent '${agent}' exited rc=${rc}; substituting sentinel '${default}' (refs #946)"
    rm -f -- "$stdout_file"
    printf '%s' "$default"
    return 0
  fi
  cat -- "$stdout_file" 2>/dev/null || printf '%s' "$default"
  rm -f -- "$stdout_file"
  return 0
}

# Test stubs — fast-success and forever-sleep — to drive the helper.
_test_fast_success() {
  printf '%s' "fast-value"
}
_test_sleep_forever() {
  sleep 60
}

# --- L4 nudge-scan harness --------------------------------------------------
# Carbon-copy of the L4 branch in bridge-daemon.sh:6022. Stubs
# bridge_write_idle_ready_agents (rc controlled by TEST_WRITER_RC) and
# spies on bridge_task_daemon_step via a per-process call counter.

_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL=0
_TEST_BRIDGE_TASK_DAEMON_STEP_CALLS=0

bridge_write_agent_snapshot() { : ; }
bridge_task_daemon_step() {
  _TEST_BRIDGE_TASK_DAEMON_STEP_CALLS=$(( _TEST_BRIDGE_TASK_DAEMON_STEP_CALLS + 1 ))
  printf 'agent\tsession\t0\t0\t0\tkey\n'
}
bridge_write_idle_ready_agents() {
  return "${TEST_WRITER_RC:-0}"
}

_test_nudge_scan_branch() {
  local snapshot_file ready_agents_file
  snapshot_file="$(mktemp)"
  ready_agents_file="$(mktemp)"
  bridge_write_agent_snapshot "$snapshot_file"
  local nudge_output=""
  if bridge_write_idle_ready_agents "$ready_agents_file"; then
    _BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL=0
    nudge_output="$(bridge_task_daemon_step "$snapshot_file" "$ready_agents_file" 2>/dev/null || true)"
  else
    _BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL=$(( _BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL + 1 ))
    bridge_audit_log daemon daemon_step_warning daemon \
      --detail step="nudge_scan_idle_ready" \
      --detail reason="bridge_write_idle_ready_agents non-zero (matrix not applied or writer error)" \
      --detail consecutive_failures="$_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL" \
      --detail action="skip_bridge_task_daemon_step" \
      2>/dev/null || true
    daemon_log_event "[L4] nudge_scan: idle_ready writer failed (consec=${_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL}); skipping bridge_task_daemon_step this tick (refs #946, matrix-aware #781)"
  fi
  rm -f "$snapshot_file" "$ready_agents_file"
  printf '%s' "$nudge_output"
}

case "${1:-}" in
  l2_value_with_timeout)
    shift
    _bridge_heartbeat_value_with_timeout "$@"
    ;;
  l4_nudge_scan)
    shift
    _test_nudge_scan_branch "$@"
    ;;
  *)
    echo "unknown subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
