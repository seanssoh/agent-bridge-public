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
#
# 2026-05-16 additions (post-v0.14.1 ship E2E):
#   - "I am using this for local development" — Claude Code's development-
#     channels warning that blocks agent launch when channels env carries
#     a development plugin. Default cursor `❯ 1` is on this option, so a
#     bare Enter accepts and continues. Discovered when patch was stuck
#     post-v0.14.1 upgrade with development-channels warning visible.
#   - "Press enter to continue" — codex CLI's cwd-confirm prompt. Different
#     shape from Claude's numbered picker (single confirmation line, no
#     options). Has its own regex below (_PICKER_CODEX_CONFIRM_RE).
#
# 2026-05-17 additions (#948 — fresh-install spawn crash-loop):
#   - "Yes, I accept" / "No, exit" (Bypass Permissions warning) — Claude's
#     default cursor is on "No, exit" (option 1). Bare Enter would EXIT
#     Claude. Now handled via _PICKER_BYPASS_PERMISSIONS_RE +
#     explicit "send 2 + Enter" through the new option-N send mechanism
#     (BRIDGE_PICKER_SWEEP_SEND_OPTION_FN seam below).
#   - Auto mode warning ("Yes, and make it my default mode" /
#     "Yes, enable auto mode" / "No, exit") — same pattern. Sweeper sends
#     option 1 (make-default) so subsequent claude restarts don't re-prompt
#     and crash-loop the agent.
# ---------------------------------------------------------------------------

_PICKER_OPTION_LINE_RE='^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]+(Stop and wait for limit to reset|Switch to extra usage|Switch to Team plan|Resume from summary \(recommended\)|Resume full session as-is|I am using this for local development)[[:space:]]*$'
_PICKER_TAIL_RE='^[[:space:]]*Enter to confirm · Esc to cancel[[:space:]]*$'

# Codex picker shape — fundamentally different from Claude's. Codex emits
# a single "Press enter to continue" line (no numbered options) when
# confirming the working directory at launch. Auto-Enter is safe because
# there's only one action path. Added 2026-05-16 after codex patch-dev
# was blocked at the cwd-confirm prompt during the v0.13.x → v0.14.1
# upgrade supervise flow.
_PICKER_CODEX_CONFIRM_RE='^[[:space:]]*Press enter to continue[[:space:]]*$'

# #948 — Bypass Permissions warning. Claude CLI default cursor is on
# "No, exit" (option 1), so bare Enter would EXIT Claude on first launch
# in a fresh install / fresh user account. Must explicitly send "2" + Enter
# to accept. The warning is emitted whenever launch_cmd uses
# `--dangerously-skip-permissions` (agent-bridge's static admin contract)
# and the user/machine hasn't acked it yet.
#
# r3 — key the matcher off the DISTINCTIVE "Yes, I accept" line, not the
# generic "No, exit" / "1. No, exit". Codex PR #949 r2 review caught that
# matching on the generic option could false-positive on any other Claude
# warning whose menu also offered "No, exit", causing the sweeper to send
# a safety-sensitive "2" against an unrelated prompt. Requiring the
# accept-option line ensures we only fire on the actual Bypass warning.
_PICKER_BYPASS_PERMISSIONS_ACCEPT_RE='^[[:space:]]*(❯[[:space:]]*)?2\.[[:space:]]+Yes, I accept[[:space:]]*$'

# #948 — Auto mode warning. 3-option picker:
#   1. Yes, and make it my default mode
#   2. Yes, enable auto mode (just this once)
#   3. No, exit
# Default cursor is on option 1. Send "1" + Enter so subsequent claude
# restarts don't re-prompt and crash-loop the agent.
#
# r3 — key the matcher off the DISTINCTIVE "Yes, and make it my default
# mode" line, not the generic "No, exit". Same false-positive guard as the
# bypass regex above.
_PICKER_AUTO_MODE_ACCEPT_RE='^[[:space:]]*(❯[[:space:]]*)?1\.[[:space:]]+Yes, and make it my default mode[[:space:]]*$'

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

# #948 — send an explicit option number followed by Enter. Used for pickers
# whose default cursor lands on a destructive option (e.g., Bypass Permissions
# warning defaults to "No, exit"). The send is split into two calls so the
# digit input is committed before Enter fires it — tmux send-keys collapses
# adjacent string args, and a stray "2Enter" literal can confuse the TUI.
# shellcheck disable=SC2329 # invoked indirectly via $_PSW_*_FN below
_psw_default_send_option() {
    local target="$1" option_num="$2"
    tmux send-keys -t "$target" "$option_num" 2>/dev/null && \
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
_PSW_SEND_OPTION_FN="${BRIDGE_PICKER_SWEEP_SEND_OPTION_FN:-_psw_default_send_option}"
_PSW_CREATE_TASK_FN="${BRIDGE_PICKER_SWEEP_CREATE_TASK_FN:-_psw_default_create_task}"

_psw_list_sessions() { "$_PSW_LIST_SESSIONS_FN"; }
_psw_capture_pane()  { "$_PSW_CAPTURE_PANE_FN"  "$@"; }
_psw_send_enter()    { "$_PSW_SEND_ENTER_FN"    "$@"; }
_psw_send_option()   { "$_PSW_SEND_OPTION_FN"   "$@"; }
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
    explicit_option=""   # #948 — when set, send "N + Enter" instead of bare Enter

    # r4 (codex PR #949 r3) + r5 (codex PR #949 r4) — scope explicit-option
    # detection to the ACTIVE picker block ONLY. capture-pane returns ~25
    # lines of scrollback, so two false-positive shapes need defending:
    #   r4 case — stale bypass accept line + active auto picker in same
    #             capture: bypass regex would win and send option 2 into
    #             the auto menu (= "just this once" instead of "make
    #             default"), ack would not persist.
    #   r5 case — stale "2. Yes, I accept" in free-text (above an unrelated
    #             active picker that ends with the canonical tail): would
    #             fire bypass branch and send option 2 into the unrelated
    #             menu (safety-sensitive false-positive).
    # active_picker now extracts only lines between the MOST RECENT
    # WARNING header (the canonical menu opener) and the MOST RECENT tail
    # line that follows it. Stale text outside that window (free-prose,
    # previous picker rounds, unrelated warnings) is excluded.
    active_picker="$(printf '%s\n' "$cap" | awk -v tail_re="$_PICKER_TAIL_RE" '
      /^[[:space:]]*WARNING:/ { start = NR; have_start = 1; have_end = 0; bail = 0 }
      have_start && $0 ~ tail_re { end = NR; have_end = 1 }
      # r6 (codex PR #949 r5) — if any non-blank line appears AFTER the
      # tail, the picker has already been answered and the bottom of the
      # pane is now showing later output. Bail; the warning+tail block in
      # scrollback is stale and must not fire.
      have_end && NR > end && /[^[:space:]]/ { bail = 1 }
      { lines[NR] = $0 }
      END {
        if (have_start && have_end && !bail) {
          for (i = start; i <= end; i++) print lines[i]
        }
      }
    ')"

    if [[ -n "$active_picker" ]] \
        && printf '%s\n' "$active_picker" | grep -qE "$_PICKER_BYPASS_PERMISSIONS_ACCEPT_RE"; then
        # Bypass Permissions warning (#948). Default cursor is "No, exit",
        # so we must EXPLICITLY send "2" to accept. Both the distinctive
        # accept line ("2. Yes, I accept") AND the canonical tail are
        # required — r3 hardening (codex PR #949 r2) ensures we don't
        # false-positive on any other Claude warning that happens to
        # include "No, exit".
        matched_pattern="bypass-permissions warning"
        explicit_option="2"
    elif [[ -n "$active_picker" ]] \
        && printf '%s\n' "$active_picker" | grep -qE "$_PICKER_AUTO_MODE_ACCEPT_RE"; then
        # Auto mode warning (#948). Send "1" so the mode becomes the user
        # default — next claude restart won't re-prompt. Same r3 hardening
        # as bypass — match the distinctive "Yes, and make it my default
        # mode" line, not the generic "No, exit".
        matched_pattern="auto-mode warning"
        explicit_option="1"
    elif printf '%s\n' "$cap" | grep -qE "$_PICKER_OPTION_LINE_RE"; then
        if printf '%s\n' "$cap" | grep -qE "$_PICKER_TAIL_RE"; then
            matched_pattern="picker option line + tail"
        else
            matched_pattern="picker option line"
        fi
    elif printf '%s\n' "$cap" | grep -qE "$_PICKER_CODEX_CONFIRM_RE"; then
        # Codex cwd-confirm picker (single "Press enter to continue" line,
        # no numbered options). Safe to auto-Enter — only one action path.
        matched_pattern="codex cwd-confirm"
    fi

    if [[ -n "$matched_pattern" ]]; then
        if [[ -n "$explicit_option" ]]; then
            _psw_log "PICKER detected on '$agent' ($matched_pattern) — sending option $explicit_option + Enter"
            if ! _psw_send_option "$agent" "$explicit_option"; then
                _psw_log "  send-option failed for $agent"
                continue
            fi
            # #948 r2 — record the actual action so the admin task body below
            # reports the safety-sensitive explicit option, not the default
            # "Enter". Codex PR #949 review caught the misreport.
            unstuck_agents+=("$agent:$matched_pattern (sent option $explicit_option)")
        else
            _psw_log "PICKER detected on '$agent' ($matched_pattern) — sending Enter for default"
            if ! _psw_send_enter "$agent"; then
                _psw_log "  send-enter failed for $agent"
                continue
            fi
            unstuck_agents+=("$agent:$matched_pattern (sent Enter)")
        fi
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

# #948 r2 — admin task body. Rewritten to use a plain multi-line string
# assignment (no heredoc-inside-command-substitution) so the parse path
# stays robust across the Bash 5.3.9 + macOS shell harness contexts where
# `$(cat <<EOF ... EOF)` with longer bodies tripped a parser edge case
# (unexpected EOF while looking for matching backtick-paren). Backslash-
# escaped quotes keep the body readable while staying within standard
# double-quoted string rules.
task_body="Claude Code interactive picker auto-unstick result:

$joined

Each entry shows the agent, picker pattern, and the actual action taken
(\"sent Enter\" for default-option pickers, \"sent option N\" for explicit
picks). The explicit-option path is used for safety-sensitive prompts
(e.g., Bypass Permissions warning, Auto mode warning - refs #948) where the
default cursor would EXIT Claude rather than accept; sweeper sends the
documented \"accept\" option (option 2 for Bypass Permissions, option 1 for
Auto mode \"make default\").

For default-Enter pickers: rate-limit pickers default to \"Stop and wait
for limit to reset\" (safest); resume-from-summary defaults to
\"Resume from summary (recommended)\".

This cron is best-effort. If the same agent shows up across multiple sweeps,
investigate manually - repeated picker hits usually indicate a deeper
plan-level issue (rate limit window saturated, broken summary, etc.) or
that the explicit-option ack did not persist across claude restarts.

log: $LOG"

if ! _psw_create_task \
        "[picker-sweep] ${#unstuck_agents[@]} agent(s) auto-unstuck from interactive picker" \
        "$task_body" \
        "$NOTIFY_AGENT" >> "$LOG" 2>&1; then
    _psw_log "warn: agent-bridge task create failed (see log above)"
fi

exit 0
