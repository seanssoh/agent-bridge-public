#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2040-upgrade-restore-verify.sh — Issue #2040 Part A.
#
# The #655 launchd restore fired `enable; bootstrap >/dev/null 2>&1 || true;
# kickstart` with NO verification. The quiesce step's `bootout` is ASYNC on
# macOS, so a `bootstrap` that races ahead of launchd's teardown gets a transient
# error ("Boot-out already in progress" / "Operation now in progress" / EIO) that
# the `|| true` swallowed — leaving the job ENABLED-BUT-UNLOADED and the daemon
# permanently down (KeepAlive=true is moot with no loaded job). Part A:
#   - poll-until-not-loaded BEFORE bootstrap (defeat the async-bootout race),
#   - retry bootstrap on the transient races,
#   - capture launchctl stderr (no blanket >/dev/null 2>&1),
#   - VERIFY loaded post-bootstrap; on failure → loud non-swallowed WARN + exact
#     remediation, and record _BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE for the summary.
#   - systemd parity: capture stderr + verify is-active for both units.
#
# This smoke sources ONLY the #2040 + #655 + #1905 helper bodies from the LIVE
# bridge-upgrade.sh (extracted between the stable comment markers, so the test
# tracks the real implementation, not a copy), installs scripted launchctl /
# systemctl shims, and asserts the verification behavior directly.
#
#   T1 — async-bootout race: launchctl reports the job LOADED for the first 2
#        `print` polls then NOT-loaded → the restart helper WAITS (poll) before
#        bootstrap (defeats the race) and ends LOADED → load_state=loaded.
#   T2 — transient bootstrap error then success: bootstrap fails once with
#        "Boot-out already in progress", retried, second attempt loads →
#        load_state=loaded, the retry is visible.
#   T3 — permanent failure: bootstrap NEVER loads the job → load_state=not_loaded,
#        a loud WARN with the exact `launchctl bootstrap gui/<uid> <plist>`
#        remediation and the captured launchctl stderr is printed (NOT swallowed).
#   T4 — systemd restore: both units report is-active → load_state=active.
#   T5 — systemd restore failure: service is-active fails → load_state=inactive +
#        a loud WARN with the `systemctl --user start` remediation.

set -uo pipefail
SMOKE_NAME="2040-upgrade-restore-verify"
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

# Extract the #2040 + #655 launchd helpers and the #1905 systemd helpers verbatim
# from the live source so the smoke never drifts from the implementation.
HELPERS="$SMOKE_TMP_ROOT/2040-helpers.sh"
awk '
  /^# BEGIN: Issue #2040 launchd restore/{f=1}
  /^# BEGIN: Issue #655 launchd-aware/{f=1}
  /^# BEGIN: Issue #1905 systemd-aware/{f=1}
  f{print}
  /^# END: Issue #655 launchd-aware/{f=0}
  /^# END: Issue #1905 systemd-aware/{f=0}
' "$UPGRADE_SRC" >"$HELPERS"
grep -q '_bridge_upgrade_launchd_restart_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #2040/#655 launchd helpers from $UPGRADE_SRC"
grep -q '_bridge_upgrade_launchd_wait_unloaded()' "$HELPERS" \
  || smoke_fail "#2040 wait-unloaded helper not present — async-bootout poll missing"
grep -q '_bridge_upgrade_systemd_restart_daemon()' "$HELPERS" \
  || smoke_fail "could not extract the #1905 systemd restart helper from $UPGRADE_SRC"

SHIM_DIR="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SHIM_DIR"
LAUNCHCTL_LOG="$SMOKE_TMP_ROOT/launchctl-calls.log"
# The launchctl shim is SCRIPTED per-test via files the shim reads. The model:
#   JOB_LOADED_FILE        — the persistent loaded state (1=loaded, 0=not). A
#       successful `bootstrap` sets it to 1; `print` returns it (rc 0/1) once the
#       async-bootout window has closed.
#   PRINT_COUNTDOWN_FILE   — models the ASYNC-BOOTOUT window: while the counter
#       is > 0 (decrementing each `print`), the job still reports LOADED
#       regardless of JOB_LOADED — i.e. launchd is still tearing the booted-out
#       job down. This is exactly the race the poll-until-not-loaded defeats.
#   BOOTSTRAP_FAIL_N_FILE  — bootstrap fails (rc=1, prints BOOTSTRAP_ERR_FILE to
#       stderr) for the first N calls then succeeds. A successful bootstrap sets
#       JOB_LOADED=1.
JOB_LOADED_FILE="$SMOKE_TMP_ROOT/job-loaded"
PRINT_COUNTDOWN_FILE="$SMOKE_TMP_ROOT/print-loaded-countdown"
BOOTSTRAP_FAIL_N_FILE="$SMOKE_TMP_ROOT/bootstrap-fail-first-n"
BOOTSTRAP_ERR_FILE="$SMOKE_TMP_ROOT/bootstrap-err-msg"
BOOTSTRAP_COUNT_FILE="$SMOKE_TMP_ROOT/bootstrap-call-count"

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
      exit 0   # async-bootout window: still reports LOADED
    fi
    loaded=0; [[ -s "$JOB_LOADED_FILE" ]] && loaded="\$(cat "$JOB_LOADED_FILE")"
    [[ "\$loaded" == "1" ]] && exit 0
    exit 1     # NOT loaded
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
    printf '1' >"$JOB_LOADED_FILE"   # success → job is now loaded
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/launchctl"

cat >"$SHIM_DIR/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${UNAME_OUT:-Darwin}"
EOF
chmod +x "$SHIM_DIR/uname"

SMOKE_UID="$(id -u)"
TEST_LABEL="ai.agent-bridge.daemon"
TEST_PLIST="$SMOKE_TMP_ROOT/${TEST_LABEL}.plist"
printf '<plist/>\n' >"$TEST_PLIST"

export TARGET_ROOT="$SMOKE_TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$TARGET_ROOT/state"
mkdir -p "$TARGET_ROOT/state"
cat >"$TARGET_ROOT/state/launchagent.config" <<EOF
BRIDGE_LAUNCHAGENT_LABEL=$TEST_LABEL
BRIDGE_LAUNCHAGENT_PLIST=$TEST_PLIST
EOF

reset_shim_state() {
  : >"$LAUNCHCTL_LOG"
  printf '0' >"$JOB_LOADED_FILE"
  printf '0' >"$PRINT_COUNTDOWN_FILE"
  : >"$BOOTSTRAP_FAIL_N_FILE"
  : >"$BOOTSTRAP_ERR_FILE"
  printf '0' >"$BOOTSTRAP_COUNT_FILE"
}

# Run the launchd restart helper with the shims on PATH; capture stderr (where
# the WARN/remediation goes) and the resolved load_state. Sleeps in the helper
# (0.5s poll) are real but bounded; shorten via a `sleep` shim that no-ops.
cat >"$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"

run_launchd_restart() {
  PATH="$SHIM_DIR:$PATH" \
  UNAME_OUT="Darwin" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$HELPERS'
    _bridge_daemon_launchd_label() { printf '%s' '$TEST_LABEL'; }
    _BRIDGE_UPGRADE_LAUNCHD_LABEL='$TEST_LABEL'
    _bridge_upgrade_launchd_restart_daemon
    printf 'LOAD_STATE=%s\n' \"\$_BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE\"
  " 2>"$SMOKE_TMP_ROOT/stderr.txt"
}

# --- T1: async-bootout race — poll until not-loaded BEFORE bootstrap ----------
reset_shim_state
# print reports LOADED for 2 polls, then NOT loaded → wait_unloaded must spin
# at least once before bootstrap. bootstrap succeeds → loaded.
printf '2' >"$PRINT_COUNTDOWN_FILE"
T1_OUT="$(run_launchd_restart)"
T1_STATE="$(printf '%s\n' "$T1_OUT" | sed -n 's/^LOAD_STATE=//p')"
smoke_assert_eq "loaded" "$T1_STATE" "T1 async-bootout race resolves to load_state=loaded"
# Prove the poll ran: at least 2 `print` calls happened before the bootstrap
# (the countdown started at 2). bootstrap appears after the print polls.
T1_FIRST_BOOTSTRAP_LINE="$(grep -n '^bootstrap ' "$LAUNCHCTL_LOG" | head -n1 | cut -d: -f1)"
T1_PRINTS_BEFORE_BOOTSTRAP="$(head -n "$(( ${T1_FIRST_BOOTSTRAP_LINE:-1} - 1 ))" "$LAUNCHCTL_LOG" | grep -c '^print ')"
[[ "${T1_PRINTS_BEFORE_BOOTSTRAP:-0}" -ge 2 ]] \
  || smoke_fail "T1 FAIL: expected >=2 print polls before bootstrap (async-bootout race not defeated); calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "T1 PASS: poll-until-not-loaded runs before bootstrap (async-bootout race defeated), load_state=loaded"

# --- T2: transient bootstrap error then retry success -------------------------
reset_shim_state
printf '0' >"$PRINT_COUNTDOWN_FILE"
printf '1' >"$BOOTSTRAP_FAIL_N_FILE"          # first bootstrap fails
printf 'Boot-out already in progress' >"$BOOTSTRAP_ERR_FILE"
T2_OUT="$(run_launchd_restart)"
T2_STATE="$(printf '%s\n' "$T2_OUT" | sed -n 's/^LOAD_STATE=//p')"
smoke_assert_eq "loaded" "$T2_STATE" "T2 transient bootstrap error is retried then loads → load_state=loaded"
T2_BOOTSTRAPS="$(grep -c '^bootstrap ' "$LAUNCHCTL_LOG")"
[[ "$T2_BOOTSTRAPS" -ge 2 ]] \
  || smoke_fail "T2 FAIL: expected >=2 bootstrap attempts (transient retry); got $T2_BOOTSTRAPS. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "T2 PASS: transient bootstrap race is retried then loads (load_state=loaded, $T2_BOOTSTRAPS bootstrap attempts)"

# --- T3: permanent failure → load_state=not_loaded + loud remediation ---------
reset_shim_state
# JOB_LOADED stays 0 (every bootstrap fails) → print always reports not-loaded.
printf '99' >"$BOOTSTRAP_FAIL_N_FILE"         # every bootstrap fails
printf 'Could not bootstrap: 5: Input/output error' >"$BOOTSTRAP_ERR_FILE"
T3_OUT="$(run_launchd_restart)"
T3_STATE="$(printf '%s\n' "$T3_OUT" | sed -n 's/^LOAD_STATE=//p')"
T3_STDERR="$(cat "$SMOKE_TMP_ROOT/stderr.txt")"
smoke_assert_eq "not_loaded" "$T3_STATE" "T3 permanent bootstrap failure → load_state=not_loaded"
smoke_assert_contains "$T3_STDERR" "ENABLED-BUT-UNLOADED" "T3 emits the enabled-but-unloaded WARN (not swallowed)"
smoke_assert_contains "$T3_STDERR" "launchctl bootstrap gui/${SMOKE_UID}" "T3 WARN includes the exact remediation command"
smoke_assert_contains "$T3_STDERR" "Input/output error" "T3 WARN surfaces the captured launchctl stderr (not >/dev/null)"
smoke_log "T3 PASS: permanent failure → not_loaded + loud non-swallowed WARN with remediation + captured stderr"

# --- systemd parity (fake systemctl) -----------------------------------------
SYSTEMCTL_LOG="$SMOKE_TMP_ROOT/systemctl-calls.log"
SVC_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/svc-is-active-rc"
TIMER_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/timer-is-active-rc"
printf '0' >"$SVC_ACTIVE_RC_FILE"
printf '0' >"$TIMER_ACTIVE_RC_FILE"
RUNTIME_BASE_GOOD="$SMOKE_TMP_ROOT/run-user"
mkdir -p "$RUNTIME_BASE_GOOD/$SMOKE_UID"
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

run_systemd_restart() {
  PATH="$SHIM_DIR:$PATH" \
  BRIDGE_UPGRADE_SYSTEMD_RUNTIME_BASE="$RUNTIME_BASE_GOOD" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    unset XDG_RUNTIME_DIR
    source '$HELPERS'
    _bridge_upgrade_systemd_restart_daemon
    printf 'LOAD_STATE=%s\n' \"\$_BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE\"
  " 2>"$SMOKE_TMP_ROOT/systemd-stderr.txt"
}

# --- T4: systemd both units active → load_state=active ------------------------
: >"$SYSTEMCTL_LOG"
printf '0' >"$SVC_ACTIVE_RC_FILE"
printf '0' >"$TIMER_ACTIVE_RC_FILE"
T4_OUT="$(run_systemd_restart)"
T4_STATE="$(printf '%s\n' "$T4_OUT" | sed -n 's/^LOAD_STATE=//p')"
smoke_assert_eq "active" "$T4_STATE" "T4 systemd both units active → load_state=active"
grep -q 'is-active agent-bridge-daemon.service' "$SYSTEMCTL_LOG" \
  || smoke_fail "T4 FAIL: systemd restore did not VERIFY is-active for the service. calls=$(cat "$SYSTEMCTL_LOG")"
smoke_log "T4 PASS: systemd restore verifies is-active for both units → load_state=active"

# --- T5: systemd service inactive → load_state=inactive + loud remediation ----
: >"$SYSTEMCTL_LOG"
printf '1' >"$SVC_ACTIVE_RC_FILE"             # service NOT active after start
printf '0' >"$TIMER_ACTIVE_RC_FILE"
T5_OUT="$(run_systemd_restart)"
T5_STATE="$(printf '%s\n' "$T5_OUT" | sed -n 's/^LOAD_STATE=//p')"
T5_STDERR="$(cat "$SMOKE_TMP_ROOT/systemd-stderr.txt")"
smoke_assert_eq "inactive" "$T5_STATE" "T5 systemd service inactive after start → load_state=inactive"
smoke_assert_contains "$T5_STDERR" "did not become active" "T5 emits the inactive-service WARN (not swallowed)"
smoke_assert_contains "$T5_STDERR" "systemctl --user start agent-bridge-daemon.service" "T5 WARN includes the exact remediation command"
smoke_log "T5 PASS: systemd service inactive → load_state=inactive + loud WARN with remediation"

smoke_log "all upgrade-restore verification tests PASS (#2040 Part A)"
