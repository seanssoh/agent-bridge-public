#!/usr/bin/env bash
# scripts/smoke/agent-create-name-validation.sh — Issue #526 smoke.
#
# Validates that `bridge-agent.sh create <name>` rejects names that look
# like CLI flags or reserved verbs before any roster mutation, and that
# `--help` short-circuits to the create usage banner. Six assertions:
#
# 1. `create --help` exits 0, prints usage, does NOT scaffold an agent.
# 2. `create -h` is treated the same way.
# 3. `create help` is rejected as a reserved name (and no scaffold).
# 4. `create ""` is rejected (Usage hint, no scaffold).
# 5. `create 'evil"name'` is rejected by the char-class regex (no scaffold).
# 6. Negative control: `create valid-worker --dry-run` succeeds and emits a
#    role block on stdout without mutating the local roster file.

set -euo pipefail

SMOKE_NAME="agent-create-name-validation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_create() {
  # Capture stdout+stderr together; never let a non-zero exit kill the test
  # before we assert on the captured text.
  bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
}

assert_no_scaffold() {
  local label="$1"
  local bad_name="$2"
  smoke_assert_eq "" "$(ls "$BRIDGE_AGENT_HOME_ROOT" 2>/dev/null || true)" \
    "$label: agents/ root stays empty (no '$bad_name' dir scaffolded)"
  if [[ -s "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
    smoke_assert_not_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" \
      "MANAGED ROLE: $bad_name" \
      "$label: local roster has no MANAGED ROLE block for '$bad_name'"
  fi
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

assert_help_short_circuit() {
  local flag="$1"
  reset_runtime
  local out
  out="$(run_create "$flag")"
  smoke_assert_contains "$out" "create <agent>" "create $flag prints usage banner"
  assert_no_scaffold "create $flag" "$flag"
}

assert_reserved_help_word() {
  reset_runtime
  local out
  out="$(run_create "help")"
  # `help` is a reserved bare verb, AND is also intercepted by the
  # help-first short-circuit in run_create — either way no scaffold.
  smoke_assert_contains "$out" "create <agent>" "create help short-circuits to usage"
  assert_no_scaffold "create help" "help"
}

assert_empty_name() {
  reset_runtime
  local out
  out="$(run_create "")"
  smoke_assert_contains "$out" "Usage:" "create '' surfaces Usage hint"
  assert_no_scaffold "create empty" ""
}

assert_metachar_name() {
  reset_runtime
  local out
  out="$(run_create 'evil"name')"
  smoke_assert_contains "$out" "에이전트 이름" "create 'evil\"name' rejected by validator"
  assert_no_scaffold "create metachar" 'evil"name'
}

assert_valid_dry_run() {
  reset_runtime
  local out
  out="$(run_create valid-worker --engine claude --dry-run)"
  smoke_assert_contains "$out" "agent: valid-worker" \
    "create valid-worker --dry-run echoes agent line"
  smoke_assert_contains "$out" "engine: claude" \
    "create valid-worker --dry-run echoes engine line"
  smoke_assert_contains "$out" "dry_run: yes" \
    "create valid-worker --dry-run flags itself as a plan, not a mutation"
  # --dry-run must not actually mutate the roster.
  if [[ -s "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
    smoke_assert_not_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" \
      "MANAGED ROLE: valid-worker" \
      "create valid-worker --dry-run does not mutate local roster"
  fi
  # And it must not have created a runtime home for the agent.
  [[ ! -d "$BRIDGE_AGENT_HOME_ROOT/valid-worker" ]] || \
    smoke_fail "create valid-worker --dry-run unexpectedly created agents/valid-worker/"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "create --help short-circuits"  assert_help_short_circuit --help
  smoke_run "create -h short-circuits"      assert_help_short_circuit -h
  smoke_run "create help reserved-word"     assert_reserved_help_word
  smoke_run "create '' rejected"            assert_empty_name
  smoke_run "create 'evil\"name' rejected"  assert_metachar_name
  smoke_run "create valid-worker --dry-run" assert_valid_dry_run

  smoke_log "PASS"
}

main "$@"
