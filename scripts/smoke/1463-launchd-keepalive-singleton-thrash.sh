#!/usr/bin/env bash
# scripts/smoke/1463-launchd-keepalive-singleton-thrash.sh — unit smoke
# for the launchd KeepAlive vs out-of-band-restart singleton-lock thrash
# fix (issue #1463).
#
# Root cause: on macOS launchd installs (KeepAlive=true, ThrottleInterval
# =30) a supervisor (liveness / silence watchdog) restarted the daemon
# OUT-OF-BAND of launchd via direct `stop --force` + `start`. The fresh
# daemon took the singleton lock OUTSIDE launchd's supervised process
# tree, so launchd's own KeepAlive job instance could never acquire it —
# it failed ensure_singleton, exited 1, and KeepAlive respawned it every
# 30s indefinitely. A secondary bug then made status report the daemon as
# stopped while it was running: _bridge_daemon_on_exit removed the
# pid-file UNCONDITIONALLY, so a losing competitor (the launchd job that
# just failed ensure_singleton) deleted the TRUE holder's pid-file, and
# bridge-status.py (no fallback) then reported `stopped pid=-`.
#
# Fix (three parts, all exercised here):
#   1. Canonical launchd-aware restart primitive
#      (bridge_daemon_launchd_restart in lib/bridge-daemon-control.sh):
#      on launchd installs it cycles launchd's OWN job via
#      `launchctl kickstart -k gui/$UID/<label>` instead of stop+start, so
#      the lock holder is always launchd's instance. Refuses (rc=2) when
#      the live lock holder is NOT launchd's job pid (existing split).
#      Both supervisors (bridge-daemon-liveness.sh +
#      bridge-watchdog-silence.py) route through the single `restart` verb.
#   2. _bridge_daemon_on_exit removes the pid-file only when it still
#      contains its own pid (otherwise audits cleanup_skipped).
#   3. bridge-status.py daemon_status gains the shell resolver's fallbacks
#      (recorded-pid cmdline validation, scoped pgrep, mkdir-lock
#      owner.pid) so a transiently-missing pid-file no longer reads as
#      "stopped".
#
# Assertions:
#   A — launchd path: with a fake Darwin `uname` + fake `launchctl` whose
#       job pid == the recorded daemon pid, bridge_daemon_launchd_restart
#       returns 0 AND issues `kickstart -k` (does NOT stop+start).
#   B — split guard (TEETH): with the recorded daemon pid alive but != the
#       launchd job pid, the primitive REFUSES (rc=2) and does NOT
#       kickstart.
#   C — non-launchd: with NO launchagent.config marker and no plist (the
#       Linux systemd/nohup shape), the primitive returns 1 so the caller
#       falls through to its existing stop+start (Linux is unaffected).
#   D — pid-file ownership guard: sources the REAL shipped decision helper
#       bridge_daemon_pid_file_cleanup_should_remove from bridge-daemon.sh
#       (not a copy, so a revert of the guard fails the smoke) and asserts
#       the on-exit removal deletes the pid-file only when it holds the
#       exiting pid; a foreign live pid is left intact (the #1463 secondary
#       bug would have erased it).
#   E — bridge-status.py fallback: with daemon.pid ABSENT but a live
#       `<BRIDGE_HOME>/bridge-daemon.sh run` process present, daemon_status
#       resolves RUNNING via the scoped-pgrep fallback (the dashboard no
#       longer disagrees with the shell resolver). Plus the mkdir-lock
#       owner.pid fallback resolves RUNNING from the lock dir alone.
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge
# state is touched. Fake `launchctl`/`uname` live on a smoke-local PATH
# shim dir, never the system binaries.
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
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1463-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

# Isolated bridge home + state dir. Nothing here touches ~/.agent-bridge.
export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
mkdir -p "$BRIDGE_STATE_DIR"

# Minimal stand-ins for helpers the control lib references (it normally
# inherits these from bridge-lib.sh). Define BEFORE sourcing so the lib's
# `command -v` guards see them; keep them inert so the smoke asserts only
# the new logic, not audit/warn side effects.
KICKSTART_MARKER="$SMOKE_DIR/kickstart-called"
AUDIT_MARKER="$SMOKE_DIR/audit.log"
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_audit_log() { printf '%s\n' "$*" >>"$AUDIT_MARKER" 2>/dev/null || true; }

# shellcheck source=/dev/null
source "$CONTROL_LIB"

for fn in bridge_daemon_launchd_restart _bridge_daemon_launchd_label _bridge_daemon_launchd_job_pid; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# PATH shim: fake `launchctl` (records kickstart calls + reports a job pid)
# and fake `uname` (forces Darwin). LAUNCHD_JOB_PID controls the pid the
# fake `launchctl print` reports; FAKE_OS controls `uname`.
# ---------------------------------------------------------------------------
SHIM_DIR="$SMOKE_DIR/bin"
mkdir -p "$SHIM_DIR"

cat >"$SHIM_DIR/launchctl" <<SHIM
#!/usr/bin/env bash
case "\$1" in
  print)
    # Emit a launchd-print-shaped block with the configured job pid.
    if [[ -n "\${LAUNCHD_JOB_PID:-}" ]]; then
      printf '\tpid = %s\n' "\$LAUNCHD_JOB_PID"
    fi
    exit 0
    ;;
  kickstart)
    printf 'kickstart %s\n' "\$*" >>"$KICKSTART_MARKER"
    exit 0
    ;;
esac
exit 0
SHIM
chmod +x "$SHIM_DIR/launchctl"

cat >"$SHIM_DIR/uname" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\${FAKE_OS:-Darwin}"
SHIM
chmod +x "$SHIM_DIR/uname"

ORIG_PATH="$PATH"
export PATH="$SHIM_DIR:$PATH"

# launchd marker the installer writes (the "we are launchd-managed" signal).
LABEL="ai.agent-bridge.daemon.smoke1463"
printf 'BRIDGE_LAUNCHAGENT_LABEL=%q\n' "$LABEL" >"$BRIDGE_STATE_DIR/launchagent.config"

# A long-lived sleeper to stand in for the live daemon pid (kill -0 true).
sleep 600 &
DAEMON_STUB_PID=$!
trap 'kill "$DAEMON_STUB_PID" 2>/dev/null; rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

reset_kickstart() { : >"$KICKSTART_MARKER"; }
kickstart_count() {
  # Count non-empty lines as a single integer. `grep -c` exits 1 on zero
  # matches (which would double-fire an `||` fallback), so read+wc instead.
  if [[ -f "$KICKSTART_MARKER" ]]; then
    local n
    n="$(wc -l <"$KICKSTART_MARKER" 2>/dev/null | tr -dc '0-9')"
    printf '%s' "${n:-0}"
  else
    printf '0'
  fi
}

# ===========================================================================
# A — launchd path: recorded daemon pid == launchd job pid → kickstart, rc=0.
# ===========================================================================
reset_kickstart
printf '%s\n' "$DAEMON_STUB_PID" >"$BRIDGE_DAEMON_PID_FILE"
LAUNCHD_JOB_PID="$DAEMON_STUB_PID" FAKE_OS="Darwin" bridge_daemon_launchd_restart "smoke-A" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && [[ "$(kickstart_count)" -ge 1 ]]; then
  _pass "A: launchd install cycles launchd's own job via kickstart -k (rc=0)"
else
  _fail "A: launchd kickstart path" "rc=$rc kickstart_count=$(kickstart_count) (expected rc=0, >=1 kickstart)"
fi

# ===========================================================================
# B — split guard (TEETH): recorded daemon pid alive but != launchd job pid
#     → REFUSE (rc=2), NO kickstart.
# ===========================================================================
reset_kickstart
printf '%s\n' "$DAEMON_STUB_PID" >"$BRIDGE_DAEMON_PID_FILE"
# Report a DIFFERENT (also-live) launchd job pid: use $$ (this smoke shell),
# which is guaranteed alive and != the daemon stub.
LAUNCHD_JOB_PID="$$" FAKE_OS="Darwin" bridge_daemon_launchd_restart "smoke-B" >/dev/null 2>&1
rc=$?
if (( rc == 2 )) && [[ "$(kickstart_count)" -eq 0 ]]; then
  _pass "B: out-of-band split (recorded pid != launchd job pid) is REFUSED (rc=2), no kickstart"
else
  _fail "B: split-guard refusal" "rc=$rc kickstart_count=$(kickstart_count) (expected rc=2, 0 kickstarts)"
fi

# ===========================================================================
# C — non-launchd (Linux systemd/nohup shape): no marker + no plist → rc=1
#     so the caller falls through to its existing stop+start. No kickstart.
# ===========================================================================
reset_kickstart
# Remove the launchd marker and ensure no plist path resolves.
rm -f "$BRIDGE_STATE_DIR/launchagent.config"
unset BRIDGE_DAEMON_LAUNCHAGENT_LABEL BRIDGE_DAEMON_LAUNCHAGENT_PLIST
# Force Linux uname so the Darwin gate alone would already return 1; we
# additionally assert the marker-absence path by testing under Darwin too.
LINUX_RC=1
FAKE_OS="Linux" bridge_daemon_launchd_restart "smoke-C-linux" >/dev/null 2>&1 || LINUX_RC=$?
DARWIN_NOMARKER_RC=1
FAKE_OS="Darwin" bridge_daemon_launchd_restart "smoke-C-darwin-nomarker" >/dev/null 2>&1 || DARWIN_NOMARKER_RC=$?
if (( LINUX_RC == 1 )) && (( DARWIN_NOMARKER_RC == 1 )) && [[ "$(kickstart_count)" -eq 0 ]]; then
  _pass "C: non-launchd install returns 1 (caller falls through to stop+start), no kickstart"
else
  _fail "C: non-launchd fall-through" "linux_rc=$LINUX_RC darwin_nomarker_rc=$DARWIN_NOMARKER_RC kickstart_count=$(kickstart_count) (expected both rc=1, 0 kickstarts)"
fi

# ===========================================================================
# D — pid-file ownership guard. Source the REAL shipped decision helper
#     bridge_daemon_pid_file_cleanup_should_remove from bridge-daemon.sh
#     (NOT a copy) so a revert of the guard in the source would make these
#     checks fail (acceptance criterion 5 — real teeth). The on-exit trap
#     calls this helper to decide whether to `rm` the pid-file; the helper
#     returns 0 ("remove": absent/empty/our-own pid) or 1 ("keep": a
#     foreign holder's pid).
# ===========================================================================
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
# bridge-daemon.sh runs a top-level dispatcher when sourced, so extract just
# the function definition and source THAT. The slice is the shipped text —
# a revert of the guard body propagates straight into this test.
GUARD_FN="$SMOKE_DIR/cleanup-guard.sh"
awk '
  /^bridge_daemon_pid_file_cleanup_should_remove\(\)[[:space:]]*\{/ { capture=1 }
  capture { print }
  capture && /^\}[[:space:]]*$/ { exit }
' "$DAEMON_SH" >"$GUARD_FN" 2>/dev/null || true
if [[ -s "$GUARD_FN" ]]; then
  # shellcheck source=/dev/null
  source "$GUARD_FN"
fi
if ! command -v bridge_daemon_pid_file_cleanup_should_remove >/dev/null 2>&1; then
  _fail "D: extract shipped guard" "bridge_daemon_pid_file_cleanup_should_remove not found in $DAEMON_SH"
else
  # Drive the on-exit removal exactly as the trap does: ask the shipped
  # helper, then rm only on a 0 return.
  _on_exit_remove_via_shipped_guard() {
    local exiting_pid="$1"
    if bridge_daemon_pid_file_cleanup_should_remove "$BRIDGE_DAEMON_PID_FILE" "$exiting_pid"; then
      rm -f "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true
    fi
  }

  # D1 — foreign live pid: a losing competitor (DIFFERENT pid) exits; the
  # true holder's file must survive.
  printf '%s\n' "$DAEMON_STUB_PID" >"$BRIDGE_DAEMON_PID_FILE"
  _on_exit_remove_via_shipped_guard "999999"
  if [[ -f "$BRIDGE_DAEMON_PID_FILE" ]] && [[ "$(tr -dc '0-9' <"$BRIDGE_DAEMON_PID_FILE")" == "$DAEMON_STUB_PID" ]]; then
    _pass "D1: shipped guard preserves the TRUE holder's pid-file when a competitor exits"
  else
    _fail "D1: pid-file ownership guard" "true holder's pid-file was deleted by a competitor's exit (the #1463 secondary bug)"
  fi

  # D2 — the holder itself exits: file is removed (normal teardown intact).
  printf '%s\n' "$DAEMON_STUB_PID" >"$BRIDGE_DAEMON_PID_FILE"
  _on_exit_remove_via_shipped_guard "$DAEMON_STUB_PID"
  if [[ ! -f "$BRIDGE_DAEMON_PID_FILE" ]]; then
    _pass "D2: shipped guard still removes the pid-file when the holder itself exits"
  else
    _fail "D2: pid-file ownership guard (self)" "pid-file not removed on the holder's own exit"
  fi

  # D3 — absent pid-file: a no-op removal must report "remove" (return 0) so
  # the trap's `rm -f` is a harmless no-op (guards the empty-file branch).
  rm -f "$BRIDGE_DAEMON_PID_FILE"
  if bridge_daemon_pid_file_cleanup_should_remove "$BRIDGE_DAEMON_PID_FILE" "$DAEMON_STUB_PID"; then
    _pass "D3: shipped guard treats an absent pid-file as safe-to-remove (no-op)"
  else
    _fail "D3: pid-file ownership guard (absent)" "absent pid-file should return 0 (remove/no-op)"
  fi
fi

# Restore real PATH/uname for the python step (it must use the system
# pgrep + interpreter, not the smoke fakes).
export PATH="$ORIG_PATH"

# ===========================================================================
# E — bridge-status.py daemon_status fallbacks. Drive the function directly
#     with a missing daemon.pid and (E1) a live scoped-pgrep target, then
#     (E2) a populated mkdir-lock owner.pid.
# ===========================================================================
STATUS_PY="$REPO_ROOT/bridge-status.py"
if [[ ! -r "$STATUS_PY" ]]; then
  _fail "E: bridge-status.py present" "not readable at $STATUS_PY"
else
  # E1 — scoped pgrep fallback. Launch a process whose argv matches
  # `<BRIDGE_HOME>/bridge-daemon.sh run` (the exact pattern the resolver
  # greps for), delete daemon.pid, and assert daemon_status reports RUNNING.
  rm -f "$BRIDGE_DAEMON_PID_FILE"
  FAKE_DAEMON="$BRIDGE_HOME/bridge-daemon.sh"
  cat >"$FAKE_DAEMON" <<'FD'
#!/usr/bin/env bash
# Stand-in matched by the resolver's `pgrep -f '<HOME>/bridge-daemon.sh run'`.
sleep 600
FD
  chmod +x "$FAKE_DAEMON"
  "$FAKE_DAEMON" run &
  FAKE_RUN_PID=$!
  # Give pgrep a moment to see the new argv.
  sleep 1

  e1_probe="$SMOKE_DIR/e1.py"
  cat >"$e1_probe" <<PROBE
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", "$STATUS_PY")
mod = importlib.util.module_from_spec(spec); sys.modules["bs"] = mod
spec.loader.exec_module(mod)
running, pid = mod.daemon_status("$BRIDGE_DAEMON_PID_FILE",
                                 state_dir="$BRIDGE_STATE_DIR",
                                 bridge_home="$BRIDGE_HOME")
print("RUNNING" if running else "STOPPED", pid)
sys.exit(0 if running else 1)
PROBE
  if e1_out="$(python3 "$e1_probe" 2>&1)" && [[ "$e1_out" == RUNNING* ]]; then
    _pass "E1: daemon_status resolves RUNNING via scoped-pgrep when daemon.pid is absent ($e1_out)"
  else
    _fail "E1: status pgrep fallback" "got '$e1_out' (expected RUNNING ...); daemon.pid was deliberately absent"
  fi
  kill "$FAKE_RUN_PID" 2>/dev/null || true

  # E2 — mkdir-lock owner.pid fallback. With daemon.pid absent and no
  # matching pgrep target, a live owner.pid in <pid_file>.lock.d must
  # resolve RUNNING (the macOS flock-less backend).
  rm -f "$BRIDGE_DAEMON_PID_FILE"
  LOCK_OWNER_DIR="$BRIDGE_DAEMON_PID_FILE.lock.d"
  mkdir -p "$LOCK_OWNER_DIR"
  printf '%s\n' "$DAEMON_STUB_PID" >"$LOCK_OWNER_DIR/owner.pid"
  e2_probe="$SMOKE_DIR/e2.py"
  cat >"$e2_probe" <<PROBE
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", "$STATUS_PY")
mod = importlib.util.module_from_spec(spec); sys.modules["bs"] = mod
spec.loader.exec_module(mod)
# bridge_home points at a dir with NO matching bridge-daemon.sh run process,
# so only the owner.pid fallback can resolve this.
running, pid = mod.daemon_status("$BRIDGE_DAEMON_PID_FILE",
                                 state_dir="$BRIDGE_STATE_DIR",
                                 bridge_home="$SMOKE_DIR/no-such-home")
print("RUNNING" if running else "STOPPED", pid)
sys.exit(0 if (running and str(pid) == "$DAEMON_STUB_PID") else 1)
PROBE
  if e2_out="$(python3 "$e2_probe" 2>&1)" && [[ "$e2_out" == "RUNNING $DAEMON_STUB_PID" ]]; then
    _pass "E2: daemon_status resolves RUNNING via mkdir-lock owner.pid fallback ($e2_out)"
  else
    _fail "E2: status owner.pid fallback" "got '$e2_out' (expected 'RUNNING $DAEMON_STUB_PID')"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n[summary] %d checks, %d failures\n' "$TOTAL" "$FAILS"
(( FAILS == 0 )) || exit 1
exit 0
