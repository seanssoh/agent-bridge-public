#!/usr/bin/env bash
# scripts/smoke/nudge-marker-recovery.sh — Issue #629 missing-marker recovery.
#
# Re-exec under bash 4+ (the literal "syrs-fi" subscript trick + declare -gA
# require it). Same bootstrap pattern as scripts/smoke/idle-counter-latch.sh.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:nudge-marker-recovery][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Standalone smoke (NOT registered in scripts/smoke-test.sh; invoke directly).
# Validates the bounded-retry recovery added to bridge_write_idle_ready_agents
# in lib/bridge-channels.sh:
#
#   T1: cycle 1 — marker missing, probe fails → counter=1, agent excluded.
#   T2: cycle 2 — same conditions → counter=2, agent excluded.
#   T3: cycle 3 — counter would reach max_retries=3 → synthetic idle-since
#       marker is created, counter cleared, agent INCLUDED in ready file.
#   T4: cycle 4 — probe restored to success, marker exists from T3 → agent
#       included; counter remains absent (no regression).
#   T5: clearing the idle marker (e.g. via bridge_agent_clear_idle_marker
#       on retire/sync) also drops the retries file so the next failure
#       starts fresh.
#
# Run: bash scripts/smoke/nudge-marker-recovery.sh

set -euo pipefail

SMOKE_NAME="nudge-marker-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# --- environment / stubs --------------------------------------------------

# Whether the next bridge_claude_session_try_mark_prompt_ready call should
# succeed. Tests flip this between cycles.
PROBE_SHOULD_SUCCEED=0

load_recovery_test_env() {
  # Stubs below are invoked indirectly by the library code we source; the
  # SC2329 ("never invoked") warnings are spurious for that pattern (same
  # treatment as scripts/smoke/idle-counter-latch.sh).
  # shellcheck disable=SC2329
  bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
  # shellcheck disable=SC2329
  bridge_die() { printf '[die] %s\n' "$*" >&2; exit 1; }
  # shellcheck disable=SC2329
  bridge_audit_log() { :; }
  # shellcheck disable=SC2329
  bridge_require_python() { :; }

  # Active-roster surface.
  # shellcheck disable=SC2329
  bridge_isolation_v2_active() { return 1; }
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR" "$BRIDGE_LOG_DIR"

  # Roster: one claude agent.
  # shellcheck disable=SC2034
  declare -gA BRIDGE_AGENT_ENGINE=()
  # shellcheck disable=SC2034
  declare -gA BRIDGE_AGENT_SESSION=()
  BRIDGE_AGENT_ENGINE["syrs-fi"]="claude"
  BRIDGE_AGENT_SESSION["syrs-fi"]="syrs-fi"
  # shellcheck disable=SC2034
  BRIDGE_AGENT_IDS=("syrs-fi")

  # shellcheck disable=SC2329
  bridge_agent_engine() { printf 'claude'; }
  # shellcheck disable=SC2329
  bridge_agent_session() { printf 'syrs-fi'; }
  # shellcheck disable=SC2329
  bridge_agent_is_active() { return 0; }

  # Source the helpers we exercise. bridge-state provides the path helpers
  # and the synthetic-marker writer (bridge_agent_mark_idle_now).
  # shellcheck source=lib/bridge-state.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-state.sh"
  # shellcheck source=lib/bridge-channels.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-channels.sh"

  # Re-stub bridge_audit_log AFTER sourcing libs — bridge-state.sh provides a
  # python-backed implementation that needs $BRIDGE_SCRIPT_DIR (unset in this
  # smoke fixture). We just need to confirm the call site fires; we don't
  # need to verify the audit row contents.
  # shellcheck disable=SC2329
  bridge_audit_log() { :; }

  # Probe stub: behaviour is controlled by PROBE_SHOULD_SUCCEED. When it
  # "succeeds" we mimic the real helper by writing the idle marker.
  # shellcheck disable=SC2329
  bridge_claude_session_try_mark_prompt_ready() {
    local agent="$1"
    if (( PROBE_SHOULD_SUCCEED == 1 )); then
      bridge_agent_mark_idle_now "$agent"
      return 0
    fi
    return 1
  }

  # Codex prompt probe (unused for our claude-only fixture, but the
  # function references it).
  # shellcheck disable=SC2329
  bridge_tmux_session_has_prompt() { return 0; }
}

# --- helpers --------------------------------------------------------------

run_cycle() {
  local out_file="$1"
  bridge_write_idle_ready_agents "$out_file"
}

assert_counter_eq() {
  local agent="$1" expected="$2" context="$3"
  local file
  file="$(bridge_agent_missing_marker_retries_file "$agent")"
  if [[ "$expected" == "absent" ]]; then
    if [[ -f "$file" ]]; then
      smoke_fail "$context: expected counter file absent, got $(cat "$file")"
    fi
    return 0
  fi
  smoke_assert_file_exists "$file" "$context: counter file"
  smoke_assert_eq "$expected" "$(cat "$file")" "$context"
}

# --- T1..T4: cycle progression -------------------------------------------

test_bounded_retry_progression() {
  load_recovery_test_env

  local agent="syrs-fi"
  local ready_file="$SMOKE_TMP_ROOT/ready.txt"

  # Pre-state: agent has no idle-since marker (simulating a turn that
  # aborted before mark-idle.sh fired).
  rm -rf "$(bridge_agent_idle_marker_dir "$agent")"

  # T1: cycle 1, probe fails → counter=1, agent excluded.
  PROBE_SHOULD_SUCCEED=0
  run_cycle "$ready_file"
  if grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "T1: agent should be excluded on first probe failure"
  fi
  assert_counter_eq "$agent" "1" "T1: counter after first failure"

  # T2: cycle 2, probe fails again → counter=2, agent still excluded.
  run_cycle "$ready_file"
  if grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "T2: agent should still be excluded on second probe failure"
  fi
  assert_counter_eq "$agent" "2" "T2: counter after second failure"

  # T3: cycle 3, probe fails reaches max_retries=3 → synthetic marker
  # written, counter cleared, agent INCLUDED.
  run_cycle "$ready_file"
  if ! grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "T3: agent should be INCLUDED after synthetic marker fallback"
  fi
  if ! bridge_agent_idle_marker_exists "$agent"; then
    smoke_fail "T3: synthetic idle-since marker should exist after fallback"
  fi
  assert_counter_eq "$agent" "absent" "T3: counter cleared after synthetic marker"

  # T4: cycle 4, marker exists (from T3), probe path not taken → agent
  # included via the normal idle_marker_exists branch.
  run_cycle "$ready_file"
  if ! grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "T4: agent should remain included once synthetic marker is in place"
  fi
  assert_counter_eq "$agent" "absent" "T4: counter still absent on healthy cycle"
}

# --- T5: clear_idle_marker drops the retries file ------------------------

test_clear_idle_marker_clears_counter() {
  load_recovery_test_env

  local agent="syrs-fi"
  local retries_file
  retries_file="$(bridge_agent_missing_marker_retries_file "$agent")"

  # Seed a stale counter (simulating partial progress through the bounded
  # retry window) then run the same cleanup path that retire/sync use.
  mkdir -p "$(bridge_agent_idle_marker_dir "$agent")"
  bridge_agent_mark_idle_now "$agent"
  printf '2\n' >"$retries_file"
  smoke_assert_file_exists "$retries_file" "T5 setup: counter seeded"

  bridge_agent_clear_idle_marker "$agent"

  if [[ -f "$retries_file" ]]; then
    smoke_fail "T5: bridge_agent_clear_idle_marker should drop the missing-marker retry counter"
  fi
  if bridge_agent_idle_marker_exists "$agent"; then
    smoke_fail "T5: bridge_agent_clear_idle_marker should also drop the idle-since marker"
  fi
}

# --- env override: BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS -------------------

test_max_retries_env_override() {
  load_recovery_test_env

  local agent="syrs-fi"
  local ready_file="$SMOKE_TMP_ROOT/ready-env.txt"

  rm -rf "$(bridge_agent_idle_marker_dir "$agent")"

  # Lower the threshold to 2 so the synthetic fallback fires on cycle 2.
  PROBE_SHOULD_SUCCEED=0
  BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS=2 run_cycle "$ready_file"
  if grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "env-override: agent should be excluded on cycle 1"
  fi
  assert_counter_eq "$agent" "1" "env-override: counter=1 after cycle 1"

  BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS=2 run_cycle "$ready_file"
  if ! grep -q "^${agent}$" "$ready_file"; then
    smoke_fail "env-override: agent should be INCLUDED on cycle 2 with max_retries=2"
  fi
  if ! bridge_agent_idle_marker_exists "$agent"; then
    smoke_fail "env-override: synthetic marker should exist on cycle 2 with max_retries=2"
  fi
  assert_counter_eq "$agent" "absent" "env-override: counter cleared on synthesis"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1..T4 (bounded retry → synthetic marker → steady state)" \
    test_bounded_retry_progression

  smoke_run "T5 (clear_idle_marker drops the retry counter)" \
    test_clear_idle_marker_clears_counter

  smoke_run "env override (BRIDGE_NUDGE_RECOVER_MAX_PROBE_FAILS=2)" \
    test_max_retries_env_override

  smoke_log "PASS: nudge-marker-recovery (#629 missing-marker bounded retry)"
}

main "$@"
