#!/usr/bin/env bash
# shellcheck shell=bash

bridge_discord_relay_enabled() {
  [[ "${BRIDGE_DISCORD_RELAY_ENABLED:-1}" != "0" ]]
}

bridge_discord_relay_state_file() {
  printf '%s' "$BRIDGE_DISCORD_RELAY_STATE_FILE"
}

bridge_discord_relay_rows_tsv() {
  local agent
  local channel_id
  local timeout
  local active
  local session

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    channel_id="$(bridge_agent_discord_channel_id "$agent")"
    [[ -n "$channel_id" ]] || continue
    timeout="$(bridge_agent_idle_timeout "$agent")"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
    if bridge_agent_is_active "$agent"; then
      active=1
    else
      active=0
    fi
    session="$(bridge_agent_session "$agent")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$channel_id" "$active" "$timeout" "$session"
  done
}

bridge_discord_relay_count() {
  local count=0
  while IFS=$'\t' read -r _agent _channel _active _timeout _session; do
    [[ -n "${_agent:-}" ]] || continue
    count=$((count + 1))
  done < <(bridge_discord_relay_rows_tsv)
  printf '%s' "$count"
}

bridge_discord_relay_step() {
  local snapshot_file
  local count

  bridge_discord_relay_enabled || return 0
  count="$(bridge_discord_relay_count)"
  (( count > 0 )) || return 0

  snapshot_file="$(mktemp)"
  bridge_discord_relay_rows_tsv >"$snapshot_file"
  if ! bridge_require_python; then
    rm -f "$snapshot_file"
    return 1
  fi

  # #946 L1 (r2): stale-source guard. Discord relay runs every daemon
  # tick; an unguarded call fans out [Errno 2] across the relay cycle
  # when the source checkout vanishes mid-flight.
  if ! bridge_resolve_script_dir_check; then
    rm -f "$snapshot_file"
    return 1
  fi
  if ! python3 "$BRIDGE_SCRIPT_DIR/bridge-discord-relay.py" \
    sync \
    --agent-snapshot "$snapshot_file" \
    --bridge-home "$BRIDGE_HOME" \
    --state-file "$(bridge_discord_relay_state_file)" \
    --runtime-config "$(bridge_compat_config_file)" \
    --relay-account "$BRIDGE_DISCORD_RELAY_ACCOUNT" \
    --poll-limit "$BRIDGE_DISCORD_RELAY_POLL_LIMIT" \
    --cooldown-seconds "$BRIDGE_DISCORD_RELAY_COOLDOWN_SECONDS"; then
    rm -f "$snapshot_file"
    bridge_warn "discord relay sync failed"
    return 1
  fi

  rm -f "$snapshot_file"
}
