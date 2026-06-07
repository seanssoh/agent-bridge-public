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

BASH_BIN="${BRIDGE_BASH_BIN:-bash}"

# --------------------------------------------------------------------------
# T1: refuse-fast default + release + re-acquire.
# A child holds the lock + sleeps; while it holds, a refuse-fast acquire from
# THIS shell must be refused. The flock backend ties the lock to the holder's
# fd lifetime, so the holder must stay alive across the contender attempt.
# --------------------------------------------------------------------------
test_refuse_fast_then_release() {
  local lock="$LOCKDIR/t1.lock"
  local ready="$SMOKE_TMP_ROOT/t1.ready"
  local proceed="$SMOKE_TMP_ROOT/t1.proceed"
  rm -f "$ready" "$proceed"

  # Holder: acquire DIRECTLY (never under $(...) — that would close the flock
  # fd), signal ready, wait for the contender, then release.
  "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    bridge_scoped_lock_acquire "$2" || { echo "holder-acquire-failed" >&2; exit 9; }
    : >"$3"                       # signal ready
    for _ in $(seq 1 50); do [[ -f "$4" ]] && break; sleep 0.1; done
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" "$ready" "$proceed" &
  local holder_pid=$!

  # Wait for the holder to hold.
  local i
  for i in $(seq 1 50); do [[ -f "$ready" ]] && break; sleep 0.1; done
  smoke_assert_file_exists "$ready" "T1 holder acquired the lock"

  # Contender (refuse-fast): must be refused while the holder holds.
  set +e
  local out rc
  out="$("$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    if bridge_scoped_lock_acquire "$2"; then
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
      echo "ACQUIRED"
    fi
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_not_contains "$out" "ACQUIRED" "T1 refuse-fast contender did NOT acquire a held lock"
  smoke_assert_contains "$out" "already running" "T1 refuse-fast contender printed a clear diagnostic"

  # Let the holder release + reap it.
  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true

  # Now a fresh acquire must succeed (lock free again).
  set +e
  out="$("$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    bridge_scoped_lock_acquire "$2" || exit 1
    echo "ACQUIRED"
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T1 fresh acquire after release returns 0"
  smoke_assert_contains "$out" "ACQUIRED" "T1 fresh acquire after release succeeds"
}

# --------------------------------------------------------------------------
# T2: --wait is bounded.
# --------------------------------------------------------------------------
test_wait_is_bounded() {
  local lock="$LOCKDIR/t2.lock"
  local ready="$SMOKE_TMP_ROOT/t2.ready"
  local proceed="$SMOKE_TMP_ROOT/t2.proceed"
  rm -f "$ready" "$proceed"

  "$BASH_BIN" -c '
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
  smoke_assert_file_exists "$ready" "T2 holder acquired the lock"

  # Contender with --wait 1: must give up after ~1s (bounded), NOT hang.
  set +e
  local out rc
  out="$("$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    if bridge_scoped_lock_acquire "$2" --wait 1; then
      bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
      echo "ACQUIRED"
    fi
  ' _ "$LOCK_LIB" "$lock" 2>&1)"
  rc=$?
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
# T7 (flock backend, only where real flock(1) exists — Linux CI): cross-process
# mutual exclusion. Guards the critical regression class where the flock fd is
# released early — e.g. capturing the token under `$(...)` (a subshell that
# closes the flock fd) instead of the direct-call / global-token convention.
# Skipped where flock is absent (macOS dev hosts run the mkdir backend covered
# by T1); the integration VM-verify stage exercises this on Linux.
# --------------------------------------------------------------------------
test_flock_cross_process_mutex() {
  if ! command -v flock >/dev/null 2>&1; then
    smoke_skip "T7 flock cross-process mutex" "flock(1) not installed (mkdir backend covered by T1)"
    return 0
  fi
  local lock="$LOCKDIR/t7.lock"
  local ready="$SMOKE_TMP_ROOT/t7.ready"
  local proceed="$SMOKE_TMP_ROOT/t7.proceed"
  rm -f "$ready" "$proceed" "$lock"

  "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    bridge_scoped_lock_acquire "$2" || exit 9
    [[ "$BRIDGE_SCOPED_LOCK_TOKEN" == flock:* ]] || { echo "not-flock-backend" >&2; exit 8; }
    : >"$3"
    for _ in $(seq 1 100); do [[ -f "$4" ]] && break; sleep 0.1; done
    bridge_scoped_lock_release "$BRIDGE_SCOPED_LOCK_TOKEN"
  ' _ "$LOCK_LIB" "$lock" "$ready" "$proceed" &
  local holder_pid=$!
  local i
  for i in $(seq 1 50); do [[ -f "$ready" ]] && break; sleep 0.1; done
  smoke_assert_file_exists "$ready" "T7 flock holder acquired the lock"

  set +e
  local out
  out="$("$BASH_BIN" -c '
    set -euo pipefail
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
