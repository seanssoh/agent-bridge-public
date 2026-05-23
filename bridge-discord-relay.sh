#!/usr/bin/env bash
# bridge-discord-relay.sh — Discord wake relay for on-demand agents

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-discord-relay.sh status
  bash $SCRIPT_DIR/bridge-discord-relay.sh sync
EOF
}

cmd_status() {
  local count
  local state_file

  count="$(bridge_discord_relay_count)"
  state_file="$(bridge_discord_relay_state_file)"

  echo "enabled: $(bridge_discord_relay_enabled && printf yes || printf no)"
  echo "relay_account: ${BRIDGE_DISCORD_RELAY_ACCOUNT}"
  echo "state_file: ${state_file}"
  echo "monitored_agents: ${count}"
  if (( count > 0 )); then
    echo "agents:"
    while IFS=$'\t' read -r agent channel_id active timeout _session; do
      [[ -n "$agent" ]] || continue
      printf '  %s | channel=%s | active=%s | idle_timeout=%ss\n' "$agent" "$channel_id" "$active" "$timeout"
    done < <(bridge_discord_relay_rows_tsv)
  fi
}

cmd_sync() {
  bridge_discord_relay_step
}

discord_args_have_help() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help|help) return 0 ;;
    esac
  done
  return 1
}

case "${1:-}" in
  status)
    shift
    # Issue #1114: accept `discord status --help` without the strict
    # arity check rejecting the help flag itself.
    if discord_args_have_help "$@"; then
      usage
      exit 0
    fi
    [[ $# -eq 0 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-discord-relay.sh status"
    cmd_status
    ;;
  sync)
    shift
    if discord_args_have_help "$@"; then
      usage
      exit 0
    fi
    [[ $# -eq 0 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-discord-relay.sh sync"
    cmd_sync
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
