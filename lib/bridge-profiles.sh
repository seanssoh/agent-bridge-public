#!/usr/bin/env bash
# shellcheck shell=bash

bridge_profiles_root() {
  printf '%s/agents' "$BRIDGE_HOME"
}

bridge_profile_source_root() {
  local agent="$1"
  printf '%s/%s' "$(bridge_profiles_root)" "$agent"
}

bridge_profile_state_file_for() {
  local agent="$1"
  printf '%s/%s.json' "$BRIDGE_PROFILE_STATE_DIR" "$agent"
}

bridge_profile_has_source() {
  local agent="$1"
  [[ -d "$(bridge_profile_source_root "$agent")" ]]
}

bridge_profile_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if bridge_profile_has_source "$agent"; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_require_profile_source() {
  local agent="$1"
  local source_root

  source_root="$(bridge_profile_source_root "$agent")"
  [[ -d "$source_root" ]] && return 0

  bridge_die "tracked profile이 없습니다: $source_root"
}

bridge_require_profile_target() {
  local agent="$1"
  local target_root

  target_root="$(bridge_resolve_profile_target "$agent" || true)"
  if [[ -n "$target_root" ]]; then
    printf '%s' "$target_root"
    return 0
  fi

  bridge_die "profile target을 찾을 수 없습니다: $agent"
}

bridge_resolve_profile_target() {
  local agent="$1"
  local target_root=""

  target_root="$(bridge_agent_profile_home "$agent")"
  if [[ -n "$target_root" ]]; then
    printf '%s' "$target_root"
    return 0
  fi

  if bridge_profile_has_source "$agent"; then
    bridge_agent_default_profile_home "$agent"
    return 0
  fi

  return 1
}

bridge_profile_active_flag() {
  local agent="$1"

  if bridge_agent_is_active "$agent"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

bridge_profile_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-profile.py" "$@"
}
