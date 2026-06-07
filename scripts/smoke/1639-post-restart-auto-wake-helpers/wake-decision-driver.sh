#!/usr/bin/env bash
# scripts/smoke/1639-post-restart-auto-wake-helpers/wake-decision-driver.sh
#
# Issue #1639 — driver for the post-restart auto-wake decision smoke.
#
# The production decision lives inside the backgrounded `bash -lc '...'`
# subshell of bridge_run_schedule_idle_marker_and_inbox_bootstrap()
# (bridge-run.sh). That function cannot be sourced directly — bridge-run.sh
# runs its launch loop unconditionally on load and re-execs through a
# privileged credential-scrub shell — and its real body backgrounds a
# subshell that waits on a live tmux prompt. This driver re-traces the EXACT
# decision branch (the gate + which inject fires + the #1199 nudge record +
# the once-per-loop marker write) against the REAL production bridge-lib.sh
# helpers (bridge_inject_metadata_only_enabled, bridge_format_injection_meta),
# with argv-recording stubs for the tmux send + queue lookup so the smoke can
# assert exactly one wake per scenario with no live tmux/queue dependency.
#
# The parent smoke (scripts/smoke/1639-post-restart-auto-wake.sh) also runs a
# source-grep gate asserting the production function still carries the guard
# tokens this driver mirrors, so a future edit to bridge-run.sh that diverges
# from this driver fails loudly instead of silently passing a stale test.
#
# Shipped as a tracked file (not a heredoc-to-file body in the smoke wrapper)
# to match scripts/smoke/835-static-admin-launch-helpers/ and to keep the
# decision bytes off the Bash 5.3.9 heredoc-write class (footgun #11).
#
# Invocation:
#   bash wake-decision-driver.sh <repo_root> <state_dir> <agent> \
#       <auto_restart_wake:0|1> <queue_has_open:0|1> \
#       <marker_present:0|1> <next_session_present:0|1>
#
# Output (stdout), one KEY=VALUE per line:
#   SEND_COUNT=<n>          number of bridge_tmux_send_and_submit calls
#   SEND_TEXT=<payload>     the injected payload (empty if none)
#   NUDGE_COUNT=<n>         number of bridge_task_note_nudge calls
#   NUDGE_KEY=<key>         the recorded nudge key (empty if none)
#   MARKER_WRITTEN=<0|1>    whether a new initial-inbox marker was written

set -euo pipefail

repo_root="$1"
state_dir="$2"
agent="$3"
auto_restart_wake="$4"
# queue_state: one of
#   queued  — at least one genuinely-queued task (nudge-live-state top + key set)
#   claimed — only claimed/blocked OPEN work, NO queued task (#1639 codex r3 [P2]:
#             nudge-live-state returns a row with empty top/key, but find-open
#             still surfaces the open task; wake fires, NO dedup key recorded)
#   cron    — ONLY [cron-dispatch] rows open, NO queued/claimed/blocked non-cron
#             work (#1639 Phase-4 codex r4: nudge-live-state reports 0 and the
#             scoped find-open excludes cron, so NO wake fires)
#   empty   — no open work at all
queue_state="$5"
marker_present="$6"
next_session_present="$7"

# Hermetic temp tree for this driver run.
work_root="$state_dir/$agent"
mkdir -p "$work_root"
next_file="$work_root/NEXT-SESSION.md"
marker_file="$work_root/initial-inbox.started"
sends_file="$work_root/sends.txt"
nudge_file="$work_root/nudge.txt"
: >"$sends_file"
: >"$nudge_file"

[[ "$marker_present" == "1" ]] && printf '0\n' >"$marker_file"
[[ "$next_session_present" == "1" ]] && printf 'handoff\n' >"$next_file"

# Source the production library for the REAL injection-payload formatters.
# shellcheck source=../../../bridge-lib.sh disable=SC1091
source "$repo_root/bridge-lib.sh"

# Argv-recording stubs, defined AFTER the source so they override the real
# tmux/queue helpers. These are the only two external effects of the wake
# decision; everything else (format, gate) runs the production code path.
# shellcheck disable=SC2317
bridge_tmux_send_and_submit() {
  # args: <session> <engine> <text> <agent>
  printf '%s\n' "${3:-}" >>"$sends_file"
}
# shellcheck disable=SC2317
bridge_task_note_nudge() {
  # args: <agent> <key>
  printf '%s\n' "${2:-}" >>"$nudge_file"
}
# shellcheck disable=SC2317
bridge_queue_cli() {
  # find-open is the scoped OPEN-set probe production reaches ONLY when
  # nudge-live-state surfaced no queued top — claimed/blocked-only open work
  # (#1639 codex r3 [P2]) or a helper-unavailable fallback. #1639 Phase-4 codex
  # r4: production scopes it to NON-CRON claimed|blocked (`--status-filter
  # claimed --status-filter blocked --exclude-title-prefix '[cron-dispatch]'`),
  # so a cron-dispatch-ONLY queue must yield no fallback wake. Model that here so
  # the smoke has teeth: only honor the cron exclusion when the caller actually
  # passes the r4 scoping flags — a regression to the unscoped `find-open
  # --agent` form drops `scoped`, surfaces the cron row, and trips the cron-only
  # SEND_COUNT=0 case below.
  if [[ "${1:-}" == "find-open" ]]; then
    local args="$*" scoped=0
    [[ "$args" == *"--status-filter claimed"* \
       && "$args" == *"--status-filter blocked"* \
       && "$args" == *"--exclude-title-prefix"*"[cron-dispatch]"* ]] && scoped=1
    case "$queue_state" in
      claimed) printf '%s\n' 99 ;;
      cron) [[ "$scoped" -eq 0 ]] && printf '%s\n' 1234 ;;
    esac
  fi
  return 0
}
# Stub bridge_with_timeout so the canonical nudge-live-state derivation runs
# without spawning python3 / reading a real DB. Production calls it with
# with_top_task=1, so emit the 6-column row:
#   queued_count <TAB> claimed_count <TAB> csv_ids <TAB> top_id <TAB> top_priority <TAB> top_title
# - queued : top_id=7 is a QUEUED id, key 7,11 is the full queued set (codex r2
#            [P2]: top + dedup key both from the same queued set).
# - claimed: a row exists (claimed_count>0) but queued cols are EMPTY, so the
#            decision must fall through to the find-open open-set probe (codex r3
#            [P2]) and record NO dedup key.
# - empty  : all columns empty.
# shellcheck disable=SC2317
bridge_with_timeout() {
  # args: <seconds> <label> <cmd...>
  if [[ "$queue_state" == "queued" ]]; then
    printf '2\t0\t7,11\t7\tnormal\ttask seven\n'
  elif [[ "$queue_state" == "claimed" ]]; then
    printf '0\t1\t\t\t\t\n'
  else
    printf '0\t0\t\t\t\t\n'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Decision branch — a faithful mirror of bridge-run.sh's inner subshell body
# from the `bridge_agent_mark_idle_now` line onward (#1639). Keep in sync; the
# parent smoke's source-grep gate locks the production guard tokens.
# ---------------------------------------------------------------------------
if [[ ! -f "$next_file" ]] \
    && { [[ ! -f "$marker_file" ]] || [[ "$auto_restart_wake" == "1" ]]; }; then
  queued_top=""
  queue_key=""
  if command -v bridge_with_timeout >/dev/null 2>&1; then
    nudge_state="$(bridge_with_timeout 15 inbox_bootstrap_nudge_key \
      python3 "$repo_root/bridge-daemon-helpers.py" \
      nudge-live-state "${BRIDGE_TASK_DB:-}" "$agent" 1 2>/dev/null)" || nudge_state=""
    if [[ -n "$nudge_state" ]]; then
      queue_key="$(printf "%s" "$nudge_state" | cut -f3)"
      queued_top="$(printf "%s" "$nudge_state" | cut -f4)"
    fi
  fi
  task_id=""
  if [[ -n "$queued_top" ]]; then
    task_id="$queued_top"
  else
    # No queued top — probe the open set for NON-CRON claimed/blocked work
    # (#1639 codex r3 [P2]); record NO dedup key (daemon nudges only queued).
    # #1639 Phase-4 codex r4: scope to claimed|blocked AND exclude cron-dispatch
    # so a cron-only queue does not trigger a spurious fallback wake — kept
    # byte-aligned with bridge-run.sh's production fallback.
    queue_key=""
    task_id="$(bridge_queue_cli find-open --agent "$agent" --status-filter claimed --status-filter blocked --exclude-title-prefix '[cron-dispatch]' 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$task_id" ]]; then
    if bridge_inject_metadata_only_enabled; then
      inject_text="$(bridge_format_injection_meta inbox-bootstrap agent="$agent" top="$task_id")"
    else
      inject_text="[Agent Bridge] ACTION REQUIRED — open tasks detected. Run exactly: ~/.agent-bridge/agb inbox $agent"
    fi
    bridge_tmux_send_and_submit "session" claude "$inject_text" "$agent"
    if [[ -n "$queue_key" ]]; then
      bridge_task_note_nudge "$agent" "$queue_key" >/dev/null 2>&1 || true
    fi
  elif [[ "$auto_restart_wake" == "1" && ! -f "$marker_file" ]]; then
    if bridge_inject_metadata_only_enabled; then
      inject_text="$(bridge_format_injection_meta session-resumed agent="$agent" reason=auto-restart)"
    else
      inject_text="[Agent Bridge] session resumed after an automatic restart — re-read your session onboarding (SOUL.md / CLAUDE.md / NEXT-SESSION.md) and check your queue: ~/.agent-bridge/agb inbox $agent"
    fi
    bridge_tmux_send_and_submit "session" claude "$inject_text" "$agent"
  fi
  if [[ ! -f "$marker_file" ]]; then
    mkdir -p "$(dirname "$marker_file")"
    printf "%s\n" "$(date +%s)" >"$marker_file"
    marker_just_written=1
  fi
fi

send_count="$(wc -l <"$sends_file" | tr -d '[:space:]')"
nudge_count="$(wc -l <"$nudge_file" | tr -d '[:space:]')"
send_text="$(head -n 1 "$sends_file" 2>/dev/null || true)"
nudge_key="$(head -n 1 "$nudge_file" 2>/dev/null || true)"

printf 'SEND_COUNT=%s\n' "$send_count"
printf 'SEND_TEXT=%s\n' "$send_text"
printf 'NUDGE_COUNT=%s\n' "$nudge_count"
printf 'NUDGE_KEY=%s\n' "$nudge_key"
printf 'MARKER_WRITTEN=%s\n' "${marker_just_written:-0}"
