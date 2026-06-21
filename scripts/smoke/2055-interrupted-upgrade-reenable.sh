#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2055-interrupted-upgrade-reenable.sh — Issue #2055.
#
# #2040 hardened the upgrade RESTORE side and added a standing liveness watcher
# that re-bootstraps an enabled-but-unloaded daemon, but it FAIL-CLOSED skips a
# *disabled* job (★ never fight an operator `agb daemon stop`). The gap (#2055):
# an upgrade KILLED between its quiesce-disable and its restore-enable leaves the
# launchd job DISABLED — indistinguishable from an operator stop, so the watcher
# correctly-but-unhelpfully skips it and the daemon stays silently down.
#
# The fix brackets the upgrade quiesce window with a DURABLE intent marker
# (state/upgrade/daemon-quiesce.intent) recording the upgrade pid. The marker —
# present with a DEAD upgrade pid — is the discriminator the watcher lacked:
#   - marker + dead upgrade pid  -> interrupted upgrade  -> re-enable + recover.
#   - marker + LIVE upgrade pid  -> upgrade in flight     -> defer (do not race).
#   - NO marker + disabled        -> operator stop        -> stay down (#2040
#                                                            contract preserved).
#
# This smoke runs the LIVE scripts/bridge-daemon-liveness.sh end-to-end with a
# stale heartbeat, a dead daemon pid, scripted launchctl/systemctl shims, and the
# various marker states, asserting on the audit events + the launchctl calls.
#
#   I1 — launchd DISABLED + marker (dead upgrade pid) → RE-ENABLE + recover
#        (rebootstrap_interrupted_upgrade + launchctl enable + bootstrap;
#        NOT skip_disabled, NOT skip_not_running).
#   I2 — ★launchd DISABLED + NO marker → SKIP (skip_disabled; NO enable/bootstrap)
#        — the #2040 operator-stop fail-closed contract is NOT regressed.
#   I3 — launchd DISABLED + marker but LIVE upgrade pid → DEFER as operator-stop
#        (skip_disabled; NO enable/bootstrap) — never race an in-flight upgrade.
#   I4 — launchd DISABLED + marker (dead pid) but print-disabled UNREADABLE →
#        STILL recover (the marker is independent proof; #2040's fail-closed-on-
#        unknown is overridden ONLY by a valid interrupted-upgrade marker).
#   S1 — ★systemd DISABLED + marker → STILL SKIP (the systemd quiesce only stops,
#        never disables — a disabled systemd unit is always an operator action).
#   U1 — UPGRADE-SIDE: write_quiesce_marker creates an attributable marker;
#        clear_quiesce_marker removes it (a clean lifecycle leaves no residue —
#        the stale-marker hole that would otherwise re-enable a later operator
#        stop is closed).
#   U2 — UPGRADE-SIDE: reenable_on_abort re-enables the launchd job + consumes the
#        marker (the catchable-abort self-heal layer).
#   U3 — UPGRADE-SIDE: reenable_on_abort with no marker → clean no-op.
#   U4 — EXIT-HANDLER (REAL): an abort with a marker outstanding (genuine
#        interrupted upgrade) → re-enable + consume the marker (self-heal fires).
#   U5 — ★EXIT-HANDLER (REAL): an abort with NO marker (a deliberate reconcile
#        failure already cleared it, or no quiesce ran) → NO re-enable. The codex
#        r2 BLOCKER guard — a deliberate stop must never be re-enabled.
#   R1 — ★RECONCILE: rc=2 (legacy no-op) PROCEEDS under set -e — proves the
#        `|| _reconcile_rc=$?` errexit-disarm makes the fail-closed `case`
#        reachable so a benign no-op is NOT wrongly failed-closed (codex r2 BLOCKER).
#   R2 — RECONCILE: rc=3 (refusal) → the fail-closed arm clears the marker + exit 1
#        (daemon stays STOPPED — #1820 intact, the discriminator stays correct).
#   M1 — MUTATION: neuter the interrupted_upgrade_quiesce discriminator → the
#        I1 interrupted disable falls back to skip_disabled (proves the new
#        discriminator is load-bearing — the test is non-vacuous).

set -uo pipefail
SMOKE_NAME="2055-interrupted-upgrade-reenable"
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
LIVENESS_SRC="$REPO_ROOT/scripts/bridge-daemon-liveness.sh"
UPGRADE_SRC="$REPO_ROOT/bridge-upgrade.sh"
smoke_assert_file_exists "$LIVENESS_SRC" "bridge-daemon-liveness.sh source present"
smoke_assert_file_exists "$UPGRADE_SRC" "bridge-upgrade.sh source present"
grep -q 'interrupted_upgrade_quiesce' "$LIVENESS_SRC" \
  || smoke_fail "#2055 interrupted-upgrade discriminator not present in $LIVENESS_SRC"
grep -q '_bridge_upgrade_write_quiesce_marker' "$UPGRADE_SRC" \
  || smoke_fail "#2055 quiesce-marker writer not present in $UPGRADE_SRC"
grep -q '_bridge_upgrade_reenable_on_abort' "$UPGRADE_SRC" \
  || smoke_fail "#2055 EXIT-handler abort re-enable not present in $UPGRADE_SRC"

# Isolated runtime root (NEVER the operator's live install — #1860 guard).
RUN_ROOT="$SMOKE_TMP_ROOT/run"
STATE_DIR="$RUN_ROOT/state"
LOG_DIR="$RUN_ROOT/logs"
mkdir -p "$STATE_DIR/upgrade" "$LOG_DIR"
HEARTBEAT_FILE="$STATE_DIR/daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
COOLDOWN_FILE="$STATE_DIR/daemon-liveness-cooldown.ts"
AUDIT_LOG="$LOG_DIR/audit.jsonl"
CONFIG_FILE="$STATE_DIR/launchagent.config"
MARKER_FILE="$STATE_DIR/upgrade/daemon-quiesce.intent"

TEST_LABEL="ai.agent-bridge.daemon"
TEST_PLIST="$SMOKE_TMP_ROOT/${TEST_LABEL}.plist"
printf '<plist/>\n' >"$TEST_PLIST"
cat >"$CONFIG_FILE" <<EOF
BRIDGE_LAUNCHAGENT_LABEL=$TEST_LABEL
BRIDGE_LAUNCHAGENT_PLIST=$TEST_PLIST
EOF

SHIM_DIR="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SHIM_DIR"
LAUNCHCTL_LOG="$SMOKE_TMP_ROOT/launchctl-calls.log"
SYSTEMCTL_LOG="$SMOKE_TMP_ROOT/systemctl-calls.log"

# Scripted launchctl shim (mirrors the #2040 smoke):
#   PRINT_RC_FILE        — `launchctl print` rc (0=loaded, 1=not). A successful
#                          bootstrap flips it to 0.
#   DISABLED_RC_FILE     — `print-disabled` emits enabled/disabled; 2 => command
#                          FAILS (unknown). `launchctl enable` flips it to 0.
#   BOOTSTRAP_LOADS_FILE — when 1, a successful bootstrap loads the job.
PRINT_RC_FILE="$SMOKE_TMP_ROOT/print-rc"
DISABLED_RC_FILE="$SMOKE_TMP_ROOT/disabled-rc"
BOOTSTRAP_LOADS_FILE="$SMOKE_TMP_ROOT/bootstrap-loads"
cat >"$SHIM_DIR/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LAUNCHCTL_LOG"
case "\${1:-}" in
  print)
    exit "\$(cat "$PRINT_RC_FILE" 2>/dev/null || printf 1)"
    ;;
  print-disabled)
    drc="\$(cat "$DISABLED_RC_FILE" 2>/dev/null || printf 0)"
    case "\$drc" in
      1) printf '\t"%s" => disabled\n' "$TEST_LABEL"; exit 0 ;;  # DISABLED
      2) exit 1 ;;                                                # command FAILS (unknown)
      *) printf '\t"%s" => enabled\n' "$TEST_LABEL"; exit 0 ;;   # enabled
    esac
    ;;
  enable)
    # A real \`launchctl enable\` clears the disabled override → print-disabled
    # then reports enabled. Reflect that so the fall-through recovery sees an
    # enabled job.
    printf '0' >"$DISABLED_RC_FILE"
    exit 0
    ;;
  bootstrap)
    loads="\$(cat "$BOOTSTRAP_LOADS_FILE" 2>/dev/null || printf 1)"
    [[ "\$loads" == "1" ]] && printf '0' >"$PRINT_RC_FILE"
    exit 0
    ;;
  kickstart) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/launchctl"

# Scripted systemctl shim (mirrors the #2040 smoke).
SVC_ENABLED_FILE="$SMOKE_TMP_ROOT/svc-enabled"
SVC_ACTIVE_RC_FILE="$SMOKE_TMP_ROOT/svc-active-rc"
SVC_START_ACTIVATES_FILE="$SMOKE_TMP_ROOT/svc-start-activates"
cat >"$SHIM_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYSTEMCTL_LOG"
case "\$*" in
  *is-enabled*)
    out="\$(cat "$SVC_ENABLED_FILE" 2>/dev/null || printf '')"
    [[ -n "\$out" ]] && printf '%s\n' "\$out"
    [[ -n "\$out" ]] && exit 0
    exit 1
    ;;
  *is-active*)
    exit "\$(cat "$SVC_ACTIVE_RC_FILE" 2>/dev/null || printf 1)"
    ;;
  *start*)
    act="\$(cat "$SVC_START_ACTIVATES_FILE" 2>/dev/null || printf 1)"
    [[ "\$act" == "1" ]] && printf '0' >"$SVC_ACTIVE_RC_FILE"
    exit 0
    ;;
  *reset-failed*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM_DIR/systemctl"

# uname shim so the OS gate is deterministic on any CI host.
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

# Establish a STALE heartbeat (older than threshold) + a DEAD daemon pid so
# main() reaches the not-running branch where the recovery lives.
seed_stale_no_pid() {
  : >"$AUDIT_LOG"
  : >"$LAUNCHCTL_LOG"
  : >"$SYSTEMCTL_LOG"
  rm -f "$COOLDOWN_FILE" "$MARKER_FILE"
  printf 'tick\n' >"$HEARTBEAT_FILE"
  local old=$(( $(date +%s) - 99999 ))
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old" +%Y%m%d%H%M.%S)" "$HEARTBEAT_FILE" 2>/dev/null || true
  printf '999999\n' >"$PID_FILE"
}

# Write a quiesce-intent marker for the given platform/target with the given
# upgrade pid (default: a guaranteed-dead pid). $3=pid override.
write_marker() {
  local platform="$1" target="$2" pid="${3:-999998}"
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_UPGRADE_PID=$pid
BRIDGE_QUIESCE_PLATFORM=$platform
BRIDGE_QUIESCE_TARGET=$target
BRIDGE_QUIESCE_TS=2026-01-01T00:00:00Z
BRIDGE_QUIESCE_VERSION=test
EOF
}

run_liveness() {
  local uname_out="${1:-Darwin}"
  local src="${2:-$LIVENESS_SRC}"
  PATH="$SHIM_DIR:$PATH" \
  UNAME_OUT="$uname_out" \
  BRIDGE_STATE_DIR="$STATE_DIR" \
  BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
  BRIDGE_DAEMON_HEARTBEAT_FILE="$HEARTBEAT_FILE" \
  BRIDGE_DAEMON_PID_FILE="$PID_FILE" \
  BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE="$COOLDOWN_FILE" \
  BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS="600" \
  BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS="600" \
  BRIDGE_LAUNCHAGENT_CONFIG_FILE="$CONFIG_FILE" \
  BRIDGE_UPGRADE_QUIESCE_MARKER_FILE="$MARKER_FILE" \
  "$BRIDGE_BASH" "$src" >"$SMOKE_TMP_ROOT/liveness-stdout.txt" 2>"$SMOKE_TMP_ROOT/liveness-stderr.txt"
}

audit_has() { grep -q "\"action\": \"$1\"" "$AUDIT_LOG" 2>/dev/null; }
launchctl_called() { grep -qE "^$1( |\$)" "$LAUNCHCTL_LOG" 2>/dev/null; }
systemctl_called() { grep -qE "(^| )$1( |\$)" "$SYSTEMCTL_LOG" 2>/dev/null; }

# ── I1: launchd DISABLED + marker (dead pid) → RE-ENABLE + recover ────────────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '1' >"$DISABLED_RC_FILE"       # DISABLED
printf '1' >"$BOOTSTRAP_LOADS_FILE"   # bootstrap will load
write_marker launchd "$TEST_LABEL"    # interrupted-upgrade marker, dead pid
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_interrupted_upgrade || smoke_fail "I1 FAIL: no interrupted_upgrade audit. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable || smoke_fail "I1 FAIL: launchctl enable was not called. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "I1 FAIL: no rebootstrap_success after re-enable. audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap || smoke_fail "I1 FAIL: bootstrap not called after re-enable. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_skip_disabled && smoke_fail "I1 FAIL: must NOT skip_disabled on an interrupted-upgrade marker. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_skip_not_running && smoke_fail "I1 FAIL: must NOT fall through to skip_not_running. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "I1 FAIL: marker must be consumed (single-latch). still present=$MARKER_FILE"
smoke_log "I1 PASS: launchd disabled + interrupted-upgrade marker → re-enable + recover (marker consumed)"

# ── I2: ★launchd DISABLED + NO marker → SKIP (operator-stop contract intact) ──
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"       # DISABLED, no marker
printf '1' >"$BOOTSTRAP_LOADS_FILE"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "I2 FAIL: no skip_disabled audit. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "I2 FAIL: must NOT enable a disabled job with no marker. calls=$(cat "$LAUNCHCTL_LOG")"
launchctl_called bootstrap && smoke_fail "I2 FAIL: must NOT bootstrap a disabled job with no marker. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "I2 FAIL: no marker must NOT be treated as interrupted upgrade. audit=$(cat "$AUDIT_LOG")"
smoke_log "I2 PASS: launchd disabled + NO marker → SKIP (operator stop respected; #2040 contract intact)"

# ── I3: launchd DISABLED + marker but LIVE upgrade pid → DEFER (don't race) ───
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL" "$$"   # LIVE pid (this smoke process)
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "I3 FAIL: a live-upgrade marker must defer as skip_disabled. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "I3 FAIL: must NOT enable while an upgrade pid is alive. calls=$(cat "$LAUNCHCTL_LOG")"
launchctl_called bootstrap && smoke_fail "I3 FAIL: must NOT bootstrap while an upgrade pid is alive. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "I3 FAIL: a LIVE upgrade pid is not an interrupted upgrade. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "I3 FAIL: marker must be PRESERVED while the upgrade is in flight. missing=$MARKER_FILE"
smoke_log "I3 PASS: launchd disabled + LIVE-upgrade marker → DEFER as skip_disabled (no race, marker preserved)"

# ── I4: launchd DISABLED + marker (dead pid) but print-disabled UNREADABLE → recover
# The marker is independent proof; #2040's fail-closed-on-unknown is overridden
# ONLY by a valid interrupted-upgrade marker.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '2' >"$DISABLED_RC_FILE"       # print-disabled FAILS (unknown)
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_interrupted_upgrade || smoke_fail "I4 FAIL: a valid marker must override fail-closed-on-unknown. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable || smoke_fail "I4 FAIL: must re-enable on a valid marker even when print-disabled is unknown. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "I4 FAIL: no rebootstrap_success. audit=$(cat "$AUDIT_LOG")"
smoke_log "I4 PASS: launchd disabled + unreadable print-disabled but valid marker → recover (marker is independent proof)"

# ── S1: ★systemd DISABLED + marker → STILL SKIP (systemd quiesce only stops) ──
seed_stale_no_pid
printf 'disabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"
write_marker systemd agent-bridge-daemon.service
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "S1 FAIL: a disabled systemd unit must STILL skip (no marker override on systemd). audit=$(cat "$AUDIT_LOG")"
systemctl_called start && smoke_fail "S1 FAIL: must NOT start a disabled systemd unit even with a marker. calls=$(cat "$SYSTEMCTL_LOG")"
smoke_log "S1 PASS: systemd disabled + marker → STILL SKIP (systemd quiesce stops not disables; disabled=operator action)"

# ── U-series: upgrade-side marker lifecycle (write / clear / abort re-enable) ──
# Extract the #2055 marker helper bodies verbatim from the live bridge-upgrade.sh
# so the unit tests never drift from the implementation. Source them in isolation
# with a minimal harness (TARGET_ROOT/BRIDGE_STATE_DIR + the launchctl shim).
U_HELPERS="$SMOKE_TMP_ROOT/2055-marker-helpers.sh"
awk '/^# BEGIN: Issue #2055 durable quiesce-intent/{f=1} f{print} /^# END: Issue #2055 durable quiesce-intent/{f=0}' \
  "$UPGRADE_SRC" >"$U_HELPERS"
grep -q '_bridge_upgrade_write_quiesce_marker()' "$U_HELPERS" \
  || smoke_fail "could not extract the #2055 marker helpers from $UPGRADE_SRC"
grep -q '_bridge_upgrade_clear_quiesce_marker()' "$U_HELPERS" \
  || smoke_fail "could not extract the #2055 clear helper from $UPGRADE_SRC"
grep -q '_bridge_upgrade_reenable_on_abort()' "$U_HELPERS" \
  || smoke_fail "could not extract the #2055 abort-reenable helper from $UPGRADE_SRC"

U_HOME="$SMOKE_TMP_ROOT/u-home"
U_STATE="$U_HOME/state"
U_MARKER="$U_STATE/upgrade/daemon-quiesce.intent"
mkdir -p "$U_STATE"

# Run an extracted-helper snippet with the marker harness + launchctl shim.
run_marker_helper() {
  local snippet="$1"
  : >"$LAUNCHCTL_LOG"
  PATH="$SHIM_DIR:$PATH" \
  TARGET_ROOT="$U_HOME" \
  BRIDGE_STATE_DIR="$U_STATE" \
  SOURCE_VERSION="u-test" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$U_HELPERS'
    $snippet
  " >"$SMOKE_TMP_ROOT/u-stdout.txt" 2>"$SMOKE_TMP_ROOT/u-stderr.txt"
}

# U1 — write then clear: a clean lifecycle leaves NO marker behind.
rm -f "$U_MARKER"
run_marker_helper '_bridge_upgrade_write_quiesce_marker launchd ai.agent-bridge.daemon'
[[ -f "$U_MARKER" ]] || smoke_fail "U1 FAIL: write_quiesce_marker did not create the marker at $U_MARKER"
grep -q 'BRIDGE_QUIESCE_PLATFORM=launchd' "$U_MARKER" || smoke_fail "U1 FAIL: marker missing platform. body=$(cat "$U_MARKER")"
grep -qE 'BRIDGE_QUIESCE_UPGRADE_PID=[0-9]+' "$U_MARKER" || smoke_fail "U1 FAIL: marker missing numeric upgrade pid. body=$(cat "$U_MARKER")"
run_marker_helper '_bridge_upgrade_clear_quiesce_marker'
[[ -f "$U_MARKER" ]] && smoke_fail "U1 FAIL: clear_quiesce_marker left the marker behind"
smoke_log "U1 PASS: write_quiesce_marker creates an attributable marker; clear_quiesce_marker removes it (clean lifecycle = no residue)"

# U2 — abort re-enable: with a marker outstanding (flag set + file present), the
# abort helper re-enables the launchd job and CONSUMES the marker.
rm -f "$U_MARKER"
run_marker_helper '
  _bridge_upgrade_write_quiesce_marker launchd ai.agent-bridge.daemon
  _bridge_upgrade_reenable_on_abort
'
launchctl_called enable || smoke_fail "U2 FAIL: abort re-enable did not call launchctl enable. calls=$(cat "$LAUNCHCTL_LOG")"
[[ -f "$U_MARKER" ]] && smoke_fail "U2 FAIL: abort re-enable left the marker behind (must consume it)"
smoke_log "U2 PASS: reenable_on_abort re-enables the launchd job + consumes the marker (catchable-abort self-heal)"

# U3 — no marker ⇒ abort re-enable is a clean no-op (never enables a job that was
# never quiesced — e.g. a pre-quiesce early abort).
rm -f "$U_MARKER"
run_marker_helper '_bridge_upgrade_reenable_on_abort'
launchctl_called enable && smoke_fail "U3 FAIL: abort re-enable must be a no-op with no outstanding marker. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "U3 PASS: reenable_on_abort with no marker → clean no-op (no spurious enable on a pre-quiesce abort)"

# U4/U5 — EXIT-handler abort gating against the REAL _bridge_upgrade_exit_handler.
# Extract the actual handler verbatim and drive it with a non-zero abort rc. The
# declare -F guards make the lock-release / JSON-emit calls no-ops in isolation.
# The handler re-enables ONLY when a marker is outstanding (a genuine interrupted
# upgrade); a deliberate reconcile failure already cleared the marker via the
# fail-closed `case *)` arm (see R-series below), so it reaches the handler with
# NO marker and does NOT re-enable.
EXIT_HANDLER="$SMOKE_TMP_ROOT/2055-exit-handler.sh"
awk '/^_bridge_upgrade_exit_handler\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPGRADE_SRC" >"$EXIT_HANDLER"
grep -q '_bridge_upgrade_reenable_on_abort' "$EXIT_HANDLER" \
  || smoke_fail "could not extract the #2055 abort-reenable call from the EXIT handler in $UPGRADE_SRC"
grep -q '_UPGRADE_RECONCILE_FAILCLOSED_PENDING' "$EXIT_HANDLER" \
  && smoke_fail "the dropped fail-closed sentinel still appears in the EXIT handler (stale design)"

run_exit_handler() {
  local seed_marker="$1"
  : >"$LAUNCHCTL_LOG"
  PATH="$SHIM_DIR:$PATH" \
  TARGET_ROOT="$U_HOME" \
  BRIDGE_STATE_DIR="$U_STATE" \
  SOURCE_VERSION="u-test" \
  SEED_MARKER="$seed_marker" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    JSON=0
    _BRIDGE_UPGRADE_LOCK_TOKEN=''
    _UPGRADE_DAEMON_QUIESCE_MARKER_WRITTEN=0
    source '$U_HELPERS'
    source '$EXIT_HANDLER'
    if [[ \"\${SEED_MARKER}\" == 1 ]]; then
      # An outstanding launchd marker (a quiesce happened, restore did not =
      # genuine interrupted upgrade). write_ sets the in-process flag too.
      _bridge_upgrade_write_quiesce_marker launchd ai.agent-bridge.daemon
    fi
    # Drive the handler with a non-zero abort status (a crash/signal rc).
    ( exit 3 ); _bridge_upgrade_exit_handler
  " >"$SMOKE_TMP_ROOT/u-stdout.txt" 2>"$SMOKE_TMP_ROOT/u-stderr.txt"
}

# U4 — marker outstanding (genuine interrupted upgrade): re-enable FIRES + marker consumed.
rm -f "$U_MARKER"
run_exit_handler 1
launchctl_called enable || smoke_fail "U4 FAIL: a genuine interrupted-upgrade abort (marker outstanding) MUST re-enable the daemon. calls=$(cat "$LAUNCHCTL_LOG")"
[[ -f "$U_MARKER" ]] && smoke_fail "U4 FAIL: the abort re-enable must consume the marker. still present=$U_MARKER"
smoke_log "U4 PASS: EXIT handler on interrupted-upgrade abort (marker outstanding) → re-enable + marker consumed (self-heal fires)"

# U5 — NO marker (deliberate reconcile failure already cleared it, OR no quiesce):
# the EXIT handler must NOT re-enable. This is the codex r2 BLOCKER guard — a
# deliberate stop must never be re-enabled by the abort path.
rm -f "$U_MARKER"
run_exit_handler 0
launchctl_called enable && smoke_fail "U5 FAIL (BLOCKER): the EXIT handler re-enabled the daemon with NO outstanding marker (a deliberate stop must stay down). calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "U5 PASS: EXIT handler on abort with NO marker → NO re-enable (deliberate stop / non-quiesce abort stays down)"

# ── R-series: the reconcile errexit-disarm makes the fail-closed `case` reachable.
# Extract the LIVE reconcile dispatch lines from bridge-upgrade.sh and confirm the
# `|| _reconcile_rc=$?` idiom is present so a non-zero driver rc is CAPTURED (not
# set -e-aborted). Then drive the exact captured-rc flow with a stub driver to
# prove rc=2 PROCEEDS (the codex r2 BLOCKER: a benign no-op must NOT be treated as
# a fail-closed stop) and rc=3 reaches the marker-clearing fail-closed arm.
grep -q '|| _reconcile_rc=\$?' "$UPGRADE_SRC" \
  || smoke_fail "R FAIL (BLOCKER): the reconcile call lost its '|| _reconcile_rc=\$?' errexit-disarm — a non-zero rc would set -e-abort before the fail-closed case (rc=2 benign no-op would wrongly fail closed)."

# Faithful mini-harness of the captured-rc + case flow (mirrors bridge-upgrade.sh).
run_reconcile_case() {
  local driver_rc="$1"
  rm -f "$U_MARKER"
  : >"$LAUNCHCTL_LOG"
  PATH="$SHIM_DIR:$PATH" \
  TARGET_ROOT="$U_HOME" \
  BRIDGE_STATE_DIR="$U_STATE" \
  SOURCE_VERSION="u-test" \
  DRIVER_RC="$driver_rc" \
  "$BRIDGE_BASH" -c "
    set -euo pipefail
    source '$U_HELPERS'
    # Quiesce wrote a marker; the reconcile is about to run.
    _bridge_upgrade_write_quiesce_marker launchd ai.agent-bridge.daemon
    _reconcile_rc=0
    bash -c 'exit \${DRIVER_RC}' || _reconcile_rc=\$?
    case \"\$_reconcile_rc\" in
      0|2) printf 'PROCEED rc=%s\n' \"\$_reconcile_rc\" ;;
      *)   _bridge_upgrade_clear_quiesce_marker; printf 'FAILCLOSED rc=%s\n' \"\$_reconcile_rc\"; exit 1 ;;
    esac
  " >"$SMOKE_TMP_ROOT/r-stdout.txt" 2>"$SMOKE_TMP_ROOT/r-stderr.txt"
}

# R1 — rc=2 (legacy no-op) PROCEEDS (does NOT set -e-abort, does NOT fail closed,
# marker preserved for the restore to clear).
run_reconcile_case 2 || smoke_fail "R1 FAIL (BLOCKER): rc=2 set -e-aborted instead of proceeding. stderr=$(cat "$SMOKE_TMP_ROOT/r-stderr.txt")"
grep -q 'PROCEED rc=2' "$SMOKE_TMP_ROOT/r-stdout.txt" || smoke_fail "R1 FAIL: rc=2 did not reach the proceed arm. out=$(cat "$SMOKE_TMP_ROOT/r-stdout.txt")"
[[ -f "$U_MARKER" ]] || smoke_fail "R1 FAIL: rc=2 proceed must PRESERVE the marker for the restore to clear. missing=$U_MARKER"
smoke_log "R1 PASS: reconcile rc=2 (legacy no-op) PROCEEDS under set -e (errexit-disarm reachable; benign no-op not failed-closed)"

# R2 — rc=3 (refusal) reaches the fail-closed arm: clears the marker + exit 1.
run_reconcile_case 3 && smoke_fail "R2 FAIL: rc=3 must exit non-zero (fail closed)."
grep -q 'FAILCLOSED rc=3' "$SMOKE_TMP_ROOT/r-stdout.txt" || smoke_fail "R2 FAIL: rc=3 did not reach the fail-closed arm. out=$(cat "$SMOKE_TMP_ROOT/r-stdout.txt")"
[[ -f "$U_MARKER" ]] && smoke_fail "R2 FAIL: the fail-closed arm must CLEAR the marker (deliberate stop). still present=$U_MARKER"
smoke_log "R2 PASS: reconcile rc=3 (refusal) → fail-closed arm clears the marker + exit 1 (daemon stays STOPPED; #1820 intact)"

# ── M1: MUTATION — neuter the discriminator → interrupted disable stays down ──
# The mutated copy MUST live next to the real script in scripts/ so REPO_ROOT
# (resolved from SCRIPT_DIR/..) still finds bridge-audit.py — otherwise emit_audit
# silently no-ops and the test is vacuously green.
MUTATED_SRC="$REPO_ROOT/scripts/.2055-liveness-mutated.$$.sh"
mutated_cleanup() { rm -f "$MUTATED_SRC"; smoke_cleanup_temp_root; }
trap mutated_cleanup EXIT
# Force the discriminator to always say "not an interrupted upgrade".
sed 's/^interrupted_upgrade_quiesce() {/interrupted_upgrade_quiesce() { return 1 ; : OLD/' "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q 'interrupted_upgrade_quiesce() { return 1 ; : OLD' "$MUTATED_SRC" || smoke_fail "M1 FAIL: mutation did not neuter the discriminator"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"       # DISABLED
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL"    # marker present, but discriminator neutered
run_liveness Darwin "$MUTATED_SRC"
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "M1 FAIL (vacuous!): without the discriminator the interrupted disable did NOT fall back to skip_disabled. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "M1 FAIL: mutated watcher must NOT detect an interrupted upgrade. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "M1 FAIL: mutated watcher must NOT re-enable. calls=$(cat "$LAUNCHCTL_LOG")"
launchctl_called bootstrap && smoke_fail "M1 FAIL: mutated watcher must NOT bootstrap. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "M1 PASS: MUTATION proven — removing the discriminator leaves the interrupted disable down (the new branch is what recovers)"

smoke_log "all interrupted-upgrade daemon re-enable tests PASS (#2055)"
