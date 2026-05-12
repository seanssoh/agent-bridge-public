#!/usr/bin/env bash
# bridge-auth.sh — manage Agent Bridge authentication material.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-auth.sh claude-token add --id <id> (--stdin|--token-file <path>) [--activate] [--replace] [--sync] [--agents static|all|csv] [--enable-auto-rotate] [--threshold 99] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token list [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token activate <id> [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token sync [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token rotate [--if-auto-enabled] [--reason <text>] [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token check <id> [--enable-on-ok] [--disable-on-quota] [--timeout <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token recover-due [--timeout <sec>] [--retry-seconds <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token auto-rotate <enable|disable|status> [--threshold 99] [--json]
EOF
}

bridge_auth_registry_path() {
  printf '%s' "${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"
}

bridge_auth_run_privileged() {
  if declare -F _bridge_isolation_v2_run_root_or_sudo >/dev/null 2>&1; then
    _bridge_isolation_v2_run_root_or_sudo "$@"
    return $?
  fi
  "$@" 2>/dev/null && return 0
  bridge_linux_sudo_root "$@"
}

bridge_auth_secret_file_for_agent() {
  local agent="$1"
  local file=""
  if bridge_isolation_v2_active 2>/dev/null; then
    file="$(bridge_isolation_v2_agent_secret_env_file "$agent" 2>/dev/null || true)"
  fi
  if [[ -z "$file" ]]; then
    file="$BRIDGE_AGENT_HOME_ROOT/$agent/credentials/launch-secrets.env"
  fi
  printf '%s' "$file"
}

bridge_auth_prepare_secret_file() {
  local agent="$1"
  local file="$2"
  local dir=""
  local group=""
  local dir_mode="0700"

  dir="$(dirname "$file")"
  if bridge_isolation_v2_active 2>/dev/null; then
    group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    [[ -n "$group" ]] || {
      printf '[error] cannot resolve v2 group for agent: %s\n' "$agent" >&2
      return 1
    }
    if [[ "${BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK:-0}" == "1" ]] \
        && ! bridge_isolation_v2_group_exists "$group"; then
      group="$(id -gn)"
      dir_mode="0700"
    elif ! bridge_isolation_v2_ensure_group "$group"; then
      if [[ "${BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK:-0}" == "1" ]]; then
        group="$(id -gn)"
        dir_mode="0700"
      else
        printf '[error] cannot ensure v2 group for %s: %s\n' "$agent" "$group" >&2
        return 1
      fi
    else
      dir_mode="2750"
    fi
  else
    group="$(id -gn)"
  fi

  if [[ ! -d "$dir" ]]; then
    bridge_auth_run_privileged mkdir -p "$dir" || {
      printf '[error] cannot create credentials dir: %s\n' "$dir" >&2
      return 1
    }
  fi
  if [[ "$dir_mode" == "2750" ]]; then
    bridge_auth_run_privileged chown "$(id -un):$group" "$dir" || return 1
    bridge_auth_run_privileged chmod 2750 "$dir" || return 1
  else
    chmod 0700 "$dir" 2>/dev/null || true
  fi
}

bridge_auth_fix_secret_file_mode() {
  local agent="$1"
  local file="$2"
  local group=""
  local file_mode="0600"

  if bridge_isolation_v2_active 2>/dev/null; then
    group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    if [[ -n "$group" ]] && bridge_isolation_v2_group_exists "$group"; then
      file_mode="0640"
      bridge_auth_run_privileged chown "$(id -un):$group" "$file" || return 1
    elif [[ "${BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK:-0}" != "1" ]]; then
      printf '[error] v2 group missing after sync for %s: %s\n' "$agent" "$group" >&2
      return 1
    fi
  fi
  chmod "$file_mode" "$file" 2>/dev/null || bridge_auth_run_privileged chmod "$file_mode" "$file"
}

bridge_auth_selected_agents() {
  local spec="${1:-static}"
  local agent=""
  local item=""
  local -a explicit=()

  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|claude)
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    *)
      IFS=',' read -r -a explicit <<<"$spec"
      for item in "${explicit[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        bridge_agent_exists "$item" || {
          printf '[error] unknown agent: %s\n' "$item" >&2
          return 1
        }
        [[ "$(bridge_agent_engine "$item")" == "claude" ]] || {
          printf '[error] agent is not a Claude agent: %s\n' "$item" >&2
          return 1
        }
        printf '%s\n' "$item"
      done
      ;;
  esac
}

bridge_auth_sync_agents() {
  local registry="$1"
  local spec="$2"
  local json_mode="$3"
  local agent=""
  local file=""
  local output=""
  local selection_output=""
  local selection_error=""
  local rc=0
  local -a agents=()
  local -a synced=()
  local -a failed=()

  selection_error="$(mktemp -t agb-auth-select.XXXXXX 2>/dev/null || printf '%s' "/tmp/agb-auth-select.$$.$RANDOM")"
  if ! selection_output="$(bridge_auth_selected_agents "$spec" 2>"$selection_error")"; then
    if [[ "$json_mode" == "1" ]]; then
      python3 - "$selection_error" <<'PY'
import json
import sys
from pathlib import Path

error = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").strip() or "agent selection failed"
print(json.dumps({"status": "failed", "agents": [], "failed": [{"agent": "", "error": error}]}, ensure_ascii=True, indent=2))
PY
    else
      cat "$selection_error" >&2
    fi
    rm -f "$selection_error"
    return 1
  fi
  rm -f "$selection_error"
  if [[ -n "$selection_output" ]]; then
    mapfile -t agents <<<"$selection_output"
  fi
  if (( ${#agents[@]} == 0 )); then
    if [[ "$json_mode" == "1" ]]; then
      python3 - <<'PY'
import json
print(json.dumps({"status": "skipped", "reason": "no_matching_claude_agents", "agents": [], "failed": []}, indent=2))
PY
    else
      printf 'skipped: no_matching_claude_agents\n'
    fi
    return 0
  fi

  for agent in "${agents[@]}"; do
    file="$(bridge_auth_secret_file_for_agent "$agent")"
    if ! bridge_auth_prepare_secret_file "$agent" "$file"; then
      failed+=("$agent:prepare_failed")
      rc=1
      continue
    fi
    if ! output="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" sync-agent --agent "$agent" --file "$file" --json 2>&1)"; then
      failed+=("$agent:$output")
      rc=1
      continue
    fi
    if ! bridge_auth_fix_secret_file_mode "$agent" "$file"; then
      failed+=("$agent:mode_failed")
      rc=1
      continue
    fi
    synced+=("$agent")
    [[ "$json_mode" == "1" ]] || printf 'synced: %s -> %s\n' "$agent" "$file"
  done

  if [[ "$json_mode" == "1" ]]; then
    python3 - "${synced[@]}" -- "${failed[@]}" <<'PY'
import json
import sys

items = sys.argv[1:]
sep = items.index("--") if "--" in items else len(items)
synced = items[:sep]
failed_raw = items[sep + 1 :]
failed = []
for row in failed_raw:
    if ":" in row:
        agent, error = row.split(":", 1)
    else:
        agent, error = row, "failed"
    failed.append({"agent": agent, "error": error})
status = "ok" if not failed else ("failed" if not synced else "partial")
print(json.dumps({"status": status, "agents": synced, "failed": failed}, ensure_ascii=True, indent=2))
PY
  fi
  return "$rc"
}

bridge_auth_json_requested() {
  local arg=""
  for arg in "$@"; do
    [[ "$arg" == "--json" ]] && return 0
  done
  return 1
}

bridge_auth_sync_requested() {
  local arg=""
  for arg in "$@"; do
    [[ "$arg" == "--sync" ]] && return 0
  done
  return 1
}

bridge_auth_agents_arg() {
  local default="${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:-static}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents)
        [[ $# -ge 2 ]] || {
          printf '[error] --agents requires a value\n' >&2
          return 1
        }
        printf '%s' "$2"
        return 0
        ;;
    esac
    shift
  done
  printf '%s' "$default"
}

bridge_auth_emit_combined_json() {
  local op_json="$1"
  local sync_json="$2"
  python3 - "$op_json" "$sync_json" <<'PY'
import json
import sys

op = json.loads(sys.argv[1])
sync = json.loads(sys.argv[2])
op["sync"] = sync
print(json.dumps(op, ensure_ascii=True, indent=2))
PY
}

command="${1:-}"
[[ -n "$command" ]] || {
  usage
  exit 1
}
shift || true

case "$command" in
  claude-token)
    subcommand="${1:-}"
    [[ -n "$subcommand" ]] || {
      usage
      exit 1
    }
    shift || true
    registry="$(bridge_auth_registry_path)"
    case "$subcommand" in
      add|activate)
        json_mode=0
        sync_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        bridge_auth_sync_requested "$@" && sync_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        op_json=""
        if [[ "$json_mode" == "1" ]]; then
          op_json="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@")"
          if [[ "$sync_mode" == "1" ]]; then
            sync_rc=0
            sync_json="$(bridge_auth_sync_agents "$registry" "$agents_spec" 1)" || sync_rc=$?
            bridge_auth_emit_combined_json "$op_json" "$sync_json"
            exit "$sync_rc"
          else
            printf '%s\n' "$op_json"
          fi
        else
          python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@"
          if [[ "$sync_mode" == "1" ]]; then
            bridge_auth_sync_agents "$registry" "$agents_spec" 0
          fi
        fi
        ;;
      list|auto-rotate|check|recover-due)
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@"
        ;;
      sync)
        json_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        bridge_auth_sync_agents "$registry" "$agents_spec" "$json_mode"
        ;;
      rotate)
        json_mode=0
        sync_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        bridge_auth_sync_requested "$@" && sync_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        if [[ "$json_mode" == "1" ]]; then
          op_json="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" rotate "$@")"
          rotate_status="$(python3 - "$op_json" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("status", ""))
except Exception:
    print("")
PY
)"
          if [[ "$sync_mode" == "1" && "$rotate_status" == "rotated" ]]; then
            sync_rc=0
            sync_json="$(bridge_auth_sync_agents "$registry" "$agents_spec" 1)" || sync_rc=$?
            bridge_auth_emit_combined_json "$op_json" "$sync_json"
            exit "$sync_rc"
          else
            printf '%s\n' "$op_json"
          fi
        else
          python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" rotate "$@"
          if [[ "$sync_mode" == "1" ]]; then
            bridge_auth_sync_agents "$registry" "$agents_spec" 0
          fi
        fi
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
