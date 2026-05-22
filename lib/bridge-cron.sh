#!/usr/bin/env bash
# shellcheck shell=bash

# PR #951 r7 (#946 L1): tests/memory-daily-harvest/smoke.sh sources this
# file via `bash -c` without bridge-lib.sh, so bridge_resolve_script_dir_check
# (defined in bridge-core.sh) would be undefined. Source bridge-core.sh
# idempotently; full-loader path is a no-op via the declare -F gate.
if ! declare -F bridge_resolve_script_dir_check >/dev/null 2>&1; then
  # shellcheck source=lib/bridge-core.sh
  source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/bridge-core.sh"
fi

# PR #953 r2 (refs #4807, codex r1 P2): the cron-helpers wrappers added in
# r1 (bridge_cron_default_slot, bridge_cron_slot_from_datetime, bridge_cron_
# safe_component, bridge_cron_actions_taken_contains, etc.) call
# `python3 "$BRIDGE_SCRIPT_DIR/lib/cron-helpers/<name>.py"` directly without
# going through bridge_cron_python's `bridge_resolve_script_dir_check` guard.
# Direct-source consumers (tests/memory-daily-harvest/smoke.sh scenario 10
# does `bash -c "source lib/bridge-cron.sh && bridge_cron_actions_taken_
# contains ..."` without bridge-lib.sh) leave BRIDGE_SCRIPT_DIR unset, so the
# helper paths expand to `/lib/cron-helpers/<name>.py` and python3 fails with
# [Errno 2]. Derive BRIDGE_SCRIPT_DIR from BASH_SOURCE here (same shape as
# bridge_resolve_script_dir_check's BASH_SOURCE recovery branch) so the
# wrappers can dispatch without each adding their own guard. The full-loader
# path (bridge-lib.sh sets BRIDGE_SCRIPT_DIR before sourcing this file) is a
# no-op via the := default-if-unset pattern.
if [[ -z "${BRIDGE_SCRIPT_DIR:-}" ]]; then
  _bridge_cron_resolved_script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P 2>/dev/null)" || _bridge_cron_resolved_script_dir=""
  if [[ -n "$_bridge_cron_resolved_script_dir" && -d "$_bridge_cron_resolved_script_dir/scripts/python-helpers" ]]; then
    BRIDGE_SCRIPT_DIR="$_bridge_cron_resolved_script_dir"
    export BRIDGE_SCRIPT_DIR
  fi
  unset _bridge_cron_resolved_script_dir
fi

bridge_require_legacy_cron_jobs() {
  if [[ -f "$BRIDGE_SOURCE_CRON_JOBS_FILE" ]]; then
    return 0
  fi

  bridge_die "legacy cron jobs 파일이 없습니다: $BRIDGE_SOURCE_CRON_JOBS_FILE"
}

bridge_require_openclaw_cron_jobs() {
  bridge_require_legacy_cron_jobs "$@"
}

bridge_cron_source_jobs_file() {
  if [[ -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    printf '%s\n' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    return 0
  fi
  if [[ -f "$BRIDGE_SOURCE_CRON_JOBS_FILE" ]]; then
    printf '%s\n' "$BRIDGE_SOURCE_CRON_JOBS_FILE"
    return 0
  fi
  return 1
}

bridge_require_cron_source_jobs() {
  local jobs_file="${1:-}"
  if [[ -n "$jobs_file" && -f "$jobs_file" ]]; then
    return 0
  fi
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  [[ -n "$jobs_file" ]] && return 0
  bridge_die "cron jobs 파일이 없습니다: $BRIDGE_NATIVE_CRON_JOBS_FILE"
}

bridge_cron_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron.py" "$@"
}

bridge_cron_runner_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron-runner.py" "$@"
}

bridge_cron_scheduler_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron-scheduler.py" "$@"
}

# PR #953 r3 (refs #4807, codex r2 P2 #1): centralized dispatcher for the
# lib/cron-helpers/*.py extraction helpers. The thirteen helper invocations
# below previously expanded `python3 "$BRIDGE_SCRIPT_DIR/lib/cron-helpers/
# <name>.py" "$@"` inline without first re-validating BRIDGE_SCRIPT_DIR. If
# the source checkout moved or BRIDGE_SCRIPT_DIR was inherited stale, the
# helper path expanded to a `[Errno 2]` while consuming `source <(...)` /
# `... | grep` patterns silently swallowed the failure — the daemon then
# continued with blank CRON_* env, which is the 13h cron-worker hang shape.
# Routing every helper through this wrapper guarantees the same per-call
# stale-source guard the `bridge_cron_python` family already enforces.
bridge_cron_helper_python() {
  local helper="${1:-}"
  [[ -n "$helper" ]] || return 1
  shift || true
  bridge_require_python
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/lib/cron-helpers/$helper.py" "$@"
}

bridge_cron_default_slot() {
  local family="${1:-memory-daily}"

  case "$family" in
    monthly-highlights)
      TZ=Asia/Seoul date +%Y-%m
      ;;
    memory-daily)
      TZ=Asia/Seoul date +%F
      ;;
    *)
      # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
      # lib/cron-helpers/default-slot-now.py — see helper docstring.
      # PR #953 r3: routed through bridge_cron_helper_python for per-call
      # BRIDGE_SCRIPT_DIR guard.
      bridge_cron_helper_python default-slot-now
      ;;
  esac
}

bridge_cron_slot_from_datetime() {
  local value="${1:-}"

  [[ -n "$value" ]] || return 1
  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/slot-from-datetime.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python slot-from-datetime "$value"
}

bridge_cron_slot_for_job() {
  local kind="${1:-}"
  local family="${2:-memory-daily}"
  local next_run_at="${3:-}"

  if [[ "$kind" == "one-shot" && -n "$next_run_at" ]]; then
    bridge_cron_slot_from_datetime "$next_run_at"
    return 0
  fi

  bridge_cron_default_slot "$family"
}

bridge_cron_scheduler_state_file() {
  printf '%s/scheduler-state.json' "$BRIDGE_CRON_STATE_DIR"
}

bridge_cron_safe_component() {
  local value="$1"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/safe-component.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python safe-component "$value"
}

bridge_cron_job_slug() {
  local job_name="$1"
  local job_id="$2"
  printf '%s-%s' "$(bridge_cron_safe_component "$job_name")" "${job_id%%-*}"
}

bridge_cron_slot_token() {
  local slot="$1"
  bridge_cron_safe_component "$slot"
}

bridge_cron_job_dir() {
  local job_name="$1"
  local job_id="$2"
  printf '%s/dispatch/%s' "$BRIDGE_CRON_STATE_DIR" "$(bridge_cron_job_slug "$job_name" "$job_id")"
}

bridge_cron_run_id() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s--%s' "$(bridge_cron_job_slug "$job_name" "$job_id")" "$(bridge_cron_slot_token "$slot")"
}

bridge_cron_run_dir_by_id() {
  local run_id="$1"
  printf '%s/runs/%s' "$BRIDGE_CRON_STATE_DIR" "$run_id"
}

bridge_cron_run_dir() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_run_dir_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_request_file_by_id() {
  local run_id="$1"
  printf '%s/request.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_request_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_request_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_result_file_by_id() {
  local run_id="$1"
  printf '%s/result.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_result_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_result_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_status_file_by_id() {
  local run_id="$1"
  printf '%s/status.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_status_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_status_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_stdout_log_by_id() {
  local run_id="$1"
  printf '%s/stdout.log' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_stdout_log() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_stdout_log_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_stderr_log_by_id() {
  local run_id="$1"
  printf '%s/stderr.log' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_stderr_log() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_stderr_log_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_payload_file_by_id() {
  local run_id="$1"
  printf '%s/payload.md' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_payload_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_payload_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_manifest_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s/%s.json' "$(bridge_cron_job_dir "$job_name" "$job_id")" "$(bridge_cron_slot_token "$slot")"
}

bridge_cron_body_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s/cron-dispatch/%s.md' "$BRIDGE_SHARED_DIR" "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_worker_dir() {
  printf '%s' "$BRIDGE_CRON_DISPATCH_WORKER_DIR"
}

bridge_cron_worker_pid_file() {
  local task_id="$1"
  printf '%s/task-%s.pid' "$(bridge_cron_worker_dir)" "$task_id"
}

bridge_cron_worker_log_file() {
  local task_id="$1"
  printf '%s/task-%s.log' "$(bridge_cron_worker_dir)" "$task_id"
}

bridge_cron_dispatch_completion_note_file_by_id() {
  local run_id="$1"
  printf '%s/cron-result/%s.md' "$BRIDGE_SHARED_DIR" "$run_id"
}

bridge_cron_dispatch_followup_file_by_id() {
  local run_id="$1"
  printf '%s/cron-followup/%s.md' "$BRIDGE_SHARED_DIR" "$run_id"
}

bridge_cron_run_id_from_body_path() {
  local body_path="$1"
  local base

  base="$(basename "$body_path")"
  printf '%s' "${base%.md}"
}

bridge_cron_load_run_shell() {
  local run_id="$1"
  local request_file result_file status_file

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/load-run-shell.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard (the daemon consumes this via
  # `source <(bridge_cron_load_run_shell)`, which would swallow a
  # python3 [Errno 2] silently and leave CRON_* env blank).
  bridge_cron_helper_python load-run-shell \
    "$request_file" "$result_file" "$status_file"
}

bridge_cron_write_completion_note() {
  local run_id="$1"
  local note_file="$2"
  local followup_task_id="${3:-}"

  # Pre-capture nested $() into locals to avoid footgun #11 (Bash 5.3.9 read_comsub/heredoc_write deadlock under I/O pressure).
  local request_file result_file status_file
  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"
  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/write-completion-note.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python write-completion-note \
    "$run_id" "$note_file" "$followup_task_id" \
    "$request_file" "$result_file" "$status_file"
}

bridge_cron_write_followup_body() {
  local run_id="$1"
  local body_file="$2"

  # Pre-capture nested $() into locals to avoid footgun #11 (Bash 5.3.9 read_comsub/heredoc_write deadlock under I/O pressure).
  local request_file result_file status_file
  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"
  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/write-followup-body.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python write-followup-body \
    "$run_id" "$body_file" \
    "$request_file" "$result_file" "$status_file"
}

bridge_cron_fallback_agent() {
  local fallback="${BRIDGE_CRON_FALLBACK_AGENT:-}"

  if [[ -n "$fallback" ]]; then
    bridge_require_cron_delivery_target "$fallback"
    printf '%s' "$fallback"
    return 0
  fi

  if [[ -n "$(bridge_admin_agent_id)" ]]; then
    bridge_require_admin_agent
    return 0
  fi

  return 1
}

bridge_resolve_cron_target() {
  local requested_agent="$1"
  local explicit="${BRIDGE_CRON_AGENT_TARGET[$requested_agent]-${BRIDGE_LEGACY_AGENT_TARGET[$requested_agent]-${BRIDGE_OPENCLAW_AGENT_TARGET[$requested_agent]-}}}"
  local suffix="${requested_agent##*-}"
  local candidate
  local matches=()

  if [[ -n "$explicit" ]]; then
    bridge_require_cron_delivery_target "$explicit"
    printf '%s' "$explicit"
    return 0
  fi

  if bridge_agent_is_cron_delivery_target "$requested_agent"; then
    printf '%s' "$requested_agent"
    return 0
  fi

  for candidate in "${BRIDGE_AGENT_IDS[@]}"; do
    if ! bridge_agent_is_cron_delivery_target "$candidate"; then
      continue
    fi
    if [[ "$candidate" == "$suffix" ]]; then
      matches+=("$candidate")
    fi
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  fi

  return 1
}

bridge_resolve_legacy_cron_target() {
  bridge_resolve_cron_target "$@"
}

bridge_resolve_openclaw_target() {
  bridge_resolve_cron_target "$@"
}

bridge_cron_write_manifest() {
  local manifest_file="$1"
  local job_id="$2"
  local job_name="$3"
  local family="$4"
  local source_agent="$5"
  local target="$6"
  local slot="$7"
  local task_id="$8"
  local created_at="$9"
  local body_file="${10}"
  local source_file="${11}"
  local run_id="${12}"
  local request_file="${13}"
  local payload_file="${14}"
  local result_file="${15}"
  local status_file="${16}"
  local stdout_log="${17}"
  local stderr_log="${18}"
  local job_delivery_mode="${19:-}"
  local job_delivery_channel="${20:-}"
  local job_delivery_target="${21:-}"
  local allow_channel_delivery="${22:-0}"
  local routing_mode="${23:-}"
  local disposable_needs_channels="${24:-0}"
  # PR1.2 / PR1.6 — per-job reporting policy override + urgency hint.
  # Empty string means "use runner default" (silent / normal).
  local cron_reporting_policy="${25:-}"
  local cron_urgency="${26:-}"

  mkdir -p "$(dirname "$manifest_file")"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/write-manifest.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python write-manifest \
    "$manifest_file" "$job_id" "$job_name" "$family" "$source_agent" \
    "$target" "$slot" "$task_id" "$created_at" "$body_file" \
    "$source_file" "$run_id" "$request_file" "$payload_file" \
    "$result_file" "$status_file" "$stdout_log" "$stderr_log" \
    "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" \
    "$allow_channel_delivery" "$routing_mode" "$disposable_needs_channels" \
    "$cron_reporting_policy" "$cron_urgency"
}

bridge_cron_write_request() {
  local request_file="$1"
  local run_id="$2"
  local job_id="$3"
  local job_name="$4"
  local family="$5"
  local source_agent="$6"
  local target="$7"
  local slot="$8"
  local task_id="$9"
  local created_at="${10}"
  local body_file="${11}"
  local payload_file="${12}"
  local result_file="${13}"
  local status_file="${14}"
  local stdout_log="${15}"
  local stderr_log="${16}"
  local source_file="${17}"
  local payload_kind="${18}"
  local target_engine="${19}"
  local target_workdir="${20}"
  local target_channels="${21:-}"
  local target_discord_state_dir="${22:-}"
  local target_telegram_state_dir="${23:-}"
  local job_delivery_mode="${24:-}"
  local job_delivery_channel="${25:-}"
  local job_delivery_target="${26:-}"
  local allow_channel_delivery="${27:-0}"
  local routing_mode="${28:-}"
  local disposable_needs_channels="${29:-0}"
  local disable_mcp="${30:-0}"
  # PR1.2 / PR1.6 — per-job reporting policy + urgency hint surfaced
  # to the runner so policy overrides actually reach build_prompt and
  # the inbox-task creation path.
  local cron_reporting_policy="${31:-}"
  local cron_urgency="${32:-}"
  local shell_script="${33:-}"
  local shell_args_json="${34:-[]}"
  local shell_env_json="${35:-{}}"
  local shell_run_as_agent="${36:-}"
  local shell_os_user="${37:-}"
  local shell_uid="${38:-}"
  local shell_gid="${39:-}"
  local shell_home="${40:-}"
  local shell_agent_env_file="${41:-}"
  local shell_env_snapshot_json="${42:-{}}"
  local shell_timeout_seconds="${43:-}"
  local shell_output_cap_bytes="${44:-}"

  mkdir -p "$(dirname "$request_file")"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/write-request.py — see helper docstring. This was
  # the most argv-dense site in lib/bridge-cron.sh (44 positional
  # arguments) and the surface most directly tied to the 13h cron-worker
  # hang on the operator host.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python write-request \
    "$request_file" "$run_id" "$job_id" "$job_name" "$family" \
    "$source_agent" "$target" "$slot" "$task_id" "$created_at" \
    "$body_file" "$payload_file" "$result_file" "$status_file" \
    "$stdout_log" "$stderr_log" "$source_file" "$payload_kind" \
    "$target_engine" "$target_workdir" "$target_channels" \
    "$target_discord_state_dir" "$target_telegram_state_dir" \
    "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" \
    "$allow_channel_delivery" "$routing_mode" \
    "$disposable_needs_channels" "$disable_mcp" \
    "$cron_reporting_policy" "$cron_urgency" \
    "$shell_script" "$shell_args_json" "$shell_env_json" \
    "$shell_run_as_agent" "$shell_os_user" "$shell_uid" "$shell_gid" \
    "$shell_home" "$shell_agent_env_file" "$shell_env_snapshot_json" \
    "$shell_timeout_seconds" "$shell_output_cap_bytes"
}

bridge_cron_write_status() {
  local status_file="$1"
  local run_id="$2"
  local state="$3"
  local engine="$4"
  local request_file="$5"
  local result_file="$6"
  local updated_at="$7"
  local error_message="${8:-}"

  mkdir -p "$(dirname "$status_file")"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/write-status.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python write-status \
    "$status_file" "$run_id" "$state" "$engine" \
    "$request_file" "$result_file" "$updated_at" "$error_message"
}

bridge_cron_normalize_shell_run_artifacts() {
  local run_dir="$1"
  shift || true
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -b -k "$run_dir" >/dev/null 2>&1 || true
    local artifact
    for artifact in "$@"; do
      [[ -n "$artifact" && -e "$artifact" ]] || continue
      setfacl -b "$artifact" >/dev/null 2>&1 || true
    done
  fi

  chmod 0700 "$run_dir" >/dev/null 2>&1 || true
  local file
  for file in "$@"; do
    [[ -n "$file" && -e "$file" ]] || continue
    chmod 0600 "$file" >/dev/null 2>&1 || true
  done
}

bridge_cron_run_dir_grant_isolation() {
  # v2 isolation contract fix (two problems):
  #
  # 1. Directory access: umask 077 in bridge-lib.sh strips all group bits at
  #    mkdir time, leaving drwx--S--- (2700). The isolated agent UID (in
  #    ab-shared via parent setgid) has zero access. chmod 2770 restores
  #    drwxrws--- so the isolated UID can traverse and write.
  #
  # 2. File readability: files written by the isolated agent inside the dir
  #    also inherit umask 077, landing at 0600 (owner-only). The controller
  #    (ec2-user, in ab-shared) cannot read the sidecar. We set a default ACL
  #    (default:group::rw-) so new files inherit group read/write from the ACL
  #    entry, overriding the umask for the group column. setfacl is
  #    best-effort; hosts without it degrade gracefully (sidecar read may fall
  #    back to child-fallback, but dispatch is not blocked).
  #
  # Shell payloads skip this call and use bridge_cron_normalize_shell_run_artifacts
  # (chmod 0700) instead — controller writes are intentional there.
  local run_dir="$1"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
  chmod 2770 "$run_dir" 2>/dev/null || return 1
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "default:group::rw-,default:mask::rw-" "$run_dir" 2>/dev/null || true
  fi
  return 0
}

bridge_cron_update_request_task_id() {
  # Atomic rewrite of request.json with the real queue task id after the
  # queue task is created (dispatch ordering defers queue create to the end
  # so the worker cannot claim before request/status/manifest/ACL are ready).
  local request_file="$1"
  local task_id="$2"

  [[ -n "$request_file" && -f "$request_file" ]] || return 0
  [[ -n "$task_id" ]] || return 0

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/update-request-task-id.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python update-request-task-id \
    "$request_file" "$task_id"
}

bridge_cron_update_manifest_task_id() {
  # Manifest uses the top-level "task_id" field (not "dispatch_task_id").
  local manifest_file="$1"
  local task_id="$2"

  [[ -n "$manifest_file" && -f "$manifest_file" ]] || return 0
  [[ -n "$task_id" ]] || return 0

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/update-manifest-task-id.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python update-manifest-task-id \
    "$manifest_file" "$task_id"
}

bridge_cron_actions_taken_contains() {
  local result_file="$1"
  local action="$2"

  [[ -n "$result_file" && -f "$result_file" ]] || return 1
  [[ -n "$action" ]] || return 1

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/actions-taken-contains.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python actions-taken-contains \
    "$result_file" "$action"
}

bridge_cron_job_always_followup() {
  local job_id="$1"

  # Footgun #11 (refs queue task #4807): heredoc-stdin extracted to
  # lib/cron-helpers/job-always-followup.py — see helper docstring.
  # PR #953 r3: routed through bridge_cron_helper_python for per-call
  # BRIDGE_SCRIPT_DIR guard.
  bridge_cron_helper_python job-always-followup \
    "$job_id" "$BRIDGE_NATIVE_CRON_JOBS_FILE"
}

# bridge_check_memory_pressure — issue #263 Track B.
#
# Defense-in-depth pre-flight probe for the cron disposable child spawn site.
# A pressured host cold-loads the Claude CLI + MCP stack into swap, which is
# the failure mode behind the observed `event-reminder-30min` 1800s timeouts.
# Returns:
#   0 — host appears healthy; the caller should proceed with dispatch.
#   1 — host is pressured; the caller should defer +15 min instead of spawning.
#
# Probes:
#   Darwin → `sysctl vm.swapusage`. If `used / total >= BRIDGE_CRON_SWAP_PCT_LIMIT`
#            (default 80) percent, return 1.
#   Linux  → `/proc/meminfo` MemAvailable. If below `BRIDGE_CRON_MIN_AVAIL_MB`
#            kilobytes (default 512 MB), return 1.
#   Other  → return 0 (we don't model BSD/Windows; assume healthy).
#
# The probe fails open: if any read fails (sysctl unavailable, /proc not
# mounted, malformed output), we return 0 so a probe glitch never blocks
# scheduled work. The pressure case is a *strict* yes — only triggered when
# we have positive evidence the host is constrained.
bridge_check_memory_pressure() {
  local kind
  kind="$(uname -s 2>/dev/null || true)"

  case "$kind" in
    Darwin)
      local usage_line used_raw total_raw used_int total_int pct
      local limit="${BRIDGE_CRON_SWAP_PCT_LIMIT:-80}"
      [[ "$limit" =~ ^[0-9]+$ ]] || limit=80

      usage_line="$(sysctl -n vm.swapusage 2>/dev/null || true)"
      [[ -n "$usage_line" ]] || return 0

      # Format: total = 4096.00M  used = 3500.00M  free = 596.00M  (encrypted)
      used_raw="$(awk '{ for (i=1; i<=NF; i++) if ($i == "used") print $(i+2) }' <<<"$usage_line")"
      total_raw="$(awk '{ for (i=1; i<=NF; i++) if ($i == "total") print $(i+2) }' <<<"$usage_line")"
      used_raw="${used_raw%M}"
      total_raw="${total_raw%M}"
      [[ -n "$used_raw" && -n "$total_raw" ]] || return 0

      # Strip the decimal portion in pure bash so we don't depend on python
      # for a probe that runs on every dispatch. `2400.00` → `2400`.
      used_int="${used_raw%%.*}"
      total_int="${total_raw%%.*}"
      [[ "$used_int" =~ ^[0-9]+$ && "$total_int" =~ ^[0-9]+$ ]] || return 0
      (( total_int > 0 )) || return 0

      pct=$(( used_int * 100 / total_int ))
      (( pct >= limit )) && return 1
      return 0
      ;;
    Linux)
      local avail_kb threshold_mb threshold_kb
      threshold_mb="${BRIDGE_CRON_MIN_AVAIL_MB:-512}"
      [[ "$threshold_mb" =~ ^[0-9]+$ ]] || threshold_mb=512
      threshold_kb=$(( threshold_mb * 1024 ))

      [[ -r /proc/meminfo ]] || return 0
      avail_kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
      [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 0

      (( avail_kb < threshold_kb )) && return 1
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}
