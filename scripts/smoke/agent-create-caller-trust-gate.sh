#!/usr/bin/env bash
# scripts/smoke/agent-create-caller-trust-gate.sh — Issue #1047 smoke.
#
# `agent create` writes a managed-role block to agent-roster.local.sh, the
# same protected system-config file `agent update` / `agent delete` mutate.
# Before #1047 `create` was ungated while update/delete rejected an
# `agent-direct` caller source — an incoherent split privilege boundary.
# This smoke locks in the corrected, symmetric gate: `agent create` is
# allowed only from an operator-trusted caller source.
#
# The single caller-source contract is bridge_agent_update_caller_source()
# (lib/bridge-agent-update.sh): an explicit BRIDGE_CALLER_SOURCE override
# of operator-tui / operator-trusted-id is honored; any other explicit
# value is demoted to agent-direct; with no override, TTY detection
# decides. These assertions run inside `$(...)` captures (no TTY), so the
# only way to reach a trusted source is the explicit override.
#
# Assertions:
#  T1: create from an agent-direct caller (no override, no TTY) is DENIED
#      with the system-config deny reason, and nothing is scaffolded.
#  T2: create with BRIDGE_CALLER_SOURCE=operator-trusted-id is ALLOWED
#      (reaches the create plan path).
#  T3: create with BRIDGE_CALLER_SOURCE=operator-tui is ALLOWED.
#  T4: create with a bogus BRIDGE_CALLER_SOURCE value is demoted to
#      agent-direct and DENIED, exactly like T1.

set -euo pipefail

SMOKE_NAME="agent-create-caller-trust-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# run_create — invoke `agent create` with an explicit caller source.
# $1 is the BRIDGE_CALLER_SOURCE value to export (empty string = no
# override, leaving the source to TTY detection → agent-direct here).
run_create() {
  local source_value="$1"
  shift
  if [[ -n "$source_value" ]]; then
    BRIDGE_CALLER_SOURCE="$source_value" \
      bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
  else
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
  fi
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

assert_no_scaffold() {
  local label="$1"
  local agent="$2"
  [[ ! -d "$BRIDGE_AGENT_HOME_ROOT/$agent" ]] || \
    smoke_fail "$label: agents/$agent/ unexpectedly scaffolded by a denied create"
  if [[ -s "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
    smoke_assert_not_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" \
      "MANAGED ROLE: $agent" \
      "$label: local roster has no MANAGED ROLE block for '$agent'"
  fi
}

assert_agent_direct_denied() {
  reset_runtime
  local out
  out="$(run_create "" gate-worker --engine claude --dry-run)"
  smoke_assert_contains "$out" "deny:" \
    "T1: agent-direct create is denied"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T1: deny reason names the agent-direct caller source"
  assert_no_scaffold "T1: agent-direct create" "gate-worker"
}

assert_operator_trusted_allowed() {
  reset_runtime
  local out
  out="$(run_create "operator-trusted-id" gate-worker --engine claude --dry-run)"
  smoke_assert_not_contains "$out" "not allowed to mutate system config" \
    "T2: operator-trusted-id create passes the caller-trust gate"
  smoke_assert_contains "$out" "agent: gate-worker" \
    "T2: operator-trusted-id create reaches the create plan path"
  smoke_assert_contains "$out" "dry_run: yes" \
    "T2: operator-trusted-id create completes the dry-run plan"
}

assert_operator_tui_allowed() {
  reset_runtime
  local out
  out="$(run_create "operator-tui" gate-worker --engine claude --dry-run)"
  smoke_assert_not_contains "$out" "not allowed to mutate system config" \
    "T3: operator-tui create passes the caller-trust gate"
  smoke_assert_contains "$out" "dry_run: yes" \
    "T3: operator-tui create completes the dry-run plan"
}

assert_bogus_source_demoted_denied() {
  reset_runtime
  local out
  out="$(run_create "definitely-not-trusted" gate-worker --engine claude --dry-run)"
  smoke_assert_contains "$out" "caller source agent-direct is not allowed to mutate system config" \
    "T4: bogus BRIDGE_CALLER_SOURCE is demoted to agent-direct and denied"
  assert_no_scaffold "T4: bogus-source create" "gate-worker"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1: agent-direct create denied"           assert_agent_direct_denied
  smoke_run "T2: operator-trusted-id create allowed"   assert_operator_trusted_allowed
  smoke_run "T3: operator-tui create allowed"          assert_operator_tui_allowed
  smoke_run "T4: bogus source demoted + denied"        assert_bogus_source_demoted_denied

  smoke_log "PASS"
}

main "$@"
