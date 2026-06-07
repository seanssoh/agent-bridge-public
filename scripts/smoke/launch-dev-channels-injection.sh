#!/usr/bin/env bash

# Issue #529: BRIDGE_AGENT_CHANNELS development-channel plugins must reach
# the actual `claude` argv. The launch builder previously called
# bridge_claude_launch_with_channels but never bridge_claude_launch_with_development_channels,
# while channel diagnostics simulated the missing call and reported
# launch_allowlisted=yes. This smoke locks the contract so the simulate-vs-real
# drift cannot return:
#
# 1. injection: BRIDGE_AGENT_CHANNELS dev-channel reaches the built launch_cmd.
# 2. dedup: a hand-pasted token in raw BRIDGE_AGENT_LAUNCH_CMD is not duplicated.
# 3. multi-channel order: declaration order is preserved for multiple dev channels.
# 4. diagnostic alignment: launch_allowlisted matches whether the real builder
#    actually injects the token (positive and negative cases).
# 5. non-dev untouched: an official-marketplace plugin does NOT acquire a
#    --dangerously-load-development-channels token, while a co-declared dev
#    channel does.
# 6. Agent Bridge Teams dev plugin launch stays plugin-scoped; its private
#    `.mcp.json` key must not be promoted to a global `server:teams` channel.
# 7. explicit server selectors also get the matching development-channel
#    allowance, because Claude requires it for server-shaped channels.

set -euo pipefail

SMOKE_NAME="launch-dev-channels-injection"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

source_bridge_lib() {
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
  # Initialize the roster associative arrays (bridge_reset_roster_maps runs
  # inside bridge_load_roster). Without this the per-agent map slots are
  # unbound and assignments below trigger `set -u` errors.
  bridge_load_roster
}

register_worker_static_claude() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/worker"
  mkdir -p "$workdir"
  bridge_add_agent_id_if_missing "worker"
  BRIDGE_AGENT_ENGINE["worker"]="claude"
  BRIDGE_AGENT_SOURCE["worker"]="static"
  BRIDGE_AGENT_SESSION["worker"]="worker-session"
  BRIDGE_AGENT_WORKDIR["worker"]="$workdir"
  BRIDGE_AGENT_LOOP["worker"]=0
  BRIDGE_AGENT_CONTINUE["worker"]=0
}

count_substring() {
  local haystack="$1"
  local needle="$2"
  local trimmed="${haystack//$needle/}"
  local removed=$(( ${#haystack} - ${#trimmed} ))
  if (( ${#needle} == 0 )); then
    printf '0'
    return 0
  fi
  printf '%d' $(( removed / ${#needle} ))
}

assert_injection() {
  local launch_cmd
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:foo@m"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:foo@m" \
    "real launch builder injects BRIDGE_AGENT_CHANNELS dev plugin into argv"
}

assert_dedup_against_raw_paste() {
  local launch_cmd count
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:foo@m"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-load-development-channels plugin:foo@m --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"
  count="$(count_substring "$launch_cmd" "plugin:foo@m")"
  smoke_assert_eq "1" "$count" \
    "dev-channel injection dedups against operator-pasted raw LAUNCH_CMD token"
}

assert_multi_channel_order_stable() {
  local launch_cmd a_pos b_pos
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:a@m,plugin:b@m"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:a@m" \
    "first declared dev channel reaches argv"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:b@m" \
    "second declared dev channel reaches argv"

  # Order: plugin:a@m must appear before plugin:b@m in the rebuilt command.
  a_pos="$(awk -v s="$launch_cmd" -v t="plugin:a@m" 'BEGIN { print index(s, t) }')"
  b_pos="$(awk -v s="$launch_cmd" -v t="plugin:b@m" 'BEGIN { print index(s, t) }')"
  if (( a_pos == 0 || b_pos == 0 || a_pos >= b_pos )); then
    smoke_fail "multi-channel order: expected plugin:a@m before plugin:b@m in: $launch_cmd"
  fi
}

assert_diagnostic_alignment() {
  local launch_cmd allowlisted

  # Positive case: declared dev channel must be allowlisted AND injected.
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:foo@m"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:foo@m" \
    "diagnostic alignment positive: real builder injects token"

  allowlisted="$(bridge_agent_channel_launch_allowlisted_for_item worker plugin:foo@m)"
  smoke_assert_eq "yes" "$allowlisted" \
    "diagnostic alignment positive: launch_allowlisted reports yes when real builder injects"

  # Negative case: remove the channel; both surfaces must agree it's not loaded.
  BRIDGE_AGENT_CHANNELS["worker"]=""
  launch_cmd="$(bridge_agent_launch_cmd worker)"
  smoke_assert_not_contains "$launch_cmd" "--dangerously-load-development-channels plugin:foo@m" \
    "diagnostic alignment negative: removed channel not in real builder argv"

  allowlisted="$(bridge_agent_channel_launch_allowlisted_for_item worker plugin:foo@m)"
  smoke_assert_eq "no" "$allowlisted" \
    "diagnostic alignment negative: launch_allowlisted reports no when real builder skips"
}

assert_non_dev_channel_untouched() {
  local launch_cmd dev_count
  # plugin:telegram@claude-plugins-official is the canonical non-dev (official
  # marketplace) plugin per bridge_channel_item_is_development. plugin:foo@m
  # is dev (marketplace != claude-plugins-official).
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:telegram@claude-plugins-official,plugin:foo@m"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"

  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:foo@m" \
    "co-declared dev channel still injected when alongside non-dev"
  smoke_assert_not_contains "$launch_cmd" "--dangerously-load-development-channels plugin:telegram@claude-plugins-official" \
    "official-marketplace plugin must not get a --dangerously-load-development-channels token"

  # Sanity: only one --dangerously-load-development-channels occurrence overall
  # (for plugin:foo@m), proving the official channel did not produce a second.
  dev_count="$(count_substring "$launch_cmd" "--dangerously-load-development-channels")"
  smoke_assert_eq "1" "$dev_count" \
    "exactly one dev-channel token emitted when one dev + one non-dev channel are declared"
}

assert_agent_bridge_teams_plugin_selector() {
  local launch_cmd
  BRIDGE_AGENT_CHANNELS["worker"]="plugin:teams@agent-bridge,plugin:ms365@agent-bridge"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"

  smoke_assert_not_contains "$launch_cmd" "--channels server:teams" \
    "Teams dev plugin does not emit a global server-shaped channel selector"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:teams@agent-bridge" \
    "Teams dev plugin still reaches Claude development-channel loading"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels plugin:ms365@agent-bridge" \
    "MS365 dev plugin still reaches Claude development-channel loading"
  smoke_assert_not_contains "$launch_cmd" "--dangerously-load-development-channels server:teams" \
    "implicit server:teams does not get a development-channel allowance"
  smoke_assert_not_contains "$launch_cmd" "--channels server:ms365" \
    "MS365 tool plugin does not get an inbound-channel server selector"
  smoke_assert_contains "$launch_cmd" "HOME=" \
    "channel launch pins Claude HOME to the agent-scoped home"
  smoke_assert_contains "$launch_cmd" "CLAUDE_CONFIG_DIR=" \
    "channel launch pins Claude config dir to the agent-scoped home"
  smoke_assert_not_contains "$launch_cmd" "TEAMS_DELIVERY_MODE" \
    "Teams channel launch never emits the removed TEAMS_DELIVERY_MODE knob (issue #1204)"
}

assert_explicit_server_selector_gets_dev_allowance() {
  local launch_cmd
  BRIDGE_AGENT_CHANNELS["worker"]="server:teams"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="claude --dangerously-skip-permissions"

  launch_cmd="$(bridge_agent_launch_cmd worker)"

  smoke_assert_contains "$launch_cmd" "--channels server:teams" \
    "explicit server:teams selector reaches Claude --channels"
  smoke_assert_contains "$launch_cmd" "--dangerously-load-development-channels server:teams" \
    "explicit server:teams selector receives required development-channel allowance"
  smoke_assert_contains "$launch_cmd" "TEAMS_STATE_DIR=" \
    "server:teams selector still injects Teams state dir"
  smoke_assert_not_contains "$launch_cmd" "TEAMS_DELIVERY_MODE" \
    "server:teams selector never emits the removed TEAMS_DELIVERY_MODE knob (issue #1204)"
  smoke_assert_contains "$launch_cmd" "HOME=" \
    "server:teams selector pins Claude HOME to the agent-scoped home"
  smoke_assert_contains "$launch_cmd" "CLAUDE_CONFIG_DIR=" \
    "server:teams selector pins Claude config dir to the agent-scoped home"
}

assert_teams_delivery_mode_source_grep_gate() {
  # Issue #1204: TEAMS_DELIVERY_MODE was removed entirely because the
  # `bridge` mode silently dropped inbound messages when BRIDGE_AGENT_ID was
  # not propagated into the plugin's environment. This grep gate locks the
  # removal in: no shipped source — code or docs — may reintroduce the
  # token. CHANGELOG.md is exempt so the historical release entry
  # documenting the removal can keep the literal string for traceability;
  # this smoke and scripts/smoke-test.sh are exempt because their own
  # must-not-survive negative assertions necessarily mention the token they
  # are forbidding.
  local matches
  matches="$(cd "$SMOKE_REPO_ROOT" && git grep -i -l 'TEAMS_DELIVERY_MODE' -- \
    ':!CHANGELOG.md' \
    ':!scripts/smoke/launch-dev-channels-injection.sh' \
    ':!scripts/smoke-test.sh' \
    2>/dev/null || true)"
  smoke_assert_eq "" "$matches" \
    "no shipped source reintroduces the removed TEAMS_DELIVERY_MODE knob"
}

assert_stale_claude_home_prefix_is_rewritten() {
  local launch_cmd home_count config_count operator_home
  # #1621/#1622 shared-mode contract: a shared (non-iso) Claude agent now runs
  # with HOME = the OPERATOR home (so generic ~/.config tools stay shared) and
  # CLAUDE_CONFIG_DIR = the PER-AGENT config dir (so Claude identity/settings/
  # transcripts/credentials stay isolated). Pin the operator home to a fixture
  # via BRIDGE_CONTROLLER_HOME so the assertion is portable (otherwise it
  # resolves to the real $HOME of whoever runs the smoke).
  operator_home="$BRIDGE_AGENT_ROOT_V2/operator-home"
  BRIDGE_AGENT_CHANNELS["worker"]="server:teams"
  BRIDGE_AGENT_LAUNCH_CMD["worker"]="HOME=/home/ec2-user CLAUDE_CONFIG_DIR=/home/ec2-user/.claude claude --dangerously-skip-permissions"

  launch_cmd="$(BRIDGE_CONTROLLER_HOME="$operator_home" bridge_agent_launch_cmd worker)"

  smoke_assert_contains "$launch_cmd" "HOME=$operator_home " \
    "stale inherited HOME is rewritten to the operator home (shared-mode #1621)"
  smoke_assert_contains "$launch_cmd" "CLAUDE_CONFIG_DIR=$BRIDGE_AGENT_ROOT_V2/worker/home/.claude" \
    "Claude config dir stays the per-agent config dir (#1520/#1621 isolation)"
  smoke_assert_not_contains "$launch_cmd" "HOME=/home/ec2-user " \
    "stale controller HOME does not survive"
  smoke_assert_not_contains "$launch_cmd" "CLAUDE_CONFIG_DIR=/home/ec2-user/.claude" \
    "stale controller Claude config dir does not survive"
  smoke_assert_not_contains "$launch_cmd" "HOME=$BRIDGE_AGENT_ROOT_V2/worker/home " \
    "shared-mode HOME is NOT the per-agent home (would fragment ~/.config; #1370)"

  home_count="$(count_substring "$launch_cmd" "HOME=")"
  config_count="$(count_substring "$launch_cmd" "CLAUDE_CONFIG_DIR=")"
  smoke_assert_eq "1" "$home_count" \
    "rewritten launch command has exactly one HOME assignment"
  smoke_assert_eq "1" "$config_count" \
    "rewritten launch command has exactly one CLAUDE_CONFIG_DIR assignment"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "launch-dev-channels-injection"
  source_bridge_lib
  register_worker_static_claude
  smoke_run "BRIDGE_AGENT_CHANNELS dev plugin reaches argv"           assert_injection
  smoke_run "dedup against operator-pasted raw LAUNCH_CMD token"      assert_dedup_against_raw_paste
  smoke_run "multi-channel injection preserves declaration order"    assert_multi_channel_order_stable
  smoke_run "diagnostic launch_allowlisted matches real builder"     assert_diagnostic_alignment
  smoke_run "non-dev (official) channel does not get dev-load token" assert_non_dev_channel_untouched
  smoke_run "Agent Bridge Teams dev plugin stays plugin-scoped"       assert_agent_bridge_teams_plugin_selector
  smoke_run "explicit server selector gets dev allowance"            assert_explicit_server_selector_gets_dev_allowance
  smoke_run "TEAMS_DELIVERY_MODE removal grep gate (#1204)"          assert_teams_delivery_mode_source_grep_gate
  smoke_run "stale Claude home prefix is rewritten"                  assert_stale_claude_home_prefix_is_rewritten
  smoke_log "passed"
}

main "$@"
