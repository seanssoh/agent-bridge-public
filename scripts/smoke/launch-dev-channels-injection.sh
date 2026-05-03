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
  smoke_log "passed"
}

main "$@"
