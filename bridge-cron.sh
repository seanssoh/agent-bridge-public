#!/usr/bin/env bash
# bridge-cron.sh — bridge-owned cron inventory, migration, and queue adapters

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") inventory [--agent <agent>] [--family <family>] [--mode recurring|one-shot|all] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") show <job-name-or-id> [--json]
  $(basename "$0") import [--source-jobs-file <path>] [--dry-run]
  $(basename "$0") list [--agent <bridge-agent>] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") create --agent <bridge-agent> (--schedule "<cron-expr>" | --at "<iso-datetime>") --title "<title>" [--payload "<text>" | --payload-file <path>] [--kind text|shell --script <path> --run-as-agent <agent> [--script-arg <arg>] [--script-env KEY=VALUE] [--timeout <seconds>] [--output-cap <bytes>]] [--tz <iana-tz>] [--delete-after-run]
  $(basename "$0") update <job-id> [--agent <bridge-agent>] [--schedule "<cron-expr>" | --at "<iso-datetime>"] [--title "<title>"] [--payload "<text>" | --payload-file <path>] [--kind text|shell --script <path> --run-as-agent <agent> [--script-arg <arg>] [--script-env KEY=VALUE] [--timeout <seconds>] [--output-cap <bytes>] [--allow-kind-transition]] [--tz <iana-tz>] [--enable|--disable] [--delete-after-run|--keep-after-run]
  $(basename "$0") delete <job-id>
  $(basename "$0") rebalance-memory-daily [--jobs-file <path>] [--schedule "<cron-expr>"] [--tz <iana-tz>] [--dry-run] [--json]
  $(basename "$0") migrate-payloads --jsonl-aware [--jobs-file <path>] [--dry-run] [--json]
  $(basename "$0") enqueue <job-name-or-id> [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]
  $(basename "$0") sync [--dry-run] [--json] [--since <iso-datetime>] [--now <iso-datetime>]
  $(basename "$0") run-subagent <run-id> [--dry-run]
  $(basename "$0") errors report [--agent <agent>] [--family <family>] [--limit <count>] [--json]
  $(basename "$0") cleanup report [--mode expired-one-shot] [--json]
  $(basename "$0") cleanup prune [--mode expired-one-shot] [--dry-run]
EOF
}

run_inventory() {
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local py_args=(
    inventory
    --jobs-file "$jobs_file"
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--family|--mode|--enabled|--limit)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        py_args+=("$1" "$2")
        shift 2
        ;;
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_cron_source_jobs "$jobs_file"
  bridge_cron_python "${py_args[@]}"
}

run_show() {
  local job_ref="${1:-}"
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local py_args=(
    show
    --jobs-file "$jobs_file"
  )

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") show <job-name-or-id> [--json]"
  py_args+=("$job_ref")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_cron_source_jobs "$jobs_file"
  bridge_cron_python "${py_args[@]}"
}

run_import() {
  local source_jobs_file="$BRIDGE_SOURCE_CRON_JOBS_FILE"
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-jobs-file)
        [[ $# -lt 2 ]] && bridge_die "--source-jobs-file 뒤에 값을 지정하세요."
        source_jobs_file="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 import 옵션입니다: $1"
        ;;
    esac
  done

  [[ -f "$source_jobs_file" ]] || bridge_die "source cron jobs 파일이 없습니다: $source_jobs_file"
  local py_args=(
    native-import
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    --source-jobs-file "$source_jobs_file"
  )
  if [[ $dry_run -eq 1 ]]; then
    py_args+=(--dry-run)
  fi
  bridge_cron_python "${py_args[@]}"
}

run_list() {
  local py_args=(
    native-list
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--enabled|--limit)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        py_args+=("$1" "$2")
        shift 2
        ;;
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        _hint="$(bridge_suggest_subcommand "cron list $1" "")"
        [[ -n "$_hint" ]] && bridge_warn "$_hint"
        bridge_die "지원하지 않는 list 옵션입니다: $1"
        ;;
    esac
  done

  bridge_cron_python "${py_args[@]}"
}

bridge_cron_validate_shell_run_config() {
  local run_as_agent="$1"
  local script_path="${2:-}"

  [[ -n "$run_as_agent" ]] || bridge_die "--run-as-agent is required for --kind shell"
  bridge_load_roster
  bridge_require_agent "$run_as_agent"
  bridge_agent_linux_user_isolation_effective "$run_as_agent" \
    || bridge_die "--run-as-agent must name a linux-user isolated agent: $run_as_agent"

  local os_user
  os_user="$(bridge_agent_os_user "$run_as_agent")"
  [[ -n "$os_user" ]] || bridge_die "--run-as-agent has no os_user: $run_as_agent"
  if [[ "$run_as_agent" =~ ^[0-9]+$ || "$os_user" =~ ^[0-9]+$ ]]; then
    bridge_die "--run-as-agent must be an agent id, not a numeric UID/user"
  fi

  [[ -n "$script_path" ]] || bridge_die "--script is required for --kind shell"
  local resolved_script="$script_path"
  case "$resolved_script" in
    '$BRIDGE_HOME'|'$BRIDGE_HOME'/*)
      resolved_script="${BRIDGE_HOME}${resolved_script#'$BRIDGE_HOME'}"
      ;;
    *'$'*)
      bridge_die "--script contains an unresolved environment variable: $script_path"
      ;;
  esac
  [[ "$resolved_script" = /* ]] || bridge_die "--script must resolve to an absolute path: $script_path"
  [[ -f "$resolved_script" && -x "$resolved_script" ]] || bridge_die "--script must be an executable file: $resolved_script"

  local owner_uid run_uid controller_uid mode_bits
  owner_uid="$(stat -c '%u' "$resolved_script" 2>/dev/null || true)"
  mode_bits="$(stat -c '%a' "$resolved_script" 2>/dev/null || true)"
  run_uid="$(id -u "$os_user" 2>/dev/null || true)"
  controller_uid="$(id -u)"
  [[ -n "$owner_uid" && -n "$run_uid" ]] || bridge_die "could not resolve --script owner or --run-as-agent uid"
  if [[ "$owner_uid" != "$controller_uid" && "$owner_uid" != "$run_uid" ]]; then
    bridge_die "--script owner must be controller uid or run-as uid: $resolved_script"
  fi
  if (( (8#$mode_bits) & 0022 )); then
    bridge_die "--script must not be group/other writable: $resolved_script"
  fi
}

run_create() {
  local py_args=(
    native-create
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )
  local kind="text"
  local run_as_agent=""
  local script_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--schedule|--at|--title|--payload|--payload-file|--tz|--actor|--kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --kind) kind="$2" ;;
          --run-as-agent) run_as_agent="$2" ;;
          --script) script_path="$2" ;;
        esac
        py_args+=("$1" "$2")
        shift 2
        ;;
      --disabled|--delete-after-run)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 create 옵션입니다: $1"
        ;;
    esac
  done

  if [[ "$kind" == "shell" ]]; then
    bridge_cron_validate_shell_run_config "$run_as_agent" "$script_path"
  fi

  bridge_cron_python "${py_args[@]}"
}

run_update() {
  local job_ref="${1:-}"
  local py_args=(
    native-update
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
  )
  local kind=""
  local run_as_agent=""
  local script_path=""
  local shell_option_seen=0

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") update <job-id> [--agent <bridge-agent>] [--schedule <cron-expr>|--at <iso-datetime>] [--title <title>] [--payload <text>|--payload-file <path>] [--tz <iana-tz>] [--enable|--disable] [--delete-after-run|--keep-after-run]"
  py_args+=("$job_ref")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--schedule|--at|--title|--payload|--payload-file|--tz|--actor|--kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --kind) kind="$2" ;;
          --run-as-agent) run_as_agent="$2" ;;
          --script) script_path="$2" ;;
        esac
        case "$1" in
          --kind|--script|--script-arg|--script-env|--run-as-agent|--timeout|--output-cap)
            shell_option_seen=1
            ;;
        esac
        py_args+=("$1" "$2")
        shift 2
        ;;
      --enable|--disable|--delete-after-run|--keep-after-run|--allow-kind-transition)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 update 옵션입니다: $1"
        ;;
    esac
  done

  local existing_shell_payload=""
  local existing_payload_kind=""
  local existing_script_path=""
  local existing_run_as_agent=""
  existing_shell_payload="$(bridge_cron_python show --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" --format shell "$job_ref" 2>/dev/null || true)"
  if [[ -n "$existing_shell_payload" ]]; then
    local CRON_JOB_PAYLOAD_KIND=""
    local CRON_JOB_PAYLOAD_SHELL_SCRIPT=""
    local CRON_JOB_EXECUTION_RUN_AS_AGENT=""
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$existing_shell_payload")
    existing_payload_kind="$CRON_JOB_PAYLOAD_KIND"
    existing_script_path="$CRON_JOB_PAYLOAD_SHELL_SCRIPT"
    existing_run_as_agent="$CRON_JOB_EXECUTION_RUN_AS_AGENT"
  fi

  if [[ "$existing_payload_kind" == "shell" || "$kind" == "shell" || $shell_option_seen -eq 1 ]]; then
    bridge_cron_validate_shell_run_config "${run_as_agent:-$existing_run_as_agent}" "${script_path:-$existing_script_path}" "update"
  fi

  bridge_cron_python "${py_args[@]}"
}

run_delete() {
  local job_ref="${1:-}"
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") delete <job-id>"
  shift || true
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 delete 옵션입니다: $1"
  bridge_cron_python native-delete --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$job_ref"
}

run_rebalance_memory_daily() {
  local jobs_file="$BRIDGE_NATIVE_CRON_JOBS_FILE"
  local py_args=(native-rebalance-memory-daily)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs-file|--schedule|--tz|--actor)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        if [[ "$1" == "--jobs-file" ]]; then
          jobs_file="$2"
        else
          py_args+=("$1" "$2")
        fi
        shift 2
        ;;
      --dry-run|--json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 rebalance-memory-daily 옵션입니다: $1"
        ;;
    esac
  done

  py_args+=(--jobs-file "$jobs_file")
  bridge_cron_python "${py_args[@]}"
}

# Issue #541 PR-A — operator-driven migration of memory-daily payloads to
# the canonical jsonl-aware body. Mirrors the cleanup-prune surface
# (jobs.json.bak-<timestamp> backup, --dry-run, --json).
run_migrate_payloads() {
  local jobs_file="$BRIDGE_NATIVE_CRON_JOBS_FILE"
  local py_args=(migrate-payloads)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs-file)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        jobs_file="$2"
        shift 2
        ;;
      --jsonl-aware|--dry-run|--json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 migrate-payloads 옵션입니다: $1"
        ;;
    esac
  done

  py_args+=(--jobs-file "$jobs_file")
  bridge_cron_python "${py_args[@]}"
}

write_materialized_payload() {
  local payload_file="$1"
  local slot="$2"
  local source_file="$3"
  local target="$4"
  local delivery_mode="$5"
  local channel_delivery_mode="${6:-}"
  local channel_delivery_channel="${7:-}"
  local channel_delivery_target="${8:-}"
  local allow_channel_delivery="${9:-0}"

  mkdir -p "$(dirname "$payload_file")"
  {
    printf '# [cron] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- source_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- target_agent: %s\n' "$target"
    printf -- '- delivery_mode: %s\n' "$delivery_mode"
    printf -- '- channel_delivery_mode: %s\n' "$channel_delivery_mode"
    printf -- '- channel_delivery_channel: %s\n' "$channel_delivery_channel"
    printf -- '- channel_delivery_target: %s\n' "$channel_delivery_target"
    printf -- '- allow_channel_delivery: %s\n' "$allow_channel_delivery"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- schedule: %s\n' "$CRON_JOB_SCHEDULE_TEXT"
    printf -- '- source_file: %s\n' "$source_file"
    printf -- '- payload_kind: %s\n' "$CRON_JOB_PAYLOAD_KIND"
    printf '\n## Original Payload\n\n'
    printf '%s\n' "$CRON_JOB_PAYLOAD_TEXT"
  } >"$payload_file"
}

write_dispatch_body() {
  local body_file="$1"
  local slot="$2"
  local run_id="$3"
  local payload_file="$4"
  local request_file="$5"
  local result_file="$6"
  local status_file="$7"
  local target="$8"
  local target_engine="$9"
  local delivery_mode="${10}"
  local channel_delivery_mode="${11:-}"
  local channel_delivery_channel="${12:-}"
  local channel_delivery_target="${13:-}"
  local allow_channel_delivery="${14:-0}"

  mkdir -p "$(dirname "$body_file")"
  {
    printf '# [cron-dispatch] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- run_id: %s\n' "$run_id"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- target_agent: %s\n' "$target"
    printf -- '- target_engine: %s\n' "$target_engine"
    printf -- '- delivery_mode: %s\n' "$delivery_mode"
    printf -- '- channel_delivery_mode: %s\n' "$channel_delivery_mode"
    printf -- '- channel_delivery_channel: %s\n' "$channel_delivery_channel"
    printf -- '- channel_delivery_target: %s\n' "$channel_delivery_target"
    printf -- '- allow_channel_delivery: %s\n' "$allow_channel_delivery"
    printf -- '- source_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- payload_file: %s\n' "$payload_file"
    printf -- '- request_file: %s\n' "$request_file"
    printf -- '- result_file: %s\n' "$result_file"
    printf -- '- status_file: %s\n' "$status_file"
    printf '\n## Instruction\n\n'
    printf 'This dispatch task is owned by the bridge daemon.\n\n'
    printf '1. The daemon claims this task and runs `agent-bridge cron run-subagent %s`\n' "$run_id"
    printf '2. The disposable child writes structured result artifacts under `state/cron/runs/%s/`\n' "$run_id"
    printf '3. The daemon closes this dispatch task when the child finishes\n'
    printf '4. If human follow-up is still needed, the daemon creates a separate `[cron-followup]` queue task\n'
    if [[ "$delivery_mode" == "fallback" ]]; then
      printf '5. This run was routed through the cron fallback agent because `%s` is not a registered cron delivery role\n' "$CRON_JOB_AGENT"
    fi
  } >"$body_file"
}

build_shell_env_snapshot_json() {
  local run_as_agent="$1"
  local os_user="$2"
  local run_home="$3"
  local agent_env_file="$4"

  (
    set -a
    if [[ -f "$agent_env_file" ]]; then
      # shellcheck source=/dev/null
      source "$agent_env_file"
    fi
    set +a
    export HOME="$run_home"
    export USER="$os_user"
    export LOGNAME="$os_user"
    export BRIDGE_AGENT_ID="$run_as_agent"
    export BRIDGE_AGENT_NAME="$run_as_agent"
    export BRIDGE_AGENT_ENV_FILE="$agent_env_file"
    export BRIDGE_CONTROLLER_UID="${BRIDGE_CONTROLLER_UID:-$(id -u)}"
    export BRIDGE_GATEWAY_PROXY=1
    bridge_require_python
    python3 - <<'PY'
import json
import os

exact = {
    "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL",
}
payload = {}
for key, value in os.environ.items():
    if key in exact or key.startswith("BRIDGE_"):
        payload[key] = value
print(json.dumps(payload, ensure_ascii=True, sort_keys=True))
PY
  )
}

run_enqueue() {
  local job_ref=""
  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  local slot=""
  local target=""
  local actor=""
  local priority="normal"
  local dry_run=0
  local title=""
  local body_file=""
  local manifest_file=""
  local manifest_rel=""
  local body_rel=""
  local request_file=""
  local request_rel=""
  local result_file=""
  local result_rel=""
  local status_file=""
  local status_rel=""
  local payload_file=""
  local payload_rel=""
  local stdout_log=""
  local stderr_log=""
  local run_id=""
  local target_engine=""
  local target_workdir=""
  local create_output=""
  local task_id=""
  local created_at=""
  local shell_payload=""
  local delivery_mode="resolved"
  local fallback_agent=""
  local job_delivery_mode=""
  local job_delivery_channel=""
  local job_delivery_target=""
  local allow_channel_delivery="0"
  local disposable_needs_channels="0"
  local disable_mcp="0"
  local target_channels=""
  local target_discord_state_dir=""
  local target_telegram_state_dir=""
  local shell_run_as_agent=""
  local shell_os_user=""
  local shell_uid=""
  local shell_gid=""
  local shell_home=""
  local shell_agent_env_file=""
  local shell_env_snapshot_json="{}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot|--target|--from|--priority|--jobs-file)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --jobs-file) jobs_file="$2" ;;
          --slot) slot="$2" ;;
          --target) target="$2" ;;
          --from) actor="$2" ;;
          --priority) priority="$2" ;;
        esac
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$job_ref" ]]; then
          job_ref="$1"
          shift
          continue
        fi
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") enqueue <job-name-or-id> [--jobs-file <path>] [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]"
  bridge_require_cron_source_jobs "$jobs_file"

  case "$priority" in
    normal|high) ;;
    *)
      bridge_die "--priority는 normal 또는 high만 지원합니다."
      ;;
  esac

  [[ -f "$jobs_file" ]] || bridge_die "cron jobs 파일이 없습니다: $jobs_file"
  bridge_load_roster

  local CRON_JOB_ID=""
  local CRON_JOB_NAME=""
  local CRON_JOB_AGENT=""
  local CRON_JOB_FAMILY=""
  local CRON_JOB_KIND=""
  local CRON_JOB_ENABLED=""
  local CRON_JOB_SCHEDULE_TEXT=""
  local CRON_JOB_NEXT_RUN_AT=""
  local CRON_JOB_PAYLOAD_KIND=""
  local CRON_JOB_PAYLOAD_TEXT=""
  local CRON_JOB_PAYLOAD_SHELL_SCRIPT=""
  local CRON_JOB_PAYLOAD_SHELL_ARGS="[]"
  local CRON_JOB_PAYLOAD_SHELL_ENV="{}"
  local CRON_JOB_PAYLOAD_SHELL_TIMEOUT_SECONDS=""
  local CRON_JOB_PAYLOAD_SHELL_OUTPUT_CAP_BYTES=""
  local CRON_JOB_EXECUTION_RUN_AS_AGENT=""

  shell_payload="$(bridge_cron_python show --jobs-file "$jobs_file" --format shell "$job_ref")" || exit $?
  # shellcheck disable=SC1090
  source <(printf '%s\n' "$shell_payload")

  [[ "$CRON_JOB_ENABLED" == "1" ]] || bridge_die "비활성 cron job은 enqueue할 수 없습니다: $CRON_JOB_NAME"
  case "$CRON_JOB_KIND" in
    recurring|one-shot) ;;
    *)
      bridge_die "지원하지 않는 cron job kind 입니다: $CRON_JOB_NAME ($CRON_JOB_KIND)"
      ;;
  esac

  if [[ -z "$slot" ]]; then
    slot="$(bridge_cron_slot_for_job "$CRON_JOB_KIND" "$CRON_JOB_FAMILY" "$CRON_JOB_NEXT_RUN_AT")"
  fi

  if [[ -n "$target" ]]; then
    bridge_require_cron_delivery_target "$target"
    delivery_mode="explicit"
  else
    target="$(bridge_resolve_cron_target "$CRON_JOB_AGENT" || true)"
    if [[ -n "$target" ]]; then
      delivery_mode="mapped"
    else
      fallback_agent="$(bridge_cron_fallback_agent || true)"
      if [[ -z "$fallback_agent" ]]; then
        bridge_die "cron target을 찾지 못했습니다: $CRON_JOB_AGENT (등록된 cron delivery role 매핑이나 BRIDGE_CRON_FALLBACK_AGENT/admin role이 필요합니다)"
      fi
      target="$fallback_agent"
      delivery_mode="fallback"
    fi
  fi

  actor="${actor:-cron:$CRON_JOB_NAME}"
  title="[cron-dispatch] $CRON_JOB_NAME ($slot)"

  # Issue #1327 (v0.15.0-beta5-2 Lane μ M4): honor the operator's
  # manual-stop intent at the dispatch site. The daemon-side
  # `bridge_daemon_cron_dispatch_wake` already refuses to wake a
  # manually-stopped static agent for an existing queued cron-dispatch
  # row, but the enqueue path itself still creates the queue task —
  # which then sits in the queue until the operator clears the
  # manual-stop flag (or worse, an autostart later picks it up after
  # the wake-side gate cleared). Block at enqueue so the row never
  # exists; the wake-side gate stays as a defense-in-depth
  # check for the auto-stop / agent-restart race (edge case 1).
  #
  # Distinguishes manual-stop (operator intent, honor here) from any
  # other "agent currently down" condition (autostart backoff,
  # broken-launch quarantine, daemon-side throttle, etc.). Those
  # cases stay handled by the wake-side path and allow re-attempt;
  # only manual-stop is honored at enqueue (edge case 2). The check
  # is gated on `bridge_agent_manual_stop_active` being declared so a
  # smoke harness that loads `bridge-cron.sh` without `bridge-state.sh`
  # (rare path — full upgrade flow always sources both) does not
  # surface as an undefined-function error; in that case the gate is
  # treated as inactive and the row is enqueued normally.
  if declare -F bridge_agent_manual_stop_active >/dev/null 2>&1 \
      && bridge_agent_manual_stop_active "$target" 2>/dev/null; then
    if declare -F bridge_audit_log >/dev/null 2>&1; then
      bridge_audit_log cron cron_dispatch_skipped "$target" \
        --detail job_name="$CRON_JOB_NAME" \
        --detail job_id="$CRON_JOB_ID" \
        --detail family="$CRON_JOB_FAMILY" \
        --detail slot="$slot" \
        --detail reason=manual_stop 2>/dev/null || true
    fi
    bridge_warn "cron-dispatch skipped ${target} (reason=manual_stop, job=${CRON_JOB_NAME} slot=${slot})"
    printf 'status: skipped\n'
    printf 'reason: manual_stop\n'
    printf 'target: %s\n' "$target"
    printf 'job_name: %s\n' "$CRON_JOB_NAME"
    printf 'slot: %s\n' "$slot"
    return 0
  fi

  run_id="$(bridge_cron_run_id "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  request_file="$(bridge_cron_request_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  result_file="$(bridge_cron_result_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  status_file="$(bridge_cron_status_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stdout_log="$(bridge_cron_stdout_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stderr_log="$(bridge_cron_stderr_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  payload_file="$(bridge_cron_payload_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  body_file="$(bridge_cron_body_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  manifest_file="$(bridge_cron_manifest_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  target_engine="$(bridge_agent_engine "$target")"
  target_workdir="$(bridge_agent_workdir "$target")"
  target_channels="$(bridge_agent_channels_csv "$target")"
  target_discord_state_dir="$(bridge_agent_discord_state_dir "$target")"
  target_telegram_state_dir="$(bridge_agent_telegram_state_dir "$target")"
  job_delivery_mode="${CRON_JOB_JOB_DELIVERY_MODE:-}"
  job_delivery_channel="${CRON_JOB_JOB_DELIVERY_CHANNEL:-}"
  job_delivery_target="${CRON_JOB_JOB_DELIVERY_TARGET:-}"
  allow_channel_delivery="${CRON_JOB_ALLOW_CHANNEL_DELIVERY:-0}"
  disposable_needs_channels="${CRON_JOB_DISPOSABLE_NEEDS_CHANNELS:-0}"
  disable_mcp="${CRON_JOB_DISABLE_MCP:-0}"
  # PR1.2 / PR1.6 — per-job cron reporting policy override (Sean Q-B
  # 2026-05-02: default | always_main_session | always_silent) and the
  # urgency hint that maps to the inbox task priority. Empty string
  # = use runner-side defaults (default policy, normal priority).
  cron_reporting_policy="${CRON_JOB_CRON_REPORTING_POLICY:-}"
  cron_urgency="${CRON_JOB_CRON_URGENCY:-}"
  shell_run_as_agent=""
  shell_os_user=""
  shell_uid=""
  shell_gid=""
  shell_home=""
  shell_agent_env_file=""
  shell_env_snapshot_json="{}"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    shell_run_as_agent="${CRON_JOB_EXECUTION_RUN_AS_AGENT:-}"
    [[ -n "$shell_run_as_agent" ]] || bridge_die "shell cron job is missing execution.runAsAgent: $CRON_JOB_NAME"
    bridge_require_agent "$shell_run_as_agent"
    bridge_agent_linux_user_isolation_effective "$shell_run_as_agent" \
      || bridge_die "shell cron run_as_agent must be linux-user isolated: $shell_run_as_agent"
    shell_os_user="$(bridge_agent_os_user "$shell_run_as_agent")"
    [[ -n "$shell_os_user" ]] || bridge_die "shell cron run_as_agent has no os_user: $shell_run_as_agent"
    [[ ! "$shell_run_as_agent" =~ ^[0-9]+$ && ! "$shell_os_user" =~ ^[0-9]+$ ]] \
      || bridge_die "shell cron run_as_agent must be an agent id, not numeric UID/user"
    shell_uid="$(id -u "$shell_os_user")"
    shell_gid="$(id -g "$shell_os_user")"
    shell_home="$(getent passwd "$shell_os_user" | awk -F: '{print $6}' | head -n1)"
    [[ -n "$shell_home" ]] || shell_home="$(bridge_agent_linux_user_home "$shell_os_user")"
    shell_agent_env_file="$(bridge_agent_linux_env_file "$shell_run_as_agent")"
    if [[ ! -f "$shell_agent_env_file" ]] && command -v bridge_write_linux_agent_env_file >/dev/null 2>&1; then
      bridge_write_linux_agent_env_file "$shell_run_as_agent" "$shell_agent_env_file"
    fi
    shell_env_snapshot_json="$(build_shell_env_snapshot_json "$shell_run_as_agent" "$shell_os_user" "$shell_home" "$shell_agent_env_file")"
  fi
  request_rel="${request_file#$BRIDGE_HOME/}"
  result_rel="${result_file#$BRIDGE_HOME/}"
  status_rel="${status_file#$BRIDGE_HOME/}"
  payload_rel="${payload_file#$BRIDGE_HOME/}"
  body_rel="${body_file#$BRIDGE_HOME/}"
  manifest_rel="${manifest_file#$BRIDGE_HOME/}"

  if [[ -f "$manifest_file" || -f "$request_file" ]]; then
    # Issue #219: pre-queue ordering writes request/manifest with
    # dispatch_task_id=0 before creating the queue task. If queue create (or
    # the subsequent task-id patch) failed on the previous pass, the run_dir
    # is stranded — there is no queue task to claim it. Validate that the
    # existing artifacts carry a positive task_id; if not, treat the run as
    # recoverable and fall through to re-enqueue (artifacts will be
    # overwritten by the same run_id).
    existing_task_id=""
    if [[ -f "$request_file" ]]; then
      existing_task_id="$("${BRIDGE_PYTHON:-python3}" -c 'import json,sys;
try:
  d=json.load(open(sys.argv[1]))
  v=d.get("dispatch_task_id")
  print(int(v) if v is not None else 0)
except Exception:
  print(0)' "$request_file" 2>/dev/null || echo 0)"
    fi
    if [[ -n "$existing_task_id" && "$existing_task_id" != "0" ]]; then
      printf 'status: already_enqueued\n'
      printf 'job: %s\n' "$CRON_JOB_NAME"
      printf 'slot: %s\n' "$slot"
      printf 'target: %s\n' "$target"
      printf 'run_id: %s\n' "$run_id"
      printf 'request_file: %s\n' "$request_rel"
      printf 'manifest: %s\n' "$manifest_rel"
      return 0
    fi
    # Stranded run from a prior failed dispatch. Clean the partial artifacts
    # so the new pass can produce a coherent run_dir.
    printf 'notice: clearing stranded pre-queue artifacts for run_id=%s (dispatch_task_id=0)\n' "$run_id" >&2
    rm -f "$request_file" "$status_file" "$manifest_file"
  fi

  if [[ $dry_run -eq 1 ]]; then
    printf 'status: dry_run\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'family: %s\n' "$CRON_JOB_FAMILY"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'delivery_mode: %s\n' "$delivery_mode"
    printf 'engine: %s\n' "$target_engine"
    printf 'actor: %s\n' "$actor"
    printf 'priority: %s\n' "$priority"
    printf 'title: %s\n' "$title"
    printf 'run_id: %s\n' "$run_id"
    printf 'body_file: %s\n' "$body_rel"
    printf 'payload_file: %s\n' "$payload_rel"
    printf 'request_file: %s\n' "$request_rel"
    printf 'result_file: %s\n' "$result_rel"
    printf 'status_file: %s\n' "$status_rel"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  write_materialized_payload "$payload_file" "$slot" "$jobs_file" "$target" "$delivery_mode" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery"
  write_dispatch_body "$body_file" "$slot" "$run_id" "$payload_file" "$request_file" "$result_file" "$status_file" "$target" "$target_engine" "$delivery_mode" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery"

  # Ordering (issue #219): write run_dir artifacts + grant ACLs BEFORE queue
  # task creation so that a daemon worker which immediately claims cannot
  # race ahead of missing request/status/manifest or missing per-run ACLs.
  # task_id=0 is a sentinel placeholder; real queue id is patched in below
  # via bridge_cron_update_*_task_id once the queue record exists.
  created_at="$(bridge_now_iso)"
  bridge_cron_write_request "$request_file" "$run_id" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "0" "$created_at" "$body_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$jobs_file" "$CRON_JOB_PAYLOAD_KIND" "$target_engine" "$target_workdir" "$target_channels" "$target_discord_state_dir" "$target_telegram_state_dir" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$delivery_mode" "$disposable_needs_channels" "$disable_mcp" "$cron_reporting_policy" "$cron_urgency" "$CRON_JOB_PAYLOAD_SHELL_SCRIPT" "$CRON_JOB_PAYLOAD_SHELL_ARGS" "$CRON_JOB_PAYLOAD_SHELL_ENV" "$shell_run_as_agent" "$shell_os_user" "$shell_uid" "$shell_gid" "$shell_home" "$shell_agent_env_file" "$shell_env_snapshot_json" "$CRON_JOB_PAYLOAD_SHELL_TIMEOUT_SECONDS" "$CRON_JOB_PAYLOAD_SHELL_OUTPUT_CAP_BYTES"
  bridge_cron_write_status "$status_file" "$run_id" "queued" "$target_engine" "$request_file" "$result_file" "$created_at"
  bridge_cron_write_manifest "$manifest_file" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "0" "$created_at" "$body_file" "$jobs_file" "$run_id" "$request_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$delivery_mode" "$disposable_needs_channels" "$cron_reporting_policy" "$cron_urgency"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    bridge_cron_normalize_shell_run_artifacts "$(bridge_cron_run_dir_by_id "$run_id")" "$request_file" "$status_file" "$payload_file"
  fi
  # Per-run ACL grant is best-effort under v1.3 (#219): the memory-daily
  # harvester now runs as the controller UID, so it does not need the
  # isolated os_user to own/rwX the per-run dir. Other families that do
  # spawn isolated subprocesses can still rely on the grant when sudo/acl
  # infrastructure is available; failure here is non-fatal and does NOT
  # remove the pre-queue artifacts.
  if [[ "$CRON_JOB_PAYLOAD_KIND" != "shell" ]]; then
    bridge_cron_run_dir_grant_isolation "$(bridge_cron_run_dir_by_id "$run_id")" "$target" >/dev/null 2>&1 || true
  fi

  create_output="$(bridge_queue_cli create --to "$target" --title "$title" --from "$actor" --priority "$priority" --body-file "$body_file")"
  printf '%s\n' "$create_output"

  if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    bridge_die "생성된 task id를 파싱하지 못했습니다."
  fi

  bridge_cron_update_request_task_id "$request_file" "$task_id"
  bridge_cron_update_manifest_task_id "$manifest_file" "$task_id"
  if [[ "$CRON_JOB_PAYLOAD_KIND" == "shell" ]]; then
    bridge_cron_normalize_shell_run_artifacts "$(bridge_cron_run_dir_by_id "$run_id")" "$request_file" "$status_file" "$payload_file"
  fi

  printf 'run_id: %s\n' "$run_id"
  printf 'request_file: %s\n' "$request_rel"
  printf 'result_file: %s\n' "$result_rel"
  printf 'status_file: %s\n' "$status_rel"
  printf 'manifest: %s\n' "$manifest_rel"
}

run_subagent() {
  local run_id="${1:-}"
  local dry_run=0
  local request_file=""
  local args=()

  shift || true
  [[ -n "$run_id" ]] || bridge_die "Usage: $(basename "$0") run-subagent <run-id> [--dry-run]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 run-subagent 옵션입니다: $1"
        ;;
    esac
  done

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  [[ -f "$request_file" ]] || bridge_die "cron run request를 찾지 못했습니다: $run_id"

  args=(run --request-file "$request_file")
  if [[ $dry_run -eq 1 ]]; then
    args+=(--dry-run)
  fi

  bridge_cron_runner_python "${args[@]}"
}

run_finalize() {
  local run_id="${1:-}"
  local json_output=0
  local request_file=""

  shift || true
  [[ -n "$run_id" ]] || bridge_die "Usage: $(basename "$0") finalize-run <run-id> [--json]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_output=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 finalize-run 옵션입니다: $1"
        ;;
    esac
  done

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  [[ -f "$request_file" ]] || bridge_die "cron run request를 찾지 못했습니다: $run_id"

  local args=(
    native-finalize-run
    --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    --request-file "$request_file"
  )
  if [[ $json_output -eq 1 ]]; then
    args+=(--json)
  fi
  bridge_cron_python "${args[@]}"
}

run_sync() {
  local dry_run=0
  local json_output=0
  local since=""
  local now=""
  local native_state_file=""
  local compat_native_state_file="$BRIDGE_CRON_STATE_DIR/native-scheduler-state.json"
  local tmp_dir=""
  local reconcile_json=""
  local legacy_json=""
  local native_json=""
  local cleanup_json=""
  local status=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      --since|--now)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --since) since="$2" ;;
          --now) now="$2" ;;
        esac
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 sync 옵션입니다: $1"
        ;;
    esac
  done

  if [[ ! -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    printf 'status: skipped\n'
    printf 'reason: no_native_cron_jobs_file\n'
    printf 'native_jobs_file: %s\n' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    return 0
  fi

  # Issue #1328 (v0.15.0-beta5-2 Lane μ M5): verify cron-state-dir anchor
  # and migrate the old tree if the env-resolved path moved. Best-effort,
  # never aborts sync. See `bridge_cron_state_dir_verify_and_migrate` for
  # the full edge-case matrix.
  if declare -F bridge_cron_state_dir_verify_and_migrate >/dev/null 2>&1; then
    bridge_cron_state_dir_verify_and_migrate >/dev/null 2>&1 || true
  fi

  native_state_file="$(bridge_cron_scheduler_state_file)"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  if [[ $dry_run -eq 0 ]]; then
    if ! bridge_cron_python reconcile-run-state \
      --tasks-db "$BRIDGE_TASK_DB" \
      --runs-dir "$BRIDGE_CRON_STATE_DIR/runs" \
      --json >"$tmp_dir/reconcile.json"; then
      status=1
    fi
    reconcile_json="$tmp_dir/reconcile.json"
  fi

  if [[ -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    local native_args=(
      sync
      --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
      --state-file "$native_state_file"
      --bridge-cron "$SCRIPT_DIR/bridge-cron.sh"
      --repo-root "$SCRIPT_DIR"
      --enqueue-jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE"
      --json
    )
    if [[ -n "$since" ]]; then
      native_args+=(--since "$since")
    fi
    if [[ -n "$now" ]]; then
      native_args+=(--now "$now")
    fi
    if [[ $dry_run -eq 1 ]]; then
      native_args+=(--dry-run)
    fi
    if ! bridge_cron_scheduler_python "${native_args[@]}" >"$tmp_dir/native.json"; then
      status=1
    fi
    native_json="$tmp_dir/native.json"

    if [[ $dry_run -eq 0 && -f "$native_state_file" && "$compat_native_state_file" != "$native_state_file" ]]; then
      cp "$native_state_file" "$compat_native_state_file"
    fi

    if [[ $dry_run -eq 0 ]]; then
      if ! bridge_cron_python cleanup-prune \
        --jobs-file "$BRIDGE_NATIVE_CRON_JOBS_FILE" \
        --mode expired-one-shot \
        --json >"$tmp_dir/native-cleanup.json"; then
        status=1
      fi
      cleanup_json="$tmp_dir/native-cleanup.json"

      # Issue #533 — opt-in periodic GC for cron run artifacts. Default OFF
      # to preserve current sync behavior exactly. Operators can enable
      # hands-off retention via:
      #   BRIDGE_CRON_RUN_ARTIFACTS_GC=1 (and optional
      #   BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS=<N> single-knob).
      # Failures here do NOT flip $status — retention is best-effort and
      # must not block scheduler tick visibility.
      if [[ "${BRIDGE_CRON_RUN_ARTIFACTS_GC:-0}" == "1" ]]; then
        local rga_args=(
          cleanup-prune
          --mode run-artifacts
          --target-root "$BRIDGE_HOME"
          --tasks-db "$BRIDGE_TASK_DB"
          --json
        )
        if [[ -n "${BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS:-}" ]]; then
          rga_args+=(--older-than-days "$BRIDGE_CRON_RUN_ARTIFACTS_OLDER_THAN_DAYS")
        fi
        bridge_cron_python "${rga_args[@]}" 2>/dev/null >"$tmp_dir/native-run-artifacts-cleanup.json" || true
      fi
    fi
  fi

  bridge_require_python
  python3 - "$legacy_json" "$native_json" "$cleanup_json" "$reconcile_json" "$json_output" <<'PY'
import json
import sys
from pathlib import Path

legacy_path, native_path, cleanup_path, reconcile_path, json_output = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"

def load(path_value):
    if not path_value:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))

sources = {}
for name, path_value in (("legacy", legacy_path), ("native", native_path)):
    payload = load(path_value)
    if payload is not None:
        sources[name] = payload
cleanup_payload = load(cleanup_path)
reconcile_payload = load(reconcile_path)

if not sources:
    payload = {"status": "skipped", "reason": "no_sources"}
    if json_output:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("status: skipped")
        print("reason: no_sources")
    raise SystemExit(0)

totals = {
    "eligible_jobs": 0,
    "due_occurrences": 0,
    "created": 0,
    "already_enqueued": 0,
    "errors": 0,
    "cleanup_deleted_jobs": 0,
    "reconciled_cancelled_runs": 0,
}
statuses = []
for source_payload in sources.values():
    summary = source_payload.get("summary", {})
    totals["eligible_jobs"] += int(summary.get("eligible", 0))
    totals["due_occurrences"] += int(summary.get("due_occurrences", 0))
    totals["created"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "created")
    totals["already_enqueued"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "already_enqueued")
    totals["errors"] += sum(1 for item in source_payload.get("results", []) if item.get("status") == "error")
    statuses.append(source_payload.get("status", "ok"))
if cleanup_payload is not None:
    totals["cleanup_deleted_jobs"] = int(cleanup_payload.get("deleted_jobs", 0))
if reconcile_payload is not None:
    totals["reconciled_cancelled_runs"] = int(reconcile_payload.get("repaired_runs", 0))

if any(status == "error" for status in statuses) or totals["errors"] > 0:
    status_value = "error"
elif statuses and all(status == "dry_run" for status in statuses):
    status_value = "dry_run"
else:
    status_value = "ok"

payload = {
    "status": status_value,
    "sources": sources,
    "cleanup": cleanup_payload,
    "reconcile": reconcile_payload,
    "totals": totals,
}

if json_output:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
else:
    print(f"status: {status_value}")
    print(f"sources: {', '.join(sorted(sources))}")
    for name in sorted(sources):
        source_payload = sources[name]
        summary = source_payload.get("summary", {})
        results = source_payload.get("results", [])
        created = sum(1 for item in results if item.get("status") == "created")
        already = sum(1 for item in results if item.get("status") == "already_enqueued")
        errors = sum(1 for item in results if item.get("status") == "error")
        print(
            f"{name}: status={source_payload.get('status', 'ok')} "
            f"eligible={summary.get('eligible', 0)} "
            f"due={summary.get('due_occurrences', 0)} "
            f"created={created} already_enqueued={already} errors={errors}"
        )
    print(f"eligible_jobs: {totals['eligible_jobs']}")
    print(f"due_occurrences: {totals['due_occurrences']}")
    print(f"created: {totals['created']}")
    print(f"already_enqueued: {totals['already_enqueued']}")
    print(f"errors: {totals['errors']}")
    if cleanup_payload is not None:
        print(f"cleanup_deleted_jobs: {totals['cleanup_deleted_jobs']}")
    if reconcile_payload is not None:
        print(f"reconciled_cancelled_runs: {totals['reconciled_cancelled_runs']}")
PY
  return "$status"
}

run_errors() {
  local errors_cmd="${1:-}"
  shift || true

  # Issue #1114: short-circuit -h/--help/help BEFORE the
  # bridge_require_cron_source_jobs guard so `cron errors --help` works
  # on hosts without a populated cron source jobs file.
  case "$errors_cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  local jobs_file
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  bridge_require_cron_source_jobs "$jobs_file"

  case "$errors_cmd" in
    report)
      local py_args=(
        errors-report
        --jobs-file "$jobs_file"
      )
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --agent|--family|--limit)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 errors report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 errors 명령입니다: ${errors_cmd:-<none>}"
      ;;
  esac
}

run_cleanup() {
  local cleanup_cmd="${1:-}"
  shift || true

  # Issue #1114: short-circuit -h/--help/help BEFORE the
  # bridge_require_cron_source_jobs guard so `cron cleanup --help` works
  # on hosts without a populated cron source jobs file.
  case "$cleanup_cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  # Issue #533 — for `--mode run-artifacts` and `--mode all` the cleanup
  # operates on BRIDGE_HOME directly and does not need a jobs file. We
  # peek at the args to decide whether to require the source jobs file.
  local _peek_mode="expired-one-shot"
  local _arg
  for _arg in "$@"; do
    if [[ "$_arg" == "run-artifacts" || "$_arg" == "all" || "$_arg" == "one-shot" || "$_arg" == "expired-one-shot" ]]; then
      _peek_mode="$_arg"
    fi
  done

  local jobs_file=""
  if [[ "$_peek_mode" != "run-artifacts" ]]; then
    jobs_file="$(bridge_cron_source_jobs_file || true)"
    bridge_require_cron_source_jobs "$jobs_file"
  fi

  case "$cleanup_cmd" in
    report)
      local py_args=(cleanup-report)
      [[ -n "$jobs_file" ]] && py_args+=(--jobs-file "$jobs_file")
      py_args+=(--target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB")
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode|--older-than-days|--target-root|--tasks-db)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    prune)
      local py_args=(cleanup-prune)
      [[ -n "$jobs_file" ]] && py_args+=(--jobs-file "$jobs_file")
      py_args+=(--target-root "$BRIDGE_HOME" --tasks-db "$BRIDGE_TASK_DB")
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode|--older-than-days|--target-root|--tasks-db)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --dry-run|--json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup prune 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 cleanup 명령입니다: ${cleanup_cmd:-<none>}"
      ;;
  esac
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  inventory)
    run_inventory "$@"
    ;;
  show)
    run_show "$@"
    ;;
  import)
    run_import "$@"
    ;;
  list)
    run_list "$@"
    ;;
  create)
    run_create "$@"
    ;;
  update)
    run_update "$@"
    ;;
  delete)
    run_delete "$@"
    ;;
  rebalance-memory-daily)
    run_rebalance_memory_daily "$@"
    ;;
  migrate-payloads)
    run_migrate_payloads "$@"
    ;;
  enqueue)
    run_enqueue "$@"
    ;;
  sync)
    run_sync "$@"
    ;;
  run-subagent)
    run_subagent "$@"
    ;;
  finalize-run)
    run_finalize "$@"
    ;;
  errors)
    run_errors "$@"
    ;;
  cleanup)
    run_cleanup "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    # Issue #163: attach an intent-recovery suggestion before dying so the
    # caller sees "혹시 X?" instead of just the bare rejection.
    # Refs #1116: `finalize-run` is an internal runtime callback (only
    # bridge-daemon.sh invokes it on cron run completion) — keep it
    # dispatchable above but absent from this typo-suggestion list so
    # operators don't reverse-engineer it from the rejection path. Every
    # other entry is operator-facing.
    _hint="$(bridge_suggest_subcommand "cron $subcommand" \
      "inventory show import list create update delete rebalance-memory-daily migrate-payloads enqueue sync run-subagent errors cleanup")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 cron 명령입니다: $subcommand"
    ;;
esac
