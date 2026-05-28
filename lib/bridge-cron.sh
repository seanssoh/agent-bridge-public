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

# Issue #1328 (v0.15.0-beta5-2 Lane μ M5): cron-state-dir anchor + migrate.
#
# The cron state dir holds scheduler state, per-job dispatch directories,
# per-run artifacts, locks, and the preflight cache. When the operator (or
# an upgrade path) changes `BRIDGE_CRON_STATE_DIR` — typically by relocating
# `BRIDGE_STATE_DIR`, by removing an `BRIDGE_CRON_STATE_DIR` env override,
# or by editing `bridge-config.json` — the scheduler silently starts writing
# to the new location, leaving the old location stranded with no migration
# step. Symptoms: deduplication state lost, in-flight runs orphaned, cron
# history gone from `agent-bridge status`.
#
# The anchor file records the last cron-state-dir path the helper observed.
# On every cron entry path that opens the state dir, the verify helper
# compares the recorded anchor against the live env and migrates (mv) the
# old tree to the new location ONLY when the old path is non-empty AND the
# new path is empty / absent (the safe single-source case).
#
# Edge-case matrix:
#   1. First run / no anchor present
#       → write the anchor, no migration. fresh-install no-op.
#   2. Anchor matches current env
#       → no-op (the common steady-state case).
#   3. Anchor differs, old exists with content, new missing or empty
#       → mv old → new, rewrite anchor, audit `cron_state_dir_migrated`.
#         This is the upgrade-driven relocation case.
#   4. Anchor differs, old missing
#       → rewrite the anchor silently (operator already migrated, or
#         the old path was never populated).
#   5. Anchor differs, BOTH old and new exist with content (edge case 4)
#       → bail with an operator-visible warning and audit
#         `cron_state_dir_conflict`. DO NOT merge automatically — that
#         risks silently dropping run history.
#   6. Operator explicitly relocated the dir themselves (edge case 3)
#       → covered by case 5 when both still have content (warn). When the
#         operator left only the new dir populated, case 4 silently
#         resyncs the anchor — respect the override.
#
# The helper is idempotent (case 2 / 4 / 6 all short-circuit), single-host
# only (no remote state to reconcile), and best-effort: a failure to write
# the anchor never breaks cron — it just means the next run will re-check.
bridge_cron_state_dir_anchor_file() {
  printf '%s/cron-state-dir-anchor.txt' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

# bridge_cron_state_dir_dir_has_content <dir>
#
# Echoes "yes" / "no" based on whether the directory has any cron-state
# artifacts that would matter to a migration decision. Treats a directory
# with only the anchor file (or no children at all) as empty so a fresh
# `$BRIDGE_CRON_STATE_DIR` that was just `mkdir -p`'d does not trip the
# conflict gate. Internal helper.
bridge_cron_state_dir_dir_has_content() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || { printf 'no\n'; return 0; }
  # `find -mindepth 1 -maxdepth 1 -print -quit` exits as soon as it sees
  # one child, so this stays O(1) on a large state tree.
  local first=""
  first="$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || printf '')"
  if [[ -n "$first" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# bridge_cron_state_dir_verify_and_migrate
#
# Idempotent verifier called from cron entry paths (notably `run_sync`).
# Returns 0 always — caller never gates on the rc. Operator-visible side
# effects:
#   - audit emission via `bridge_audit_log` (best-effort).
#   - `bridge_warn` line for the conflict case.
bridge_cron_state_dir_verify_and_migrate() {
  local anchor_file=""
  local recorded=""
  local current="${BRIDGE_CRON_STATE_DIR:-}"
  [[ -n "$current" ]] || return 0

  anchor_file="$(bridge_cron_state_dir_anchor_file)"
  local anchor_dir=""
  anchor_dir="$(dirname "$anchor_file" 2>/dev/null || printf '')"
  # Ensure the anchor's parent dir exists so the first-run write below
  # never fails on a fresh install. Best-effort — silent on perm error.
  [[ -n "$anchor_dir" && -d "$anchor_dir" ]] || mkdir -p "$anchor_dir" 2>/dev/null || true

  if [[ -f "$anchor_file" ]]; then
    recorded="$(cat "$anchor_file" 2>/dev/null | head -n1)"
    # Strip trailing whitespace (CR / LF / space) defensively — an
    # operator who edits the file in a text editor may add a newline.
    recorded="${recorded%$'\r'}"
  fi

  # Case 1: no anchor yet (fresh install or first run after this change
  # landed). Record current path; no migration.
  if [[ -z "$recorded" ]]; then
    printf '%s\n' "$current" >"$anchor_file" 2>/dev/null || true
    return 0
  fi

  # Case 2: anchor matches → no-op.
  if [[ "$recorded" == "$current" ]]; then
    return 0
  fi

  # Anchor differs. Probe both paths.
  local old_has="no"
  local new_has="no"
  old_has="$(bridge_cron_state_dir_dir_has_content "$recorded")"
  new_has="$(bridge_cron_state_dir_dir_has_content "$current")"

  # Case 5: both have content → bail with conflict warning. Operator
  # must resolve manually before we touch either tree.
  if [[ "$old_has" == "yes" && "$new_has" == "yes" ]]; then
    bridge_warn "cron state dir conflict: anchor=${recorded} (non-empty) AND BRIDGE_CRON_STATE_DIR=${current} (non-empty). Refusing automatic migration. Reconcile manually and update ${anchor_file}, or unset \$BRIDGE_CRON_STATE_DIR to fall back to the canonical path."
    if declare -F bridge_audit_log >/dev/null 2>&1; then
      bridge_audit_log cron cron_state_dir_conflict "${BRIDGE_AGENT_ID:-controller}" \
        --detail recorded="$recorded" \
        --detail current="$current" \
        --detail anchor_file="$anchor_file" 2>/dev/null || true
    fi
    return 0
  fi

  # Case 3: old has content, new is empty/absent → safe to migrate.
  if [[ "$old_has" == "yes" && "$new_has" == "no" ]]; then
    # Ensure the parent of $current exists so `mv` lands cleanly.
    local current_parent=""
    current_parent="$(dirname "$current" 2>/dev/null || printf '')"
    [[ -n "$current_parent" && -d "$current_parent" ]] || mkdir -p "$current_parent" 2>/dev/null || true
    # If the new path already exists as an empty dir, mv would fail
    # because the target is occupied. Remove the empty target first
    # (rmdir refuses if non-empty — safety net against the
    # has_content "no" → empty stub case).
    if [[ -d "$current" ]]; then
      rmdir "$current" 2>/dev/null || true
    fi
    if mv "$recorded" "$current" 2>/dev/null; then
      printf '%s\n' "$current" >"$anchor_file" 2>/dev/null || true
      if declare -F bridge_audit_log >/dev/null 2>&1; then
        bridge_audit_log cron cron_state_dir_migrated "${BRIDGE_AGENT_ID:-controller}" \
          --detail from="$recorded" \
          --detail to="$current" \
          --detail anchor_file="$anchor_file" 2>/dev/null || true
      fi
      bridge_warn "cron state dir migrated: $recorded → $current (anchor refreshed)"
      return 0
    fi
    bridge_warn "cron state dir migrate failed: mv $recorded → $current returned non-zero. Anchor unchanged so the next run re-attempts; reconcile manually if this persists."
    return 0
  fi

  # Case 4 / 6: old missing, or operator already moved → silently
  # refresh the anchor to the current path. No migration needed.
  printf '%s\n' "$current" >"$anchor_file" 2>/dev/null || true
  return 0
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

# bridge_cron_uid_drop_cache_dir
#
# Cache directory for `bridge_cron_uid_drop_preflight` per-agent TTL entries.
# Lives under the cron state root so a smoke `BRIDGE_CRON_STATE_DIR` override
# isolates the cache from the operator's live install.
bridge_cron_uid_drop_cache_dir() {
  printf '%s/preflight-uid-drop' "$BRIDGE_CRON_STATE_DIR"
}

# bridge_cron_uid_drop_cache_file <agent>
#
# Cache key includes the value of BRIDGE_CRON_USE_SETPRIV (0/1) as a suffix
# so a flag toggle naturally invalidates the prior entry — e.g. if the
# operator opts setpriv in (=1) after a refusal under =0, the next preflight
# does NOT serve the stale "refuse" decision from the wrong-policy cache.
# Each policy gets its own cache slot; both decay via the same TTL.
bridge_cron_uid_drop_cache_file() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  local flag_suffix="0"
  if [[ "${BRIDGE_CRON_USE_SETPRIV:-0}" == "1" ]]; then
    flag_suffix="1"
  fi
  printf '%s/%s.setpriv%s.cache' "$(bridge_cron_uid_drop_cache_dir)" "$(bridge_cron_safe_component "$agent")" "$flag_suffix"
}

# bridge_cron_uid_drop_preflight <agent>
#
# Issue #1314 (CRITICAL/security): the runner-internal `RuntimeError("no
# supported UID drop helper found (sudo or setpriv)")` at
# bridge-cron-runner.py:481 is a last-resort seal. Without a pre-flight
# validation at dispatch time, a sudo/setpriv-misconfigured environment can
# allow the dispatch to proceed with the controller UID — a security boundary
# bypass for iso v2 agents.
#
# This helper mirrors the EXACT runner shape used by
# `shell_command_for_execution` (bridge-cron-runner.py:463-481) so a sudoers
# rule that allows `sudo` but rejects the precise `-n -H -u <user> env -i`
# argv shape is caught here, not at exec time. Mirrors Lane F #1290 sudoers-
# template precedent: shape-matching beats existence-matching.
#
# Result band:
#   0 — UID drop validated for this agent. Caller may proceed with dispatch.
#       (Non-iso agents and non-Linux hosts short-circuit to 0 — controller
#        UID is the expected execution UID there, so no drop is required.)
#   1 — Pre-flight refuses. Iso v2 effective AND no working UID-drop helper
#       (sudo invocation in the exact runner shape fails AND setpriv missing).
#       Caller MUST refuse to dispatch and emit
#       `cron_dispatch_refused reason=iso_uid_drop_unavailable`.
#
# TTL cache (default 300s, override BRIDGE_CRON_UID_DROP_PREFLIGHT_TTL_SECONDS):
# per-agent file storing `<expires_at_epoch>\t<result>`. The shell-cron
# dispatch path runs at every cron tick (potentially every minute on a busy
# host), so a per-dispatch `sudo -n` probe would add measurable latency. The
# TTL cache amortizes the probe cost while staying short enough that a
# sudoers/setpriv repair is reflected within 5 minutes.
#
# Cache invalidation: a 0-byte / malformed / expired entry is treated as
# absent — the helper re-probes and rewrites. The cache is NEVER consulted
# for `force=1` (the smoke entry point uses this). The cache file name also
# includes the `BRIDGE_CRON_USE_SETPRIV` flag value (0/1) as a suffix so a
# flag toggle naturally invalidates the prior decision — opting setpriv in
# after a refusal under =0 starts at a fresh cache slot.
#
# setpriv opt-in (BRIDGE_CRON_USE_SETPRIV, default 0): when sudo fails AND
# setpriv exists, pre-flight refuses unless the operator has explicitly
# asserted `BRIDGE_CRON_USE_SETPRIV=1`. The runner (bridge-cron-runner.py
# :492-498) gates its own setpriv branch on the same env var, so both
# layers agree on policy. Auto-selecting setpriv would mask a sudoers
# misconfig with an exec-time EPERM; opt-in keeps the security boundary
# explicit. When BOTH sudo+setpriv are available and the flag is 1, sudo
# wins (canonical iso v2 path).
#
# Edge cases (mirrors brief):
#   - Non-iso agent (BRIDGE_AGENT_OS_USER empty / Linux-isolation-not-
#     effective) → return 0 immediately; cron runs as controller UID.
#   - macOS / non-Linux host → return 0 immediately (Linux-only iso v2).
#   - Sudoers shape mismatch (sudo works for `id` but not `-n -H -u <user>
#     env -i true`) → fail the probe AND consult the setpriv fallback
#     (which requires BRIDGE_CRON_USE_SETPRIV=1 to be eligible).
#   - setpriv missing OR BRIDGE_CRON_USE_SETPRIV unset/0 → if sudo also
#     fails, refuse.
#   - Both sudo + setpriv work AND flag=1 → sudo wins (matches runner's
#     ordering at lines 492-498).
#   - Mixed env (one agent OK, another fails) → per-agent cache file, not
#     global. The cache is keyed by `bridge_cron_safe_component(agent)`
#     PLUS the flag suffix.
#
# Audit emission is the caller's responsibility (see dispatch site).
bridge_cron_uid_drop_preflight() {
  local agent="$1"
  local force="${2:-0}"
  local cache_file=""
  local now_ts=0
  local cache_entry=""
  local cache_expires=""
  local cache_result=""
  local ttl="${BRIDGE_CRON_UID_DROP_PREFLIGHT_TTL_SECONDS:-300}"
  local os_user=""
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"

  [[ -n "$agent" ]] || return 0
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300

  # Non-Linux host or roster lookup unavailable → short-circuit to OK
  # (controller-UID execution is the expected/required path there).
  if ! declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
    return 0
  fi
  if ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 0
  fi

  # Iso v2 effective but no os_user in roster → cannot prove drop is feasible.
  # Refuse to dispatch; the request would land at the runner's RuntimeError
  # anyway, but pre-flight gives the operator an actionable audit row instead
  # of a runner-exit traceback.
  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  if [[ -z "$os_user" ]]; then
    return 1
  fi

  # Same-UID short-circuit: mirror bridge-cron-runner.py:473-474. If the
  # controller (daemon) is ALREADY running as the agent's iso UID, the runner
  # builds `env -i ... script` with no sudo/setpriv wrap. No drop is needed,
  # so pre-flight passes. This is the per-agent isolated-daemon shape (rare
  # but supported).
  local current_uid="" target_uid=""
  current_uid="$(id -u 2>/dev/null || printf '')"
  target_uid="$(id -u "$os_user" 2>/dev/null || printf '')"
  if [[ -n "$current_uid" && -n "$target_uid" && "$current_uid" == "$target_uid" ]]; then
    return 0
  fi

  now_ts="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now_ts" =~ ^[0-9]+$ ]] || now_ts=0

  # TTL cache lookup (skip on force=1).
  if [[ "$force" != "1" ]]; then
    cache_file="$(bridge_cron_uid_drop_cache_file "$agent" 2>/dev/null || printf '')"
    if [[ -n "$cache_file" && -f "$cache_file" ]]; then
      cache_entry="$(<"$cache_file")" 2>/dev/null || cache_entry=""
      cache_expires="${cache_entry%%	*}"
      cache_result="${cache_entry##*	}"
      if [[ "$cache_expires" =~ ^[0-9]+$ \
          && "$cache_result" =~ ^[01]$ \
          && "$now_ts" -lt "$cache_expires" ]]; then
        return "$cache_result"
      fi
    fi
  fi

  # Live probe — mirror the EXACT runner argv shape. The runner builds:
  #   sudo -n -H -u <os_user> env -i KEY=val script args...
  # We probe with:
  #   sudo -n -H -u <os_user> env -i HOME=/tmp <bash_bin> -c 'exit 0'
  # so a sudoers rule that whitelists e.g. `bash` for the os_user but rejects
  # `-H` or `env -i` (Defaults env_reset / requiretty mismatch) trips the
  # probe here, not at runner-exec time. Stderr suppressed unless the
  # debug env is set; the result band is what the caller acts on.
  local probe_rc=2
  if command -v sudo >/dev/null 2>&1; then
    if [[ "${BRIDGE_CRON_UID_DROP_PREFLIGHT_DEBUG:-0}" == "1" ]]; then
      sudo -n -H -u "$os_user" env -i HOME=/tmp "$bash_bin" -c 'exit 0' && probe_rc=0 || probe_rc=$?
    elif sudo -n -H -u "$os_user" env -i HOME=/tmp "$bash_bin" -c 'exit 0' >/dev/null 2>&1; then
      probe_rc=0
    else
      probe_rc=$?
    fi
  fi

  local result=1
  if [[ "$probe_rc" -eq 0 ]]; then
    # Sudo arm OK — preferred (canonical iso v2 path). This branch wins even
    # when setpriv is also present and BRIDGE_CRON_USE_SETPRIV=1: the runner
    # at bridge-cron-runner.py:492-498 also prefers `sudo` over `setpriv`
    # when both are present, so pre-flight matches that ordering exactly.
    result=0
  elif [[ "${BRIDGE_CRON_USE_SETPRIV:-0}" == "1" ]] && command -v setpriv >/dev/null 2>&1; then
    # The runner's setpriv fallback (line 495-497) does not actually require
    # privilege to test — `setpriv --reuid <controller_uid> --regid <gid>` to
    # the current UID/GID is a no-op if available. But we cannot probe a
    # cross-UID setpriv from the controller without root; the runner's
    # setpriv branch is unreachable unless the cron worker itself is already
    # running as root or with CAP_SETUID/CAP_SETGID. On a standard
    # controller-UID daemon, this branch is essentially dead — but the runner
    # keeps it for parity with hosts that run the daemon as root. We
    # therefore treat `setpriv present + BRIDGE_CRON_USE_SETPRIV=1` as
    # "operator-asserted best-effort fallback may work" and pass pre-flight.
    # Without the opt-in flag, setpriv is ignored: the runner ALSO gates its
    # setpriv arm on the same flag (kept in lockstep), so a refusal here
    # mirrors a runtime refusal at the runner.
    result=0
  fi

  # Persist cache entry (best-effort).
  cache_file="$(bridge_cron_uid_drop_cache_file "$agent" 2>/dev/null || printf '')"
  if [[ -n "$cache_file" ]]; then
    local cache_dir
    cache_dir="$(dirname "$cache_file")"
    if mkdir -p "$cache_dir" 2>/dev/null; then
      local expires=$(( now_ts + ttl ))
      printf '%s\t%s\n' "$expires" "$result" >"$cache_file" 2>/dev/null || true
      chmod 0600 "$cache_file" 2>/dev/null || true
    fi
  fi

  return "$result"
}

bridge_cron_run_dir_grant_isolation() {
  # v2 isolation contract fix (two problems), scoped to isolated targets only:
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
  # **Scope gate (codex r1):** apply ONLY when the target agent has effective
  # linux-user isolation. Without the gate this helper would broaden every
  # non-shell cron run dir on shared/macOS hosts from a private umask-077 dir
  # to a group-writable dir — over-permissioning. Non-isolated targets keep
  # the existing umask-077 mode.
  #
  # Shell payloads skip this call and use bridge_cron_normalize_shell_run_artifacts
  # (chmod 0700) instead — controller writes are intentional there.
  local run_dir="$1"
  local target_agent="$2"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
  # No target → cannot prove isolation is in effect; no-op safely.
  [[ -n "$target_agent" ]] || return 0
  if ! declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
    return 0
  fi
  if ! bridge_agent_linux_user_isolation_effective "$target_agent" 2>/dev/null; then
    return 0
  fi
  # Bind the leaf to the target's per-agent group (e.g. ab-agent-<X>) before
  # chmod 2770. Without this chgrp the leaf inherits the controller primary
  # group (umask 077 + non-setgid parent), which the isolated UID is not in;
  # group=2770 would then be useless. The chgrp confines access to
  # controller + the target's isolated UID — and only them. ab-shared on the
  # parents lets isolated UIDs TRAVERSE but not read other agents' run dirs.
  if declare -F bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
    local agent_grp
    agent_grp="$(bridge_isolation_v2_agent_group_name "$target_agent" 2>/dev/null)" || agent_grp=""
    if [[ -n "$agent_grp" ]]; then
      chgrp "$agent_grp" "$run_dir" 2>/dev/null || return 1
    fi
  fi
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
