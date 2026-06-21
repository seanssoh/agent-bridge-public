#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2040-daemon-enabled-but-unloaded.sh — Issue #2040 Part B.
#
# The independent liveness watcher (its own launchd job / systemd timer, survives
# the daemon's death) is the only viable recovery for an ENABLED-BUT-UNLOADED
# daemon: launchd KeepAlive / systemd Restart= are moot with no loaded job, and
# cron self-heal is impossible (cron needs the daemon). Before #2040 the watcher
# saw "heartbeat stale + no pid" and just emitted daemon_liveness_skip_not_running.
# Part B adds a standing re-bootstrap BEFORE that skip — gated on the job being
# PROVEN should-be-running-but-unloaded, cooldown-controlled, and ★airtight on
# the operator-disabled case (NEVER fight an `agb daemon stop`).
#
# This smoke runs the LIVE scripts/bridge-daemon-liveness.sh end-to-end with a
# stale heartbeat, a dead daemon pid, and scripted launchctl / systemctl shims,
# asserting on the audit events (logs/audit.jsonl) and stdout.
#
#   L1 — launchd ENABLED-BUT-UNLOADED → re-bootstrap SUCCESS
#        (rebootstrap_attempt + rebootstrap_success; NOT skip_not_running).
#   L2 — ★launchd DISABLED → SKIP (rebootstrap_skip_disabled; NO bootstrap call;
#        NOT skip_not_running) — never fight an operator stop.
#   L3 — launchd LOADED (but no pid) → defer (rebootstrap_skip_loaded then the
#        standard skip_not_running; KeepAlive owns the loaded-job respawn).
#   L4 — launchd enabled-but-unloaded but COOLDOWN active → suppressed
#        (rebootstrap_skip_cooldown; NO bootstrap call).
#   L5 — launchd re-bootstrap FAILS (bootstrap never loads) → rebootstrap_failed
#        + loud WARN with `launchctl bootstrap` remediation.
#   S1 — systemd ENABLED + INACTIVE → re-start (rebootstrap_attempt +
#        rebootstrap_success; reset-failed + start called).
#   S2 — ★systemd DISABLED → SKIP (rebootstrap_skip_disabled; NO start call).
#   M1 — MUTATION: with the rebootstrap dispatcher call removed from main(), the
#        enabled-but-unloaded launchd case falls through to skip_not_running
#        (proves the new branch is what recovers — the test is non-vacuous).

set -uo pipefail
SMOKE_NAME="2040-daemon-enabled-but-unloaded"
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
smoke_assert_file_exists "$LIVENESS_SRC" "bridge-daemon-liveness.sh source present"
grep -q 'maybe_rebootstrap_unloaded_daemon' "$LIVENESS_SRC" \
  || smoke_fail "#2040 rebootstrap dispatcher not present in $LIVENESS_SRC"

# Isolated runtime root (NEVER the operator's live install — #1860 guard).
RUN_ROOT="$SMOKE_TMP_ROOT/run"
STATE_DIR="$RUN_ROOT/state"
LOG_DIR="$RUN_ROOT/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR"
HEARTBEAT_FILE="$STATE_DIR/daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
COOLDOWN_FILE="$STATE_DIR/daemon-liveness-cooldown.ts"
AUDIT_LOG="$LOG_DIR/audit.jsonl"
CONFIG_FILE="$STATE_DIR/launchagent.config"

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

# Scripted launchctl shim:
#   PRINT_RC_FILE          — `launchctl print` exit code (0=loaded, 1=not).
#                            A successful `bootstrap` flips it to 0.
#   DISABLED_RC_FILE       — `launchctl print-disabled` emits `"<label>" => true`
#                            when DISABLED_RC=1 else `=> false`.
#   BOOTSTRAP_LOADS_FILE   — when 1, a successful bootstrap sets PRINT_RC=0 (job
#                            loads); when 0, bootstrap "succeeds" but the job
#                            never loads (drives the failure path).
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
    # Faithful to real macOS \`launchctl print-disabled gui/<uid>\` output, which
    # is tab-indented \`"<label>" => enabled\` / \`"<label>" => disabled\` (NOT the
    # legacy true/false). The production grep accepts both spellings; the smoke
    # uses the REAL one so a regression to a true-only match would be caught.
    drc="\$(cat "$DISABLED_RC_FILE" 2>/dev/null || printf 0)"
    case "\$drc" in
      1) printf '\t"%s" => disabled\n' "$TEST_LABEL"; exit 0 ;;  # DISABLED
      2) exit 1 ;;                                                # command FAILS (unknown)
      *) printf '\t"%s" => enabled\n' "$TEST_LABEL"; exit 0 ;;   # enabled
    esac
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

# Scripted systemctl shim:
#   SVC_ENABLED_FILE  — `is-enabled` stdout (enabled / disabled / "" for unknown).
#   SVC_ACTIVE_RC_FILE — `is-active` exit code; a successful `start` sets it 0
#                        when SVC_START_ACTIVATES=1.
#   SVC_START_ACTIVATES_FILE — 1 => start makes is-active succeed; 0 => stays
#                              inactive (failure path).
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

# sleep no-op (the helpers do not sleep in Part B, but keep parity/speed).
cat >"$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"

# Establish a STALE heartbeat (older than threshold) and a DEAD pid so main()
# reaches the not-running branch where Part B lives. Threshold/cooldown are
# small so the smoke is fast; the watcher sanitizes them.
seed_stale_no_pid() {
  : >"$AUDIT_LOG"
  : >"$LAUNCHCTL_LOG"
  : >"$SYSTEMCTL_LOG"
  rm -f "$COOLDOWN_FILE"
  # heartbeat 99999s old
  printf 'tick\n' >"$HEARTBEAT_FILE"
  local old=$(( $(date +%s) - 99999 ))
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old" +%Y%m%d%H%M.%S)" "$HEARTBEAT_FILE" 2>/dev/null || true
  # a pid that is guaranteed dead (very high, unused)
  printf '999999\n' >"$PID_FILE"
}

# Run the liveness watcher (the real script) with all shims + isolated env.
run_liveness() {
  local uname_out="${1:-Darwin}"
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
  "$BRIDGE_BASH" "$LIVENESS_SRC" >"$SMOKE_TMP_ROOT/liveness-stdout.txt" 2>"$SMOKE_TMP_ROOT/liveness-stderr.txt"
}

audit_has() { grep -q "\"action\": \"$1\"" "$AUDIT_LOG" 2>/dev/null; }
launchctl_called() { grep -qE "^$1( |\$)" "$LAUNCHCTL_LOG" 2>/dev/null; }
systemctl_called() { grep -qE "(^| )$1( |\$)" "$SYSTEMCTL_LOG" 2>/dev/null; }

# ── L1: launchd ENABLED-BUT-UNLOADED → re-bootstrap SUCCESS ───────────────────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '0' >"$DISABLED_RC_FILE"       # NOT disabled (enabled)
printf '1' >"$BOOTSTRAP_LOADS_FILE"   # bootstrap will load the job
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_attempt || smoke_fail "L1 FAIL: no rebootstrap_attempt audit. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "L1 FAIL: no rebootstrap_success audit. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_skip_not_running && smoke_fail "L1 FAIL: must NOT fall through to skip_not_running. audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap || smoke_fail "L1 FAIL: bootstrap was not called. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "L1 PASS: launchd enabled-but-unloaded → re-bootstrap SUCCESS (no skip_not_running)"

# ── L2: ★launchd DISABLED → SKIP (never fight an operator stop) ───────────────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '1' >"$DISABLED_RC_FILE"       # DISABLED (operator stop)
printf '1' >"$BOOTSTRAP_LOADS_FILE"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "L2 FAIL: no rebootstrap_skip_disabled audit. audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap && smoke_fail "L2 FAIL: bootstrap MUST NOT be called on a disabled job. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_attempt && smoke_fail "L2 FAIL: must not attempt re-bootstrap on a disabled job. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_skip_not_running && smoke_fail "L2 FAIL: disabled-skip must short-circuit (no skip_not_running). audit=$(cat "$AUDIT_LOG")"
smoke_log "L2 PASS: launchd DISABLED job → SKIP + audit, NO bootstrap (operator stop respected)"

# ── L3: launchd LOADED (but no pid) → defer to KeepAlive ──────────────────────
seed_stale_no_pid
printf '0' >"$PRINT_RC_FILE"          # LOADED already
printf '0' >"$DISABLED_RC_FILE"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_loaded || smoke_fail "L3 FAIL: no rebootstrap_skip_loaded audit. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_skip_not_running || smoke_fail "L3 FAIL: a loaded-but-no-pid job must fall through to skip_not_running. audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap && smoke_fail "L3 FAIL: bootstrap MUST NOT be called when the job is already loaded. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "L3 PASS: launchd LOADED job → skip_loaded + defer to skip_not_running (KeepAlive owns it)"

# ── L4: enabled-but-unloaded but COOLDOWN active → suppressed ─────────────────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '0' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
printf '%s\n' "$(date +%s)" >"$COOLDOWN_FILE"   # cooldown started NOW
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_cooldown || smoke_fail "L4 FAIL: no rebootstrap_skip_cooldown audit. audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap && smoke_fail "L4 FAIL: cooldown must suppress the bootstrap. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "L4 PASS: enabled-but-unloaded under cooldown → skip_cooldown, NO bootstrap (storm control)"

# ── L5: launchd re-bootstrap FAILS → rebootstrap_failed + loud WARN ───────────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '0' >"$DISABLED_RC_FILE"
printf '0' >"$BOOTSTRAP_LOADS_FILE"   # bootstrap "succeeds" but job never loads
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_failed || smoke_fail "L5 FAIL: no rebootstrap_failed audit. audit=$(cat "$AUDIT_LOG")"
L5_STDERR="$(cat "$SMOKE_TMP_ROOT/liveness-stderr.txt")"
smoke_assert_contains "$L5_STDERR" "still UNLOADED after re-bootstrap" "L5 emits a loud WARN on failure"
smoke_assert_contains "$L5_STDERR" "launchctl bootstrap gui/" "L5 WARN includes the exact remediation"
smoke_log "L5 PASS: launchd re-bootstrap failure → rebootstrap_failed + loud WARN with remediation"

# ── L6: ★FAIL-CLOSED — print-disabled UNREADABLE → SKIP (cannot confirm enabled)
# If we cannot read the disabled-state we must NOT recover (the job could be
# operator-disabled). Skip with disabled_state=unknown, never bootstrap.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '2' >"$DISABLED_RC_FILE"       # print-disabled FAILS (unknown)
printf '1' >"$BOOTSTRAP_LOADS_FILE"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "L6 FAIL: no skip_disabled audit on unreadable print-disabled. audit=$(cat "$AUDIT_LOG")"
grep -q '"disabled_state": "unknown"' "$AUDIT_LOG" || smoke_fail "L6 FAIL: disabled_state must be 'unknown' (fail-closed). audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap && smoke_fail "L6 FAIL: must NOT bootstrap when disabled-state is unknown. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "L6 PASS: print-disabled unreadable → fail-closed SKIP (disabled_state=unknown, NO bootstrap)"

# ── S1: systemd ENABLED + INACTIVE → re-start ─────────────────────────────────
seed_stale_no_pid
printf 'enabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"        # inactive
printf '1' >"$SVC_START_ACTIVATES_FILE"  # start activates
run_liveness Linux
audit_has daemon_liveness_rebootstrap_attempt || smoke_fail "S1 FAIL: no rebootstrap_attempt audit. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "S1 FAIL: no rebootstrap_success audit. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_skip_not_running && smoke_fail "S1 FAIL: must NOT fall through to skip_not_running. audit=$(cat "$AUDIT_LOG")"
systemctl_called start || smoke_fail "S1 FAIL: systemctl start was not called. calls=$(cat "$SYSTEMCTL_LOG")"
systemctl_called reset-failed || smoke_fail "S1 FAIL: reset-failed not called before start. calls=$(cat "$SYSTEMCTL_LOG")"
smoke_log "S1 PASS: systemd enabled+inactive → reset-failed + start + verify active (rebootstrap_success)"

# ── S2: ★systemd DISABLED → SKIP (never fight an operator stop) ───────────────
seed_stale_no_pid
printf 'disabled' >"$SVC_ENABLED_FILE"
printf '1' >"$SVC_ACTIVE_RC_FILE"
run_liveness Linux
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "S2 FAIL: no rebootstrap_skip_disabled audit. audit=$(cat "$AUDIT_LOG")"
systemctl_called start && smoke_fail "S2 FAIL: systemctl start MUST NOT be called on a disabled unit. calls=$(cat "$SYSTEMCTL_LOG")"
audit_has daemon_liveness_skip_not_running && smoke_fail "S2 FAIL: disabled-skip must short-circuit. audit=$(cat "$AUDIT_LOG")"
smoke_log "S2 PASS: systemd DISABLED unit → SKIP + audit, NO start (operator stop respected)"

# ── M1: MUTATION — remove the dispatcher call → falls through to skip_not_running
# The mutated copy MUST live next to the real script in scripts/ so the watcher's
# REPO_ROOT (resolved from its own SCRIPT_DIR/..) still finds bridge-audit.py —
# otherwise emit_audit silently no-ops and the test would be vacuously green.
MUTATED_SRC="$REPO_ROOT/scripts/.2040-liveness-mutated.$$.sh"
mutated_cleanup() { rm -f "$MUTATED_SRC"; smoke_cleanup_temp_root; }
trap mutated_cleanup EXIT
# Neuter the dispatcher so the not-running branch can no longer recover.
sed 's/maybe_rebootstrap_unloaded_daemon "\$age"/false/' "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q 'if false; then' "$MUTATED_SRC" || smoke_fail "M1 FAIL: mutation did not neuter the dispatcher call"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # enabled-but-unloaded (would recover unmutated)
printf '0' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
PATH="$SHIM_DIR:$PATH" \
UNAME_OUT="Darwin" \
BRIDGE_STATE_DIR="$STATE_DIR" \
BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
BRIDGE_DAEMON_HEARTBEAT_FILE="$HEARTBEAT_FILE" \
BRIDGE_DAEMON_PID_FILE="$PID_FILE" \
BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE="$COOLDOWN_FILE" \
BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS="600" \
BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS="600" \
BRIDGE_LAUNCHAGENT_CONFIG_FILE="$CONFIG_FILE" \
"$BRIDGE_BASH" "$MUTATED_SRC" >/dev/null 2>&1
audit_has daemon_liveness_skip_not_running || smoke_fail "M1 FAIL (vacuous test!): without the dispatcher the enabled-but-unloaded case did NOT fall through to skip_not_running. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_success && smoke_fail "M1 FAIL: mutated watcher must NOT recover (it still re-bootstrapped). audit=$(cat "$AUDIT_LOG")"
launchctl_called bootstrap && smoke_fail "M1 FAIL: mutated watcher must NOT bootstrap. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "M1 PASS: MUTATION proven — removing the dispatcher restores skip_not_running (the new branch is what recovers)"

smoke_log "all enabled-but-unloaded recovery tests PASS (#2040 Part B)"
