#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1905-upgrade-systemd-quiesce-respawn.sh — Issue #1905.
#
# On systemd-managed installs the #1820 reconcile quiesce in bridge-upgrade.sh
# used a script-level `bridge-daemon.sh stop` only, which is NOT systemd-aware:
# `agent-bridge-daemon.service` (Restart=) + `agent-bridge-daemon-liveness.timer`
# respawn the daemon inside the quiesce window and the fail-closed fence keeps
# seeing a live pid → rc=3 abort → half-applied upgrade.
#
# The fix adds gated, best-effort systemd helpers to bridge-upgrade.sh:
#   _bridge_upgrade_systemd_user_bus_ready  — establish XDG_RUNTIME_DIR (#1905 r2)
#   _bridge_upgrade_daemon_systemd_active   — bus + systemctl + is-active gate
#   _bridge_upgrade_systemd_quiesce_daemon  — stop timer THEN service (no respawn)
#   _bridge_upgrade_systemd_restart_daemon  — start service THEN re-arm timer
#
# This smoke sources ONLY those helper bodies from the live bridge-upgrade.sh
# source (extracted between the #1905 BEGIN/END markers, so the test tracks the
# real implementation, not a copy), installs a `systemctl` shim that records
# every call AND reproduces the real no-bus failure (#1905 r2: `--user` without
# XDG_RUNTIME_DIR fails "connect to bus" and is NOT logged — closing the CI blind
# spot that masked the r2 regression), and asserts (with the test env
# XDG_RUNTIME_DIR UNSET so the helpers MUST establish it):
#   T1 — systemd-active quiesce stops ONLY the SERVICE (#2064: the liveness TIMER
#        is LEFT RUNNING so a SIGKILL'd upgrade still has an invoker for the
#        quiesce marker; the watcher's live-upgrade DEFER guard avoids the fence
#        race that stopping the timer used to prevent).
#   T2 — systemd restart starts the SERVICE, then re-arms the liveness TIMER
#        (idempotent on an already-running timer).
#   T3 — NON-systemd path (detector → false) makes ZERO systemctl calls
#        (byte-for-byte unchanged behavior) even with systemctl on PATH.
#   T4/T5 — inline-fallback detector: inactive → is-active probe only; active →
#        stop the SERVICE only (#2064: no timer stop).
#   T6 — _bridge_upgrade_systemd_user_bus_ready exports XDG_RUNTIME_DIR from
#        /run/user/<uid> when unset, respects an already-set value, and fails
#        (rc!=0) when no user runtime dir exists.
#   T7 — with NO reachable user bus, quiesce makes ZERO systemctl calls (graceful
#        fallback to the script-level stop, never a silent broken `--user` call).

set -uo pipefail
SMOKE_NAME="1905-upgrade-systemd-quiesce-respawn"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi

smoke_make_temp_root "$SMOKE_NAME"
UPGRADE_SRC="$REPO_ROOT/bridge-upgrade.sh"
smoke_assert_file_exists "$UPGRADE_SRC" "bridge-upgrade.sh source present"

# Extract the #1905 helper bodies verbatim from the live source so the smoke
# never drifts from the implementation. The markers are stable comment fences.
HELPERS="$SMOKE_TMP_ROOT/1905-helpers.sh"
awk '/^# BEGIN: Issue #1905 systemd-aware/{f=1} f{print} /^# END: Issue #1905 systemd-aware/{f=0}' \
  "$UPGRADE_SRC" >"$HELPERS"
grep -q '_bridge_upgrade_systemd_quiesce_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #1905 helpers from $UPGRADE_SRC"

# A `systemctl` shim that appends each invocation (args joined by spaces) to a
# log file, then exits per a controllable `is-active` outcome. Drop it on a
# PATH-front dir so the helpers resolve THIS one. The `is-active` outcome lets
# the INLINE-fallback detector path (no canonical detector in scope) report
# either active (rc 0) or inactive (rc != 0); stop/start always succeed (rc 0).
SHIM_DIR="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SHIM_DIR"
SYSTEMCTL_LOG="$SMOKE_TMP_ROOT/systemctl-calls.log"
IS_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/is-active-rc"
printf '0' >"$IS_ACTIVE_RC_FILE"
cat >"$SHIM_DIR/systemctl" <<EOF
#!/usr/bin/env bash
# #1905 r2: \`systemctl --user\` needs XDG_RUNTIME_DIR to reach the user bus.
# Reproduce the real no-bus failure — if --user is requested without
# XDG_RUNTIME_DIR, fail "connect to bus" and DO NOT log (the call never reached
# the bus). This closes the CI blind spot that masked the r2 regression: a fix
# that forgets to establish XDG_RUNTIME_DIR shows up as ZERO logged calls.
__is_user=0
for __a in "\$@"; do [[ "\$__a" == "--user" ]] && __is_user=1; done
if [[ "\$__is_user" == "1" && -z "\${XDG_RUNTIME_DIR:-}" ]]; then
  echo "systemctl --user: Failed to connect to bus (XDG_RUNTIME_DIR not defined)" >&2
  exit 1
fi
printf '%s\n' "\$*" >>"$SYSTEMCTL_LOG"
case "\$*" in
  *is-active*) exit "\$(cat '$IS_ACTIVE_RC_FILE' 2>/dev/null || printf 0)" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/systemctl"

# #1905 r2: fake user-runtime-dir bases so the smoke can deterministically drive
# _bridge_upgrade_systemd_user_bus_ready (which establishes XDG_RUNTIME_DIR from
# BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE/<uid>) without needing a real /run/user.
# GOOD has the <uid> subdir (bus establishable); EMPTY does not (bus down).
SMOKE_UID="$(id -u)"
RUNTIME_BASE_GOOD="$SMOKE_TMP_ROOT/run-user"
mkdir -p "$RUNTIME_BASE_GOOD/$SMOKE_UID"
RUNTIME_BASE_EMPTY="$SMOKE_TMP_ROOT/run-user-empty"
mkdir -p "$RUNTIME_BASE_EMPTY"
# Default for T1-T5: a reachable bus. Individual tests override per-case.
TEST_RUNTIME_BASE="$RUNTIME_BASE_GOOD"

# Count non-empty lines in a file (0 when absent/empty). grep -c emits "0" AND
# exits non-zero on no match, so a `|| fallback` would double-print — use a
# membership test then grep.
count_calls() {
  local f="$1"
  [[ -s "$f" ]] || { printf '0'; return 0; }
  grep -c . "$f"
}

# Count MUTATING systemctl calls (stop/start) — excludes the read-only
# is-active detection probe. grep -c emits "0" AND exits non-zero on no match,
# which would double-print under a `|| fallback`; capture matches first.
count_mutating_calls() {
  local f="$1" matches
  [[ -s "$f" ]] || { printf '0'; return 0; }
  matches="$(grep -cE '(^| )(stop|start) ' "$f" 2>/dev/null)" || matches=0
  printf '%s' "${matches:-0}"
}

# Run a helper invocation in an isolated bash with the systemctl shim on PATH
# and the CANONICAL detector defined (the lib/bridge-daemon-control.sh path).
# $1 = detector rc (0=systemd, 1=not), $2 = helper to invoke.
run_helper() {
  local det_rc="$1" fn="$2"
  # #1905 r2: run with XDG_RUNTIME_DIR UNSET so the helper MUST establish it from
  # the injected runtime base — otherwise the no-bus shim rejects every `--user`
  # call and the stop/start calls go unlogged (which is exactly the regression we
  # want to catch).
  PATH="$SHIM_DIR:$PATH" \
  BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$TEST_RUNTIME_BASE" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    unset XDG_RUNTIME_DIR
    source '$HELPERS'
    _bridge_daemon_control_systemd_active() { return $det_rc; }
    $fn
  " 2>/dev/null
}

# Run a helper with NO canonical detector in scope — this exercises the INLINE
# `systemctl --user is-active` fallback (the defensive belt-and-suspenders path
# for when lib/bridge-daemon-control.sh is not sourced). In production
# bridge-upgrade.sh DOES source that module (via bridge-lib.sh), so the
# canonical detector exercised in T1/T3 is the normal path and this inline
# fallback is the safety net. The is-active outcome is controlled via
# IS_ACTIVE_RC_FILE. $1 = helper.
run_helper_inline_fallback() {
  local fn="$1"
  PATH="$SHIM_DIR:$PATH" \
  BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$TEST_RUNTIME_BASE" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    unset XDG_RUNTIME_DIR
    source '$HELPERS'
    $fn
  " 2>/dev/null
}

# --- T1: systemd-active quiesce stops ONLY the SERVICE (#2064: leaves timer up) -
# Issue #2064 (Finding 2): the quiesce no longer stops agent-bridge-daemon-liveness
# .timer. Stopping it was the old way to keep the watcher from racing the #1820
# fence, but it left a SIGKILL'd upgrade with no running invoker to observe the
# quiesce marker → daemon stuck down. The timer now stays running; the watcher's
# live_upgrade_quiesce_in_flight DEFER guard keeps it from racing the fence while
# the upgrade pid is alive. So the quiesce makes exactly ONE mutating call —
# stop the SERVICE — and MUST NOT stop the timer.
: >"$SYSTEMCTL_LOG"
run_helper 0 _bridge_upgrade_systemd_quiesce_daemon
Q_CALLS="$(cat "$SYSTEMCTL_LOG")"
Q_MUT="$(count_mutating_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "1" "$Q_MUT" "T1 quiesce makes exactly 1 mutating systemctl call (stop service only) (got: $Q_CALLS)"
smoke_assert_contains "$Q_CALLS" "stop agent-bridge-daemon.service" "T1 stops the SERVICE"
grep -E 'stop[[:space:]]+agent-bridge-daemon-liveness\.timer' "$SYSTEMCTL_LOG" >/dev/null 2>&1 \
  && smoke_fail "T1 FAIL (#2064 regression): quiesce must NOT stop the liveness TIMER (a SIGKILL'd upgrade then has no invoker). calls=$Q_CALLS"
smoke_log "T1 PASS: systemd quiesce stops daemon.service ONLY, leaves liveness.timer running (#2064)"

# --- T2: systemd restart starts service THEN re-arms timer -------------------
# The restart helper is systemctl-presence-gated (not is-active), so the
# detector override is irrelevant here — pass 0 for symmetry.
# Issue #2040: the restore now also VERIFIES is-active for both units after
# starting them, so the assertion is on the MUTATING-call order (start service ->
# start timer), not an exact total count. The default shim reports is-active=0
# (active) so the verify passes cleanly.
: >"$SYSTEMCTL_LOG"
run_helper 0 _bridge_upgrade_systemd_restart_daemon
R_CALLS="$(cat "$SYSTEMCTL_LOG")"
# Mutating starts in order (excludes the read-only is-active verify probes).
R_START_SEQ="$(grep -oE 'start agent-bridge-daemon(\.service|-liveness\.timer)' "$SYSTEMCTL_LOG" | tr '\n' '|' | sed 's/|$//')"
smoke_assert_contains "$R_CALLS" "start agent-bridge-daemon.service" "T2 starts the SERVICE"
smoke_assert_contains "$R_CALLS" "start agent-bridge-daemon-liveness.timer" "T2 re-arms the liveness TIMER"
smoke_assert_eq "start agent-bridge-daemon.service|start agent-bridge-daemon-liveness.timer" "$R_START_SEQ" \
  "T2 start order is service -> timer (got: $R_START_SEQ; full: $R_CALLS)"
# The #2040 verify probe must run is-active for both units.
smoke_assert_contains "$R_CALLS" "is-active agent-bridge-daemon.service" "T2 verifies is-active for the SERVICE (#2040)"
smoke_assert_contains "$R_CALLS" "is-active agent-bridge-daemon-liveness.timer" "T2 verifies is-active for the TIMER (#2040)"
smoke_log "T2 PASS: systemd restart starts daemon.service THEN re-arms liveness.timer (with #2040 is-active verify)"

# --- T3: NON-systemd (canonical detector → false) makes ZERO systemctl calls -
# Detector → false. Run with the systemctl shim STILL on PATH to prove the
# quiesce helper short-circuits on the detector (not merely on systemctl being
# absent) and never touches systemctl on a non-systemd install.
: >"$SYSTEMCTL_LOG"
run_helper 1 _bridge_upgrade_systemd_quiesce_daemon
NS_COUNT="$(count_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "0" "$NS_COUNT" "T3 non-systemd quiesce (canonical detector false) makes ZERO systemctl calls (got: $(cat "$SYSTEMCTL_LOG"))"
smoke_log "T3 PASS: non-systemd path (canonical detector) makes zero systemctl calls (unchanged behavior)"

# --- T4: INLINE-fallback path, service INACTIVE → ZERO MUTATING calls ---------
# The defensive fallback: when lib/bridge-daemon-control.sh is NOT in scope the
# gate uses the inline `systemctl --user is-active` check instead of the
# canonical detector. (In production bridge-upgrade.sh sources that module via
# bridge-lib.sh, so this fallback is belt-and-suspenders — but it must still be
# correct.) With the service inactive the quiesce helper must make ONLY the
# read-only is-active probe and ZERO mutating (stop/start) calls — i.e. a
# non-systemd / inactive install is behaviorally unchanged (no daemon-unit
# state is touched).
: >"$SYSTEMCTL_LOG"
printf '1' >"$IS_ACTIVE_RC_FILE"   # is-active → inactive
run_helper_inline_fallback _bridge_upgrade_systemd_quiesce_daemon
T4_MUT="$(count_mutating_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "0" "$T4_MUT" "T4 inline-fallback inactive quiesce makes ZERO mutating systemctl calls (got: $(cat "$SYSTEMCTL_LOG"))"
# And it must have actually probed is-active (proving the inline fallback ran).
grep -q 'is-active' "$SYSTEMCTL_LOG" \
  || smoke_fail "T4 FAIL: inline fallback did not probe is-active (got: $(cat "$SYSTEMCTL_LOG"))"
smoke_log "T4 PASS: inline-fallback inactive path probes is-active only, zero mutating calls"

# --- T5: INLINE-fallback path, service ACTIVE → stop SERVICE only (#2064) ------
# Same inline fallback, but is-active → active: the quiesce helper must stop the
# SERVICE (proving the inline fallback gate also drives the fix, not just the
# canonical-detector path). Issue #2064: it must NOT stop the liveness timer (the
# timer stays running so a SIGKILL'd upgrade still has an invoker).
: >"$SYSTEMCTL_LOG"
printf '0' >"$IS_ACTIVE_RC_FILE"   # is-active → active
run_helper_inline_fallback _bridge_upgrade_systemd_quiesce_daemon
T5_MUT="$(count_mutating_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "1" "$T5_MUT" "T5 inline-fallback active quiesce makes 1 mutating systemctl call (stop service only) (got: $(cat "$SYSTEMCTL_LOG"))"
T5_STOPS="$(grep -E '(^| )stop ' "$SYSTEMCTL_LOG")"
smoke_assert_contains "$T5_STOPS" "stop agent-bridge-daemon.service" "T5 inline-fallback stops the SERVICE"
grep -E 'stop[[:space:]]+agent-bridge-daemon-liveness\.timer' "$SYSTEMCTL_LOG" >/dev/null 2>&1 \
  && smoke_fail "T5 FAIL (#2064 regression): inline-fallback quiesce must NOT stop the liveness TIMER. stops=$T5_STOPS"
smoke_log "T5 PASS: inline-fallback active path stops daemon.service ONLY, leaves liveness.timer running (#2064)"

# --- T6: user-bus establishment (_bridge_upgrade_systemd_user_bus_ready) -------
# (a) XDG unset + a present /run/user/<uid> (GOOD base) → exports XDG_RUNTIME_DIR.
T6_OUT="$SMOKE_TMP_ROOT/t6-xdg.out"
: >"$T6_OUT"
PATH="$SHIM_DIR:$PATH" BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$RUNTIME_BASE_GOOD" "$BRIDGE_BASH" -c "
  set -uo pipefail
  unset XDG_RUNTIME_DIR
  source '$HELPERS'
  _bridge_upgrade_systemd_user_bus_ready && printf '%s' \"\${XDG_RUNTIME_DIR:-}\" >'$T6_OUT'
" 2>/dev/null
smoke_assert_eq "$RUNTIME_BASE_GOOD/$SMOKE_UID" "$(cat "$T6_OUT")" "T6a bus-ready exports XDG_RUNTIME_DIR from /run/user/<uid> when unset"
# (b) XDG already set to an existing dir → respected unchanged (BASE ignored).
: >"$T6_OUT"
PATH="$SHIM_DIR:$PATH" XDG_RUNTIME_DIR="$RUNTIME_BASE_GOOD" BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$RUNTIME_BASE_EMPTY" "$BRIDGE_BASH" -c "
  set -uo pipefail
  source '$HELPERS'
  _bridge_upgrade_systemd_user_bus_ready && printf '%s' \"\${XDG_RUNTIME_DIR:-}\" >'$T6_OUT'
" 2>/dev/null
smoke_assert_eq "$RUNTIME_BASE_GOOD" "$(cat "$T6_OUT")" "T6b bus-ready respects an already-set XDG_RUNTIME_DIR"
# (c) XDG unset + NO /run/user/<uid> (EMPTY base) → returns non-zero (bus down).
if PATH="$SHIM_DIR:$PATH" BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$RUNTIME_BASE_EMPTY" "$BRIDGE_BASH" -c "
  set -uo pipefail
  unset XDG_RUNTIME_DIR
  source '$HELPERS'
  _bridge_upgrade_systemd_user_bus_ready
" 2>/dev/null; then
  smoke_fail "T6c FAIL: bus-ready must return non-zero when no user runtime dir exists"
fi
smoke_log "T6 PASS: user-bus establishment (export-when-unset / respect-when-set / fail-when-no-runtime-dir)"

# --- T7: no reachable user bus → quiesce makes ZERO systemctl calls -----------
# XDG unset + NO /run/user/<uid>: the bus-ready gate fails, so even with the
# canonical detector "active" the quiesce helper must NOT emit broken
# `systemctl --user` calls — it short-circuits (detector returns 1) and the real
# call site falls back to the script-level stop. The no-bus shim would reject any
# leaked `--user` call, so ZERO logged calls proves the graceful fallback (this
# is the regression T1 catches from the other side: T1 needs the helper to
# ESTABLISH the bus, T7 needs it to FALL BACK when it cannot).
: >"$SYSTEMCTL_LOG"
TEST_RUNTIME_BASE="$RUNTIME_BASE_EMPTY"
run_helper 0 _bridge_upgrade_systemd_quiesce_daemon
T7_COUNT="$(count_calls "$SYSTEMCTL_LOG")"
TEST_RUNTIME_BASE="$RUNTIME_BASE_GOOD"
smoke_assert_eq "0" "$T7_COUNT" "T7 no-bus quiesce makes ZERO systemctl calls (graceful fallback, got: $(cat "$SYSTEMCTL_LOG"))"
smoke_log "T7 PASS: no reachable user bus → quiesce short-circuits to script-level fallback (zero systemctl calls)"

smoke_log "all systemd quiesce/respawn tests PASS (#1905)"
