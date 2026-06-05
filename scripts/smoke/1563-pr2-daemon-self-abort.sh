#!/usr/bin/env bash
# scripts/smoke/1563-pr2-daemon-self-abort.sh — unit + live smoke for the
# #1563 PR-2 daemon T1 SELF-ABORT BACKSTOP + T0 OS-init restart wiring.
#
# THE WEDGE (the actual #1563 bug): the daemon can sit "alive-but-not-
# ticking" — cmd_run's pid stays alive while cmd_sync_cycle is blocked on an
# unbounded child. A naive `kill -0 $pid` health check passes the wedge. PR-2
# makes a wedged daemon SELF-ABORT (exit non-zero) so T0 (launchd KeepAlive /
# systemd Restart=always) restarts a FRESH daemon — WITHOUT ever aborting a
# HEALTHY daemon mid-long-step (the flapping-monitor irony is the #1 risk).
#
# THE MECHANISM PR-2 ships (this smoke pins):
#   - lib/bridge-daemon-control.sh: the runner-process supervisor
#     bridge_daemon_run_tick_supervised runs ONE tick as a CHILD in its own
#     process group; the child writes a progress heartbeat around each long
#     bounded step (bridge_daemon_tick_progress_touch); the supervisor watches
#     progress FRESHNESS against the max-step-budget + grace deadline
#     (bridge_daemon_tick_deadline_seconds). On a wedge it kills the child's
#     process group, emits daemon_tick_deadline_exceeded, and returns
#     BRIDGE_DAEMON_TICK_WEDGE_RC (99).
#   - bridge-daemon.sh: cmd_run runs the tick via the supervisor and `exit`s
#     non-zero on the wedge rc so OS-init restarts; _bridge_daemon_mark_progress
#     refreshes the progress heartbeat around the long bounded steps.
#   - scripts/install-daemon-systemd.sh + install-daemon-launchagent.sh: the
#     OS-init restart wiring (Restart=always / KeepAlive) that turns the
#     non-zero exit into a fresh daemon.
#
# Everything sourced here is the REAL shipped lib (lib/bridge-daemon-
# control.sh), not a copy, so a revert of the hardening fails this smoke.
#
# Assertions (the negative control (A) is MANDATORY and carries teeth):
#   A  — HEALTHY-LONG-STEP NEGATIVE CONTROL: a healthy long step that runs
#        LONGER than the liveness threshold but keeps stamping progress around
#        its (bounded) work → NO self-abort (returns 0). TEETH: a before/after-
#        only heartbeat paired with a SHORTER (sub-step) threshold MUST FAIL
#        the control (the supervisor DOES abort it) — proving the heartbeat
#        actually pulses and the deadline is max-step-derived, not a constant.
#   B  — WEDGED unbounded step → self-abort within (max-step + grace), returns
#        BRIDGE_DAEMON_TICK_WEDGE_RC, and emits a daemon_tick_deadline_exceeded
#        audit row carrying tick_id + last_step + duration_seconds +
#        deadline_seconds.
#   C  — stale timer/child DISARMED between ticks: after a normal tick the
#        child is reaped (no orphan), the next supervised tick forks a FRESH
#        child + FRESH progress baseline, and a prior tick's stale progress
#        does NOT make the next healthy tick abort.
#   D  — T0 wiring static-assert: the launchd plist carries KeepAlive, the
#        systemd unit carries Restart=always (+ Type=notify/WatchdogSec under
#        --watchdog), cmd_run `exit`s on the wedge rc, and the deadline is
#        max-step-budget-derived (NOT a small nudge-latency number).
#   E  — deadline purity: bridge_daemon_tick_deadline_seconds == max_step +
#        grace, and is >= the longest legitimate single step (daily_backup
#        600s) — so no healthy bounded step can trip it.
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge state
# is touched. Footgun #11: pipe/argv stdin only — no heredoc-stdin to a
# subprocess capture.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
# _skip: an environment limitation prevented an assertion from running, but it
# is NOT a regression (the invariant is covered elsewhere). Loud by design.
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
SYSTEMD_INSTALLER="$REPO_ROOT/scripts/install-daemon-systemd.sh"
LAUNCHD_INSTALLER="$REPO_ROOT/scripts/install-daemon-launchagent.sh"
for f in "$CONTROL_LIB" "$DAEMON_SH" "$SYSTEMD_INSTALLER" "$LAUNCHD_INSTALLER"; do
  if [[ ! -r "$f" ]]; then
    printf '[FAIL] required source not found: %s\n' "$f" >&2
    exit 1
  fi
done

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1563-pr2-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Isolated bridge home + state dir. Nothing here touches ~/.agent-bridge.
export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"

# Audit sink: capture the action token (2nd arg) of every bridge_audit_log
# call to a per-call file so the assertions can grep for
# daemon_tick_deadline_exceeded without a real audit backend. Also capture the
# full --detail argv so we can assert the structured fields.
AUDIT_LOG="$SMOKE_DIR/audit.log"
AUDIT_DETAIL="$SMOKE_DIR/audit-detail.log"
: >"$AUDIT_LOG"
: >"$AUDIT_DETAIL"
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_audit_log() {
  # args: <actor> <action> <target> [--detail k=v ...]; record the action +
  # the full argv (for the structured-field assertion).
  printf '%s\n' "${2:-}" >>"$AUDIT_LOG" 2>/dev/null || true
  printf '%s\n' "$*" >>"$AUDIT_DETAIL" 2>/dev/null || true
}
audit_count() {
  local token="$1"
  grep -c -x "$token" "$AUDIT_LOG" 2>/dev/null | tr -dc '0-9' | head -c 8
}
reset_audit() { : >"$AUDIT_LOG"; : >"$AUDIT_DETAIL"; }

# Tight per-step budgets so the smoke runs in seconds, not minutes. The
# DEADLINE = max-step + grace = 3 + 1 = 4s. The "long step" runs 6s while
# stamping progress (so age stays ~1s) — proving the deadline is max-step-
# derived, not total-tick-derived.
export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=3
export BRIDGE_DAEMON_TICK_GRACE_SECONDS=1
export BRIDGE_DAEMON_TICK_POLL_SECONDS=1
# The resolved-max-step now floors on EVERY operator-tunable step ceiling
# (token-recovery 60 / token-check 45 / cron-staging 25 / cron-sync 30 by
# default). For the FAST wedge tests below we clamp them all to 1s so the
# effective deadline stays the tiny 4s above; the E5/E6 assertions explicitly
# RAISE individual knobs to prove the coupling. Production keeps the real
# defaults (all < the 600s floor, so they never change the deadline there).
export BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1
export BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS=1
export BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS=1
export BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1
export BRIDGE_CRON_SYNC_TIMEOUT=1

# shellcheck source=/dev/null
source "$CONTROL_LIB"

# Helper presence gate — a revert of the PR-2 hardening removes these.
for fn in bridge_daemon_run_tick_supervised bridge_daemon_tick_deadline_seconds \
          bridge_daemon_tick_progress_touch bridge_daemon_tick_progress_file \
          _bridge_daemon_tick_progress_age bridge_daemon_sd_notify; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s (PR-2 hardening missing?)\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

DEADLINE="$(bridge_daemon_tick_deadline_seconds)"

# ===========================================================================
# E — deadline purity (cheap, run first so the value is known for later text).
# ===========================================================================
if [[ "$DEADLINE" == "4" ]]; then
  _pass "E1 deadline == max_step(3) + grace(1) == 4"
else
  _fail "E1 deadline-derivation" "expected 4, got '$DEADLINE'"
fi
# With production defaults the deadline must be >= the longest legitimate
# single step (daily_backup 600s). Compute the production default explicitly.
PROD_DEADLINE="$(BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=600 BRIDGE_DAEMON_TICK_GRACE_SECONDS=120 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_deadline_seconds")"
if [[ "$PROD_DEADLINE" =~ ^[0-9]+$ ]] && (( PROD_DEADLINE >= 600 )); then
  _pass "E2 production deadline ($PROD_DEADLINE s) >= longest legit step (daily_backup 600s) — max-step-derived, not nudge-latency"
else
  _fail "E2 production-deadline-floor" "expected >=600, got '$PROD_DEADLINE'"
fi
# E3 — codex #1563-PR2 BLOCKER coverage: an operator who RAISES
# BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS (the documented large-install knob) must
# automatically WIDEN the T1 deadline — otherwise a healthy backup running
# under its own (raised) bridge_with_timeout would self-abort (the flapping
# irony). With backup=900 and the default floor 600 + grace 120, the deadline
# must be > 900 (i.e. 900 + 120 = 1020), NOT the fixed 720.
E3_DEADLINE="$(BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=600 BRIDGE_DAEMON_TICK_GRACE_SECONDS=120 BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=900 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_deadline_seconds")"
if [[ "$E3_DEADLINE" =~ ^[0-9]+$ ]] && (( E3_DEADLINE > 900 )); then
  _pass "E3 raised BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=900 widens deadline to ${E3_DEADLINE}s (> 900) — no false-abort of a healthy raised-timeout backup"
else
  _fail "E3 backup-timeout-coupling" "expected deadline > 900 when backup timeout is 900, got '$E3_DEADLINE' (a fixed 720 would FALSE-ABORT a healthy backup)"
fi
# E4 — the resolved-max-step helper itself reflects the raised backup timeout.
E4_MAXSTEP="$(BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=600 BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1200 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_resolved_max_step_seconds")"
if [[ "$E4_MAXSTEP" == "1200" ]]; then
  _pass "E4 resolved-max-step tracks BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS (1200 → 1200), never below a configured bounded step"
else
  _fail "E4 resolved-max-step" "expected 1200, got '$E4_MAXSTEP'"
fi
# E5 — codex #1563-PR2 round-2 BLOCKER coverage: daily-backup is NOT the only
# operator-tunable bridge_with_timeout step. Raising any of the OTHER reachable
# step ceilings (claude-token-recovery / claude-token-check / cron-staging-
# apply / cron-sync) must ALSO widen the deadline so a healthy raised step is
# never self-aborted. Check each one drives the resolved-max-step.
E5_FAIL=0
for kv in BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS:1500 BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS:1400 BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS:1300 BRIDGE_CRON_SYNC_TIMEOUT:1100; do
  k="${kv%%:*}"; v="${kv#*:}"
  got="$(env "$k=$v" BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=600 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_resolved_max_step_seconds")"
  if [[ "$got" != "$v" ]]; then
    printf '[FAIL] E5: %s=%s did NOT drive resolved-max-step (got %s) — healthy raised %s step could false-abort\n' "$k" "$v" "$got" "$k" >&2
    E5_FAIL=1
  fi
done
if (( E5_FAIL == 0 )); then
  _pass "E5 every operator-tunable step ceiling (token-recovery/token-check/cron-staging/cron-sync) widens the deadline — no false-abort of any raised bounded step"
else
  _fail "E5 multi-knob-coupling" "see missing-knob lines above"
fi
# E6 — the deadline from a raised non-backup knob is > that knob (not the
# fixed 720). e.g. cron-staging 1300 → deadline 1300 + grace 120 = 1420.
E6_DEADLINE="$(BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=600 BRIDGE_DAEMON_TICK_GRACE_SECONDS=120 BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1300 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_deadline_seconds")"
if [[ "$E6_DEADLINE" =~ ^[0-9]+$ ]] && (( E6_DEADLINE > 1300 )); then
  _pass "E6 raised non-backup step (cron-staging 1300) → deadline ${E6_DEADLINE}s (> 1300), NOT the fixed 720"
else
  _fail "E6 non-backup-deadline" "expected > 1300, got '$E6_DEADLINE'"
fi

# ===========================================================================
# A — HEALTHY-LONG-STEP NEGATIVE CONTROL (MANDATORY, with teeth).
# ===========================================================================
# Healthy long step: runs 6s (> the 4s deadline) but stamps progress every
# second around its bounded work, so progress age never reaches the deadline.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
healthy_long_tick() {
  bridge_daemon_tick_progress_touch "long_step"
  local i
  for i in 1 2 3 4 5 6; do
    bridge_daemon_tick_progress_touch "long_step"
    sleep 1
  done
  return 0
}
reset_audit
A_RC=0
bridge_daemon_run_tick_supervised 1 healthy_long_tick || A_RC=$?
A_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( A_RC == 0 )) && [[ "${A_ABORTS:-0}" == "0" ]]; then
  _pass "A healthy-long-step (6s > ${DEADLINE}s deadline, progress kept fresh) → NO self-abort (rc=0, 0 deadline rows)"
else
  _fail "A negative-control" "healthy long step WAS aborted (rc=$A_RC, deadline_rows=${A_ABORTS:-?}) — false-positive wedge (the flapping irony)"
fi

# TEETH: prove the control has bite. A before/after-ONLY heartbeat (no mid-step
# stamps) paired with a SHORTER threshold (sub-step deadline) MUST be aborted —
# if it were NOT, the negative control above would be vacuous (it would pass
# even with a broken/constant heartbeat).
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
before_after_only_tick() {
  bridge_daemon_tick_progress_touch "ba_step"   # before
  sleep 6                                        # long opaque work, NO mid stamp
  bridge_daemon_tick_progress_touch "ba_step"   # after (never reached in time)
  return 0
}
reset_audit
# Shorter threshold: deadline = 2 + 0 = 2s, well under the 6s opaque sleep.
T_RC=0
( export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=2
  export BRIDGE_DAEMON_TICK_GRACE_SECONDS=0
  export BRIDGE_DAEMON_TICK_POLL_SECONDS=1
  bridge_daemon_run_tick_supervised 99 before_after_only_tick ) || T_RC=$?
T_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( T_RC == ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99} )) && [[ "${T_ABORTS:-0}" != "0" ]]; then
  _pass "A-teeth before/after-only heartbeat + shorter threshold → FAILS the control (aborted rc=$T_RC) — the negative control has bite"
else
  _fail "A-teeth" "before/after-only + short threshold was NOT aborted (rc=$T_RC, rows=${T_ABORTS:-?}) — negative control is vacuous"
fi

# ===========================================================================
# A2 — PRODUCTION before+after BRACKETING teeth (#1563 PR-2 r2, codex BLOCKING).
# ===========================================================================
# Reproduces the codex healthy-daemon false-abort probe at the EXACT shape the
# production wiring now defends against: a long bounded step that stamps
# progress BEFORE it runs, consumes ~max_step, and is followed by healthy TAIL
# work (release_monitor + the rest of the tick). The cmd_sync_cycle markers now
# stamp progress BEFORE *and* AFTER each long step, so a healthy max-duration
# step re-baselines the heartbeat and the tail inherits the FULL deadline. This
# teeth proves BOTH directions:
#   (1) a BEFORE-ONLY revert (no AFTER stamp) + ~max_step + healthy tail MUST be
#       FALSE-ABORTED (rc=99) — i.e. the production bug codex reproduced; and
#   (2) the BEFORE+AFTER production wiring with the SAME timings MUST NOT abort.
# With the smoke's deadline=4 (max_step 3 + grace 1): step=3s (age reaches ~3,
# under deadline — a healthy step) then tail=3s. Before-only: age climbs 3→6,
# crosses 4 → ABORT. Before+after: the AFTER stamp resets age to 0, tail age
# only reaches ~3 < 4 → NO abort. The mid-step pulse the A negative-control uses
# did NOT catch this class (it pulsed every second); a real long step is opaque
# between its before/after marks.

# (1) BEFORE-ONLY: stamp before, run the step (~max_step), then healthy tail
#     work with NO further stamp until the tick ends. This is the pre-fix
#     production shape — it MUST false-abort.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
before_only_then_tail_tick() {
  bridge_daemon_tick_progress_touch "long_step"   # BEFORE the long step
  sleep 3                                          # the long bounded step (~max_step)
  # NO after-stamp here (the bug). Healthy tail work follows:
  sleep 3                                          # tail (release_monitor + rest)
  return 0
}
reset_audit
BO_RC=0
bridge_daemon_run_tick_supervised 21 before_only_then_tail_tick || BO_RC=$?
BO_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( BO_RC == ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99} )) && [[ "${BO_ABORTS:-0}" != "0" ]]; then
  _pass "A2-teeth BEFORE-ONLY stamp + ~max_step + healthy tail → FALSE-ABORTED (rc=$BO_RC) — proves a before-only revert reintroduces the healthy-daemon false-abort codex reproduced"
else
  _fail "A2-teeth before-only" "before-only + max_step + tail was NOT aborted (rc=$BO_RC, rows=${BO_ABORTS:-?}) — the teeth is vacuous; the production false-abort class is not pinned"
fi

# (2) BEFORE+AFTER (production wiring): same timings, but re-baseline progress
#     AFTER the long step. The tail inherits the FULL deadline → NO abort. This
#     is what the cmd_sync_cycle before+after markers now do for every long step.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
before_after_then_tail_tick() {
  bridge_daemon_tick_progress_touch "long_step"   # BEFORE the long step
  sleep 3                                          # the long bounded step (~max_step)
  bridge_daemon_tick_progress_touch "long_step"   # AFTER — re-baseline (the fix)
  sleep 3                                          # tail inherits the full deadline
  return 0
}
reset_audit
BA_RC=0
bridge_daemon_run_tick_supervised 22 before_after_then_tail_tick || BA_RC=$?
BA_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( BA_RC == 0 )) && [[ "${BA_ABORTS:-0}" == "0" ]]; then
  _pass "A2 BEFORE+AFTER production wiring + ~max_step + healthy tail → NO false-abort (rc=0) — the AFTER stamp re-baselines and the tail gets the full deadline"
else
  _fail "A2 before+after" "before+after wiring was FALSE-ABORTED (rc=$BA_RC, rows=${BA_ABORTS:-?}) — the production bracketing does not prevent the healthy-daemon abort"
fi

# ===========================================================================
# B — WEDGED unbounded step → self-abort within (max-step + grace) + audit.
# ===========================================================================
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
wedged_tick() {
  bridge_daemon_tick_progress_touch "wedge_step"
  sleep 600   # unbounded hang, NO further progress
  return 0
}
reset_audit
B_START="$(date +%s)"
B_RC=0
bridge_daemon_run_tick_supervised 7 wedged_tick || B_RC=$?
B_END="$(date +%s)"
B_ELAPSED=$(( B_END - B_START ))
B_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( B_RC == ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99} )); then
  _pass "B wedged unbounded step → self-abort rc=$B_RC (BRIDGE_DAEMON_TICK_WEDGE_RC)"
else
  _fail "B wedge-rc" "expected rc ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99}, got $B_RC"
fi
# Aborted within (deadline + a generous grace for poll/kill teardown).
if (( B_ELAPSED <= DEADLINE + 8 )); then
  _pass "B abort latency ${B_ELAPSED}s within (deadline ${DEADLINE}s + teardown grace)"
else
  _fail "B abort-latency" "took ${B_ELAPSED}s, expected <= $((DEADLINE + 8))s"
fi
if [[ "${B_ABORTS:-0}" != "0" ]]; then
  _pass "B emitted daemon_tick_deadline_exceeded (count=${B_ABORTS})"
else
  _fail "B audit-emit" "no daemon_tick_deadline_exceeded row"
fi
# Structured fields: the single deadline row must carry tick_id, last_step,
# duration_seconds, deadline_seconds.
B_ROW="$(grep 'daemon_tick_deadline_exceeded' "$AUDIT_DETAIL" 2>/dev/null | head -n1)"
B_FIELD_FAIL=0
for field in "tick_id=7" "last_step=wedge_step" "duration_seconds=" "deadline_seconds=${DEADLINE}"; do
  case "$B_ROW" in
    *"$field"*) : ;;
    *) printf '[FAIL] B fields: missing "%s" in row: %s\n' "$field" "$B_ROW" >&2; B_FIELD_FAIL=1 ;;
  esac
done
if (( B_FIELD_FAIL == 0 )); then
  _pass "B structured fields present (tick_id=7, last_step=wedge_step, duration_seconds, deadline_seconds=${DEADLINE})"
else
  _fail "B structured-fields" "see missing-field lines above"
fi

# ===========================================================================
# C — stale timer/child DISARMED between ticks (no cross-tick fire / orphan).
# ===========================================================================
# Tick 1 wedges → supervisor kills the child. Tick 2 is HEALTHY and quick. The
# fresh-baseline-per-tick contract means tick 2 must NOT inherit tick 1's stale
# progress and abort. Also assert no orphaned child survives a normal tick.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
quick_healthy_tick() {
  bridge_daemon_tick_progress_touch "quick_step"
  sleep 1
  return 0
}
reset_audit
# First, a wedge (consumes its own deadline), then immediately a healthy tick.
bridge_daemon_run_tick_supervised 10 wedged_tick >/dev/null 2>&1 || true
C_RC=0
bridge_daemon_run_tick_supervised 11 quick_healthy_tick || C_RC=$?
C_HEALTHY_ABORTS="$(grep 'tick_id=11' "$AUDIT_DETAIL" 2>/dev/null | grep -c 'daemon_tick_deadline_exceeded' || true)"
if (( C_RC == 0 )) && [[ "${C_HEALTHY_ABORTS:-0}" == "0" ]]; then
  _pass "C next tick after a wedge forks a FRESH baseline → healthy tick NOT aborted (no cross-tick stale-timer fire)"
else
  _fail "C cross-tick-disarm" "healthy tick after a wedge was aborted (rc=$C_RC, rows=${C_HEALTHY_ABORTS:-?})"
fi
# Orphan check: after a normal tick, the spawned grandchild (a sleeper) must
# be gone. Use a tick that backgrounds a marker sleeper and records its pid.
ORPHAN_PIDFILE="$SMOKE_DIR/orphan.pid"
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
tick_with_child() {
  bridge_daemon_tick_progress_touch "child_step"
  ( sleep 30 ) &
  printf '%s\n' "$!" >"$ORPHAN_PIDFILE"
  sleep 1
  return 0
}
reset_audit
bridge_daemon_run_tick_supervised 12 tick_with_child >/dev/null 2>&1 || true
# A normally-completing tick is NOT killed by the supervisor, so a backgrounded
# grandchild it deliberately spawned MAY still be alive — that is expected
# (the supervisor only process-group-kills on a WEDGE). The orphan-prevention
# contract is specifically about the WEDGE path: assert there the killed
# child's tree is gone.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
wedged_tick_with_grandchild() {
  bridge_daemon_tick_progress_touch "wedge_gc_step"
  ( sleep 600 ) &
  printf '%s\n' "$!" >"$ORPHAN_PIDFILE"
  sleep 600
  return 0
}
reset_audit
bridge_daemon_run_tick_supervised 13 wedged_tick_with_grandchild >/dev/null 2>&1 || true
GC_PID="$(tr -dc '0-9' <"$ORPHAN_PIDFILE" 2>/dev/null | head -c 12)"
if [[ -n "$GC_PID" ]]; then
  # Give the SIGKILL a beat to land.
  sleep 1
  if kill -0 "$GC_PID" 2>/dev/null; then
    # Best-effort cleanup so we don't leak the sleeper.
    kill -KILL "$GC_PID" 2>/dev/null || true
    _fail "C orphan-prevention" "wedged tick's grandchild pid=$GC_PID survived the process-group kill"
  else
    _pass "C wedge kills the child's process group — grandchild pid=$GC_PID reaped (no orphan)"
  fi
else
  _skip "C orphan-prevention" "could not capture grandchild pid"
fi

# ===========================================================================
# D — T0 wiring static-assert (launchd KeepAlive + systemd Restart/notify +
#     cmd_run exits on the wedge rc).
# ===========================================================================
# D1 — launchd plist carries KeepAlive (true).
if grep -q '<key>KeepAlive</key>' "$LAUNCHD_INSTALLER"; then
  _pass "D1 launchd plist carries KeepAlive (OS-init restart on any exit)"
else
  _fail "D1 launchd-keepalive" "no <key>KeepAlive</key> in $LAUNCHD_INSTALLER"
fi
# D2 — systemd unit carries Restart=always (restart on the T1 non-zero exit).
if grep -q "'Restart=always'" "$SYSTEMD_INSTALLER" || grep -q 'Restart=always' "$SYSTEMD_INSTALLER"; then
  _pass "D2 systemd unit carries Restart=always (OS-init restart on non-zero exit)"
else
  _fail "D2 systemd-restart" "no Restart=always in $SYSTEMD_INSTALLER"
fi
# D3 — --watchdog renders Type=notify + WatchdogSec (the optional outer ring).
D3_OUT="$(bash "$SYSTEMD_INSTALLER" --bridge-home "$SMOKE_DIR/wd" --no-sudo-self --watchdog 2>/dev/null || true)"
if printf '%s\n' "$D3_OUT" | grep -q '^Type=notify' \
   && printf '%s\n' "$D3_OUT" | grep -q '^WatchdogSec=' \
   && printf '%s\n' "$D3_OUT" | grep -q '^Restart=always'; then
  _pass "D3 --watchdog → Type=notify + WatchdogSec + Restart=always (independent systemd outer ring)"
else
  _fail "D3 systemd-watchdog" "missing Type=notify / WatchdogSec / Restart=always under --watchdog"
fi
# D3b — default (no --watchdog) keeps Type=simple (no flap-risk by default).
D3B_OUT="$(bash "$SYSTEMD_INSTALLER" --bridge-home "$SMOKE_DIR/wd2" --no-sudo-self 2>/dev/null || true)"
if printf '%s\n' "$D3B_OUT" | grep -q '^Type=simple' \
   && ! printf '%s\n' "$D3B_OUT" | grep -q '^WatchdogSec='; then
  _pass "D3b default unit stays Type=simple, no WatchdogSec (no Type=notify flap risk by default)"
else
  _fail "D3b systemd-default" "default unit unexpectedly carries notify/watchdog"
fi
# D3c — codex #1563-PR2 coverage: a too-small --watchdog-sec is RAISED above
# the T1 deadline so systemd can never fire before the daemon's own self-abort.
# Run with the PRODUCTION floors (clear the smoke's tiny tick-tuning env so the
# installer computes its real 600+120=720 floor, not the smoke's fast deadline).
D3C_OUT="$(env -u BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS -u BRIDGE_DAEMON_TICK_GRACE_SECONDS -u BRIDGE_DAEMON_TICK_POLL_SECONDS -u BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS bash "$SYSTEMD_INSTALLER" --bridge-home "$SMOKE_DIR/wd3" --no-sudo-self --watchdog-sec 100 2>/dev/null || true)"
D3C_SEC="$(printf '%s\n' "$D3C_OUT" | sed -n 's/^WatchdogSec=//p' | tr -dc '0-9' | head -c 8)"
if [[ "$D3C_SEC" =~ ^[0-9]+$ ]] && (( D3C_SEC > 720 )); then
  _pass "D3c too-small --watchdog-sec=100 raised to ${D3C_SEC}s (> T1 deadline 720s) — systemd stays the slower outer ring"
else
  _fail "D3c watchdog-coupling" "WatchdogSec not raised above the T1 deadline (got '${D3C_SEC}', expected > 720)"
fi
# D3d — watchdog-sec tracks a raised backup timeout too (the coupling source).
D3D_OUT="$(env -u BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS -u BRIDGE_DAEMON_TICK_GRACE_SECONDS -u BRIDGE_DAEMON_TICK_POLL_SECONDS BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1800 bash "$SYSTEMD_INSTALLER" --bridge-home "$SMOKE_DIR/wd4" --no-sudo-self --watchdog-sec 100 2>/dev/null || true)"
D3D_SEC="$(printf '%s\n' "$D3D_OUT" | sed -n 's/^WatchdogSec=//p' | tr -dc '0-9' | head -c 8)"
if [[ "$D3D_SEC" =~ ^[0-9]+$ ]] && (( D3D_SEC > 1800 )); then
  _pass "D3d WatchdogSec floor tracks raised backup timeout (1800 → raised to ${D3D_SEC}s > 1800)"
else
  _fail "D3d watchdog-backup-coupling" "WatchdogSec did not track the raised backup timeout (got '${D3D_SEC}', expected > 1800)"
fi
# D3e — codex round-2: the systemd WatchdogSec floor mirrors the FULL step set,
# not only daily-backup. A raised NON-backup step (cron-staging 1600) must also
# push WatchdogSec above it.
D3E_OUT="$(env -u BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS -u BRIDGE_DAEMON_TICK_GRACE_SECONDS -u BRIDGE_DAEMON_TICK_POLL_SECONDS BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1600 bash "$SYSTEMD_INSTALLER" --bridge-home "$SMOKE_DIR/wd5" --no-sudo-self --watchdog-sec 100 2>/dev/null || true)"
D3E_SEC="$(printf '%s\n' "$D3E_OUT" | sed -n 's/^WatchdogSec=//p' | tr -dc '0-9' | head -c 8)"
if [[ "$D3E_SEC" =~ ^[0-9]+$ ]] && (( D3E_SEC > 1600 )); then
  _pass "D3e WatchdogSec floor mirrors the FULL step set — raised cron-staging (1600) → watchdog ${D3E_SEC}s > 1600"
else
  _fail "D3e watchdog-fullset-coupling" "WatchdogSec did not track a raised non-backup step (got '${D3E_SEC}', expected > 1600)"
fi
# D4 — cmd_run EXITS non-zero on the wedge rc (the self-abort → OS-init).
#      Static-assert the wiring: cmd_run calls the supervisor and exits on the
#      reserved wedge rc.
if grep -q 'bridge_daemon_run_tick_supervised' "$DAEMON_SH" \
   && grep -q 'BRIDGE_DAEMON_TICK_WEDGE_RC' "$DAEMON_SH" \
   && grep -Eq 'exit "\$cycle_status"' "$DAEMON_SH"; then
  _pass "D4 cmd_run routes the tick through the supervisor and exits non-zero on the wedge rc (OS-init restart)"
else
  _fail "D4 cmd_run-wiring" "cmd_run does not wire supervisor + wedge-rc exit in $DAEMON_SH"
fi
# D5 — the long bounded steps refresh progress (the markers are wired) AND are
# BRACKETED before+after (#1563 PR-2 r2, codex BLOCKING). A before-ONLY stamp
# leaves a healthy max-duration step's tail with only the grace window → the
# false-abort class. Assert (a) precompact_events is now wired (BLOCKING 2) and
# (b) EVERY long bounded step's mark appears at least TWICE in cmd_sync_cycle
# (the BEFORE + AFTER stamps) so a revert to before-only is caught.
D5_FAIL=0
# Restrict the count to the cmd_sync_cycle body so an unrelated occurrence
# elsewhere in the file cannot mask a missing after-stamp.
SYNC_BODY="$(awk '/^cmd_sync_cycle\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DAEMON_SH")"
for step in daily_backup bridge_sync watchdog a2a_deliver_tick precompact_events; do
  marker="_bridge_daemon_mark_progress \"$step\""
  if ! grep -qF "$marker" "$DAEMON_SH"; then
    printf '[FAIL] D5: missing progress marker: %s\n' "$marker" >&2
    D5_FAIL=1
    continue
  fi
  cnt="$(printf '%s\n' "$SYNC_BODY" | grep -cF "$marker" | tr -dc '0-9' | head -c 4)"
  [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
  if (( cnt < 2 )); then
    printf '[FAIL] D5: long step %s is NOT bracketed before+after (mark count=%s in cmd_sync_cycle; expected >= 2)\n' "$step" "$cnt" >&2
    D5_FAIL=1
  fi
done
if (( D5_FAIL == 0 )); then
  _pass "D5 every long bounded step (daily_backup/bridge_sync/watchdog/a2a_deliver_tick/precompact_events) is BRACKETED before+after — no before-only false-abort gap"
else
  _fail "D5 progress-markers" "see missing/under-bracketed marker lines above"
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 1563-pr2-daemon-self-abort: %d checks (%d skipped) — T1 backstop + T0 wiring verified\n' "$TOTAL" "$SKIPS"
  exit 0
fi
printf '[FAIL] 1563-pr2-daemon-self-abort: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
