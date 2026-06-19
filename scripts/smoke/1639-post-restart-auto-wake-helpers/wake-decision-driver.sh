#!/usr/bin/env bash
# scripts/smoke/1639-post-restart-auto-wake-helpers/wake-decision-driver.sh
#
# Issue #1639 + #2003 — driver for the post-restart auto-wake decision smoke.
#
# The production decision lives inside the backgrounded `bash -lc '...'`
# subshell of bridge_run_schedule_idle_marker_and_inbox_bootstrap()
# (bridge-run.sh). That function cannot be sourced directly — bridge-run.sh
# runs its launch loop unconditionally on load and re-execs through a
# privileged credential-scrub shell — and its real body backgrounds a
# subshell that waits on a live tmux prompt. This driver re-traces the EXACT
# decision branch (the gate + which inject fires + the #1199 nudge record +
# the per-session restart-wake latch) against the REAL production bridge-lib.sh
# helpers (bridge_inject_metadata_only_enabled, bridge_format_injection_meta,
# bridge_agent_restart_wake_marker_file, bridge_run_handoff_task_find_or_create),
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
#       <auto_restart_wake:0|1> <queue_state:queued|claimed|cron|empty> \
#       <marker_present:0|1> <next_session_present:0|1> \
#       [queue_available:0|1] [session_identity]
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
#   claimed — only claimed/blocked OPEN work, NO queued task (#1639 codex r3 [P2])
#   cron    — ONLY [cron-dispatch] rows open, NO non-cron work (#1639 r4 → no wake)
#   empty   — no open work at all
queue_state="$5"
marker_present="$6"
next_session_present="$7"
# queue_available (#2003): 0 means the handoff find/create path fails (queue
# outage), exercising the queue-less restart-wake marker fallback. Default 1.
queue_available="${8:-1}"
# session_identity override (#2003): when set, the production code resolves the
# Claude session id via the stub below so two driver runs can model the SAME or
# DIFFERENT launched session (re-wake idempotency across sessions).
session_identity_override="${9:-}"

# Hermetic temp tree for this driver run. NOTE: the restart-wake marker latch
# (#2003) is written under bridge_agent_idle_marker_dir = $BRIDGE_ACTIVE_AGENT_DIR
# /<agent>; the parent smoke points BRIDGE_ACTIVE_AGENT_DIR at its own state tree
# so the latch persists across driver runs that share a session_identity.
work_root="$state_dir/$agent"
mkdir -p "$work_root"
next_file="$work_root/NEXT-SESSION.md"
marker_file="$work_root/initial-inbox.started"
sends_file="$work_root/sends.txt"
nudge_file="$work_root/nudge.txt"
: >"$sends_file"
: >"$nudge_file"

[[ "$marker_present" == "1" ]] && printf '0\n' >"$marker_file"
[[ "$next_session_present" == "1" ]] && printf 'handoff-body\n' >"$next_file"

# Source the production library for the REAL injection-payload formatters +
# the #2003 restart-wake marker + handoff find/create helpers.
# shellcheck source=../../../bridge-lib.sh disable=SC1091
source "$repo_root/bridge-lib.sh"

# Argv-recording stubs, defined AFTER the source so they override the real
# tmux/queue helpers. Everything else (format, gate, marker math) runs the
# production code path.
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
bridge_agent_session_id() {
  # #2003 session_identity source. Empty → production falls back to tmux:<s>:<nonce>.
  printf '%s' "$session_identity_override"
}
# shellcheck disable=SC2317
bridge_agent_workdir() {
  # Point the next-session digest/file resolver at this driver's hermetic tree
  # so bridge_agent_next_session_digest hashes OUR NEXT-SESSION.md (production:
  # WORK_DIR == workdir, so next_file and the digest file are the same).
  printf '%s' "$work_root"
}
# shellcheck disable=SC2317
bridge_queue_cli() {
  # #2003 handoff find-or-create: production now routes through the ATOMIC
  # `upsert-open` (BEGIN IMMEDIATE) instead of racy find-open+create. It emits
  # `TASK_ID=<n>` (shell format) for the existing-or-created row, or fails on a
  # queue outage. Model that here so the smoke exercises the same id-extraction.
  if [[ "${1:-}" == "upsert-open" ]]; then
    [[ "$queue_available" == "1" ]] || return 1   # queue outage → caller falls back
    # Already-queued handoff (the SessionStart-hook ran first): existing id 55.
    # Otherwise the upsert created it: id 77. TASK_CREATED is informational.
    if [[ "$queue_state" == "queued" ]]; then
      printf "TASK_ID=55\nTASK_CREATED=0\n"
    else
      printf "TASK_ID=77\nTASK_CREATED=1\n"
    fi
    return 0
  fi
  # find-open is the scoped OPEN-set probe production reaches ONLY when
  # nudge-live-state surfaced no queued top — claimed/blocked-only open work
  # (#1639 codex r3 [P2]). The r4 cron exclusion is honored only when the caller
  # passes the scoping flags. (The handoff path no longer uses find-open.)
  if [[ "${1:-}" == "find-open" ]]; then
    local args="$*"
    # Robust fallback the production helper uses if TASK_ID parse ever fails:
    # re-find the handoff by exact title. Mirror the upsert ids.
    if [[ "$args" == *"[bridge:handoff-pending]"* ]]; then
      [[ "$queue_available" == "1" ]] || return 0
      if [[ "$queue_state" == "queued" ]]; then printf '%s\n' 55; else printf '%s\n' 77; fi
      return 0
    fi
    local scoped=0
    [[ "$args" == *"--status-filter claimed"* \
       && "$args" == *"--status-filter blocked"* \
       && "$args" == *"--exclude-title-prefix"*"[cron-dispatch]"* ]] && scoped=1
    case "$queue_state" in
      claimed) printf '%s\n' 99 ;;
      cron) [[ "$scoped" -eq 0 ]] && printf '%s\n' 1234 ;;
    esac
    return 0
  fi
  return 0
}
# Stub bridge_with_timeout so the canonical nudge-live-state derivation runs
# without spawning python3 / reading a real DB. Production calls it with
# with_top_task=1, so emit the 6-column row:
#   queued_count <TAB> claimed_count <TAB> csv_ids <TAB> top_id <TAB> top_priority <TAB> top_title
# shellcheck disable=SC2317
bridge_with_timeout() {
  # args: <seconds> <label> <cmd...>
  if [[ "$queue_state" == "queued" && "$next_session_present" != "1" ]]; then
    # A genuinely-queued NON-handoff task.
    printf '2\t0\t7,11\t7\tnormal\ttask seven\n'
  else
    # claimed/cron/empty, OR a NEXT-SESSION present with no separately-queued
    # task (the handoff itself is surfaced via find/create, not nudge-live-state).
    if [[ "$queue_state" == "claimed" ]]; then
      printf '0\t1\t\t\t\t\n'
    else
      printf '0\t0\t\t\t\t\n'
    fi
  fi
  return 0
}

# Provide a launch nonce identical in spirit to production.
launch_nonce="driver-${RANDOM}${RANDOM}"
session="smoke-session"

# ---------------------------------------------------------------------------
# Decision branch — a faithful mirror of bridge-run.sh's inner subshell body
# from the `bridge_agent_mark_idle_now` line onward (#1639 + #2003). Keep in
# sync; the parent smoke's source-grep gate locks the production guard tokens.
# ---------------------------------------------------------------------------
if [[ ! -f "$marker_file" ]] || [[ "$auto_restart_wake" == "1" ]]; then
  session_identity="$(bridge_agent_session_id "$agent" 2>/dev/null || true)"
  if [[ -n "$session_identity" ]]; then
    session_identity="claude:${session_identity}"
  else
    session_identity="tmux:${session}:${launch_nonce}"
  fi

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
  wake_kind=""
  payload_digest="none"
  fallback_kick=0
  if [[ -n "$queued_top" ]]; then
    task_id="$queued_top"
    wake_kind="queued"
    payload_digest="$queue_key"
  else
    task_id="$(bridge_queue_cli find-open --agent "$agent" --status-filter claimed --status-filter blocked --exclude-title-prefix '[cron-dispatch]' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$task_id" ]]; then
      wake_kind="claimed-blocked"
      queue_key=""
      payload_digest="none"
    elif [[ -f "$next_file" ]]; then
      wake_kind="handoff"
      payload_digest="$(bridge_agent_next_session_digest "$agent" 2>/dev/null || printf "none")"
      handoff_id="$(bridge_run_handoff_task_find_or_create "$agent" "$next_file" 2>/dev/null || true)"
      if [[ -n "$handoff_id" ]]; then
        task_id="$handoff_id"
        queue_key="$handoff_id"
      else
        queue_key=""
        fallback_kick=1
      fi
    elif [[ "$auto_restart_wake" == "1" && ! -f "$marker_file" ]]; then
      wake_kind="first-launch-empty"
      payload_digest="none"
      fallback_kick=1
    fi
  fi

  restart_wake_marker=""
  if (( fallback_kick == 1 )); then
    restart_wake_marker="$(bridge_agent_restart_wake_marker_file "$agent" "$session_identity" "$wake_kind" "$payload_digest")"
    if [[ -f "$restart_wake_marker" ]]; then
      fallback_kick=0
      task_id=""
    fi
  fi

  if [[ -n "$task_id" ]]; then
    if bridge_inject_metadata_only_enabled; then
      inject_text="$(bridge_format_injection_meta inbox-bootstrap agent="$agent" top="$task_id")"
    else
      inject_text="[Agent Bridge] ACTION REQUIRED — open tasks detected. Run exactly: ~/.agent-bridge/agb inbox $agent"
    fi
    bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
    if [[ -n "$queue_key" ]]; then
      bridge_task_note_nudge "$agent" "$queue_key" >/dev/null 2>&1 || true
    fi
  elif (( fallback_kick == 1 )); then
    if [[ "$wake_kind" == "handoff" ]]; then
      if bridge_inject_metadata_only_enabled; then
        inject_text="$(bridge_format_injection_meta handoff-resume agent="$agent" reason=auto-restart)"
      else
        inject_text="[Agent Bridge] session resumed after an automatic restart — a NEXT-SESSION.md handoff is pending."
      fi
    else
      if bridge_inject_metadata_only_enabled; then
        inject_text="$(bridge_format_injection_meta session-resumed agent="$agent" reason=auto-restart)"
      else
        inject_text="[Agent Bridge] session resumed after an automatic restart."
      fi
    fi
    bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
    if [[ -n "$restart_wake_marker" ]]; then
      mkdir -p "$(dirname "$restart_wake_marker")" 2>/dev/null || true
      printf "%s\n" "$(date +%s)" >"$restart_wake_marker" 2>/dev/null || true
    fi
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
