#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/655-upgrade-launchd-quiesce-respawn.sh — Issue #655.
#
# The macOS launchd analog of #1905. On a macOS launchd install the daemon
# lifecycle is owned by the agent-bridge LaunchAgent (`KeepAlive=true`). The
# #1820 reconcile quiesce in bridge-upgrade.sh used a script-level
# `bridge-daemon.sh stop` only, which is NOT launchd-aware: launchd respawns the
# daemon within ~1-2s inside the quiesce window and the fail-closed fence keeps
# seeing a live pid → rc=3 abort → half-applied upgrade. (Same failure shape
# #1905 fixed for systemd; the systemd helpers are a no-op on macOS because they
# gate on `systemctl`.)
#
# The fix adds gated, best-effort launchd helpers to bridge-upgrade.sh:
#   _bridge_upgrade_daemon_launchd_active   — Darwin + launchctl + resolvable
#                                             agent-bridge LaunchAgent label gate
#   _bridge_upgrade_launchd_quiesce_daemon  — disable THEN bootout the KeepAlive
#                                             job (so launchd cannot respawn)
#   _bridge_upgrade_launchd_restart_daemon  — enable + bootstrap(plist) +
#                                             kickstart to restore on restart
#
# This smoke sources ONLY those helper bodies from the live bridge-upgrade.sh
# source (extracted between the #655 BEGIN/END markers, so the test tracks the
# real implementation, not a copy), installs a `launchctl` shim that records
# every call, stubs the launchd-label resolver + a `uname` shim, and asserts:
#   T1 — launchd-active quiesce DISABLEs the job, THEN BOOTs it OUT (disable
#        first so KeepAlive can't immediately re-load the booted-out job).
#   T2 — launchd restart ENABLEs the job, BOOTSTRAPs the plist, THEN kickstarts.
#   T3 — NON-launchd path (uname → Linux) makes ZERO launchctl calls (byte-for-
#        byte unchanged behavior) even with launchctl on PATH.
#   T4 — launchctl ABSENT → detector false → quiesce makes ZERO calls (graceful
#        fallback to the script-level stop, no broken launchctl invocations).
#   T5 — launchd-ish host but the label can't be resolved (empty) → detector
#        false → quiesce makes ZERO mutating calls (graceful WARN fallback).

set -uo pipefail
SMOKE_NAME="655-upgrade-launchd-quiesce-respawn"
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

# Extract the #655 helper bodies verbatim from the live source so the smoke
# never drifts from the implementation. The markers are stable comment fences.
HELPERS="$SMOKE_TMP_ROOT/655-helpers.sh"
awk '/^# BEGIN: Issue #655 launchd-aware/{f=1} f{print} /^# END: Issue #655 launchd-aware/{f=0}' \
  "$UPGRADE_SRC" >"$HELPERS"
grep -q '_bridge_upgrade_launchd_quiesce_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #655 helpers from $UPGRADE_SRC"

# A `launchctl` shim that appends each invocation (args joined by spaces) to a
# log file, then exits 0. Drop it on a PATH-front dir so the helpers resolve
# THIS one. The launchctl subcommands the helpers drive (disable/bootout/enable/
# bootstrap/kickstart) all "succeed" so the test asserts on the recorded
# call sequence, not on launchctl behavior.
SHIM_DIR="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SHIM_DIR"
LAUNCHCTL_LOG="$SMOKE_TMP_ROOT/launchctl-calls.log"
cat >"$SHIM_DIR/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LAUNCHCTL_LOG"
exit 0
EOF
chmod +x "$SHIM_DIR/launchctl"

# A `uname` shim so the smoke can drive the Darwin gate deterministically on a
# Linux CI host (and a non-Darwin value for the T3 unchanged-path assertion).
# Reads the desired kernel name from UNAME_OUT in the environment.
cat >"$SHIM_DIR/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${UNAME_OUT:-Linux}"
EOF
chmod +x "$SHIM_DIR/uname"

SMOKE_UID="$(id -u)"
TEST_LABEL="ai.agent-bridge.daemon"
TEST_PLIST="$SMOKE_TMP_ROOT/${TEST_LABEL}.plist"
# A present plist so the restart helper takes the bootstrap branch (not the
# kickstart-only fallback). Contents are irrelevant — the shim records the call.
printf '<plist/>\n' >"$TEST_PLIST"

# state/launchagent.config marker so the restart helper resolves the plist from
# the same source the installer writes. TARGET_ROOT points at this temp home.
# Exported once (constant across every helper run) so the per-command env
# prefixes below don't have to re-derive a $TARGET_ROOT-relative path (which
# tripped SC2097/SC2098: a same-line `BRIDGE_STATE_DIR="$TARGET_ROOT/state"`
# would expand the PARENT's value, not the just-assigned prefix).
export TARGET_ROOT="$SMOKE_TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$TARGET_ROOT/state"
mkdir -p "$TARGET_ROOT/state"
cat >"$TARGET_ROOT/state/launchagent.config" <<EOF
BRIDGE_LAUNCHAGENT_LABEL=$TEST_LABEL
BRIDGE_LAUNCHAGENT_PLIST=$TEST_PLIST
EOF

# Count non-empty lines in a file (0 when absent/empty). grep -c emits "0" AND
# exits non-zero on no match, so a `|| fallback` would double-print — use a
# membership test then grep.
count_calls() {
  local f="$1"
  [[ -s "$f" ]] || { printf '0'; return 0; }
  grep -c . "$f"
}

# Count MUTATING launchctl calls (disable/bootout/enable/bootstrap/kickstart).
# All launchctl calls the helpers make are mutating; this excludes nothing today
# but mirrors the #1905 smoke's read-only/mutating split convention so a future
# read-only probe addition would not silently inflate the assertion.
count_mutating_calls() {
  local f="$1" matches
  [[ -s "$f" ]] || { printf '0'; return 0; }
  matches="$(grep -cE '(^| )(disable|bootout|enable|bootstrap|kickstart) ' "$f" 2>/dev/null)" || matches=0
  printf '%s' "${matches:-0}"
}

# Run a helper invocation in an isolated bash with the launchctl + uname shims on
# PATH and a stubbed _bridge_daemon_launchd_label (the lib/bridge-daemon-control.sh
# resolver, which the helper calls to learn the label + the "we are
# launchd-managed" signal). $1 = the label the stub returns (empty = unresolvable),
# $2 = UNAME_OUT (kernel name for the Darwin gate), $3 = helper to invoke.
run_helper() {
  local stub_label="$1" uname_out="$2" fn="$3"
  PATH="$SHIM_DIR:$PATH" \
  UNAME_OUT="$uname_out" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$HELPERS'
    _bridge_daemon_launchd_label() { printf '%s' '$stub_label'; [[ -n '$stub_label' ]]; }
    $fn
  " >/dev/null 2>&1
}

# Same as run_helper but with NO _bridge_daemon_launchd_label resolver in scope —
# exercises the detector's `command -v _bridge_daemon_launchd_label` guard
# (graceful no-op when lib/bridge-daemon-control.sh is not sourced). In production
# bridge-upgrade.sh DOES source that module via bridge-lib.sh, so this is the
# safety net. $1 = UNAME_OUT, $2 = helper, $3 (optional) = "no-launchctl" to drop
# the launchctl shim from PATH.
run_helper_no_resolver() {
  local uname_out="$1" fn="$2" mode="${3:-}"
  local path_front="$SHIM_DIR"
  if [[ "$mode" == "no-launchctl" ]]; then
    # A PATH dir with the uname shim but NO launchctl, and scrub the system
    # launchctl by pointing at an empty bin then the uname-only dir.
    local nl_dir="$SMOKE_TMP_ROOT/bin-no-launchctl"
    mkdir -p "$nl_dir"
    cp "$SHIM_DIR/uname" "$nl_dir/uname"
    # Run with a PATH that has ONLY our uname shim dir (no launchctl anywhere).
    UNAME_OUT="$uname_out" \
    PATH="$nl_dir" \
    "$BRIDGE_BASH" -c "
      set -uo pipefail
      source '$HELPERS'
      $fn
    " >/dev/null 2>&1
    return 0
  fi
  PATH="$path_front:$PATH" \
  UNAME_OUT="$uname_out" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$HELPERS'
    $fn
  " >/dev/null 2>&1
}

# --- T1: launchd-active quiesce DISABLEs then BOOTs OUT ----------------------
: >"$LAUNCHCTL_LOG"
run_helper "$TEST_LABEL" "Darwin" _bridge_upgrade_launchd_quiesce_daemon
Q_CALLS="$(cat "$LAUNCHCTL_LOG")"
Q_FIRST="$(sed -n '1p' "$LAUNCHCTL_LOG")"
Q_SECOND="$(sed -n '2p' "$LAUNCHCTL_LOG")"
Q_COUNT="$(count_calls "$LAUNCHCTL_LOG")"
smoke_assert_eq "2" "$Q_COUNT" "T1 quiesce makes exactly 2 launchctl calls (got: $Q_CALLS)"
smoke_assert_contains "$Q_FIRST" "disable gui/${SMOKE_UID}/${TEST_LABEL}" "T1 first call DISABLEs the launchd job"
smoke_assert_contains "$Q_SECOND" "bootout gui/${SMOKE_UID}/${TEST_LABEL}" "T1 second call BOOTs OUT the launchd job"
# Order: disable before bootout so KeepAlive can't immediately re-load the job.
[[ "$Q_FIRST" == *"disable"* && "$Q_SECOND" == *"bootout"* ]] \
  || smoke_fail "T1 FAIL: must disable BEFORE bootout. calls=$Q_CALLS"
smoke_log "T1 PASS: launchd quiesce disables THEN boots out the KeepAlive job"

# --- T2: launchd restart ENABLEs, BOOTSTRAPs the plist, THEN kickstarts ------
: >"$LAUNCHCTL_LOG"
run_helper "$TEST_LABEL" "Darwin" _bridge_upgrade_launchd_restart_daemon
R_CALLS="$(cat "$LAUNCHCTL_LOG")"
R_FIRST="$(sed -n '1p' "$LAUNCHCTL_LOG")"
R_SECOND="$(sed -n '2p' "$LAUNCHCTL_LOG")"
R_THIRD="$(sed -n '3p' "$LAUNCHCTL_LOG")"
R_COUNT="$(count_calls "$LAUNCHCTL_LOG")"
smoke_assert_eq "3" "$R_COUNT" "T2 restart makes exactly 3 launchctl calls (got: $R_CALLS)"
smoke_assert_contains "$R_FIRST" "enable gui/${SMOKE_UID}/${TEST_LABEL}" "T2 first call ENABLEs the launchd job"
smoke_assert_contains "$R_SECOND" "bootstrap gui/${SMOKE_UID} $TEST_PLIST" "T2 second call BOOTSTRAPs the resolved plist"
smoke_assert_contains "$R_THIRD" "kickstart -k gui/${SMOKE_UID}/${TEST_LABEL}" "T2 third call kickstarts the job"
[[ "$R_FIRST" == *"enable"* && "$R_SECOND" == *"bootstrap"* && "$R_THIRD" == *"kickstart"* ]] \
  || smoke_fail "T2 FAIL: must enable -> bootstrap -> kickstart in order. calls=$R_CALLS"
smoke_log "T2 PASS: launchd restart enables, bootstraps the plist, then kickstarts"

# --- T3: NON-launchd (uname → Linux) makes ZERO launchctl calls --------------
# uname → Linux. Run with the launchctl shim STILL on PATH to prove the quiesce
# helper short-circuits on the Darwin gate (not merely on launchctl being
# absent) and never touches launchctl on a non-launchd install.
: >"$LAUNCHCTL_LOG"
run_helper "$TEST_LABEL" "Linux" _bridge_upgrade_launchd_quiesce_daemon
NS_COUNT="$(count_calls "$LAUNCHCTL_LOG")"
smoke_assert_eq "0" "$NS_COUNT" "T3 non-launchd quiesce (uname Linux) makes ZERO launchctl calls (got: $(cat "$LAUNCHCTL_LOG"))"
smoke_log "T3 PASS: non-launchd path (uname Linux) makes zero launchctl calls (unchanged behavior)"

# --- T4: launchctl ABSENT → ZERO calls (graceful fallback) -------------------
# Darwin host but NO launchctl on PATH: the detector's `command -v launchctl`
# guard fails, so the quiesce helper short-circuits to ZERO calls and the real
# call site falls back to the script-level stop. (No resolver in scope either —
# this is the most degraded path; it must still be a clean no-op.)
: >"$LAUNCHCTL_LOG"
run_helper_no_resolver "Darwin" _bridge_upgrade_launchd_quiesce_daemon no-launchctl
T4_COUNT="$(count_calls "$LAUNCHCTL_LOG")"
smoke_assert_eq "0" "$T4_COUNT" "T4 no-launchctl quiesce makes ZERO launchctl calls (graceful fallback, got: $(cat "$LAUNCHCTL_LOG"))"
smoke_log "T4 PASS: launchctl absent → quiesce short-circuits to script-level fallback (zero launchctl calls)"

# --- T5: launchd-ish host but UNRESOLVABLE label → ZERO mutating calls --------
# Darwin + launchctl present, but the label resolves empty (no marker / no
# plist): the detector returns false and the quiesce helper makes ZERO mutating
# calls — a behaviorally-unchanged no-op rather than emitting broken
# `gui/<uid>/` calls with an empty label.
: >"$LAUNCHCTL_LOG"
run_helper "" "Darwin" _bridge_upgrade_launchd_quiesce_daemon
T5_MUT="$(count_mutating_calls "$LAUNCHCTL_LOG")"
smoke_assert_eq "0" "$T5_MUT" "T5 unresolvable-label quiesce makes ZERO mutating launchctl calls (got: $(cat "$LAUNCHCTL_LOG"))"
smoke_log "T5 PASS: launchd-ish host with no resolvable label → quiesce is a clean no-op (zero mutating calls)"

smoke_log "all launchd quiesce/respawn tests PASS (#655)"
