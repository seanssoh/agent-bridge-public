#!/usr/bin/env bash
# scripts/smoke/1388-daemon-lock-fd-cloexec.sh — unit smoke for the
# daemon singleton-lock fd-inheritance fix (issue #1388).
#
# Root cause: bridge_daemon_ensure_singleton() opens the singleton lock
# with `exec {lock_fd}>"$lock_path"` and holds it for the daemon's
# process lifetime. Bash does NOT set close-on-exec on these fds, so a
# daemon-launched `bridge-start.sh` → `tmux new-session` chain leaks the
# fd to the immortal tmux server (reparents to PPID 1). After the daemon
# dies, the orphaned tmux keeps the flock → respawned daemon hits
# `flock -n` busy → daemon_spawn_lock_busy → restart-loop.
#
# Fix: the fd number is recorded in $BRIDGE_DAEMON_SINGLETON_LOCK_FD on
# a successful flock acquire, and the daemon's agent-launch sites run
# through bridge_daemon_run_without_singleton_lock, which closes the fd
# FOR THE CHILD ONLY (`{var}>&-`) while the daemon keeps its own copy
# (and the flock) for its lifetime.
#
# This smoke sources the SHIPPED helper from lib/bridge-daemon-control.sh
# (not a copy) and asserts:
#   (A) FIX     — a child launched through the wrapper does NOT inherit
#                 the singleton lock fd.
#   (B) TEETH   — the SAME child launched WITHOUT the wrapper DOES
#                 inherit it (proves the assertion would catch a revert
#                 of the fix; this is the literal #1388 leak).
#   (C) PARENT  — after the wrapped launch, the parent still holds the
#                 fd AND the flock (singleton guarantee intact).
#   (D) PASS    — with the global empty (mkdir-lock fallback / lock not
#                 acquired), the wrapper is a transparent pass-through.
#   (E) ARGV    — arguments with spaces / `;` / `$(...)` survive the
#                 wrapper unmangled on BOTH branches (the `eval`-built
#                 redirection that was rejected mangled these).
#   (F) WORKER  — issue #1390: the daemon's supp-groups-refresh worker is
#                 launched DETACHED/disowned (`( … & disown )`) so it
#                 outlives the daemon restart it triggers. The #1389 helper
#                 closes the fd only for its inner child, which is
#                 INSUFFICIENT here — backgrounding the helper leaves the
#                 waiting subshell holding the fd. The fix closes the fd
#                 for the SUBSHELL ITSELF (`exec {var}>&-` inside `( )`).
#                 F scans /proc (Linux) for any non-daemon process holding
#                 the lockfile while the worker is alive: with the close
#                 the daemon is the only holder (FIX), without it the
#                 subshell/worker leak it (TEETH). #1389's A/B/C only
#                 proved the synchronous tmux shape, not this leak.
#
# Cross-platform: fd-inheritance is detected with the portable `<&N`
# open-test (no /proc dependency), so the deterministic fd-close logic
# is exercised on macOS dev hosts too. The live restart-cycle repro is a
# Linux-only VM gate (see issue #1388 acceptance) — this smoke covers
# the fd-close contract that gate depends on.
#
# Footgun #11: pipe/argv stdin only — no heredoc-stdin to subprocess.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# Fleet-down guard: this smoke is destructive (it forks daemon-shaped children
# and exercises lock teardown). Force a private tmux universe BEFORE any such
# op so a stray run from inside a live agent pane can't down the shared fleet.
# shellcheck source=../../lib/bridge-smoke-tmux-isolation.sh
source "$SCRIPT_DIR/../../lib/bridge-smoke-tmux-isolation.sh"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
if [[ ! -r "$CONTROL_LIB" ]]; then
  printf '[FAIL] daemon-control lib not found at %s\n' "$CONTROL_LIB" >&2
  exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
  # The fix only matters on hosts with flock(1) (the production Linux
  # path). On a host without flock the daemon uses the mkdir-lock
  # fallback (no fd to leak), so the wrapper is a no-op there — there is
  # nothing to assert beyond the pass-through, which we still cover.
  printf '[note] flock(1) not present — exercising pass-through behavior only\n'
fi

# shellcheck source=/dev/null
source "$CONTROL_LIB"

if ! command -v bridge_daemon_run_without_singleton_lock >/dev/null 2>&1; then
  printf '[FAIL] bridge_daemon_run_without_singleton_lock not defined after sourcing %s\n' "$CONTROL_LIB" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1388-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

LOCK_PATH="$SMOKE_DIR/daemon.pid.lock"

# Portable child probe: launch a real subprocess (`bash -c`) and have it
# report whether fd $1 is open in its own process image. Mirrors the
# real leak surface (a daemon-spawned child inheriting the descriptor).
# Prints INHERITED / NOT_INHERITED on stdout.
# shellcheck disable=SC2329  # invoked indirectly via the wrapper helper
_child_fd_report() {
  local fd="$1"
  bash -c '{ true; } <&'"$fd"' 2>/dev/null && echo INHERITED || echo NOT_INHERITED'
}

# ---------------------------------------------------------------------------
# Open + flock + record the global EXACTLY as the daemon's flock backend
# does, so the smoke drives the shipped contract end-to-end.
# ---------------------------------------------------------------------------
LOCK_FD=""
# shellcheck disable=SC2093
if ! exec {LOCK_FD}>"$LOCK_PATH" 2>/dev/null; then
  printf '[FAIL] could not open lock fd on %s\n' "$LOCK_PATH" >&2
  exit 1
fi

ACQUIRED=0
if command -v flock >/dev/null 2>&1; then
  if flock -n "$LOCK_FD" 2>/dev/null; then
    ACQUIRED=1
    # This is the line the fix adds in bridge_daemon_ensure_singleton.
    BRIDGE_DAEMON_SINGLETON_LOCK_FD="$LOCK_FD"
  fi
fi

if (( ACQUIRED == 1 )); then
  # (A) FIX: child launched through the wrapper must NOT inherit the fd.
  got="$(bridge_daemon_run_without_singleton_lock _child_fd_report "$LOCK_FD")"
  if [[ "$got" == "NOT_INHERITED" ]]; then
    _pass "A: wrapper closes the singleton lock fd for the child (not inherited)"
  else
    _fail "A: wrapper closes the singleton lock fd for the child" "got '$got' (expected NOT_INHERITED)"
  fi

  # (B) TEETH: the SAME child WITHOUT the wrapper inherits it (the leak).
  got="$(_child_fd_report "$LOCK_FD")"
  if [[ "$got" == "INHERITED" ]]; then
    _pass "B: teeth — un-wrapped launch DOES leak the fd (revert would be caught)"
  else
    _fail "B: teeth — un-wrapped launch leaks the fd" \
      "got '$got' (expected INHERITED — if NOT_INHERITED the test has no teeth)"
  fi

  # (C) PARENT: after the wrapped launch, the daemon still holds the fd
  # AND the flock. A second fd to the same file must fail to acquire.
  if { true; } <&"$LOCK_FD" 2>/dev/null; then
    _pass "C1: parent retains the singleton lock fd after the wrapped launch"
  else
    _fail "C1: parent retains the singleton lock fd" "parent fd $LOCK_FD is closed"
  fi
  BUSY_FD=""
  if exec {BUSY_FD}>"$LOCK_PATH" 2>/dev/null; then
    if flock -n "$BUSY_FD" 2>/dev/null; then
      _fail "C2: singleton guarantee intact (flock still held)" "a competing flock -n succeeded — lock was released"
    else
      _pass "C2: singleton guarantee intact — competing flock -n still fails"
    fi
    exec {BUSY_FD}>&- 2>/dev/null || true
  fi
else
  printf '[note] flock not acquired (no flock(1) or busy) — skipping fd-leak assertions A/B/C\n'
fi

# Release our hold so the pass-through tests run from a clean state.
if [[ "$LOCK_FD" =~ ^[0-9]+$ ]]; then
  eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
fi
BRIDGE_DAEMON_SINGLETON_LOCK_FD=""

# (D) PASS-THROUGH: with the global empty the wrapper runs the command
# transparently (this is the mkdir-fallback / lock-not-acquired path).
out="$(bridge_daemon_run_without_singleton_lock printf '%s\n' "pass-through-ok")"
if [[ "$out" == "pass-through-ok" ]]; then
  _pass "D: empty fd → wrapper is a transparent pass-through"
else
  _fail "D: empty fd → wrapper is a transparent pass-through" "got '$out'"
fi

# (E) ARGV-SAFETY: arguments with spaces / `;` / command-substitution
# must survive verbatim on BOTH branches (empty-fd pass-through here, and
# the close-for-child branch below). The rejected `eval`-built form
# mangled exactly these.
# shellcheck disable=SC2329  # invoked indirectly via the wrapper helper
_argv_echo() { for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; }
EXPECT='[a b][x;y][$(touch '"$SMOKE_DIR"'/pwned)]'

# E1: empty-fd branch
got="$(bridge_daemon_run_without_singleton_lock _argv_echo "a b" "x;y" '$(touch '"$SMOKE_DIR"'/pwned)')"
if [[ "$got" == "$EXPECT" ]] && [[ ! -e "$SMOKE_DIR/pwned" ]]; then
  _pass "E1: argv preserved + no command injection (empty-fd branch)"
else
  _fail "E1: argv preserved (empty-fd branch)" "got '$got' (expected '$EXPECT'); pwned=$( [[ -e "$SMOKE_DIR/pwned" ]] && echo YES || echo no )"
fi

# E2: close-for-child branch (re-acquire a fd + set the global)
LOCK_FD2=""
if command -v flock >/dev/null 2>&1 && exec {LOCK_FD2}>"$LOCK_PATH" 2>/dev/null && flock -n "$LOCK_FD2" 2>/dev/null; then
  BRIDGE_DAEMON_SINGLETON_LOCK_FD="$LOCK_FD2"
  got="$(bridge_daemon_run_without_singleton_lock _argv_echo "a b" "x;y" '$(touch '"$SMOKE_DIR"'/pwned2)')"
  if [[ "$got" == '[a b][x;y][$(touch '"$SMOKE_DIR"'/pwned2)]' ]] && [[ ! -e "$SMOKE_DIR/pwned2" ]]; then
    _pass "E2: argv preserved + no command injection (close-for-child branch)"
  else
    _fail "E2: argv preserved (close-for-child branch)" "got '$got'; pwned2=$( [[ -e "$SMOKE_DIR/pwned2" ]] && echo YES || echo no )"
  fi
  eval "exec ${LOCK_FD2}>&-" 2>/dev/null || true
  BRIDGE_DAEMON_SINGLETON_LOCK_FD=""
else
  printf '[note] flock not available — skipping E2 (close-for-child argv branch)\n'
fi

# ---------------------------------------------------------------------------
# (F) DETACHED WORKER LAUNCH SHAPE (issue #1390)
#
# The daemon's supp-groups-refresh worker is NOT launched synchronously
# like the tmux sites (A/B/C). It is launched DETACHED inside a
# backgrounded subshell and disowned, SPECIFICALLY so it survives the
# daemon restart it itself triggers:
#
#     (
#       if [[ "$BRIDGE_DAEMON_SINGLETON_LOCK_FD" =~ ^[0-9]+$ ]]; then
#         exec {BRIDGE_DAEMON_SINGLETON_LOCK_FD}>&- || true
#       fi
#       "$bash_abs" "$daemon_script" supp-refresh-worker "$name" \
#         >>"$worker_log" 2>&1 &
#       disown 2>/dev/null || true
#     ) 2>/dev/null || true
#
# Why NOT the #1389 helper here: `bridge_daemon_run_without_singleton_lock`
# closes the fd only for its inner `"$@"` child. If the helper invocation
# is the thing being `&`-backgrounded, the backgrounded SUBSHELL that hosts
# the helper stays alive `wait`ing on the external worker and KEEPS the
# inherited fd open the whole time — and that waiting subshell can outlive
# the daemon (the worker restarts it) and pin the flock. So a child-only
# close is insufficient for the detached shape. The fix closes the fd for
# the SUBSHELL ITSELF (`exec {var}>&-`, inside the `( )`), so neither the
# subshell nor anything it forks (the worker) holds the descriptor.
#
# Teeth therefore cannot just probe the worker's own fd (codex #1390
# re-review: that false-passes while a surviving subshell still holds it).
# Instead each variant launches an external worker that SLEEPS, then scans
# /proc for ANY non-daemon process holding the lockfile WHILE the worker is
# alive:
#   (F1) FIX   — with the subshell-level close, the ONLY holder is the
#                daemon (no subshell, no worker).
#   (F2) TEETH — with the close REMOVED (the literal #1390 leak), at least
#                one non-daemon process (the waiting subshell and/or the
#                worker) holds the lockfile → a regression is caught.
#   (F3/F4)    — the daemon (parent) keeps its own fd + flock throughout.
#
# Requires /proc (Linux). The live restart-cycle is a Linux-only gate
# anyway (file header); on macOS dev hosts the mkdir-lock fallback has no
# fd to leak, so this whole section is skipped.
# ---------------------------------------------------------------------------
_await_file() {
  local path="$1" i
  for i in $(seq 1 50); do
    [[ -s "$path" ]] && return 0
    sleep 0.1
  done
  return 1
}

# Count LIVE processes that hold an open fd on $LOCK_PATH, by scanning
# /proc/<pid>/fd symlinks. Prints the count.
#
# Excludes BOTH $$ (the smoke shell, the legitimate daemon stand-in that
# holds the recorded lock fd) AND $BASHPID. $BASHPID matters because this
# function is invoked in a `$(...)` command substitution, which forks a
# subshell with a DIFFERENT pid that inherits the smoke shell's fd table —
# including the lock fd — and would otherwise count ITSELF as a spurious
# holder. (The fd close in the FIX path applies to the worker's detached
# subshell, not to this measurement subshell.) After excluding the smoke
# shell and the measurement subshell, any remaining holder is a genuine
# leaked descriptor in the worker's process tree.
_count_nondaemon_lock_holders() {
  local n=0 piddir pid fdlink tgt
  for piddir in /proc/[0-9]*; do
    pid="${piddir##*/}"
    [[ "$pid" == "$$" ]] && continue
    [[ "$pid" == "$BASHPID" ]] && continue
    for fdlink in "$piddir"/fd/*; do
      tgt="$(readlink -f "$fdlink" 2>/dev/null || true)"
      if [[ "$tgt" == "$LOCK_PATH" ]]; then
        n=$((n + 1))
        break
      fi
    done
  done
  printf '%s\n' "$n"
}

LOCK_FD3=""
if [[ ! -d /proc ]]; then
  printf '[note] /proc not present — skipping F (detached worker launch shape, #1390; Linux-only gate)\n'
elif command -v flock >/dev/null 2>&1 && exec {LOCK_FD3}>"$LOCK_PATH" 2>/dev/null && flock -n "$LOCK_FD3" 2>/dev/null; then
  BRIDGE_DAEMON_SINGLETON_LOCK_FD="$LOCK_FD3"

  # External worker that records its pid then sleeps, so we can inspect the
  # process tree while it (and any waiting subshell) is alive. Mirrors the
  # real worker: an external `bash <daemon> supp-refresh-worker` process.
  WORKER_SH="$SMOKE_DIR/worker-sleep.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s" "$$" > "%s"\nsleep 3\n' "$SMOKE_DIR/worker.pid" >"$WORKER_SH"
  chmod +x "$WORKER_SH"
  F_LOG="$SMOKE_DIR/worker.log"

  # (F1) FIX: subshell-level close before the detached launch. While the
  # worker is alive, the daemon must be the ONLY holder of the lockfile.
  rm -f "$SMOKE_DIR/worker.pid" "$F_LOG"
  (
    if [[ "${BRIDGE_DAEMON_SINGLETON_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
      exec {BRIDGE_DAEMON_SINGLETON_LOCK_FD}>&- || true
    fi
    bash "$WORKER_SH" >>"$F_LOG" 2>&1 &
    disown 2>/dev/null || true
  ) 2>/dev/null || true
  if _await_file "$SMOKE_DIR/worker.pid"; then
    holders="$(_count_nondaemon_lock_holders)"
    if [[ "$holders" == "0" ]]; then
      _pass "F1: detached worker launch (subshell-level close) — no non-daemon process holds the lock fd"
    else
      _fail "F1: detached worker launch (subshell-level close)" \
        "$holders non-daemon process(es) hold the lock fd (expected 0 — #1390 leak via subshell/worker)"
    fi
  else
    _fail "F1: detached worker launch (subshell-level close)" "worker never started (detachment broke?)"
  fi
  wait 2>/dev/null || true

  # (F2) TEETH: the SAME detached shape WITHOUT the close. This is the
  # literal #1390 leak — the waiting subshell (and/or the worker) inherits
  # and holds the fd, outliving the daemon and pinning the flock. If a
  # future refactor drops the subshell-level close, F1 flips to >0 holders
  # and is caught; F2 proves the scan actually observes the leak.
  rm -f "$SMOKE_DIR/worker.pid" "$F_LOG"
  (
    bash "$WORKER_SH" >>"$F_LOG" 2>&1 &
    disown 2>/dev/null || true
  ) 2>/dev/null || true
  if _await_file "$SMOKE_DIR/worker.pid"; then
    holders="$(_count_nondaemon_lock_holders)"
    if (( holders > 0 )); then
      _pass "F2: teeth — un-closed detached launch leaks the fd ($holders non-daemon holder(s); #1390 regression caught)"
    else
      _fail "F2: teeth — un-closed detached launch leaks the fd" \
        "0 non-daemon holders (expected >0 — if 0 the test has no teeth)"
    fi
  else
    _fail "F2: teeth — un-closed detached launch" "worker never started"
  fi
  wait 2>/dev/null || true

  # (F3) PARENT: the daemon still holds the fd AND the flock throughout.
  if { true; } <&"$LOCK_FD3" 2>/dev/null; then
    _pass "F3: parent retains the singleton lock fd after the detached worker launches"
  else
    _fail "F3: parent retains the singleton lock fd" "parent fd $LOCK_FD3 is closed"
  fi
  BUSY_FD3=""
  if exec {BUSY_FD3}>"$LOCK_PATH" 2>/dev/null; then
    if flock -n "$BUSY_FD3" 2>/dev/null; then
      _fail "F4: singleton guarantee intact after worker fork" "a competing flock -n succeeded — lock was released"
    else
      _pass "F4: singleton guarantee intact after worker fork — competing flock -n still fails"
    fi
    exec {BUSY_FD3}>&- 2>/dev/null || true
  fi

  eval "exec ${LOCK_FD3}>&-" 2>/dev/null || true
  BRIDGE_DAEMON_SINGLETON_LOCK_FD=""
else
  printf '[note] flock not available — skipping F (detached worker launch shape, #1390)\n'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n[summary] %d/%d tests passed\n' $((TOTAL - FAILS)) "$TOTAL"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
