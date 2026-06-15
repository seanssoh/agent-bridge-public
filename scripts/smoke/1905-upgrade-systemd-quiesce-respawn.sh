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
# The fix adds three gated, best-effort systemd helpers to bridge-upgrade.sh:
#   _bridge_upgrade_daemon_systemd_active   — systemctl + service is-active gate
#   _bridge_upgrade_systemd_quiesce_daemon  — stop timer THEN service (no respawn)
#   _bridge_upgrade_systemd_restart_daemon  — start service THEN re-arm timer
#
# This smoke sources ONLY those helper bodies from the live bridge-upgrade.sh
# source (extracted between the #1905 BEGIN/END markers, so the test tracks the
# real implementation, not a copy), installs a `systemctl` shim that records
# every call, and asserts:
#   T1 — systemd-active quiesce stops the liveness TIMER, then the SERVICE
#        (timer first so it can't re-fire the service).
#   T2 — systemd restart starts the SERVICE, then re-arms the liveness TIMER.
#   T3 — NON-systemd path (detector → false) makes ZERO systemctl calls
#        (byte-for-byte unchanged behavior) even with systemctl on PATH.

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
printf '%s\n' "\$*" >>"$SYSTEMCTL_LOG"
case "\$*" in
  *is-active*) exit "\$(cat '$IS_ACTIVE_RC_FILE' 2>/dev/null || printf 0)" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/systemctl"

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
  PATH="$SHIM_DIR:$PATH" "$BRIDGE_BASH" -c "
    set -uo pipefail
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
  PATH="$SHIM_DIR:$PATH" "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$HELPERS'
    $fn
  " 2>/dev/null
}

# --- T1: systemd-active quiesce stops timer THEN service ---------------------
: >"$SYSTEMCTL_LOG"
run_helper 0 _bridge_upgrade_systemd_quiesce_daemon
Q_CALLS="$(cat "$SYSTEMCTL_LOG")"
Q_FIRST="$(sed -n '1p' "$SYSTEMCTL_LOG")"
Q_SECOND="$(sed -n '2p' "$SYSTEMCTL_LOG")"
Q_COUNT="$(count_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "2" "$Q_COUNT" "T1 quiesce makes exactly 2 systemctl calls (got: $Q_CALLS)"
smoke_assert_contains "$Q_FIRST" "stop agent-bridge-daemon-liveness.timer" "T1 first call stops the liveness TIMER"
smoke_assert_contains "$Q_SECOND" "stop agent-bridge-daemon.service" "T1 second call stops the SERVICE"
# Order: the timer must be stopped before the service (so it can't re-fire it).
[[ "$Q_FIRST" == *"liveness.timer"* && "$Q_SECOND" == *"daemon.service"* ]] \
  || smoke_fail "T1 FAIL: timer must be stopped BEFORE service. calls=$Q_CALLS"
smoke_log "T1 PASS: systemd quiesce stops liveness.timer THEN daemon.service"

# --- T2: systemd restart starts service THEN re-arms timer -------------------
# The restart helper is systemctl-presence-gated (not is-active), so the
# detector override is irrelevant here — pass 0 for symmetry.
: >"$SYSTEMCTL_LOG"
run_helper 0 _bridge_upgrade_systemd_restart_daemon
R_CALLS="$(cat "$SYSTEMCTL_LOG")"
R_FIRST="$(sed -n '1p' "$SYSTEMCTL_LOG")"
R_SECOND="$(sed -n '2p' "$SYSTEMCTL_LOG")"
R_COUNT="$(count_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "2" "$R_COUNT" "T2 restart makes exactly 2 systemctl calls (got: $R_CALLS)"
smoke_assert_contains "$R_FIRST" "start agent-bridge-daemon.service" "T2 first call starts the SERVICE"
smoke_assert_contains "$R_SECOND" "start agent-bridge-daemon-liveness.timer" "T2 second call re-arms the liveness TIMER"
[[ "$R_FIRST" == *"daemon.service"* && "$R_SECOND" == *"liveness.timer"* ]] \
  || smoke_fail "T2 FAIL: service must be started BEFORE the timer. calls=$R_CALLS"
smoke_log "T2 PASS: systemd restart starts daemon.service THEN re-arms liveness.timer"

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

# --- T5: INLINE-fallback path, service ACTIVE → timer-then-service stop -------
# Same inline fallback, but is-active → active: the quiesce helper must now
# stop the liveness TIMER then the SERVICE (proving the inline fallback gate
# also drives the fix, not just the canonical-detector path).
: >"$SYSTEMCTL_LOG"
printf '0' >"$IS_ACTIVE_RC_FILE"   # is-active → active
run_helper_inline_fallback _bridge_upgrade_systemd_quiesce_daemon
T5_MUT="$(count_mutating_calls "$SYSTEMCTL_LOG")"
smoke_assert_eq "2" "$T5_MUT" "T5 inline-fallback active quiesce makes 2 mutating systemctl calls (got: $(cat "$SYSTEMCTL_LOG"))"
T5_STOPS="$(grep -E '(^| )stop ' "$SYSTEMCTL_LOG")"
T5_FIRST_STOP="$(printf '%s\n' "$T5_STOPS" | sed -n '1p')"
T5_SECOND_STOP="$(printf '%s\n' "$T5_STOPS" | sed -n '2p')"
[[ "$T5_FIRST_STOP" == *"liveness.timer"* && "$T5_SECOND_STOP" == *"daemon.service"* ]] \
  || smoke_fail "T5 FAIL: inline-fallback must stop timer BEFORE service. stops=$T5_STOPS"
smoke_log "T5 PASS: inline-fallback active path stops liveness.timer THEN daemon.service"

smoke_log "all systemd quiesce/respawn tests PASS (#1905)"
