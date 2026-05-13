#!/usr/bin/env bash
# shellcheck shell=bash

bridge_guard_python() {
  bridge_require_python
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
# Track D follow-up to #713 / #809: server hosts default to "1" so prompt
# guard runs on fresh hosted installs without an extra opt-in. dev hosts
# default to "0" so a laptop install stays quiet. Explicit env override
# (set to "0" or "1") wins over host_profile via the call site in
# bridge_prompt_guard_enabled_default.
bridge_prompt_guard_default() {
  # Lazy-source bridge-host-profile.sh: lib/bridge-guard.sh is loaded by
  # contexts that may or may not have already sourced the host-profile
  # helper. `type` check avoids re-source on every call.
  if ! declare -F bridge_host_profile_is_dev >/dev/null 2>&1; then
    if [[ -r "${BRIDGE_SCRIPT_DIR:-}/lib/bridge-host-profile.sh" ]]; then
      # shellcheck source=/dev/null
      source "${BRIDGE_SCRIPT_DIR}/lib/bridge-host-profile.sh"
    elif [[ -r "${BRIDGE_HOME:-}/lib/bridge-host-profile.sh" ]]; then
      # shellcheck source=/dev/null
      source "${BRIDGE_HOME}/lib/bridge-host-profile.sh"
    fi
  fi
  if declare -F bridge_host_profile_is_dev >/dev/null 2>&1 \
      && bridge_host_profile_is_dev; then
    printf '0'
  else
    printf '1'
  fi
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
