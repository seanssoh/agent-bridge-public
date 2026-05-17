#!/usr/bin/env bash
# shellcheck shell=bash

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
      bridge_require_python
      python3 - <<'PY'
from datetime import datetime, timezone

print(datetime.now(timezone.utc).astimezone().replace(second=0, microsecond=0).isoformat(timespec="minutes"))
PY
      ;;
  esac
}

bridge_cron_slot_from_datetime() {
  local value="${1:-}"

  [[ -n "$value" ]] || return 1
  bridge_require_python
  python3 - "$value" <<'PY'
from datetime import datetime
import sys

text = sys.argv[1]
if text.endswith("Z"):
    text = text[:-1] + "+00:00"
dt = datetime.fromisoformat(text)
print(dt.replace(second=0, microsecond=0).isoformat(timespec="minutes"))
PY
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

  bridge_require_python
  python3 - "$value" <<'PY'
import re
import sys

text = sys.argv[1]
slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")
print(slug or "item")
PY
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

  bridge_require_python
  python3 - "$request_file" "$result_file" "$status_file" <<'PY'
import json
import shlex
import sys
from pathlib import Path

request_file = Path(sys.argv[1])
result_file = Path(sys.argv[2])
status_file = Path(sys.argv[3])


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_file)
result = load(result_file)
status = load(status_file)

fields = {
    "CRON_RUN_ID": request.get("run_id", request_file.parent.name),
    "CRON_JOB_ID": request.get("job_id", ""),
    "CRON_JOB_NAME": request.get("job_name", ""),
    "CRON_FAMILY": request.get("family", ""),
    "CRON_SLOT": request.get("slot", ""),
    "CRON_TARGET_AGENT": request.get("target_agent", ""),
    "CRON_TARGET_ENGINE": request.get("target_engine", ""),
    "CRON_RESULT_STATUS": result.get("status", ""),
    "CRON_RESULT_SUMMARY": result.get("summary", ""),
    "CRON_RUN_STATE": status.get("state", ""),
    # Issue #393: surface deferred_reason so the daemon can suppress
    # cron-followup tasks for memory_pressure deferrals. Empty string
    # for non-deferred runs (legacy callers see the same value).
    "CRON_DEFERRED_REASON": str(status.get("deferred_reason") or "").strip(),
    "CRON_RESULT_FILE": str(result_file),
    "CRON_STATUS_FILE": str(status_file),
    "CRON_STDOUT_LOG": request.get("stdout_log", ""),
    "CRON_STDERR_LOG": request.get("stderr_log", ""),
    "CRON_PROMPT_FILE": str(request_file.parent / "prompt.txt"),
    "CRON_NEEDS_HUMAN_FOLLOWUP": "1" if result.get("needs_human_followup") else "0",
    # Issue #345 Track B (instance #4): cron failures split into
    # admin-resolvable (close/refresh/retry) and human-config (config drift,
    # binding mismatch, retired-agent cleanup). Subagents may set
    # `failure_class` in result.json; jobs may carry a static
    # `failure_class` in request.json. Default `admin-resolvable` keeps
    # the legacy admin-queue path for unclassified failures.
    "CRON_FAILURE_CLASS": str(
        result.get("failure_class")
        or request.get("failure_class")
        or "admin-resolvable"
    ).strip().lower() or "admin-resolvable",
    # PR1.8 — surface the cron-runner reporting decision so the daemon can
    # gate its own followup-task path. Empty string when the cron-runner
    # didn't populate the field (legacy / pre-PR1 result.json).
    "CRON_REPORTING_DECISION": str(result.get("reporting_decision") or status.get("reporting_decision") or "").strip(),
    "CRON_DELIVERY_INTENT": str(result.get("delivery_intent") or status.get("delivery_intent") or "").strip(),
    "CRON_INBOX_TASK_ID": str(result.get("inbox_task_id") if result.get("inbox_task_id") is not None else (status.get("inbox_task_id") if status.get("inbox_task_id") is not None else "")),
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
}

bridge_cron_write_completion_note() {
  local run_id="$1"
  local note_file="$2"
  local followup_task_id="${3:-}"

  bridge_require_python
  # Pre-capture nested $() into locals to avoid footgun #11 (Bash 5.3.9 read_comsub/heredoc_write deadlock under I/O pressure).
  local request_file result_file status_file
  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"
  python3 - "$run_id" "$note_file" "$followup_task_id" "$request_file" "$result_file" "$status_file" <<'PY'
import json
import sys
from pathlib import Path

run_id, note_file, followup_task_id, request_file, result_file, status_file = sys.argv[1:]
request_path = Path(request_file)
result_path = Path(result_file)
status_path = Path(status_file)
note_path = Path(note_file)


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_path)
result = load(result_path)
status = load(status_path)

job_name = request.get("job_name", "")
slot = request.get("slot", "")
state = status.get("state", result.get("status", "unknown"))

lines = [
    "# Cron Dispatch Result",
    "",
    f"- run_id: {run_id}",
    f"- job: {job_name}",
    f"- family: {request.get('family', '')}",
    f"- slot: {slot}",
    f"- target_agent: {request.get('target_agent', '')}",
    f"- engine: {request.get('target_engine', '')}",
    f"- state: {state}",
    f"- child_status: {result.get('status', '')}",
    f"- request_file: {request_file}",
    f"- result_file: {result_file}",
    f"- status_file: {status_file}",
]

stdout_log = request.get("stdout_log")
stderr_log = request.get("stderr_log")
if stdout_log:
    lines.append(f"- stdout_log: {stdout_log}")
if stderr_log:
    lines.append(f"- stderr_log: {stderr_log}")
if followup_task_id:
    lines.append(f"- followup_task_id: {followup_task_id}")

summary = str(result.get("summary", "")).strip()
if summary:
    lines.extend(["", "## Summary", "", summary])

recommended = result.get("recommended_next_steps") or []
if recommended:
    lines.extend(["", "## Recommended Next Steps", ""])
    for item in recommended:
        lines.append(f"- {item}")

runner_error = str(result.get("runner_error", "")).strip()
if runner_error:
    lines.extend(["", "## Runner Error", "", runner_error])

note_path.parent.mkdir(parents=True, exist_ok=True)
note_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

bridge_cron_write_followup_body() {
  local run_id="$1"
  local body_file="$2"

  bridge_require_python
  # Pre-capture nested $() into locals to avoid footgun #11 (Bash 5.3.9 read_comsub/heredoc_write deadlock under I/O pressure).
  local request_file result_file status_file
  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"
  python3 - "$run_id" "$body_file" "$request_file" "$result_file" "$status_file" <<'PY'
import json
import sys
from pathlib import Path

run_id, body_file, request_file, result_file, status_file = sys.argv[1:]
request_path = Path(request_file)
result_path = Path(result_file)
status_path = Path(status_file)
body_path = Path(body_file)


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_path)
result = load(result_path)
status = load(status_path)

job_name = request.get("job_name", run_id)
title = f"# [cron-followup] {job_name}"
lines = [
    title,
    "",
    f"- run_id: {run_id}",
    f"- slot: {request.get('slot', '')}",
    f"- family: {request.get('family', '')}",
    f"- target_agent: {request.get('target_agent', '')}",
    f"- engine: {request.get('target_engine', '')}",
    f"- run_state: {status.get('state', '')}",
    f"- child_status: {result.get('status', '')}",
    f"- request_file: {request_file}",
    f"- result_file: {result_file}",
    f"- status_file: {status_file}",
]

stdout_log = request.get("stdout_log")
stderr_log = request.get("stderr_log")
if stdout_log:
    lines.append(f"- stdout_log: {stdout_log}")
if stderr_log:
    lines.append(f"- stderr_log: {stderr_log}")

summary = str(result.get("summary", "")).strip()
if summary:
    lines.extend(["", "## Summary", "", summary])

channel_relay = result.get("channel_relay") if isinstance(result.get("channel_relay"), dict) else None
if channel_relay:
    lines.extend(["", "## Channel Relay", ""])
    for key in ("transport", "target", "urgency", "subject"):
        value = str(channel_relay.get(key, "")).strip()
        if value:
            lines.append(f"- {key}: {value}")
    lines.extend(["", "### Relay Body", "", str(channel_relay.get("body", "")).rstrip(), ""])

for section, key in (
    ("Findings", "findings"),
    ("Actions Taken", "actions_taken"),
    ("Recommended Next Steps", "recommended_next_steps"),
    ("Artifacts", "artifacts"),
):
    values = result.get(key) or []
    if not values:
      continue
    lines.extend(["", f"## {section}", ""])
    for item in values:
        lines.append(f"- {item}")

runner_error = str(result.get("runner_error", "")).strip()
if runner_error:
    lines.extend(["", "## Runner Error", "", runner_error])

if channel_relay:
    lines.extend([
        "## Action Required",
        "",
        "You are the parent agent receiving this cron result. You MUST:",
        "1. Review the summary, findings, and typed Channel Relay payload above",
        "2. Send the relay body from your own parent session using your human-facing channel tool",
        "3. Treat transport/target as routing hints unless request metadata or parent policy overrides them",
        "4. Mark this task done with delivery evidence or the concrete blocker",
        "",
        "Do NOT delegate the final send back to a disposable child. The parent session must own the outbound message.",
    ])
else:
    lines.extend([
        "",
        "## Action Required",
        "",
        "You are the parent agent receiving this cron result. You MUST:",
        "1. Review the summary and findings above",
        "2. Post a concise report to your Discord or Telegram channel",
        "3. If recommended_next_steps includes DM or notification targets, execute them",
        "4. Mark this task done with a note summarizing what you reported",
        "",
        "Do NOT just acknowledge this task silently. Your channel subscribers expect reports.",
    ])

body_path.parent.mkdir(parents=True, exist_ok=True)
body_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
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

  bridge_require_python
  python3 - "$manifest_file" "$job_id" "$job_name" "$family" "$source_agent" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$source_file" "$run_id" "$request_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$routing_mode" "$disposable_needs_channels" "$cron_reporting_policy" "$cron_urgency" <<'PY'
import json
import sys
from pathlib import Path

(manifest_file, job_id, job_name, family, source_agent, target, slot, task_id, created_at, body_file, source_file, run_id, request_file, payload_file, result_file, status_file, stdout_log, stderr_log, job_delivery_mode, job_delivery_channel, job_delivery_target, allow_channel_delivery, routing_mode, disposable_needs_channels, cron_reporting_policy, cron_urgency) = sys.argv[1:]

payload = {
    "job_id": job_id,
    "job_name": job_name,
    "family": family,
    "source_agent": source_agent,
    "target_agent": target,
    "routing_mode": routing_mode,
    "job_delivery_mode": job_delivery_mode,
    "job_delivery_channel": job_delivery_channel,
    "job_delivery_target": job_delivery_target,
    # PR1.4 — `allow_channel_delivery` is the legacy key name. Wire the
    # new `allow_structured_relay` alongside it so the cron-runner can
    # read the new name preferentially while existing operator surfaces
    # (manifest readers, audit consumers) keep seeing the old key.
    "allow_channel_delivery": allow_channel_delivery == "1",
    "allow_structured_relay": allow_channel_delivery == "1",
    "disposable_needs_channels": disposable_needs_channels == "1",
    "cron_reporting_policy": cron_reporting_policy,
    "cron_urgency": cron_urgency,
    "slot": slot,
    "task_id": int(task_id),
    "created_at": created_at,
    "run_id": run_id,
    "body_file": body_file,
    "request_file": request_file,
    "payload_file": payload_file,
    "result_file": result_file,
    "status_file": status_file,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_file": source_file,
}

Path(manifest_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
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

  bridge_require_python
  python3 - "$request_file" "$run_id" "$job_id" "$job_name" "$family" "$source_agent" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$source_file" "$payload_kind" "$target_engine" "$target_workdir" "$target_channels" "$target_discord_state_dir" "$target_telegram_state_dir" "$job_delivery_mode" "$job_delivery_channel" "$job_delivery_target" "$allow_channel_delivery" "$routing_mode" "$disposable_needs_channels" "$disable_mcp" "$cron_reporting_policy" "$cron_urgency" "$shell_script" "$shell_args_json" "$shell_env_json" "$shell_run_as_agent" "$shell_os_user" "$shell_uid" "$shell_gid" "$shell_home" "$shell_agent_env_file" "$shell_env_snapshot_json" "$shell_timeout_seconds" "$shell_output_cap_bytes" <<'PY'
import json
import sys
from pathlib import Path

(request_file, run_id, job_id, job_name, family, source_agent, target, slot, task_id, created_at, body_file, payload_file, result_file, status_file, stdout_log, stderr_log, source_file, payload_kind, target_engine, target_workdir, target_channels, target_discord_state_dir, target_telegram_state_dir, job_delivery_mode, job_delivery_channel, job_delivery_target, allow_channel_delivery, routing_mode, disposable_needs_channels, disable_mcp, cron_reporting_policy, cron_urgency, shell_script, shell_args_json, shell_env_json, shell_run_as_agent, shell_os_user, shell_uid, shell_gid, shell_home, shell_agent_env_file, shell_env_snapshot_json, shell_timeout_seconds, shell_output_cap_bytes) = sys.argv[1:]

def decode_json(value, fallback):
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        return fallback
    return decoded

payload = {
    "run_id": run_id,
    "job_id": job_id,
    "job_name": job_name,
    "family": family,
    "source_agent": source_agent,
    "target_agent": target,
    "target_engine": target_engine,
    "target_workdir": target_workdir,
    "target_channels": target_channels,
    "target_discord_state_dir": target_discord_state_dir,
    "target_telegram_state_dir": target_telegram_state_dir,
    "routing_mode": routing_mode,
    "job_delivery_mode": job_delivery_mode,
    "job_delivery_channel": job_delivery_channel,
    "job_delivery_target": job_delivery_target,
    # PR1.4 — wire both keys; cron-runner reads `allow_structured_relay`
    # first and falls back to the legacy name.
    "allow_channel_delivery": allow_channel_delivery == "1",
    "allow_structured_relay": allow_channel_delivery == "1",
    "disposable_needs_channels": disposable_needs_channels == "1",
    "disable_mcp": disable_mcp == "1",
    "cron_reporting_policy": cron_reporting_policy,
    "cron_urgency": cron_urgency,
    "slot": slot,
    "dispatch_task_id": int(task_id),
    "created_at": created_at,
    "dispatch_body_file": body_file,
    "payload_file": payload_file,
    "payload_kind": payload_kind,
    "result_file": result_file,
    "status_file": status_file,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_file": source_file,
}
if payload_kind == "shell":
    shell_payload = {
        "kind": "shell",
        "script": shell_script,
        "args": decode_json(shell_args_json, []),
        "env": decode_json(shell_env_json, {}),
        "timeoutSeconds": int(shell_timeout_seconds or 900),
        "outputCapBytes": int(shell_output_cap_bytes or 65536),
    }
    payload["payload"] = shell_payload
    payload["execution"] = {
        "run_as_agent": shell_run_as_agent,
        "os_user": shell_os_user,
        "uid": int(shell_uid),
        "gid": int(shell_gid),
        "home": shell_home,
        "agent_env_file": shell_agent_env_file,
        "env_snapshot": decode_json(shell_env_snapshot_json, {}),
    }

Path(request_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
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

  bridge_require_python
  python3 - "$status_file" "$run_id" "$state" "$engine" "$request_file" "$result_file" "$updated_at" "$error_message" <<'PY'
import json
import sys
from pathlib import Path

(status_file, run_id, state, engine, request_file, result_file, updated_at, error_message) = sys.argv[1:]

payload = {
    "run_id": run_id,
    "state": state,
    "engine": engine,
    "updated_at": updated_at,
    "request_file": request_file,
    "result_file": result_file,
}
if error_message:
    payload["error"] = error_message

Path(status_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
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
  # v2 hard-cut: the per-agent group + setgid contract on the per-agent
  # root covers cron per-run dirs reachable by the isolated UID. No
  # per-run-dir named-user ACL grant is applied. Retained as a no-op
  # stub so callers (`dispatch_cron_run`) link cleanly.
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

  bridge_require_python
  python3 - "$request_file" "$task_id" <<'PY'
import json
import os
import sys

path = sys.argv[1]
task_id = int(sys.argv[2])

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["dispatch_task_id"] = task_id

tmp = path + ".tmp." + str(os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=True, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

bridge_cron_update_manifest_task_id() {
  # Manifest uses the top-level "task_id" field (not "dispatch_task_id").
  local manifest_file="$1"
  local task_id="$2"

  [[ -n "$manifest_file" && -f "$manifest_file" ]] || return 0
  [[ -n "$task_id" ]] || return 0

  bridge_require_python
  python3 - "$manifest_file" "$task_id" <<'PY'
import json
import os
import sys

path = sys.argv[1]
task_id = int(sys.argv[2])

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["task_id"] = task_id

tmp = path + ".tmp." + str(os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=True, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

bridge_cron_actions_taken_contains() {
  local result_file="$1"
  local action="$2"

  [[ -n "$result_file" && -f "$result_file" ]] || return 1
  [[ -n "$action" ]] || return 1

  bridge_require_python
  python3 - "$result_file" "$action" <<'PY'
import json
import sys

result_file = sys.argv[1]
action = sys.argv[2]

try:
    with open(result_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

actions = data.get("actions_taken") or []
if not isinstance(actions, list):
    sys.exit(1)

sys.exit(0 if action in actions else 1)
PY
}

bridge_cron_job_always_followup() {
  local job_id="$1"

  bridge_require_python
  python3 - "$job_id" "$BRIDGE_NATIVE_CRON_JOBS_FILE" <<'PY'
import json
import sys
from pathlib import Path

job_id = sys.argv[1]
jobs_file = Path(sys.argv[2]).expanduser()

if not jobs_file.exists():
    print("0")
    raise SystemExit(0)

try:
    data = json.loads(jobs_file.read_text(encoding="utf-8"))
except Exception:
    print("0")
    raise SystemExit(0)

for job in data.get("jobs", []):
    if job.get("id") == job_id:
        metadata = job.get("metadata") or {}
        if metadata.get("alwaysFollowup") or metadata.get("always_followup"):
            print("1")
        else:
            print("0")
        raise SystemExit(0)

print("0")
PY
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
