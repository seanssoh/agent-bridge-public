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

# Time budget for Claude to reach the foreground (i.e. begin presenting its
# trust/dev-channels prompts) AFTER tmux session creation. The controller
# watcher arms immediately at tmux-create time, but on a fresh-plugin-cache
# launch bridge-run.sh first runs bridge_run_sync_dev_plugin_cache for the
# four configured channels, which can take 3-5 minutes; only then does it
# exec `claude`. The previous design only had a single 60s prompt-accept
# budget — so the controller watcher would time out before Claude even
# started, leaving the trust/dev-channels prompts unanswered and the
# operator stuck pressing Enter manually. Split budget: this one covers
# "wait until claude is in the foreground" and is intentionally generous.
# The existing accept timeout (default 60s) then covers "from foreground
# to prompt accepted" which is typically <10s.
bridge_start_dev_channels_claude_foreground_timeout() {
  local foreground_timeout="${BRIDGE_START_DEV_CHANNELS_CLAUDE_FOREGROUND_TIMEOUT_SECONDS:-600}"

  [[ "$foreground_timeout" =~ ^[0-9]+$ ]] || foreground_timeout=600
  (( foreground_timeout > 0 )) || foreground_timeout=600
  printf '%s' "$foreground_timeout"
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

bridge_start_should_send_onboarding_nudge() {
  # Fresh-install nudge gate (see usage in main flow). Returns 0 only
  # when the agent's SESSION-TYPE.md declares `Session Type: admin` AND
  # `Onboarding State: pending`. Static-claude and dynamic agents are
  # NOT nudged — they have no onboarding flow tied to first user msg.
  local agent="$1"
  local home_dir
  home_dir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -d "$home_dir" ]] || return 1
  [[ -f "$home_dir/SESSION-TYPE.md" ]] || return 1
  grep -qE '^- Session Type:[[:space:]]*admin\b' "$home_dir/SESSION-TYPE.md" 2>/dev/null || return 1
  [[ "$(bridge_agent_onboarding_state "$agent" 2>/dev/null || printf '')" == "pending" ]]
}

bridge_start_send_onboarding_nudge_async() {
  # Send a short onboarding-start nudge to the agent's tmux session in
  # the background so the foreground bridge-start.sh flow continues to
  # the post-launch verify + attach step. The nudge fires ~8 seconds
  # after the agent process becomes interactive (Claude Code welcome
  # screen + initial prompt rendering settles around that mark).
  local session="$1"
  local agent="$2"
  (
    sleep 8
    if bridge_tmux_session_exists "$session" 2>/dev/null; then
      # Type the message then send Enter as a separate key event.
      # Single-line nudge — the agent's SESSION-TYPE.md owns the
      # specific question script.
      tmux send-keys -t "$session" '안녕하세요. 처음 시작하는 install이라 onboarding을 진행해주세요.' 2>/dev/null || true
      sleep 0.5
      tmux send-keys -t "$session" Enter 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  disown $! 2>/dev/null || true
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

# Issue #1769 mechanism 2: a setup-freshness check tripped the fresh gate.
# Record its name (for one diagnostic log line per failed check) and whether
# the check is genuinely fresh-requiring — i.e. whether the relaunched Claude
# would NOT pick the corrected artifact up via the re-ensure pass that runs
# later in this same bridge-start process before the engine exec.
#
# All of stop/session-start/prompt/prompt-guard/tool-policy hook status read
# settings.json, which Claude reloads at launch on resume just as on a fresh
# start; their ensure helpers run unconditionally below (not gated on
# INSTALL_PROJECT_SKILL), so a tripped hook check is always re-ensured this
# run → re-ensurable. The CLAUDE.md-guidance and skill-bootstrap checks are
# re-rendered only when INSTALL_PROJECT_SKILL=1 (the normal start/restart
# default); under --skip-project-skill that render is skipped, so the
# corrected artifact would not be in place for the relaunch → fresh-required.
bridge_start_note_fresh_trip() {
  local check_name="$1"
  local fresh_required="${2:-0}"
  FORCE_FRESH_SESSION=1
  FRESH_TRIPPED_CHECKS+=("$check_name")
  if [[ "$fresh_required" == "1" ]]; then
    FRESH_TRIPPED_FRESH_REQUIRED+=("$check_name")
  fi
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
  local foreground_timeout=""
  local log_dir=""
  local logfile="/dev/null"
  local errfile="/dev/null"

  accept_timeout="$(bridge_start_dev_channels_accept_timeout)"
  foreground_timeout="$(bridge_start_dev_channels_claude_foreground_timeout)"
  log_dir="$(bridge_agent_log_dir "$agent")"
  if mkdir -p "$log_dir" 2>/dev/null; then
    logfile="$log_dir/$(date '+%Y%m%d').log"
    errfile="$log_dir/$(date '+%Y%m%d').err.log"
  fi

  echo "[info] controller-side Claude development-channels auto-accept armed for '$session' (foreground=${foreground_timeout}s, accept=${accept_timeout}s)"
  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      accept_timeout="$4"
      foreground_timeout="$5"
      source "$script_dir/bridge-lib.sh"
      if ! bridge_tmux_session_exists "$session"; then
        printf "[%s] [warn] controller auto-accept dev-channels skipped: tmux session=%s already gone\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" >&2
        exit 0
      fi
      # Issue #825: primary trigger is pane-content-text match for the
      # dev-channels picker. The foreground-basename gate has been observed
      # to false-negative on v0.11.0+ live installs (Claude apparently
      # presents the picker from a wrapper whose `comm` does not match
      # claude|claude-*|claude.*) which wedged the watcher indefinitely.
      # We poll BOTH the picker text AND the legacy foreground gate;
      # whichever fires first wins. The picker text (specifically the
      # "WARNING: Loading development channels" + "I am using this for
      # local development" pair detected by
      # bridge_tmux_pane_has_dev_channels_picker) is unique to the Claude
      # dev-channels load path, so its presence alone is sufficient
      # evidence the picker has been drawn — we do not require an
      # additional process-name match on top. The picker-sweep allow-list
      # (scripts/picker-sweep.sh:137-138) does NOT include the dev-channels
      # picker text, so the two watcher surfaces stay disjoint.
      picker_seen=0
      foreground_ready=0
      poll_seconds="${BRIDGE_START_DEV_CHANNELS_PICKER_POLL_SECONDS:-2}"
      [[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll_seconds=2
      start_ts="$(date +%s)"
      while :; do
        if ! bridge_tmux_session_exists "$session"; then
          printf "[%s] [warn] controller auto-accept dev-channels aborted: tmux session=%s ended before picker/foreground (likely plugin-cache or launch failure)\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$session" >&2
          exit 0
        fi
        if bridge_tmux_pane_has_dev_channels_picker "$session"; then
          picker_seen=1
          break
        fi
        if bridge_tmux_pane_foreground_is_claude "$session"; then
          foreground_ready=1
          break
        fi
        elapsed=$(( $(date +%s) - start_ts ))
        if (( elapsed >= foreground_timeout )); then
          printf "[%s] [warn] controller auto-accept dev-channels timeout waiting for picker/claude foreground on session=%s agent=%s after %ss\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent" "$foreground_timeout" >&2
          exit 0
        fi
        sleep "$poll_seconds"
      done
      # Issue #1306: daemon auto-recovery via --no-attach was observed
      # leaving the dev-channels picker hung for 23+ minutes on iso v2
      # agents. The watcher armed and logged "controller-side Claude
      # development-channels auto-accept armed" but the picker key was
      # never sent. The tmux session existed and the picker text was
      # drawn, but the chain of
      # bridge_tmux_wait_for_prompt -> bridge_tmux_claude_advance_blocker
      # -> bridge_tmux_wait_for_claude_foreground carries a foreground
      # process-name gate that false-negatives in the unattended /
      # background-daemon-spawned tmux session shape (the pane_pid
      # comm does not reliably match the claude regex even after the
      # picker is fully drawn). The previous fix (#825) bypassed that
      # gate via env var only on the picker_seen path, but the indirect
      # chain still tripped intermittently because wait_for_prompt
      # own polling iterates bridge_tmux_session_has_prompt AND
      # bridge_tmux_claude_blocker_state again. A transient race
      # between picker text presence and blocker-state detection (e.g.
      # picker drawn, but the 80-line capture window slid past the
      # WARNING line in the brief moment between watcher poll and
      # wait_for_prompt poll) was enough to leave the picker hanging.
      #
      # Root fix (per feedback-root-vs-symptom-framing): drop the
      # foreground/attach gate entirely on the picker-text trigger path
      # and send Enter DIRECTLY to the tmux pane the moment the picker
      # text is observed. The picker text -- WARNING: Loading
      # development channels + I am using this for local development
      # -- is unique to this prompt shape and the cursor glyph is
      # already parked on option 1, so Enter selects it. No process-tree
      # walk, no foreground basename check, no wait_for_prompt
      # indirection; just session-exists + picker-text-detected. This
      # is the only auto-accept invocation contract daemon-auto-recovery
      # (--no-attach) actually needs.
      #
      # The legacy foreground-trigger path is preserved verbatim for
      # callers that reach it (Claude entered the foreground but picker
      # has not been drawn yet). It still routes through
      # bridge_tmux_wait_for_prompt so other blocker states the
      # session may transition through (trust, summary) keep their
      # existing handling.
      if (( picker_seen == 1 )); then
        # Settle delay: capture race with the picker draw cycle. A
        # short pause lets Claude finish painting option 1 before we
        # send. 200ms keeps the unattended-recovery path snappy while
        # still allowing the render to settle.
        sleep 0.2
        # Re-verify session existence; a session that died between
        # picker detection and send (e.g. parent bridge-run.sh crashed
        # on a follow-up plugin-cache error) should not be logged as
        # "completed".
        if bridge_tmux_session_exists "$session" \
           && bridge_tmux_pane_has_dev_channels_picker "$session"; then
          # Direct send — no attach gate, no foreground gate, no
          # wait_for_prompt indirection. bridge_tmux_send_keys_with_timeout
          # wraps tmux send-keys with the daemon-wide 10s watchdog
          # (#265); it does NOT require an attached client.
          if bridge_tmux_send_keys_with_timeout tmux_send_dev_channels_picker_direct \
              -t "$(bridge_tmux_pane_target "$session")" C-m; then
            printf "[%s] [info] controller auto-accept dev-channels completed (picker-text trigger, direct send) on session=%s agent=%s\n" \
              "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent"
            exit 0
          else
            printf "[%s] [warn] controller auto-accept dev-channels direct send failed on session=%s agent=%s; falling back to wait_for_prompt\n" \
              "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent" >&2
          fi
        else
          printf "[%s] [warn] controller auto-accept dev-channels picker cleared between detect and send on session=%s agent=%s; skipping send\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent" >&2
          exit 0
        fi
        # Direct-send fallback path (rare): keep the legacy env-var
        # bypass + wait_for_prompt route in case the direct send
        # itself raises (e.g. tmux IPC failure inside the 10s
        # watchdog). The wait_for_prompt retry loop handles up to 12
        # Enter presses with its own picker re-detection.
        export BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND=0
      fi
      if bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then
        if (( picker_seen == 1 )); then
          printf "[%s] [info] controller auto-accept dev-channels completed (picker-text trigger, wait_for_prompt fallback) on session=%s agent=%s\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent"
        else
          printf "[%s] [info] controller auto-accept dev-channels completed (foreground trigger) on session=%s agent=%s\n" \
            "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent"
        fi
      else
        printf "[%s] [warn] controller auto-accept dev-channels failed/timeout on session=%s agent=%s\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" "$agent" >&2
      fi
    ' -- "$SCRIPT_DIR" "$session" "$agent" "$accept_timeout" "$foreground_timeout"
  ) </dev/null >>"$logfile" 2>>"$errfile" &
}

bridge_start_prepare_agent_log_files() {
  local agent="$1"
  local log_dir=""
  local logfile=""
  local errfile=""

  log_dir="$(bridge_agent_log_dir "$agent")"
  [[ -n "$log_dir" ]] || return 0
  mkdir -p "$log_dir" 2>/dev/null || return 0

  logfile="$log_dir/$(date '+%Y%m%d').log"
  errfile="$log_dir/$(date '+%Y%m%d').err.log"
  touch "$logfile" "$errfile" 2>/dev/null || true
  chmod g+rwx "$log_dir" 2>/dev/null || true
  chmod g+rw "$logfile" "$errfile" 2>/dev/null || true
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
# Issue #1769 mechanism 2: record WHICH setup-freshness check tripped the
# fresh gate so the discard is diagnosable, and classify whether that check
# is re-ensured later in THIS same bridge-start run (so a resumable session
# need not be thrown away — see the gate-downgrade block below).
FRESH_TRIPPED_CHECKS=()
FRESH_TRIPPED_FRESH_REQUIRED=()
SUPPRESS_MISSING_CHANNELS=0
CHANNEL_REASON=""
AGENT_ENV_FILE=""

# workdir existence: for a linux-user isolated agent the agent root
# (`<data-root>/agents/<agent>/`) is `root:ab-agent-<agent>` mode 0750
# and `workdir/` is 2770 — the controller user is not in the agent
# group at process scope, so a plain `[[ -d "$WORK_DIR" ]]` cannot
# traverse the 0750 parent and false-negates even when workdir exists
# (#1028). Probe via the existing sudo-handoff helper for isolated
# agents; non-isolated agents keep the plain controller-side test.
WORK_DIR_PRESENT=0
if bridge_agent_linux_user_isolation_effective "$AGENT"; then
  if bridge_linux_sudo_root test -d "$WORK_DIR" 2>/dev/null; then
    WORK_DIR_PRESENT=1
  fi
elif [[ -d "$WORK_DIR" ]]; then
  WORK_DIR_PRESENT=1
fi

if [[ $WORK_DIR_PRESENT -eq 0 ]]; then
  # Two auto-rebuild paths cover the post-migration "workdir vanished"
  # gap from #714 (item 10 — `patch-dev` static-role with no workdir
  # tree at all). #4 in the per-symptom table:
  #   - DEFAULT_WORK_DIR: legacy default home path. Plain mkdir.
  #   - v2 canonical: $BRIDGE_AGENT_ROOT_V2/<agent>/workdir. Same
  #     identity as the just-resolved $WORK_DIR for static roles, but
  #     under v2 the parent (`<root>/agents/<agent>/`) may be
  #     root-owned, so fall back to bridge_linux_sudo_root.
  # Anything else (operator-supplied --workdir to a dynamic agent,
  # roster-explicit non-default path on a v2-disabled install) keeps
  # the original die behavior: we don't want to silently materialize
  # directories the operator named by mistake.
  #
  # Direct prefix-string comparison against $BRIDGE_AGENT_ROOT_V2 is
  # used instead of re-invoking bridge_agent_workdir() — that helper
  # falls through to BRIDGE_AGENT_WORKDIR[<agent>] (an external path)
  # when v2 is not active, which would cause $WORK_DIR to compare
  # equal to itself and erroneously skip the die branch on v2-disabled
  # installs (codex r2 finding).
  if [[ "$WORK_DIR" == "$DEFAULT_WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
  elif [[ -n "$BRIDGE_AGENT_ROOT_V2" && "$WORK_DIR" == "$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir" ]]; then
    echo "[info] '$AGENT' static workdir 누락, 자동 재생성: $WORK_DIR"
    if ! mkdir -p "$WORK_DIR" 2>/dev/null; then
      # v2 isolated layout: the parent agent root may be root-owned
      # (`<data-root>/agents/<agent>/` mode 0750 root:root) so the
      # controller user cannot mkdir the workdir leaf directly. Reuse
      # the existing sudo-handoff helper from lib/bridge-agents.sh
      # (no new helper introduced — Track B owns sudo-handoff helper
      # surface).
      bridge_linux_sudo_root mkdir -p "$WORK_DIR" || \
        bridge_die "workdir 자동 재생성 실패: $WORK_DIR"
    fi
    # Post-regen re-check: same privilege-aware probe — a plain
    # `[[ ! -d ]]` here false-negates on the isolated 0750 layout and
    # would spuriously bridge_die even though workdir now exists (#1028).
    if bridge_agent_linux_user_isolation_effective "$AGENT"; then
      bridge_linux_sudo_root test -d "$WORK_DIR" 2>/dev/null \
        || bridge_die "workdir 자동 재생성 후에도 존재하지 않음: $WORK_DIR"
    elif [[ ! -d "$WORK_DIR" ]]; then
      bridge_die "workdir 자동 재생성 후에도 존재하지 않음: $WORK_DIR"
    fi
  else
    bridge_die "workdir가 없습니다: $WORK_DIR"
  fi
fi

# Issue #1417 — sync-on-start identity reconciliation. For a managed-project
# agent (workdir != home) `agent create` materializes the HOME identity files
# into the workdir once; a later hand-edit of the HOME copy never propagates,
# so the runtime (which reads workdir-first via bridge_agent_onboarding_state)
# silently ignores the HOME edit and onboarding can stay stuck `pending`. This
# call re-materializes the workdir identity copies FROM HOME at every start —
# but ONLY identity files, ONLY when HOME differs AND is the newer copy, and
# fail-closed (it never clobbers a deliberate workdir runtime value or any
# workdir-anchored watchdog state #1108/#1109, and never aborts the launch).
# No-op in shared mode (workdir == home, single physical copy) and on a
# dry-run. $WORK_DIR is passed as the explicit target so the resolution
# matches what this launch actually uses.
if [[ $DRY_RUN -eq 0 ]] \
    && declare -F bridge_layout_sync_identity_from_home >/dev/null 2>&1; then
  bridge_layout_sync_identity_from_home "$AGENT" "$ENGINE" "$WORK_DIR" || true
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
  # Issue #1769 mechanism 2: each tripped check is recorded by name. The
  # CLAUDE.md-guidance and skill-bootstrap artifacts are only re-rendered
  # when INSTALL_PROJECT_SKILL=1, so they are fresh-required (no re-ensure
  # this run) under --skip-project-skill; the hook-status checks are always
  # re-ensured below regardless of INSTALL_PROJECT_SKILL.
  _fresh_required_setup=$(( INSTALL_PROJECT_SKILL == 1 ? 0 : 1 ))
  if bridge_project_claude_guidance_needed "$WORK_DIR"; then
    bridge_start_note_fresh_trip claude_guidance_needed "$_fresh_required_setup"
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    # Issue #1151: thread $AGENT so v2-isolation guard polarity fix can
    # resolve roster os_user.
    bridge_ensure_project_claude_guidance "$WORK_DIR" "$AGENT" >/dev/null 2>&1 || true
  fi
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    bridge_start_note_fresh_trip skill_bootstrap_needed "$_fresh_required_setup"
  fi
  if ! bridge_claude_stop_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    bridge_start_note_fresh_trip stop_hook_status 0
  fi
  if ! bridge_claude_session_start_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    bridge_start_note_fresh_trip session_start_hook_status 0
  fi
  if ! bridge_claude_prompt_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    bridge_start_note_fresh_trip prompt_hook_status 0
  fi
  if ! bridge_claude_prompt_guard_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    bridge_start_note_fresh_trip prompt_guard_hook_status 0
  fi
  if ! bridge_claude_tool_policy_hooks_status "$WORK_DIR" >/dev/null 2>&1; then
    bridge_start_note_fresh_trip tool_policy_hooks_status 0
  fi
  unset _fresh_required_setup
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    # Issue #1155: thread $AGENT (3rd arg) so the v2-isolation guard in
    # bridge_bootstrap_project_skill can resolve roster os_user. Without
    # this thread-through, the helper's `bridge_write_managed_markdown`
    # call would `mkdir -p` / `mv` under the isolated-UID-owned workdir
    # and surface Permission denied to operator stdout right before the
    # tmux session dies (the call here is unredirected — see #1155).
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR" "$AGENT"; then
      bridge_warn "Claude bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  bridge_bootstrap_claude_shared_skills "$AGENT" "$WORK_DIR" || true
  # Issue #1073: defensive seed of the per-agent CLAUDE_CONFIG_DIR's
  # `.claude.json` for agents created before this seed was added to the
  # `agent create` flow. Idempotent (`setdefault` semantics on every key)
  # and a no-op for engines other than Claude. Without this, an existing
  # fresh channel agent that was created on a prior bridge version would
  # still hit the theme-picker / trust-dialog restart loop on its next
  # start until the operator manually ran `auth claude-token sync`.
  bridge_ensure_claude_first_run_config "$AGENT" "$WORK_DIR" >/dev/null 2>&1 || true
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
  # Ensure HUD stdin tap is in place before the sudo-wrap so that linux-user
  # isolated agents get their isolated-home settings rendered from controller
  # context. bridge_ensure_hud_usage_tap is a no-op when no HUD statusLine is
  # configured or when the tap is already present.
  bridge_ensure_hud_usage_tap "$WORK_DIR" "$AGENT_LAUNCH_CMD" "$AGENT" >/dev/null 2>&1 || true
  if ! bridge_disable_claude_webhook_channel "$AGENT" "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude backlog webhook channel cleanup skipped: $WORK_DIR"
  fi
elif [[ "$ENGINE" == "codex" && $SAFE_MODE -eq 0 ]]; then
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    # Codex resume semantics are unchanged by #1769 mechanism 2 (the
    # resume-downgrade below is Claude-only); record the trip name purely
    # for the diagnostic log line.
    bridge_start_note_fresh_trip skill_bootstrap_needed 1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    # Issue #1155: thread $AGENT (3rd arg) for the v2-isolation guard.
    # Same rationale as the Claude branch above — unredirected here, so
    # any controller-side mkdir/mv failure would reach operator stdout.
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR" "$AGENT"; then
      bridge_warn "Codex bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  if ! bridge_ensure_codex_hooks >/dev/null; then
    bridge_die "Codex hook 설정에 실패했습니다: $WORK_DIR"
  fi
fi

if [[ $FORCE_FRESH_SESSION -eq 1 ]]; then
  # Issue #1769 mechanism 2: the setup-freshness gate used to silently drop a
  # perfectly resumable session whenever ANY check tripped — the discard was
  # invisible on normal restart flows (the visible warning below only fires
  # when the operator explicitly passed --continue) and it defeated the #981
  # restart re-inject fleet-wide after every controller-side settings
  # re-render. Two changes here, both additive:
  #
  #   1. Diagnosability: log one line per tripped check, naming the check —
  #      no longer silent, even on normal restarts.
  #   2. Downgrade on resumable restart: for Claude, when a resume id is
  #      resolvable AND every tripped check is re-ensured later in THIS run
  #      (i.e. none is fresh-required), keep the resume. The ensure pass that
  #      already ran above (and runs again for the engine) re-renders the
  #      stale CLAUDE.md / skills / hooks before the engine exec, and a
  #      resumed Claude reloads settings.json at launch exactly like a fresh
  #      one — so the fresh launch bought nothing the re-ensure didn't.
  #
  # Force-fresh is preserved (unchanged behavior) when there is no resumable
  # id, when a genuinely fresh-required check tripped (e.g. CLAUDE.md guidance
  # / skill bootstrap under --skip-project-skill, where the re-render is
  # skipped this run), or for Codex.
  _fresh_resumable_id=""
  if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 && "${CONTINUE_MODE}" == "1" ]]; then
    _fresh_resumable_id="$(bridge_claude_resume_session_id_for_agent "$AGENT" 2>/dev/null || true)"
  fi
  _fresh_required_count=${#FRESH_TRIPPED_FRESH_REQUIRED[@]}
  if [[ -n "$_fresh_resumable_id" && $_fresh_required_count -eq 0 ]]; then
    # Downgrade: keep the resumable session; the re-ensure pass fixed setup.
    for _check in "${FRESH_TRIPPED_CHECKS[@]}"; do
      bridge_warn "setup-freshness check '$_check' tripped on restart but is re-ensured this run; resuming session_id=${_fresh_resumable_id} (was: silent fresh discard, #1769)."
    done
    FORCE_FRESH_SESSION=0
    if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
      EFFECTIVE_CONTINUE_MODE="$CONTINUE_MODE"
    fi
  else
    # Fresh launch (preserved behavior) — but now logged, naming each check.
    for _check in "${FRESH_TRIPPED_CHECKS[@]}"; do
      _fresh_req_note="re-ensurable"
      for _fr in "${FRESH_TRIPPED_FRESH_REQUIRED[@]+"${FRESH_TRIPPED_FRESH_REQUIRED[@]}"}"; do
        [[ "$_fr" == "$_check" ]] && _fresh_req_note="fresh-required"
      done
      bridge_warn "setup-freshness check '$_check' ($_fresh_req_note) forced a fresh session (#1769 diagnostic)."
    done
    unset _fresh_req_note _fr
    if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "1" ]]; then
      bridge_warn "Bridge project setup changed or was missing. Forcing a fresh session so CLAUDE.md, skills, and hooks are loaded."
    fi
    EFFECTIVE_CONTINUE_MODE=0
  fi
  unset _fresh_resumable_id _fresh_required_count _check
elif [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  EFFECTIVE_CONTINUE_MODE="$CONTINUE_MODE"
fi

# Issue #268 + #1334 L4 (v0.14.5-beta5-2 Lane ξ): warn the operator when this
# launch is effectively fresh (CONTINUE_MODE=0 — either operator-supplied
# --no-continue OR controller-derived FORCE_FRESH_SESSION) but a stale
# resume id is still persisted. The persisted id is NOT cleared by a
# fresh-launch — only `agb agent forget-session <agent>` clears it
# permanently — so the next normal restart will pick the bad id back up
# without operator visibility.
#
# Order contract (must match bridge-run.sh:167-175 / #1334 L4): both
# callers evaluate EFFECTIVE/explicit "continue=0" → persisted-id read →
# warn-and-fall-through, in that sequence. The persisted id is never
# clobbered here; FORCE_FRESH_SESSION only steers the engine launch line
# (via --no-continue injected into SESSION_CMD), it does NOT mutate the
# session-id persist file. That separation keeps the recovery path
# explicit: operator must run `agb agent forget-session` to permanently
# discard a known-bad id, and a fresh-for-this-run launch is a
# non-destructive one-shot.
#
# Pre-#1334 bug: this branch checked `CONTINUE_EXPLICIT==1 && CONTINUE_MODE==0`,
# so a controller-derived FORCE_FRESH (operator did not pass --no-continue,
# but bridge_project_claude_guidance_needed / hook-status probes set
# FORCE_FRESH_SESSION=1) silently skipped the warn at the bridge-start
# layer — even though bridge-run.sh:167-175 DID warn after the injected
# --no-continue made CONTINUE_EXPLICIT=1 there. Operators saw a single
# bridge-run warning with no upstream context. Switching the gate to
# EFFECTIVE_CONTINUE_MODE makes the bridge-start warn fire whenever the
# effective state is "launch fresh + persisted id remains", matching the
# bridge-run.sh end-state.
if [[ "${EFFECTIVE_CONTINUE_MODE:-1}" == "0" ]]; then
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

# Issue #1190/#1191 (beta22, codex r1 — 2026-05-25): idempotent start-time
# hook for bundled plugins (plugins/teams, plugins/ms365, …) that ship a
# `package.json`. The helper
# `bridge_provision_bundled_plugins_node_modules` (lib/bridge-channels.sh)
# was previously invoked only from `bridge-setup.sh run_teams()` and
# `bridge-upgrade.sh` — meaning a fresh install path that never ran setup
# or upgrade (e.g. operator added a plugin: channel via `agent create`
# alone) reaches first launch with missing `node_modules`, and the MCP
# server later fails with "Cannot find module ...".
#
# Runs BEFORE the isolation prep + bridge-run.sh exec so the shared
# `plugins/<id>/node_modules` tree is in place by the time the iso-side
# dev-plugin-cache copies it into /home/<iso>/.claude/plugins/cache/<…>.
#
# Idempotent: the helper's staleness check at lib/bridge-channels.sh:848-863
# skips work when the existing node_modules is newer than both package.json
# and bun.lock. The chmod widen always runs so iso UIDs can read.
#
# Fail-closed when an agent declares a plugin: channel that maps to a
# bundled plugin (plugins/<id>) which has package.json AND bun is
# unavailable: per brief, "don't let MCP startup fail later with
# module-not-found". Operator guidance: install bun, or remove the
# bundled plugin channel.
#
# Best-effort otherwise: a `bun install` failure inside the helper still
# warns + returns nonzero, but we keep launching (the agent may still be
# useful with degraded plugin functionality, and the operator can
# recover via `agb setup teams`).
#
# Skips entirely when no plugin: channels are declared.
if [[ $DRY_RUN -eq 0 ]]; then
  _bundled_chan_csv="$(bridge_agent_channels_csv "$AGENT" 2>/dev/null || true)"
  if [[ "$_bundled_chan_csv" == *plugin:* ]]; then
    # Determine which bundled plugins the agent's channels actually
    # require (have a package.json on disk). teams is covered by the
    # teams-specific helper invoked from setup; ms365 / future bundled
    # plugins go through bridge_provision_bundled_plugins_node_modules.
    _bundled_required=""
    _IFS_save="$IFS"
    IFS=','
    for _tok in $_bundled_chan_csv; do
      _tok="${_tok// /}"
      [[ "$_tok" == plugin:*@agent-bridge ]] || continue
      _name="${_tok#plugin:}"
      _name="${_name%@agent-bridge}"
      # Only the bundled plugin types that actually have package.json
      # under $BRIDGE_SCRIPT_DIR/plugins/ count toward "required".
      if [[ -f "$BRIDGE_SCRIPT_DIR/plugins/$_name/package.json" ]]; then
        _bundled_required="${_bundled_required:+$_bundled_required,}$_name"
      fi
    done
    IFS="$_IFS_save"
    unset _IFS_save _tok _name

    if [[ -n "$_bundled_required" ]]; then
      # bun preflight — fail closed for channel-required bundled plugins
      # when bun is missing. The agent's declared channels would later
      # crash the MCP servers with module-not-found if we let start
      # proceed without node_modules.
      _bun_bin=""
      if declare -F bridge_resolve_bun_executable >/dev/null 2>&1; then
        _bun_bin="$(bridge_resolve_bun_executable 2>/dev/null || true)"
      fi
      if [[ -z "$_bun_bin" ]]; then
        bridge_audit_log state bundled_plugin_runtime_missing_bun "$AGENT" \
          --field channels="$_bundled_chan_csv" \
          --field required_bundled="$_bundled_required" >/dev/null 2>&1 || true
        bridge_die "agent '$AGENT' declares bundled plugin channels ($_bundled_required) that require a node_modules tree under \$BRIDGE_SCRIPT_DIR/plugins/, but \`bun\` is not on PATH. Install bun (\`agb setup teams\` provisions it) or remove the bundled plugin channel(s) from this agent."
      fi
      # Run BOTH provisioners. The general helper SKIPS the `teams`
      # plugin (covered by the teams-specific helper at
      # lib/bridge-channels.sh:580), so we must invoke that separately
      # when the agent declares plugin:teams@agent-bridge. Order matters
      # only for log clarity — the two helpers operate on disjoint
      # plugin trees.
      case ",$_bundled_required," in
        *,teams,*)
          if declare -F bridge_install_teams_plugin_node_modules >/dev/null 2>&1; then
            bridge_install_teams_plugin_node_modules 0 "$_bun_bin" || \
              bridge_warn "teams plugin node_modules provisioning returned nonzero — see warns above; the agent will still launch but Teams MCP may fail until the operator runs \`agb setup teams\`."
          fi
          ;;
      esac
      if declare -F bridge_provision_bundled_plugins_node_modules >/dev/null 2>&1; then
        bridge_provision_bundled_plugins_node_modules 0 "$_bun_bin" || \
          bridge_warn "bundled plugin node_modules provisioning returned nonzero — see warns above; the agent will still launch but MCP for one or more bundled plugins may fail until the operator runs \`agb setup teams\`."
      fi
      unset _bun_bin
    fi
    unset _bundled_required
  fi
  unset _bundled_chan_csv
fi

if bridge_isolation_disabled_by_env; then
  bridge_warn "BRIDGE_DISABLE_ISOLATION=1 — skipping v2 isolation prep for '$AGENT' (security boundary disabled, agent will run as controller UID without sudo wrap or per-agent env file)"
elif bridge_agent_linux_user_isolation_effective "$AGENT"; then
  AGENT_ENV_FILE="$(bridge_agent_linux_env_file "$AGENT")"
  bridge_write_linux_agent_env_file "$AGENT" "$AGENT_ENV_FILE"

  # L1-D (beta21, codex r1 spec / PR #1196): re-derive the per-UID plugin
  # catalog on every start/restart so an existing iso agent picks up
  # marketplaces that were added AFTER the agent was created (via `agb
  # plugins seed`, manual marketplace add, etc.). Without this, the
  # per-UID `known_marketplaces.json` is only written at agent-create /
  # reapply via `bridge_linux_prepare_agent_isolation` (lib/bridge-agents.sh:4156)
  # and at `agb plugins seed` via the D2 merge helper (bridge-plugins.sh,
  # PR #1189) — operator-side drift (e.g. iso HOME catalog reset, new
  # external marketplace added to roster but no agent-recreate) leaves
  # the iso UID with a stale catalog and dev-plugin-cache reports
  # `marketplace-mismatch:<marketplace>` for every plugin that lives in
  # the missing marketplace.
  #
  # The CANONICAL writer is `bridge_linux_share_plugin_catalog`
  # (lib/bridge-agents.sh:2512+) — it re-derives the filtered per-UID
  # catalog + installed_plugins.json + marketplace symlinks from the
  # shared plugin cache and the agent's declared channels/plugins each
  # time it runs. Stale or manually-edited per-UID state is therefore
  # overwritten with the canonical state on every start, closing the
  # "operator drifted existing agent" failure mode that D2 (seed-side
  # merge) cannot reach.
  #
  # SUPPRESS_MISSING_CHANNELS=1 (line 568 above): the suppress-aware
  # launcher is used when the agent is mid-onboarding and its channel
  # runtime is incomplete. Calling the share helper here in that mode
  # could turn a suppressed-channel recovery start into a NEW hard
  # failure if the shared plugin cache is also absent (helper
  # `bridge_die`s on a populated channel list but no cache). Skip the
  # share call in that mode (codex r1 option (a)) — the agent's plugin
  # channels are suppressed for launch anyway, so the per-UID catalog
  # is not consulted in the launch path. The next non-suppressed start
  # re-runs this helper and brings the catalog back to canonical.
  #
  # For normal starts that DO need plugin channels but lack the shared
  # cache, the helper fails loud with its existing "run `agb plugins
  # seed`" guidance — no silent no-op.
  if [[ "$SUPPRESS_MISSING_CHANNELS" -eq 1 ]]; then
    bridge_warn "BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 — skipping per-UID plugin catalog re-derivation for '$AGENT' (suppress-aware launch; the next non-suppressed start re-derives)"
  else
    _l1d_os_user="$(bridge_agent_os_user "$AGENT" 2>/dev/null || true)"
    if [[ -z "$_l1d_os_user" ]]; then
      bridge_warn "bridge-start.sh L1-D: cannot resolve os_user for agent '$AGENT' — skipping per-UID plugin catalog re-derivation (the agent's plugin channels may report marketplace-mismatch on this launch; recover via \`agent-bridge isolate $AGENT\` to repair)"
    else
      _l1d_user_home="$(bridge_agent_linux_user_home "$_l1d_os_user")"
      _l1d_controller_user="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
      if [[ -z "$_l1d_controller_user" ]]; then
        bridge_warn "bridge-start.sh L1-D: cannot resolve controller user for agent '$AGENT' — skipping per-UID plugin catalog re-derivation"
      elif ! bridge_linux_share_plugin_catalog \
              "$_l1d_os_user" "$_l1d_user_home" "$_l1d_controller_user" "$AGENT"; then
        # Helper fails loud (bridge_die) on a populated channel list +
        # absent shared cache; that path never returns here. Other
        # failures (chown / chmod / symlink) are non-fatal for the
        # start path — the agent may still launch with a stale (but
        # non-empty) per-UID catalog from a prior create/seed pass.
        # Surface a warn so the operator sees the drift.
        bridge_warn "bridge-start.sh L1-D: per-UID plugin catalog re-derivation FAILED for agent '$AGENT' (start continues with the prior catalog; expect marketplace-mismatch reports if a marketplace was added since the last agent-create / seed)"
      fi
      unset _l1d_user_home _l1d_controller_user
    fi
    unset _l1d_os_user
  fi
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
# Issue #1158 r2: inline BRIDGE_CONTROLLER_UID into the SESSION_CMD env
# prefix so it is available at bridge-lib.sh source time inside the
# isolated child (i.e. when bridge-marker-bootstrap.sh validates the
# layout marker). The per-agent env file at $BRIDGE_AGENT_ENV_FILE also
# carries this value (lib/bridge-agents.sh:3461-3462), but that file is
# only sourced LATER inside bridge_load_roster — AFTER marker
# validation has already run. Without this inline prefix the marker
# validator sees an empty exported controller UID and rejects a
# controller-owned marker under sudo -u <agent_user>, killing v2
# linux-user isolated starts (#1158). Belt-and-suspenders: the variable
# is also in bridge_agent_preserved_env_vars() so any future controller
# path that exports it flows through too.
if [[ -z "${BRIDGE_CONTROLLER_UID:-}" ]]; then
  SESSION_CMD="BRIDGE_CONTROLLER_UID=$(printf '%q' "$(id -u)") ${SESSION_CMD}"
else
  SESSION_CMD="BRIDGE_CONTROLLER_UID=$(printf '%q' "$BRIDGE_CONTROLLER_UID") ${SESSION_CMD}"
fi
# Issue #1330 M7 (v0.14.5-beta5-2 Lane ξ): inline BRIDGE_AGENT_ID into the
# SESSION_CMD env prefix so child processes — Claude/Codex and any MCP
# servers they spawn (plugins/teams, plugins/ms365, …) — see a populated
# BRIDGE_AGENT_ID from the earliest moment.
#
# Why belt-and-suspenders: BRIDGE_AGENT_ID is set THREE other places:
#   1. bridge-run.sh:140 (early — before bridge_load_roster reads the
#      scoped roster snapshot, see #116).
#   2. bridge-run.sh:350 (late — immediately before the engine exec).
#   3. The per-agent env file at $BRIDGE_AGENT_ENV_FILE
#      (lib/bridge-agents.sh:3559-3560), which is sourced inside
#      bridge_load_roster.
# None of these paths runs BEFORE the SESSION_CMD env prefix evaluates,
# so MCP servers spawned by an engine path that bypasses bridge-run.sh
# (or by an early hook like prompt_timestamp.py that reads BRIDGE_AGENT_ID
# at source time) would see a blank scalar. The Teams MCP server's
# activity-index write at plugins/teams/server.ts:2314 falls back to
# "" → silent skip → PreCompact channel-route lookup later misses the
# session-id mapping. Inlining here closes the gap at the env-prefix
# level so every downstream consumer (including any future bare engine
# launch that does not go through bridge-run.sh) inherits the populated
# value.
#
# Quoting via printf '%q' keeps agent ids with whitespace / shell
# metacharacters safe across the bash -lc boundary the sudo wrap uses
# at bridge-start.sh:891. The agent id is also slug-validated at create
# time (lib/bridge-agents.sh:bridge_validate_agent_id), so this is
# defense-in-depth for the historical record (no current id violates
# the slug rule).
SESSION_CMD="BRIDGE_AGENT_ID=$(printf '%q' "$AGENT") ${SESSION_CMD}"
# Issue #1118: resolve the engine binary's absolute path on the controller
# and propagate it into the sudo'd child via the SESSION_CMD env prefix.
# Without this, a v2 linux-user-isolated agent's `bash -lc "claude ..."`
# child dies with `claude: command not found` because the controller's
# per-user install (typically `~/.local/bin/claude`) is not on the service
# user's PATH. bridge-run.sh rewrites the leading `claude`/`codex` token in
# LAUNCH_CMD to this absolute path before exec, so the lookup never depends
# on the service user's PATH. The variable is empty (and the rewrite a
# no-op) when the engine binary cannot be resolved on the controller —
# falling back to the legacy bare-name behavior so a hand-installed engine
# at a non-default location is no worse off than today.
ENGINE_BIN_RESOLVED=""
if ENGINE_BIN_RESOLVED="$(bridge_resolve_engine_binary "$ENGINE")"; then
  SESSION_CMD="BRIDGE_ENGINE_BIN=$(printf '%q' "$ENGINE_BIN_RESOLVED") ${SESSION_CMD}"
fi
if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
  SESSION_CMD="BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 ${SESSION_CMD}"
fi
if bridge_start_should_controller_accept_dev_channels "$AGENT" "$SUPPRESS_MISSING_CHANNELS"; then
  CONTROLLER_DEV_CHANNELS_ACCEPT=1
  SESSION_CMD="BRIDGE_CONTROLLER_DEV_CHANNELS_ACCEPT=1 ${SESSION_CMD}"
fi
# Issue #1639: signal the launched bridge-run.sh loop whether this start is an
# AUTO-restart (daemon / upgrade / watchdog / `bridge-agent.sh restart` without
# --attach) versus an operator-driven interactive launch/attach. ATTACH defaults
# to 0 and only flips to 1 when the operator passes --attach (interactive
# `agent-bridge start`/`agent restart --attach`); every daemon/upgrade restart
# path invokes bridge-start.sh without --attach, so ATTACH==0 is the clean
# auto-restart discriminator. bridge-run.sh uses BRIDGE_AUTO_RESTART_WAKE to
# inject a one-time first-turn wake into the new Claude session so queued/blocked
# work does not stall on a session that opened idle. NOT set on an interactive
# launch — the operator is already there to type the first message.
if [[ $ATTACH -eq 0 ]]; then
  SESSION_CMD="BRIDGE_AUTO_RESTART_WAKE=1 ${SESSION_CMD}"
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
  # L1-D Part A (beta22, #1196 sequel — codex r1 root-cause re-diagnosis,
  # 2026-05-25): when the agent declares plugin: channels, the runner
  # binds dev-plugin-cache to /home/<iso>/.claude/plugins via the iso
  # HOME resolved by bridge-run.sh. If sudo-wrap is unavailable here, the
  # SESSION_CMD continues to run as the controller UID but
  # bridge-run.sh's `BRIDGE_CLAUDE_CONFIG_DIR` resolution will still point
  # at the iso UID's HOME — so a controller-side dev-plugin-cache write
  # tree-walks into root-owned /home/<iso>/.claude/plugins and trips
  # EPERM on os.rename. That is exactly the L1-D symptom (patch agent
  # report 2026-05-24): plugin-channel iso agent first-start, no
  # operator chmod/sudo, wedges silently on EPERM. The legacy fallback
  # path swallowed the actual blocker into a warn and let bridge-run.sh
  # exec the controller into the iso HOME tree.
  #
  # Fail closed BEFORE the launch exec when plugin channels are declared.
  # For non-plugin channel agents (or no channels at all) the legacy
  # warn+fall-through path is preserved — shared-mode launch is harmless
  # if no controller process targets the iso HOME plugin tree.
  _l1d_chan_csv="$(bridge_agent_channels_csv "$AGENT" 2>/dev/null || true)"
  if [[ "$_l1d_chan_csv" == *plugin:* ]]; then
    bridge_audit_log state linux_user_sudo_unavailable_plugin_channels_fail_closed "$AGENT" \
      --field os_user="$SUDO_WRAP_OS_USER" \
      --field reason="$SUDO_WRAP_FALLBACK_REASON" \
      --field channels="$_l1d_chan_csv" >/dev/null 2>&1 || true
    unset _l1d_chan_csv
    # beta23 Option A: removed remediation option (c) "use shared-mode
    # isolation (BRIDGE_DISABLE_ISOLATION=1)". The Option A contract
    # rejects shared-mode as a recovery surface (it disables the
    # security boundary). The only supported recovery is provisioning
    # passwordless sudo for the iso UID (option a) or removing the
    # plugin: channels declaration (option b).
    bridge_die "linux-user isolation for '$AGENT' has plugin: channels but UID switch is unavailable: $SUDO_WRAP_FALLBACK_REASON. Continuing as the controller UID would point dev-plugin-cache at /home/<iso>/.claude/plugins and trip EPERM on os.rename (L1-D root cause, codex r1 2026-05-25). Choose ONE of: (a) enable passwordless sudo for the iso UID — run \`agent-bridge isolate $AGENT --install-sudoers\` (Linux); (b) remove plugin: channels from this agent and re-run \`agent create\`."
  fi
  unset _l1d_chan_csv
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
  # Issue #1060 D2: surface the identity source (layer 2) alongside the
  # workspace (layer 3) so dry-run and `agent show` report the same
  # three-layer model. `workdir` is the cwd the runtime launches in;
  # `agent_home` is the authored canonical identity tree. On a v2 install
  # the two diverge — before #1060 dry-run only printed `workdir`.
  if declare -F bridge_layout_agent_home >/dev/null 2>&1; then
    echo "agent_home=$(bridge_layout_agent_home "$AGENT")"
  fi
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
# Issue #1353 (v0.15.0-beta5-2 Track A) — clear setup-pending grace
# marker. By the time we reach this point we have passed the channel-
# plugin preflight (line 1027-1033) — so the channel validator has
# accepted whatever the agent has set up so far, and the grace window
# is no longer needed. An explicit operator `agent start` is also a
# legitimate exit from the grace window: the operator has decided the
# agent is ready, and any subsequent auto-start from the daemon should
# use the normal (non-silent) backoff path on validator-miss.
bridge_agent_clear_setup_pending "$AGENT" 2>/dev/null || true
bridge_start_prepare_agent_log_files "$AGENT"

# Refresh the launch window so a new session id can be detected for this run.
# shellcheck disable=SC2034
BRIDGE_AGENT_CREATED_AT["$AGENT"]="$(date +%s)"
bridge_persist_agent_state "$AGENT"

_bridge_start_new_session_err="$(mktemp 2>/dev/null || printf '/tmp/agb-newsession-err.%s' "$$")"
if ! tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$SESSION_CMD" 2>"$_bridge_start_new_session_err"; then
  # Race: the early `bridge_tmux_session_exists` check at the top of the
  # script may not have caught a daemon-spawned session that landed in
  # the gap. tmux emits `duplicate session: <name>` on stderr — that's
  # cosmetic noise, not a real failure. Treat existing-session as OK,
  # everything else as a real failure surface the captured stderr.
  if bridge_tmux_session_exists "$SESSION" 2>/dev/null; then
    if grep -q 'duplicate session' "$_bridge_start_new_session_err" 2>/dev/null; then
      printf '[info] tmux session %s already exists (race with daemon spawn) — proceeding with attached attach\n' "$SESSION"
    fi
  else
    printf '[error] tmux new-session failed for %s:\n' "$SESSION" >&2
    cat "$_bridge_start_new_session_err" >&2 2>/dev/null || true
    rm -f "$_bridge_start_new_session_err"
    exit 1
  fi
fi
rm -f "$_bridge_start_new_session_err"
unset _bridge_start_new_session_err
bridge_tmux_bootstrap_session_options "$SESSION"
if [[ "$ENGINE" == "claude" ]]; then
  bridge_tmux_prepare_claude_session "$SESSION" 8 >/dev/null 2>&1 || true
  if [[ $CONTROLLER_DEV_CHANNELS_ACCEPT -eq 1 ]]; then
    bridge_start_schedule_dev_channels_accept "$SESSION" "$AGENT"
  fi
  # Fresh-install onboarding nudge: SESSION-TYPE.md's first-session
  # checklist for admin agents triggers "when the first user message
  # arrives" — but on a brand-new install no user message has been
  # typed yet, so the agent sits idle at the prompt waiting. Auto-send
  # a one-line nudge so onboarding doesn't require the operator to
  # type something first. Discovered during E2E test on Ubuntu 24.04
  # VM (2026-05-16).
  #
  # Run BEFORE bridge_agent_mark_idle_now: the idle-marker writer can
  # fail under set -e (e.g., ensure_matrix_path warns on a non-isolated
  # state-agent-dir row), causing bridge-start.sh to exit before
  # reaching the nudge. The nudge spawn is itself async + heavily
  # guarded against errors.
  if bridge_start_should_send_onboarding_nudge "$AGENT"; then
    bridge_start_send_onboarding_nudge_async "$SESSION" "$AGENT" || true
  fi
  bridge_agent_mark_idle_now "$AGENT" || true
fi
if [[ -z "$(bridge_agent_session_id "$AGENT")" ]]; then
  # Issue #1248 Lane A3 r2 (codex r1 BLOCKING): drop the
  # `2>&1 ... || true` swallow. `bridge_refresh_agent_session_id`
  # `bridge_die`s on persist-write failure (`state_dir_write_failed:
  # session_id`); `bridge_die` calls `exit 1`, which the `|| true` cannot
  # intercept — so the only practical effect of the swallow was to redirect
  # the structured stderr reason and the `[session-id]` success breadcrumb
  # to /dev/null while bridge-start.sh died silently. Let stderr through
  # so the operator sees the structured reason on failure and the
  # session_id capture breadcrumb on success. Stdout (the captured id)
  # is still suppressed because nothing here consumes it.
  #
  # BUT under `set -euo pipefail` (top of this script) a benign detect-empty
  # `return 1` from bridge_refresh_agent_session_id aborts bridge-start.sh,
  # which the restart helper treats as launch-failed and ROLLS BACK — killing
  # a perfectly healthy session that simply had not written its session
  # artifact within the 12×0.25s detection window yet (e.g. a slower Claude
  # CLI `--continue` boot with plugins/MCP). detect-empty is explicitly "a
  # safety-net visibility hook, not an error" (see the tail comment in
  # bridge_refresh_agent_session_id); the daemon backfills the id on its next
  # sync. Re-add `|| true` so the empty return is non-fatal. This does NOT
  # mask bridge_die persist-failures (those `exit 1` directly, which `|| true`
  # cannot intercept) and does NOT redirect stderr, so the #1248 visibility
  # intent is fully preserved.
  bridge_refresh_agent_session_id "$AGENT" 12 0.25 >/dev/null || true
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
