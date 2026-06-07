#!/usr/bin/env bash
# scripts/smoke/1661-upgrade-singleton-lock.sh — Issue #1661 smoke.
#
# `agent-bridge upgrade --apply` (and `rollback --apply`) had no singleton lock,
# so two concurrent runs against the same BRIDGE_HOME could race the daemon +
# agent mass-restart (5-process thrash on the v0.16.1 cascade rollout). Fix:
# a shared lib/bridge-lock.sh primitive (flock-first / mkdir-fallback) that the
# upgrade path acquires for MUTATING flows only, on the SAME state/locks/
# upgrade.lock for both upgrade and rollback, refuse-fast by default with an
# optional bounded --wait, released via the existing _bridge_upgrade_exit_handler
# (NOT a second EXIT trap).
#
# Coverage (sources the SHIPPED helper from lib/bridge-lock.sh — not a copy):
#   T1  refuse-fast: acquire → a SECOND refuse-fast acquire on the same lock is
#       refused (rc!=0) with a diagnostic naming the holder pid; after release,
#       a fresh acquire succeeds.
#   T2  --wait: a contender with `--wait 1` against a held lock gives up after
#       the bounded timeout (rc!=0) — proving --wait is bounded, not infinite.
#   T3  mkdir-fallback stale reclaim: simulate a crashed owner (lockdir present,
#       owner pid DEAD) → a new acquire reclaims and succeeds. Forced onto the
#       mkdir backend so the reclaim path is exercised even where flock exists.
#   T4  same-lockfile mutual exclusion: the helper does not care whether the
#       holder is an "upgrade" or a "rollback" — holding state/locks/upgrade.lock
#       refuses the other (they share one lockfile).
#   T5  upgrade.sh wiring: the script locks MUTATING flows only — `--dry-run`
#       and `analyze` do NOT acquire (no lockfile materializes), and a real
#       mutating `--apply` against a pre-held lock refuses fast.
#   T6  release-in-exit-handler, not a 2nd trap: bridge-upgrade.sh installs
#       exactly ONE `trap ... EXIT`, and its handler releases the lock token.
#
# Footgun #11: no heredoc / here-string feeding a subprocess interpreter.

set -euo pipefail

SMOKE_NAME="1661-upgrade-singleton-lock"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$SMOKE_REPO_ROOT"
LOCK_LIB="$ROOT_DIR/lib/bridge-lock.sh"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd bash
smoke_assert_file_exists "$LOCK_LIB" "lib/bridge-lock.sh present"
smoke_assert_file_exists "$UPGRADE_SH" "bridge-upgrade.sh present"

smoke_make_temp_root
LOCKDIR="$SMOKE_TMP_ROOT/locks"
mkdir -p "$LOCKDIR"

# bash 4+ is required to source lib/bridge-lock.sh (its flock branch uses the
# `exec {fd}>>` dynamic-fd form, a bash-4 feature). On macOS the bare `bash` is
# 3.2, so prefer an explicit BRIDGE_BASH_BIN, then a Homebrew bash, then PATH
# bash — and verify the chosen binary is >= 4 (fail loud rather than silently
# mis-test under 3.2).
_pick_bash() {
  local cand
  for cand in "${BRIDGE_BASH_BIN:-}" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    if [[ "$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" =~ ^[4-9]$|^[1-9][0-9]+$ ]]; then
      printf '%s' "$cand"; return 0
    fi
  done
  return 1
}
BASH_BIN="$(_pick_bash)" || smoke_fail "no bash >= 4 found (need it for the lock-lib dynamic-fd flock branch)"

# Hold the production singleton lock with a LIVE process so refuse-fast
# assertions genuinely contend on BOTH backends:
#   * flock backend (default where flock(1) exists): a live `flock -x <file> -c
#     sleep` process holds the KERNEL flock on the exact lockfile — the prod
#     helper's `flock -n` contender then sees it busy. Version-independent.
#   * mkdir backend (BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1, e.g. no flock): a live
#     bash-4 process calls bridge_scoped_lock_acquire (creates <file>.d + a
#     live-owner-pid) and sleeps; the lockdir persists with a live owner so the
#     contender's stale-reclaim never fires.
# Args: $1=lockfile $2=ready-file $3=proceed-file.
# Sets _HELD_LOCK_PID to the holder PID (NOT via $() — a bg process started in
# a command substitution dies when that subshell returns; we background it in
# the caller's own shell and return the pid through a global).
# Caller signals teardown by `: >"$3"` then `wait "$_HELD_LOCK_PID"`.
_HELD_LOCK_PID=""
_hold_lock_bg() {
  local lock="$1" ready="$2" proceed="$3"
  rm -f "$ready" "$proceed" "$lock"
  if [[ "${BRIDGE_SCOPED_LOCK_DISABLE_FLOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
    # Live kernel-flock holder (POSIX sh body — no bash version dependency).
    flock -x "$lock" -c "touch \"$ready\"; while [ ! -f \"$proceed\" ]; do sleep 0.1; done" &
  else
    # mkdir-backend holder via the prod helper in a live bash-4 process.
    BRIDGE_SCOPED_LOCK_DISABLE_FLOCK="${BRIDGE_SCOPED_LOCK_DISABLE_FLOCK:-1}" \
    "$BASH_BIN" -c '
      source "$1"
      bridge_scoped_lock_acquire "$2" || exit 9
      : >"$3"
      while [[ ! -f "$4" ]]; do sleep 0.1; done
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
    ' _ "$LOCK_LIB" "$lock" "$ready" "$proceed" &
  fi
  _HELD_LOCK_PID=$!
  local i
  for i in $(seq 1 100); do [[ -f "$ready" ]] && break; sleep 0.1; done
}

# --------------------------------------------------------------------------
# T1: refuse-fast default + release + re-acquire, proven on BOTH backends.
# A LIVE process holds the lock (via _hold_lock_bg — kernel flock or mkdir
# lockdir-with-live-owner) while a refuse-fast contender must be refused with a
# clear diagnostic; after teardown a fresh acquire must succeed. Running both
# `flock` and `BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1` (mkdir) keeps parity with
# Linux CI (flock) and macOS dev (mkdir).
# --------------------------------------------------------------------------
_refuse_fast_assert_once() {
  # $1=label-suffix (backend name) ; uses caller env BRIDGE_SCOPED_LOCK_DISABLE_FLOCK
  local backend="$1"
  local lock="$LOCKDIR/t1-$backend.lock"
  local ready="$SMOKE_TMP_ROOT/t1-$backend.ready"
  local proceed="$SMOKE_TMP_ROOT/t1-$backend.proceed"

  _hold_lock_bg "$lock" "$ready" "$proceed"
  local holder_pid="$_HELD_LOCK_PID"
  smoke_assert_file_exists "$ready" "T1[$backend] live holder acquired the lock"

  # Contender (refuse-fast): must be refused while the holder holds.
  set +e
  local out
  out="$("$BASH_BIN" -c '
    source "$1"
    if bridge_scoped_lock_acquire "$2"; then
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
      echo "ACQUIRED"
    fi
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  set -e
  smoke_assert_not_contains "$out" "ACQUIRED" "T1[$backend] refuse-fast contender did NOT acquire a held lock"
  smoke_assert_contains "$out" "already running" "T1[$backend] refuse-fast contender printed a clear diagnostic"

  # Tear down the holder, then a fresh acquire must succeed (lock free again).
  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true
  set +e
  local rc
  out="$("$BASH_BIN" -c '
    source "$1"
    bridge_scoped_lock_acquire "$2" || exit 1
    echo "ACQUIRED"
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T1[$backend] fresh acquire after release returns 0"
  smoke_assert_contains "$out" "ACQUIRED" "T1[$backend] fresh acquire after release succeeds"
}

test_refuse_fast_then_release() {
  # mkdir backend (always available).
  BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1 _refuse_fast_assert_once "mkdir"
  # flock backend (where flock(1) exists — Linux CI always; macOS with `brew
  # install flock`). Skipped only when flock is genuinely absent.
  if command -v flock >/dev/null 2>&1; then
    BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=0 _refuse_fast_assert_once "flock"
  else
    smoke_skip "T1[flock] refuse-fast" "flock(1) not installed (mkdir backend covered above)"
  fi
}

# --------------------------------------------------------------------------
# T2: --wait is bounded.
# --------------------------------------------------------------------------
test_wait_is_bounded() {
  local lock="$LOCKDIR/t2.lock"
  local ready="$SMOKE_TMP_ROOT/t2.ready"
  local proceed="$SMOKE_TMP_ROOT/t2.proceed"

  # Live holder (flock backend where available, else mkdir).
  _hold_lock_bg "$lock" "$ready" "$proceed"
  local holder_pid="$_HELD_LOCK_PID"
  smoke_assert_file_exists "$ready" "T2 live holder acquired the lock"

  # Contender with --wait 1: must give up after ~1s (bounded), NOT hang.
  set +e
  local out
  out="$("$BASH_BIN" -c '
    source "$1"
    if bridge_scoped_lock_acquire "$2" --wait 1; then
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
      echo "ACQUIRED"
    fi
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  set -e
  smoke_assert_not_contains "$out" "ACQUIRED" "T2 --wait 1 contender gave up (bounded) on a held lock"

  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# T3: mkdir-fallback stale reclaim (dead owner pid). Forced onto the mkdir
# backend via BRIDGE_SCOPED_LOCK_DISABLE_FLOCK so the reclaim path is exercised
# regardless of whether the host ships flock (CI is Linux + has flock; macOS
# does not — the seam makes the test deterministic on both).
# --------------------------------------------------------------------------
test_mkdir_stale_reclaim() {
  local lock="$LOCKDIR/t3.lock"
  local lock_dir="${lock}.d"
  # Plant a stale lockdir with a guaranteed-dead owner pid.
  mkdir -p "$lock_dir"
  printf 'pid=%s\nstarted=%s\n' "999999" "2000-01-01T00:00:00+0000" >"$lock_dir/owner"

  set +e
  local out rc
  out="$(BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1 "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    bridge_scoped_lock_acquire "$2" || exit 1
    echo "ACQUIRED token=$BRIDGE_SCOPED_LOCK_TOKEN"
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T3 stale-lock reclaim returns 0"
  smoke_assert_contains "$out" "ACQUIRED token=mkdir:" "T3 reclaimed via mkdir backend"
  [[ ! -d "$lock_dir" ]] || smoke_fail "T3 lockdir not released after reclaim+release"
}

# --------------------------------------------------------------------------
# T4: same-lockfile mutual exclusion (upgrade vs rollback share one lockfile).
# The helper is lock-name based, so two acquirers of the SAME path are mutually
# exclusive regardless of the logical operation name. (T1 already proves the
# refuse; here we assert the lockfile path the upgrade flow uses is a single
# shared name — upgrade.lock — so a held upgrade lock blocks a rollback.)
# --------------------------------------------------------------------------
test_same_lockfile_for_upgrade_and_rollback() {
  # bridge-upgrade.sh must reference exactly one lock path for both flows.
  local hits
  hits="$(grep -c 'state/locks/upgrade\.lock' "$UPGRADE_SH" || true)"
  [[ "$hits" -ge 1 ]] || smoke_fail "T4 bridge-upgrade.sh does not reference state/locks/upgrade.lock"
  # And no SECOND distinct lock path for rollback.
  if grep -Eq 'state/locks/rollback\.lock' "$UPGRADE_SH"; then
    smoke_fail "T4 rollback uses a SEPARATE lockfile — must share upgrade.lock"
  fi
  smoke_log "ok: T4 upgrade + rollback share state/locks/upgrade.lock"
}

# --------------------------------------------------------------------------
# T5: upgrade.sh wiring — mutating-only acquisition.
#   - dry-run does NOT acquire (no upgrade.lock file/dir materializes).
#   - a real mutating --apply against a PRE-HELD lock refuses fast.
# We pre-hold the lock from this shell (a background holder) and run the real
# bridge-upgrade.sh --apply; it must refuse without doing the upgrade.
# --------------------------------------------------------------------------
test_upgrade_sh_locks_mutating_only() {
  local home="$SMOKE_TMP_ROOT/uhome"
  local src="$SMOKE_TMP_ROOT/usrc"
  mkdir -p "$home/state" "$src"
  # Minimal source checkout so the script can resolve SOURCE_ROOT.
  git -C "$src" init -q
  git -C "$src" config user.email smoke@example.com
  git -C "$src" config user.name s
  git -C "$src" config commit.gpgsign false
  printf '0.16.2\n' >"$src/VERSION"
  cp "$ROOT_DIR/bridge-upgrade.sh" "$src/"
  cp "$ROOT_DIR/bridge-lib.sh" "$src/" 2>/dev/null || true

  local lock="$home/state/locks/upgrade.lock"

  # (a) dry-run must NOT materialize the lock.
  rm -rf "$home/state/locks"
  set +e
  "$BASH_BIN" "$UPGRADE_SH" --source "$src" --target "$home" --dry-run --no-pull >/dev/null 2>&1
  set -e
  if [[ -e "$lock" || -d "${lock}.d" ]]; then
    smoke_fail "T5 dry-run acquired the upgrade lock (should be read-only)"
  fi
  smoke_log "ok: T5 dry-run did NOT acquire the lock"

  # (b) a mutating --apply against a PRE-HELD lock must refuse fast.
  local ready="$SMOKE_TMP_ROOT/t5.ready"
  local proceed="$SMOKE_TMP_ROOT/t5.proceed"
  rm -f "$ready" "$proceed"
  mkdir -p "$home/state/locks"
  BRIDGE_HOME="$home" "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    bridge_scoped_lock_acquire "$2" || exit 9
    : >"$3"
    for _ in $(seq 1 100); do [[ -f "$4" ]] && break; sleep 0.1; done
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" "$ready" "$proceed" &
  local holder_pid=$!
  local i
  for i in $(seq 1 50); do [[ -f "$ready" ]] && break; sleep 0.1; done
  smoke_assert_file_exists "$ready" "T5 pre-holder acquired upgrade.lock"

  set +e
  local out rc
  out="$("$BASH_BIN" "$UPGRADE_SH" --source "$src" --target "$home" --apply --no-pull --no-restart-daemon --no-restart-agents 2>&1)"
  rc=$?
  set -e
  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true

  [[ "$rc" -ne 0 ]] || smoke_fail "T5 mutating --apply against a held lock should refuse (rc!=0), got rc=$rc"
  smoke_assert_contains "$out" "이미 실행 중" "T5 mutating --apply refused with the already-running diagnostic"
}

# --------------------------------------------------------------------------
# T6: release lives in the EXISTING top-level exit handler — NOT a new second
# top-level EXIT trap. (A pre-existing function-scoped `trap ... EXIT` for a
# tempfile inside bridge_upgrade_collect_agent_restart_report is unrelated and
# legitimate; we assert there is exactly ONE TOP-LEVEL handler trap and that the
# lock release lives inside that handler's body.)
# --------------------------------------------------------------------------
test_single_exit_trap_with_release() {
  # Exactly one top-level trap wiring the singleton handler to EXIT.
  local handler_traps
  handler_traps="$(grep -cE "^trap[[:space:]]+_bridge_upgrade_exit_handler[[:space:]]+EXIT" "$UPGRADE_SH" || true)"
  smoke_assert_eq "1" "$handler_traps" "T6 exactly one top-level _bridge_upgrade_exit_handler EXIT trap"

  # No NEW top-level (column-0) EXIT trap was added beyond that handler.
  local toplevel_traps
  toplevel_traps="$(grep -cE "^trap[[:space:]]+.*[[:space:]]EXIT([[:space:]]|$)" "$UPGRADE_SH" || true)"
  smoke_assert_eq "1" "$toplevel_traps" "T6 only the singleton handler is wired at top level (no 2nd top-level EXIT trap)"

  # The release must live INSIDE the handler function body (between its `{` and
  # the closing `}`), proving integration rather than a separate trap.
  local in_handler_release
  in_handler_release="$(awk '
    /^_bridge_upgrade_exit_handler\(\)[[:space:]]*\{/ { inh=1 }
    inh && /bridge_scoped_lock_release/ { found=1 }
    inh && /^}/ { inh=0 }
    END { print (found ? "yes" : "no") }
  ' "$UPGRADE_SH")"
  smoke_assert_eq "yes" "$in_handler_release" "T6 lock release is integrated inside _bridge_upgrade_exit_handler"
}

# --------------------------------------------------------------------------
# T7 (flock backend, only where real flock(1) exists — Linux CI): the prod
# helper's flock-token contender (`bridge_scoped_lock_acquire`, which runs
# `flock -n` on the shared lockfile) must be refused while a DIFFERENT live
# process holds the kernel flock on that file. Guards both the early-fd-release
# regression class AND the `flock -w 0`-vs-`-n` refuse-fast contract. Skipped
# where flock is absent (mkdir backend covered by T1[mkdir]).
# --------------------------------------------------------------------------
test_flock_cross_process_mutex() {
  if ! command -v flock >/dev/null 2>&1; then
    smoke_skip "T7 flock cross-process mutex" "flock(1) not installed (mkdir backend covered by T1)"
    return 0
  fi
  local lock="$LOCKDIR/t7.lock"
  local ready="$SMOKE_TMP_ROOT/t7.ready"
  local proceed="$SMOKE_TMP_ROOT/t7.proceed"

  # T7 is THE flock-backend test: force the flock backend for BOTH the holder
  # AND the contender, even when the whole smoke is invoked with an ambient
  # BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1 (mkdir-forced). A flock holder + a mkdir
  # contender would not contend on the same primitive (false ACQUIRED).
  # Live kernel-flock holder (a different process) via the shared helper.
  BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=0 _hold_lock_bg "$lock" "$ready" "$proceed"
  local holder_pid="$_HELD_LOCK_PID"
  smoke_assert_file_exists "$ready" "T7 live flock holder acquired the lock"

  set +e
  local out
  out="$(BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=0 "$BASH_BIN" -c '
    source "$1"
    if bridge_scoped_lock_acquire "$2"; then
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
      echo "ACQUIRED"
    fi
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  set -e
  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true
  smoke_assert_not_contains "$out" "ACQUIRED" "T7 flock contender refused while a DIFFERENT process holds the lock"
  smoke_assert_contains "$out" "already running" "T7 flock contender printed the refuse diagnostic"
}

# --------------------------------------------------------------------------
# T8: rollback's full-snapshot restore must NOT delete state/locks (which holds
# the active upgrade.lock the rollback itself is holding). restore_live_backup()
# takes the no-entries path → remove_existing_target_children(), which wipes
# every target child except `backups`. #1661 preserves `state/locks` so the live
# lock's inode (flock identity) and its mkdir lockdir survive the wipe. Without
# the fix the lock vanishes mid-rollback and the mutual-exclusion guarantee is
# lost in the highest-risk window. AST/argv-driven (footgun #11: python via -c).
# --------------------------------------------------------------------------
test_rollback_preserves_state_locks() {
  local probe
  probe='
import os, sys, importlib.util, json, tempfile, pathlib

upg = sys.argv[1]
spec = importlib.util.spec_from_file_location("bu_t8", upg)
mod = importlib.util.module_from_spec(spec)
sys.modules["bu_t8"] = mod
spec.loader.exec_module(mod)

root = pathlib.Path(tempfile.mkdtemp())
target = root / "target"
backup = target / "backups" / "upgrade-x"
# Live target: some state (to be wiped/restored) + an ACTIVE lock. Model BOTH
# backends: a flock-style lock file (inode identity) AND a mkdir-style lockdir
# with the LIVE owner pid.
(target / "state" / "locks").mkdir(parents=True)
lockfile = target / "state" / "locks" / "upgrade.lock"
lockfile.write_text("pid=%d\nstarted=now\n" % os.getpid())
lock_inode_before = os.stat(lockfile).st_ino
(target / "state" / "locks" / "upgrade.lock.d").mkdir()
live_owner = target / "state" / "locks" / "upgrade.lock.d" / "owner"
live_owner.write_text("pid=%d\nstarted=now\n" % os.getpid())   # LIVE owner
(target / "state" / "stale.txt").write_text("old-state")
(target / "agents").mkdir()
(target / "agents" / "a.txt").write_text("live-agent")
# Full-snapshot backup (no manifest entries -> the wipe path). CRITICALLY the
# backup itself contains a STALE state/locks owner from a prior locked upgrade
# (dead pid 999999). A naive merge would copy this over the live owner.
(backup / "live" / "agents").mkdir(parents=True)
(backup / "live" / "agents" / "a.txt").write_text("restored-agent")
(backup / "live" / "state" / "locks" / "upgrade.lock.d").mkdir(parents=True)
(backup / "live" / "state" / "locks" / "upgrade.lock.d" / "owner").write_text("pid=999999\nstarted=old\n")
(backup / "live" / "state" / "fresh.txt").write_text("restored-state")
(backup / "manifest.json").write_text(json.dumps({}))   # no entries -> wipe path

mod.restore_live_backup(target, backup)

ok = True
# 1. The active lock file SURVIVED with the SAME inode (flock identity intact).
if not lockfile.exists():
    print("FAIL: state/locks/upgrade.lock deleted by rollback"); ok = False
elif os.stat(lockfile).st_ino != lock_inode_before:
    print("FAIL: lock inode changed (recreated, not preserved)"); ok = False
# 2. The lockdir itself survived (mkdir-backend identity).
if not (target / "state" / "locks").is_dir():
    print("FAIL: state/locks dir removed"); ok = False
# 3. The LIVE owner pid was NOT overwritten by the stale backup owner (the
#    mkdir-fallback reclaim race the patch must close).
if "999999" in live_owner.read_text():
    print("FAIL: stale backup owner pid overwrote the live lock owner"); ok = False
if str(os.getpid()) not in live_owner.read_text():
    print("FAIL: live owner pid lost during rollback restore"); ok = False
# 4. Rollback still restored the backup content (agents/a.txt -> restored).
if (target / "agents" / "a.txt").read_text() != "restored-agent":
    print("FAIL: backup content not restored"); ok = False
# 5. Stale non-preserved state was wiped (not silently kept).
if (target / "state" / "stale.txt").exists():
    print("FAIL: non-preserved stale state survived the wipe"); ok = False
print("OK" if ok else "NOT-OK")
'
  local out
  out="$(python3 -c "$probe" "$ROOT_DIR/bridge-upgrade.py" 2>&1)"
  smoke_assert_contains "$out" "OK" "T8 rollback preserves state/locks (lock survives, content restored, stale wiped)"
  smoke_assert_not_contains "$out" "NOT-OK" "T8 no preservation/restore failures"
  smoke_assert_not_contains "$out" "FAIL:" "T8 no specific preservation failure"
}

smoke_require_cmd git
smoke_require_cmd python3
smoke_run "T1 refuse-fast default + release + re-acquire" test_refuse_fast_then_release
smoke_run "T2 --wait is bounded" test_wait_is_bounded
smoke_run "T3 mkdir-fallback stale reclaim (dead owner)" test_mkdir_stale_reclaim
smoke_run "T4 same lockfile for upgrade + rollback" test_same_lockfile_for_upgrade_and_rollback
smoke_run "T5 upgrade.sh locks mutating flows only" test_upgrade_sh_locks_mutating_only
smoke_run "T6 single EXIT trap + release inside it" test_single_exit_trap_with_release
smoke_run "T7 flock cross-process mutual exclusion (Linux)" test_flock_cross_process_mutex
smoke_run "T8 rollback preserves state/locks (does not delete its own lock)" test_rollback_preserves_state_locks

smoke_log "PASS"
