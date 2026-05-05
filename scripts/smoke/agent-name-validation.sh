#!/usr/bin/env bash
# scripts/smoke/agent-name-validation.sh — Issue #598 Track 4 smoke.
#
# Validates the test-artifact name policy: `agent create` and dynamic
# `agent-bridge --name <agent>` refuse names matching a test-artifact
# pattern (smoke-/test-/bootstrap-/created-agent-/pref- prefix or a
# trailing -repro-<N>) unless the operator opts in with --test-fixture.
# When the flag is used, an `agent_test_fixture_created` audit row is
# written so cleanup tooling can identify reapable test fixtures.
#
# Eight assertions:
# T1: `agent create smoke-foo` (no flag) — refused, no scaffold
# T2: `agent create smoke-foo --test-fixture --dry-run` — succeeds, audit
#     row recorded
# T3: `agent create test-bar` (no flag) — refused
# T4: `agent create created-agent-baz` (no flag) — refused
# T5: `agent create my-agent-repro-42` (no flag) — refused
# T6: `agent create my-agent --dry-run` (no flag) — succeeds (not a test
#     pattern; positive control)
# T7: `agent-bridge --codex --name smoke-x` (no flag) — refused
# T8: helper-level: with --test-fixture, the policy passes and the flag
#     plumbing lands TEST_FIXTURE=1 (driving the spawn path end-to-end
#     would require live tmux; the helper + plumbing are the boundary
#     this fixture owns).

set -euo pipefail

SMOKE_NAME="agent-name-validation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_create() {
  # Capture stdout+stderr together; never let a non-zero exit kill the
  # test before we assert on the captured text.
  bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
}

run_agent_bridge() {
  bash "$SMOKE_REPO_ROOT/agent-bridge" "$@" 2>&1 || true
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
  : >"$BRIDGE_AUDIT_LOG"
}

assert_refused_create() {
  local name="$1"
  reset_runtime
  local out
  out="$(run_create "$name")"
  smoke_assert_contains "$out" "test-artifact pattern" \
    "create $name refused with test-artifact-pattern message"
  smoke_assert_contains "$out" "--test-fixture" \
    "create $name refusal hints at --test-fixture opt-in"
  assert_no_scaffold "create $name" "$name"
}

assert_test_fixture_create() {
  reset_runtime
  local out
  out="$(run_create smoke-foo --engine claude --test-fixture --dry-run)"
  smoke_assert_contains "$out" "agent: smoke-foo" \
    "create smoke-foo --test-fixture --dry-run accepted"
  smoke_assert_contains "$out" "dry_run: yes" \
    "create smoke-foo --test-fixture --dry-run flags itself as a plan"
  # Audit row lands even on --dry-run (the policy/audit step runs before
  # the dry-run gating, so cleanup tooling can see the opt-in regardless
  # of whether the role was actually written).
  smoke_assert_file_exists "$BRIDGE_AUDIT_LOG" \
    "create --test-fixture: audit log file exists"
  local audit_text
  audit_text="$(cat "$BRIDGE_AUDIT_LOG")"
  smoke_assert_contains "$audit_text" "agent_test_fixture_created" \
    "create --test-fixture writes agent_test_fixture_created audit row"
  smoke_assert_contains "$audit_text" "smoke-foo" \
    "audit row carries the agent name"
  smoke_assert_contains "$audit_text" "test-fixture-flag" \
    "audit row carries reason=test-fixture-flag"
  smoke_assert_contains "$audit_text" "create" \
    "audit row carries entrypoint=create"
}

assert_positive_control_dry_run() {
  reset_runtime
  local out
  out="$(run_create my-agent --engine claude --dry-run)"
  smoke_assert_contains "$out" "agent: my-agent" \
    "create my-agent --dry-run accepted (not a test pattern)"
  smoke_assert_contains "$out" "dry_run: yes" \
    "create my-agent --dry-run flags itself as a plan"
  # No audit row from the test-fixture path on a non-matching name.
  if [[ -s "$BRIDGE_AUDIT_LOG" ]]; then
    smoke_assert_not_contains "$(cat "$BRIDGE_AUDIT_LOG")" \
      "agent_test_fixture_created" \
      "non-test-pattern create does not emit agent_test_fixture_created"
  fi
}

assert_refused_spawn() {
  reset_runtime
  local out
  # `--no-attach` keeps us out of an interactive tmux attach if the
  # validation were to ever pass; the test-artifact policy fails the
  # call long before the tmux step.
  out="$(run_agent_bridge --codex --name smoke-x --no-attach)"
  smoke_assert_contains "$out" "test-artifact pattern" \
    "spawn smoke-x refused with test-artifact-pattern message"
  smoke_assert_contains "$out" "--test-fixture" \
    "spawn smoke-x refusal hints at --test-fixture opt-in"
}

resolve_bash4() {
  # Mirror the bridge-lib.sh re-exec list: pick a Bash 4+ binary so the
  # `declare -g` in lib/bridge-core.sh works when we source it for the
  # helper-level assertions.
  local cand
  for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    if "$cand" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

assert_helper_plumbing() {
  # Source the helper directly to verify the prefix/suffix matcher is
  # canonical and that the spawn-side --test-fixture flag plumbs into
  # TEST_FIXTURE=1 without invoking tmux. This is the boundary this
  # fixture owns; driving the full spawn path would require live tmux.
  local bash4
  if ! bash4="$(resolve_bash4)"; then
    smoke_skip "helper plumbing" "no Bash 4+ binary on PATH (lib/bridge-core.sh uses declare -g)"
    return 0
  fi

  local helper_script
  helper_script="$SMOKE_TMP_ROOT/helper-check.sh"
  cat >"$helper_script" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SMOKE_REPO_ROOT="$1"
# shellcheck source=lib/bridge-core.sh
source "$SMOKE_REPO_ROOT/lib/bridge-core.sh"

for name in smoke-foo test-bar bootstrap-x created-agent-y pref-z my-agent-repro-42; do
  if ! bridge_validate_agent_name_test_artifact "$name"; then
    printf 'FAIL: expected %s to match test-artifact pattern\n' "$name" >&2
    exit 1
  fi
done

for name in my-agent reviewer codex-main agent-prefix repro-without-suffix; do
  if bridge_validate_agent_name_test_artifact "$name"; then
    printf 'FAIL: expected %s NOT to match test-artifact pattern\n' "$name" >&2
    exit 1
  fi
done

printf 'OK\n'
HELPER

  local out
  out="$("$bash4" "$helper_script" "$SMOKE_REPO_ROOT" 2>&1)" || \
    smoke_fail "helper plumbing: $out"
  smoke_assert_contains "$out" "OK" "helper matcher canonical (positive + negative)"

  # Argparse plumbing: scan the agent-bridge entry point to confirm
  # --test-fixture is wired (cheap textual contract — keeps T8 honest
  # without booting tmux).
  smoke_assert_contains \
    "$(cat "$SMOKE_REPO_ROOT/agent-bridge")" \
    "TEST_FIXTURE=1" \
    "agent-bridge wires --test-fixture into TEST_FIXTURE=1"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1: create smoke-foo refused"            assert_refused_create smoke-foo
  smoke_run "T2: create smoke-foo --test-fixture ok"  assert_test_fixture_create
  smoke_run "T3: create test-bar refused"             assert_refused_create test-bar
  smoke_run "T4: create created-agent-baz refused"    assert_refused_create created-agent-baz
  smoke_run "T5: create my-agent-repro-42 refused"    assert_refused_create my-agent-repro-42
  smoke_run "T6: create my-agent (positive control)"  assert_positive_control_dry_run
  smoke_run "T7: spawn smoke-x refused"               assert_refused_spawn
  smoke_run "T8: --test-fixture helper + plumbing"    assert_helper_plumbing

  smoke_log "PASS"
}

main "$@"
