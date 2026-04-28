#!/usr/bin/env bash
# bridge-run.sh — roster 기반 에이전트 실행기

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

# PR-E: in v2 mode + linux-user isolation, switch the runtime umask from
# bridge-lib.sh's default 0077 (private) to 0007 (group-writable). The v2
# group-setgid layout (PR-A/B/C) gives new files the right group, but the
# mode bits depend on umask. Without 0007, a setgid 2770 channel/runtime
# dir would still hold 0600 files that the controller (group member) can
# only read because of the inherited group ownership combined with chmod
# at directory creation; agent-created channel state .env files would
# lack group rw and the daemon's controller-side health probes would
# silently see EACCES.
#
# Called twice from this script: once after the first bridge_require_agent
# at startup, and once from bridge_run_refresh_roster_if_changed after the
# subsequent bridge_require_agent on roster reload. Defined here (above
# any caller) so the first call site below is not running against an
# undefined function (PR #399 r1 FAIL #14): bash with `set -uo pipefail`
# silently emits "command not found" + rc=127 and the script keeps going,
# leaving initial v2 launches inheriting bridge-lib.sh's 0077.
#
# BRIDGE_RUN_UMASK_PROBE_FILE is a hidden smoke-only hook: when set, the
# helper writes the resulting umask (post-set) to that path so a smoke
# fixture can assert the bridge-run.sh effective umask without parsing
# /proc/<pid>/status. Inert when unset.
bridge_run_apply_v2_umask_if_needed() {
  local agent="$1"
  if bridge_isolation_v2_active 2>/dev/null \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    umask 007
  fi
  if [[ -n "${BRIDGE_RUN_UMASK_PROBE_FILE:-}" ]]; then
    umask >"$BRIDGE_RUN_UMASK_PROBE_FILE" 2>/dev/null || true
  fi
}

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-run.sh <agent> [--once] [--continue|--no-continue] [--safe-mode] [--dry-run]"
  echo "       bash $SCRIPT_DIR/bridge-run.sh --list"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
ONCE=0
DRY_RUN=0
CONTINUE_EXPLICIT=0
CONTINUE_MODE=1
SAFE_MODE=0
AGENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --safe-mode)
      SAFE_MODE=1
      shift
      ;;
    --continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=1
      shift
      ;;
    --no-continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=0
      shift
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$AGENT" ]]; then
        AGENT="$1"
      else
        bridge_die "에이전트는 하나만 지정할 수 있습니다."
      fi
      shift
      ;;
  esac
done

# Export BRIDGE_AGENT_ID before roster load so bridge_load_roster can pick up
# the per-agent scoped snapshot when this script runs under an isolated UID
# that cannot read the 0600 agent-roster.local.sh. See issue #116.
if [[ -n "$AGENT" ]]; then
  export BRIDGE_AGENT_ID="$AGENT"
fi
bridge_load_roster

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$AGENT" ]]; then
  usage
  exit 1
fi

bridge_require_agent "$AGENT"

# PR-E: apply v2 umask before any runtime mkdir/plugin sync/launch work.
# bridge-lib.sh:17 unconditionally set 0077; this helper only changes it
# when BRIDGE_LAYOUT=v2 and the agent is linux-user-isolated.
bridge_run_apply_v2_umask_if_needed "$AGENT"

if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
fi

# Issue #268: same warning as bridge-start.sh, repeated here because operators
# can invoke bridge-run.sh directly (and tmux session_cmd injects --no-continue
# without going through bridge-start.sh on FORCE_FRESH_SESSION paths). Goes to
# stderr so dry-run callers parsing stdout for `session_id=...` keep working.
if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "0" ]]; then
  _persisted_session_id="$(bridge_agent_persisted_session_id "$AGENT")"
  if [[ -n "$_persisted_session_id" ]]; then
    bridge_warn "launched fresh for this run, but saved session_id=${_persisted_session_id} remains; next normal restart will resume it. Use 'agb agent forget-session $AGENT' to clear permanently."
  fi
  unset _persisted_session_id
fi

if [[ $SAFE_MODE -eq 1 ]]; then
  ONCE=1
fi

WORK_DIR="$(bridge_agent_workdir "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
SESSION="$(bridge_agent_session "$AGENT")"
if [[ $SAFE_MODE -eq 1 ]]; then
  LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
else
  LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
fi

if [[ -z "$WORK_DIR" || -z "$LAUNCH_CMD" ]]; then
  bridge_die "'$AGENT'의 workdir 또는 launch command가 비어 있습니다."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "agent=$AGENT"
  echo "engine=$ENGINE"
  echo "workdir=$WORK_DIR"
  echo "loop=$(bridge_agent_loop "$AGENT")"
  echo "continue=$(bridge_agent_continue "$AGENT")"
  echo "session_id=$(bridge_agent_session_id "$AGENT")"
  echo "safe_mode=$SAFE_MODE"
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  echo "launch=$(bridge_redact_inline_env_secrets "$LAUNCH_CMD")"
  exit 0
fi

export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:$PATH"
export BRIDGE_AGENT_ID="$AGENT"
export BRIDGE_ADMIN_AGENT_ID="$(bridge_admin_agent_id)"
export BRIDGE_AGENT_WORKDIR="$WORK_DIR"
export BRIDGE_AGENT_ISOLATION_MODE="$(bridge_agent_isolation_mode "$AGENT")"
export BRIDGE_AGENT_OS_USER="$(bridge_agent_os_user "$AGENT")"
export BRIDGE_AGENT_INJECT_TIMESTAMP="$(bridge_agent_inject_timestamp "$AGENT")"
export BRIDGE_AGENT_PROMPT_GUARD_POLICY="$(bridge_guard_policy_raw "$AGENT")"
export BRIDGE_PROMPT_GUARD_CANARY_TOKENS="$(bridge_agent_prompt_guard_canary "$AGENT")"

mkdir -p "$(bridge_agent_log_dir "$AGENT")" "$BRIDGE_SHARED_DIR"
cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."

LOGFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').log"
ERRFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').err.log"
BRIDGE_RUN_ROSTER_SIGNATURE=""

log_line() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$LOGFILE"
}

log_loop_help() {
  bridge_run_session_attached || return 0
  log_line "tmux에서 쉘로 돌아가기: Ctrl-b 를 누른 뒤 d 를 누르세요."
  log_line "에이전트를 완전히 종료하기: 바깥 터미널에서 'agb kill ${AGENT}' 를 실행하세요."
}

bridge_run_session_attached() {
  local attached

  [[ -n "$SESSION" ]] || return 1
  attached="$(bridge_tmux_session_attached_count "$SESSION" 2>/dev/null || printf '0')"
  [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
  (( attached > 0 ))
}

bridge_run_detach_attached_clients() {
  [[ -n "$SESSION" ]] || return 0
  bridge_tmux_detach_clients "$SESSION" >/dev/null 2>&1 || true
}

bridge_run_stop_foreground_session() {
  if [[ "$(bridge_agent_source "$AGENT")" == "static" ]]; then
    bridge_agent_mark_manual_stop "$AGENT"
  fi
  bridge_agent_clear_idle_marker "$AGENT"
}

bridge_run_cleanup_mcp_orphans() {
  local min_age="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"

  [[ "${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=0

  # Give orphaned MCP grandchildren a brief chance to be reparented to init
  # before scanning, otherwise the conservative detector can miss them.
  sleep 0.2
  bridge_mcp_orphan_cleanup "session-exit:${AGENT}" "$min_age" 1 >/dev/null 2>&1 || true
}

bridge_run_roster_signature() {
  local payload=""
  local file=""

  for file in "$BRIDGE_ROSTER_FILE" "$BRIDGE_ROSTER_LOCAL_FILE"; do
    payload+="${file}"$'\n'
    if [[ -f "$file" ]]; then
      payload+="present"$'\n'
      payload+="$(cat "$file")"$'\n'
    else
      payload+="missing"$'\n'
    fi
  done

  bridge_sha1 "$payload"
}

bridge_run_refresh_roster_if_changed() {
  local signature=""

  signature="$(bridge_run_roster_signature)"
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" && "$signature" == "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    return 0
  fi

  bridge_load_roster
  bridge_require_agent "$AGENT"
  # PR-E: re-apply v2 umask after roster reload — bridge-lib.sh's umask 077
  # is sticky across the process but a defensive re-set guards against any
  # subshell that may have reset it during the refresh.
  bridge_run_apply_v2_umask_if_needed "$AGENT"
  if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
    BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
  fi
  WORK_DIR="$(bridge_agent_workdir "$AGENT")"
  ENGINE="$(bridge_agent_engine "$AGENT")"
  SESSION="$(bridge_agent_session "$AGENT")"
  [[ -n "$WORK_DIR" ]] || bridge_die "'$AGENT'의 workdir가 비어 있습니다."
  cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    log_line "[info] roster changed on disk; reloading before next relaunch"
  fi
  BRIDGE_RUN_ROSTER_SIGNATURE="$signature"
}

# Returns 0 if there is at least one open (queued/claimed/blocked) handoff
# task for the agent. Used by bridge_run_reconcile_next_session_state to
# preserve NEXT-SESSION.md while the next session has not yet acknowledged
# the handoff. find-open already excludes terminal states.
bridge_run_handoff_pending_for_agent() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  local found=""
  found="$(bridge_queue_cli find-open --agent "$agent" \
    --title-prefix "[bridge:handoff-pending]" --format id 2>/dev/null || true)"
  [[ -n "$found" ]]
}

bridge_run_reconcile_next_session_state() {
  local next_file=""
  local marker_file=""
  local age_seconds=""
  local ttl_seconds="${BRIDGE_NEXT_SESSION_AUTO_CLEAR_SECONDS:-300}"

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  next_file="$(bridge_agent_next_session_file "$AGENT")"
  [[ -f "$next_file" ]] || return 0

  if bridge_run_handoff_pending_for_agent "$AGENT"; then
    log_line "[info] NEXT-SESSION.md preserved — handoff task pending for $AGENT"
    return 0
  fi

  age_seconds="$(bridge_agent_maybe_expire_next_session "$AGENT" "$ttl_seconds" || true)"
  if [[ "$age_seconds" =~ ^[0-9]+$ ]]; then
    marker_file="$(bridge_agent_next_session_marker_file "$AGENT")"
    log_line "[info] auto-cleared stale NEXT-SESSION.md after ${age_seconds}s (previous handoff digest was already delivered)"
    bridge_audit_log daemon next_session_autocleared "$AGENT" \
      --detail age_seconds="$age_seconds" \
      --detail ttl_seconds="$ttl_seconds" \
      --detail next_session_file="$next_file" \
      --detail marker_file="$marker_file"
    return 0
  fi

  if [[ "$(bridge_agent_continue "$AGENT")" == "1" ]]; then
    log_line "[warn] NEXT-SESSION.md present at $next_file -> --resume suppressed for this restart. Delete it after handoff verification."
  fi
}

bridge_run_schedule_idle_marker_and_inbox_bootstrap() {
  local next_file="$WORK_DIR/NEXT-SESSION.md"
  local marker_file=""

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  marker_file="$(bridge_agent_initial_inbox_marker_file "$AGENT")"

  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      marker_file="$4"
      next_file="$5"
      source "$script_dir/bridge-lib.sh"
      if bridge_tmux_wait_for_prompt "$session" claude 30; then
        if [[ -z "$(bridge_agent_session_id "$agent")" ]]; then
          # Claude session metadata can appear after tmux startup. Refresh once
          # more at prompt-ready time so static resume state is persisted before
          # the agent later goes inactive.
          bridge_refresh_agent_session_id "$agent" 24 0.5 >/dev/null 2>&1 || true
        fi
        bridge_agent_mark_idle_now "$agent"
        if [[ ! -f "$next_file" && ! -f "$marker_file" ]]; then
          task_id="$(bridge_queue_cli find-open --agent "$agent" 2>/dev/null | head -n 1 || true)"
          if [[ -n "$task_id" ]]; then
            if bridge_inject_metadata_only_enabled; then
              inject_text="$(bridge_format_injection_meta inbox-bootstrap agent="$agent" top="$task_id")"
            else
              inject_text="[Agent Bridge] ACTION REQUIRED — queued tasks detected. Run exactly: ~/.agent-bridge/agb inbox $agent"
            fi
            bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
          fi
          mkdir -p "$(dirname "$marker_file")"
          printf "%s\n" "$(date +%s)" >"$marker_file"
        fi
      fi
    ' -- "$SCRIPT_DIR" "$SESSION" "$AGENT" "$marker_file" "$next_file"
  ) >/dev/null 2>&1 &
}

bridge_run_should_auto_accept_dev_channels() {
  local launch_cmd="$1"
  local effective=""

  [[ "$ENGINE" == "claude" ]] || return 1
  [[ $SAFE_MODE -eq 0 ]] || return 1
  # Presence of --dangerously-load-development-channels in the launch cmd
  # is itself the operator's explicit opt-in; the warning picker is a
  # confirmation of that same decision. Auto-accept whenever any dev
  # channel is extracted from the cmd, regardless of the per-agent
  # allowlist or isolation mode. PR #364 r2 originally gated this on the
  # bridge_agent_auto_accept_dev_channels_csv allowlist, which silently
  # excluded non-isolated agents whose roster had a non-default override
  # (issue #410: sales_sean stalled indefinitely on the picker on cold
  # start because the per-agent allowlist did not intersect the loaded
  # dev channels).
  effective="$(bridge_extract_development_channels_from_command "$launch_cmd")"
  [[ -n "$effective" ]] || return 1
  return 0
}

bridge_run_schedule_dev_channels_accept() {
  local launch_cmd="$1"

  bridge_run_should_auto_accept_dev_channels "$launch_cmd" || return 0

  # Operator-tunable timeout. Default 60s covers 4-plugin cold-start
  # (bun teams + bun ms365 + node cosmax-* MCP servers) on isolated
  # linux-user agents where claude takes longer than the historic 15s
  # budget to draw the development-channels picker. Reduce to 5–15s in
  # diagnosis to fail-loud quickly.
  local accept_timeout="${BRIDGE_RUN_DEV_CHANNELS_ACCEPT_TIMEOUT_SECONDS:-60}"
  [[ "$accept_timeout" =~ ^[0-9]+$ ]] || accept_timeout=60
  (( accept_timeout > 0 )) || accept_timeout=60

  log_line "[info] auto-accepting Claude development-channels prompt for allowlisted dev channel(s) (timeout=${accept_timeout}s)"

  # Background child must not silently swallow stderr — that hid every
  # picker-stuck warning before. Route its output to the agent log files
  # the parent already maintains so wait_for_prompt's bridge_warn lines
  # land where operators look. accept_timeout is passed in as $3 because
  # the child runs in a fresh `bash -lc` shell with `set -u` — outer
  # locals are not visible.
  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      accept_timeout="$3"
      source "$script_dir/bridge-lib.sh"
      if ! bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then
        printf "[%s] [warn] auto-accept dev-channels: bridge_tmux_wait_for_prompt failed/timeout on session=%s\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" >&2
      fi
    ' -- "$SCRIPT_DIR" "$SESSION" "$accept_timeout"
  ) </dev/null >>"$LOGFILE" 2>>"$ERRFILE" &
}

bridge_run_sync_dev_plugin_cache() {
  local channels=""
  local output=""
  local line=""

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  channels="$(bridge_agent_effective_dev_channels_csv "$AGENT")"
  [[ -n "$channels" ]] || return 0

  if output="$(python3 "$SCRIPT_DIR/bridge-dev-plugin-cache.py" sync --channels "$channels" 2>&1)"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log_line "[dev-plugin-cache] $line"
    done <<<"$output"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log_line "[dev-plugin-cache] $line"
    done <<<"$output"
    bridge_warn "development plugin cache sync failed for ${AGENT}"
  fi
}

bridge_run_safe_mode_resume_hint() {
  local mode=""
  local admin_agent=""

  mode="$(bridge_safe_mode_resume_mode "$AGENT")"
  admin_agent="$(bridge_require_admin_agent 2>/dev/null || true)"
  log_line "[safe-mode] booting ${AGENT} with minimal launch"
  log_line "[safe-mode] ignored roster launch_cmd: $(bridge_redact_inline_env_secrets "$(bridge_agent_launch_cmd_raw "$AGENT")")"
  if [[ -n "$(bridge_agent_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed channels: $(bridge_agent_channels_csv "$AGENT")"
  fi
  if [[ -n "$(bridge_agent_effective_dev_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed development channels: $(bridge_agent_effective_dev_channels_csv "$AGENT")"
  fi
  log_line "[safe-mode] skipped project bootstrap and channel plugin loading"
  log_line "[safe-mode] resume strategy: ${mode}"
  if [[ -n "$admin_agent" && "$AGENT" == "$admin_agent" ]]; then
    log_line "[safe-mode] return to normal mode with: agb admin"
  else
    log_line "[safe-mode] return to normal mode with: agent-bridge agent start ${AGENT}"
  fi
}

bridge_run_fail_backoff_seconds() {
  local count="$1"
  local csv="${BRIDGE_RUN_FAIL_BACKOFFS_CSV:-5,10,20,40,80}"
  local -a values=()
  local index=0

  IFS=',' read -r -a values <<<"$csv"
  [[ "$count" =~ ^[0-9]+$ ]] || count=1
  index=$((count - 1))
  if (( index < 0 )); then
    index=0
  fi
  if (( index < ${#values[@]} )); then
    printf '%s' "${values[$index]}"
  elif (( ${#values[@]} > 0 )); then
    printf '%s' "${values[$((${#values[@]} - 1))]}"
  else
    printf '%s' "80"
  fi
}

log_line "${AGENT} 에이전트 시작 (engine=${ENGINE}, dir=${WORK_DIR})"
BRIDGE_RUN_ROSTER_SIGNATURE="$(bridge_run_roster_signature)"
if [[ $SAFE_MODE -eq 1 ]]; then
  bridge_run_safe_mode_resume_hint
fi

FAIL_COUNT=0
RESTART_COUNT=0
RAPID_FAIL_COUNT=0
RAPID_FAIL_WINDOW="${BRIDGE_RUN_RAPID_FAIL_WINDOW_SECONDS:-10}"
MAX_RAPID_FAILS="${BRIDGE_RUN_MAX_RAPID_FAILS:-5}"
HEALTHY_RUN_RESET_SECONDS="${BRIDGE_RUN_HEALTHY_RESET_SECONDS:-60}"
while true; do
  local_launch_cmd_display=""
  local_err_size_before=0
  local_err_size_after=0
  run_started_at=0
  run_ended_at=0
  run_duration=0
  rapid_failure=0
  sleep_seconds=5
  bridge_run_refresh_roster_if_changed
  export BRIDGE_AGENT_LOOP_RESTART_COUNT="$RESTART_COUNT"
  bridge_run_reconcile_next_session_state
  if [[ $SAFE_MODE -eq 1 ]]; then
    LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
  else
    LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
  fi
  [[ -n "$LAUNCH_CMD" ]] || bridge_die "'$AGENT'의 launch command가 비어 있습니다."
  local_launch_cmd_display="$(bridge_redact_inline_env_secrets "$LAUNCH_CMD")"

  if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
    bridge_run_sync_dev_plugin_cache
    bridge_ensure_claude_launch_channel_plugins "$AGENT"
    bridge_run_schedule_dev_channels_accept "$LAUNCH_CMD"
    bridge_run_schedule_idle_marker_and_inbox_bootstrap
  fi

  log_line "실행: ${local_launch_cmd_display}"
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_before="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi
  # v2 isolation: load per-agent launch secrets from credentials/launch-secrets.env
  # into the child shell so the child inherits them via export, NEVER via
  # composing into LAUNCH_CMD. Composing tokens into LAUNCH_CMD leaks via
  # process listings, raw display output, crash-report paths, and
  # any tee'd stderr. Loading inside the launch subshell (not the parent)
  # also prevents stale secrets from persisting across restart-loop
  # iterations after the credentials file is rotated, emptied, or removed.
  _v2_secret_file=""
  if bridge_isolation_v2_active; then
    _v2_secret_file="$(bridge_isolation_v2_agent_secret_env_file "$AGENT" 2>/dev/null || true)"
    [[ -n "$_v2_secret_file" && -f "$_v2_secret_file" ]] || _v2_secret_file=""
  fi
  run_started_at="$(date +%s)"
  if [[ -n "$_v2_secret_file" ]]; then
    # PR-C r2 (codex r1 G-19): the subshell-wrap pattern lives in
    # lib/bridge-isolation-v2.sh as bridge_isolation_v2_exec_with_secret_env
    # so the smoke test exercises the EXACT production code path. The
    # helper sets BRIDGE_ISOLATION_V2_LAST_EXEC_RC to the child's exit
    # code (or calls bridge_die on loader failure).
    BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
    bridge_isolation_v2_exec_with_secret_env \
      "$_v2_secret_file" "$BRIDGE_BASH_BIN" "$LAUNCH_CMD" "$ERRFILE" "$AGENT"
    EXIT_CODE="$BRIDGE_ISOLATION_V2_LAST_EXEC_RC"
    unset BRIDGE_ISOLATION_V2_LAST_EXEC_RC
  else
    if "$BRIDGE_BASH_BIN" -lc "$LAUNCH_CMD" 2> >(tee -a "$ERRFILE" >&2); then
      EXIT_CODE=0
    else
      EXIT_CODE=$?
    fi
  fi
  unset _v2_secret_file
  run_ended_at="$(date +%s)"
  if [[ "$run_started_at" =~ ^[0-9]+$ && "$run_ended_at" =~ ^[0-9]+$ ]]; then
    run_duration=$((run_ended_at - run_started_at))
  fi
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_after="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi

  bridge_run_cleanup_mcp_orphans

  if [[ $ONCE -eq 1 ]]; then
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    log_line "1회 실행 종료 (코드: ${EXIT_CODE})"
    exit "$EXIT_CODE"
  fi

  if [[ $EXIT_CODE -eq 0 ]] && bridge_run_session_attached; then
    if bridge_agent_should_stop_on_attached_clean_exit "$AGENT"; then
      if [[ $FAIL_COUNT -gt 0 ]]; then
        bridge_agent_clear_crash_report "$AGENT"
      fi
      bridge_run_stop_foreground_session
      log_line "정상 종료. admin 온보딩이 아직 완료되지 않았으므로 자동 재시작하지 않습니다. 다시 열려면 'agb admin'을 실행하세요."
      exit 0
    else
      log_line "정상 종료. 온보딩 완료/일반 루프 에이전트이므로 tmux client는 분리하고, 에이전트는 백그라운드에서 계속 재시작합니다."
      bridge_run_detach_attached_clients
    fi
  fi

  if [[ $EXIT_CODE -ne 0 ]]; then
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$HEALTHY_RUN_RESET_SECONDS" =~ ^[0-9]+$ ]] && (( run_duration >= HEALTHY_RUN_RESET_SECONDS )); then
      FAIL_COUNT=0
      RAPID_FAIL_COUNT=0
      bridge_agent_clear_crash_report "$AGENT"
    fi
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$RAPID_FAIL_WINDOW" =~ ^[0-9]+$ ]] && (( run_duration < RAPID_FAIL_WINDOW )); then
      rapid_failure=1
      RAPID_FAIL_COUNT=$((RAPID_FAIL_COUNT + 1))
    else
      RAPID_FAIL_COUNT=0
    fi
    if [[ $FAIL_COUNT -eq 5 || $(( FAIL_COUNT % 10 )) -eq 0 ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display"
      bridge_audit_log daemon crash_loop_detected "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail stderr_file="$ERRFILE"
    fi
    if [[ $rapid_failure -eq 1 && "$RAPID_FAIL_COUNT" =~ ^[0-9]+$ && "$MAX_RAPID_FAILS" =~ ^[0-9]+$ && $RAPID_FAIL_COUNT -ge $MAX_RAPID_FAILS ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display"
      bridge_agent_write_broken_launch_state "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display" "$local_err_size_before"
      bridge_audit_log daemon crash_loop_broken "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail rapid_fail_count="$RAPID_FAIL_COUNT" \
        --detail rapid_fail_window="$RAPID_FAIL_WINDOW"
      log_line "[fail] ${RAPID_FAIL_COUNT} consecutive rapid failures under ${RAPID_FAIL_WINDOW}s. Circuit breaker opened."
      log_line "[fail] recovery: agent-bridge agent safe-mode ${AGENT}"
      log_loop_help
      exit 1
    fi
    if [[ $rapid_failure -eq 1 ]]; then
      sleep_seconds="$(bridge_run_fail_backoff_seconds "$RAPID_FAIL_COUNT")"
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, rapid=${RAPID_FAIL_COUNT}/${MAX_RAPID_FAILS}, 실행시간: ${run_duration}s). ${sleep_seconds}초 후 재시작..."
    else
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, 실행시간: ${run_duration}s). 5초 후 재시작..."
    fi
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [[ $rapid_failure -eq 1 ]]; then
      sleep "$sleep_seconds"
    elif [[ $FAIL_COUNT -ge 10 ]]; then
      log_line "연속 ${FAIL_COUNT}회 실패. 60초 대기..."
      sleep 60
    else
      sleep 5
    fi
  else
    if [[ $FAIL_COUNT -gt 0 ]]; then
      bridge_agent_clear_crash_report "$AGENT"
      bridge_audit_log daemon crash_loop_recovered "$AGENT" \
        --detail engine="$ENGINE" \
        --detail previous_fail_count="$FAIL_COUNT"
    fi
    FAIL_COUNT=0
    RAPID_FAIL_COUNT=0
    log_line "정상 종료. 5초 후 재시작..."
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    sleep 5
  fi
done
