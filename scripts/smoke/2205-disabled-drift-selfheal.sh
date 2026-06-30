#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2205-disabled-drift-selfheal.sh — Issue #2205.
#
# #2055 closed the interrupted-UPGRADE disable hole: an upgrade SIGKILL'd between
# its quiesce-disable and restore-enable leaves the launchd job disabled, and a
# durable per-path marker (dead writer pid) lets the liveness watcher tell that
# from an operator `agb daemon stop`. #2205 GENERALIZES that into the proof
# contract for ANY first-party non-operator disable: the marker now carries a
# `reason` enum and the watcher only re-enables a disabled job when the marker's
# platform+target MATCH the exact job it is about to recover (the cross-target
# confusion guard the #2055 code lacked). `interrupted_upgrade` is one reason
# value; a marker written before #2205 (no BRIDGE_QUIESCE_REASON field) defaults
# to it, so the #2055 path is preserved.
#
# This smoke runs the LIVE scripts/bridge-daemon-liveness.sh end-to-end with a
# stale heartbeat, a dead daemon pid, scripted launchctl/systemctl shims, and the
# various marker states, plus the LIVE bridge-doctor.py detector. Each guard has a
# MUTATION proof (revert the guard → the corresponding case flips and the smoke
# fails), so the test is non-vacuous.
#
#   P1 — launchd DISABLED + marker (dead writer, reason=watchdog_disable, MATCHING
#        platform+target) → RE-ENABLE + recover (proves a NON-upgrade reason value
#        also recovers — the generalization is real, not upgrade-only).
#   P2 — ★launchd DISABLED + NO marker → SKIP (operator-stop). The residual #2205
#        hole's fail-closed default.
#   P3 — ★launchd DISABLED + marker whose TARGET is a DIFFERENT label → SKIP. The
#        new cross-target tooth: a marker for another job must NOT re-enable this
#        one (else a stale/foreign marker re-arms an operator-stopped job).
#   P4 — ★launchd DISABLED + marker whose PLATFORM=systemd → SKIP (platform
#        mismatch; a systemd marker can never prove a launchd job's disable).
#   P5 — ★launchd UNKNOWN probe (print-disabled unreadable) + valid matching marker →
#        SKIP + marker RETAINED (★Phase-4 r2 tri-state: a marker proves the LAST
#        first-party action, NOT the CURRENT state — an unreadable probe cannot rule
#        out an operator re-disable, so fail closed; never enable).
#   MP5 — ★MUTATION: revert the tri-state split (unknown re-enters the disabled
#        recovery) → P5's unknown+marker case re-enables (P5's guard is load-bearing).
#   P6 — ★launchd DISABLED + MALFORMED matching marker (valid early fields, broken
#        shell tail) → SKIP (checked single-source parse fails closed; a marker that
#        does not fully parse is never proof — codex r1).
#   P7 — ★launchd DISABLED + OFF-SCHEMA matching marker (sources rc=0 but carries an
#        unexpected key) → SKIP (strict-schema validation: source success is not
#        sufficient proof — codex r2).
#   MP6 — ★MUTATION: neuter the checked-source rejection → P6's malformed marker
#        re-enables (P6's guard is independently load-bearing).
#   MP7 — ★MUTATION: neuter the strict-schema `*) return 1` arm → P7's off-schema
#        marker re-enables (P7's guard is independently load-bearing).
#   M1 — ★MUTATION (target tooth): neuter the target-match guard → P3's foreign-
#        target marker STARTS re-enabling the operator-stopped job (recover). The
#        cross-target guard is load-bearing.
#   M2 — ★MUTATION (marker gate): neuter the whole discriminator → P1's recoverable
#        disable falls back to skip_disabled. The marker gate is load-bearing.
#   D1 — DOCTOR: launchd disabled + daemon down + NO marker → the read-only
#        detector emits `daemon-launchd-disabled-drift` (the otherwise-silent drift
#        is made visible).
#   D2 — ★DOCTOR: launchd disabled + a MATCHING dead-writer marker → NO finding (the
#        watcher owns the recoverable case; the doctor must not double-report it).
#   D3 — DOCTOR mutation: neuter the marker carve-out → D2's matching-marker case
#        STARTS reporting (the carve-out is load-bearing).
#   D4 — ★DOCTOR: launchd disabled + MALFORMED matching marker → REPORTS (an
#        unparseable marker is not proof of recoverability; codex r1).
#   MD4 — ★DOCTOR MUTATION: neuter the well-formedness gate → D4's malformed marker
#        suppresses (D4's guard is independently load-bearing).
#   D5 — ★DOCTOR: launchd disabled + matching marker but LIVE writer → REPORTS (only
#        a DEAD-writer matching marker is the watcher's recoverable case).
#   MD5 — ★DOCTOR MUTATION: drop the dead-writer term → D5's live-writer marker
#        suppresses (D5's guard is independently load-bearing).
#   D6 — ★DOCTOR: launchd UNKNOWN probe (unreadable) + perfect dead-writer marker →
#        REPORTS (★Phase-4 r2 tri-state: the watcher won't recover an unknown probe,
#        so the doctor must surface it; only POSITIVELY-readable disabled suppresses).
#   MD6 — ★DOCTOR MUTATION: drop the positive-readable-disabled term → D6's unknown-
#        probe case suppresses (D6's guard is independently load-bearing).

set -uo pipefail
SMOKE_NAME="2205-disabled-drift-selfheal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() { rm -f "${MUTATED_SRC:-}" "${MUTATED_DOCTOR:-}" 2>/dev/null; smoke_cleanup_temp_root; }
trap cleanup EXIT

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi

smoke_make_temp_root "$SMOKE_NAME"
LIVENESS_SRC="$REPO_ROOT/scripts/bridge-daemon-liveness.sh"
UPGRADE_SRC="$REPO_ROOT/bridge-upgrade.sh"
DOCTOR_SRC="$REPO_ROOT/bridge-doctor.py"
smoke_assert_file_exists "$LIVENESS_SRC" "bridge-daemon-liveness.sh source present"
smoke_assert_file_exists "$UPGRADE_SRC" "bridge-upgrade.sh source present"
smoke_assert_file_exists "$DOCTOR_SRC" "bridge-doctor.py source present"
grep -q 'non_operator_disable_marker' "$LIVENESS_SRC" \
  || smoke_fail "#2205 generalized marker discriminator not present in $LIVENESS_SRC"
grep -q 'BRIDGE_QUIESCE_REASON' "$UPGRADE_SRC" \
  || smoke_fail "#2205 reason field not present in the marker writer in $UPGRADE_SRC"
grep -q 'detect_disabled_drift_no_marker' "$DOCTOR_SRC" \
  || smoke_fail "#2205 doctor detector not present in $DOCTOR_SRC"

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

# Scripted launchctl shim (mirrors the #2055 smoke):
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

# Write a quiesce/disable-intent marker. $1=platform $2=target $3=reason
# $4=pid (default guaranteed-dead). PSID empty (legacy → bare-pid defer); TS=now
# (fresh, so the bounded age fallback does not trip).
write_marker() {
  local platform="$1" target="$2" reason="${3:-interrupted_upgrade}" pid="${4:-999998}"
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_UPGRADE_PID=$pid
BRIDGE_QUIESCE_UPGRADE_PSID=''
BRIDGE_QUIESCE_UPGRADE_UID=$(id -u 2>/dev/null || printf '%s' "${UID:-}")
BRIDGE_QUIESCE_PLATFORM=$platform
BRIDGE_QUIESCE_TARGET=$target
BRIDGE_QUIESCE_REASON=$reason
BRIDGE_QUIESCE_TS=$ts
BRIDGE_QUIESCE_VERSION=test
EOF
}

# Write a marker whose early fields are VALID + MATCHING (numeric pid, launchd
# platform, this label) but whose tail is BROKEN shell that nonetheless starts with
# an ALLOWED key — an unterminated single-quoted value. This passes the strict-schema
# prefix check (the key is on-allowlist) but the unbalanced quote makes `source` FAIL,
# so it isolates the checked-source guard (codex r1) from the strict-schema guard
# (codex r2). A checked single-source must FAIL CLOSED.
write_malformed_marker() {
  local target="${1:-$TEST_LABEL}"
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_UPGRADE_PID=999998
BRIDGE_QUIESCE_PLATFORM=launchd
BRIDGE_QUIESCE_TARGET=$target
BRIDGE_QUIESCE_REASON='watchdog_disable
BRIDGE_QUIESCE_VERSION=unterminated-quote-above-breaks-source
EOF
}

# Write a marker whose lines are ALL syntactically-valid sourceable assignments AND
# whose recognized fields are VALID + MATCHING, but which carries an OFF-SCHEMA extra
# key (sources rc=0, so the checked-source alone would accept it). Strict-schema
# validation must reject it (codex r2) — an unexpected key is not this marker's
# content and is not proof of a first-party disable.
write_offschema_marker() {
  local target="${1:-$TEST_LABEL}"
  mkdir -p "$(dirname "$MARKER_FILE")"
  cat >"$MARKER_FILE" <<EOF
BRIDGE_QUIESCE_UPGRADE_PID=999998
BRIDGE_QUIESCE_PLATFORM=launchd
BRIDGE_QUIESCE_TARGET=$target
BRIDGE_QUIESCE_REASON=watchdog_disable
BRIDGE_QUIESCE_UNEXPECTED_KEY=injected
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

# ── P1: launchd DISABLED + marker (dead writer, NON-upgrade reason, matching) ──
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '1' >"$DISABLED_RC_FILE"       # DISABLED
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable   # non-upgrade reason, dead pid
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_interrupted_upgrade || smoke_fail "P1 FAIL: no recovery audit on a valid matching marker. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable || smoke_fail "P1 FAIL: launchctl enable not called. calls=$(cat "$LAUNCHCTL_LOG")"
launchctl_called bootstrap || smoke_fail "P1 FAIL: bootstrap not called after re-enable. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_success || smoke_fail "P1 FAIL: no rebootstrap_success. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_skip_disabled && smoke_fail "P1 FAIL: must NOT skip a valid-marker disable. audit=$(cat "$AUDIT_LOG")"
grep -q '"reason": "watchdog_disable"' "$AUDIT_LOG" || smoke_fail "P1 FAIL: the marker reason must be surfaced in the audit. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] && smoke_fail "P1 FAIL: marker must be consumed on confirmed recovery. still present=$MARKER_FILE"
smoke_log "P1 PASS: launchd disabled + matching non-upgrade-reason marker → re-enable + recover (reason surfaced, marker consumed)"

# ── P2: ★launchd DISABLED + NO marker → SKIP (operator-stop fail-closed) ───────
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "P2 FAIL: no skip_disabled audit. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P2 FAIL: must NOT enable a disabled job with no marker. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "P2 PASS: launchd disabled + NO marker → SKIP (operator-stop fail-closed; residual #2205 hole defaults closed)"

# ── P3: ★launchd DISABLED + marker for a DIFFERENT target → SKIP (cross-target) ─
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "ai.agent-bridge.SOME-OTHER-job" watchdog_disable   # FOREIGN target
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "P3 FAIL: a foreign-target marker must fail closed (skip_disabled). audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P3 FAIL (BLOCKER): a marker for ANOTHER job must NOT re-enable this one. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "P3 FAIL: a target-mismatch marker is not proof of THIS job's first-party disable. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "P3 FAIL: a non-matching marker must be left untouched. missing=$MARKER_FILE"
smoke_log "P3 PASS: launchd disabled + FOREIGN-target marker → SKIP (the cross-target tooth holds the operator-stop invariant)"

# ── P4: ★launchd DISABLED + marker PLATFORM=systemd → SKIP (platform mismatch) ─
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker systemd "$TEST_LABEL" watchdog_disable   # systemd marker, launchd job
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "P4 FAIL: a platform-mismatch marker must fail closed. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P4 FAIL (BLOCKER): a systemd marker must NOT re-enable a launchd job. calls=$(cat "$LAUNCHCTL_LOG")"
smoke_log "P4 PASS: launchd disabled + systemd-PLATFORM marker → SKIP (platform mismatch fail-closed)"

# ── P5: ★launchd UNKNOWN (print-disabled unreadable) + valid matching marker → SKIP
# (★Phase-4 r2 tri-state invariant): a marker proves the LAST first-party action was a
# disable, NOT the CURRENT state. If we cannot READ the live disabled-state we cannot
# rule out an operator RE-disable AFTER the marker, so we must FAIL CLOSED — skip,
# RETAIN the marker for a later readable poll, NO enable / NO bootstrap. (Pre-r2 this
# wrongly recovered on a valid marker regardless of probe readability — the bug
# Phase-4 r1 rejected.)
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '2' >"$DISABLED_RC_FILE"       # print-disabled FAILS (unknown)
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL" ensure_singleton_bootout
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_unknown_disabled || smoke_fail "P5 FAIL: an UNKNOWN disabled-probe must fail closed (skip_unknown_disabled), even with a valid marker. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P5 FAIL (BLOCKER): must NOT re-enable on an unreadable probe — a marker does not prove the CURRENT state. calls=$(cat "$LAUNCHCTL_LOG")"
launchctl_called bootstrap && smoke_fail "P5 FAIL (BLOCKER): must NOT bootstrap on an unreadable probe. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "P5 FAIL: an unknown probe is not a recovery, even with a marker. audit=$(cat "$AUDIT_LOG")"
[[ -f "$MARKER_FILE" ]] || smoke_fail "P5 FAIL: the marker must be RETAINED for a later readable poll. missing=$MARKER_FILE"
smoke_log "P5 PASS: launchd UNKNOWN probe + valid matching marker → SKIP + marker RETAINED (a marker proves the last action, not the current state; #2205 Phase-4 r2)"

# ── MP5: ★MUTATION for P5 — revert the tri-state split (make `unknown` re-enter the
# recovery path like `disabled` did pre-r2) → P5's unknown+marker case would START
# re-enabling. Proves the tri-state entry guard is load-bearing. Two edits revert it:
# neuter the unknown early-return guard (never matches) AND widen the disabled test to
# `!= enabled` so an unknown probe re-enters the marker/re-enable recovery (the old bug).
MUTATED_SRC="$REPO_ROOT/scripts/.2205-liveness-mut-p5.$$.sh"
sed -e 's/if \[\[ "\$disabled_state" == "unknown" \]\]; then/if false; then  # MUT unknown-guard neutered/' \
    -e 's/if \[\[ "\$disabled_state" == "disabled" \]\]; then/if [[ "$disabled_state" != "enabled" ]]; then  # MUT widened/' \
    "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q 'MUT unknown-guard neutered' "$MUTATED_SRC" || smoke_fail "MP5 FAIL: mutation did not neuter the unknown guard"
grep -q 'MUT widened' "$MUTATED_SRC" || smoke_fail "MP5 FAIL: mutation did not widen the disabled test"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '2' >"$DISABLED_RC_FILE"       # print-disabled FAILS (unknown)
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL" ensure_singleton_bootout
run_liveness Darwin "$MUTATED_SRC"
launchctl_called enable || smoke_fail "MP5 FAIL (vacuous!): with the unknown guard reverted, an unknown+marker case should re-enable, but it did not. calls=$(cat "$LAUNCHCTL_LOG")"
rm -f "$MUTATED_SRC"; MUTATED_SRC=""
smoke_log "MP5 PASS: MUTATION proven — reverting the tri-state split makes an unknown probe re-enable on a marker (P5's guard is load-bearing)"

# ── P6: ★launchd DISABLED + MALFORMED matching marker → SKIP (checked-source parse)
# The marker's early fields are valid+matching but its tail is broken shell. A
# checked single-source must fail closed — never re-enable on a marker that does
# not fully parse (codex r1: the per-field source ignored parse failures).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_malformed_marker "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "P6 FAIL: a malformed marker must fail closed (skip_disabled). audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P6 FAIL (BLOCKER): a marker that does not fully parse must NOT re-enable the job. calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "P6 FAIL: an unparseable marker is not proof. audit=$(cat "$AUDIT_LOG")"
smoke_log "P6 PASS: launchd disabled + MALFORMED matching marker → SKIP (checked-source parse fails closed; codex r1 hole closed)"

# ── P7: ★launchd DISABLED + OFF-SCHEMA matching marker → SKIP (strict-schema)
# The marker SOURCES cleanly (rc=0) and its recognized fields are valid+matching, but
# it carries an unexpected key. The checked-source alone would accept it; strict-schema
# validation must reject it (codex r2: source success is not sufficient proof).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_offschema_marker "$TEST_LABEL"
run_liveness Darwin
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "P7 FAIL: an off-schema marker must fail closed (skip_disabled). audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "P7 FAIL (BLOCKER): a marker with an unexpected key must NOT re-enable the job (source success is not proof). calls=$(cat "$LAUNCHCTL_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "P7 FAIL: an off-schema marker is not proof. audit=$(cat "$AUDIT_LOG")"
smoke_log "P7 PASS: launchd disabled + OFF-SCHEMA matching marker (sources OK but unexpected key) → SKIP (strict-schema fails closed; codex r2 hole closed)"

# ── MP6: ★MUTATION for P6 — neuter the checked-source rejection (drop the `|| exit 1`
# / `|| return 1` so a source error no longer fails closed) → P6's malformed marker
# would start re-enabling. Proves the checked-source is independently load-bearing.
MUTATED_SRC="$REPO_ROOT/scripts/.2205-liveness-mut-p6.$$.sh"
sed -e 's/source "\$marker" 2>\/dev\/null || exit 1/source "$marker" 2>\/dev\/null; true/' \
    -e 's/  )" || return 1/  )"/' "$LIVENESS_SRC" >"$MUTATED_SRC"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_malformed_marker "$TEST_LABEL"
run_liveness Darwin "$MUTATED_SRC"
launchctl_called enable || smoke_fail "MP6 FAIL (vacuous!): without the checked-source rejection a malformed marker should re-enable, but it did not. calls=$(cat "$LAUNCHCTL_LOG")"
rm -f "$MUTATED_SRC"; MUTATED_SRC=""
smoke_log "MP6 PASS: MUTATION proven — removing the checked-source rejection makes a malformed marker re-arm the job (P6's guard is independently load-bearing)"

# ── MP7: ★MUTATION for P7 — neuter the strict-schema `*) return 1` arm (accept any
# line) → P7's off-schema marker would start re-enabling. Proves the schema gate is
# independently load-bearing.
MUTATED_SRC="$REPO_ROOT/scripts/.2205-liveness-mut-p7.$$.sh"
sed 's/      \*) return 1 ;;   # off-schema line/      *) : ;;   # MUT off-schema line/' "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q '\*) : ;;   # MUT off-schema line' "$MUTATED_SRC" \
  || smoke_fail "MP7 FAIL: mutation did not neuter the strict-schema arm"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_offschema_marker "$TEST_LABEL"
run_liveness Darwin "$MUTATED_SRC"
launchctl_called enable || smoke_fail "MP7 FAIL (vacuous!): without the strict-schema arm an off-schema marker should re-enable, but it did not. calls=$(cat "$LAUNCHCTL_LOG")"
rm -f "$MUTATED_SRC"; MUTATED_SRC=""
smoke_log "MP7 PASS: MUTATION proven — removing the strict-schema arm makes an off-schema marker re-arm the job (P7's guard is independently load-bearing)"

# ── M1: ★MUTATION (target tooth) — neuter the target-match guard → P3's foreign
# marker STARTS re-enabling the operator-stopped job. Proves the cross-target
# guard is load-bearing (the test is non-vacuous).
MUTATED_SRC="$REPO_ROOT/scripts/.2205-liveness-mut-target.$$.sh"
# Drop the `[[ "$target" == "$want_target" ]] || return 1` line.
grep -v '\[\[ "\$target" == "\$want_target" \]\] || return 1' "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q '\[\[ "\$target" == "\$want_target" \]\] || return 1' "$MUTATED_SRC" \
  && smoke_fail "M1 FAIL: mutation did not remove the target-match guard"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "ai.agent-bridge.SOME-OTHER-job" watchdog_disable   # FOREIGN target
run_liveness Darwin "$MUTATED_SRC"
launchctl_called enable || smoke_fail "M1 FAIL (vacuous!): without the target guard a foreign-target marker should re-enable, but it did not. calls=$(cat "$LAUNCHCTL_LOG")"
rm -f "$MUTATED_SRC"; MUTATED_SRC=""
smoke_log "M1 PASS: MUTATION proven — removing the target-match guard makes a foreign marker re-arm an operator-stopped job (the guard is load-bearing)"

# ── M2: ★MUTATION (marker gate) — neuter the whole discriminator → P1's
# recoverable disable falls back to skip_disabled. Proves the marker gate recovers.
MUTATED_SRC="$REPO_ROOT/scripts/.2205-liveness-mut-gate.$$.sh"
sed 's/^non_operator_disable_marker() {/non_operator_disable_marker() { return 1 ; : OLD/' "$LIVENESS_SRC" >"$MUTATED_SRC"
grep -q 'non_operator_disable_marker() { return 1 ; : OLD' "$MUTATED_SRC" \
  || smoke_fail "M2 FAIL: mutation did not neuter the discriminator"
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
printf '1' >"$BOOTSTRAP_LOADS_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable   # valid matching marker
run_liveness Darwin "$MUTATED_SRC"
audit_has daemon_liveness_rebootstrap_skip_disabled || smoke_fail "M2 FAIL (vacuous!): without the discriminator a valid disable did NOT fall back to skip_disabled. audit=$(cat "$AUDIT_LOG")"
audit_has daemon_liveness_rebootstrap_interrupted_upgrade && smoke_fail "M2 FAIL: a neutered discriminator must NOT recover. audit=$(cat "$AUDIT_LOG")"
launchctl_called enable && smoke_fail "M2 FAIL: a neutered discriminator must NOT enable. calls=$(cat "$LAUNCHCTL_LOG")"
rm -f "$MUTATED_SRC"; MUTATED_SRC=""
smoke_log "M2 PASS: MUTATION proven — removing the marker discriminator leaves the recoverable disable down (the gate is what recovers)"

# ── DOCTOR: read-only visibility for an UNPROVABLE disabled-drift ──────────────
run_doctor() {
  local src="${1:-$DOCTOR_SRC}"
  PATH="$SHIM_DIR:$PATH" \
  BRIDGE_STATE_DIR="$STATE_DIR" \
  BRIDGE_UPGRADE_QUIESCE_MARKER_FILE="$MARKER_FILE" \
  python3 "$src" --json --detectors daemon-launchd-disabled-drift \
    >"$SMOKE_TMP_ROOT/doctor-out.json" 2>"$SMOKE_TMP_ROOT/doctor-err.txt"
}
doctor_has_drift() { grep -q '"daemon-launchd-disabled-drift"' "$SMOKE_TMP_ROOT/doctor-out.json" 2>/dev/null; }

# D1 — launchd disabled + daemon down + NO marker → the detector reports.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"          # not loaded
printf '1' >"$DISABLED_RC_FILE"       # DISABLED
run_doctor
doctor_has_drift || smoke_fail "D1 FAIL: an unprovable disabled-drift must be reported. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json") err=$(cat "$SMOKE_TMP_ROOT/doctor-err.txt")"
smoke_log "D1 PASS: doctor surfaces launchd disabled + no marker as daemon-launchd-disabled-drift (silent drift made visible)"

# D2 — ★launchd disabled + a MATCHING marker → NO finding (watcher owns it).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable   # matching → recoverable
run_doctor
doctor_has_drift && smoke_fail "D2 FAIL: a recoverable matching-marker drift must NOT be double-reported by the doctor. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
smoke_log "D2 PASS: doctor stays quiet on a matching-marker (watcher-recoverable) drift (no double-report)"

# D3 — ★DOCTOR MUTATION: neuter the marker carve-out → D2's matching-marker case
# STARTS reporting (the carve-out is load-bearing).
MUTATED_DOCTOR="$REPO_ROOT/.2205-doctor-mut.$$.py"
# Neuter the marker carve-out by forcing its matching test to never hold. The
# carve-out is the load-bearing branch that keeps the doctor quiet on a
# watcher-recoverable drift; if removed, D2's matching-marker case must report.
python3 - "$DOCTOR_SRC" "$MUTATED_DOCTOR" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "    if recoverable:\n        # The watcher can prove + recover this; not an unprovable drift.\n        return None"
assert needle in text, "carve-out branch not found for mutation"
text = text.replace(needle, "    if False and recoverable:\n        return None")
open(dst, "w", encoding="utf-8").write(text)
PY
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable
run_doctor "$MUTATED_DOCTOR"
doctor_has_drift || smoke_fail "D3 FAIL (vacuous!): without the carve-out a matching-marker drift should report, but it did not. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
rm -f "$MUTATED_DOCTOR"; MUTATED_DOCTOR=""
smoke_log "D3 PASS: DOCTOR MUTATION proven — removing the marker carve-out makes a recoverable drift report (the carve-out is load-bearing)"

# D4 — ★launchd disabled + OFF-SCHEMA matching marker → the detector REPORTS (codex
# r2: an off-schema marker — an unexpected key — is not proof of recoverability, so it
# must NOT suppress the finding; the doctor's strict-schema gate mirrors the watcher).
# (The doctor parses line-by-line, not via `source`, so its detectable-malformed case
# is the OFF-SCHEMA marker — an unknown key — not the unbalanced-quote one the watcher
# catches via source.)
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_offschema_marker "$TEST_LABEL"
run_doctor
doctor_has_drift || smoke_fail "D4 FAIL: an off-schema marker must NOT suppress the doctor finding (drift stays visible). out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
smoke_log "D4 PASS: doctor reports on an OFF-SCHEMA matching marker (an unexpected key is no proof; drift stays visible)"

# MD4 — ★MUTATION for D4: neuter the doctor's well-formedness gate (force
# marker_well_formed true unconditionally) → D4's off-schema marker would START
# suppressing the finding. Proves the well-formedness gate is independently load-bearing.
MUTATED_DOCTOR="$REPO_ROOT/.2205-doctor-mut-md4.$$.py"
python3 - "$DOCTOR_SRC" "$MUTATED_DOCTOR" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "                marker_well_formed = False\n                continue"
assert needle in text, "well-formedness reject branch not found for MD4 mutation"
text = text.replace(needle, "                marker_well_formed = True  # MUT\n                continue", 1)
open(dst, "w", encoding="utf-8").write(text)
PY
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_offschema_marker "$TEST_LABEL"
run_doctor "$MUTATED_DOCTOR"
doctor_has_drift && smoke_fail "MD4 FAIL (vacuous!): with the well-formedness gate neutered an off-schema marker should suppress, but the finding still fired. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
rm -f "$MUTATED_DOCTOR"; MUTATED_DOCTOR=""
smoke_log "MD4 PASS: MUTATION proven — neutering the well-formedness gate makes an off-schema marker suppress (D4's guard is independently load-bearing)"

# D5 — ★launchd disabled + matching marker but LIVE writer pid → the detector
# REPORTS (a live writer is not the watcher's dead-writer recoverable case; the
# watcher would defer, so the doctor must keep the drift visible).
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable "$$"   # LIVE writer (this smoke)
run_doctor
doctor_has_drift || smoke_fail "D5 FAIL: a LIVE-writer marker is not a dead-writer recoverable case; the doctor must report. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
smoke_log "D5 PASS: doctor reports on a LIVE-writer matching marker (only a DEAD-writer matching marker suppresses)"

# MD5 — ★MUTATION for D5: drop the `_pid_dead(marker_pid)` term from the recoverable
# predicate → D5's LIVE-writer marker would START suppressing. Proves the dead-writer
# requirement is independently load-bearing.
MUTATED_DOCTOR="$REPO_ROOT/.2205-doctor-mut-md5.$$.py"
python3 - "$DOCTOR_SRC" "$MUTATED_DOCTOR" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "        and _pid_dead(marker_pid)\n"
assert needle in text, "_pid_dead term not found for MD5 mutation"
text = text.replace(needle, "        and True  # MUT _pid_dead dropped\n", 1)
open(dst, "w", encoding="utf-8").write(text)
PY
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '1' >"$DISABLED_RC_FILE"
write_marker launchd "$TEST_LABEL" watchdog_disable "$$"   # LIVE writer
run_doctor "$MUTATED_DOCTOR"
doctor_has_drift && smoke_fail "MD5 FAIL (vacuous!): with the dead-writer requirement dropped a live-writer marker should suppress, but the finding still fired. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
rm -f "$MUTATED_DOCTOR"; MUTATED_DOCTOR=""
smoke_log "MD5 PASS: MUTATION proven — dropping the dead-writer requirement makes a live-writer marker suppress (D5's guard is independently load-bearing)"

# D6 — ★launchd UNKNOWN probe (print-disabled unreadable) + unloaded + valid
# dead-writer matching marker → the detector REPORTS (★Phase-4 r2 tri-state): the
# watcher fails closed on an unknown probe and will NOT recover, so the doctor must
# NOT suppress — even a perfect marker cannot prove the CURRENT state is recoverable.
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"             # not loaded (unloaded=True)
printf '2' >"$DISABLED_RC_FILE"          # print-disabled UNREADABLE (unknown)
write_marker launchd "$TEST_LABEL" watchdog_disable   # valid DEAD-writer matching marker
run_doctor
doctor_has_drift || smoke_fail "D6 FAIL: an UNKNOWN disabled-probe must NOT be suppressed by a marker (the watcher won't recover it). out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
smoke_log "D6 PASS: doctor reports on an UNKNOWN-probe drift even with a perfect marker (only POSITIVELY-readable disabled is the watcher's recoverable case; #2205 Phase-4 r2)"

# MD6 — ★MUTATION for D6: drop the `disabled_readable and disabled` requirement from
# the recoverable predicate → D6's unknown-probe case would START suppressing. Proves
# the positive-readable-disabled requirement is independently load-bearing.
MUTATED_DOCTOR="$REPO_ROOT/.2205-doctor-mut-md6.$$.py"
python3 - "$DOCTOR_SRC" "$MUTATED_DOCTOR" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "        disabled_readable\n        and disabled\n        and marker_well_formed"
assert needle in text, "positive-readable-disabled terms not found for MD6 mutation"
text = text.replace(needle, "        True  # MUT readable+disabled dropped\n        and marker_well_formed", 1)
open(dst, "w", encoding="utf-8").write(text)
PY
seed_stale_no_pid
printf '1' >"$PRINT_RC_FILE"
printf '2' >"$DISABLED_RC_FILE"          # unknown probe
write_marker launchd "$TEST_LABEL" watchdog_disable   # valid dead-writer marker
run_doctor "$MUTATED_DOCTOR"
doctor_has_drift && smoke_fail "MD6 FAIL (vacuous!): with the positive-readable-disabled requirement dropped an unknown-probe drift should suppress, but the finding still fired. out=$(cat "$SMOKE_TMP_ROOT/doctor-out.json")"
rm -f "$MUTATED_DOCTOR"; MUTATED_DOCTOR=""
smoke_log "MD6 PASS: MUTATION proven — dropping the positive-readable-disabled requirement makes an unknown-probe drift suppress (D6's guard is independently load-bearing)"

smoke_log "all non-operator disabled-drift self-heal tests PASS (#2205)"
