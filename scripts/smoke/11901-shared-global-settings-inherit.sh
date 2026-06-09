#!/usr/bin/env bash
# scripts/smoke/11901-shared-global-settings-inherit.sh
#
# Queue request #11901 (operator-approved Option 1, 2026-06-10): a SHARED
# (non-isolated) static Claude agent inherits the operator's system-global
# `~/.claude/settings.json` as the bottom-most render layer, so operator
# changes to global settings propagate to shared agents on the next render —
# while per-class managed defaults, bridge hooks, and per-agent preserved
# keys all still win. iso-v2 agents are UNAFFECTED; dynamic agents already
# read the real `~/.claude`.
#
# This smoke pins the full contract via a file-as-argv Python helper (no
# heredoc-stdin to Python — footgun #11):
#   AC1  global-only key (agentPushNotifEnabled) propagates
#   AC2  per-class static autoCompactWindow=400k wins over global 1M; hooks stay
#   AC3  per-agent enabledPlugins divergence preserved + independent
#   AC4  dynamic agent path: no regression
#   AC5  iso-v2 renderer carries NO operator-global option (cannot leak)
#   AC6  fail-safe: missing/malformed/empty global -> degrade to bridge base
#   FILTER  sensitive/machine-specific keys dropped; benign inherited
#
# Also pins the shell resolver: `bridge_hook_operator_global_settings_file`
# must resolve to `<operator-home>/.claude/settings.json` via the
# `BRIDGE_CONTROLLER_HOME` seam, and must print nothing (fail-safe) when no
# operator home can be resolved.

set -euo pipefail

SMOKE_NAME="11901-shared-global-settings-inherit"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

assert_renderer_contract() {
  smoke_make_temp_root "$SMOKE_NAME"
  python3 "$SCRIPT_DIR/11901-shared-global-settings-inherit-helper.py" \
    "$SMOKE_REPO_ROOT" "$SMOKE_TMP_ROOT" \
    || smoke_fail "render-shared-settings operator-global inheritance contract failed (#11901)"
}

assert_shell_resolver() {
  # The shell helper must resolve the operator-global path from the operator
  # HOME via `bridge_agent_operator_home_dir`, NOT $CLAUDE_CONFIG_DIR /
  # $BRIDGE_AGENT_HOME_ROOT. We unit-test the helper against a stubbed
  # operator-home resolver so the test stays portable on the dev macOS
  # bash 3.2 host (sourcing the full lib/bridge-agents.sh standalone needs
  # bash 4.2+). The integration wiring through the real resolver is exercised
  # by the live manual check noted in the PR.
  local out
  out="$(
    bash -c '
      set -euo pipefail
      source "'"$SMOKE_REPO_ROOT"'/lib/bridge-hooks.sh"
      bridge_agent_operator_home_dir() { printf "/tmp/op-home-fixture"; }
      bridge_hook_operator_global_settings_file
    '
  )"
  smoke_assert_eq "$out" "/tmp/op-home-fixture/.claude/settings.json" \
    "resolver derives operator-global from operator HOME"

  # Fail-safe: when no operator home can be resolved (resolver returns
  # non-zero / empty), the helper must print NOTHING so the Python renderer
  # receives "" and degrades to the bridge base.
  local out_empty
  out_empty="$(
    bash -c '
      set -euo pipefail
      source "'"$SMOKE_REPO_ROOT"'/lib/bridge-hooks.sh"
      bridge_agent_operator_home_dir() { return 1; }
      bridge_hook_operator_global_settings_file
    '
  )"
  smoke_assert_eq "$out_empty" "" \
    "resolver prints nothing when operator home is unresolvable (fail-safe)"
}

main() {
  smoke_run "render-shared-settings operator-global inheritance contract" \
    assert_renderer_contract
  smoke_run "shell resolver derives operator-global from operator HOME" \
    assert_shell_resolver

  smoke_log "PASS"
}

main "$@"
