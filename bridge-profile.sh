#!/usr/bin/env bash
# bridge-profile.sh — tracked agent profile status, diff, and deploy

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") status [agent|--all]
  $(basename "$0") diff <agent>
  $(basename "$0") deploy <agent> [--dry-run] [--force]
EOF
}

run_status() {
  local all=0
  local agent=""
  local profile_agents=()
  local target_root=""
  local active_flag=""
  local py_args=()
  local i

  # Issue #1114 (codex r1 follow-up): -h/--help in the agent slot
  # prints usage instead of being treated as an agent id (which then
  # dies in bridge_require_agent with a roster mismatch). Restricted
  # to the dashed forms — bare `help` could be a legitimate agent id.
  case "${1:-}" in
    -h|--help)
      usage
      return 0
      ;;
  esac

  if [[ "${1:-}" == "--all" ]]; then
    all=1
    shift
  elif [[ $# -gt 0 ]]; then
    agent="$1"
    shift
  fi

  [[ $# -eq 0 ]] || bridge_die "Usage: $(basename "$0") status [agent|--all]"

  if [[ $all -eq 1 || -z "$agent" ]]; then
    mapfile -t profile_agents < <(bridge_profile_agent_ids)
    if [[ ${#profile_agents[@]} -eq 0 ]]; then
      echo "(tracked agent profile 없음)"
      return 0
    fi
  else
    bridge_require_agent "$agent"
    bridge_require_profile_source "$agent"
    profile_agents=("$agent")
  fi

  for ((i = 0; i < ${#profile_agents[@]}; i++)); do
    agent="${profile_agents[$i]}"
    target_root="$(bridge_resolve_profile_target "$agent" || true)"
    active_flag="$(bridge_profile_active_flag "$agent")"
    py_args=(
      status
      --agent "$agent"
      --source-root "$(bridge_profile_source_root "$agent")"
      --state-file "$(bridge_profile_state_file_for "$agent")"
      --active "$active_flag"
    )
    if [[ -n "$target_root" ]]; then
      py_args+=(--target-root "$target_root")
    fi
    bridge_profile_python "${py_args[@]}"
    if (( i + 1 < ${#profile_agents[@]} )); then
      echo
    fi
  done
}

run_diff() {
  local agent="${1:-}"
  local py_args=()

  [[ $# -eq 1 && -n "$agent" ]] || bridge_die "Usage: $(basename "$0") diff <agent>"

  bridge_require_agent "$agent"
  bridge_require_profile_source "$agent"

  py_args=(
    diff
    --agent "$agent"
    --source-root "$(bridge_profile_source_root "$agent")"
    --target-root "$(bridge_require_profile_target "$agent")"
    --state-file "$(bridge_profile_state_file_for "$agent")"
    --active "$(bridge_profile_active_flag "$agent")"
  )
  bridge_profile_python "${py_args[@]}"
}

run_deploy() {
  local agent="${1:-}"
  local dry_run=0
  local force=0
  local py_args=()

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") deploy <agent> [--dry-run] [--force]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_agent "$agent"
  bridge_require_profile_source "$agent"

  py_args=(
    deploy
    --agent "$agent"
    --source-root "$(bridge_profile_source_root "$agent")"
    --target-root "$(bridge_require_profile_target "$agent")"
    --state-file "$(bridge_profile_state_file_for "$agent")"
    --active "$(bridge_profile_active_flag "$agent")"
    --deployed-at "$(bridge_now_iso)"
    --deployed-by "${USER:-unknown}"
  )
  if [[ $dry_run -eq 1 ]]; then
    py_args+=(--dry-run)
  fi
  if [[ $force -eq 1 ]]; then
    py_args+=(--force)
  fi

  bridge_profile_python "${py_args[@]}"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  status)
    run_status "$@"
    ;;
  diff)
    run_diff "$@"
    ;;
  deploy)
    run_deploy "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 profile 명령입니다: $subcommand"
    ;;
esac
