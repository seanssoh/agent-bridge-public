#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2210-norestart-reconcile-restore.sh — Issue #2210.
#
# `agb upgrade --apply ... --no-restart-daemon` could leave the daemon silently
# DOWN: the #1820 layout-v2 reconcile ALWAYS quiesces (boots out + disables) a
# managed daemon for its reconcile window, REGARDLESS of --restart-daemon. With
# --no-restart-daemon the restart phase is skipped, so the old code's
# --no-restart branch did ONLY `_bridge_upgrade_clear_quiesce_marker` — leaving
# the booted-out launchd/systemd job unloaded AND clearing the one signal the
# standing liveness watcher uses to recover an interrupted-upgrade disable. Net:
# a daemon that was UP before the upgrade is left down with no auto-recovery
# (fleet-down). The fix restores a RECONCILE-INDUCED bootout even under
# --no-restart-daemon (suppressing only an *elective* restart), gated STRICTLY on
# _UPGRADE_DAEMON_*_MANAGED set THIS run by the quiesce block, mirroring the
# RESTART_DAEMON==1 branch's restore + marker discrimination, and KEEPING the
# marker (+ loud WARN) when recovery is not confirmed.
#
# This smoke sources the #2210 no-restart branch body, the #655/#2040 launchd +
# #1905 systemd restore helpers, and the #2055 marker helpers VERBATIM from the
# live bridge-upgrade.sh (extracted between stable comment markers, so the test
# tracks the real implementation, not a copy), installs scripted launchctl /
# systemctl shims + a marker harness, and drives the no-restart decision logic.
#
#   T1 — launchd MANAGED this run, bootstrap succeeds → restore helper IS invoked
#        (bootstrap called), job ends LOADED, quiesce marker CLEARED.
#   T2 — systemd MANAGED this run, units active → restore helper IS invoked
#        (start called), load-state active, quiesce marker CLEARED.
#   T3 — launchd MANAGED this run, bootstrap NEVER loads → restore IS invoked,
#        load-state not_loaded, a loud non-swallowed WARN is emitted, AND the
#        quiesce marker is KEPT (not cleared) for the liveness watcher (#2210
#        option 3 + the #2055/#2064 marker-discrimination invariant).
#   NEG — NEITHER _UPGRADE_DAEMON_*_MANAGED set (an operator-disabled / already-down
#        job, NOT a reconcile-induced bootout) → the restore helper is NOT invoked
#        (no bootstrap/start), the marker is cleared. The ★hard guard: an upgrade
#        never resurrects a job the operator independently disabled.
#   MUTATION — re-run T1's harness against a MUTATED branch body (the pre-fix
#        clear-only branch): the restore helper is NOT invoked → the job is left
#        NOT loaded + the marker cleared (silent-down). The smoke asserts this
#        regression IS detected (mutation guard: revert ⇒ smoke fails).

set -uo pipefail
SMOKE_NAME="2210-norestart-reconcile-restore"
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

# --- Extract live helper bodies + the #2210 branch verbatim -------------------
HELPERS="$SMOKE_TMP_ROOT/2210-helpers.sh"
awk '
  /^# BEGIN: Issue #2040 launchd restore/{f=1}
  /^# BEGIN: Issue #655 launchd-aware/{f=1}
  /^# BEGIN: Issue #1905 systemd-aware/{f=1}
  /^# BEGIN: Issue #2055 durable quiesce-intent/{f=1}
  f{print}
  /^# END: Issue #655 launchd-aware/{f=0}
  /^# END: Issue #1905 systemd-aware/{f=0}
  /^# END: Issue #2055 durable quiesce-intent/{f=0}
' "$UPGRADE_SRC" >"$HELPERS"
grep -q '_bridge_upgrade_launchd_restart_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #2040/#655 launchd restart helper from $UPGRADE_SRC"
grep -q '_bridge_upgrade_systemd_restart_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #1905 systemd restart helper from $UPGRADE_SRC"
grep -q '_bridge_upgrade_clear_quiesce_marker()' "$HELPERS" \
  || smoke_fail "could not extract the #2055 clear-marker helper from $UPGRADE_SRC"
grep -q '_bridge_upgrade_quiesce_marker_path()' "$HELPERS" \
  || smoke_fail "could not extract the #2055 marker-path helper from $UPGRADE_SRC"

# The #2210 no-restart branch body (the part inside `elif [[ $DRY_RUN -eq 0 ]]`).
BRANCH="$SMOKE_TMP_ROOT/2210-branch.sh"
awk '
  /^  # BEGIN: Issue #2210 no-restart reconcile-induced bootout restore/{f=1}
  f{print}
  /^  # END: Issue #2210 no-restart reconcile-induced bootout restore/{f=0}
' "$UPGRADE_SRC" >"$BRANCH"
grep -q '_bridge_upgrade_launchd_restart_daemon' "$BRANCH" \
  || smoke_fail "MUTATION GUARD (static): the #2210 no-restart branch does NOT call _bridge_upgrade_launchd_restart_daemon — the reconcile-induced bootout restore was reverted/removed. A --no-restart-daemon upgrade would leave a booted-out launchd daemon silently DOWN. branch=$(cat "$BRANCH")"
grep -q '_bridge_upgrade_systemd_restart_daemon' "$BRANCH" \
  || smoke_fail "MUTATION GUARD (static): the #2210 no-restart branch does NOT call _bridge_upgrade_systemd_restart_daemon — the reconcile-induced bootout restore was reverted/removed. branch=$(cat "$BRANCH")"
grep -q '_UPGRADE_DAEMON_SYSTEMD_MANAGED' "$BRANCH" && grep -q '_UPGRADE_DAEMON_LAUNCHD_MANAGED' "$BRANCH" \
  || smoke_fail "MUTATION GUARD (static): the #2210 branch restore is NOT gated on _UPGRADE_DAEMON_*_MANAGED — the ★hard guard (restore ONLY a reconcile-induced bootout, never an operator-disabled job) is missing. branch=$(cat "$BRANCH")"

# --- Shims --------------------------------------------------------------------
SHIM_DIR="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SHIM_DIR"
LAUNCHCTL_LOG="$SMOKE_TMP_ROOT/launchctl-calls.log"
SYSTEMCTL_LOG="$SMOKE_TMP_ROOT/systemctl-calls.log"
JOB_LOADED_FILE="$SMOKE_TMP_ROOT/job-loaded"
PRINT_COUNTDOWN_FILE="$SMOKE_TMP_ROOT/print-loaded-countdown"
BOOTSTRAP_FAIL_N_FILE="$SMOKE_TMP_ROOT/bootstrap-fail-first-n"
BOOTSTRAP_ERR_FILE="$SMOKE_TMP_ROOT/bootstrap-err-msg"
BOOTSTRAP_COUNT_FILE="$SMOKE_TMP_ROOT/bootstrap-call-count"
SVC_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/svc-is-active-rc"
TIMER_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/timer-is-active-rc"

cat >"$SHIM_DIR/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LAUNCHCTL_LOG"
sub="\${1:-}"
case "\$sub" in
  print)
    c=0
    [[ -s "$PRINT_COUNTDOWN_FILE" ]] && c="\$(cat "$PRINT_COUNTDOWN_FILE")"
    if [[ "\$c" =~ ^[0-9]+\$ ]] && (( c > 0 )); then
      printf '%s' "\$(( c - 1 ))" >"$PRINT_COUNTDOWN_FILE"
      exit 0
    fi
    loaded=0; [[ -s "$JOB_LOADED_FILE" ]] && loaded="\$(cat "$JOB_LOADED_FILE")"
    [[ "\$loaded" == "1" ]] && exit 0
    exit 1
    ;;
  bootstrap)
    n="\$(cat "$BOOTSTRAP_COUNT_FILE" 2>/dev/null || printf 0)"
    n=\$(( n + 1 )); printf '%s' "\$n" >"$BOOTSTRAP_COUNT_FILE"
    failn=0; [[ -s "$BOOTSTRAP_FAIL_N_FILE" ]] && failn="\$(cat "$BOOTSTRAP_FAIL_N_FILE")"
    if [[ "\$failn" =~ ^[0-9]+\$ ]] && (( n <= failn )); then
      msg="\$(cat "$BOOTSTRAP_ERR_FILE" 2>/dev/null || printf 'Bootstrap failed')"
      printf '%s\n' "\$msg" >&2
      exit 1
    fi
    printf '1' >"$JOB_LOADED_FILE"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/launchctl"

cat >"$SHIM_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYSTEMCTL_LOG"
case "\$*" in
  *"is-active agent-bridge-daemon.service"*) exit "\$(cat "$SVC_ACTIVE_RC_FILE")" ;;
  *"is-active agent-bridge-daemon-liveness.timer"*) exit "\$(cat "$TIMER_ACTIVE_RC_FILE")" ;;
  *start*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/systemctl"

cat >"$SHIM_DIR/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${UNAME_OUT:-Darwin}"
EOF
chmod +x "$SHIM_DIR/uname"

cat >"$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"

SMOKE_UID="$(id -u)"
TEST_LABEL="ai.agent-bridge.daemon"
TEST_PLIST="$SMOKE_TMP_ROOT/${TEST_LABEL}.plist"
printf '<plist/>\n' >"$TEST_PLIST"

export TARGET_ROOT="$SMOKE_TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$TARGET_ROOT/state"
mkdir -p "$TARGET_ROOT/state/upgrade"
cat >"$TARGET_ROOT/state/launchagent.config" <<EOF
BRIDGE_LAUNCHAGENT_LABEL=$TEST_LABEL
BRIDGE_LAUNCHAGENT_PLIST=$TEST_PLIST
EOF
MARKER_FILE="$TARGET_ROOT/state/upgrade/daemon-quiesce.intent"

reset_shim_state() {
  : >"$LAUNCHCTL_LOG"
  : >"$SYSTEMCTL_LOG"
  printf '0' >"$JOB_LOADED_FILE"
  printf '0' >"$PRINT_COUNTDOWN_FILE"
  : >"$BOOTSTRAP_FAIL_N_FILE"
  : >"$BOOTSTRAP_ERR_FILE"
  printf '0' >"$BOOTSTRAP_COUNT_FILE"
  printf '0' >"$SVC_ACTIVE_RC_FILE"
  printf '0' >"$TIMER_ACTIVE_RC_FILE"
}

seed_marker() {
  # platform = $1 (launchd|systemd), target = $2
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_PLATFORM=$1
BRIDGE_QUIESCE_TARGET=$2
EOF
}

# Run the #2210 no-restart branch (or a mutated branch) with the live helpers +
# marker harness sourced and the shims on PATH. Drives _UPGRADE_DAEMON_*_MANAGED
# via env so we exercise the real gate. Echoes the resolved load-state so the
# caller can assert; the launchctl/systemctl logs + marker file are inspected
# afterward.
run_branch() {
  local branch_file="$1" launchd_managed="$2" systemd_managed="$3"
  PATH="$SHIM_DIR:$PATH" \
  UNAME_OUT="Darwin" \
  BRIDGE_UPGRADE_QUIESCE_MARKER_FILE="$MARKER_FILE" \
  _UPGRADE_DAEMON_LAUNCHD_MANAGED="$launchd_managed" \
  _UPGRADE_DAEMON_SYSTEMD_MANAGED="$systemd_managed" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$HELPERS'
    _bridge_daemon_launchd_label() { printf '%s' '$TEST_LABEL'; }
    _BRIDGE_UPGRADE_LAUNCHD_LABEL='$TEST_LABEL'
    _BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE='unknown'
    _BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE='unknown'
    _UPGRADE_DAEMON_QUIESCE_MARKER_WRITTEN=1
    DRY_RUN=0
    # The extracted branch body is the self-contained \`if/else/fi\` that lives
    # INSIDE the live \`elif [[ \$DRY_RUN -eq 0 ]]; then ... fi\` arm (the BEGIN
    # marker sits after the \`elif ... then\`), so it runs verbatim here.
    $(cat "$branch_file")
    printf 'LAUNCHD_STATE=%s\n' \"\${_BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE:-unset}\"
    printf 'SYSTEMD_STATE=%s\n' \"\${_BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE:-unset}\"
  " 2>"$SMOKE_TMP_ROOT/stderr.txt"
}

# --- T1: launchd MANAGED, bootstrap succeeds → restore invoked + marker cleared
reset_shim_state
seed_marker launchd "$TEST_LABEL"
T1_OUT="$(run_branch "$BRANCH" 1 0)"
T1_LSTATE="$(printf '%s\n' "$T1_OUT" | sed -n 's/^LAUNCHD_STATE=//p')"
smoke_assert_eq "loaded" "$T1_LSTATE" "T1 launchd reconcile-induced bootout restored under --no-restart-daemon → load_state=loaded"
grep -q '^bootstrap ' "$LAUNCHCTL_LOG" \
  || smoke_fail "T1 FAIL: the launchd restore helper was NOT invoked (no bootstrap call) under --no-restart-daemon — daemon left booted-out. calls=$(cat "$LAUNCHCTL_LOG")"
[[ ! -f "$MARKER_FILE" ]] \
  || smoke_fail "T1 FAIL: quiesce marker was NOT cleared after a CONFIRMED launchd restore (still present: $(cat "$MARKER_FILE"))"
smoke_log "T1 PASS: launchd reconcile-induced bootout is restored under --no-restart-daemon (bootstrap invoked, loaded, marker cleared)"

# --- T2: systemd MANAGED, units active → restore invoked + marker cleared -----
reset_shim_state
seed_marker systemd agent-bridge-daemon.service
T2_OUT="$(BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$SMOKE_TMP_ROOT/run-user" \
  XDG_RUNTIME_DIR="$SMOKE_TMP_ROOT/run-user/$SMOKE_UID" \
  bash -c "mkdir -p '$SMOKE_TMP_ROOT/run-user/$SMOKE_UID'; exit 0"; \
  XDG_RUNTIME_DIR="$SMOKE_TMP_ROOT/run-user/$SMOKE_UID" run_branch "$BRANCH" 0 1)"
T2_SSTATE="$(printf '%s\n' "$T2_OUT" | sed -n 's/^SYSTEMD_STATE=//p')"
smoke_assert_eq "active" "$T2_SSTATE" "T2 systemd reconcile-induced bootout restored under --no-restart-daemon → load_state=active"
grep -q 'start agent-bridge-daemon.service' "$SYSTEMCTL_LOG" \
  || smoke_fail "T2 FAIL: the systemd restore helper was NOT invoked (no service start) under --no-restart-daemon. calls=$(cat "$SYSTEMCTL_LOG")"
[[ ! -f "$MARKER_FILE" ]] \
  || smoke_fail "T2 FAIL: quiesce marker was NOT cleared after a CONFIRMED systemd restore (still present: $(cat "$MARKER_FILE"))"
smoke_log "T2 PASS: systemd reconcile-induced bootout is restored under --no-restart-daemon (service start invoked, active, marker cleared)"

# --- T3: launchd MANAGED, bootstrap never loads → WARN + marker KEPT ----------
reset_shim_state
seed_marker launchd "$TEST_LABEL"
printf '99' >"$BOOTSTRAP_FAIL_N_FILE"        # every bootstrap fails → never loads
printf 'Could not bootstrap: 5: Input/output error' >"$BOOTSTRAP_ERR_FILE"
T3_OUT="$(run_branch "$BRANCH" 1 0)"
T3_LSTATE="$(printf '%s\n' "$T3_OUT" | sed -n 's/^LAUNCHD_STATE=//p')"
T3_STDERR="$(cat "$SMOKE_TMP_ROOT/stderr.txt")"
smoke_assert_eq "not_loaded" "$T3_LSTATE" "T3 launchd restore that does NOT confirm recovery → load_state=not_loaded"
grep -q '^bootstrap ' "$LAUNCHCTL_LOG" \
  || smoke_fail "T3 FAIL: the launchd restore helper was NOT invoked even though _UPGRADE_DAEMON_LAUNCHD_MANAGED=1. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_assert_contains "$T3_STDERR" "did NOT confirm recovery" "T3 emits the loud non-swallowed unrecovered WARN (#2210 option 3)"
[[ -f "$MARKER_FILE" ]] \
  || smoke_fail "T3 FAIL: quiesce marker was CLEARED after an UNCONFIRMED restore — the liveness watcher loses its only recovery signal → silent-down (the exact #2055/#2064 regression)."
smoke_log "T3 PASS: an unconfirmed launchd restore emits a loud WARN and KEEPS the marker for the liveness watcher"

# --- NEG (★hard guard): no managed bootout this run → NO restore, marker clear -
reset_shim_state
# An operator-disabled job: a marker may be present (e.g. residue) but NEITHER
# _UPGRADE_DAEMON_*_MANAGED is set this run, so the upgrade must NOT resurrect it.
seed_marker launchd "$TEST_LABEL"
NEG_OUT="$(run_branch "$BRANCH" 0 0)"
NEG_LSTATE="$(printf '%s\n' "$NEG_OUT" | sed -n 's/^LAUNCHD_STATE=//p')"
smoke_assert_eq "unknown" "$NEG_LSTATE" "NEG no reconcile-induced bootout this run → restore helper never ran (load_state stays unknown)"
if grep -qE '^(bootstrap|enable|kickstart) ' "$LAUNCHCTL_LOG"; then
  smoke_fail "NEG FAIL (★HARD GUARD VIOLATED): an upgrade RESTORED a daemon job that was NOT booted out by THIS run's reconcile (_UPGRADE_DAEMON_*_MANAGED both 0) — an operator-disabled job would be silently resurrected. calls=$(cat "$LAUNCHCTL_LOG")"
fi
grep -q 'start agent-bridge-daemon.service' "$SYSTEMCTL_LOG" 2>/dev/null \
  && smoke_fail "NEG FAIL (★HARD GUARD VIOLATED): systemd restore ran with no managed bootout this run. calls=$(cat "$SYSTEMCTL_LOG")"
[[ ! -f "$MARKER_FILE" ]] \
  || smoke_fail "NEG FAIL: the (case-b) no-managed-bootout branch did not clear the marker (still present: $(cat "$MARKER_FILE"))"
smoke_log "NEG PASS (★hard guard): a job NOT booted out by this run's reconcile is NEVER restored; the marker is cleared (case b)"

# --- MUTATION: revert the fix (clear-only branch) ⇒ silent-down, smoke catches -
# Synthesize the PRE-FIX branch body (the regression): clear the marker, no
# restore. Run T1's harness against it and assert the regression IS observable —
# the restore is not invoked, the job stays not loaded, and the marker is cleared.
MUT_BRANCH="$SMOKE_TMP_ROOT/2210-branch-mutated.sh"
cat >"$MUT_BRANCH" <<'EOF'
  # PRE-FIX #2055 behavior: clear the marker, never restore (the bug).
  if declare -F _bridge_upgrade_clear_quiesce_marker >/dev/null 2>&1; then
    _bridge_upgrade_clear_quiesce_marker
  fi
EOF
reset_shim_state
seed_marker launchd "$TEST_LABEL"
MUT_OUT="$(run_branch "$MUT_BRANCH" 1 0)"
MUT_LSTATE="$(printf '%s\n' "$MUT_OUT" | sed -n 's/^LAUNCHD_STATE=//p')"
# The mutated branch must demonstrate the regression we fixed: no restore call,
# job left not loaded (load-state never advanced past 'unknown'), marker cleared.
if grep -q '^bootstrap ' "$LAUNCHCTL_LOG"; then
  smoke_fail "MUTATION HARNESS BROKEN: the pre-fix clear-only branch somehow invoked the launchd restore — the mutation is not actually exercising the regression. calls=$(cat "$LAUNCHCTL_LOG")"
fi
smoke_assert_eq "unknown" "$MUT_LSTATE" "MUTATION: pre-fix branch never restores → load_state stays unknown (daemon left booted-out)"
[[ ! -f "$MARKER_FILE" ]] \
  || smoke_fail "MUTATION HARNESS BROKEN: pre-fix branch should clear the marker unconditionally."
smoke_log "MUTATION PASS: the pre-fix clear-only branch leaves the launchd daemon NOT restored + the marker cleared (silent-down) — the live fix's T1/T3 assertions (bootstrap invoked, marker kept-or-cleared on load-state) would FAIL against it. Reverting the fix ⇒ this smoke fails."

smoke_log "all #2210 --no-restart-daemon reconcile-restore tests PASS"
