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
#   F1 — ★#2064 Finding 1: launchd interrupted-upgrade marker but the re-enable
#        FAILS → the marker SURVIVES (KEEP) + rebootstrap_failed audited, no
#        success. The pre-#2064 eager clear-before-enable stranded the daemon.
#   F1b— control: same marker, re-enable SUCCEEDS → marker consumed (survival is
#        gated on failure, not always-keep).
#   F1c— ★codex r2: enable rc0 but print-disabled UNREADABLE on re-query (unknown)
#        AND bootstrap FAILS → marker SURVIVES (consume is deferred to a confirmed
#        LOAD, which never comes — an unknown re-query is not a verified re-enable).
#   F1d— control for F1c: same unknown re-query but bootstrap LOADS → deferred
#        consume fires (a confirmed load is the healthy signal).
#   F2 — ★#2064 Finding 2 (static): the systemd quiesce LEAVES the liveness timer
#        running (only the service is stopped) so a SIGKILL'd upgrade keeps an
#        invoker to observe the marker.
#   F2a— systemd enabled+inactive + LIVE-upgrade marker → DEFER (no start, marker
#        preserved) — the running timer must not race the #1820 fence.
#   F2b— ★the SIGKILL topology: systemd enabled+inactive + ORPHANED (dead-pid)
#        marker → the running timer REAPS it (reset-failed + start). The
#        uncatchable-interruption path the stopped timer could not cover.
#   F2c— control: systemd enabled+inactive + NO marker → still recovers (#2040
#        enabled+inactive contract not regressed by the defer guard).
#   F2d— Finding-1 parity on systemd: orphaned marker + the reap start does NOT
#        activate → rebootstrap_failed + the orphaned marker SURVIVES (a confirmed
#        reap is required to consume it).
#   F3 — ★#2064 r3 Finding 3 (TOOTH): the NORMAL restart-phase common cleanup clears
#        the quiesce marker ONLY on a CONFIRMED recovery (launchd LOAD_STATE=loaded /
#        systemd LOAD_STATE=active). A restart-phase restore that left the job
#        enabled-but-unloaded (LOAD_STATE=not_loaded) → the marker SURVIVES for the
#        liveness watcher (the unconditional-clear-after-unverified-restore hole).
#   F3b— control for F3: same path but LOAD_STATE=loaded → the marker is CLEARED
#        (the gate consumes on confirmed recovery, not always-keep). + a STATIC guard
#        that the source no longer unconditionally clears after the restart phase.
#   F4 — ★#2064 r3 Finding 4 (TOOTH): a marker whose recorded pid is a LIVE process
#        but whose START-IDENTITY does NOT match (the SIGKILL'd upgrade's pid was
#        REUSED by an unrelated long-lived process) → REAPED, not deferred forever.
#   F4b— ★#2064 r3 Finding 4 (age fallback): a marker with a LIVE pid + MATCHING-ish
#        (empty/legacy) identity but a TS older than the bounded ceiling → REAPED
#        (defense-in-depth: an over-age marker is an orphan even if the pid is live).
#   U7 — ★#2064 r3 codex catch: the REAL _bridge_upgrade_write_quiesce_marker records a
#        start-identity token that, even with the space-laden BSD `ps -o lstart=` form,
#        survives a `source` of the marker INTACT (non-empty + equal to a fresh
#        recompute). The pre-fix unquoted+spaced PSID parsed as `KEY=ps-lstart:Mon` +
#        a stray command → identity read back EMPTY → PID-reuse defense silently lost
#        on macOS/BSD. Proves the marker is round-trip-safe + the identity matches +
#        the recorded token carries no whitespace and no single-quote.
#   U8 — ★#2064 r3 codex round-2: a pathological/locale `ps -o lstart=` that emits a
#        SINGLE-QUOTE must be STRIPPED by the write-side allowlist (else the ' breaks
#        the single-quoted marker value → empty readback again). Shims `ps` to emit a
#        quote-bearing value, runs the REAL identity helper, asserts the token is
#        allowlist-clean AND round-trips through a single-quoted marker.
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
#   U6 — ★EXIT-HANDLER (REAL, codex r2): an abort with a marker outstanding but the
#        re-enable UNVERIFIED (job not loaded after bootstrap) → marker SURVIVES
#        (consume gated on a confirmed load, not on a not-disabled print-disabled).
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
# #2064 tooth F1: when this control file is `1`, a `launchctl enable` is REFUSED —
# it does NOT clear the disabled override, so print-disabled keeps reporting the
# job disabled. Models a launchd that rejects the re-enable (the Finding-1 failure
# the marker must survive). Default (absent/0) = enable succeeds (legacy shim).
ENABLE_FAILS_FILE="$SMOKE_TMP_ROOT/enable-fails"
# #2064 tooth F1c/F1d (codex r2): when `1`, a SUCCESSFUL `launchctl enable` (rc 0)
# leaves print-disabled UNREADABLE (drc=2 unknown) instead of flipping to enabled —
# models an enable that returned 0 but whose disabled-state cannot be verified. The
# watcher must then DEFER the marker consume to the post-bootstrap load-confirmation
# (consume only if the job loads; keep the marker if the bootstrap fails).
ENABLE_SETS_UNKNOWN_FILE="$SMOKE_TMP_ROOT/enable-sets-unknown"
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
    # enabled job — UNLESS the F1 tooth forces a refusal (override unchanged).
    if [[ "\$(cat "$ENABLE_FAILS_FILE" 2>/dev/null || printf 0)" == "1" ]]; then
      exit 1
    fi
    if [[ "\$(cat "$ENABLE_SETS_UNKNOWN_FILE" 2>/dev/null || printf 0)" == "1" ]]; then
      printf '2' >"$DISABLED_RC_FILE"   # enable rc 0 but print-disabled now UNREADABLE
    else
      printf '0' >"$DISABLED_RC_FILE"
    fi
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
  printf '0' >"$ENABLE_FAILS_FILE"          # #2064 F1: default = re-enable succeeds
  printf '0' >"$ENABLE_SETS_UNKNOWN_FILE"   # #2064 F1c/F1d: default = enable flips to enabled
  rm -f "$COOLDOWN_FILE" "$MARKER_FILE"
  printf 'tick\n' >"$HEARTBEAT_FILE"
  local old=$(( $(date +%s) - 99999 ))
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old" +%Y%m%d%H%M.%S)" "$HEARTBEAT_FILE" 2>/dev/null || true
  printf '999999\n' >"$PID_FILE"
}

# Write a quiesce-intent marker for the given platform/target with the given
# upgrade pid (default: a guaranteed-dead pid). $3=pid override. #2064 r3:
# $4=start-identity (BRIDGE_QUIESCE_UPGRADE_PSID) override — empty (default) models a
# legacy marker with no recorded identity (the watcher then falls back to the
# bare-pid defer); a non-matching token models a REUSED pid. $5=BRIDGE_QUIESCE_TS
# override — defaults to NOW (a fresh marker, so the bounded age fallback does NOT
# trip); pass an old ISO-8601 ts to model an over-age orphan.
write_marker() {
  local platform="$1" target="$2" pid="${3:-999998}"
  local psid="${4:-}"
  local ts="${5:-$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')}"
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_UPGRADE_PID=$pid
BRIDGE_QUIESCE_UPGRADE_PSID='$psid'
BRIDGE_QUIESCE_UPGRADE_UID=$(id -u 2>/dev/null || printf '%s' "${UID:-}")
BRIDGE_QUIESCE_PLATFORM=$platform
BRIDGE_QUIESCE_TARGET=$target
BRIDGE_QUIESCE_TS=$ts
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

# ── F1 (#2064 Finding 1): launchd interrupted-upgrade marker but the re-enable
# FAILS → the marker MUST SURVIVE (KEEP) so the next poll retries; a forced
# re-enable failure is audited rebootstrap_failed and does NOT reach
# rebootstrap_success. The pre-#2064 code cleared the marker BEFORE the
# `launchctl enable || true`, so a failed enable silently stranded the daemon.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '1' >"$DISABLED_RC_FILE"       # DISABLED
printf '1' >"$BOOTSTRAP_LOADS_FILE"
printf '1' >"$ENABLE_FAILS_FILE"      # ★ launchctl enable is REFUSED (override stays disabled)
write_marker launchd "$TEST_LABEL"    # interrupted-upgrade marker, dead pid
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_interrupted_upgrade || smoke_fail "F1 FAIL: the interrupted-upgrade branch must still fire (it just must not succeed). audit=$(cat "$AUDIT_LOG")"
launchctl_called enable || smoke_fail "F1 FAIL: re-enable must be ATTEMPTED. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_failed || smoke_fail "F1 FAIL: a re-enable that did not take must audit rebootstrap_failed. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_success && smoke_fail "F1 FAIL: a refused re-enable must NOT report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "F1 FAIL (BLOCKER): the quiesce marker MUST SURVIVE a failed re-enable (else the daemon is stranded with no discriminator for the next poll). missing=$MARKER_FILE"
smoke_log "F1 PASS: launchd interrupted-upgrade re-enable FAILS → marker SURVIVES + rebootstrap_failed audited (next poll retries; the #2055 strand-hole is closed)"

# F1b — control: with the SAME interrupted marker but the re-enable SUCCEEDS, the
# marker is consumed (proves F1's survival is gated on FAILURE, not always-keep).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
printf '0' >"$ENABLE_FAILS_FILE"      # enable succeeds
write_marker launchd "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_success || smoke_fail "F1b FAIL: a successful re-enable+bootstrap must report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "F1b FAIL: a CONFIRMED re-enable must consume the marker. still present=$MARKER_FILE"
smoke_log "F1b PASS: launchd interrupted-upgrade re-enable SUCCEEDS → marker consumed (survival is gated on failure)"

# F1c — ★codex r2: `launchctl enable` returns 0 but print-disabled is UNREADABLE on
# re-query (unknown), AND the subsequent BOOTSTRAP FAILS to load → the marker must
# SURVIVE. An unknown re-query is NOT a confirmed re-enable; the consume is deferred
# to the post-bootstrap load-confirmation, which here never comes. This is the exact
# hole codex flagged: clearing on an unverifiable print-disabled would strand the job.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"               # not loaded
printf '1' >"$DISABLED_RC_FILE"            # DISABLED initially
printf '0' >"$BOOTSTRAP_LOADS_FILE"        # ★ bootstrap does NOT load the job
printf '0' >"$ENABLE_FAILS_FILE"           # enable returns 0...
printf '1' >"$ENABLE_SETS_UNKNOWN_FILE"    # ★ ...but leaves print-disabled UNREADABLE
write_marker launchd "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_interrupted_upgrade || smoke_fail "F1c FAIL: the interrupted branch must still fire (marker = independent proof, proceed on unknown). audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap || smoke_fail "F1c FAIL: must still ATTEMPT bootstrap on an unknown re-query (recover, do not block). calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success && smoke_fail "F1c FAIL: a bootstrap that did not load must NOT report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "F1c FAIL (BLOCKER, codex r2): an UNVERIFIED re-enable (unknown re-query) + FAILED bootstrap must KEEP the marker. missing=$MARKER_FILE"
smoke_log "F1c PASS: enable rc0 but unknown re-query + bootstrap FAILS → marker SURVIVES (consume deferred to confirmed load; codex r2 hole closed)"

# F1d — control for F1c: SAME unknown re-query, but the bootstrap SUCCEEDS (loads
# the job) → the deferred consume fires (a confirmed LOAD is the healthy signal).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"        # ★ bootstrap loads the job
printf '0' >"$ENABLE_FAILS_FILE"
printf '1' >"$ENABLE_SETS_UNKNOWN_FILE"    # unknown re-query
write_marker launchd "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_success || smoke_fail "F1d FAIL: a confirmed bootstrap load must report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "F1d FAIL: a confirmed LOAD (even via unknown re-query) must consume the deferred marker. still present=$MARKER_FILE"
smoke_log "F1d PASS: enable rc0 + unknown re-query but bootstrap LOADS → deferred marker consumed (consume gated on confirmed load, not on the unknown re-query)"

# ── F2 (#2064 Finding 2): systemd SIGKILL/power-loss recovery via a RUNNING timer.
# The quiesce no longer stops the liveness timer; the watcher DEFERs while a LIVE
# upgrade holds the marker (no fence race) and REAPS an orphaned (dead-pid) marker
# left by a killed upgrade. Static guard first: the upgrade quiesce must NOT stop
# the liveness timer (that was the topology hole — nothing left to observe the
# marker after a SIGKILL).
QUIESCE_FN="$SMOKE_TMP_ROOT/2064-systemd-quiesce.sh"
awk '/^_bridge_upgrade_systemd_quiesce_daemon\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPGRADE_SRC" >"$QUIESCE_FN"
grep -q 'systemctl --user stop agent-bridge-daemon.service' "$QUIESCE_FN" \
  || smoke_fail "F2 FAIL: the systemd quiesce must still stop the SERVICE (the #1820 fence needs it down)."
grep -E 'stop[[:space:]]+agent-bridge-daemon-liveness\.timer' "$QUIESCE_FN" >/dev/null 2>&1 \
  && smoke_fail "F2 FAIL (BLOCKER): the systemd quiesce STILL stops the liveness timer — a SIGKILL'd upgrade then has no invoker to observe the marker (#2064 regression)."
smoke_log "F2 PASS (static): systemd quiesce stops the service but LEAVES the liveness timer running (a SIGKILL'd upgrade keeps an invoker)"

# F2a — systemd enabled+inactive + LIVE-upgrade marker → DEFER (no start, marker
# preserved). This is the running-timer firing DURING a legitimate quiesce window;
# it must not race the #1820 fence.
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"          # inactive (quiesce stopped the service)
printf '1' >"$SVC_START_ACTIVATES_FILE"
write_marker systemd agent-bridge-daemon.service "$$"   # LIVE upgrade pid (this smoke)
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_live_upgrade || smoke_fail "F2a FAIL: a live-upgrade marker must DEFER the systemd recovery. audit=$(cat "$AUDIT_LOG")"
systemctl_called start && smoke_fail "F2a FAIL (BLOCKER): must NOT start the service while a live upgrade holds the marker (would race the #1820 fence). calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success && smoke_fail "F2a FAIL: a deferred recovery must not report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "F2a FAIL: the marker must be PRESERVED while the upgrade is in flight. missing=$MARKER_FILE"
smoke_log "F2a PASS: systemd enabled+inactive + LIVE-upgrade marker → DEFER (no start, marker preserved; no fence race)"

# F2b — ★the SIGKILL topology: systemd enabled+inactive + ORPHANED (dead-pid)
# marker → the still-running timer REAPS it (reset-failed + start). The upgrade was
# killed between quiesce and restore; nothing else can recover the daemon.
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"          # inactive
printf '1' >"$SVC_START_ACTIVATES_FILE"    # start activates it
write_marker systemd agent-bridge-daemon.service   # default = guaranteed-dead pid (orphaned)
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_live_upgrade && smoke_fail "F2b FAIL: a DEAD-pid (orphaned) marker is not in-flight; must NOT defer. audit=$(cat "$AUDIT_LOG")"
systemctl_called start || smoke_fail "F2b FAIL (BLOCKER): a SIGKILL'd upgrade (orphaned marker, enabled+inactive) must be REAPED by the running timer (start). calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "F2b FAIL: the reap must report success once the unit is active. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "F2b FAIL: a CONFIRMED reap must consume the orphaned marker (no lingering residue). still present=$MARKER_FILE"
smoke_log "F2b PASS: systemd enabled+inactive + ORPHANED marker (SIGKILL'd upgrade) → REAPED by the running timer + marker consumed (uncatchable-interruption path covered)"

# F2c — control: systemd enabled+inactive + NO marker → still recovers (the
# pre-existing #2040 enabled+inactive recovery is not regressed by the defer guard).
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"
printf '1' >"$SVC_START_ACTIVATES_FILE"
run_liveness Linux       # no marker written
systemctl_called start || smoke_fail "F2c FAIL: enabled+inactive with no marker must still recover (#2040 contract). calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_skip_live_upgrade && smoke_fail "F2c FAIL: no marker must not be read as a live upgrade. audit=$(cat "$AUDIT_LOG")"
smoke_log "F2c PASS: systemd enabled+inactive + NO marker → recover (the defer guard does not regress #2040)"

# F2d — Finding-1 parity on systemd: orphaned marker + the reap START does NOT
# activate the unit → rebootstrap_failed + the orphaned marker SURVIVES (the next
# poll retries; a confirmed reap is required to consume it, mirroring launchd F1).
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"          # inactive
printf '0' >"$SVC_START_ACTIVATES_FILE"    # ★ start does NOT activate it
write_marker systemd agent-bridge-daemon.service   # orphaned (dead pid)
run_liveness Linux
systemctl_called start || smoke_fail "F2d FAIL: the reap must ATTEMPT a start. calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_failed || smoke_fail "F2d FAIL: a start that did not activate must audit rebootstrap_failed. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_success && smoke_fail "F2d FAIL: a failed reap must NOT report success. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "F2d FAIL: a FAILED reap must KEEP the orphaned marker for the next poll. missing=$MARKER_FILE"
smoke_log "F2d PASS: systemd orphaned marker + reap START fails to activate → rebootstrap_failed + marker SURVIVES (consume gated on confirmed reap)"

# ── F4 (#2064 r3 Finding 4 TOOTH): PID-REUSE — a marker pointing at a LIVE process
# whose START-IDENTITY does NOT match must be REAPED, not deferred forever. Models
# the SIGKILL'd-upgrade-pid-reused-by-an-unrelated-long-lived-process topology: the
# bare `kill -0 $pid` would (wrongly) see the marker as in-flight and DEFER forever.
# We write a marker with pid=$$ (this smoke process, guaranteed LIVE) but inject a
# PSID token that cannot match $$'s real start-identity → the watcher must recompute
# $$'s identity, see the mismatch, and REAP (start) rather than defer.
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"          # inactive (enabled+inactive recovery surface)
printf '1' >"$SVC_START_ACTIVATES_FILE"    # a start activates it
write_marker systemd agent-bridge-daemon.service "$$" "linux-starttime:1" # LIVE pid, BOGUS identity
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_live_upgrade && smoke_fail "F4 FAIL (BLOCKER): a REUSED-pid marker (live pid, identity mismatch) must NOT be read as in-flight — it would defer to a non-upgrade forever. audit=$(cat "$AUDIT_LOG")"
systemctl_called start || smoke_fail "F4 FAIL (BLOCKER): a reused-pid marker must be REAPED (start), not deferred. calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "F4 FAIL: the reap must report success once active. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "F4 FAIL: a CONFIRMED reap must consume the reused-pid marker. still present=$MARKER_FILE"
smoke_log "F4 PASS: PID-REUSE marker (LIVE pid + identity MISMATCH) → REAPED not deferred (the kill -0-only defer hole is closed)"

# F4b — the bounded stale-marker AGE fallback (defense-in-depth): a marker with a
# LIVE pid and a LEGACY (empty) identity token — which would otherwise DEFER on the
# bare-pid fallback — but a TS older than the bounded ceiling → REAPED. An over-age
# marker is an orphan even when its pid resolves to a live process and we cannot prove
# reuse via identity. Inject a TS ~2h old (default ceiling 3600s).
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"
printf '1' >"$SVC_START_ACTIVATES_FILE"
_old_ts="$(date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '2000-01-01T00:00:00Z')"
write_marker systemd agent-bridge-daemon.service "$$" "" "$_old_ts"  # LIVE pid, no identity, OVER-AGE
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_live_upgrade && smoke_fail "F4b FAIL (BLOCKER): an OVER-AGE marker (past the ceiling) must NOT defer even with a live pid — it is an orphan. audit=$(cat "$AUDIT_LOG")"
systemctl_called start || smoke_fail "F4b FAIL (BLOCKER): an over-age marker (live pid) must be REAPED via the bounded age fallback. calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "F4b FAIL: the over-age reap must report success once active. audit=$(cat "$AUDIT_LOG")"
smoke_log "F4b PASS: OVER-AGE marker (LIVE pid past the bounded ceiling) → REAPED via the age fallback (defense-in-depth behind the identity check)"

# F4c — control / non-regression: a marker with a LIVE pid, a MATCHING start-identity,
# and a FRESH ts → STILL DEFERS (a genuine in-flight upgrade must not be reaped). This
# proves F4/F4b reap on the FAILURE signals (mismatch / over-age), not always-reap.
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"
printf '1' >"$SVC_START_ACTIVATES_FILE"
# Recompute THIS process's real start-identity using the WATCHER'S OWN function so the
# marker's recorded token is byte-identical to what the watcher will recompute for the
# live $$ (a real in-flight upgrade). Extracting + sourcing the actual function (not a
# re-implemented inline copy) is what keeps this control from drifting from the
# normalization the watcher applies (codex r3: the inline copy missed the space→'_'
# normalization and the control wrongly reaped).
PSID_FN="$SMOKE_TMP_ROOT/2064-quiesce-psid.sh"
awk '/^quiesce_pid_start_identity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LIVENESS_SRC" >"$PSID_FN"
grep -q 'quiesce_pid_start_identity()' "$PSID_FN" \
  || smoke_fail "F4c FAIL: could not extract quiesce_pid_start_identity from $LIVENESS_SRC"
# Pass the SMOKE's own pid ($$) explicitly — a bare `$$` inside `bash -c` would be the
# SUBSHELL's pid, not the smoke's, so the recorded token would describe a dead helper
# process and never match the watcher's recompute for the marker's pid (the smoke).
_self_pid=$$
_self_psid="$("$BRIDGE_BASH" -c "source '$PSID_FN'; quiesce_pid_start_identity \"\$1\"" _ "$_self_pid" 2>/dev/null)"
write_marker systemd agent-bridge-daemon.service "$_self_pid" "$_self_psid"   # LIVE pid, MATCHING identity, fresh ts
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_live_upgrade || smoke_fail "F4c FAIL: a genuine in-flight upgrade (live pid, MATCHING identity, fresh ts) must DEFER (not be reaped). audit=$(cat "$AUDIT_LOG")"
systemctl_called start && smoke_fail "F4c FAIL (BLOCKER): must NOT reap a genuine in-flight upgrade. calls=$(cat "$SYSTEMCTL_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "F4c FAIL: a deferred in-flight marker must be PRESERVED. missing=$MARKER_FILE"
smoke_log "F4c PASS: in-flight marker (LIVE pid + MATCHING identity + fresh ts) → DEFER (identity/age teeth do not regress the genuine-upgrade defer)"

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
# Default shim state: enable succeeds (flips disabled→enabled), bootstrap LOADS the
# job (print → 0), so the EXIT handler's #2064 load-confirmation passes. Individual
# tests override the control files before calling to model failure paths.
run_marker_helper() {
  local snippet="$1"
  : >"$LAUNCHCTL_LOG"
  printf '1' >"$DISABLED_RC_FILE"            # start disabled (an interrupted quiesce)
  printf '1' >"$PRINT_RC_FILE"               # start not-loaded
  printf '1' >"$BOOTSTRAP_LOADS_FILE"        # bootstrap will load the job
  printf '0' >"$ENABLE_FAILS_FILE"
  printf '0' >"$ENABLE_SETS_UNKNOWN_FILE"
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
  local load_ok="${2:-1}"   # #2064: when 1 (default), bootstrap LOADS the job so the
                            # EXIT handler's load-confirmation passes; 0 = bootstrap
                            # does NOT load (re-enable UNVERIFIED → marker KEPT).
  : >"$LAUNCHCTL_LOG"
  printf '1' >"$DISABLED_RC_FILE"            # start disabled (interrupted quiesce)
  printf '1' >"$PRINT_RC_FILE"               # start not-loaded
  printf '%s' "$load_ok" >"$BOOTSTRAP_LOADS_FILE"
  printf '0' >"$ENABLE_FAILS_FILE"
  printf '0' >"$ENABLE_SETS_UNKNOWN_FILE"
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

# U6 — ★codex r2 EXIT-handler parity: marker outstanding, the re-enable is ATTEMPTED
# but the job does NOT load (bootstrap fails → the #2064 load-confirmation fails) →
# the marker MUST SURVIVE (the dying upgrade leaves it for the still-running liveness
# watcher to retry). The pre-r2 handler consumed it whenever print-disabled was
# merely not-disabled (incl. an unreadable/empty print-disabled).
rm -f "$U_MARKER"
run_exit_handler 1 0   # marker outstanding; bootstrap does NOT load the job
launchctl_called enable || smoke_fail "U6 FAIL: the re-enable must still be ATTEMPTED on an interrupted-upgrade abort. calls=$(cat "$LAUNCHCTL_LOG")"
[[ -f "$U_MARKER" ]] || smoke_fail "U6 FAIL (BLOCKER, codex r2): an UNVERIFIED re-enable (job not loaded) must KEEP the marker for the liveness watcher. missing=$U_MARKER"
smoke_log "U6 PASS: EXIT handler re-enable UNVERIFIED (job not loaded) → marker SURVIVES (consume gated on confirmed load; codex r2 hole closed)"

# U7 — ★#2064 r3 codex catch: the REAL marker writer records a start-identity that
# SOURCES back INTACT. On BSD/mac the raw `ps -o lstart=` form is "Mon Jun 24 ..." —
# space-laden — and the marker is a SOURCEABLE KEY=value file, so an unquoted/raw
# value would parse as `BRIDGE_QUIESCE_UPGRADE_PSID=ps-lstart:Mon` + a stray `Jun ...`
# command → the recorded identity reads back EMPTY and the whole PID-reuse defense
# degrades to the bare-pid defer. Drive the real writer (pid=$$, so the identity is
# populated on any host with /proc or ps), then SOURCE the marker and assert the PSID
# round-trips non-empty AND equals a fresh recompute of the upgrade-side helper.
rm -f "$U_MARKER"
run_marker_helper '
  _bridge_upgrade_write_quiesce_marker launchd ai.agent-bridge.daemon
  # Fresh recompute of THIS process identity via the SAME helper the writer used.
  _fresh="$(_bridge_upgrade_pid_start_identity "$$")"
  # Source the marker the way the watcher does and surface the read-back PSID.
  # shellcheck disable=SC1090
  _read="$(source "'"$U_MARKER"'" 2>/dev/null; printf "%s" "${BRIDGE_QUIESCE_UPGRADE_PSID:-}")"
  printf "FRESH=[%s]\n" "$_fresh"
  printf "READBACK=[%s]\n" "$_read"
'
_u7_fresh="$(grep -E "^FRESH=" "$SMOKE_TMP_ROOT/u-stdout.txt" | sed -e "s/^FRESH=\[//" -e "s/\]$//")"
_u7_read="$(grep -E "^READBACK=" "$SMOKE_TMP_ROOT/u-stdout.txt" | sed -e "s/^READBACK=\[//" -e "s/\]$//")"
# If neither /proc nor ps yields a token on this host, the identity is legitimately
# empty (the documented conservative fallback) — both sides empty is consistent, not a
# bug. The bug we guard is a NON-EMPTY identity that read back EMPTY/truncated.
if [[ -n "$_u7_fresh" ]]; then
  [[ -n "$_u7_read" ]] || smoke_fail "U7 FAIL (BLOCKER, codex r3): the recorded start-identity ('$_u7_fresh') read back EMPTY after sourcing the marker — a spaced/unquoted PSID broke the source (PID-reuse defense lost on BSD/mac). marker=$(cat "$U_MARKER")"
  [[ "$_u7_read" == "$_u7_fresh" ]] || smoke_fail "U7 FAIL (BLOCKER): the sourced PSID '$_u7_read' != the fresh recompute '$_u7_fresh' (identity round-trip mismatch → a genuine in-flight upgrade would be misclassified)."
  case "$_u7_read" in
    *[[:space:]]*) smoke_fail "U7 FAIL: the recorded PSID '$_u7_read' still contains raw whitespace — it must be normalized to a single shell word for the sourceable marker." ;;
    *\'*)          smoke_fail "U7 FAIL (BLOCKER, codex r3 round-2): the recorded PSID '$_u7_read' contains a single-quote — it would break the single-quoted marker value and re-open the empty-readback hole." ;;
  esac
  smoke_log "U7 PASS: real marker writer records a start-identity that SOURCES back intact + matches a fresh recompute (codex r3 spaced-PSID source hole closed)"
else
  smoke_log "U7 PASS (degraded host): no /proc or ps identity source available → identity legitimately empty both sides (conservative bare-pid fallback; nothing to round-trip)"
fi

# U8 — ★#2064 r3 codex round-2: the WRITE-side normalization must STRIP a single-quote
# even when the underlying `ps` emits one (a pathological/locale lstart) — otherwise a
# ' in the value breaks the single-quoted marker on source. Stub `ps` to emit a value
# containing a quote + spaces, run the REAL identity helper, and assert the token is
# allowlist-clean (no quote, no whitespace) AND that a marker carrying it sources back
# intact. Forces the ps branch by making /proc unreadable via a fake pid arg path is
# not possible, so we shim ps directly and drive the helper with a pid the shim echoes.
PS_SHIM_DIR="$SMOKE_TMP_ROOT/ps-shim"
mkdir -p "$PS_SHIM_DIR"
cat >"$PS_SHIM_DIR/ps" <<'PSEOF'
#!/usr/bin/env bash
# Emit a lstart-shaped value WITH a single-quote and spaces (worst case).
printf "Mon Jun 24 07:24:01 O'Clock 2026\n"
PSEOF
chmod +x "$PS_SHIM_DIR/ps"
rm -f "$U_MARKER"
# Run the real helper with the ps shim FIRST on PATH and /proc reads suppressed by
# pointing at a pid whose /proc/<pid>/stat we make unreadable (a non-existent pid).
_u8_out="$(
  PATH="$PS_SHIM_DIR:$PATH" \
  TARGET_ROOT="$U_HOME" BRIDGE_STATE_DIR="$U_STATE" SOURCE_VERSION="u-test" \
  "$BRIDGE_BASH" -c "
    set -uo pipefail
    source '$U_HELPERS'
    # pid 2222222 almost certainly has no /proc entry → forces the ps branch.
    _t=\"\$(_bridge_upgrade_pid_start_identity 2222222)\"
    printf 'TOKEN=[%s]\n' \"\$_t\"
  " 2>/dev/null
)"
_u8_tok="$(printf '%s\n' "$_u8_out" | grep -E "^TOKEN=" | sed -e "s/^TOKEN=\[//" -e "s/\]$//")"
if [[ -n "$_u8_tok" ]]; then
  case "$_u8_tok" in
    *\'*)          smoke_fail "U8 FAIL (BLOCKER): the helper passed through a single-quote ('$_u8_tok') from ps lstart — it must be stripped by the allowlist." ;;
    *[[:space:]]*) smoke_fail "U8 FAIL (BLOCKER): the helper passed through whitespace ('$_u8_tok') from ps lstart." ;;
  esac
  # Prove the token survives a real sourceable marker round-trip (single-quote-wrapped).
  _u8_marker="$SMOKE_TMP_ROOT/u8-marker.state"
  printf "BRIDGE_QUIESCE_UPGRADE_PSID='%s'\n" "$_u8_tok" >"$_u8_marker"
  # shellcheck disable=SC1090
  _u8_read="$("$BRIDGE_BASH" -c "source '$_u8_marker' 2>/dev/null; printf '%s' \"\${BRIDGE_QUIESCE_UPGRADE_PSID:-}\"")"
  [[ "$_u8_read" == "$_u8_tok" ]] || smoke_fail "U8 FAIL (BLOCKER): the allowlisted token '$_u8_tok' did not round-trip through a single-quoted marker (read back '$_u8_read')."
  smoke_log "U8 PASS: a quote-bearing ps lstart is STRIPPED to an allowlist-clean token that round-trips a single-quoted marker (codex r3 round-2 quote hole closed)"
else
  smoke_fail "U8 FAIL: the ps shim did not produce a token (the ps branch was not exercised). out=$_u8_out"
fi

# ── F3 (#2064 r3 Finding 3 TOOTH): the NORMAL restart-phase common cleanup must
# clear the quiesce marker ONLY on a CONFIRMED recovery (launchd LOAD_STATE=loaded /
# systemd LOAD_STATE=active), and LEAVE it for the liveness watcher otherwise. The
# pre-r3 cleanup cleared it UNCONDITIONALLY once the restart phase ran to completion,
# so a restore that left the launchd job enabled-but-unloaded removed the marker
# anyway → the next liveness poll had no discriminator → daemon silently down.
#
# Static guard FIRST (non-vacuous): the source must (a) NO LONGER contain the old
# unconditional-clear rationale, and (b) gate the restart-phase clear on the
# LOAD_STATE confirmed-recovery signal.
grep -q 'unconditionally clear the quiesce-intent marker' "$UPGRADE_SRC" \
  && smoke_fail "F3 FAIL (BLOCKER): the restart-phase still UNCONDITIONALLY clears the quiesce marker after an unverified restore (#2064 r3 Finding 3 not applied)."
grep -q '_bridge_upgrade_restart_recovery_confirmed' "$UPGRADE_SRC" \
  || smoke_fail "F3 FAIL: the restart-phase confirmed-recovery gate (_bridge_upgrade_restart_recovery_confirmed) is absent from $UPGRADE_SRC."
smoke_log "F3 (static) PASS: restart-phase clear is gated on confirmed recovery (no unconditional clear after an unverified restore)"

# Faithful mini-harness of the restart-phase confirmed-recovery gate (mirrors the
# bridge-upgrade.sh block). Drives the REAL _bridge_upgrade_clear_quiesce_marker with
# the managed-flag + LOAD_STATE combos so the assertion is on actual marker survival.
run_restart_clear_gate() {
  local managed="$1" load_state="$2"   # managed: launchd|systemd|none
  rm -f "$U_MARKER"
  PATH="$SHIM_DIR:$PATH" \
  TARGET_ROOT="$U_HOME" \
  BRIDGE_STATE_DIR="$U_STATE" \
  SOURCE_VERSION="u-test" \
  GATE_MANAGED="$managed" \
  GATE_LOAD_STATE="$load_state" \
  "$BRIDGE_BASH" -c "
    # ★ Run under the REAL upgrader errexit regime so this harness catches an
    # errexit-abort in the gate (a trailing '[[ ]] && var=1' false-branch would
    # trip set -e — the gate must be set-e-safe).
    set -euo pipefail
    source '$U_HELPERS'
    # A quiesce wrote a marker; the restart phase has now run.
    _bridge_upgrade_write_quiesce_marker '\${GATE_MANAGED/none/launchd}' ai.agent-bridge.daemon
    _UPGRADE_DAEMON_LAUNCHD_MANAGED=0
    _UPGRADE_DAEMON_SYSTEMD_MANAGED=0
    _BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE='unknown'
    _BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE='unknown'
    case \"\${GATE_MANAGED}\" in
      launchd) _UPGRADE_DAEMON_LAUNCHD_MANAGED=1; _BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE=\"\${GATE_LOAD_STATE}\" ;;
      systemd) _UPGRADE_DAEMON_SYSTEMD_MANAGED=1; _BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE=\"\${GATE_LOAD_STATE}\" ;;
    esac
    # ↓ verbatim shape of the bridge-upgrade.sh restart-phase confirmed-recovery gate.
    _bridge_upgrade_restart_recovery_confirmed=0
    if [[ \"\${_UPGRADE_DAEMON_LAUNCHD_MANAGED:-0}\" == \"1\" ]]; then
      if [[ \"\${_BRIDGE_UPGRADE_LAUNCHD_LOAD_STATE:-unknown}\" == \"loaded\" ]]; then
        _bridge_upgrade_restart_recovery_confirmed=1
      fi
    elif [[ \"\${_UPGRADE_DAEMON_SYSTEMD_MANAGED:-0}\" == \"1\" ]]; then
      if [[ \"\${_BRIDGE_UPGRADE_SYSTEMD_LOAD_STATE:-unknown}\" == \"active\" ]]; then
        _bridge_upgrade_restart_recovery_confirmed=1
      fi
    else
      _bridge_upgrade_restart_recovery_confirmed=1
    fi
    if (( _bridge_upgrade_restart_recovery_confirmed == 1 )); then
      _bridge_upgrade_clear_quiesce_marker
    fi
  " >"$SMOKE_TMP_ROOT/f3-stdout.txt" 2>"$SMOKE_TMP_ROOT/f3-stderr.txt"
}

# F3 — launchd restart-phase restore left the job NOT loaded → marker SURVIVES.
run_restart_clear_gate launchd not_loaded
[[ -f "$U_MARKER" ]] || smoke_fail "F3 FAIL (BLOCKER): a restart-phase launchd restore that left the job not_loaded must KEEP the marker for the liveness watcher. missing=$U_MARKER"
smoke_log "F3 PASS: restart-phase launchd restore NOT confirmed (not_loaded) → marker SURVIVES (no unconditional clear after an unverified restore)"

# F3b — control: launchd restore CONFIRMED loaded → marker CLEARED (the gate consumes
# on confirmed recovery, not always-keep).
run_restart_clear_gate launchd loaded
[[ -f "$U_MARKER" ]] && smoke_fail "F3b FAIL: a CONFIRMED launchd restore (loaded) must CLEAR the marker. still present=$U_MARKER"
smoke_log "F3b PASS: restart-phase launchd restore CONFIRMED (loaded) → marker CLEARED (gate consumes on confirmed recovery)"

# F3c — systemd parity: restore left the unit inactive → marker SURVIVES.
run_restart_clear_gate systemd inactive
[[ -f "$U_MARKER" ]] || smoke_fail "F3c FAIL (BLOCKER): a restart-phase systemd restore that left the unit inactive must KEEP the marker. missing=$U_MARKER"
smoke_log "F3c PASS: restart-phase systemd restore NOT confirmed (inactive) → marker SURVIVES (launchd/systemd parity)"

# F3d — systemd control: restore CONFIRMED active → marker CLEARED.
run_restart_clear_gate systemd active
[[ -f "$U_MARKER" ]] && smoke_fail "F3d FAIL: a CONFIRMED systemd restore (active) must CLEAR the marker. still present=$U_MARKER"
smoke_log "F3d PASS: restart-phase systemd restore CONFIRMED (active) → marker CLEARED (gate consumes on confirmed recovery)"

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
