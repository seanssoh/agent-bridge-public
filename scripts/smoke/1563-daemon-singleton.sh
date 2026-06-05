#!/usr/bin/env bash
# scripts/smoke/1563-daemon-singleton.sh — unit + live smoke for the
# #1563 PR-1 daemon SINGLETON HARDENING (the rc2 foundation).
#
# Root cause (#1276/#1563/#1463): TWO concurrent `bridge-daemon.sh run`
# were observed live. The flock singleton exists, but a supervisor-restart
# race window (the exiting old daemon's lock-fd releases async while
# launchd KeepAlive / systemd respawns a new one) plus a recycled-pid
# eviction path let two coexist or let an unrelated process get killed.
#
# PR-1 hardens the singleton so (the invariant this smoke proves):
#   1. Exactly ONE daemon owns the lock AND publishes the active-generation
#      owner record (pid + cmdline + start_time + generation).
#   2. A LOSER exits cleanly (audit `daemon_singleton_loser_exit`) and
#      NEVER evicts the live holder.
#   3. A stale predecessor is reclaimed/evicted ONLY after positive proof
#      (PID-not-alive OR cmdline-mismatch OR start-time-mismatch). A
#      recycled pid (same number, different `ps -o lstart=`) is NOT the
#      holder → reclaim the slot WITHOUT signalling it.
#   4. The process-lifetime flock fd-hold + mkdir fallback are preserved.
#
# Everything sourced here is the REAL shipped lib (lib/bridge-daemon-
# control.sh), not a copy, so a revert of the hardening fails this smoke.
#
# Assertions:
#   A  — two concurrent ensure_singleton against one BRIDGE_HOME → exactly
#        ONE winner; the loser returns 1 + emits daemon_singleton_loser_exit
#        + does NOT evict (winner's pid-file + owner record intact).
#   B  — restart-race / never-evict-a-live-holder: a live holder owns the
#        flock; a competitor that opens the same lockfile gets flock -n
#        busy, loses, and the holder's process + pid-file survive.
#   C1 — stale-holder reclaim (dead pid): pid-file records a DEAD pid →
#        the next ensure_singleton wins and reclaims the slot, no kill.
#   C2 — stale-holder reclaim WITH start-time PROOF: pid-file records a
#        LIVE, daemon-cmdline pid whose `ps -o lstart=` does NOT match the
#        owner record (a recycled pid) → it is NOT killed; the slot is
#        reclaimed via daemon_spawn_reclaim_unproven_pid (the process keeps
#        running). This is the teeth for #1563 point 3.
#   C3 — proven-stale predecessor IS evictable: a live, daemon-cmdline pid
#        whose lstart MATCHES the owner record → daemon_spawn_replacing
#        (the legitimate replace path still works; the proof gate is not a
#        blanket no-kill).
#   D  — owner record shape: a successful acquire publishes pid +
#        start_time + generation under the lock.
#   E  — LIVE integration: actually spawn two `bridge-daemon.sh run` in an
#        isolated BRIDGE_HOME and assert exactly ONE survives (the smoke-
#        test harness does not exercise the real daemon; CLAUDE.md requires
#        a live isolated check for daemon submit paths).
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge
# state is touched. Stand-in daemons live on a smoke-local PATH, never the
# system binaries.
#
# Footgun #11: pipe/argv stdin only — no heredoc-stdin to subprocess.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
if [[ ! -r "$CONTROL_LIB" ]]; then
  printf '[FAIL] daemon-control lib not found at %s\n' "$CONTROL_LIB" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1563-smoke.XXXXXX")"

# Track stand-in pids so the trap can reap them even on early exit.
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

# Audit sink: the sourced lib calls bridge_audit_log for every state
# transition. Capture the action token (3rd arg) to a per-call file so the
# assertions can grep for daemon_singleton_loser_exit / daemon_started /
# daemon_spawn_* without a real audit backend.
AUDIT_LOG="$SMOKE_DIR/audit.log"
: >"$AUDIT_LOG"
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_audit_log() {
  # args: <category> <action> <actor> [--detail k=v ...]; record the action.
  printf '%s\n' "${2:-}" >>"$AUDIT_LOG" 2>/dev/null || true
}
audit_count() {
  local token="$1"
  grep -c -x "$token" "$AUDIT_LOG" 2>/dev/null | tr -dc '0-9' | head -c 8
}
reset_audit() { : >"$AUDIT_LOG"; }

# shellcheck source=/dev/null
source "$CONTROL_LIB"

for fn in bridge_daemon_ensure_singleton _bridge_daemon_proc_start_time \
          _bridge_daemon_singleton_owner_path _bridge_daemon_singleton_write_owner \
          _bridge_daemon_singleton_owner_field; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s (PR-1 hardening missing?)\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

# A stand-in "daemon" whose `ps -o args=` contains `bridge-daemon.sh run`
# (the exact substring the eviction + self-check cmdline gate matches).
# Launched from a smoke-local path so it never resembles the real daemon.
DAEMON_SHAPED="$SMOKE_DIR/bridge-daemon.sh"
cat >"$DAEMON_SHAPED" <<'STANDIN'
#!/usr/bin/env bash
# Stand-in matched by `*bridge-daemon.sh run*`. Sleeps so kill -0 is true.
sleep 600
STANDIN
chmod +x "$DAEMON_SHAPED"

STANDIN_LAST_PID=""
start_standin_daemon() {
  # Launch the daemon-shaped sleeper as `<path>/bridge-daemon.sh run` so its
  # argv matches the cmdline gate. Sets STANDIN_LAST_PID (a global, NOT a
  # command-substitution return — a `&` job inside `$(...)` runs in a
  # subshell whose $! and array mutation never reach the parent, which
  # raced the C2/C3 stand-in pids).
  "$DAEMON_SHAPED" run &
  STANDIN_LAST_PID=$!
  STANDIN_PIDS+=("$STANDIN_LAST_PID")
}

reset_state() {
  rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.owner" 2>/dev/null || true
  rm -rf "$BRIDGE_DAEMON_PID_FILE.lock" "$BRIDGE_DAEMON_PID_FILE.lock.d" 2>/dev/null || true
  reset_audit
}

# ===========================================================================
# A — two concurrent ensure_singleton → exactly ONE winner; loser audits
#     daemon_singleton_loser_exit and does NOT evict the winner.
# ===========================================================================
# We run two real `ensure_singleton` invocations as separate processes
# against the same BRIDGE_HOME. The flock backend (Linux/CI) makes the
# loser's `flock -n` fail; the mkdir backend (macOS dev) makes the loser's
# `mkdir` fail. Either way exactly one wins. Because the WINNER holds its
# flock fd for its process lifetime, it must stay alive while the loser
# runs — so we run the winner as a backgrounded holder that parks until the
# loser has finished, then we inspect the audit log + pid-file.
A_WINLOG="$SMOKE_DIR/a-win.log"
A_LOSELOG="$SMOKE_DIR/a-lose.log"
reset_state

# Holder process: source the lib, acquire, then PARK (keeping the flock fd
# open) until a sentinel file appears. Records its own pid + the rc.
A_HOLD_SENTINEL="$SMOKE_DIR/a-release"
rm -f "$A_HOLD_SENTINEL"
A_HOLDER_SCRIPT="$SMOKE_DIR/a-holder.sh"
cat >"$A_HOLDER_SCRIPT" <<HOLDER
#!/usr/bin/env bash
set -uo pipefail
export BRIDGE_HOME="$BRIDGE_HOME"
export BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_DAEMON_PID_FILE"
AUDIT_LOG="$AUDIT_LOG"
bridge_warn() { printf '[warn] %s\n' "\$*" >&2; }
bridge_audit_log() { printf '%s\n' "\${2:-}" >>"\$AUDIT_LOG" 2>/dev/null || true; }
# shellcheck source=/dev/null
source "$CONTROL_LIB"
if bridge_daemon_ensure_singleton; then
  printf 'rc=0 pid=%s\n' "\$\$" >"$A_WINLOG"
else
  printf 'rc=1 pid=%s\n' "\$\$" >"$A_WINLOG"
fi
# Park with the flock fd held for our process lifetime until released.
while [[ ! -f "$A_HOLD_SENTINEL" ]]; do sleep 0.05; done
HOLDER
chmod +x "$A_HOLDER_SCRIPT"

bash "$A_HOLDER_SCRIPT" &
A_HOLDER_PID=$!
STANDIN_PIDS+=("$A_HOLDER_PID")
# Wait for the holder to have acquired (its win-log appears).
A_WAIT=0
while [[ ! -f "$A_WINLOG" ]] && (( A_WAIT < 100 )); do sleep 0.05; A_WAIT=$((A_WAIT + 1)); done

# Competitor: a second ensure_singleton in THIS shell while the holder is
# alive. It must lose (rc=1) without evicting.
A_LOSE_RC=0
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1 || A_LOSE_RC=$?
printf 'rc=%s pid=%s\n' "$A_LOSE_RC" "$$" >"$A_LOSELOG"

A_WIN_RC="$(awk -F'[= ]' '/^rc=/{print $2; exit}' "$A_WINLOG" 2>/dev/null || true)"
A_WIN_PID="$(awk -F'[= ]' '/pid=/{print $4; exit}' "$A_WINLOG" 2>/dev/null || true)"
A_PIDFILE_PID="$(tr -dc '0-9' <"$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true)"
A_LOSER_EXIT_ROWS="$(audit_count daemon_singleton_loser_exit)"
A_KILL_ROWS="$(audit_count daemon_spawn_replacing_killed)"

if [[ "$A_WIN_RC" == "0" ]] && (( A_LOSE_RC == 1 )) \
   && [[ -n "$A_WIN_PID" && "$A_PIDFILE_PID" == "$A_WIN_PID" ]] \
   && (( ${A_LOSER_EXIT_ROWS:-0} >= 1 )) && (( ${A_KILL_ROWS:-0} == 0 )); then
  _pass "A: two concurrent run → one winner (pid=$A_WIN_PID), loser rc=1 + daemon_singleton_loser_exit, no eviction"
else
  _fail "A: one-survivor + loser-no-evict" "win_rc=$A_WIN_RC lose_rc=$A_LOSE_RC winpid=$A_WIN_PID pidfile=$A_PIDFILE_PID loser_exit_rows=${A_LOSER_EXIT_ROWS:-0} kill_rows=${A_KILL_ROWS:-0}"
fi

# Release the holder.
touch "$A_HOLD_SENTINEL"
wait "$A_HOLDER_PID" 2>/dev/null || true

# ===========================================================================
# B — never-evict-a-live-holder (restart-race window). A live holder owns
#     the lock; a competitor must lose and the holder's PROCESS must survive
#     (the #1563 supervisor-restart race: the loser must not TERM/KILL the
#     real holder).
# ===========================================================================
reset_state
B_HOLD_SENTINEL="$SMOKE_DIR/b-release"
rm -f "$B_HOLD_SENTINEL"
B_WINLOG="$SMOKE_DIR/b-win.log"
B_HOLDER_SCRIPT="$SMOKE_DIR/b-holder.sh"
cat >"$B_HOLDER_SCRIPT" <<HOLDER
#!/usr/bin/env bash
set -uo pipefail
export BRIDGE_HOME="$BRIDGE_HOME"
export BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_DAEMON_PID_FILE"
AUDIT_LOG="$AUDIT_LOG"
bridge_warn() { :; }
bridge_audit_log() { printf '%s\n' "\${2:-}" >>"\$AUDIT_LOG" 2>/dev/null || true; }
# shellcheck source=/dev/null
source "$CONTROL_LIB"
bridge_daemon_ensure_singleton && printf 'ok pid=%s\n' "\$\$" >"$B_WINLOG"
while [[ ! -f "$B_HOLD_SENTINEL" ]]; do sleep 0.05; done
HOLDER
chmod +x "$B_HOLDER_SCRIPT"

bash "$B_HOLDER_SCRIPT" &
B_HOLDER_PID=$!
STANDIN_PIDS+=("$B_HOLDER_PID")
B_WAIT=0
while [[ ! -f "$B_WINLOG" ]] && (( B_WAIT < 100 )); do sleep 0.05; B_WAIT=$((B_WAIT + 1)); done

# Competitor loses; holder must still be alive afterward.
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1
B_LOSE_RC=$?
if (( B_LOSE_RC == 1 )) && kill -0 "$B_HOLDER_PID" 2>/dev/null; then
  _pass "B: competitor loses (rc=1) and the LIVE holder (pid=$B_HOLDER_PID) is NOT evicted"
else
  _fail "B: never-evict-a-live-holder" "lose_rc=$B_LOSE_RC holder_alive=$(kill -0 "$B_HOLDER_PID" 2>/dev/null && echo yes || echo no)"
fi
touch "$B_HOLD_SENTINEL"
wait "$B_HOLDER_PID" 2>/dev/null || true

# ===========================================================================
# C1 — stale-holder reclaim (DEAD pid). pid-file records a pid that is NOT
#      alive → the next ensure_singleton wins and reclaims the slot. No
#      kill row (nothing alive to evict).
# ===========================================================================
reset_state
# Find a pid that is guaranteed dead: spawn a true and reap it.
( true ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true
# In the rare case the OS recycled it instantly, bump until it's not alive.
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID + 100000)); done
printf '%s\n' "$DEAD_PID" >"$BRIDGE_DAEMON_PID_FILE"
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1
C1_RC=$?
C1_PIDFILE="$(tr -dc '0-9' <"$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true)"
C1_KILLS="$(audit_count daemon_spawn_replacing_killed)"
if (( C1_RC == 0 )) && [[ "$C1_PIDFILE" == "$$" ]] && (( ${C1_KILLS:-0} == 0 )); then
  _pass "C1: dead-pid pid-file is reclaimable (rc=0, slot=$$), no kill"
else
  _fail "C1: stale dead-pid reclaim" "rc=$C1_RC pidfile=$C1_PIDFILE kills=${C1_KILLS:-0}"
fi

# ===========================================================================
# C2 — recycled-pid is NOT killed (the #1563 point-3 teeth). pid-file +
#      owner record name a LIVE, daemon-cmdline pid, but the owner record's
#      recorded start_time does NOT match the live process's `ps -o lstart=`
#      (i.e. the pid was recycled to a different generation). ensure_singleton
#      must NOT signal it — it reclaims the slot via
#      daemon_spawn_reclaim_unproven_pid and the stand-in keeps running.
# ===========================================================================
reset_state
start_standin_daemon; RECYCLED_PID="$STANDIN_LAST_PID"
sleep 0.3  # let ps see the new argv
# Record this pid in the pid-file AND an owner record, but with a bogus
# start_time so the live lstart cannot match (simulates pid recycling).
printf '%s\n' "$RECYCLED_PID" >"$BRIDGE_DAEMON_PID_FILE"
OWNER_PATH="$BRIDGE_DAEMON_PID_FILE.owner"
{
  printf 'pid=%s\n' "$RECYCLED_PID"
  printf 'cmdline=%s\n' "$DAEMON_SHAPED run"
  printf 'start_time=%s\n' "Thu Jan  1 00:00:00 1970"
  printf 'generation=%s\n' "1"
} >"$OWNER_PATH"
( bridge_daemon_ensure_singleton ) >/dev/null 2>&1
C2_RC=$?
sleep 0.2
C2_KILLS="$(audit_count daemon_spawn_replacing_killed)"
C2_REPLACING="$(audit_count daemon_spawn_replacing)"
C2_UNPROVEN="$(audit_count daemon_spawn_reclaim_unproven_pid)"
if (( C2_RC == 0 )) && kill -0 "$RECYCLED_PID" 2>/dev/null \
   && (( ${C2_KILLS:-0} == 0 )) && (( ${C2_REPLACING:-0} == 0 )) \
   && (( ${C2_UNPROVEN:-0} >= 1 )); then
  _pass "C2: recycled pid (lstart mismatch) is NOT killed — slot reclaimed via daemon_spawn_reclaim_unproven_pid, process survives"
else
  _fail "C2: recycled-pid no-kill (start-time proof)" "rc=$C2_RC alive=$(kill -0 "$RECYCLED_PID" 2>/dev/null && echo yes || echo no) kills=${C2_KILLS:-0} replacing=${C2_REPLACING:-0} unproven=${C2_UNPROVEN:-0}"
fi
kill "$RECYCLED_PID" 2>/dev/null || true

# ===========================================================================
# C3 — proven-stale predecessor IS evictable (the gate is not a blanket
#      no-kill). pid-file + owner record name a LIVE, daemon-cmdline pid
#      whose owner-record start_time MATCHES its live `ps -o lstart=` → this
#      is a genuine stale predecessor → daemon_spawn_replacing fires and the
#      stand-in is terminated.
# ===========================================================================
reset_state
start_standin_daemon; PRED_PID="$STANDIN_LAST_PID"
sleep 0.3
PRED_START="$(_bridge_daemon_proc_start_time "$PRED_PID" 2>/dev/null || true)"
printf '%s\n' "$PRED_PID" >"$BRIDGE_DAEMON_PID_FILE"
{
  printf 'pid=%s\n' "$PRED_PID"
  printf 'cmdline=%s\n' "$DAEMON_SHAPED run"
  printf 'start_time=%s\n' "$PRED_START"
  printf 'generation=%s\n' "999"
} >"$BRIDGE_DAEMON_PID_FILE.owner"
if [[ -z "$PRED_START" ]]; then
  _fail "C3: setup" "could not read predecessor start_time via ps -o lstart= (ps unavailable?)"
else
  ( bridge_daemon_ensure_singleton ) >/dev/null 2>&1
  C3_RC=$?
  C3_REPLACING="$(audit_count daemon_spawn_replacing)"
  # The stand-in should be terminated (TERM within the 10s grace).
  C3_WAIT=0
  while kill -0 "$PRED_PID" 2>/dev/null && (( C3_WAIT < 30 )); do sleep 0.2; C3_WAIT=$((C3_WAIT + 1)); done
  C3_DEAD="no"; kill -0 "$PRED_PID" 2>/dev/null || C3_DEAD="yes"
  if (( C3_RC == 0 )) && (( ${C3_REPLACING:-0} >= 1 )) && [[ "$C3_DEAD" == "yes" ]]; then
    _pass "C3: proven-stale predecessor (lstart MATCHES owner record) IS evicted via daemon_spawn_replacing"
  else
    _fail "C3: proven-stale evictable" "rc=$C3_RC replacing=${C3_REPLACING:-0} predecessor_dead=$C3_DEAD"
  fi
fi
kill "$PRED_PID" 2>/dev/null || true

# ===========================================================================
# D — owner record shape: a clean acquire publishes pid + start_time +
#     generation under the lock. Run a short-lived holder, read the record
#     while it is held.
# ===========================================================================
reset_state
D_SENTINEL="$SMOKE_DIR/d-release"; rm -f "$D_SENTINEL"
D_DONE="$SMOKE_DIR/d-done"
D_HOLDER="$SMOKE_DIR/d-holder.sh"
cat >"$D_HOLDER" <<HOLDER
#!/usr/bin/env bash
set -uo pipefail
export BRIDGE_HOME="$BRIDGE_HOME"
export BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_DAEMON_PID_FILE"
bridge_warn() { :; }
bridge_audit_log() { :; }
# shellcheck source=/dev/null
source "$CONTROL_LIB"
bridge_daemon_ensure_singleton && printf '%s' "\$\$" >"$D_DONE"
while [[ ! -f "$D_SENTINEL" ]]; do sleep 0.05; done
HOLDER
chmod +x "$D_HOLDER"
bash "$D_HOLDER" &
D_PID=$!
STANDIN_PIDS+=("$D_PID")
D_WAIT=0
while [[ ! -f "$D_DONE" ]] && (( D_WAIT < 100 )); do sleep 0.05; D_WAIT=$((D_WAIT + 1)); done
D_OWNER="$BRIDGE_DAEMON_PID_FILE.owner"
D_REC_PID="$(_bridge_daemon_singleton_owner_field pid 2>/dev/null || true)"
D_REC_START="$(_bridge_daemon_singleton_owner_field start_time 2>/dev/null || true)"
D_REC_GEN="$(_bridge_daemon_singleton_owner_field generation 2>/dev/null || true)"
D_HOLDER_PID="$(cat "$D_DONE" 2>/dev/null | tr -dc '0-9')"
if [[ -f "$D_OWNER" ]] && [[ -n "$D_REC_PID" && "$D_REC_PID" == "$D_HOLDER_PID" ]] \
   && [[ -n "$D_REC_START" ]] && [[ "$D_REC_GEN" =~ ^[0-9] ]]; then
  _pass "D: owner record published under the lock (pid=$D_REC_PID, start_time present, generation=$D_REC_GEN)"
else
  _fail "D: owner record shape" "owner_exists=$([[ -f "$D_OWNER" ]] && echo yes || echo no) rec_pid=$D_REC_PID holder=$D_HOLDER_PID start='$D_REC_START' gen='$D_REC_GEN'"
fi
touch "$D_SENTINEL"
wait "$D_PID" 2>/dev/null || true

# ===========================================================================
# E — LIVE integration: actually spawn TWO `bridge-daemon.sh run` against a
#     FRESH isolated BRIDGE_HOME and assert exactly ONE survives. This is the
#     real-daemon check CLAUDE.md requires (the smoke-test harness does not
#     exercise the live daemon). Bounded: each daemon is given a tiny window
#     then both are reaped; we count how many are still alive + holding the
#     pid-file.
# ===========================================================================
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
if [[ ! -r "$DAEMON_SH" ]]; then
  _fail "E: bridge-daemon.sh present" "not readable at $DAEMON_SH"
else
  E_HOME="$SMOKE_DIR/live-home"
  E_STATE="$E_HOME/state"
  mkdir -p "$E_STATE"
  E_PIDFILE="$E_STATE/daemon.pid"
  E_LOG1="$SMOKE_DIR/e-d1.log"
  E_LOG2="$SMOKE_DIR/e-d2.log"
  # Spawn two real daemons racing the same BRIDGE_HOME. Fast interval so
  # they tick; we only need them up long enough to race ensure_singleton.
  spawn_live_daemon() {
    local logf="$1"
    env BRIDGE_HOME="$E_HOME" BRIDGE_STATE_DIR="$E_STATE" \
        BRIDGE_DAEMON_PID_FILE="$E_PIDFILE" BRIDGE_DAEMON_INTERVAL=1 \
        BRIDGE_DAEMON_HEARTBEAT_SECONDS=1 \
        bash "$DAEMON_SH" run >"$logf" 2>&1 &
    local p=$!
    STANDIN_PIDS+=("$p")
    printf '%s' "$p"
  }
  E_P1="$(spawn_live_daemon "$E_LOG1")"
  E_P2="$(spawn_live_daemon "$E_LOG2")"
  # Give them time to both reach ensure_singleton and for the loser to exit.
  E_WAIT=0
  while (( E_WAIT < 60 )); do
    sleep 0.25
    E_ALIVE=0
    kill -0 "$E_P1" 2>/dev/null && E_ALIVE=$((E_ALIVE + 1))
    kill -0 "$E_P2" 2>/dev/null && E_ALIVE=$((E_ALIVE + 1))
    # Once exactly one remains, we can stop early.
    (( E_ALIVE <= 1 )) && break
    E_WAIT=$((E_WAIT + 1))
  done
  E_SURVIVORS=0
  kill -0 "$E_P1" 2>/dev/null && E_SURVIVORS=$((E_SURVIVORS + 1))
  kill -0 "$E_P2" 2>/dev/null && E_SURVIVORS=$((E_SURVIVORS + 1))
  E_PIDFILE_PID="$(tr -dc '0-9' <"$E_PIDFILE" 2>/dev/null || true)"
  # Exactly one survivor, and the pid-file names a LIVE process.
  E_PIDFILE_ALIVE="no"
  [[ -n "$E_PIDFILE_PID" ]] && kill -0 "$E_PIDFILE_PID" 2>/dev/null && E_PIDFILE_ALIVE="yes"
  if (( E_SURVIVORS == 1 )) && [[ "$E_PIDFILE_ALIVE" == "yes" ]]; then
    _pass "E: two LIVE 'bridge-daemon.sh run' raced → exactly ONE survivor (pid-file=$E_PIDFILE_PID alive)"
  else
    _fail "E: live one-survivor" "survivors=$E_SURVIVORS pidfile=$E_PIDFILE_PID pidfile_alive=$E_PIDFILE_ALIVE (logs: $E_LOG1 / $E_LOG2)"
  fi
  # Reap both live daemons.
  kill -TERM "$E_P1" "$E_P2" 2>/dev/null || true
  sleep 0.5
  kill -KILL "$E_P1" "$E_P2" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
printf '\n[summary] %d checks, %d failures\n' "$TOTAL" "$FAILS"
(( FAILS == 0 )) || exit 1
exit 0
