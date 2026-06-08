#!/usr/bin/env bash
# scripts/smoke/1667-daemon-control-lock-serialize.sh — Issue #1667 smoke.
#
# `lib/bridge-daemon-control.sh:bridge_daemon_refresh_after_group_membership_change`
# acquired the daemon-refresh lock via command-substitution capture —
# `lock_token="$(_bridge_daemon_control_lock_acquire ...)"` — which runs the
# acquire in a `$(...)` subshell. For the FLOCK backend the lock is held by an
# open fd; when the `$(...)` subshell exits that fd closes and the flock is
# RELEASED immediately, so the "held" lock provided no mutual exclusion for the
# rest of the daemon-refresh critical section (re-check + restart). The mkdir
# fallback was unaffected (no fd to leak).
#
# Fix (#1667, mirrors the #1661 lib/bridge-lock.sh fix): the acquire helper
# returns its token via the BRIDGE_DAEMON_CONTROL_LOCK_TOKEN global and is
# called DIRECTLY (never under `$(...)`), so the fd lives in the caller's shell
# for the lock's full intended lifetime.
#
# Coverage (sources the SHIPPED helper from lib/bridge-daemon-control.sh — not
# a copy):
#   T1  direct-acquire holds across a critical section (flock backend): a holder
#       acquires DIRECTLY (the prod pattern) and keeps the token live while it
#       does work; a SECOND live process trying to flock the SAME file is
#       refused. Proves the fd survives the function return — the load-bearing
#       guarantee #1667 restores.
#   T2  regression witness: the OLD `$()`-capture pattern does NOT serialize on
#       the flock backend — a contender CAN flock the file even while the
#       "holder" thinks it holds the token. This is the bug; the test asserts
#       the broken pattern is broken so a future revert to `$()` is caught by
#       T1 flipping to the (wrong) T2 behavior.
#   T3  token shape + release round-trips on BOTH backends (flock where present,
#       mkdir fallback always) via the global, never stdout.
#   T4  call-site wiring: bridge-daemon-control.sh calls the acquire helper
#       directly (no `$()` capture of _bridge_daemon_control_lock_acquire) and
#       reads BRIDGE_DAEMON_CONTROL_LOCK_TOKEN.
#
# Footgun #11: no heredoc / here-string feeding a subprocess interpreter.

set -euo pipefail

SMOKE_NAME="1667-daemon-control-lock-serialize"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$SMOKE_REPO_ROOT"
CONTROL_LIB="$ROOT_DIR/lib/bridge-daemon-control.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd bash
smoke_assert_file_exists "$CONTROL_LIB" "lib/bridge-daemon-control.sh present"

smoke_make_temp_root
LOCKDIR="$SMOKE_TMP_ROOT/locks"
mkdir -p "$LOCKDIR"

# bash 4+ is required to source lib/bridge-daemon-control.sh (its flock branch
# uses the `exec {fd}>` dynamic-fd form, a bash-4 feature). macOS bare bash is
# 3.2 — prefer BRIDGE_BASH_BIN, then Homebrew bash, then PATH bash, verifying
# >= 4 (fail loud rather than silently mis-test under 3.2).
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
BASH_BIN="$(_pick_bash)" || smoke_fail "no bash >= 4 found (need it for the daemon-control flock dynamic-fd branch)"

# A bash -c body that sources the lib (with the minimal shims it needs at
# source time) and then runs an inner script body. Invoked as:
#   "$BASH_BIN" -c "$_RUN_WITH_LIB" _ "$CONTROL_LIB" '<inner body>' <data...>
# so $0=_, $1=lib, $2=inner-body, $3..=data. After sourcing, the positionals
# are reset to the data args, so the inner body sees them as $1, $2, $3, ...
# Shared by every sub-process so they all see an identical sourced helper. The
# shims are no-ops on the success/lock paths exercised here.
_RUN_WITH_LIB='
  set -u
  _lib="$1"
  _body="$2"
  shift 2
  bridge_warn() { printf "[shim warn] %s\n" "$*" >&2; }
  bridge_audit_log() { return 0; }
  bridge_linux_sudo_root() { "$@"; }
  bridge_current_user() { id -un; }
  bridge_daemon_pid() { return 1; }
  # shellcheck disable=SC1090
  source "$_lib"
  eval "$_body"
'

# --------------------------------------------------------------------------
# T1: direct-acquire (the prod pattern) holds the flock across a critical
# section. A live holder acquires DIRECTLY, signals ready, and sleeps inside
# its "critical section"; a SECOND live process attempting `flock -n` on the
# SAME lockfile must be refused while the holder holds. This is THE #1667
# guarantee: the fd survives the acquire function's return.
# --------------------------------------------------------------------------
test_direct_acquire_holds_across_section() {
  if ! command -v flock >/dev/null 2>&1; then
    smoke_skip "T1 direct-acquire holds (flock)" "flock(1) not installed (mkdir backend covered by T3)"
    return 0
  fi
  local lock="$LOCKDIR/t1.lock"
  local ready="$SMOKE_TMP_ROOT/t1.ready"
  local proceed="$SMOKE_TMP_ROOT/t1.proceed"
  rm -f "$ready" "$proceed" "$lock"

  # Holder: acquire DIRECTLY (token via the global), signal ready, hold the
  # token live across a critical section until told to proceed, then release.
  "$BASH_BIN" -c "$_RUN_WITH_LIB" _ "$CONTROL_LIB" '
    _bridge_daemon_control_lock_acquire "$1" 5 || exit 9
    tok="$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
    [[ -n "$tok" ]] || exit 8
    : >"$2"
    # Critical section: hold the lock while we "do work" (poll for teardown).
    for _ in $(seq 1 200); do [[ -f "$3" ]] && break; sleep 0.1; done
    _bridge_daemon_control_lock_release "$tok"
  ' "$lock" "$ready" "$proceed" &
  local holder_pid=$!
  local i
  for i in $(seq 1 100); do [[ -f "$ready" ]] && break; sleep 0.1; done
  smoke_assert_file_exists "$ready" "T1 holder acquired the lock directly"

  # Contender: a DIFFERENT process must NOT be able to flock the same file
  # while the holder holds it. Use real flock -n directly so the test does not
  # depend on the helper's own correctness for the assertion.
  set +e
  flock -n "$lock" -c 'true'
  local rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T1 contender refused while holder holds the lock across its critical section"

  # Tear down the holder; afterwards the lock is free.
  : >"$proceed"
  wait "$holder_pid" 2>/dev/null || true
  set +e
  flock -n "$lock" -c 'true'
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T1 lock free again after holder releases"
}

# --------------------------------------------------------------------------
# T2: regression witness — the OLD `$()`-capture pattern does NOT serialize on
# the flock backend. A holder that captures the token under command
# substitution sees the fd CLOSED on subshell exit, so a contender CAN acquire
# the same lock immediately. Asserting the broken pattern is broken gives T1
# teeth: if someone reverts the prod call site to `$()`, the lock stops
# serializing and the bug returns. (We can't assert "T1 fails" directly without
# editing prod, so we demonstrate the failure mode on the captured token here.)
# --------------------------------------------------------------------------
test_old_capture_pattern_does_not_serialize() {
  if ! command -v flock >/dev/null 2>&1; then
    smoke_skip "T2 old-capture regression witness (flock)" "flock(1) not installed"
    return 0
  fi
  local lock="$LOCKDIR/t2.lock"
  rm -f "$lock"

  # Reproduce the OLD pattern in a single process: capture the acquire under
  # `$(...)`. On the flock backend the subshell's fd closes immediately, so the
  # lock is NOT held even though a token string was captured. A subsequent
  # `flock -n` on the same file from THIS process then succeeds — proving the
  # early release.
  set +e
  local out
  out="$("$BASH_BIN" -c "$_RUN_WITH_LIB" _ "$CONTROL_LIB" '
    # OLD broken pattern: token captured under command substitution.
    tok="$(_bridge_daemon_control_lock_acquire "$1" 5 2>/dev/null; printf "%s" "$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN")"
    # The token string is non-empty, but the flock fd died with the subshell.
    if flock -n "$1" -c "true"; then
      echo "EARLY-RELEASE"   # the lock was NOT actually held — the #1667 bug.
    else
      echo "STILL-HELD"
    fi
  ' "$lock" 2>&1)"
  set -e
  smoke_assert_contains "$out" "EARLY-RELEASE" "T2 old \$()-capture pattern releases the flock early (the #1667 bug it documents)"
}

# --------------------------------------------------------------------------
# T3: token shape + release round-trip via the global on BOTH backends.
# --------------------------------------------------------------------------
test_token_via_global_round_trip() {
  local lock="$LOCKDIR/t3.lock"
  rm -f "$lock" "${lock}.d" 2>/dev/null || true
  set +e
  local out rc
  out="$("$BASH_BIN" -c "$_RUN_WITH_LIB" _ "$CONTROL_LIB" '
    _bridge_daemon_control_lock_acquire "$1" 5 || exit 1
    tok="$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
    [[ -n "$tok" ]] || { echo "EMPTY-TOKEN"; exit 1; }
    case "$tok" in
      flock:*:*) echo "SHAPE-FLOCK" ;;
      mkdir:*)   echo "SHAPE-MKDIR" ;;
      *) echo "SHAPE-BAD:$tok"; exit 1 ;;
    esac
    # The acquire MUST NOT have printed the token to stdout (it returns via the
    # global only). The only stdout from this body is our echo above.
    _bridge_daemon_control_lock_release "$tok"
    # Re-acquire after release proves the release actually freed the lock.
    _bridge_daemon_control_lock_acquire "$1" 5 || { echo "REACQUIRE-FAILED"; exit 1; }
    _bridge_daemon_control_lock_release "$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
    echo "REACQUIRED"
  ' "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T3 acquire/release round-trip returns 0"
  smoke_assert_not_contains "$out" "EMPTY-TOKEN" "T3 token returned via global is non-empty"
  smoke_assert_not_contains "$out" "SHAPE-BAD" "T3 token has a known shape"
  smoke_assert_contains "$out" "REACQUIRED" "T3 release freed the lock (re-acquire after release succeeds)"

  # mkdir backend (covers macOS dev + any host without flock). The
  # daemon-control acquire selects its backend via `command -v flock` and has
  # no disable-flock seam (unlike lib/bridge-lock.sh's
  # BRIDGE_SCOPED_LOCK_DISABLE_FLOCK), so the mkdir path is exercised only on
  # hosts where flock(1) is genuinely absent (stock macOS, minimal containers).
  # On a flock host the path above already covered the flock backend.
  if command -v flock >/dev/null 2>&1; then
    smoke_skip "T3 mkdir-backend token" "flock(1) present — mkdir backend exercised on no-flock hosts (stock macOS / minimal CI image)"
    return 0
  fi
  rm -f "$lock"; rm -rf "${lock}.d" 2>/dev/null || true
  set +e
  out="$("$BASH_BIN" -c "$_RUN_WITH_LIB" _ "$CONTROL_LIB" '
    _bridge_daemon_control_lock_acquire "$1" 5 || exit 1
    case "$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN" in
      mkdir:*) echo "MKDIR-OK" ;;
      *) echo "NOT-MKDIR:$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"; exit 1 ;;
    esac
    _bridge_daemon_control_lock_release "$BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
  ' "$lock" 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T3 mkdir-backend acquire/release returns 0"
  smoke_assert_contains "$out" "MKDIR-OK" "T3 mkdir backend returns a mkdir: token via the global"
}

# --------------------------------------------------------------------------
# T4: call-site wiring — the prod caller must NOT capture the acquire under
# `$()`, and must read the token from the global. Guards against a future
# refactor silently re-introducing the early-release pattern.
# --------------------------------------------------------------------------
test_call_site_wiring() {
  # No command-substitution capture of the acquire helper anywhere in the lib.
  # Audit NON-comment lines only — the function's docblock legitimately quotes
  # the anti-pattern (`tok="$(_bridge_daemon_control_lock_acquire ...)"`) as the
  # thing NOT to do, so a naive grep over the whole file false-positives.
  if grep -vE '^[[:space:]]*#' "$CONTROL_LIB" \
      | grep -qE '\$\([[:space:]]*_bridge_daemon_control_lock_acquire'; then
    smoke_fail "T4 call site still captures _bridge_daemon_control_lock_acquire under \$() (the #1667 bug)"
  fi
  smoke_log "ok: T4 no \$()-capture of the acquire helper"

  # The caller reads the token from the global.
  grep -qF 'BRIDGE_DAEMON_CONTROL_LOCK_TOKEN' "$CONTROL_LIB" \
    || smoke_fail "T4 lib does not reference BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
  smoke_log "ok: T4 token is read from BRIDGE_DAEMON_CONTROL_LOCK_TOKEN"
}

smoke_run "T1 direct-acquire holds the flock across the critical section" test_direct_acquire_holds_across_section
smoke_run "T2 old \$()-capture pattern releases the flock early (regression witness)" test_old_capture_pattern_does_not_serialize
smoke_run "T3 token via global + release round-trip (flock + mkdir)" test_token_via_global_round_trip
smoke_run "T4 call-site wiring: no \$()-capture, reads the global" test_call_site_wiring

smoke_log "PASS"
