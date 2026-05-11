#!/bin/bash
# librarian-idle-exit.sh — librarian calls this when its inbox is empty.
#
# Strategy: dynamic agent should not idle. After draining the last
# [librarian-ingest] task the librarian session invokes this script, which:
#   1. double-checks inbox is truly empty (race guard: work could have arrived
#      in the last second)
#   2. if inbox still empty, calls `agb agent stop librarian` in --no-attach
#      mode — bridge-daemon terminates the tmux session gracefully
#   3. else exits 0 so the calling session stays alive and resumes the loop
#
# Intended use: the librarian CLAUDE.md agent invokes this as its final bash
# call when it has no remaining work. The watchdog cron brings the agent back
# on demand.
#
# Safe to run anywhere; no-ops if librarian isn't registered.

set -u

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
BRIDGE_CLI="$BRIDGE_HOME/agent-bridge"
AGB="$BRIDGE_HOME/agb"
AGENT="librarian"
LOG="$BRIDGE_HOME/state/librarian-watchdog.log"
GRACE_SECONDS="${LIBRARIAN_IDLE_GRACE_SECONDS:-60}"

log() { printf '%s [idle-exit] %s\n' "$(date +%FT%T%z)" "$*" 2>/dev/null >>"$LOG" || true; }

if ! "$BRIDGE_CLI" agent list 2>/dev/null | awk '{print $1}' | grep -qx "$AGENT"; then
  log "librarian not registered — nothing to stop"
  exit 0
fi

# race guard: brief grace window so a watchdog that's about to create a task
# doesn't collide with our shutdown.
sleep "$GRACE_SECONDS"

INBOX_RAW="$("$AGB" inbox "$AGENT" 2>/dev/null || true)"
OPEN_COUNT="$(printf '%s\n' "$INBOX_RAW" | grep -cE '\[librarian-ingest\]' || true)"
OPEN_COUNT="${OPEN_COUNT:-0}"

if [[ "$OPEN_COUNT" -gt 0 ]]; then
  log "inbox not empty after grace ($OPEN_COUNT open) — abort shutdown"
  exit 0
fi

log "inbox empty — requesting stop"
if "$BRIDGE_CLI" agent stop "$AGENT" >>"$LOG" 2>&1; then
  log "librarian stopped"
  exit 0
fi

log "stop failed — leaving session for watchdog to retry"
exit 0
