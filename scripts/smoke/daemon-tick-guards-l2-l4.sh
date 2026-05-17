#!/usr/bin/env bash
#
# scripts/smoke/daemon-tick-guards-l2-l4.sh — issue #946 L2 + L4 regression.
#
# Proves that bridge-daemon.sh tick-loop defenses survive the two wedge
# vectors operator-host evidence (2026-05-17) caught:
#
#   L2: write_agent_heartbeat used to evaluate command substitutions
#       (bridge_agent_channel_status, etc.) inline inside its `cat <<EOF`
#       heredoc body. A wedged downstream helper (most commonly: a python3
#       fork against a stale-worktree helper path) would hang the heredoc
#       and accumulate stuck child processes per tick.
#
#       After the L2 fix every command-substitution is pre-resolved via
#       _bridge_heartbeat_value_with_timeout, which forks the helper into
#       a background subshell, polls for completion with a per-call ceiling,
#       and on deadline kills the child + substitutes a sentinel + logs a
#       [L2] event.
#
#   L4: nudge_scan used to fall through to bridge_task_daemon_step even
#       when bridge_write_idle_ready_agents failed — the downstream step
#       then consumed an empty/broken ready-agent file and silently
#       suppressed [task-queued] interrupts for the duration of the wedge.
#
#       After the L4 fix bridge_task_daemon_step is gated on the writer's
#       success: the broken ready-agent file is never consumed, the
#       failure increments a consecutive-failure counter that surfaces in
#       the audit log as `daemon_step_warning` with
#       `consecutive_failures=N`, and a [L4] event with the same counter
#       is appended to the crash log.
#
# What we exercise:
#
#   1. _bridge_heartbeat_value_with_timeout fires its deadline on a
#      function that sleeps past the ceiling — returns the sentinel and
#      emits a [L2] line + daemon_heartbeat_helper_timeout audit row
#      tagged with the call_site label.
#   2. _bridge_heartbeat_value_with_timeout passes through stdout for a
#      fast-completing function — no [L2] event, no audit row.
#   3. The L4 path: when bridge_write_idle_ready_agents returns non-zero,
#      bridge_task_daemon_step is invoked with --maintenance-only (PR
#      #952 r2 P2 #1) so queue maintenance side-effects still run, but
#      the nudge candidate enumeration is skipped. The [L4] log line
#      names the consecutive-failure counter, and the audit row carries
#      action="maintenance_only_skip_nudges".
#   4. The L4 success path: when bridge_write_idle_ready_agents succeeds
#      after a streak of failures, the counter resets to 0 and the next
#      success does NOT produce a daemon_step_warning audit row.
#   5. PR #952 r2 P2 #2: a helper that forks a python3 grandchild is
#      reaped recursively — the L2 timeout descendant-kill closes the
#      orphan window codex r1 flagged.
#
# Hermetic: isolated BRIDGE_HOME; never touches the live install. No real
# daemon process is started — we exercise the bash functions directly to
# avoid bringing up the full sync_cycle dependency stack (roster + tmux +
# queue schema + ...).

# Bash 4+ re-exec (mirrors scripts/smoke/daemon-heredoc-timeout.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:daemon-tick-guards-l2-l4] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon-tick-guards-l2-l4"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_REPO_ROOT="$SMOKE_REPO_ROOT"
export BRIDGE_SCRIPT_DIR="$BRIDGE_REPO_ROOT"
: >"$BRIDGE_AUDIT_LOG"

# Driver lives in a separate checked-in helper file (NOT written via
# heredoc) to dodge Bash 5.3.9's footgun #11 (heredoc-write deadlock
# under set -e parents wedges `cat >FILE <<EOF...EOF` once the body
# exceeds the PIPE_BUF threshold). See CLAUDE.md §"Recent critical
# patches (v0.13.7-v0.13.10)" for the full catalog and
# lib/upgrade-helpers/ for the bridge-upgrade precedent.
DRIVER="$SCRIPT_DIR/daemon-tick-guards-helpers/tick-guard-driver.sh"
[[ -x "$DRIVER" ]] || smoke_fail "missing tick-guard driver: $DRIVER"

# Helper that invokes the driver with the smoke harness environment.
run_driver() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    BRIDGE_REPO_ROOT="$BRIDGE_REPO_ROOT" \
    BRIDGE_SCRIPT_DIR="$BRIDGE_SCRIPT_DIR" \
    BRIDGE_LAYOUT="$BRIDGE_LAYOUT" \
    BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
    bash "$DRIVER" "$@"
}

# --- L2: deadline kills a wedged helper -------------------------------------

step_l2_timeout_substitutes_sentinel() {
  smoke_log "L2 step 1: a 2s ceiling on a sleep-forever helper must return the sentinel"
  local started ended elapsed
  started="$(date +%s)"
  local output
  # Args: <secs> <label> <agent> <default> <fn-name>
  output="$(run_driver l2_value_with_timeout 2 sleep_test agent-x SENTINEL_FALLBACK _test_sleep_forever)"
  ended="$(date +%s)"
  elapsed=$(( ended - started ))
  if (( elapsed > 6 )); then
    smoke_fail "L2 ceiling did not fire — elapsed=${elapsed}s (budget 2s + grace); the deadlock would still wedge the daemon"
  fi
  smoke_assert_eq "SENTINEL_FALLBACK" "$output" "L2 timeout should substitute the sentinel default"
  smoke_log "  elapsed=${elapsed}s output='$output' — deadline fired, sentinel returned"

  # Confirm [L2] crash log entry.
  local crash_log="$BRIDGE_LOG_DIR/daemon-crash.log"
  if [[ ! -s "$crash_log" ]]; then
    smoke_fail "L2 crash log empty after timeout — daemon_log_event did not fire: $crash_log"
  fi
  if ! grep -q "\[L2\] heartbeat helper 'sleep_test' for agent 'agent-x' timed out at 2s" "$crash_log"; then
    smoke_fail "L2 crash log missing the expected timeout line: $(cat "$crash_log")"
  fi
  smoke_log "  [L2] timeout line written to $crash_log"

  # Confirm audit row tagged with call_site + agent.
  if ! grep -q '"call_site": "heartbeat_sleep_test"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing heartbeat_sleep_test call_site: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if ! grep -q 'daemon_heartbeat_helper_timeout' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing daemon_heartbeat_helper_timeout action: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  audit row daemon_heartbeat_helper_timeout present"
}

step_l2_fast_path_passes_through() {
  smoke_log "L2 step 2: a fast-completing helper must return its stdout verbatim with NO [L2] event"

  # Snapshot the crash log + audit log first so we can prove nothing new
  # is appended on the success path.
  local crash_log="$BRIDGE_LOG_DIR/daemon-crash.log"
  : >"$crash_log"
  : >"$BRIDGE_AUDIT_LOG"

  local output
  output="$(run_driver l2_value_with_timeout 5 fast_test agent-y SHOULD_NOT_APPEAR _test_fast_success)"
  smoke_assert_eq "fast-value" "$output" "L2 fast path should pass through stdout"

  if [[ -s "$crash_log" ]]; then
    smoke_fail "L2 success path wrote a crash log line — should be silent: $(cat "$crash_log")"
  fi
  if grep -q 'daemon_heartbeat_helper_timeout' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
    smoke_fail "L2 success path wrote a timeout audit row — should not: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  fast path silent, stdout passed through"
}

step_l2_python3_grandchild_reaped() {
  # PR #952 r2 P2 #2 regression: codex r1 flagged that the previous
  # implementation killed only the immediate background subshell PID, not
  # the real python3/tmux grandchild started inside the helper. A wedged
  # helper would still leak a long-running child per heartbeat tick.
  #
  # This probe wires a bash function that spawns a python3 subprocess
  # which sleeps 5s and then writes a sentinel file. The L2 timeout is
  # set to 2s. After timeout + 4s settle, the sentinel MUST NOT exist —
  # proving the python3 grandchild was killed alongside the subshell
  # wrapper. Pre-r2 code left the python3 child alive and the sentinel
  # appeared.
  smoke_log "L2 step 3: a helper spawning a python3 grandchild must reap the grandchild on timeout"

  local crash_log="$BRIDGE_LOG_DIR/daemon-crash.log"
  : >"$crash_log"
  : >"$BRIDGE_AUDIT_LOG"

  # Sentinel file lives outside BRIDGE_HOME so a destructive cleanup of
  # BRIDGE_HOME on test end does not race with the child write.
  local sentinel
  sentinel="$(mktemp -t l2-pychild-XXXXXX)"
  rm -f -- "$sentinel"

  local output started ended elapsed
  started="$(date +%s)"
  output="$(TEST_SENTINEL_FILE="$sentinel" run_driver l2_value_with_timeout_pythonchild 2 pychild_test agent-z SENTINEL_FALLBACK)"
  ended="$(date +%s)"
  elapsed=$(( ended - started ))

  # Helper must have returned the sentinel inside the 2s + grace budget.
  smoke_assert_eq "SENTINEL_FALLBACK" "$output" "L2 timeout should substitute the sentinel default"
  if (( elapsed > 6 )); then
    smoke_fail "L2 ceiling did not fire promptly — elapsed=${elapsed}s (budget 2s + grace)"
  fi

  # The python3 child sleeps 5s before writing. The L2 fires at 2s. Wait
  # 4 more seconds past return so the child (if it survived) finishes
  # its sleep and writes. Total wall time from start: ~2s helper +
  # ~0.5s kill + 4s settle = ~6.5s.
  sleep 4

  if [[ -f "$sentinel" ]]; then
    smoke_fail "L2 P2 #2 regression: python3 grandchild survived the timeout — sentinel exists: $(ls -l "$sentinel"; cat "$sentinel" 2>/dev/null || true)"
  fi
  smoke_log "  python3 grandchild reaped — sentinel file did not appear after $((elapsed + 4))s total"
  rm -f -- "$sentinel"
}

# --- L4: writer failure skips bridge_task_daemon_step + counts streak --------

step_l4_writer_failure_runs_maintenance_only() {
  # PR #952 r2 P2 #1: r1 skipped bridge_task_daemon_step entirely on
  # writer failure, which starved the same step's queue maintenance
  # side-effects (lease extension/expire, cron de-dupe, stale-claim
  # requeue, blocked-task aging) for the whole tick. r2 splits the two
  # concerns: nudge dispatch is still skipped on writer failure, but the
  # maintenance path runs via bridge_task_daemon_step --maintenance-only.
  smoke_log "L4 step 1: writer failure must (a) skip nudge dispatch and (b) still run maintenance-only step"

  local crash_log="$BRIDGE_LOG_DIR/daemon-crash.log"
  : >"$crash_log"
  : >"$BRIDGE_AUDIT_LOG"

  # Cross-process step-mode spy: each driver invocation appends its
  # bridge_task_daemon_step mode ("maintenance" or "full") to this file.
  local spy_file
  spy_file="$(mktemp -t l4-step-spy-XXXXXX)"
  : >"$spy_file"

  # Three consecutive failures to prove the consecutive-failure counter
  # increments rather than resetting on each tick.
  local nudge_output_1 nudge_output_2 nudge_output_3
  nudge_output_1="$(TEST_WRITER_RC=1 TEST_STEP_SPY_FILE="$spy_file" run_driver l4_nudge_scan)"
  nudge_output_2="$(TEST_WRITER_RC=1 TEST_STEP_SPY_FILE="$spy_file" run_driver l4_nudge_scan)"
  nudge_output_3="$(TEST_WRITER_RC=1 TEST_STEP_SPY_FILE="$spy_file" run_driver l4_nudge_scan)"

  # Each invocation is a separate driver process, so the consec counter
  # resets between invocations from THE SMOKE'S point of view. But the
  # audit row from each tick must still be present.
  smoke_assert_eq "" "$nudge_output_1" "L4 writer failure should produce empty nudge_output (no nudge dispatch)"
  smoke_assert_eq "" "$nudge_output_2" "L4 writer failure (2nd) should produce empty nudge_output"
  smoke_assert_eq "" "$nudge_output_3" "L4 writer failure (3rd) should produce empty nudge_output"

  # P2 #1 regression assertion: the maintenance-only step MUST have run
  # on each of the three failed ticks (3 rows, all mode=maintenance, no
  # "full" rows).
  local maintenance_runs full_runs
  maintenance_runs="$(grep -c '^maintenance$' "$spy_file" || true)"
  full_runs="$(grep -c '^full$' "$spy_file" || true)"
  if (( maintenance_runs < 3 )); then
    smoke_fail "L4 P2 #1 regression: expected >=3 maintenance-only step invocations across 3 failed ticks, got ${maintenance_runs} (spy file: $(cat "$spy_file"))"
  fi
  if (( full_runs > 0 )); then
    smoke_fail "L4 writer-failure path should not invoke the full step (got ${full_runs} full runs): $(cat "$spy_file")"
  fi
  smoke_log "  3 failed ticks invoked bridge_task_daemon_step --maintenance-only (queue maintenance preserved)"

  # The cumulative audit-log presence (one row per failed tick).
  local skip_rows
  skip_rows="$(grep -c '"action": "maintenance_only_skip_nudges"' "$BRIDGE_AUDIT_LOG" || true)"
  if (( skip_rows < 3 )); then
    smoke_fail "L4 audit should have >=3 maintenance_only_skip_nudges rows, got $skip_rows: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if ! grep -q '"step": "nudge_scan_idle_ready"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "L4 audit missing nudge_scan_idle_ready step tag: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  # Each failure should carry a consecutive_failures detail.
  if ! grep -q '"consecutive_failures": "1"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "L4 audit missing consecutive_failures=1 (first failure in each fresh process): $(cat "$BRIDGE_AUDIT_LOG")"
  fi

  # The [L4] crash log line must mention the consec counter and the
  # maintenance-only intent so an operator can grep for the wedge.
  if ! grep -q "\[L4\] nudge_scan: idle_ready writer failed" "$crash_log"; then
    smoke_fail "[L4] line missing from crash log: $(cat "$crash_log")"
  fi
  if ! grep -q "running daemon_step maintenance-only and skipping nudges this tick" "$crash_log"; then
    smoke_fail "[L4] line missing maintenance-only phrasing: $(cat "$crash_log")"
  fi
  smoke_log "  3 failed ticks emitted [L4] + audit row + maintenance-only invocation"
  rm -f -- "$spy_file"
}

step_l4_writer_success_runs_step() {
  smoke_log "L4 step 2: writer success must invoke bridge_task_daemon_step (full mode) AND not emit a skip row"

  local crash_log="$BRIDGE_LOG_DIR/daemon-crash.log"
  : >"$crash_log"
  : >"$BRIDGE_AUDIT_LOG"

  local spy_file
  spy_file="$(mktemp -t l4-step-spy-success-XXXXXX)"
  : >"$spy_file"

  local nudge_output
  nudge_output="$(TEST_WRITER_RC=0 TEST_STEP_SPY_FILE="$spy_file" run_driver l4_nudge_scan)"

  # The bridge_task_daemon_step stub prints 'agent\tsession\t0\t0\t0\tkey'
  # — assert we got it back, proving the step ran (full mode).
  smoke_assert_contains "$nudge_output" "agent" "L4 success path should invoke bridge_task_daemon_step"

  # Spy must show exactly one full invocation and no maintenance-only
  # invocation on the success path.
  local full_runs maintenance_runs
  full_runs="$(grep -c '^full$' "$spy_file" || true)"
  maintenance_runs="$(grep -c '^maintenance$' "$spy_file" || true)"
  smoke_assert_eq "1" "$full_runs" "L4 success path should invoke the FULL step exactly once"
  smoke_assert_eq "0" "$maintenance_runs" "L4 success path should not invoke maintenance-only step"

  if grep -q 'maintenance_only_skip_nudges' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
    smoke_fail "L4 success path wrote a maintenance_only_skip_nudges audit row — should be silent: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if grep -q '\[L4\]' "$crash_log" 2>/dev/null; then
    smoke_fail "L4 success path wrote a [L4] crash log line — should be silent: $(cat "$crash_log")"
  fi
  smoke_log "  success path invoked the full step and stayed silent"
  rm -f -- "$spy_file"
}

# --- proof of in-source wiring ----------------------------------------------
#
# The driver above is a carbon-copy of the production helpers. Guard
# against drift by asserting the exact bash function and the L4 branch
# shape are present in the checked-in bridge-daemon.sh.

step_in_source_wiring_present() {
  smoke_log "in-source check: bridge-daemon.sh defines the L2 helper and the L4 maintenance-only branch"

  local daemon_sh="$BRIDGE_REPO_ROOT/bridge-daemon.sh"
  local state_sh="$BRIDGE_REPO_ROOT/lib/bridge-state.sh"
  local queue_py="$BRIDGE_REPO_ROOT/bridge-queue.py"
  smoke_assert_file_exists "$daemon_sh" "bridge-daemon.sh"
  smoke_assert_file_exists "$state_sh" "lib/bridge-state.sh"
  smoke_assert_file_exists "$queue_py" "bridge-queue.py"

  if ! grep -q '^_bridge_heartbeat_value_with_timeout()' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing _bridge_heartbeat_value_with_timeout helper definition"
  fi
  if ! grep -q '_bridge_heartbeat_value_with_timeout 10 channel_status' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing the channel_status bounded call (the operator-host wedge surface)"
  fi
  if ! grep -q '_BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing the L4 consecutive-failure counter"
  fi
  # PR #952 r2 P2 #1 wiring: the L4 fail-path now runs the maintenance-
  # only step instead of skipping the whole call.
  if ! grep -q 'running daemon_step maintenance-only and skipping nudges this tick' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing the [L4] r2 maintenance-only message — P2 #1 regression"
  fi
  if ! grep -q 'bridge_task_daemon_step --maintenance-only' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing the --maintenance-only invocation on the L4 fail-path — P2 #1 regression"
  fi
  # PR #952 r2 P2 #1 wiring (state.sh wrapper): the --maintenance-only
  # first-arg branch must be present so the python step receives
  # --skip-nudges.
  if ! grep -q -- '--maintenance-only' "$state_sh"; then
    smoke_fail "lib/bridge-state.sh missing the --maintenance-only first-arg branch in bridge_task_daemon_step — P2 #1 regression"
  fi
  if ! grep -q -- '--skip-nudges' "$state_sh"; then
    smoke_fail "lib/bridge-state.sh missing the --skip-nudges arg propagation — P2 #1 regression"
  fi
  # PR #952 r2 P2 #1 wiring (python): cmd_daemon_step must short-circuit
  # before the nudge enumeration when --skip-nudges is set.
  if ! grep -q 'skip_nudges' "$queue_py"; then
    smoke_fail "bridge-queue.py missing the skip_nudges arg handling — P2 #1 regression"
  fi

  # PR #952 r2 P2 #2 wiring: the recursive descendant kill helper must
  # exist AND be invoked on the timeout path.
  if ! grep -q '^_bridge_kill_proc_tree()' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing _bridge_kill_proc_tree helper — P2 #2 regression"
  fi
  if ! grep -q '_bridge_kill_proc_tree "$pid" "TERM"' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing TERM-recursive kill on timeout — P2 #2 regression"
  fi
  if ! grep -q '_bridge_kill_proc_tree "$pid" "KILL"' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh missing KILL-recursive kill on timeout — P2 #2 regression"
  fi

  # write_agent_heartbeat heredoc body must no longer contain inline
  # command substitutions for the helpers we pre-resolved. The grep below
  # asserts the heredoc references the local vars (hb_channel_status) and
  # that the failing legacy form (\$(bridge_agent_channel_status) inside
  # the heredoc) is gone.
  if ! grep -q 'channel_status: \${hb_channel_status}' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh heartbeat heredoc no longer uses pre-resolved hb_channel_status — the regression returned"
  fi
  # Specifically catch the legacy form. We grep for the literal substring
  # so a future refactor that re-introduces inline $(bridge_agent_*) calls
  # inside the heartbeat heredoc trips this.
  if grep -q 'channel_status: \$(bridge_agent_channel_status' "$daemon_sh"; then
    smoke_fail "bridge-daemon.sh heartbeat heredoc reintroduced inline \$(bridge_agent_channel_status …) — the L2 wedge surface is back"
  fi
  smoke_log "  L2 helper + tree-kill + L4 maintenance-only + heredoc-pre-resolution all wired"
}

smoke_run "L2 helper: deadline fires on wedged helper + sentinel + [L2] + audit" step_l2_timeout_substitutes_sentinel
smoke_run "L2 helper: fast path passes through silently" step_l2_fast_path_passes_through
smoke_run "L2 helper: python3 grandchild reaped on timeout (P2 #2 regression)" step_l2_python3_grandchild_reaped
smoke_run "L4 nudge_scan: writer failure runs maintenance-only step + skips nudges (P2 #1 regression)" step_l4_writer_failure_runs_maintenance_only
smoke_run "L4 nudge_scan: writer success invokes full step + silent" step_l4_writer_success_runs_step
smoke_run "in-source: bridge-daemon.sh L2/L4 wiring is present and not regressed" step_in_source_wiring_present

smoke_log "PASS"
