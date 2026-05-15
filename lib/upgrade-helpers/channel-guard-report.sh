#!/usr/bin/env bash
# channel-guard-report.sh — generate the channel-guard report table consumed
# by bridge_upgrade_channel_guard_json.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: tab-separated rows (one per agent with a "miss" channel status):
#   <agent>\t<active>\t<required_channels>\t<reason>
#
# Footgun #11 third variant (task #4538): this body used to live as a
# `bridge_upgrade_with_target_env … bash -s -- … <<'EOF' … EOF` heredoc-stdin
# inside bridge_upgrade_channel_guard_report. Bash 5.3.9 wedges the parent in
# `heredoc_write -> write()` when sending the heredoc body to the bash -s
# subprocess (producer-side mirror of the read_comsub bug fixed in v0.13.7
# and v0.13.8). Moving the script body to a regular file and invoking it via
# `bash $0 args` removes the heredoc-stdin path entirely.

set -euo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster

agent=""
session=""
active="no"
reason=""
required=""

for agent in "${BRIDGE_AGENT_IDS[@]}"; do
  if [[ "$(bridge_agent_channel_status "$agent")" != "miss" ]]; then
    continue
  fi
  session="$(bridge_agent_session "$agent")"
  active="no"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    active="yes"
  fi
  reason="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -z "$reason" ]]; then
    reason="$(bridge_agent_channel_status_reason "$agent")"
  fi
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  required="$(bridge_agent_channels_csv "$agent")"
  printf "%s\t%s\t%s\t%s\n" "$agent" "$active" "$required" "$reason"
done

# silence shellcheck SC2034 for $target_root — kept in the signature for
# future use and parity with the prior heredoc body.
: "$target_root"
