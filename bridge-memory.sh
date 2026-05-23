#!/usr/bin/env bash
# bridge-memory.sh — bridge-native memory wiki helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") init --agent <agent> [--user <id[:display-name]>]... [--dry-run] [--json]
  $(basename "$0") capture --agent <agent> [--user <id>] --source <source> [--author <name>] [--channel <id>] [--title <text>] (--text <text> | --text-file <path>) [--dry-run] [--json]
  $(basename "$0") ingest --agent <agent> (--capture <id> | --latest | --all) [--dry-run] [--json]
  $(basename "$0") promote --agent <agent> --kind user|shared|project|decision [--user <id>] [--capture <id>] [--page <slug>] [--summary <text>] [--dry-run] [--json]
  $(basename "$0") remember --agent <agent> [--user <id>] --source <source> [--author <name>] [--channel <id>] [--title <text>] --text <text> [--kind none|user|shared|project|decision] [--page <slug>] [--summary <text>] [--dry-run] [--json]
  $(basename "$0") lint --agent <agent> [--json]
  $(basename "$0") search --agent <agent> --query <text> [--user <id>] [--scope wiki|all|user|daily|shared|project|decision|raw] [--limit <count>] [--json]
  $(basename "$0") rebuild-index --agent <agent> [--db-path <path>] [--dry-run] [--json]
  $(basename "$0") query --agent <agent> --query <text> [--user <id>] [--scope all|wiki|user|daily|shared|project|decision|raw] [--limit <count>] [--db-path <path>] [--json]
EOF
}

run_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-memory.py" "$@"
}

resolve_agent_home() {
  local agent="$1"
  bridge_require_agent "$agent"
  printf '%s' "$(bridge_agent_workdir "$agent")"
}

command="${1:-}"
[[ -n "$command" ]] || { usage; exit 1; }
shift || true

# Issue #1114: -h/--help/help on the top-level dispatcher prints usage
# and exits 0 instead of falling through to the "지원하지 않는 memory
# 명령입니다" error path. The sub-command --help branches lower in the
# file are unreachable when the dispatcher rejects the sub first.
case "$command" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

agent=""
users=()
dry_run=0
json_mode=0
bridge_home="${BRIDGE_HOME:-$HOME/.agent-bridge}"

case "$command" in
  init)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          users+=("$2")
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory init 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(init --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template")
    for item in "${users[@]}"; do
      args+=(--user "$item")
    done
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  capture)
    user_id="default"
    source_name=""
    author=""
    channel=""
    title=""
    text=""
    text_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --source)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          source_name="$2"
          shift 2
          ;;
        --author)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          author="$2"
          shift 2
          ;;
        --channel)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          channel="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --text)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          text="$2"
          shift 2
          ;;
        --text-file)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          text_file="$2"
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory capture 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$source_name" ]] || bridge_die "--source is required"
    if [[ -z "$text" && -z "$text_file" ]]; then
      bridge_die "--text or --text-file is required"
    fi
    args=(capture --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template" --user "$user_id" --source "$source_name")
    [[ -n "$author" ]] && args+=(--author "$author")
    [[ -n "$channel" ]] && args+=(--channel "$channel")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$text" ]] && args+=(--text "$text")
    [[ -n "$text_file" ]] && args+=(--text-file "$text_file")
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  ingest)
    capture_id=""
    latest=0
    all_items=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --capture)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          capture_id="$2"
          shift 2
          ;;
        --latest)
          latest=1
          shift
          ;;
        --all)
          all_items=1
          shift
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory ingest 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(ingest --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template")
    [[ -n "$capture_id" ]] && args+=(--capture "$capture_id")
    [[ $latest -eq 1 ]] && args+=(--latest)
    [[ $all_items -eq 1 ]] && args+=(--all)
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  promote)
    kind=""
    user_id=""
    capture_id=""
    page=""
    title=""
    summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --kind)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          kind="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --capture)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          capture_id="$2"
          shift 2
          ;;
        --page)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          page="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --summary)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          summary="$2"
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory promote 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$kind" ]] || bridge_die "--kind is required"
    args=(promote --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template" --kind "$kind")
    [[ -n "$user_id" ]] && args+=(--user "$user_id")
    [[ -n "$capture_id" ]] && args+=(--capture "$capture_id")
    [[ -n "$page" ]] && args+=(--page "$page")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$summary" ]] && args+=(--summary "$summary")
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  remember)
    user_id="default"
    source_name=""
    author=""
    channel=""
    title=""
    text=""
    kind="user"
    page=""
    summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --source)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          source_name="$2"
          shift 2
          ;;
        --author)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          author="$2"
          shift 2
          ;;
        --channel)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          channel="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --text)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          text="$2"
          shift 2
          ;;
        --kind)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          kind="$2"
          shift 2
          ;;
        --page)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          page="$2"
          shift 2
          ;;
        --summary)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          summary="$2"
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory remember 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$source_name" ]] || bridge_die "--source is required"
    [[ -n "$text" ]] || bridge_die "--text is required"
    args=(remember --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template" --user "$user_id" --source "$source_name" --text "$text" --kind "$kind")
    [[ -n "$author" ]] && args+=(--author "$author")
    [[ -n "$channel" ]] && args+=(--channel "$channel")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$page" ]] && args+=(--page "$page")
    [[ -n "$summary" ]] && args+=(--summary "$summary")
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  lint)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory lint 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(lint --agent "$agent" --home "$(resolve_agent_home "$agent")")
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  rebuild-index)
    db_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --db-path)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          db_path="$2"
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory rebuild-index 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(rebuild-index --agent "$agent" --home "$(resolve_agent_home "$agent")" --bridge-home "$bridge_home")
    [[ -n "$db_path" ]] && args+=(--db-path "$db_path")
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  search)
    query=""
    user_id=""
    scope="wiki"
    limit=10
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --query)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          query="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --scope)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          scope="$2"
          shift 2
          ;;
        --limit)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          limit="$2"
          shift 2
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory search 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$query" ]] || bridge_die "--query is required"
    args=(search --agent "$agent" --home "$(resolve_agent_home "$agent")" --query "$query" --scope "$scope" --limit "$limit")
    [[ -n "$user_id" ]] && args+=(--user "$user_id")
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  query)
    query=""
    user_id=""
    scope="all"
    limit=10
    db_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --query)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          query="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --scope)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          scope="$2"
          shift 2
          ;;
        --limit)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          limit="$2"
          shift 2
          ;;
        --db-path)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          db_path="$2"
          shift 2
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory query 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$query" ]] || bridge_die "--query is required"
    args=(query --agent "$agent" --home "$(resolve_agent_home "$agent")" --bridge-home "$bridge_home" --query "$query" --scope "$scope" --limit "$limit")
    [[ -n "$user_id" ]] && args+=(--user "$user_id")
    [[ -n "$db_path" ]] && args+=(--db-path "$db_path")
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  *)
    # Issue #163 Phase 2: surface an intent-recovery hint before dying so
    # "memory <typo>" is aligned with the other dispatchers instead of
    # silently printing usage and exiting 1.
    _hint="$(bridge_suggest_subcommand "$command" \
      "init capture ingest promote remember lint search rebuild-index query")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 memory 명령입니다: $command"
    ;;
esac
