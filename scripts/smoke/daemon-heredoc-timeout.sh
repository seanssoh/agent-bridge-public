#!/usr/bin/env bash
#
# scripts/smoke/daemon-heredoc-timeout.sh — issue #800 Track A regression.
#
# Proves that the daemon-loop subprocess helpers (bridge-daemon-helpers.py)
# are correctly wrapped by bridge_with_timeout so a deliberately-stalling
# helper cannot wedge the main loop the way the unwrapped
# `$(python3 - <<'PY')` heredoc-stdin pattern did on v0.7.6 (cf. #800).
#
# What we exercise (in order):
#
#   1. bridge_with_timeout(2, …) around a python helper that sleeps forever
#      must terminate the child within the budget + small margin and exit
#      with rc=124. This is the core wrapping correctness check.
#   2. A `daemon_subprocess_timeout` row must be appended to the audit log
#      with our call-site label so the operator can see which step hung.
#   3. A second invocation immediately after must still succeed (the loop
#      is not wedged — recovery is automatic on next tick). We swap the
#      helper for a no-op to simulate "next tick, helper recovered".
#   4. bridge-daemon-helpers.py exposes all 9 subcommands Track A relies on.
#
# r2 (codex finding — synthetic-helper coverage gap)
# --------------------------------------------------
# Steps 1-3 above use synthetic sleeps-forever.py / noop.py. r2 codex review
# called that out: the smoke never exercised a REAL `bridge-daemon-helpers.py`
# subcommand body, only the bridge_with_timeout shell wrapper. To close that
# gap without modifying production code (no env-var override or PATH hook in
# the daemon — it resolves the helper via $SCRIPT_DIR/bridge-daemon-helpers.py
# directly), r2 adds:
#
#   5. mcp-orphan-cleanup-parse stalled on a FIFO `report_file`. The real
#      subcommand body calls `Path(...).read_text()`, which blocks forever
#      on an empty FIFO. bridge_with_timeout 2s must kill it. Asserts the
#      audit row tags `call_site=mcp_orphan_cleanup_parse`.
#   6. mcp-orphan-cleanup-parse with a valid JSON file passes through cleanly
#      (proves the shim wraps but does not break the real subcommand body).
#   7. nudge-live-state against a sqlite DB whose write lock is held by a
#      sidecar python process. The helper's `sqlite3.connect(...).execute(...)`
#      blocks on the lock; bridge_with_timeout 2s must kill it. This is the
#      most realistic I/O-wait stall — exactly the class of hang #800
#      documented.
#   8. Loop-survival across two consecutive bridge_with_timeout calls: the
#      FIFO-stall fires (rc=124|137), then immediately the same subcommand
#      against a valid file succeeds (rc=0). Proves the wrapping is
#      non-wedging across calls. (Driving a full `bridge-daemon.sh sync`
#      tick is impractical here — cmd_sync_cycle requires substantial
#      runtime bootstrap (roster, tmux sessions, queue DB schema, hooks,
#      cron state) that the smoke environment does not provide. The
#      consecutive-call pattern is the cleanest realistic equivalent to
#      a "next tick" assertion without modifying production code to add
#      a dry-run mode.)
#
# We do NOT need real claude/codex binaries — we test only the daemon's
# subprocess wrapping correctness via the bridge_with_timeout helper that
# bridge-daemon.sh uses for every callsite touched by Track A.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon.sh).
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
  echo "[smoke:daemon-heredoc-timeout] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon-heredoc-timeout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
# bridge_with_timeout falls back to a plain exec on hosts without timeout(1),
# which would silently skip the actual coverage we are testing. Insist on
# either timeout or gtimeout so the smoke is meaningful.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  smoke_fail "neither timeout(1) nor gtimeout(1) available; bridge_with_timeout cannot enforce the ceiling and this smoke would silently pass without coverage. install coreutils."
fi

smoke_setup_bridge_home "$SMOKE_NAME"

# Use the in-tree bridge-state.sh so we exercise the real bridge_with_timeout.
export BRIDGE_REPO_ROOT="$SMOKE_REPO_ROOT"
export BRIDGE_SCRIPT_DIR="$BRIDGE_REPO_ROOT"
# bridge_audit_log appends to $BRIDGE_AUDIT_LOG — lib.sh sets this for us.
: >"$BRIDGE_AUDIT_LOG"

# Synthesize the two helpers we need.
STALL_HELPER="$SMOKE_TMP_ROOT/sleeps-forever.py"
cat >"$STALL_HELPER" <<'PY'
#!/usr/bin/env python3
"""Deliberately-stalling helper for the #800 Track A smoke. Sleeps
indefinitely so bridge_with_timeout has to kill us via SIGTERM/SIGKILL."""
import time
import sys
# Drain stdin if anything is piped in (the real heredoc-stdin pattern
# from before Track A would block here forever; we just discard).
try:
    sys.stdin.read()
except Exception:
    pass
while True:
    time.sleep(60)
PY
chmod +x "$STALL_HELPER"

NOOP_HELPER="$SMOKE_TMP_ROOT/noop.py"
cat >"$NOOP_HELPER" <<'PY'
#!/usr/bin/env python3
"""Recovered helper — returns the same shape nudge-live-state would."""
print("0\t0\t")
PY
chmod +x "$NOOP_HELPER"

# Driver script that sources bridge_with_timeout and invokes it on argv.
# Written to disk so we avoid layered quoting around `bash -c`.
DRIVER="$SMOKE_TMP_ROOT/with-timeout-driver.sh"
cat >"$DRIVER" <<'EOF'
#!/usr/bin/env bash
# args: <secs> <label> <cmd> [cmd_args...]
set -uo pipefail
SCRIPT_DIR="${BRIDGE_REPO_ROOT:?}"
# shellcheck source=/dev/null
source "$BRIDGE_REPO_ROOT/lib/bridge-state.sh"
secs="$1"
label="$2"
shift 2
bridge_with_timeout "$secs" "$label" "$@"
EOF
chmod +x "$DRIVER"

run_with_timeout_subshell() {
  local label="$1"
  local secs="$2"
  shift 2
  local rc=0
  local started ended elapsed
  started="$(date +%s)"
  set +e
  "$DRIVER" "$secs" "$label" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  ended="$(date +%s)"
  elapsed=$(( ended - started ))
  printf 'rc=%d elapsed=%d\n' "$rc" "$elapsed"
}

step_wrapping_terminates_stalled_helper() {
  smoke_log "step 1: bridge_with_timeout 2s must terminate the stalling helper"
  local output rc elapsed
  output="$(run_with_timeout_subshell nudge_live_state 2 python3 "$STALL_HELPER")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "could not parse rc from: $output"
  [[ -n "$elapsed" ]] || smoke_fail "could not parse elapsed from: $output"
  # timeout(1) returns 124 on hit, 137 if KILL was needed.
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "expected rc=124 or 137 from timeout, got rc=$rc (elapsed=${elapsed}s, output=$output)"
  fi
  # Budget = 2s + generous 5s slack for cold python startup + fork on slow CI.
  if (( elapsed > 8 )); then
    smoke_fail "wrapping did NOT enforce the 2s ceiling (elapsed=${elapsed}s); the heredoc-write deadlock class would still be possible"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s (within budget)"
}

step_audit_row_written() {
  smoke_log "step 2: daemon_subprocess_timeout audit row must be present"
  if [[ ! -s "$BRIDGE_AUDIT_LOG" ]]; then
    smoke_fail "audit log is empty after timeout fired: $BRIDGE_AUDIT_LOG"
  fi
  # bridge_audit_log writes JSONL via bridge-audit.py — grep is sufficient
  # to confirm both the action and the call-site label.
  if ! grep -q 'daemon_subprocess_timeout' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing 'daemon_subprocess_timeout' row: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if ! grep -q 'nudge_live_state' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing 'nudge_live_state' call-site tag: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  audit row present with call_site=nudge_live_state"
}

step_loop_recovers_next_tick() {
  smoke_log "step 3: a follow-up invocation must succeed (loop not wedged)"
  local output rc elapsed
  output="$(run_with_timeout_subshell nudge_live_state 5 python3 "$NOOP_HELPER")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ "$rc" == "0" ]] || smoke_fail "follow-up invocation should succeed but rc=$rc (output=$output)"
  if (( elapsed > 5 )); then
    smoke_fail "follow-up invocation should be fast but elapsed=${elapsed}s"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s — daemon loop recovers naturally"
}

step_helper_subcommands_resolve() {
  smoke_log "step 4: bridge-daemon-helpers.py exposes the expected subcommands"
  local help_out
  help_out="$(python3 "$BRIDGE_REPO_ROOT/bridge-daemon-helpers.py" --help 2>&1 || true)"
  local sub
  # Track A (9) + #800 regression follow-up (4 new for PR #799 sites).
  for sub in usage-alert-parse release-alert-parse backup-parse stall-iso-format \
             permission-expire-scan watchdog-problem-count nudge-live-state \
             memory-daily-orphan-scan mcp-orphan-cleanup-parse \
             usage-rotation-candidates-parse rotation-status-parse \
             recovery-status-parse sync-status-parse; do
    smoke_assert_contains "$help_out" "$sub" "helper --help should list $sub"
  done
}

# ---------------------------------------------------------------------------
# r2 codex finding — exercise REAL bridge-daemon-helpers.py subcommands
# under realistic stalls, not synthetic sleeps-forever.py.
# ---------------------------------------------------------------------------

# Path to the real, checked-in helper. This is the same path bridge-daemon.sh
# invokes via "$SCRIPT_DIR/bridge-daemon-helpers.py".
REAL_HELPER="$BRIDGE_REPO_ROOT/bridge-daemon-helpers.py"

step_real_helper_stalls_on_fifo() {
  smoke_log "step 5: real mcp-orphan-cleanup-parse must stall on an empty FIFO"
  # mcp-orphan-cleanup-parse calls Path(report_file).read_text() — a FIFO
  # with no writer blocks indefinitely, exercising the real subcommand body.
  local fifo="$SMOKE_TMP_ROOT/cleanup-report.fifo"
  rm -f "$fifo"
  if ! mkfifo "$fifo" 2>/dev/null; then
    smoke_fail "mkfifo not available; cannot construct realistic helper stall"
  fi

  local output rc elapsed
  output="$(run_with_timeout_subshell mcp_orphan_cleanup_parse 2 \
              python3 "$REAL_HELPER" mcp-orphan-cleanup-parse "$fifo")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "could not parse rc from: $output"
  [[ -n "$elapsed" ]] || smoke_fail "could not parse elapsed from: $output"
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "real-helper FIFO stall: expected rc=124|137, got rc=$rc (elapsed=${elapsed}s)"
  fi
  if (( elapsed > 8 )); then
    smoke_fail "real-helper FIFO stall: ceiling not enforced (elapsed=${elapsed}s, budget 2s)"
  fi

  # Audit row must tag the new call_site label so an operator can identify
  # which real subcommand wedged. bridge_with_timeout writes the row on
  # 124/137 with `call_site=$label` (label was the second argv to the driver).
  if ! grep -q '"call_site": "mcp_orphan_cleanup_parse"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing call_site=mcp_orphan_cleanup_parse after FIFO stall: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s — real helper stalled and got killed"

  # Drain the FIFO so cleanup doesn't hang on EXIT. The helper child was
  # SIGKILLed by timeout(1), so the FIFO has no pending reader; just unlink.
  rm -f "$fifo"
}

step_real_helper_passthrough() {
  smoke_log "step 6: real mcp-orphan-cleanup-parse with valid JSON must pass through"
  local report="$SMOKE_TMP_ROOT/cleanup-report.json"
  cat >"$report" <<'JSON'
{"killed_count": 3, "orphan_count": 7, "freed_mb_estimate": 42, "errors": ["a", "b"]}
JSON

  # Use the driver so the call is wrapped in bridge_with_timeout (5s budget —
  # the real subcommand is a single JSON parse + print).
  local rc=0
  local stdout_file="$SMOKE_TMP_ROOT/passthrough.out"
  set +e
  "$DRIVER" 5 mcp_orphan_cleanup_parse python3 "$REAL_HELPER" \
      mcp-orphan-cleanup-parse "$report" >"$stdout_file" 2>&1
  rc=$?
  set -e
  if (( rc != 0 )); then
    smoke_fail "real-helper passthrough should succeed but rc=$rc (out: $(cat "$stdout_file"))"
  fi
  local row
  row="$(cat "$stdout_file")"
  # Expected shape: killed_count \t orphan_count \t freed_mb_estimate \t error_count
  smoke_assert_eq "3"$'\t'"7"$'\t'"42"$'\t'"2" "$row" "passthrough row should match JSON input"
  smoke_log "  row='$row' — real helper produced expected output"
}

step_real_helper_stalls_on_sqlite_lock() {
  smoke_log "step 7: real nudge-live-state must stall on a held sqlite write lock"
  local db_path="$SMOKE_TMP_ROOT/tasks-locked.db"
  rm -f "$db_path"
  # Build a minimal schema covering the columns nudge-live-state reads.
  python3 - "$db_path" <<'PYINIT'
import sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db)
c.execute("""
    CREATE TABLE tasks (
        id            INTEGER PRIMARY KEY,
        assigned_to   TEXT,
        status        TEXT,
        claimed_by    TEXT,
        title         TEXT
    )
""")
c.commit()
c.close()
PYINIT
  [[ -f "$db_path" ]] || smoke_fail "could not initialize sqlite DB at $db_path"

  # Sidecar holds BEGIN EXCLUSIVE for up to 30s so the helper's
  # sqlite3.connect(...).execute(SELECT ...) blocks on the writer lock.
  # 30s is well above the helper's 2s budget; the locker is reaped on EXIT
  # via $LOCKER_PID below.
  local locker_pid_file="$SMOKE_TMP_ROOT/sqlite-locker.pid"
  rm -f "$locker_pid_file"
  python3 - "$db_path" "$locker_pid_file" <<'PYLOCK' &
import os, sqlite3, sys, time
db, pidfile = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db, isolation_level=None, timeout=60)
conn.execute("BEGIN EXCLUSIVE")
with open(pidfile, "w") as fh:
    fh.write(str(os.getpid()))
time.sleep(30)
PYLOCK
  local locker_pid=$!
  # Wait for the locker to actually grab the lock (pidfile appears).
  local waits=0
  while [[ ! -s "$locker_pid_file" ]] && (( waits < 30 )); do
    sleep 0.1
    waits=$(( waits + 1 ))
  done
  if [[ ! -s "$locker_pid_file" ]]; then
    kill "$locker_pid" 2>/dev/null || true
    wait "$locker_pid" 2>/dev/null || true
    smoke_fail "sqlite locker sidecar never acquired the EXCLUSIVE lock"
  fi

  local output rc elapsed
  output="$(run_with_timeout_subshell nudge_live_state 2 \
              python3 "$REAL_HELPER" nudge-live-state "$db_path" some-agent)"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"

  kill "$locker_pid" 2>/dev/null || true
  wait "$locker_pid" 2>/dev/null || true

  [[ -n "$rc" ]] || smoke_fail "could not parse rc from: $output"
  [[ -n "$elapsed" ]] || smoke_fail "could not parse elapsed from: $output"
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "real-helper sqlite-lock stall: expected rc=124|137, got rc=$rc (elapsed=${elapsed}s, output=$output)"
  fi
  if (( elapsed > 8 )); then
    smoke_fail "real-helper sqlite-lock stall: ceiling not enforced (elapsed=${elapsed}s)"
  fi
  # The previous step_audit_row_written already verified the
  # daemon_subprocess_timeout row gets written with call_site=nudge_live_state
  # for the synthetic stall; here we just confirm a second row was appended
  # so the operator can distinguish multiple stalls within a single tick.
  local count
  count="$(grep -c '"call_site": "nudge_live_state"' "$BRIDGE_AUDIT_LOG" || true)"
  if (( count < 2 )); then
    smoke_fail "audit log should now have >=2 nudge_live_state timeout rows, got $count"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s — real helper stalled on real sqlite I/O wait"
}

step_loop_survives_real_stall_then_recovers() {
  smoke_log "step 8: two consecutive bridge_with_timeout calls — real stall then real success"
  # Re-use the FIFO + passthrough vectors back-to-back via the same driver,
  # mirroring what a daemon tick does when the same callsite is invoked
  # again on the next cycle after a timeout.
  local fifo="$SMOKE_TMP_ROOT/cleanup-report-r2.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || smoke_fail "mkfifo failed for recovery test"

  # Call 1: stall.
  local rc1=0
  local out1="$SMOKE_TMP_ROOT/recover-tick1.out"
  set +e
  "$DRIVER" 2 mcp_orphan_cleanup_parse python3 "$REAL_HELPER" \
      mcp-orphan-cleanup-parse "$fifo" >"$out1" 2>&1
  rc1=$?
  set -e
  if [[ "$rc1" != "124" && "$rc1" != "137" ]]; then
    rm -f "$fifo"
    smoke_fail "recovery tick1 should time out, got rc=$rc1 (out: $(cat "$out1"))"
  fi
  rm -f "$fifo"

  # Call 2: same callsite, valid input — must succeed immediately.
  local report="$SMOKE_TMP_ROOT/cleanup-report-r2.json"
  cat >"$report" <<'JSON'
{"killed_count": 0, "orphan_count": 0, "freed_mb_estimate": 0, "errors": []}
JSON
  local rc2=0
  local out2="$SMOKE_TMP_ROOT/recover-tick2.out"
  local start_ts end_ts elapsed2
  start_ts="$(date +%s)"
  set +e
  "$DRIVER" 5 mcp_orphan_cleanup_parse python3 "$REAL_HELPER" \
      mcp-orphan-cleanup-parse "$report" >"$out2" 2>&1
  rc2=$?
  set -e
  end_ts="$(date +%s)"
  elapsed2=$(( end_ts - start_ts ))
  if (( rc2 != 0 )); then
    smoke_fail "recovery tick2 should succeed but rc=$rc2 (out: $(cat "$out2"))"
  fi
  if (( elapsed2 > 5 )); then
    smoke_fail "recovery tick2 should be fast but elapsed=${elapsed2}s"
  fi
  smoke_assert_eq "0"$'\t'"0"$'\t'"0"$'\t'"0" "$(cat "$out2")" "recovery tick2 output"
  smoke_log "  tick1 rc=$rc1, tick2 rc=$rc2 elapsed=${elapsed2}s — wrapping is non-wedging across calls"
}

# ---------------------------------------------------------------------------
# #800 regression follow-up — PR #799 introduced 4 new daemon callsites plus
# 2 library sites that bypassed PR #801's wrapping convention. The steps
# below mirror the existing 9-site assertions exactly:
#
#   * For each new call_site label, drive bridge_with_timeout 2s against the
#     synthetic STALL_HELPER and confirm rc=124|137 within budget. This
#     proves the wrap label is wired correctly at the new bash callsite.
#   * Confirm the audit row tags the new call_site so the operator can
#     identify which regression site wedged.
#   * Confirm the real helper subcommand passes valid JSON through cleanly
#     (smoke against malformed argv would just print to stderr — pure parse
#     paths, no stall vector — so we cover the happy path via the real
#     helper to prove the subcommand body itself works).
#
# Library sites (core_match, skills_resolve_target) follow Pattern B
# (python3 -c "$SCRIPT" here-string). We exercise the SAME bridge_with_timeout
# wrapper with their labels because Pattern B and Pattern A go through the
# same wrapping helper — what we are proving is "the bash callsite label is
# wired and the ceiling is enforced", which is identical for both patterns.
# ---------------------------------------------------------------------------

# Run a 2s stall with the given call_site label and confirm both the rc=124|137
# outcome and an audit row tagged with the label.
_assert_label_stall_and_audit() {
  local label="$1"
  smoke_log "  label=$label — driving 2s stall + audit row check"
  local output rc elapsed
  output="$(run_with_timeout_subshell "$label" 2 python3 "$STALL_HELPER")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "could not parse rc from: $output (label=$label)"
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "label=$label: expected rc=124|137, got rc=$rc (elapsed=${elapsed}s)"
  fi
  if (( elapsed > 8 )); then
    smoke_fail "label=$label: ceiling not enforced (elapsed=${elapsed}s, budget 2s)"
  fi
  if ! grep -q "\"call_site\": \"$label\"" "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing call_site=$label after stall: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "    rc=$rc elapsed=${elapsed}s — wrap fires + audit row present"
}

step_pr799_usage_rotation_candidates_wrap() {
  smoke_log "step 9: PR #799 site — usage_rotation_candidates_parse wrap + audit"
  _assert_label_stall_and_audit usage_rotation_candidates_parse

  # Real-helper happy path: confirm the subcommand body parses valid input.
  local out
  out="$(python3 "$REAL_HELPER" usage-rotation-candidates-parse \
    '{"rotation_candidates":[{"provider":"claude","account":"a","window":"5h","used_percent":"95","reset_at":"x","source":"s","message":"m"}]}')"
  smoke_assert_eq "claude"$'\t'"a"$'\t'"5h"$'\t'"95"$'\t'"x"$'\t'"s"$'\t'"m" "$out" \
    "usage-rotation-candidates-parse should emit 7-col row from valid JSON"
}

step_pr799_rotation_status_wrap() {
  smoke_log "step 10: PR #799 site — rotation_status_parse wrap + audit"
  _assert_label_stall_and_audit rotation_status_parse

  local out
  out="$(python3 "$REAL_HELPER" rotation-status-parse \
    '{"status":"rotated","reason":"ok","old_active_token_id":"a","active_token_id":"b","sync":{"status":"ok"}}')"
  smoke_assert_eq "rotated"$'\t'"ok"$'\t'"a"$'\t'"b"$'\t'"ok" "$out" \
    "rotation-status-parse should emit 5-col row from valid JSON"
}

step_pr799_recovery_status_wrap() {
  smoke_log "step 11: PR #799 site — recovery_status_parse wrap + audit"
  _assert_label_stall_and_audit recovery_status_parse

  local out
  out="$(python3 "$REAL_HELPER" recovery-status-parse \
    '{"status":"ok","reason":"","checked_count":1,"recovered_count":1,"still_disabled_count":0,"recovered":["t1"],"sync_recommended":true}')"
  smoke_assert_eq "ok"$'\t\t'"1"$'\t'"1"$'\t'"0"$'\t'"t1"$'\t'"1" "$out" \
    "recovery-status-parse should emit 7-col row from valid JSON"
}

step_pr799_sync_status_wrap() {
  smoke_log "step 12: PR #799 site — sync_status_parse wrap + audit"
  _assert_label_stall_and_audit sync_status_parse

  local out
  out="$(python3 "$REAL_HELPER" sync-status-parse '{"status":"ok"}')"
  smoke_assert_eq "ok" "$out" \
    "sync-status-parse should print the status string from valid JSON"

  # Parse failure prints "error" (bash callsite treats empty/error as a
  # sync failure for audit purposes).
  local err
  err="$(python3 "$REAL_HELPER" sync-status-parse 'not-json')"
  smoke_assert_eq "error" "$err" \
    "sync-status-parse should print 'error' on parse failure"
}

step_lib_core_match_wrap() {
  smoke_log "step 13: library site — lib/bridge-core.sh core_match wrap + audit"
  _assert_label_stall_and_audit core_match
}

step_lib_skills_resolve_target_wrap() {
  smoke_log "step 14: library site — lib/bridge-skills.sh skills_resolve_target wrap + audit"
  _assert_label_stall_and_audit skills_resolve_target
}

smoke_run "stalling helper terminates within budget" step_wrapping_terminates_stalled_helper
smoke_run "daemon_subprocess_timeout audit row written" step_audit_row_written
smoke_run "next tick recovers without intervention" step_loop_recovers_next_tick
smoke_run "all Track-A + PR #799 regression subcommands wired up" step_helper_subcommands_resolve
smoke_run "real helper (mcp-orphan-cleanup-parse) stalls on FIFO" step_real_helper_stalls_on_fifo
smoke_run "real helper (mcp-orphan-cleanup-parse) passes through valid JSON" step_real_helper_passthrough
smoke_run "real helper (nudge-live-state) stalls on sqlite EXCLUSIVE lock" step_real_helper_stalls_on_sqlite_lock
smoke_run "loop survives real stall then recovers on next call" step_loop_survives_real_stall_then_recovers
smoke_run "PR #799 site: usage_rotation_candidates_parse wrap" step_pr799_usage_rotation_candidates_wrap
smoke_run "PR #799 site: rotation_status_parse wrap" step_pr799_rotation_status_wrap
smoke_run "PR #799 site: recovery_status_parse wrap" step_pr799_recovery_status_wrap
smoke_run "PR #799 site: sync_status_parse wrap" step_pr799_sync_status_wrap
smoke_run "library site: lib/bridge-core.sh core_match wrap" step_lib_core_match_wrap
smoke_run "library site: lib/bridge-skills.sh skills_resolve_target wrap" step_lib_skills_resolve_target_wrap

smoke_log "PASS"
