#!/usr/bin/env bash
#
# scripts/smoke/mcp-liveness-giveup-auto-clear.sh — issue #1307
# (v0.15.0-beta5-1 Lane 3).
#
# Before this PR, `plugin_mcp_liveness_giveup` was a sticky terminal
# state. After 5 failed restart attempts (the giveup threshold added in
# #715 A), the daemon's nudge/wake path short-circuited indefinitely
# — even after the agent normalised (picker unblocked, activity_state
# → idle, MCP transient restored). The only recovery was a manual
# `agent-bridge agent restart` or `bridge-daemon.sh sync`. Operators
# perceived this as silent Teams message drop.
#
# Fix:
#   - Persist a GIVEUP=1 + GIVEUP_TS=<ts> ledger to the plugin-liveness
#     state file at the moment the giveup audit row fires.
#   - New tick step `process_mcp_liveness_giveup_recovery` runs every
#     daemon loop, drives an activity_state observer
#     (LAST_ACTIVITY_STATE), and triggers a read-only liveness recheck
#     on either (a) non-idle → idle transition, or (b)
#     BRIDGE_MCP_LIVENESS_GIVEUP_FALLBACK_SECS (default 300) elapsed
#     since the giveup ts.
#   - On success: emit `plugin_mcp_liveness_recovered`, clear giveup
#     ledger (RESTART_ATTEMPTS reset so the next miss gets a full
#     restart budget).
#   - On failure: emit `plugin_mcp_liveness_recheck_still_failed`,
#     re-arm GIVEUP_TS=now (slides the fallback window).
#
# Cases (all run in an isolated BRIDGE_HOME via scripts/smoke/lib.sh —
# never touches live runtime).
#
#   T1. Activity-state trigger: synth giveup ledger + a non-idle prev
#       LAST_ACTIVITY_STATE. Stub `bridge_recheck_mcp_liveness` to
#       success. Run the recovery tick. Assert giveup ledger cleared
#       AND `plugin_mcp_liveness_recovered` audit row emitted with
#       `trigger=activity_idle`.
#
#   T2. Fallback timer trigger: synth giveup ledger with GIVEUP_TS far
#       in the past (>fallback_secs ago). prev_state == idle (no
#       transition). Stub recheck to success. Assert recovery fires
#       on the fallback path: giveup cleared + `recovered` audit row
#       with `trigger=fallback_timer`.
#
#   T3. Recheck still fails: synth giveup ledger, non-idle → idle
#       transition. Stub recheck to FAILURE. Assert giveup NOT cleared,
#       audit row is `plugin_mcp_liveness_recheck_still_failed`, AND
#       GIVEUP_TS is bumped to "now" (re-armed).
#
#   T4 (teeth). With the new tick step's body neutered (replaced with a
#       no-op), giveup persists indefinitely — the activity_state
#       transition has NO observable effect. This proves the smoke
#       catches a regression that removes the recovery tick. Only
#       executed when SMOKE_TEETH=1 so the main flow stays clean.
#
#   T5. Back-compat / no-giveup baseline: agent with no GIVEUP ledger
#       runs through the tick. Assert recovery does NOT fire (no
#       recheck stub called, no audit row emitted) — only the
#       activity_state observer updates LAST_ACTIVITY_STATE.
#
#   T_production_order. End-to-end ordering test (codex r1 BLOCKING
#       repro). Seed giveup ledger + a non-idle prev LAST_ACTIVITY_STATE.
#       Stub missing-MCP-CSV probe to "" (recovered) AND stub
#       bridge_recheck_mcp_liveness to success. Run the FULL daemon
#       tick steps in production order
#       (`process_mcp_liveness_giveup_recovery`, then
#       `process_plugin_liveness`). Assert
#       `plugin_mcp_liveness_recovered` audit row was emitted BEFORE
#       the silent-clear path in `bridge_report_plugin_liveness_miss`
#       could wipe the ledger. This catches the r1 bypass class.
#
#   T_production_order_teeth (opt-in SMOKE_TEETH=1). Revert ordering
#       proof: run `process_plugin_liveness` FIRST (the pre-r2 order).
#       Assert the silent clear deletes GIVEUP/GIVEUP_TS BEFORE
#       recovery can emit the audit row — proving the smoke catches
#       the regression. Without the guard helper in r2, the silent
#       clear deletes the ledger and the audit log is empty.
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess —
# helper bodies are extracted with awk + emitted via printf-to-file.

_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:mcp-liveness-giveup-auto-clear] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="mcp-liveness-giveup-auto-clear"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="test_clean"

# Resolve a Bash 4+ interpreter for inner `bash <driver>` invocations.
BRIDGE_BASH="${BASH4_BIN:-}"
if [[ -z "$BRIDGE_BASH" || ! -x "$BRIDGE_BASH" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  else
    BRIDGE_BASH="$(command -v bash)"
  fi
fi
"$BRIDGE_BASH" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1 || \
  smoke_fail "Bash 4+ interpreter not found (BASH4_BIN=${BASH4_BIN:-unset}); install homebrew bash"

# State file path matches bridge_plugin_liveness_state_file.
STATE_FILE="$BRIDGE_STATE_DIR/plugin-liveness/$AGENT.env"
mkdir -p "$(dirname "$STATE_FILE")"

# Extract just the helpers we need from bridge-daemon.sh — kept in
# lockstep with the production functions. The smoke replicates a
# minimal tick to assert recovery semantics without depending on the
# full daemon loop / roster loader / tmux probes.
HELPERS_FUNCS="$SMOKE_TMP_ROOT/helpers.sh"
{
  awk '
    /^bridge_plugin_liveness_state_file\(\) \{/      { capture=1 }
    /^bridge_clear_plugin_liveness_state\(\) \{/      { capture=1 }
    /^bridge_clear_plugin_liveness_state_if_no_giveup\(\) \{/ { capture=1 }
    /^bridge_note_plugin_liveness_state\(\) \{/       { capture=1 }
    /^bridge_agent_mcp_giveup_arm\(\) \{/             { capture=1 }
    /^bridge_agent_mcp_giveup_active\(\) \{/          { capture=1 }
    /^bridge_agent_mcp_giveup_ts\(\) \{/              { capture=1 }
    /^bridge_agent_mcp_giveup_clear\(\) \{/           { capture=1 }
    /^bridge_agent_mcp_note_activity_state\(\) \{/    { capture=1 }
    /^bridge_report_plugin_liveness_miss\(\) \{/      { capture=1 }
    /^process_plugin_liveness\(\) \{/                 { capture=1 }
    /^process_mcp_liveness_giveup_recovery\(\) \{/    { capture=1 }
    /^daemon_source_state_file\(\) \{/                { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/bridge-daemon.sh"
} >"$HELPERS_FUNCS"

for fn in bridge_plugin_liveness_state_file \
          bridge_clear_plugin_liveness_state \
          bridge_clear_plugin_liveness_state_if_no_giveup \
          bridge_note_plugin_liveness_state \
          bridge_agent_mcp_giveup_arm \
          bridge_agent_mcp_giveup_active \
          bridge_agent_mcp_giveup_ts \
          bridge_agent_mcp_giveup_clear \
          bridge_agent_mcp_note_activity_state \
          bridge_report_plugin_liveness_miss \
          process_plugin_liveness \
          process_mcp_liveness_giveup_recovery \
          daemon_source_state_file; do
  if ! grep -q "^${fn}() {" "$HELPERS_FUNCS"; then
    smoke_fail "extract failed: helper $fn not found in $HELPERS_FUNCS"
  fi
done

# build_driver <recheck-rc> <cur-activity-state> <teeth> > driver.sh
#   recheck-rc: 0 = recheck-success, 1 = recheck-fail
#   cur-activity-state: idle|working|picker_block|...
#   teeth: 1 = replace process_mcp_liveness_giveup_recovery body with a
#          no-op (T4 regression-proof)
build_driver() {
  local driver_path="$1"
  local recheck_rc="$2"
  local cur_state="$3"
  local teeth="${4:-0}"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"
    # bridge_audit_log → append a JSON-ish line to the audit log so the
    # smoke can grep for `plugin_mcp_liveness_recovered` /
    # `plugin_mcp_liveness_recheck_still_failed` rows.
    printf 'bridge_audit_log() {\n'
    printf '  local actor="$1"; local action="$2"; local target="$3"; shift 3\n'
    printf '  local details=""\n'
    printf '  while (( $# > 0 )); do\n'
    printf '    case "$1" in\n'
    printf '      --detail) details="${details} $2"; shift 2;;\n'
    printf '      *) shift;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '  printf "actor=%%s action=%%s target=%%s%%s\\n" \\\n'
    printf '    "$actor" "$action" "$target" "$details" \\\n'
    printf '    >>"$BRIDGE_AUDIT_LOG"\n'
    printf '}\n'
    printf 'daemon_info() { :; }\n'
    printf 'daemon_warn() { :; }\n'
    printf 'bridge_require_python() { :; }\n'
    # Stub the probe helpers process_mcp_liveness_giveup_recovery calls.
    printf 'bridge_agent_heartbeat_activity_state() { printf "%%s" "%s"; }\n' "$cur_state"
    printf 'bridge_recheck_mcp_liveness() { return %s; }\n' "$recheck_rc"
    printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf "%%s" "plugin:teams@agent-bridge"; }\n'
    printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
    printf 'source "%s"\n' "$HELPERS_FUNCS"
    if [[ "$teeth" == "1" ]]; then
      # Teeth proof: replace the production tick body with a no-op so the
      # observer + recheck wiring is gone. T4 asserts giveup PERSISTS
      # under this stub — proving the smoke catches a regression that
      # removes the tick.
      printf 'process_mcp_liveness_giveup_recovery() { :; }\n'
    fi
    printf 'process_mcp_liveness_giveup_recovery\n'
  } >"$driver_path"
}

# build_driver_production_order <driver_path> <recheck-rc> <cur-activity-state> <reorder>
#   Wraps the FULL production sequence: process_mcp_liveness_giveup_recovery
#   then process_plugin_liveness (when reorder=1 — r2 fix order), or
#   process_plugin_liveness then process_mcp_liveness_giveup_recovery
#   (when reorder=0 — pre-r2 order, used for the teeth test).
#
#   recheck-rc: 0 = MCP probe recovered, 1 = still missing.
#   cur-activity-state: idle | working | picker_block | ...
#   reorder: 1 = recovery-first (r2 production order)
#            0 = liveness-first (pre-r2 order — teeth)
#
# Stubs bridge_report_plugin_liveness_miss's dependencies so the
# function reaches the "missing CSV empty" silent-clear branch (the
# specific branch codex r1 used to wipe the giveup ledger).
build_driver_production_order() {
  local driver_path="$1"
  local recheck_rc="$2"
  local cur_state="$3"
  local reorder="${4:-1}"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"
    printf 'bridge_audit_log() {\n'
    printf '  local actor="$1"; local action="$2"; local target="$3"; shift 3\n'
    printf '  local details=""\n'
    printf '  while (( $# > 0 )); do\n'
    printf '    case "$1" in\n'
    printf '      --detail) details="${details} $2"; shift 2;;\n'
    printf '      *) shift;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '  printf "actor=%%s action=%%s target=%%s%%s\\n" \\\n'
    printf '    "$actor" "$action" "$target" "$details" \\\n'
    printf '    >>"$BRIDGE_AUDIT_LOG"\n'
    printf '}\n'
    printf 'daemon_info() { :; }\n'
    printf 'daemon_warn() { :; }\n'
    printf 'bridge_require_python() { :; }\n'
    # Stubs for bridge_report_plugin_liveness_miss prerequisites — all
    # return the "agent is healthy, has a session, has required CSV"
    # path so the function reaches the missing-CSV silent-clear branch.
    printf 'bridge_agent_source() { printf "static"; }\n'
    printf 'bridge_agent_engine() { printf "claude"; }\n'
    printf 'bridge_agent_channel_status() { printf "ok"; }\n'
    printf 'bridge_agent_session() { printf "test-session"; }\n'
    printf 'bridge_tmux_session_exists() { return 0; }\n'
    printf 'bridge_agent_effective_launch_plugin_channels_csv() { printf "plugin:teams@agent-bridge"; }\n'
    # CRITICAL — empty missing CSV reaches the silent-clear branch.
    printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf ""; }\n'
    printf 'bridge_sha1() { printf "deadbeef"; }\n'
    printf 'bridge_with_timeout() { shift; "$@"; }\n'
    printf 'daemon_agent_restart_mcp() { return 0; }\n'
    printf 'bridge_trim_whitespace() { printf "%%s" "$1"; }\n'
    printf 'bridge_tmux_session_attached_count() { printf "0"; }\n'
    # Recovery-tick probes.
    printf 'bridge_agent_heartbeat_activity_state() { printf "%%s" "%s"; }\n' "$cur_state"
    printf 'bridge_recheck_mcp_liveness() { return %s; }\n' "$recheck_rc"
    printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
    printf 'source "%s"\n' "$HELPERS_FUNCS"
    # Production order — recovery FIRST when reorder=1 (r2 fix),
    # liveness FIRST when reorder=0 (pre-r2 teeth proof).
    if [[ "$reorder" == "1" ]]; then
      printf 'process_mcp_liveness_giveup_recovery\n'
      printf 'process_plugin_liveness\n'
    else
      printf 'process_plugin_liveness\n'
      printf 'process_mcp_liveness_giveup_recovery\n'
    fi
  } >"$driver_path"
}

# seed_giveup <giveup_ts> <prev_activity_state>
seed_giveup() {
  local giveup_ts="$1"
  local prev_state="$2"
  rm -f "$STATE_FILE"
  {
    printf 'LAST_KEY=%s\n' "deadbeef"
    printf 'LAST_DETECTED_TS=%s\n' "1700000000"
    printf 'LAST_RESTART_TS=%s\n' "1700000010"
    # restart_attempts == max_restarts + 1 (the sentinel value the
    # production giveup branch bumps to after emitting the audit).
    printf 'RESTART_ATTEMPTS=6\n'
    printf 'GIVEUP=1\n'
    printf 'GIVEUP_TS=%s\n' "$giveup_ts"
    printf 'LAST_ACTIVITY_STATE=%s\n' "$prev_state"
  } >"$STATE_FILE"
}

assert_state_field() {
  local field="$1"
  local expected="$2"
  local context="$3"
  local got=""
  if [[ -f "$STATE_FILE" ]]; then
    got="$(sed -n "s/^${field}=//p" "$STATE_FILE" | head -n 1 | sed "s/^'//;s/'$//")"
  fi
  smoke_assert_eq "$expected" "$got" "$context: ${field}"
}

assert_state_field_missing() {
  local field="$1"
  local context="$2"
  if [[ ! -f "$STATE_FILE" ]]; then
    return 0
  fi
  if grep -q "^${field}=" "$STATE_FILE"; then
    smoke_fail "$context: state file unexpectedly carries ${field}: $(grep "^${field}=" "$STATE_FILE")"
  fi
}

audit_grep() {
  local needle="$1"
  grep -F "$needle" "$SMOKE_TMP_ROOT/audit.jsonl" 2>/dev/null || true
}

reset_audit() {
  : >"$SMOKE_TMP_ROOT/audit.jsonl"
}

# ---------------------------------------------------------------------------
# T1 — activity_state transition triggers recovery on recheck success.
# ---------------------------------------------------------------------------
smoke_log "T1: activity_state non-idle → idle triggers recovery"
seed_giveup 1700000000 "picker_block"
reset_audit
DRIVER_T1="$SMOKE_TMP_ROOT/t1-driver.sh"
build_driver "$DRIVER_T1" 0 "idle" 0
"$BRIDGE_BASH" "$DRIVER_T1" \
  || smoke_fail "T1: driver exited non-zero"

# Recovered audit row emitted with the right trigger.
audit_t1="$(audit_grep "plugin_mcp_liveness_recovered")"
[[ -n "$audit_t1" ]] || smoke_fail "T1: no plugin_mcp_liveness_recovered audit row"
smoke_assert_contains "$audit_t1" "trigger=activity_idle" \
  "T1: recovered audit row carries trigger=activity_idle"
smoke_assert_contains "$audit_t1" "prev_activity_state=picker_block" \
  "T1: recovered audit row records the prev activity_state"

# Giveup cleared — file exists but has no GIVEUP/GIVEUP_TS, only the
# preserved LAST_ACTIVITY_STATE.
assert_state_field_missing "GIVEUP" "T1: GIVEUP must be removed"
assert_state_field_missing "GIVEUP_TS" "T1: GIVEUP_TS must be removed"
assert_state_field_missing "RESTART_ATTEMPTS" "T1: RESTART_ATTEMPTS must be reset (file rewritten)"
assert_state_field "LAST_ACTIVITY_STATE" "idle" "T1: LAST_ACTIVITY_STATE persists across clear"
smoke_log "T1 PASS — activity_idle trigger clears giveup + emits recovered audit row"

# ---------------------------------------------------------------------------
# T2 — fallback timer triggers recovery when no activity transition observed.
# ---------------------------------------------------------------------------
smoke_log "T2: fallback timer triggers recovery after BRIDGE_MCP_LIVENESS_GIVEUP_FALLBACK_SECS"
# Seed with prev_state=idle (no transition) and giveup_ts far in the past.
seed_giveup 1 "idle"
reset_audit
# Use a small fallback so the smoke doesn't have to wait. Default is 300s.
DRIVER_T2="$SMOKE_TMP_ROOT/t2-driver.sh"
build_driver "$DRIVER_T2" 0 "idle" 0
# Export the env override so the recovery tick picks it up. The driver
# inherits the env.
BRIDGE_MCP_LIVENESS_GIVEUP_FALLBACK_SECS=1 \
  "$BRIDGE_BASH" "$DRIVER_T2" \
  || smoke_fail "T2: driver exited non-zero"

audit_t2="$(audit_grep "plugin_mcp_liveness_recovered")"
[[ -n "$audit_t2" ]] || smoke_fail "T2: no plugin_mcp_liveness_recovered audit row"
smoke_assert_contains "$audit_t2" "trigger=fallback_timer" \
  "T2: recovered audit row carries trigger=fallback_timer"
assert_state_field_missing "GIVEUP" "T2: GIVEUP cleared"
assert_state_field_missing "GIVEUP_TS" "T2: GIVEUP_TS cleared"
smoke_log "T2 PASS — fallback timer triggers recovery without transition"

# ---------------------------------------------------------------------------
# T3 — recheck still fails: re-arm GIVEUP_TS, NOT cleared.
# ---------------------------------------------------------------------------
smoke_log "T3: recheck-still-fails re-arms GIVEUP_TS without clearing"
seed_giveup 1700000000 "picker_block"
reset_audit
DRIVER_T3="$SMOKE_TMP_ROOT/t3-driver.sh"
build_driver "$DRIVER_T3" 1 "idle" 0
"$BRIDGE_BASH" "$DRIVER_T3" \
  || smoke_fail "T3: driver exited non-zero"

audit_t3="$(audit_grep "plugin_mcp_liveness_recheck_still_failed")"
[[ -n "$audit_t3" ]] || smoke_fail "T3: no plugin_mcp_liveness_recheck_still_failed audit row"
smoke_assert_contains "$audit_t3" "missing_channels=plugin:teams@agent-bridge" \
  "T3: still-failed audit row records the missing channel CSV"

# GIVEUP still set, GIVEUP_TS bumped to a fresh value (NOT the old 1700000000).
assert_state_field "GIVEUP" "1" "T3: GIVEUP must remain set"
old_ts=1700000000
new_ts="$(sed -n 's/^GIVEUP_TS=//p' "$STATE_FILE" | head -n 1 | sed "s/^'//;s/'$//")"
if [[ -z "$new_ts" ]]; then
  smoke_fail "T3: GIVEUP_TS missing after re-arm"
fi
if (( new_ts <= old_ts )); then
  smoke_fail "T3: GIVEUP_TS must be re-armed to a newer ts; got new=$new_ts old=$old_ts"
fi
# Should not have emitted a recovered row.
recovered_t3="$(audit_grep "plugin_mcp_liveness_recovered")"
[[ -z "$recovered_t3" ]] || smoke_fail "T3: spurious recovered audit row when recheck failed: $recovered_t3"
smoke_log "T3 PASS — recheck-still-fails re-arms GIVEUP_TS, keeps GIVEUP=1, emits still_failed row"

# ---------------------------------------------------------------------------
# T5 — back-compat: agent with no giveup ledger runs through without firing.
# ---------------------------------------------------------------------------
smoke_log "T5: no-giveup agent runs the observer tick without recovery firing"
rm -f "$STATE_FILE"
reset_audit
DRIVER_T5="$SMOKE_TMP_ROOT/t5-driver.sh"
build_driver "$DRIVER_T5" 0 "idle" 0
"$BRIDGE_BASH" "$DRIVER_T5" \
  || smoke_fail "T5: driver exited non-zero"

audit_t5="$(audit_grep "plugin_mcp_liveness_recovered")"
[[ -z "$audit_t5" ]] || smoke_fail "T5: spurious recovered audit row for no-giveup agent: $audit_t5"
audit_t5b="$(audit_grep "plugin_mcp_liveness_recheck_still_failed")"
[[ -z "$audit_t5b" ]] || smoke_fail "T5: spurious still_failed audit row for no-giveup agent: $audit_t5b"

# Observer should have written LAST_ACTIVITY_STATE for the agent.
assert_state_field "LAST_ACTIVITY_STATE" "idle" \
  "T5: LAST_ACTIVITY_STATE written even when no giveup is active"
smoke_log "T5 PASS — no-giveup baseline writes activity-state anchor only"

# ---------------------------------------------------------------------------
# T_production_order — codex r1 BLOCKING repro. End-to-end ordering test:
# with giveup armed AND a recovered MCP probe, the FULL daemon tick
# (recovery first → plugin_liveness second) must emit the
# `plugin_mcp_liveness_recovered` audit row BEFORE the silent-clear path
# in bridge_report_plugin_liveness_miss can wipe the ledger.
# ---------------------------------------------------------------------------
smoke_log "T_production_order: r2 order (recovery→liveness) emits audit before silent-clear can wipe ledger"
seed_giveup 1700000000 "picker_block"
reset_audit
DRIVER_TP="$SMOKE_TMP_ROOT/tp-driver.sh"
build_driver_production_order "$DRIVER_TP" 0 "idle" 1
"$BRIDGE_BASH" "$DRIVER_TP" \
  || smoke_fail "T_production_order: driver exited non-zero"

audit_tp="$(audit_grep "plugin_mcp_liveness_recovered")"
[[ -n "$audit_tp" ]] || smoke_fail "T_production_order: no plugin_mcp_liveness_recovered audit row — silent-clear bypass not closed"
smoke_assert_contains "$audit_tp" "trigger=activity_idle" \
  "T_production_order: recovered audit row carries trigger=activity_idle"
smoke_assert_contains "$audit_tp" "prev_activity_state=picker_block" \
  "T_production_order: recovered audit row records prev activity_state"
# After the full tick, giveup is cleared (recovery's giveup_clear plus
# liveness's silent clear both ran). State file may or may not exist
# depending on which path ran last — what matters is GIVEUP is gone.
assert_state_field_missing "GIVEUP" "T_production_order: GIVEUP cleared after full tick"
assert_state_field_missing "GIVEUP_TS" "T_production_order: GIVEUP_TS cleared after full tick"
smoke_log "T_production_order PASS — recovery emits audit before silent-clear"

# ---------------------------------------------------------------------------
# T_production_order_teeth — revert ordering proof. With the pre-r2
# order (plugin_liveness first → recovery second), the silent-clear path
# wipes GIVEUP/GIVEUP_TS BEFORE recovery can read them. Without the
# bridge_clear_plugin_liveness_state_if_no_giveup guard, the ledger is
# gone, recovery sees giveup_active=false, and the audit row is NEVER
# emitted. Only runs when SMOKE_TEETH=1 so the main flow stays clean.
# ---------------------------------------------------------------------------
if [[ "${SMOKE_TEETH:-0}" == "1" ]]; then
  # Two teeth tests:
  #   (a) Guard intact + pre-r2 order. The guard alone preserves the
  #       ledger so the recovery tick (running second) still sees
  #       GIVEUP=1 and emits the audit row. Asserts the defense-in-
  #       depth guard alone is sufficient.
  #   (b) Guard reverted (silent clear bypasses the guard) + pre-r2
  #       order. Both fixes are gone; the silent clear deletes the
  #       ledger before recovery can run. Asserts the audit row is
  #       MISSING — this is the codex r1 BLOCKING repro.
  smoke_log "T_production_order_teeth (a): pre-r2 order + guard intact → audit still emitted"
  seed_giveup 1700000000 "picker_block"
  reset_audit
  DRIVER_TP_TEETH_A="$SMOKE_TMP_ROOT/tp-teeth-a-driver.sh"
  build_driver_production_order "$DRIVER_TP_TEETH_A" 0 "idle" 0
  "$BRIDGE_BASH" "$DRIVER_TP_TEETH_A" \
    || smoke_fail "T_production_order_teeth (a): driver exited non-zero"
  audit_tp_teeth_a="$(audit_grep "plugin_mcp_liveness_recovered")"
  [[ -n "$audit_tp_teeth_a" ]] || smoke_fail \
    "T_production_order_teeth (a): with guard helper, pre-r2 order should STILL emit recovered audit row"
  smoke_log "T_production_order_teeth (a) PASS — guard alone preserves ledger under reverted ordering"

  smoke_log "T_production_order_teeth (b): pre-r2 order + guard REVERTED → audit MUST be missing (codex r1 BLOCKING repro)"
  seed_giveup 1700000000 "picker_block"
  reset_audit
  DRIVER_TP_TEETH_B="$SMOKE_TMP_ROOT/tp-teeth-b-driver.sh"
  # Build a fresh driver that runs in pre-r2 order WITH the guard helper
  # overridden to the unguarded clear — both fixes simultaneously
  # reverted. Use the build_driver_production_order primitive but
  # append the guard override AFTER the function calls would have run
  # — wait, that won't work because Bash function defs are early-bound.
  # Solution: build the driver manually with the same stubs and the
  # guard override BEFORE the function calls.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"
    printf 'bridge_audit_log() {\n'
    printf '  local actor="$1"; local action="$2"; local target="$3"; shift 3\n'
    printf '  local details=""\n'
    printf '  while (( $# > 0 )); do\n'
    printf '    case "$1" in\n'
    printf '      --detail) details="${details} $2"; shift 2;;\n'
    printf '      *) shift;;\n'
    printf '    esac\n'
    printf '  done\n'
    printf '  printf "actor=%%s action=%%s target=%%s%%s\\n" \\\n'
    printf '    "$actor" "$action" "$target" "$details" \\\n'
    printf '    >>"$BRIDGE_AUDIT_LOG"\n'
    printf '}\n'
    printf 'daemon_info() { :; }\n'
    printf 'daemon_warn() { :; }\n'
    printf 'bridge_require_python() { :; }\n'
    printf 'bridge_agent_source() { printf "static"; }\n'
    printf 'bridge_agent_engine() { printf "claude"; }\n'
    printf 'bridge_agent_channel_status() { printf "ok"; }\n'
    printf 'bridge_agent_session() { printf "test-session"; }\n'
    printf 'bridge_tmux_session_exists() { return 0; }\n'
    printf 'bridge_agent_effective_launch_plugin_channels_csv() { printf "plugin:teams@agent-bridge"; }\n'
    printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf ""; }\n'
    printf 'bridge_sha1() { printf "deadbeef"; }\n'
    printf 'bridge_with_timeout() { shift; "$@"; }\n'
    printf 'daemon_agent_restart_mcp() { return 0; }\n'
    printf 'bridge_trim_whitespace() { printf "%%s" "$1"; }\n'
    printf 'bridge_tmux_session_attached_count() { printf "0"; }\n'
    printf 'bridge_agent_heartbeat_activity_state() { printf "idle"; }\n'
    printf 'bridge_recheck_mcp_liveness() { return 0; }\n'
    printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
    printf 'source "%s"\n' "$HELPERS_FUNCS"
    # Override the guard back to the unguarded clear — Bash late binds
    # function names, so a later redefinition shadows the earlier one.
    printf 'bridge_clear_plugin_liveness_state_if_no_giveup() { bridge_clear_plugin_liveness_state "$1"; }\n'
    # Pre-r2 order — liveness first, recovery second.
    printf 'process_plugin_liveness\n'
    printf 'process_mcp_liveness_giveup_recovery\n'
  } >"$DRIVER_TP_TEETH_B"
  "$BRIDGE_BASH" "$DRIVER_TP_TEETH_B" \
    || smoke_fail "T_production_order_teeth (b): driver exited non-zero"
  audit_tp_teeth_b="$(audit_grep "plugin_mcp_liveness_recovered")"
  [[ -z "$audit_tp_teeth_b" ]] || smoke_fail \
    "T_production_order_teeth (b): audit row was emitted when BOTH fixes reverted; smoke does NOT catch the regression: $audit_tp_teeth_b"
  smoke_log "T_production_order_teeth (b) PASS — audit MISSING when both fixes reverted (smoke would catch the regression)"
fi

# ---------------------------------------------------------------------------
# T_teeth — revert proof (opt-in via SMOKE_TEETH=1).
# ---------------------------------------------------------------------------
if [[ "${SMOKE_TEETH:-0}" == "1" ]]; then
  smoke_log "T_teeth: with recovery tick stubbed to no-op, giveup MUST persist"
  seed_giveup 1700000000 "picker_block"
  reset_audit
  DRIVER_TEETH="$SMOKE_TMP_ROOT/teeth-driver.sh"
  build_driver "$DRIVER_TEETH" 0 "idle" 1
  "$BRIDGE_BASH" "$DRIVER_TEETH" \
    || smoke_fail "T_teeth: driver exited non-zero"

  audit_teeth="$(audit_grep "plugin_mcp_liveness_recovered")"
  [[ -z "$audit_teeth" ]] || smoke_fail "T_teeth FAIL — recovered audit row emitted under no-op stub"
  assert_state_field "GIVEUP" "1" "T_teeth: GIVEUP MUST persist when tick is neutered"
  assert_state_field "GIVEUP_TS" "1700000000" "T_teeth: GIVEUP_TS unchanged"
  smoke_log "T_teeth PASS — neutered tick leaves giveup sticky (regression proof)"
fi

smoke_log "OK $SMOKE_NAME"
