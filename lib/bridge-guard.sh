#!/usr/bin/env bash
# shellcheck shell=bash

bridge_guard_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-guard.py" "$@"
}

bridge_guard_policy_raw() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PROMPT_GUARD[$agent]-}"
}

bridge_guard_policy_value() {
  local raw="$1"
  local key="$2"
  local entry=""
  local entry_key=""
  local entry_value=""

  [[ -n "$raw" ]] || return 1
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    entry="$(bridge_trim_whitespace "$entry")"
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == *:* ]]; then
      entry_key="${entry%%:*}"
      entry_value="${entry#*:}"
    elif [[ "$entry" == *=* ]]; then
      entry_key="${entry%%=*}"
      entry_value="${entry#*=}"
    else
      continue
    fi
    entry_key="$(bridge_trim_whitespace "$entry_key")"
    entry_value="$(bridge_trim_whitespace "$entry_value")"
    if [[ "${entry_key,,}" == "${key,,}" ]]; then
      printf '%s' "$entry_value"
      return 0
    fi
  done
  return 1
}

bridge_guard_bool_value() {
  local raw="${1:-}"
  local default="${2:-0}"

  case "${raw,,}" in
    1|true|yes|on)
      printf '1'
      ;;
    0|false|no|off)
      printf '0'
      ;;
    *)
      printf '%s' "$default"
      ;;
  esac
}

# Default value for BRIDGE_PROMPT_GUARD_ENABLED when the env is unset.
# Track D's host_profile-aware default (`server` → `1`, `dev` → `0`,
# shipped in v0.11.0 / PR #813) was reverted 2026-05-14 because operators
# reported the auto-enable produced too many spurious blocks on real
# channel / MCP / intake traffic on server installs. Prompt guard is
# back to default-OFF on every host; operators who want it on opt in
# explicitly via `BRIDGE_PROMPT_GUARD_ENABLED=1`, same shape as v0.10.0
# and earlier. picker-sweep retains its v0.11.0 default-on behavior.
bridge_prompt_guard_default() {
  printf '0'
}

bridge_prompt_guard_enabled_default() {
  local raw="${BRIDGE_PROMPT_GUARD_ENABLED:-}"
  if [[ -z "$raw" ]]; then
    raw="$(bridge_prompt_guard_default)"
  fi
  bridge_guard_bool_value "$raw" "0"
}

bridge_agent_prompt_guard_enabled() {
  local agent="$1"
  local raw=""
  local configured=""

  raw="$(bridge_guard_policy_raw "$agent")"
  if configured="$(bridge_guard_policy_value "$raw" "enabled" 2>/dev/null)"; then
    [[ "$(bridge_guard_bool_value "$configured" "0")" == "1" ]]
    return $?
  fi
  [[ "$(bridge_prompt_guard_enabled_default)" == "1" ]]
}

bridge_prompt_guard_surface_threshold_default() {
  local surface="$1"
  case "$surface" in
    channel)
      printf '%s' "${BRIDGE_PROMPT_GUARD_CHANNEL_MIN_BLOCK:-high}"
      ;;
    task_body)
      printf '%s' "${BRIDGE_PROMPT_GUARD_TASK_BODY_MIN_BLOCK:-high}"
      ;;
    intake)
      printf '%s' "${BRIDGE_PROMPT_GUARD_INTAKE_MIN_BLOCK:-critical}"
      ;;
    mcp_output)
      printf '%s' "${BRIDGE_PROMPT_GUARD_MCP_OUTPUT_MIN_BLOCK:-high}"
      ;;
    prompt)
      printf '%s' "${BRIDGE_PROMPT_GUARD_PROMPT_MIN_BLOCK:-high}"
      ;;
    *)
      printf '%s' "${BRIDGE_PROMPT_GUARD_MIN_BLOCK:-high}"
      ;;
  esac
}

bridge_agent_prompt_guard_min_block() {
  local agent="$1"
  local surface="$2"
  local raw=""
  local configured=""
  local scoped_key=""

  raw="$(bridge_guard_policy_raw "$agent")"
  scoped_key="${surface}_min_block"
  if configured="$(bridge_guard_policy_value "$raw" "$scoped_key" 2>/dev/null)"; then
    printf '%s' "$configured"
    return 0
  fi
  if configured="$(bridge_guard_policy_value "$raw" "min_block" 2>/dev/null)"; then
    printf '%s' "$configured"
    return 0
  fi
  bridge_prompt_guard_surface_threshold_default "$surface"
}

bridge_agent_prompt_guard_canary() {
  local agent="$1"
  local raw=""
  local configured=""

  raw="$(bridge_guard_policy_raw "$agent")"
  if configured="$(bridge_guard_policy_value "$raw" "canary" 2>/dev/null)"; then
    printf '%s' "$configured"
    return 0
  fi
  printf '%s' "${BRIDGE_PROMPT_GUARD_CANARY_TOKENS:-}"
}
