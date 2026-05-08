#!/usr/bin/env bash
# bridge-start.sh — roster 기반 tmux 세션 시작기

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-start.sh <agent> [--replace] [--attach|--no-attach] [--continue|--no-continue] [--safe-mode] [--dry-run] [--skip-project-skill]"
  echo "       bash $SCRIPT_DIR/bridge-start.sh --list"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
REPLACE=0
ATTACH=0
DRY_RUN=0
CONTINUE_EXPLICIT=0
CONTINUE_MODE=1
INSTALL_PROJECT_SKILL=1
SAFE_MODE=0
AGENT=""
CONTROLLER_DEV_CHANNELS_ACCEPT=0

bridge_start_dev_channels_accept_timeout() {
  local accept_timeout="${BRIDGE_START_DEV_CHANNELS_ACCEPT_TIMEOUT_SECONDS:-${BRIDGE_RUN_DEV_CHANNELS_ACCEPT_TIMEOUT_SECONDS:-60}}"

  [[ "$accept_timeout" =~ ^[0-9]+$ ]] || accept_timeout=60
  (( accept_timeout > 0 )) || accept_timeout=60
  printf '%s' "$accept_timeout"
}

bridge_start_effective_dev_channels_csv() {
  local agent="$1"
  local suppress_missing="${2:-0}"

  if [[ "$suppress_missing" == "1" ]]; then
    BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_agent_effective_dev_channels_csv "$agent"
    return 0
  fi

  bridge_agent_effective_dev_channels_csv "$agent"
}

bridge_start_should_controller_accept_dev_channels() {
  local agent="$1"
  local suppress_missing="${2:-0}"
  local effective=""

  [[ "$ENGINE" == "claude" ]] || return 1
  [[ $SAFE_MODE -eq 0 ]] || return 1
  effective="$(bridge_start_effective_dev_channels_csv "$agent" "$suppress_missing")"
  [[ -n "$effective" ]]
}

bridge_start_post_launch_verify() {
  # Issue #715-C / #714-5: tmux new-session reports success even if the
  # session dies a few hundred ms later (plugin MCP liveness restart loop,
  # missing operator config, isolation permission errors). Poll
  # bridge_tmux_session_exists for a short window and surface a log tail +
  # remediation hint when the session disappears, so `agb admin` and
  # `bash bridge-start.sh <agent>` no longer report success on a dead
  # tmux pane.
  local session="$1"
  local agent="$2"
  local attempts="${BRIDGE_START_VERIFY_POLL_ATTEMPTS:-10}"
  local interval="${BRIDGE_START_VERIFY_POLL_INTERVAL_SECONDS:-1}"
  local tail_lines="${BRIDGE_START_VERIFY_LOG_TAIL_LINES:-20}"
  local i log_dir log_file=""

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=10
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1
  [[ "$tail_lines" =~ ^[0-9]+$ ]] || tail_lines=20
  (( attempts > 0 )) || return 0
  (( interval > 0 )) || interval=1

  # Defensive: if tmux helper isn't loaded for any reason, preserve prior
  # behaviour (silent skip) rather than spuriously failing healthy starts.
  declare -F bridge_tmux_session_exists >/dev/null 2>&1 || return 0

  for ((i = 0; i < attempts; i++)); do
    sleep "$interval"
    if ! bridge_tmux_session_exists "$session"; then
      log_dir="$(bridge_agent_log_dir "$agent" 2>/dev/null || true)"
      if [[ -n "$log_dir" ]]; then
        log_file="$log_dir/$(date '+%Y%m%d').log"
      fi
      bridge_warn "세션 '$session'이 시작 직후 종료되었습니다 (시작 후 $((i + 1)) 회차 polling)."
      if [[ -n "$log_file" && -r "$log_file" ]]; then
        printf '[info] 마지막 로그 (%s):\n' "$log_file" >&2
        tail -n "$tail_lines" "$log_file" >&2 || true
      else
        printf '[info] 에이전트 로그를 찾지 못했습니다 (확인 경로: %s)\n' "${log_file:-<unknown>}" >&2
      fi
      cat >&2 <<EOF
[info] 가능한 원인:
  - daemon 쪽 plugin MCP liveness restart loop
    (확인: grep "plugin MCP liveness miss" "\$BRIDGE_HOME/state/daemon.log")
  - operator-config 누락 (예: discord/teams 토큰; agb setup discord / agb setup teams)
  - workdir 권한 (linux-user isolation; agent workdir 소유권/모드 확인)
EOF
      return 1
    fi
  done
  return 0
}

bridge_start_schedule_dev_channels_accept() {
  local session="$1"
  local agent="$2"
  local accept_timeout=""
  local log_dir=""
  local logfile="/dev/null"
  local errfile="/dev/null"

  accept_timeout="$(bridge_start_dev_channels_accept_timeout)"
  log_dir="$(bridge_agent_log_dir "$agent")"
  if mkdir -p "$log_dir" 2>/dev/null; then
    logfile="$log_dir/$(date '+%Y%m%d').log"
    errfile="$log_dir/$(date '+%Y%m%d').err.log"
  fi

  echo "[info] controller-side Claude development-channels auto-accept armed for '$session' (timeout=${accept_timeout}s)"
  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      accept_timeout="$4"
      source "$script_dir/bridge-lib.sh"
      if bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then
        printf "[%s] [info] controller auto-accept dev-channels completed on session=%s agent=%s\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent"
      else
        printf "[%s] [warn] controller auto-accept dev-channels failed/timeout on session=%s agent=%s\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent" >&2
      fi
    ' -- "$SCRIPT_DIR" "$session" "$agent" "$accept_timeout"
  ) </dev/null >>"$logfile" 2>>"$errfile" &
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    --attach)
      ATTACH=1
      shift
      ;;
    --no-attach)
      ATTACH=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --safe-mode)
      SAFE_MODE=1
      INSTALL_PROJECT_SKILL=0
      shift
      ;;
    --skip-project-skill)
      INSTALL_PROJECT_SKILL=0
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

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$AGENT" ]]; then
  usage
  exit 1
fi

bridge_require_agent "$AGENT"
bridge_agent_clear_manual_stop "$AGENT"

SESSION="$(bridge_agent_session "$AGENT")"
WORK_DIR="$(bridge_agent_workdir "$AGENT")"
DEFAULT_WORK_DIR="$(bridge_agent_default_home "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
RUNNER="$SCRIPT_DIR/bridge-run.sh"
ENV_PREFIX="$(bridge_export_env_prefix)"
EFFECTIVE_CONTINUE_MODE="$(bridge_agent_continue "$AGENT")"
FORCE_FRESH_SESSION=0
SUPPRESS_MISSING_CHANNELS=0
CHANNEL_REASON=""
AGENT_ENV_FILE=""

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ "$WORK_DIR" == "$DEFAULT_WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
  else
    bridge_die "workdir가 없습니다: $WORK_DIR"
  fi
fi

if bridge_tmux_session_exists "$SESSION"; then
  if [[ $REPLACE -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[info] 기존 세션 '$SESSION' would be replaced"
    else
      bridge_tmux_kill_session "$SESSION"
      echo "[info] 기존 세션 '$SESSION' 제거"
    fi
  else
    echo "[info] 세션 '$SESSION'이 이미 실행 중입니다."
    if [[ $ATTACH -eq 1 ]]; then
      bridge_attach_tmux_session "$SESSION"
    fi
    exit 0
  fi
fi

if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
  if bridge_project_claude_guidance_needed "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    bridge_ensure_project_claude_guidance "$WORK_DIR" >/dev/null 2>&1 || true
  fi
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_stop_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_session_start_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_prompt_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_prompt_guard_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_tool_policy_hooks_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR"; then
      bridge_warn "Claude bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  bridge_bootstrap_claude_shared_skills "$AGENT" "$WORK_DIR" || true
  if ! bridge_ensure_claude_project_trust "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude project trust seed failed: $WORK_DIR"
  fi
  # Issue #555: forward agent id (3rd arg) so each ensure-*-hook helper
  # relinks the per-agent effective file at $BRIDGE_AGENT_HOME_ROOT/<agent>/
  # .claude/settings.effective.json. Issue #570: managed autoCompactWindow
  # default is unconditionally 1_000_000; launch_cmd is forwarded for
  # caller-signature parity only (no longer consulted by the renderer).
  AGENT_LAUNCH_CMD="$(bridge_agent_launch_cmd_raw "$AGENT" 2>/dev/null || true)"
  if ! bridge_ensure_claude_stop_hook "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null; then
    bridge_die "Claude Stop hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_session_start_hook "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null; then
    bridge_die "Claude SessionStart hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_prompt_hook "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null; then
    bridge_die "Claude UserPromptSubmit hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_prompt_guard_hook "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null; then
    bridge_die "Claude prompt guard hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_tool_policy_hooks "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null; then
    bridge_die "Claude tool policy hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_disable_claude_webhook_channel "$AGENT" "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude backlog webhook channel cleanup skipped: $WORK_DIR"
  fi
elif [[ "$ENGINE" == "codex" && $SAFE_MODE -eq 0 ]]; then
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR"; then
      bridge_warn "Codex bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  if ! bridge_ensure_codex_hooks >/dev/null; then
    bridge_die "Codex hook 설정에 실패했습니다: $WORK_DIR"
  fi
fi

if [[ $FORCE_FRESH_SESSION -eq 1 ]]; then
  if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "1" ]]; then
    bridge_warn "Bridge project setup changed or was missing. Forcing a fresh session so CLAUDE.md, skills, and hooks are loaded."
  fi
  EFFECTIVE_CONTINUE_MODE=0
elif [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  EFFECTIVE_CONTINUE_MODE="$CONTINUE_MODE"
fi

# Issue #268: warn the operator when --no-continue is launching fresh but a
# stale resume id is still persisted. Without this, an operator who used
# --no-continue to escape a broken `claude --resume` does not realise the
# next normal restart will pick the bad id back up.
if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "0" ]]; then
  _persisted_session_id="$(bridge_agent_persisted_session_id "$AGENT")"
  if [[ -n "$_persisted_session_id" ]]; then
    bridge_warn "launched fresh for this run, but saved session_id=${_persisted_session_id} remains; next normal restart will resume it. Use 'agb agent forget-session $AGENT' to clear permanently."
  fi
  unset _persisted_session_id
fi

if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
  CHANNEL_REASON="$(bridge_agent_channel_status_reason "$AGENT")"
  if [[ -n "$CHANNEL_REASON" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$AGENT"; then
      SUPPRESS_MISSING_CHANNELS=1
      bridge_warn "Channel runtime is incomplete for pending admin '$AGENT'. Starting without missing channel plugins until onboarding completes: $CHANNEL_REASON"
    elif [[ $DRY_RUN -eq 0 ]]; then
      bridge_die "$(bridge_agent_channel_setup_guidance "$AGENT" "$CHANNEL_REASON")"
    fi
  fi
fi

if bridge_isolation_disabled_by_env; then
  bridge_warn "BRIDGE_DISABLE_ISOLATION=1 — skipping v2 isolation prep for '$AGENT' (security boundary disabled, agent will run as controller UID without sudo wrap or per-agent env file)"
elif bridge_agent_linux_user_isolation_effective "$AGENT"; then
  AGENT_ENV_FILE="$(bridge_agent_linux_env_file "$AGENT")"
  bridge_write_linux_agent_env_file "$AGENT" "$AGENT_ENV_FILE"
fi

SESSION_CMD="$(bridge_join_quoted "$BRIDGE_BASH_BIN" "$RUNNER" "$AGENT")"
if [[ "$EFFECTIVE_CONTINUE_MODE" == "1" ]]; then
  SESSION_CMD+=" --continue"
else
  SESSION_CMD+=" --no-continue"
fi
if [[ $SAFE_MODE -eq 1 ]]; then
  SESSION_CMD+=" --safe-mode"
fi
if [[ "$(bridge_agent_loop "$AGENT")" != "1" ]]; then
  SESSION_CMD+=" --once"
fi
if [[ -n "$ENV_PREFIX" ]]; then
  SESSION_CMD="${ENV_PREFIX} ${SESSION_CMD}"
fi
if [[ -n "$AGENT_ENV_FILE" ]]; then
  SESSION_CMD="BRIDGE_AGENT_ENV_FILE=$(printf '%q' "$AGENT_ENV_FILE") ${SESSION_CMD}"
fi
if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
  SESSION_CMD="BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 ${SESSION_CMD}"
fi
if bridge_start_should_controller_accept_dev_channels "$AGENT" "$SUPPRESS_MISSING_CHANNELS"; then
  CONTROLLER_DEV_CHANNELS_ACCEPT=1
  SESSION_CMD="BRIDGE_CONTROLLER_DEV_CHANNELS_ACCEPT=1 ${SESSION_CMD}"
fi

SUDO_WRAP_ACTIVE=0
SUDO_WRAP_OS_USER=""
SUDO_WRAP_FALLBACK_REASON=""
# v0.8.0 T5: BRIDGE_DISABLE_ISOLATION=1 short-circuits the sudo wrap so
# the SESSION_CMD runs unwrapped under the controller UID. The earlier
# env-file guard already emitted the operator warning; this branch
# stays silent to avoid a duplicate per-restart log line.
if bridge_isolation_disabled_by_env; then
  :
elif bridge_agent_linux_user_isolation_effective "$AGENT"; then
  SUDO_WRAP_OS_USER="$(bridge_agent_os_user "$AGENT")"
  if [[ "$(id -u)" == "0" ]]; then
    SUDO_WRAP_FALLBACK_REASON="controller is root; sudo wrap skipped"
  elif ! id -u "$SUDO_WRAP_OS_USER" >/dev/null 2>&1; then
    SUDO_WRAP_FALLBACK_REASON="os_user $SUDO_WRAP_OS_USER does not exist"
  elif ! bridge_linux_can_sudo_to "$SUDO_WRAP_OS_USER"; then
    SUDO_WRAP_FALLBACK_REASON="passwordless sudo -u $SUDO_WRAP_OS_USER not available"
  else
    SUDO_WRAP_ACTIVE=1
  fi
fi

if [[ $SUDO_WRAP_ACTIVE -eq 1 ]]; then
  SUDO_PRESERVE_ENV="$(bridge_agent_preserved_env_vars)"
  SUDO_WRAPPED_CMD="sudo -n -u $(printf '%q' "$SUDO_WRAP_OS_USER") -H"
  if [[ -n "$SUDO_PRESERVE_ENV" ]]; then
    SUDO_WRAPPED_CMD+=" --preserve-env=$(printf '%q' "$SUDO_PRESERVE_ENV")"
  fi
  SUDO_WRAPPED_CMD+=" -- $(printf '%q' "$BRIDGE_BASH_BIN") -lc $(printf '%q' "$SESSION_CMD")"
  SESSION_CMD="$SUDO_WRAPPED_CMD"
elif [[ -n "$SUDO_WRAP_OS_USER" && -n "$SUDO_WRAP_FALLBACK_REASON" && $DRY_RUN -eq 0 ]]; then
  bridge_warn "linux-user isolation requested for '$AGENT' but UID switch unavailable: $SUDO_WRAP_FALLBACK_REASON. Falling back to shared-mode launch. Run 'agent-bridge isolate $AGENT --install-sudoers' or configure sudoers manually (see docs/linux-host-acceptance.md)."
  bridge_audit_log state linux_user_sudo_unavailable "$AGENT" \
    --field os_user="$SUDO_WRAP_OS_USER" \
    --field reason="$SUDO_WRAP_FALLBACK_REASON" >/dev/null 2>&1 || true
fi

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
    launch_channels="$(BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_agent_launch_channels_csv "$AGENT")"
  else
    launch_channels="$(bridge_agent_launch_channels_csv "$AGENT")"
  fi
  echo "agent=$AGENT"
  echo "session=$SESSION"
  echo "workdir=$WORK_DIR"
  echo "continue=$EFFECTIVE_CONTINUE_MODE"
  echo "safe_mode=$SAFE_MODE"
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "launch_channels=$launch_channels"
  if [[ -n "$AGENT_ENV_FILE" ]]; then
    echo "agent_env_file=$AGENT_ENV_FILE"
  fi
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  if [[ -n "$CHANNEL_REASON" ]]; then
    echo "channel_reason=$CHANNEL_REASON"
  fi
  if [[ -n "$SUDO_WRAP_OS_USER" ]]; then
    echo "sudo_wrap_active=$SUDO_WRAP_ACTIVE"
    echo "sudo_wrap_os_user=$SUDO_WRAP_OS_USER"
    if [[ -n "$SUDO_WRAP_FALLBACK_REASON" ]]; then
      echo "sudo_wrap_fallback_reason=$SUDO_WRAP_FALLBACK_REASON"
    fi
  fi
  echo "tmux_command=$SESSION_CMD"
  exit 0
fi

if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
  if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
    BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_ensure_claude_launch_channel_plugins "$AGENT"
  else
    bridge_ensure_claude_launch_channel_plugins "$AGENT"
  fi
fi

bridge_agent_clear_idle_marker "$AGENT"
# Issue #589: clear prompt-ready latch from any prior session. The marker
# is per-session; once the new session boots and its tmux pane reaches the
# Claude/Codex prompt, send-path or daemon-poll will rewrite it.
bridge_agent_clear_prompt_ready "$AGENT"

# #256 Gap 2: an explicit operator start/safe-mode here is the documented
# way out of a rapid-fail quarantine. Clear the broken-launch marker only
# once we are past dry-run short-circuits, workdir validation, and the
# channel-plugin preflight — so a `--dry-run` inspect or a failed-start
# (missing workdir / channel setup error) does not silently unquarantine
# the agent before any relaunch actually runs. If the underlying cause
# is still present, `bridge-run.sh` will trip the circuit breaker again
# and re-write the marker on the first post-unblock failure cycle.
bridge_agent_clear_broken_launch "$AGENT"

# Refresh the launch window so a new session id can be detected for this run.
# shellcheck disable=SC2034
BRIDGE_AGENT_CREATED_AT["$AGENT"]="$(date +%s)"
bridge_persist_agent_state "$AGENT"

tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$SESSION_CMD"
bridge_tmux_bootstrap_session_options "$SESSION"
if [[ "$ENGINE" == "claude" ]]; then
  bridge_tmux_prepare_claude_session "$SESSION" 8 >/dev/null 2>&1 || true
  if [[ $CONTROLLER_DEV_CHANNELS_ACCEPT -eq 1 ]]; then
    bridge_start_schedule_dev_channels_accept "$SESSION" "$AGENT"
  fi
  bridge_agent_mark_idle_now "$AGENT"
fi
if [[ -z "$(bridge_agent_session_id "$AGENT")" ]]; then
  bridge_refresh_agent_session_id "$AGENT" 12 0.25 >/dev/null 2>&1 || true
fi
echo "[info] 세션 '$SESSION' 시작 완료"

# Issue #715-C / #714-5: short post-launch has-session polling so a session
# that dies inside the first few seconds (e.g. daemon restart loop on an
# unconfigured plugin MCP, isolation permission failure) is surfaced with
# a log tail and remediation hint instead of a silent success.
if ! bridge_start_post_launch_verify "$SESSION" "$AGENT"; then
  exit 1
fi

if [[ $ATTACH -eq 1 ]]; then
  bridge_attach_tmux_session "$SESSION"
fi
