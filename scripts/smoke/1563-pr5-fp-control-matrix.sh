#!/usr/bin/env bash
# scripts/smoke/1563-pr5-fp-control-matrix.sh — #1563 PR-5 INTEGRATION TEETH:
# the daemon-redesign FALSE-POSITIVE control matrix.
#
# The #1563 daemon redesign added FIVE supervision behaviors (singleton PR-1,
# T1 self-abort PR-2, admin-liveness escalation PR-3, A2A receiver backoff/
# breaker PR-4) whose #1 shared risk is the FLAPPING-MONITOR IRONY: a
# supervisor that punishes a HEALTHY daemon is worse than no supervisor at all.
# Each PR shipped its own smoke that proves its mechanism; this PR-5 matrix is
# the INTEGRATION teeth that exercises the COMBINED behaviors as one
# false-positive control surface — every row asserts both directions:
#   (i)  the HEALTHY / negative-control case is NOT punished, and
#   (ii) a TEETH-REVERT (the pre-redesign / mis-tuned shape) DOES misfire, so
#        the negative control above is never vacuous.
#
# Everything sourced here is the REAL shipped code (lib/bridge-daemon-control.sh,
# the extracted bridge-daemon.sh functions, lib/bridge-a2a.sh, the
# lib/daemon-helpers/a2a-receiver-exit-cause.py classifier) — NOT a copy — so a
# revert of any hardening fails the matching row.
#
# The 7-row matrix (each = setup / act / assert + a teeth-revert that FAILS):
#   1. healthy long step → NO self-abort (PR-2 B1 negative control). Teeth: a
#      before-only stamp + a healthy tail under a sub-step threshold MUST abort.
#   2. genuinely wedged unbounded step → self-abort within (max-step + grace)
#      (PR-2 wedge rc). Teeth: a fresh heartbeat must PREVENT the abort.
#   3. stale timer disarmed between ticks (PR-2 fresh-baseline-per-tick): a
#      tick that wedges does NOT make the NEXT healthy tick abort.
#   4. singleton race → exactly one survivor (PR-1 start-time-proof eviction).
#      Teeth: a recycled pid (lstart mismatch) is NOT killed.
#   5. escalation task-create-fail → audit + retry; patch-dev ONLY after the
#      admin-down predicate; busy/live admin → NO escalation (PR-3). Teeth: the
#      busy-admin negative control + the swallowed-||true revert.
#   6. admin-self MCP-giveup → patch-dev when resolvable / audit-only fallback
#      (PR-3). Teeth: no-pair → audit-only, never a useless self-route.
#   7. A2A transient → backoff-no-thrash vs real-crash → bounded-restart +
#      escalate; auth/config HELD; fail-closed bind/HMAC INTACT (PR-4). Teeth:
#      auth_config must NOT take the transient backoff path.
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge state is
# touched. Footgun #11 / heredoc-ban: ZERO heredoc-stdin to a captured
# subprocess — function bodies are extracted with awk, file scaffolding uses
# `{ printf ...; } >file`, inline python is `python3 -c '<script>' argv only.
#
# iso-helper note: this fixture references the A2A supervise STATE FILE name
# (`receiver-supervise.env`) and constructs `.env`-suffixed paths only to ASSERT
# the PR-4 contract in a mktemp fixture — it performs NO controller->isolated
# boundary RW, so it is whole-file allowlisted in
# scripts/baselines/iso-helper-allowlist.txt (mirrors the #1520c / #1533 test
# fixtures), NOT a runtime boundary site.

set -uo pipefail

# Re-exec under Bash 4+ (associative arrays in the singleton lib; portable to
# the PR-1/PR-3 smokes' re-exec ladder).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash" "${BASH4_BIN:-}"; do
    if [[ -n "$_candidate" && -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1563-pr5-fp-control-matrix] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
# _skip: an environment limitation prevented a row from running, but it is NOT a
# regression (the invariant is covered by the per-PR smoke). Loud by design.
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
A2A_LIB="$REPO_ROOT/lib/bridge-a2a.sh"
EXIT_CAUSE_PY="$REPO_ROOT/lib/daemon-helpers/a2a-receiver-exit-cause.py"
for f in "$CONTROL_LIB" "$DAEMON_SH" "$A2A_LIB" "$EXIT_CAUSE_PY"; do
  if [[ ! -r "$f" ]]; then
    printf '[FAIL] required source not found: %s\n' "$f" >&2
    exit 1
  fi
done

TMPDIR_BASE="${TMPDIR:-/tmp}"
# Fail FAST (never hang) if the fixture root cannot be created. Under `set -u`
# without `set -e`, an empty SMOKE_DIR would collapse every fixture path to a
# root-relative file (/home, /audit.log, …) and the matrix would then spin on a
# downstream unbound-var instead of failing — so guard the mktemp explicitly.
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1563-pr5-smoke.XXXXXX" 2>/dev/null || true)"
if [[ -z "$SMOKE_DIR" || ! -d "$SMOKE_DIR" ]]; then
  printf '[FAIL] could not create the isolated fixture root via mktemp -d under %s — aborting (no fixture, no run)\n' "$TMPDIR_BASE" >&2
  exit 1
fi
# Track stand-in pids so the trap reaps them even on early exit.
STANDIN_PIDS=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() {
  local p
  for p in "${STANDIN_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$SMOKE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Isolated bridge home + state dir. Nothing here touches ~/.agent-bridge.
export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
mkdir -p "$BRIDGE_STATE_DIR"

# ---------------------------------------------------------------------------
# Audit sink: capture the action token (2nd arg) + the full --detail argv of
# every bridge_audit_log call so the rows can grep for the structured signals
# without a real audit backend. Stubs match the per-PR smokes' shape.
# ---------------------------------------------------------------------------
AUDIT_LOG="$SMOKE_DIR/audit.log"
AUDIT_DETAIL="$SMOKE_DIR/audit-detail.log"
: >"$AUDIT_LOG"
: >"$AUDIT_DETAIL"
# shellcheck disable=SC2329  # invoked indirectly by the sourced libs
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced libs
bridge_audit_log() {
  printf '%s\n' "${2:-}" >>"$AUDIT_LOG" 2>/dev/null || true
  printf '%s\n' "$*" >>"$AUDIT_DETAIL" 2>/dev/null || true
}
# shellcheck disable=SC2329  # invoked indirectly by the extracted daemon funcs
daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329
daemon_info() { printf '[stub-info] %s\n' "$*"; }
# shellcheck disable=SC2329
daemon_log_event() { printf '[stub-log] %s\n' "$*"; }
audit_count() {
  local token="$1"
  grep -c -x "$token" "$AUDIT_LOG" 2>/dev/null | tr -dc '0-9' | head -c 8
}
reset_audit() { : >"$AUDIT_LOG"; : >"$AUDIT_DETAIL"; }

# extract_fn <name> <file> — pull a single top-level shell function body
# (`^name() {` to the first column-0 `^}$`) from a source file. The functions
# under test contain no inner column-0 heredocs, so this is exact.
extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
    capture { print }
    capture && /^}$/ { capture=0; exit }
  ' "$2"
}

# ===========================================================================
# Tight per-step budgets so the matrix runs in seconds. DEADLINE = max-step +
# grace = 3 + 1 = 4s. We clamp every operator-tunable step ceiling so the
# resolved-max-step stays the tiny floor; rows 1-3 use this fast deadline.
# ===========================================================================
export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=3
export BRIDGE_DAEMON_TICK_GRACE_SECONDS=1
export BRIDGE_DAEMON_TICK_POLL_SECONDS=1
export BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1
export BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS=1
export BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS=1
export BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1
export BRIDGE_CRON_SYNC_TIMEOUT=1

# shellcheck source=/dev/null
source "$CONTROL_LIB"

# Helper presence gate — a revert of the PR-1/PR-2 hardening removes these.
for fn in bridge_daemon_run_tick_supervised bridge_daemon_tick_deadline_seconds \
          bridge_daemon_tick_progress_touch bridge_daemon_ensure_singleton \
          _bridge_daemon_proc_start_time _bridge_daemon_singleton_owner_field \
          bridge_daemon_state_counter_incr; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s (#1563 PR-1/PR-2 hardening missing?)\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

DEADLINE="$(bridge_daemon_tick_deadline_seconds)"
if [[ "$DEADLINE" != "4" ]]; then
  printf '[FAIL] matrix precondition: deadline expected 4 (max_step 3 + grace 1), got %s\n' "$DEADLINE" >&2
  exit 1
fi

# ===========================================================================
# ROW 1 — healthy long step → NO self-abort (the flapping-monitor negative
#         control). A long step that outlives the deadline but keeps stamping
#         progress around its bounded work MUST NOT abort. Teeth: a before-only
#         stamp + a healthy tail under a sub-step threshold MUST abort.
# ===========================================================================
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row1_healthy_long_tick() {
  bridge_daemon_tick_progress_touch "long_step"
  local i
  for i in 1 2 3 4 5 6; do
    bridge_daemon_tick_progress_touch "long_step"
    sleep 1
  done
  return 0
}
reset_audit
R1_RC=0
bridge_daemon_run_tick_supervised 1 row1_healthy_long_tick || R1_RC=$?
R1_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( R1_RC == 0 )) && [[ "${R1_ABORTS:-0}" == "0" ]]; then
  _pass "ROW1 healthy long step (6s > ${DEADLINE}s deadline, progress kept fresh) → NO self-abort (rc=0, 0 deadline rows)"
else
  _fail "ROW1 healthy-no-abort" "a HEALTHY long step was self-aborted (rc=$R1_RC, deadline_rows=${R1_ABORTS:-?}) — the flapping-monitor false-positive"
fi

# ROW1 teeth: a before-only stamp + healthy tail under a SHORTER threshold MUST
# be aborted — if it were not, ROW1 would be vacuous (it would pass even with a
# constant/broken heartbeat).
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row1_before_only_tick() {
  bridge_daemon_tick_progress_touch "ba_step"
  sleep 6   # opaque work, NO mid-step stamp
  return 0
}
reset_audit
R1T_RC=0
( export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=2
  export BRIDGE_DAEMON_TICK_GRACE_SECONDS=0
  export BRIDGE_DAEMON_TICK_POLL_SECONDS=1
  bridge_daemon_run_tick_supervised 91 row1_before_only_tick ) || R1T_RC=$?
R1T_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( R1T_RC == ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99} )) && [[ "${R1T_ABORTS:-0}" != "0" ]]; then
  _pass "ROW1-teeth before-only stamp + opaque tail + short threshold → DOES abort (rc=$R1T_RC) — the negative control has bite"
else
  _fail "ROW1-teeth" "before-only + short threshold was NOT aborted (rc=$R1T_RC, rows=${R1T_ABORTS:-?}) — ROW1 negative control is vacuous"
fi

# ===========================================================================
# ROW 2 — genuinely wedged unbounded step → self-abort within (max-step+grace).
#         Teeth: a fresh heartbeat (kept-alive sidecar) must PREVENT the abort.
# ===========================================================================
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row2_wedged_tick() {
  bridge_daemon_tick_progress_touch "wedge_step"
  sleep 600   # unbounded hang, NO further progress
  return 0
}
reset_audit
R2_START="$(date +%s)"
R2_RC=0
bridge_daemon_run_tick_supervised 2 row2_wedged_tick || R2_RC=$?
R2_END="$(date +%s)"
R2_ELAPSED=$(( R2_END - R2_START ))
R2_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( R2_RC == ${BRIDGE_DAEMON_TICK_WEDGE_RC:-99} )) && [[ "${R2_ABORTS:-0}" != "0" ]] \
   && (( R2_ELAPSED <= DEADLINE + 8 )); then
  _pass "ROW2 wedged unbounded step → self-abort rc=$R2_RC within ${R2_ELAPSED}s (<= deadline ${DEADLINE}s + teardown), daemon_tick_deadline_exceeded emitted"
else
  _fail "ROW2 wedge-aborts" "wedge not aborted as expected (rc=$R2_RC, rows=${R2_ABORTS:-?}, elapsed=${R2_ELAPSED}s)"
fi

# ROW2 teeth: the SAME shape but the tick keeps the heartbeat FRESH (a
# kept-alive sidecar stamps progress every second) → the supervisor must NOT
# abort it. If it aborted anyway, the wedge detector would be firing on
# liveness it can see — a false positive. The sidecar is reaped when the tick
# returns.
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row2_kept_alive_tick() {
  bridge_daemon_tick_progress_touch "alive_step"
  local k=0
  while (( k < 7 )); do
    bridge_daemon_tick_progress_touch "alive_step"
    sleep 1
    k=$(( k + 1 ))
  done
  return 0
}
reset_audit
R2T_RC=0
bridge_daemon_run_tick_supervised 92 row2_kept_alive_tick || R2T_RC=$?
R2T_ABORTS="$(audit_count daemon_tick_deadline_exceeded)"
if (( R2T_RC == 0 )) && [[ "${R2T_ABORTS:-0}" == "0" ]]; then
  _pass "ROW2-teeth a kept-fresh heartbeat (same 7s wall-clock as the wedge) PREVENTS the abort (rc=0) — the wedge detector keys on progress freshness, not wall-clock"
else
  _fail "ROW2-teeth" "a heartbeat-fresh long step was aborted (rc=$R2T_RC, rows=${R2T_ABORTS:-?}) — the wedge detector mis-fires on a live daemon"
fi

# ===========================================================================
# ROW 3 — stale timer disarmed between ticks: tick N wedges → supervisor kills
#         the child + forks a FRESH baseline; tick N+1 (healthy) does NOT
#         inherit the stale progress and abort (no cross-tick fire / orphan).
# ===========================================================================
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row3_quick_tick() {
  bridge_daemon_tick_progress_touch "quick_step"
  sleep 1
  return 0
}
reset_audit
bridge_daemon_run_tick_supervised 30 row2_wedged_tick >/dev/null 2>&1 || true   # tick N wedges
R3_RC=0
bridge_daemon_run_tick_supervised 31 row3_quick_tick || R3_RC=$?               # tick N+1 healthy
R3_HEALTHY_ABORTS="$(grep 'tick_id=31' "$AUDIT_DETAIL" 2>/dev/null | grep -c 'daemon_tick_deadline_exceeded' || true)"
if (( R3_RC == 0 )) && [[ "${R3_HEALTHY_ABORTS:-0}" == "0" ]]; then
  _pass "ROW3 the healthy tick AFTER a wedge forks a FRESH baseline → NOT aborted (no cross-tick stale-timer fire)"
else
  _fail "ROW3 cross-tick-disarm" "the healthy tick after a wedge was aborted (rc=$R3_RC, rows=${R3_HEALTHY_ABORTS:-?}) — a stale timer fired into the next tick"
fi

# ROW3 orphan teeth: the WEDGE path process-group-kills the child tree. A
# grandchild backgrounded inside a wedged tick must be reaped (no orphan).
ORPHAN_PIDFILE="$SMOKE_DIR/row3-orphan.pid"
# shellcheck disable=SC2329  # invoked via the supervisor's `"$@"`
row3_wedge_with_grandchild() {
  bridge_daemon_tick_progress_touch "gc_step"
  ( sleep 600 ) &
  printf '%s\n' "$!" >"$ORPHAN_PIDFILE"
  sleep 600
  return 0
}
reset_audit
bridge_daemon_run_tick_supervised 32 row3_wedge_with_grandchild >/dev/null 2>&1 || true
R3_GC="$(tr -dc '0-9' <"$ORPHAN_PIDFILE" 2>/dev/null | head -c 12)"
if [[ -n "$R3_GC" ]]; then
  sleep 1
  if kill -0 "$R3_GC" 2>/dev/null; then
    kill -KILL "$R3_GC" 2>/dev/null || true
    _fail "ROW3 orphan-prevention" "wedged tick's grandchild pid=$R3_GC survived the process-group kill"
  else
    _pass "ROW3-teeth wedge process-group-kills the child tree — grandchild pid=$R3_GC reaped (no orphan)"
  fi
else
  _skip "ROW3 orphan-prevention" "could not capture grandchild pid"
fi

# ===========================================================================
# ROW 4 — singleton race → exactly ONE survivor (PR-1 start-time-proof
#         eviction). Two concurrent ensure_singleton against one BRIDGE_HOME →
#         exactly one winner + the loser audits daemon_singleton_loser_exit and
#         NEVER evicts. Teeth: a recycled pid (lstart mismatch) is reclaimed
#         WITHOUT a kill.
# ===========================================================================
reset_singleton_state() {
  rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.owner" 2>/dev/null || true
  rm -rf "$BRIDGE_DAEMON_PID_FILE.lock" "$BRIDGE_DAEMON_PID_FILE.lock.d" 2>/dev/null || true
  reset_audit
}

# A stand-in daemon whose argv matches `*bridge-daemon.sh run*` (the eviction
# cmdline gate). Launched from a smoke-local path so it never resembles the real
# binary. The body is written to a FILE (NOT heredoc-stdin to a subprocess).
DAEMON_SHAPED="$SMOKE_DIR/bridge-daemon.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# Stand-in matched by *bridge-daemon.sh run*. Sleeps so kill -0 is true.\n'
  printf 'sleep 600\n'
} >"$DAEMON_SHAPED"
chmod +x "$DAEMON_SHAPED"
STANDIN_LAST_PID=""
start_standin_daemon() {
  "$DAEMON_SHAPED" run &
  STANDIN_LAST_PID=$!
  STANDIN_PIDS+=("$STANDIN_LAST_PID")
}

# A holder script that acquires the singleton, parks with the flock fd held
# until a sentinel appears. File scaffolding via `{ printf ...; } >file`.
reset_singleton_state
R4_WINLOG="$SMOKE_DIR/r4-win.log"
R4_SENTINEL="$SMOKE_DIR/r4-release"; rm -f "$R4_SENTINEL"
R4_HOLDER="$SMOKE_DIR/r4-holder.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'export BRIDGE_HOME=%q\n' "$BRIDGE_HOME"
  printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
  printf 'export BRIDGE_DAEMON_PID_FILE=%q\n' "$BRIDGE_DAEMON_PID_FILE"
  printf 'AUDIT_LOG=%q\n' "$AUDIT_LOG"
  printf 'bridge_warn() { printf "[warn] %%s\\n" "$*" >&2; }\n'
  printf 'bridge_audit_log() { printf "%%s\\n" "${2:-}" >>"$AUDIT_LOG" 2>/dev/null || true; }\n'
  printf '# shellcheck source=/dev/null\n'
  printf 'source %q\n' "$CONTROL_LIB"
  printf 'if bridge_daemon_ensure_singleton; then printf "rc=0 pid=%%s\\n" "$$" >%q; else printf "rc=1 pid=%%s\\n" "$$" >%q; fi\n' "$R4_WINLOG" "$R4_WINLOG"
  printf 'while [[ ! -f %q ]]; do sleep 0.05; done\n' "$R4_SENTINEL"
} >"$R4_HOLDER"
chmod +x "$R4_HOLDER"

bash "$R4_HOLDER" &
R4_HOLDER_PID=$!
STANDIN_PIDS+=("$R4_HOLDER_PID")
R4_WAIT=0
while [[ ! -f "$R4_WINLOG" ]] && (( R4_WAIT < 100 )); do sleep 0.05; R4_WAIT=$((R4_WAIT + 1)); done

# Competitor: a second ensure_singleton in THIS shell while the holder is alive.
# It must lose (rc=1) without evicting.
R4_LOSE_RC=0
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1 || R4_LOSE_RC=$?
R4_WIN_RC="$(awk -F'[= ]' '/^rc=/{print $2; exit}' "$R4_WINLOG" 2>/dev/null || true)"
R4_WIN_PID="$(awk -F'[= ]' '/pid=/{print $4; exit}' "$R4_WINLOG" 2>/dev/null || true)"
R4_PIDFILE_PID="$(tr -dc '0-9' <"$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true)"
R4_LOSER_ROWS="$(audit_count daemon_singleton_loser_exit)"
R4_KILL_ROWS="$(audit_count daemon_spawn_replacing_killed)"
if [[ "$R4_WIN_RC" == "0" ]] && (( R4_LOSE_RC == 1 )) \
   && [[ -n "$R4_WIN_PID" && "$R4_PIDFILE_PID" == "$R4_WIN_PID" ]] \
   && (( ${R4_LOSER_ROWS:-0} >= 1 )) && (( ${R4_KILL_ROWS:-0} == 0 )); then
  _pass "ROW4 two concurrent ensure_singleton → exactly ONE survivor (pid=$R4_WIN_PID); loser rc=1 + daemon_singleton_loser_exit, no eviction"
else
  _fail "ROW4 one-survivor" "win_rc=$R4_WIN_RC lose_rc=$R4_LOSE_RC winpid=$R4_WIN_PID pidfile=$R4_PIDFILE_PID loser_rows=${R4_LOSER_ROWS:-0} kill_rows=${R4_KILL_ROWS:-0}"
fi
touch "$R4_SENTINEL"
wait "$R4_HOLDER_PID" 2>/dev/null || true

# ROW4 teeth: a recycled pid (live, daemon-cmdline, but owner-record start_time
# does NOT match the live `ps -o lstart=`) is NOT killed — the slot is reclaimed
# via daemon_spawn_reclaim_unproven_pid. A revert to the blanket-kill eviction
# would TERM/KILL an unrelated live process (the #1563 point-3 hazard).
reset_singleton_state
start_standin_daemon; R4_RECYCLED="$STANDIN_LAST_PID"
sleep 0.3   # let ps see the new argv
printf '%s\n' "$R4_RECYCLED" >"$BRIDGE_DAEMON_PID_FILE"
{
  printf 'pid=%s\n' "$R4_RECYCLED"
  printf 'cmdline=%s\n' "$DAEMON_SHAPED run"
  printf 'start_time=%s\n' "Thu Jan  1 00:00:00 1970"
  printf 'generation=%s\n' "1"
} >"$BRIDGE_DAEMON_PID_FILE.owner"
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1
R4T_RC=$?
sleep 0.2
R4T_KILLS="$(audit_count daemon_spawn_replacing_killed)"
R4T_UNPROVEN="$(audit_count daemon_spawn_reclaim_unproven_pid)"
if (( R4T_RC == 0 )) && kill -0 "$R4_RECYCLED" 2>/dev/null \
   && (( ${R4T_KILLS:-0} == 0 )) && (( ${R4T_UNPROVEN:-0} >= 1 )); then
  _pass "ROW4-teeth recycled pid (lstart mismatch) is NOT killed — slot reclaimed via daemon_spawn_reclaim_unproven_pid, the unrelated process survives"
else
  _fail "ROW4-teeth recycled-no-kill" "rc=$R4T_RC alive=$(kill -0 "$R4_RECYCLED" 2>/dev/null && echo yes || echo no) kills=${R4T_KILLS:-0} unproven=${R4T_UNPROVEN:-0}"
fi
kill "$R4_RECYCLED" 2>/dev/null || true

# ===========================================================================
# ROW 5 + ROW 6 — admin-liveness + MCP-giveup escalation (PR-3). Extract the
# escalation functions from bridge-daemon.sh, stub the roster/heartbeat/CLI
# primitives, and drive the false-positive control surface:
#   ROW5: busy/live admin → NO escalation (the flapping-monitor guard);
#         admin-down → escalate to patch-dev ONLY after the down predicate;
#         task-create-fail → audit + retained retry (the swallowed-||true teeth).
#   ROW6: admin-self MCP-giveup → route to patch-dev when resolvable; audit-only
#         when no codex pair (never a useless self-route).
# ===========================================================================
ADMIN="patch"
ADMIN_DEV="patch-dev"
export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
export BRIDGE_DAEMON_ADMIN_DOWN_STALE_SECS=300
export BRIDGE_DAEMON_ADMIN_DOWN_COOLDOWN_SECS=1800
export BRIDGE_DAEMON_MCP_GIVEUP_ADMIN_COOLDOWN_SECS=1800
export SCRIPT_DIR="$REPO_ROOT"

# Audit detail sink that records the CSV detail for the action-with-detail
# assertions (P5 uses action=route_to_admin_dev etc.). Reuse AUDIT_DETAIL.
esc_audit_count() { grep -c "\"action\":\"$1\"" "$SMOKE_DIR/esc-audit.jsonl" 2>/dev/null || true; }
ESC_AUDIT="$SMOKE_DIR/esc-audit.jsonl"
: >"$ESC_AUDIT"
# Override bridge_audit_log for the escalation rows to a JSONL sink (so detail
# CSV is greppable, mirroring the PR-3 smoke).
# shellcheck disable=SC2329  # invoked indirectly via the bridge_audit_log alias inside run_escalation_rows
esc_bridge_audit_log() {
  local action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail) [[ -n "$detail_csv" ]] && detail_csv+=";"; detail_csv+="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '{"action":"%s","target":"%s","detail":"%s"}\n' "$action" "$target" "$detail_csv" >>"$ESC_AUDIT"
}
esc_audit_reset() { : >"$ESC_AUDIT"; }

# Extract the escalation functions into a sourceable file.
ESC_FUNCS="$SMOKE_DIR/esc-funcs.sh"
: >"$ESC_FUNCS"
ESC_OK=1
for fn in \
  bridge_daemon_admin_liveness_escalation_state_dir \
  bridge_daemon_admin_liveness_marker_file \
  bridge_daemon_resolve_admin_dev_agent \
  bridge_daemon_admin_liveness_class \
  process_daemon_admin_liveness_escalation \
  bridge_daemon_mcp_giveup_escalate_admin
do
  body="$(extract_fn "$fn" "$DAEMON_SH")"
  if [[ -z "$body" ]]; then
    printf '[FAIL] ROW5/6: could not extract %s from bridge-daemon.sh\n' "$fn" >&2
    ESC_OK=0
    continue
  fi
  printf '%s\n\n' "$body" >>"$ESC_FUNCS"
done

if (( ESC_OK == 1 )); then
  # Stub primitives in a subshell so the escalation overrides + the JSONL audit
  # sink never leak into the rest of the matrix.
  run_escalation_rows() {
    # Roster predicate: ADMIN + ADMIN_DEV exist by default.
    declare -gA _SMOKE_AGENT_EXISTS=()
    _SMOKE_AGENT_EXISTS["$ADMIN"]=1
    _SMOKE_AGENT_EXISTS["$ADMIN_DEV"]=1
    # shellcheck disable=SC2329  # invoked indirectly by the extracted PR-3 funcs
    bridge_agent_exists() { [[ "${_SMOKE_AGENT_EXISTS[$1]:-0}" == "1" ]]; }
    _SMOKE_ACTIVITY_STATE="stopped"
    # shellcheck disable=SC2329  # invoked indirectly by the extracted PR-3 funcs
    bridge_agent_heartbeat_activity_state() { printf '%s' "$_SMOKE_ACTIVITY_STATE"; }
    # shellcheck disable=SC2329  # invoked indirectly by the extracted PR-3 funcs
    bridge_agent_heartbeat_state_file() { printf '%s/heartbeat/%s.env' "$BRIDGE_STATE_DIR" "$1"; }
    # shellcheck disable=SC2329  # invoked indirectly by the extracted PR-3 funcs
    daemon_source_state_file() {
      local file="$1"
      [[ -f "$file" ]] || return 1
      # shellcheck source=/dev/null
      source "$file" 2>/dev/null || return 1
      return 0
    }
    seed_heartbeat() {
      local agent="$1" updated_ts="$2" f
      f="$(bridge_agent_heartbeat_state_file "$agent")"
      mkdir -p "$(dirname "$f")"
      { printf 'HEARTBEAT_UPDATED_TS=%s\n' "$updated_ts"
        printf 'HEARTBEAT_NEXT_TS=%s\n' "$((updated_ts + 300))"; } >"$f"
    }
    clear_heartbeat() { rm -f "$(bridge_agent_heartbeat_state_file "$1")" 2>/dev/null || true; }

    # Mock CLI under BRIDGE_HOME so target_bridge resolves to it; rc controlled
    # by a sentinel file. File scaffolding via `{ printf ...; } >file`.
    MOCK_BIN="$BRIDGE_HOME/agent-bridge"
    TASK_LOG="$SMOKE_DIR/esc-task.log"
    RC_FILE="$SMOKE_DIR/esc-task.rc"
    : >"$TASK_LOG"; printf '0' >"$RC_FILE"
    { printf '#!/usr/bin/env bash\n'
      printf 'if [[ "${1:-}" == "task" && "${2:-}" == "create" ]]; then\n'
      printf '  printf "%%s\\n" "$*" >>%q\n' "$TASK_LOG"
      printf '  exit "$(cat %q 2>/dev/null || printf 0)"\n' "$RC_FILE"
      printf 'fi\nexit 0\n'; } >"$MOCK_BIN"
    chmod 0755 "$MOCK_BIN"
    task_create_count() { grep -c . "$TASK_LOG" 2>/dev/null || true; }
    task_log_reset() { : >"$TASK_LOG"; }
    set_task_rc() { printf '%s' "$1" >"$RC_FILE"; }

    # Route audits to the JSONL sink for these rows.
    # shellcheck disable=SC2329  # invoked indirectly by the extracted PR-3 funcs
    bridge_audit_log() { esc_bridge_audit_log "$@"; }

    # shellcheck source=/dev/null
    source "$ESC_FUNCS"

    reset_esc() {
      esc_audit_reset; task_log_reset; set_task_rc 0
      rm -rf "$BRIDGE_STATE_DIR/admin-liveness-escalations" 2>/dev/null || true
    }

    # --- ROW5: busy admin → NO escalate (the negative control). ---
    local now state class ok5=1
    now="$(date +%s)"
    for state in working starting picker_blocked idle; do
      reset_esc
      _SMOKE_ACTIVITY_STATE="$state"
      seed_heartbeat "$ADMIN" "$(( now - 9999 ))"   # VERY stale heartbeat, but session live
      class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
      [[ "$class" == "alive" ]] || { ok5=0; printf '[detail] ROW5: state=%s classified %s, expected alive\n' "$state" "$class" >&2; }
      process_daemon_admin_liveness_escalation || true
      [[ "$(task_create_count)" == "0" ]] || { ok5=0; printf '[detail] ROW5: state=%s produced an escalation task\n' "$state" >&2; }
      [[ "$(esc_audit_count daemon_admin_down_escalated)" == "0" ]] || { ok5=0; printf '[detail] ROW5: state=%s emitted an escalation audit\n' "$state" >&2; }
    done
    if (( ok5 == 1 )); then
      printf 'ROW5-busy:PASS\n'
    else
      printf 'ROW5-busy:FAIL\n'
    fi

    # --- ROW5: admin-down → escalate to patch-dev ONLY after the predicate. ---
    reset_esc
    _SMOKE_ACTIVITY_STATE="stopped"
    seed_heartbeat "$ADMIN" "$(( now - 600 ))"   # 600s > 300s threshold → down
    class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
    process_daemon_admin_liveness_escalation || true
    if [[ "$class" == "down" ]] && [[ "$(task_create_count)" == "1" ]] \
       && grep -q -- "--to $ADMIN_DEV" "$TASK_LOG" && grep -q -- "--from daemon" "$TASK_LOG" \
       && [[ "$(esc_audit_count daemon_admin_down_escalated)" == "1" ]]; then
      printf 'ROW5-down:PASS\n'
    else
      printf 'ROW5-down:FAIL class=%s tasks=%s\n' "$class" "$(task_create_count)"
    fi

    # --- ROW5: fresh admin (no heartbeat) → unknown grace → NO escalate. ---
    reset_esc
    _SMOKE_ACTIVITY_STATE="stopped"
    clear_heartbeat "$ADMIN"
    class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
    process_daemon_admin_liveness_escalation || true
    if [[ "$class" == "unknown" ]] && [[ "$(task_create_count)" == "0" ]]; then
      printf 'ROW5-grace:PASS\n'
    else
      printf 'ROW5-grace:FAIL class=%s tasks=%s\n' "$class" "$(task_create_count)"
    fi

    # --- ROW5 teeth: task-create-fail → audit + retained retry (no marker). ---
    reset_esc
    _SMOKE_ACTIVITY_STATE="stopped"
    seed_heartbeat "$ADMIN" "$(( now - 600 ))"
    set_task_rc 1
    process_daemon_admin_liveness_escalation || true
    local marker="$BRIDGE_STATE_DIR/admin-liveness-escalations/${ADMIN}.ts"
    local f1="$(esc_audit_count daemon_escalation_task_create_failed)"
    local s1="$(esc_audit_count daemon_admin_down_escalated)"
    local m1="absent"; [[ -f "$marker" ]] && m1="present"
    process_daemon_admin_liveness_escalation || true   # next tick re-attempts
    local attempts2="$(task_create_count)"
    if [[ "$f1" == "1" && "$s1" == "0" && "$m1" == "absent" && "$attempts2" == "2" ]]; then
      printf 'ROW5-teeth:PASS\n'
    else
      printf 'ROW5-teeth:FAIL failrow=%s successrow=%s marker=%s attempts2=%s\n' "$f1" "$s1" "$m1" "$attempts2"
    fi

    # --- ROW6: MCP-giveup admin-self → route to patch-dev (resolvable). ---
    reset_esc
    bridge_daemon_mcp_giveup_escalate_admin "$ADMIN" "plugin:teams@agent-bridge" "$now" || true
    if [[ "$(task_create_count)" == "1" ]] && grep -q -- "--to $ADMIN_DEV" "$TASK_LOG" \
       && [[ "$(esc_audit_count plugin_mcp_liveness_giveup_admin_self)" == "1" ]] \
       && grep -q 'action=route_to_admin_dev' "$ESC_AUDIT" \
       && [[ "$(esc_audit_count plugin_mcp_liveness_giveup_escalated)" == "1" ]]; then
      printf 'ROW6-self-route:PASS\n'
    else
      printf 'ROW6-self-route:FAIL tasks=%s\n' "$(task_create_count)"
    fi

    # --- ROW6 teeth: admin-self with NO codex pair → audit-only, no task. ---
    reset_esc
    unset '_SMOKE_AGENT_EXISTS[patch-dev]'
    bridge_daemon_mcp_giveup_escalate_admin "$ADMIN" "plugin:teams@agent-bridge" "$now" || true
    if [[ "$(task_create_count)" == "0" ]] \
       && [[ "$(esc_audit_count plugin_mcp_liveness_giveup_admin_self)" == "1" ]] \
       && grep -q 'action=audit_only_no_admin_dev' "$ESC_AUDIT" \
       && [[ "$(esc_audit_count plugin_mcp_liveness_giveup_escalated)" == "0" ]]; then
      printf 'ROW6-no-pair:PASS\n'
    else
      printf 'ROW6-no-pair:FAIL tasks=%s\n' "$(task_create_count)"
    fi
  }

  ESC_OUT="$(run_escalation_rows 2>"$SMOKE_DIR/esc-detail.log")"

  emit_esc_row() {
    local key="$1" label="$2"
    if printf '%s\n' "$ESC_OUT" | grep -q "^${key}:PASS"; then
      _pass "$label"
    else
      local line; line="$(printf '%s\n' "$ESC_OUT" | grep "^${key}:" | head -n1)"
      _fail "$label" "${line:-no result emitted} (detail: $SMOKE_DIR/esc-detail.log)"
    fi
  }
  emit_esc_row ROW5-busy      "ROW5 busy/idle admin (working/starting/picker_blocked/idle, even with a stale heartbeat) → class alive → NO escalation (the flapping-monitor guard)"
  emit_esc_row ROW5-down      "ROW5 admin-down (stopped + stale heartbeat past threshold) → escalate exactly once to patch-dev (--from daemon), daemon_admin_down_escalated emitted"
  emit_esc_row ROW5-grace     "ROW5 fresh admin (no heartbeat state) → unknown grace → NO escalation (no false-positive on a host just started watching)"
  emit_esc_row ROW5-teeth     "ROW5-teeth task-create-fail → daemon_escalation_task_create_failed audited + NO success row + NO cooldown marker + next tick re-attempts (the swallowed-||true revert is caught)"
  emit_esc_row ROW6-self-route "ROW6 admin-self MCP-giveup with a codex pair → durable task routed to patch-dev (action=route_to_admin_dev), not a useless self-route"
  emit_esc_row ROW6-no-pair   "ROW6-teeth admin-self MCP-giveup with NO codex pair → audit-only (action=audit_only_no_admin_dev), no task, no escalation"
else
  _fail "ROW5/6 extract" "could not extract the PR-3 escalation functions from bridge-daemon.sh"
fi

# ===========================================================================
# ROW 7 — A2A receiver supervision (PR-4). The portable, deterministic core of
# the backoff/breaker policy + the exit-cause classifier, driven as units:
#   - transient (config+secret VALID) → backoff `wait` (no immediate respawn)
#     until the open threshold → `open` (stop respawning + escalate);
#   - a real crash after a healthy bind → bounded restart (`retry`/legacy cap);
#   - auth/config error → HELD immediately, NEVER the transient backoff path;
#   - the fail-closed bind/HMAC boundary is UNTOUCHED (the classifier is
#     observability-only — it changes supervision policy, not what is accepted).
# The live receiver bind/HMAC refusal is covered end-to-end by
# 1563-pr4-a2a-receiver-healthz; here we pin the fail-closed INTACT property
# structurally + the decision-policy teeth deterministically.
# ===========================================================================
ROW7_OUT="$(
  set +e
  # Test the documented DEFAULTS, then assert the decision words.
  unset BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS \
        BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS \
        BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD
  # shellcheck source=/dev/null
  source "$A2A_LIB" 2>/dev/null
  # Exponential, capped backoff.
  printf 'b1=%s\n' "$(bridge_a2a_backoff_seconds 1)"
  printf 'b2=%s\n' "$(bridge_a2a_backoff_seconds 2)"
  printf 'bcap=%s\n' "$(bridge_a2a_backoff_seconds 99)"
  # Breaker opens at the default threshold (5).
  if bridge_a2a_breaker_should_open 4; then printf 'open4=yes\n'; else printf 'open4=no\n'; fi
  if bridge_a2a_breaker_should_open 5; then printf 'open5=yes\n'; else printf 'open5=no\n'; fi
  # Decision words: transient inside backoff → wait (no respawn); transient over
  # threshold → open; auth_config → hold (never the transient path); a real exit
  # (unknown) → retry (bounded restart, NOT held, NOT backed off).
  printf 'd_wait=%s\n' "$(bridge_a2a_supervise_decision transient 1 100 100)"
  printf 'd_retry=%s\n' "$(bridge_a2a_supervise_decision transient 1 0 100000)"
  printf 'd_open=%s\n' "$(bridge_a2a_supervise_decision transient 5 0 100000)"
  printf 'd_auth=%s\n' "$(bridge_a2a_supervise_decision auth_config 0 0 0)"
  printf 'd_unknown=%s\n' "$(bridge_a2a_supervise_decision unknown 9 0 100)"
)"
ROW7_POLICY_OK=1
for kv in b1=30 b2=60 bcap=900 open4=no open5=yes d_wait=wait d_retry=retry d_open=open d_auth=hold d_unknown=retry; do
  case "$ROW7_OUT" in
    *"$kv"*) : ;;
    *) ROW7_POLICY_OK=0; printf '[detail] ROW7: missing policy fact %s in:\n%s\n' "$kv" "$ROW7_OUT" >&2 ;;
  esac
done
if (( ROW7_POLICY_OK == 1 )); then
  _pass "ROW7 A2A supervision policy: transient backs off (wait, no respawn) → opens at threshold; a real exit retries (bounded); auth/config HELD (never the transient thrash)"
else
  _fail "ROW7 supervision-policy" "the backoff/breaker/decision policy regressed (see detail above)"
fi

# ROW7 classifier teeth: the exit-cause classifier tags transient vs auth_config
# from the receiver's own audit phase/code — this is what KEEPS an auth/config
# error OUT of the transient backoff path. A revert that classified a config
# error as transient would thrash it.
ROW7_CLS_DIR="$SMOKE_DIR/row7-classify"
mkdir -p "$ROW7_CLS_DIR"
printf '%s\n' '{"event":"startup_fail","code":"tailscale_unavailable","phase":"bind","detail":"tailnet down"}' >"$ROW7_CLS_DIR/transient.jsonl"
printf '%s\n' '{"event":"startup_fail","code":"peer_no_secret","phase":"config","detail":"no secret"}' >"$ROW7_CLS_DIR/auth.jsonl"
: >"$ROW7_CLS_DIR/empty.log"
R7_T="$(python3 "$EXIT_CAUSE_PY" "$ROW7_CLS_DIR/out-t.json" "$ROW7_CLS_DIR/empty.log" "$ROW7_CLS_DIR/transient.jsonl" bind_proof_failed 123 1000 20 2>/dev/null || true)"
R7_A="$(python3 "$EXIT_CAUSE_PY" "$ROW7_CLS_DIR/out-a.json" "$ROW7_CLS_DIR/empty.log" "$ROW7_CLS_DIR/auth.jsonl" startup_fail 123 1000 20 2>/dev/null || true)"
if printf '%s' "$R7_T" | grep -q 'transient' && printf '%s' "$R7_A" | grep -q 'auth_config' \
   && grep -q '"error_class": "transient"' "$ROW7_CLS_DIR/out-t.json" 2>/dev/null \
   && grep -q '"error_class": "auth_config"' "$ROW7_CLS_DIR/out-a.json" 2>/dev/null; then
  _pass "ROW7-teeth exit-cause classifier tags bind-phase tailscale_unavailable=transient and config-phase peer_no_secret=auth_config — the auth/config error stays OUT of the transient backoff thrash"
else
  _fail "ROW7-teeth classifier" "classifier did not tag transient/auth_config correctly (t='$R7_T' a='$R7_A')"
fi

# ROW7 fail-closed INTACT (structural): the supervisor's restart NEVER passes
# the smoke-only insecure-bind escape hatches, and `start` re-runs the full
# fail-closed preflight. A revert that loosened this would let an auto-restart
# bring the receiver up under a degraded loopback/secret-bypass bind. The live
# 401/403/bind refusal is exercised by 1563-pr4-a2a-receiver-healthz; here we
# pin the supervisor wiring that keeps the boundary unchanged.
SUP_BODY="$(extract_fn process_a2a_receiver_supervise_tick "$DAEMON_SH")"
if [[ -n "$SUP_BODY" ]] \
   && printf '%s\n' "$SUP_BODY" | grep -q 'env -u BRIDGE_A2A_ALLOW_TEST_BIND -u BRIDGE_A2A_DEV_INSECURE_BIND' \
   && printf '%s\n' "$SUP_BODY" | grep -q 'bridge-handoff-daemon.sh" start'; then
  _pass "ROW7 fail-closed INTACT: the supervisor restart scrubs BRIDGE_A2A_ALLOW_TEST_BIND/BRIDGE_A2A_DEV_INSECURE_BIND and uses the start verb (full preflight) — the bind/HMAC boundary is unchanged by the supervision policy"
else
  _fail "ROW7 fail-closed-wiring" "the supervisor restart no longer scrubs the insecure-bind escape hatches / no longer uses the start verb — the fail-closed boundary may have loosened"
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 1563-pr5-fp-control-matrix: %d checks (%d skipped) — 7-row daemon-redesign false-positive control surface verified\n' "$TOTAL" "$SKIPS"
  exit 0
fi
printf '[FAIL] 1563-pr5-fp-control-matrix: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
