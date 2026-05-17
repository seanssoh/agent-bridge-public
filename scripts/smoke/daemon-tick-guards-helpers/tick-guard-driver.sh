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
#
# PR #952 r2 P2 #2: recursive descendant kill. Mirrors
# _bridge_kill_proc_tree in bridge-daemon.sh — kills the entire descendant
# tree so a python3/tmux grandchild does not leak as an orphan.
#
# PR #952 r3 P2 #1: pgrep failure escalation. Mirrors the production
# _bridge_enumerate_children — when pgrep returns exit ≥2 (macOS sandbox
# "Cannot get process list", /proc unreadable, etc.), fall back to
# parsing `ps -A -o pid,ppid` so the wedged helper's grandchildren are
# still discovered and killed.
_bridge_enumerate_children() {
  local parent_pid="$1"
  local pgrep_out pgrep_rc=0
  pgrep_out="$(pgrep -P "$parent_pid" 2>/dev/null)" || pgrep_rc=$?
  if (( pgrep_rc == 0 )) || (( pgrep_rc == 1 )); then
    [[ -n "$pgrep_out" ]] && printf '%s\n' "$pgrep_out"
    return 0
  fi
  local line child_pid child_ppid
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    child_pid="${line%% *}"
    child_ppid="${line#* }"
    child_ppid="${child_ppid#"${child_ppid%%[![:space:]]*}"}"
    child_ppid="${child_ppid%% *}"
    [[ -z "$child_pid" || -z "$child_ppid" ]] && continue
    [[ "$child_pid" =~ ^[0-9]+$ && "$child_ppid" =~ ^[0-9]+$ ]] || continue
    if [[ "$child_ppid" == "$parent_pid" ]]; then
      printf '%s\n' "$child_pid"
    fi
  done < <(ps -A -o pid=,ppid= 2>/dev/null)
  return 0
}

_bridge_kill_proc_tree() {
  # PR #952 r4 P1: process-group kill is the primary mechanism. The
  # wrapper subshell is its own pgrp leader (the helper enables `set -m`
  # before forking), so a negative-pid kill reaches every descendant
  # without depending on pgrep / ps process-table access. Defensive
  # enumeration runs second and is a no-op when the pgrp kill succeeded.
  local root_pid="$1"
  local sig="${2:-TERM}"
  kill "-$sig" -- "-$root_pid" 2>/dev/null || true
  local children child
  children="$(_bridge_enumerate_children "$root_pid")"
  if [[ -n "$children" ]]; then
    for child in $children; do
      _bridge_kill_proc_tree "$child" "$sig"
    done
  fi
  kill "-$sig" "$root_pid" 2>/dev/null || true
}

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
  # PR #952 r4 P1: enable bash monitor mode just around the fork so the
  # wrapper subshell becomes its own process-group leader. Mirrors the
  # production helper.
  set -m
  ( set +m; "$@" >"$stdout_file" 2>/dev/null ) &
  local pid=$!
  set +m
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
    # PR #952 r2 P2 #2: recursive descendant kill (the production helper
    # does the same). Without this, a python3/tmux grandchild outlives
    # the timeout and writes its sentinel file after the parent already
    # returned the fallback — codex r1's leak.
    _bridge_kill_proc_tree "$pid" "TERM"
    sleep 0.5
    # r6 (codex PR #952 r5) — unconditional KILL escalation. A SIGTERM-
    # ignoring grandchild in the same process group survives the first
    # _bridge_kill_proc_tree TERM and the wrapper dying makes kill -0 false,
    # but the grandchild is still alive. SIGKILL is uncatchable so this
    # negative-PID KILL reaches it via the pgrp. Mirror production
    # bridge-daemon.sh exactly so the smoke catches the same class of
    # regression.
    _bridge_kill_proc_tree "$pid" "KILL"
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
  # Silence monitor-mode "Done" / "Terminated" job-completion notices
  # that bash prints to stderr (PR #952 r4 P1).
  wait "$pid" 2>/dev/null && rc=0 || rc=$?
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

# PR #952 r2 P2 #2 regression probe — a bash function that forks a python3
# child writing a sentinel file after 5s. The L2 helper must kill the
# python3 grandchild on timeout; if it survives, the sentinel file will
# appear in TEST_SENTINEL_FILE after the timeout fires and we return.
_test_spawn_python3_sentinel_writer() {
  local sentinel="${TEST_SENTINEL_FILE:?TEST_SENTINEL_FILE not set}"
  # Run the python3 child in the same process group as us (no setsid /
  # nohup). The parent function (this bash function) sleeps forever so the
  # L2 helper deadline must fire while the python3 child is still alive.
  # If the helper only kills the immediate subshell wrapper, the python3
  # child orphans into pid 1 and proceeds to write the sentinel — that is
  # exactly the leak codex flagged.
  python3 -c "
import time, sys
time.sleep(5)
with open(sys.argv[1], 'w') as f:
    f.write('survived')
" "$sentinel" &
  local child=$!
  # Parent blocks too so the L2 helper has both PIDs to clean up.
  wait "$child"
}

# --- L4 maintenance-mode probe ---------------------------------------------
# PR #952 r2 P2 #1: spy that records which mode the production-side
# fall-through invoked bridge_task_daemon_step with. The smoke asserts
# that on writer failure the maintenance-only mode was invoked (so the
# downstream cron-dedupe / lease-extend / blocked-task-aging work was NOT
# starved by the wedged writer).
_TEST_BRIDGE_TASK_DAEMON_STEP_MAINTENANCE_CALLS=0
_TEST_BRIDGE_TASK_DAEMON_STEP_FULL_CALLS=0

# --- L4 nudge-scan harness --------------------------------------------------
# Carbon-copy of the L4 branch in bridge-daemon.sh:6022. Stubs
# bridge_write_idle_ready_agents (rc controlled by TEST_WRITER_RC) and
# spies on bridge_task_daemon_step via a per-process call counter.

_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL=0
_TEST_BRIDGE_TASK_DAEMON_STEP_CALLS=0

bridge_write_agent_snapshot() { : ; }
# PR #952 r2 P2 #1: stub records whether the caller passed
# --maintenance-only (the writer-failure path) or invoked the full step
# (writer-success path). Writes the breadcrumb to TEST_STEP_SPY_FILE so
# the smoke can assert across separate driver invocations.
bridge_task_daemon_step() {
  _TEST_BRIDGE_TASK_DAEMON_STEP_CALLS=$(( _TEST_BRIDGE_TASK_DAEMON_STEP_CALLS + 1 ))
  local mode="full"
  if [[ "${1:-}" == "--maintenance-only" ]]; then
    mode="maintenance"
    _TEST_BRIDGE_TASK_DAEMON_STEP_MAINTENANCE_CALLS=$(( _TEST_BRIDGE_TASK_DAEMON_STEP_MAINTENANCE_CALLS + 1 ))
  else
    _TEST_BRIDGE_TASK_DAEMON_STEP_FULL_CALLS=$(( _TEST_BRIDGE_TASK_DAEMON_STEP_FULL_CALLS + 1 ))
  fi
  if [[ -n "${TEST_STEP_SPY_FILE:-}" ]]; then
    printf '%s\n' "$mode" >>"$TEST_STEP_SPY_FILE"
  fi
  if [[ "$mode" == "full" ]]; then
    printf 'agent\tsession\t0\t0\t0\tkey\n'
  fi
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
      --detail action="maintenance_only_skip_nudges" \
      2>/dev/null || true
    daemon_log_event "[L4] nudge_scan: idle_ready writer failed (consec=${_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL}); running daemon_step maintenance-only and skipping nudges this tick (refs #946 L4, PR #952 r2, matrix-aware #781)"
    # PR #952 r2 P2 #1: still invoke the step in maintenance-only mode so
    # the queue maintenance side-effects (lease, cron-dedup, blocked-task
    # aging) are not starved by a transient writer failure.
    bridge_task_daemon_step --maintenance-only "$snapshot_file" >/dev/null 2>&1 || true
  fi
  rm -f "$snapshot_file" "$ready_agents_file"
  printf '%s' "$nudge_output"
}

case "${1:-}" in
  l2_value_with_timeout)
    shift
    _bridge_heartbeat_value_with_timeout "$@"
    ;;
  l2_value_with_timeout_pythonchild)
    # PR #952 r2 P2 #2 probe: drive the helper with the python3-grandchild
    # spawner. The smoke asserts TEST_SENTINEL_FILE does NOT exist after
    # the timeout + settle window, proving the grandchild was reaped.
    shift
    _bridge_heartbeat_value_with_timeout "$1" "$2" "$3" "$4" _test_spawn_python3_sentinel_writer
    ;;
  l2_value_with_timeout_pgrep_broken)
    # PR #952 r3 P2 #1 probe: TEST_PGREP_BROKEN_PATH points at a directory
    # containing a stub pgrep that exits 3 (macOS sandbox failure). We
    # prepend it to PATH only AFTER the helper has been entered, so the
    # subshell child path lookup hits the stub. The smoke asserts that
    # the descendant python3 child still gets reaped — proving the ps
    # fallback discovered it after pgrep failed.
    shift
    if [[ -n "${TEST_PGREP_BROKEN_PATH:-}" ]]; then
      export PATH="${TEST_PGREP_BROKEN_PATH}:${PATH}"
    fi
    _bridge_heartbeat_value_with_timeout "$1" "$2" "$3" "$4" _test_spawn_python3_sentinel_writer
    ;;
  l2_value_with_timeout_pgrep_and_ps_broken)
    # PR #952 r4 P1 probe: TEST_BROKEN_PROCTABLE_PATH points at a
    # directory containing stubs for BOTH pgrep AND ps that exit non-zero
    # with "Operation not permitted" — this is the macOS sandbox /
    # restricted-container scenario codex r3 caught. With both
    # process-table primitives denied, descendant enumeration returns
    # the empty list. The r3 form would only reap the immediate wrapper
    # subshell and leak the python3 grandchild.
    #
    # r4 puts the wrapper in its own process group via `set -m` and
    # kills via negative-pid, which does NOT require process-table
    # access. The smoke asserts the python3 child sentinel never
    # appears, proving the pgrp kill reached the grandchild.
    shift
    if [[ -n "${TEST_BROKEN_PROCTABLE_PATH:-}" ]]; then
      export PATH="${TEST_BROKEN_PROCTABLE_PATH}:${PATH}"
    fi
    _bridge_heartbeat_value_with_timeout "$1" "$2" "$3" "$4" _test_spawn_python3_sentinel_writer
    ;;
  enumerate_children_pgrep_broken)
    # PR #952 r3 P2 #1 unit probe: exercise _bridge_enumerate_children
    # with a broken pgrep stub on PATH. Spawn a known child process
    # (sleep 30), then call the function and assert the child PID
    # appears in stdout — proving ps fallback works.
    shift
    if [[ -n "${TEST_PGREP_BROKEN_PATH:-}" ]]; then
      export PATH="${TEST_PGREP_BROKEN_PATH}:${PATH}"
    fi
    # Spawn child, capture PID, give kernel a moment to register it.
    sleep 30 &
    child_pid=$!
    sleep 0.2
    # Print "<my_pid> <child_pid> <enumeration_output>" so the smoke
    # can assert child_pid appears in enumeration output.
    echo "PARENT=$$"
    echo "CHILD=$child_pid"
    echo "ENUM_OUTPUT_BEGIN"
    _bridge_enumerate_children "$$"
    echo "ENUM_OUTPUT_END"
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
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
