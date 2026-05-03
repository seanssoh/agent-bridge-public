#!/usr/bin/env bash
# scripts/smoke/agent-create-name-validation.sh — Issue #526 smoke.
#
# Validates that `bridge-agent.sh create <name>` rejects names that look
# like CLI flags or reserved verbs before any roster mutation, and that
# `--help` short-circuits to the create usage banner. Seven assertions:
#
# 1. `create --help` exits 0, prints usage, does NOT scaffold an agent.
# 2. `create -h` is treated the same way.
# 3. `create version` is rejected as a reserved name (and no scaffold).
#    `version` is on the reserved list but — unlike `help` — is NOT
#    intercepted by the help-first short-circuit, so it actually exercises
#    the reserved-name branch in bridge_validate_agent_name.
# 4. `create ""` is rejected (Usage hint, no scaffold).
# 5. `create 'evil"name'` is rejected by the char-class regex (no scaffold).
# 6. Positive control: `create 9worker --dry-run` succeeds, locking in the
#    intentional regex loosening that allows numeric-start names.
# 7. Negative control: `create valid-worker --dry-run` succeeds and emits a
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

assert_reserved_version_word() {
  reset_runtime
  local out
  out="$(run_create "version")"
  # `version` is on the reserved-name list but is NOT intercepted by the
  # help-first short-circuit (which only handles -h/--help/help), so this
  # actually exercises the reserved-name branch of the validator.
  smoke_assert_contains "$out" "예약어" "create version rejected by reserved-name validator"
  assert_no_scaffold "create version" "version"
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

assert_numeric_start_dry_run() {
  reset_runtime
  local out
  out="$(run_create 9worker --engine claude --dry-run)"
  smoke_assert_contains "$out" "agent: 9worker" \
    "create 9worker --dry-run accepted (numeric-start regex loosening)"
  smoke_assert_contains "$out" "dry_run: yes" \
    "create 9worker --dry-run flags itself as a plan, not a mutation"
  if [[ -s "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
    smoke_assert_not_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" \
      "MANAGED ROLE: 9worker" \
      "create 9worker --dry-run does not mutate local roster"
  fi
  [[ ! -d "$BRIDGE_AGENT_HOME_ROOT/9worker" ]] || \
    smoke_fail "create 9worker --dry-run unexpectedly created agents/9worker/"
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
  smoke_run "create version reserved-word"  assert_reserved_version_word
  smoke_run "create '' rejected"            assert_empty_name
  smoke_run "create 'evil\"name' rejected"  assert_metachar_name
  smoke_run "create 9worker --dry-run"      assert_numeric_start_dry_run
  smoke_run "create valid-worker --dry-run" assert_valid_dry_run

  smoke_log "PASS"
}

main "$@"
