#!/usr/bin/env bash
# scripts/picker-sweep.sh — auto-unstick Claude Code interactive pickers.
#
# Claude Code occasionally stops on an interactive picker (rate-limit options,
# resume-from-summary, etc.) waiting for a human keypress. For long-running
# tmux-managed agents that nobody is watching, this freezes the session
# indefinitely. This script scans every tmux session, detects a picker that
# matches a closed pattern allow-list, and presses Enter on the default option.
#
# Usage (essential cron; cron registration is unconditional as of #833, so a
# fresh `bridge-init` produces a working sweep on both server and dev installs.
# The runtime default-skip on host_profile=dev applies only to manual runs that
# do not set BRIDGE_PICKER_SWEEP_ENABLED — the auto-registered cron payload
# always sets it, so cron-fired runs execute regardless of profile.
# Explicit BRIDGE_PICKER_SWEEP_ENABLED=0 always wins):
#
#   *) On every fresh install, `bridge-init.sh` auto-registers a
#      `*/10 * * * *` bridge-native cron via
#      `lib/bridge-init-default-crons.sh::bridge_init_register_default_picker_sweep`.
#      Operators do not need to register it manually. To disable on a given
#      install, run `agb cron update picker-sweep --disable` after init.
#   *) Explicit override: `BRIDGE_PICKER_SWEEP_ENABLED=0` in the environment
#      that invokes the script (or in the cron payload) forces the
#      explicit-opt-out path. `BRIDGE_PICKER_SWEEP_ENABLED=1` forces the
#      enabled path even on host_profile=dev (the auto-registered cron
#      payload sets this).
#   *) Set BRIDGE_PICKER_SWEEP_SELF to the agent name running this cron, so
#      its own tmux pane is skipped (false-positives from talking ABOUT a
#      picker in a doc/PR/log are the dominant failure mode).
#   *) Optionally set BRIDGE_PICKER_SWEEP_NOTIFY to an admin agent ID. If set,
#      the script enqueues a queue task summarising auto-unstick events. If
#      empty, the script logs only.
#
# OS crontab example (recommended — fully bypasses claude/codex). Note the
# entire entry must be on ONE physical line; crontab does not honor shell
# backslash continuation:
#
#   */10 * * * * BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=admin BRIDGE_PICKER_SWEEP_NOTIFY=admin bash /full/path/.agent-bridge/scripts/picker-sweep.sh >> /full/path/.agent-bridge/logs/picker-sweep.log 2>&1
#
# See OPERATIONS.md "picker-sweep" for the bridge-native cron variant and the
# trade-offs (self-recursion risk, future #663 shell-payload mode).
#
# Test seams: this script reads four wrapper-function names from the
# environment so the smoke can replace tmux/queue calls with fixtures without
# patching the script. See `_psw_run_*` calls below.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory and BRIDGE_HOME so the script works from any cwd.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# scripts/ lives directly under BRIDGE_HOME by convention.
_PICKER_SWEEP_BRIDGE_HOME_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_HOME="${BRIDGE_HOME:-$_PICKER_SWEEP_BRIDGE_HOME_DEFAULT}"

LOG="${BRIDGE_PICKER_SWEEP_LOG:-$BRIDGE_HOME/logs/picker-sweep.log}"
mkdir -p "$(dirname "$LOG")"

_psw_now() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

_psw_log() {
    printf '[%s] %s\n' "$(_psw_now)" "$*" >> "$LOG"
}

# ---------------------------------------------------------------------------
# Opt-in gate. Cron registration is unconditional as of #833, and the auto-
# registered cron payload always sets `BRIDGE_PICKER_SWEEP_ENABLED=1` — so
# cron-fired runs execute on both server and dev installs. The runtime gates
# below apply only to MANUAL invocations (operator running this script by
# hand outside the cron payload):
#
#   1. `BRIDGE_PICKER_SWEEP_ENABLED=0` — explicit operator opt-out, wins
#      against any host_profile signal.
#   2. `host_profile=dev` — when the env value is unset, a dev install
#      default-skips a manual run. The operator can set
#      `BRIDGE_PICKER_SWEEP_ENABLED=1` on a dev host to override; the
#      auto-registered cron payload already does this.
#
# Order matters: explicit env wins over host_profile.
# ---------------------------------------------------------------------------

# host_profile=dev opt-out — only consulted when BRIDGE_PICKER_SWEEP_ENABLED is
# unset. Sourcing lib/bridge-host-profile.sh gives us `bridge_host_profile_is_dev`,
# which reads $BRIDGE_HOME/state/install/host-profile.json directly without
# pulling in the full bridge lib chain.
if [[ -z "${BRIDGE_PICKER_SWEEP_ENABLED:-}" ]]; then
    if [[ -r "$BRIDGE_HOME/lib/bridge-host-profile.sh" ]]; then
        # shellcheck source=/dev/null
        source "$BRIDGE_HOME/lib/bridge-host-profile.sh"
        if bridge_host_profile_is_dev; then
            _psw_log "host_profile=dev — picker-sweep default-skipped (set BRIDGE_PICKER_SWEEP_ENABLED=1 to override)"
            printf '[picker-sweep] host_profile=dev — set BRIDGE_PICKER_SWEEP_ENABLED=1 to enable per-feature (see OPERATIONS.md). The cron payload already sets this; this skip only applies to manual runs.\n' >&2
            exit 0
        fi
    fi
fi

if [[ "${BRIDGE_PICKER_SWEEP_ENABLED:-1}" != "1" ]]; then
    _psw_log "BRIDGE_PICKER_SWEEP_ENABLED=0 (explicit opt-out) — picker-sweep skipped"
    exit 0
fi

# ---------------------------------------------------------------------------
# Required runtime knobs. We do NOT fall back to BRIDGE_ADMIN_AGENT_ID even
# when the roster is sourced — silent admin-as-default would re-introduce the
# false-positive trap (admin's own pane discusses pickers in PR bodies / logs)
# and operators must opt into self-skip + notify explicitly.
# ---------------------------------------------------------------------------

SELF_AGENT="${BRIDGE_PICKER_SWEEP_SELF:-}"
NOTIFY_AGENT="${BRIDGE_PICKER_SWEEP_NOTIFY:-}"

if [[ -z "$SELF_AGENT" && -z "$NOTIFY_AGENT" ]]; then
    _psw_log "warn: BRIDGE_PICKER_SWEEP_SELF and BRIDGE_PICKER_SWEEP_NOTIFY both unset; running without self-skip or admin notification (log only)"
fi

# ---------------------------------------------------------------------------
# Picker pattern allow-list. Line-anchored *strictly* — only whitespace is
# allowed between line-start and the option marker. This rejects markdown
# quote prefixes (`>   ❯ 1. Stop and wait...`), bullet lists, and other
# free-prose contexts that could otherwise paste a picker option text into
# an agent's pane (PR body, upstream issue draft, debug log).
#
# Real picker shape:
#   ❯ 1. <option text>
#   2. <option text>
#
# Add new options carefully — false-positive on Claude's own output is the
# main failure mode. Prefer expanding the option enumeration to a whole new
# regex only if Anthropic ships a new picker shape.
# ---------------------------------------------------------------------------

_PICKER_OPTION_LINE_RE='^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]+(Stop and wait for limit to reset|Switch to extra usage|Switch to Team plan|Resume from summary \(recommended\)|Resume full session as-is)[[:space:]]*$'
_PICKER_TAIL_RE='^[[:space:]]*Enter to confirm · Esc to cancel[[:space:]]*$'

# ---------------------------------------------------------------------------
# Test seams. The smoke replaces these with fixture-driven wrappers.
#
# Default implementations call real tmux / agent-bridge. Each wrapper reads
# from stdin / writes to stdout so smoke can pipe through cat-files.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329 # invoked indirectly via $_PSW_*_FN below
_psw_default_list_sessions() {
    tmux list-sessions -F "#{session_name}" 2>/dev/null
}

# shellcheck disable=SC2329 # invoked indirectly via $_PSW_*_FN below
_psw_default_capture_pane() {
    local target="$1"
    tmux capture-pane -pt "$target" 2>/dev/null | tail -25
}

# shellcheck disable=SC2329 # invoked indirectly via $_PSW_*_FN below
_psw_default_send_enter() {
    local target="$1"
    tmux send-keys -t "$target" Enter 2>/dev/null
}

# shellcheck disable=SC2329 # invoked indirectly via $_PSW_*_FN below
_psw_default_create_task() {
    local title="$1" body="$2" recipient="$3"
    "$BRIDGE_HOME/agent-bridge" task create \
        --to "$recipient" \
        --from "cron:picker-sweep" \
        --priority normal \
        --title "$title" \
        --body "$body" 2>&1
}

# Resolve seam overrides (smoke supplies executable paths / function names).
_PSW_LIST_SESSIONS_FN="${BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN:-_psw_default_list_sessions}"
_PSW_CAPTURE_PANE_FN="${BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN:-_psw_default_capture_pane}"
_PSW_SEND_ENTER_FN="${BRIDGE_PICKER_SWEEP_SEND_ENTER_FN:-_psw_default_send_enter}"
_PSW_CREATE_TASK_FN="${BRIDGE_PICKER_SWEEP_CREATE_TASK_FN:-_psw_default_create_task}"

_psw_list_sessions() { "$_PSW_LIST_SESSIONS_FN"; }
_psw_capture_pane()  { "$_PSW_CAPTURE_PANE_FN"  "$@"; }
_psw_send_enter()    { "$_PSW_SEND_ENTER_FN"    "$@"; }
_psw_create_task()   { "$_PSW_CREATE_TASK_FN"   "$@"; }

# ---------------------------------------------------------------------------
# Sweep.
# ---------------------------------------------------------------------------

unstuck_agents=()

while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    if [[ -n "$SELF_AGENT" && "$agent" == "$SELF_AGENT" ]]; then
        continue
    fi

    cap="$(_psw_capture_pane "$agent" || true)"
    matched_pattern=""
    if printf '%s\n' "$cap" | grep -qE "$_PICKER_OPTION_LINE_RE"; then
        if printf '%s\n' "$cap" | grep -qE "$_PICKER_TAIL_RE"; then
            matched_pattern="picker option line + tail"
        else
            matched_pattern="picker option line"
        fi
    fi

    if [[ -n "$matched_pattern" ]]; then
        _psw_log "PICKER detected on '$agent' ($matched_pattern) — sending Enter for default"
        if ! _psw_send_enter "$agent"; then
            _psw_log "  send-enter failed for $agent"
            continue
        fi
        unstuck_agents+=("$agent:$matched_pattern")
    fi
done < <(_psw_list_sessions)

if (( ${#unstuck_agents[@]} == 0 )); then
    _psw_log "no picker stuck — sweep clean"
    exit 0
fi

joined="$(printf '%s\n' "${unstuck_agents[@]}")"
_psw_log "summary: ${#unstuck_agents[@]} agents unstuck"

if [[ -z "$NOTIFY_AGENT" ]]; then
    _psw_log "BRIDGE_PICKER_SWEEP_NOTIFY unset — skipping admin task creation"
    exit 0
fi

task_body=$(cat <<EOF
Claude Code interactive picker auto-unstick result:

$joined

Each session was advanced via the default option (Enter). The default for
rate-limit pickers is "Stop and wait for limit to reset" (safest); the default
for resume-from-summary is "Resume from summary (recommended)".

This cron is best-effort. If the same agent shows up across multiple sweeps,
investigate manually — repeated picker hits usually indicate a deeper
plan-level issue (rate limit window saturated, broken summary, etc).

log: $LOG
EOF
)

if ! _psw_create_task \
        "[picker-sweep] ${#unstuck_agents[@]} agent(s) auto-unstuck from interactive picker" \
        "$task_body" \
        "$NOTIFY_AGENT" >> "$LOG" 2>&1; then
    _psw_log "warn: agent-bridge task create failed (see log above)"
fi

exit 0
