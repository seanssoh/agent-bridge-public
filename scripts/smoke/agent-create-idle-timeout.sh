#!/usr/bin/env bash
# scripts/smoke/agent-create-idle-timeout.sh — Issue #1093 smoke.
#
# Validates the new `agent create` policy flags:
#  - `--idle-timeout <seconds>` (new) persists BRIDGE_AGENT_IDLE_TIMEOUT
#    on the managed-role block with the literal value.
#  - `--always-on` (legacy bare) still produces IDLE_TIMEOUT="0".
#  - `--always-on yes` (new extended) still produces IDLE_TIMEOUT="0".
#  - `--loop no` (new extended) persists BRIDGE_AGENT_LOOP="0" — the
#    legacy bare `--loop` continued to emit LOOP="1" only.
#  - Validation: `--idle-timeout -1` and `--idle-timeout abc` are
#    refused at parse time; `--always-on no` is refused (v1 contract).
#
# These run through an operator-trusted caller source (no TTY needed —
# BRIDGE_CALLER_SOURCE=operator-tui forces it) so the smoke does not
# depend on the host's TTY semantics.

set -euo pipefail

SMOKE_NAME="agent-create-idle-timeout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_create() {
  BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

read_field() {
  # Pull the BRIDGE_AGENT_<KEY>["<agent>"]= line from the roster file.
  local key="$1"
  local agent="$2"
  grep "^${key}\\[\"${agent}\"\\]=" "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1
}

assert_idle_timeout_explicit() {
  reset_runtime
  local out
  out="$(run_create idle300 --engine claude --idle-timeout 300)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_IDLE_TIMEOUT" "idle300")"
  smoke_assert_contains "$line" '="300"' "roster carries IDLE_TIMEOUT=300"
  smoke_assert_contains "$out" "idle_timeout: 300" "text output surfaces idle_timeout"
}

assert_idle_timeout_zero_maps_to_always_on() {
  reset_runtime
  local out
  out="$(run_create idle0 --engine claude --idle-timeout 0)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_IDLE_TIMEOUT" "idle0")"
  smoke_assert_contains "$line" '="0"' "roster carries IDLE_TIMEOUT=0 for --idle-timeout 0"
  smoke_assert_contains "$out" "always_on: yes" "--idle-timeout 0 surfaces always_on=yes"
}

assert_always_on_legacy_bare() {
  reset_runtime
  local out
  out="$(run_create alwayson1 --engine claude --always-on)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_IDLE_TIMEOUT" "alwayson1")"
  smoke_assert_contains "$line" '="0"' "bare --always-on persists IDLE_TIMEOUT=0"
  smoke_assert_contains "$out" "always_on: yes" "text output surfaces always_on=yes"
}

assert_always_on_explicit_yes() {
  reset_runtime
  local out
  out="$(run_create alwayson2 --engine claude --always-on yes)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_IDLE_TIMEOUT" "alwayson2")"
  smoke_assert_contains "$line" '="0"' "--always-on yes persists IDLE_TIMEOUT=0"
}

assert_loop_no_persists_zero() {
  reset_runtime
  local out
  out="$(run_create loopoff --engine claude --loop no)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_LOOP" "loopoff")"
  smoke_assert_contains "$line" '="0"' "--loop no persists LOOP=0"
  smoke_assert_contains "$out" "loop: no" "text output surfaces loop=no"
}

assert_loop_yes_persists_one() {
  reset_runtime
  local out
  out="$(run_create loopon --engine claude --loop yes)"
  smoke_assert_contains "$out" "create: ok" "create succeeded"
  local line
  line="$(read_field "BRIDGE_AGENT_LOOP" "loopon")"
  smoke_assert_contains "$line" '="1"' "--loop yes persists LOOP=1"
  smoke_assert_contains "$out" "loop: yes" "text output surfaces loop=yes"
}

assert_idle_timeout_validation() {
  reset_runtime
  # Negative integer → reject. Bare `-1` would be parsed as a flag-like
  # token, so use a value that the int regex refuses but doesn't start
  # with `-` to exercise the parser arm.
  local rc=0 out
  set +e
  out="$(run_create badidle --engine claude --idle-timeout abc 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "expected --idle-timeout abc to be refused; output=$out"
  fi
  smoke_assert_contains "$out" "0 이상의 정수" "reject reason names integer constraint"
}

assert_always_on_no_refused() {
  reset_runtime
  local rc=0 out
  set +e
  out="$(run_create badao --engine claude --always-on no 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "expected --always-on no to be refused; output=$out"
  fi
  smoke_assert_contains "$out" "v1 에서 지원하지 않습니다" "v1 contract surfaces in reject reason"
}

assert_create_json_carries_policy() {
  reset_runtime
  local out
  out="$(run_create jsonpolicy --engine claude --idle-timeout 600 --loop no --json)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert payload["agent"] == "jsonpolicy", payload
assert payload["policy"]["idle_timeout"] == "600", payload
assert payload["policy"]["loop"] == "no", payload
' "$out"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "agent-create-idle-timeout"
  smoke_run "--idle-timeout <N> persists IDLE_TIMEOUT line"        assert_idle_timeout_explicit
  smoke_run "--idle-timeout 0 maps to always_on"                   assert_idle_timeout_zero_maps_to_always_on
  smoke_run "bare --always-on persists IDLE_TIMEOUT=0"             assert_always_on_legacy_bare
  smoke_run "--always-on yes persists IDLE_TIMEOUT=0"              assert_always_on_explicit_yes
  smoke_run "--loop no persists LOOP=0"                            assert_loop_no_persists_zero
  smoke_run "--loop yes persists LOOP=1"                           assert_loop_yes_persists_one
  smoke_run "--idle-timeout rejects non-integer values"            assert_idle_timeout_validation
  smoke_run "--always-on no is refused in v1"                      assert_always_on_no_refused
  smoke_run "--json envelope carries policy { idle_timeout, loop }" assert_create_json_carries_policy
  smoke_log "passed"
}

main "$@"
