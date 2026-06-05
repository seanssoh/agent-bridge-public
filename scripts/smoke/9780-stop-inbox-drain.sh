#!/usr/bin/env bash
# scripts/smoke/9780-stop-inbox-drain.sh — Stop/turn-end inbox auto-drain
# (#9780). HIGH-RISK: the Stop-hook chain. The §3 infinite-Stop-loop guard is
# the crux — a marker I/O bug or a never-resetting guard key would be an
# infinite Stop→block→Stop loop.
#
# THE GAP. The Claude/Codex Stop chain SURFACES the inbox as context but never
# BLOCKS to drain it, so a finished turn shows "you have pending tasks" yet
# still goes idle. The daemon nudge that should catch idle sessions is itself
# unstable (submit_lost_post_grace). Net: queued A2A/watchdog/memory work
# silently accumulates until an external push or a human wakes the agent.
#
# THE FIX. A new Stop step (hooks/inbox-auto-drain.py for Claude;
# check-inbox.py --format codex for Codex) emits {"decision":"block",...} when
# there is genuinely-actionable queue work, guarded against looping by a
# per-agent marker whose key is id+status(+updated_ts).
#
# This test pins, in an isolated BRIDGE_HOME (+ BRIDGE_ACTIVE_AGENT_DIR so the
# marker lands in the fixture tree, never the live runtime):
#   (1) queued task        → emits decision:block (auto-continue).
#   (2) empty/actionless   → exit 0, NO block, NO loop.
#   (3) same unchanged key → 2nd Stop does NOT re-block (marker dedup).
#   (4) progress (status   → key change RESETS the guard → blocks again.
#       change)
#   (5) consecutive cap    → stops blocking (allow idle).
#   (6) marker parse fail  → fail-open exit 0 (no block).
#   (7) marker write fail  → fail-open exit 0 (no block).
#   (8) queue error        → fail-open exit 0.
#   (9) stop_hook_active   → exit 0 (never stack on a prior chain block).
#  (10) codex managed hook → check-inbox.py --format codex drives the same drain
#       + same guard.
#  (11) daemon nudge-      → last_nudge_ts + last_nudge_key updated for the
#       suppression stamp     queued set, nudge_fail_count NOT incremented.
#  (12) #1199 retained     → queued-only ACTION REQUIRED stays queued-only;
#       claimed-work Stop behavior explicitly tested.
#
# Footgun #11: all queue mutation goes through the real CLI; no python3
# heredoc-stdin and no `<<<` here-string (see scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="9780-stop-inbox-drain"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-9780.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"
export BRIDGE_HOME="$REPO_ROOT"
export BRIDGE_STATE_DIR="$TMP_DIR/state"
# Pin the per-agent runtime state root into the fixture so the loop-guard
# marker NEVER lands in the operator's live ~/.agent-bridge tree. The hook
# resolves the marker via bridge_active_agent_dir() which honours this var
# first (matches bridge-lib.sh:BRIDGE_ACTIVE_AGENT_DIR).
export BRIDGE_ACTIVE_AGENT_DIR="$TMP_DIR/state/agents"
# Deterministic guard knobs.
export BRIDGE_STOP_DRAIN_CAP=2
export BRIDGE_STOP_DRAIN_COOLDOWN=300

AGENT="drain-tester"
export BRIDGE_AGENT_ID="$AGENT"
MARKER="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT/inbox-drain-state.json"

QUEUE() { python3 "$REPO_ROOT/bridge-queue.py" "$@"; }

drain_claude() {
  # $1 = event JSON (default {})
  printf '%s' "${1:-\{\}}" | python3 "$REPO_ROOT/hooks/inbox-auto-drain.py" 2>/dev/null
}
drain_codex() {
  printf '%s' "${1:-\{\}}" | python3 "$REPO_ROOT/hooks/check_inbox.py" --format codex 2>/dev/null
}
check_inbox_text() {
  printf '%s' '{}' | python3 "$REPO_ROOT/hooks/check_inbox.py" --format text 2>/dev/null
}

reset_marker() { rm -f "$MARKER" "$MARKER.tmp" 2>/dev/null || true; }

failed=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

# ============================================================
# Phase 1 — queued task → decision:block (auto-continue)
# ============================================================
QUEUE create --to "$AGENT" --from bridge --title "drain me" --body "b" \
  --format shell >"$TMP_DIR/create.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create.sh"
TASK="$TASK_ID"
reset_marker

OUT="$(drain_claude)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "claim the highest-priority"; then
  pass "queued task: Claude Stop emits decision:block (auto-continue)"
else
  fail "queued task should emit decision:block (got: '${OUT}')"
fi

# Marker must exist AFTER the block (atomic-persist-before-block).
if [[ -f "$MARKER" ]]; then
  pass "queued task: guard marker written (atomic-persist-before-block)"
else
  fail "guard marker should exist after a block (path: ${MARKER})"
fi

# ============================================================
# Phase 2 — same unchanged key on 2nd Stop → does NOT re-block
# ============================================================
OUT="$(drain_claude)"
if [[ -z "$OUT" ]]; then
  pass "same unchanged key: 2nd Stop does NOT re-block (marker dedup)"
else
  fail "2nd Stop on same unchanged task must NOT re-block (got: '${OUT}')"
fi

# ============================================================
# Phase 3 — progress (status change) RESETS the guard
# ============================================================
# Claim the task: id+status changes → key changes → guard resets → blocks
# again (now on the claimed anti-abandonment path).
QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
OUT="$(drain_claude)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "claimed work"; then
  pass "progress (claim → status change) RESETS the guard → blocks on claimed work"
else
  fail "a status change should reset the guard and re-block (got: '${OUT}')"
fi

# ============================================================
# Phase 4 — #1199 retained: claimed-only is NOT an ACTION REQUIRED text nudge
# ============================================================
# The task is now claimed. The TEXT nudge (queued-only ACTION REQUIRED) must be
# empty — claimed work never fires the queued-only re-nudge (issue #1199).
OUT="$(check_inbox_text)"
if [[ -z "$OUT" ]]; then
  pass "#1199 retained: claimed task does NOT fire the queued-only ACTION REQUIRED text nudge"
else
  fail "claimed task must NOT fire ACTION REQUIRED text nudge (got: '${OUT}')"
fi

# ...but the Stop drain still BLOCKS on open claimed work (anti-abandonment),
# verified in Phase 3. Re-confirm via the codex managed hook below.

# ============================================================
# Phase 5 — empty/actionless queue → exit 0, NO block, NO loop
# ============================================================
# $TASK is claimed by $AGENT (Phase 3) → close it directly.
QUEUE done "$TASK" --agent "$AGENT" --note "done" >/dev/null
reset_marker
OUT="$(drain_claude)"
if [[ -z "$OUT" ]]; then
  pass "empty queue: Claude Stop does NOT block (never loop on empty)"
else
  fail "empty queue must NOT block (got: '${OUT}')"
fi
# And the marker must NOT be written when there is nothing actionable.
if [[ ! -f "$MARKER" ]]; then
  pass "empty queue: no guard marker written (idle quietly)"
else
  fail "empty queue should not write a guard marker"
fi

# ============================================================
# Phase 6 — consecutive cap → stops blocking (allow idle)
# ============================================================
# Fresh queued task; the key stays the SAME unchanged key across Stops (status
# stays 'queued'). To exercise the cap rather than the cooldown we set cooldown
# to 0 for this phase so only the consecutive cap gates. With CAP=2 the 1st and
# 2nd Stops block, the 3rd idles.
QUEUE create --to "$AGENT" --from bridge --title "cap me" --body "b" \
  --format shell >"$TMP_DIR/create-cap.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-cap.sh"
CAPTASK="$TASK_ID"
reset_marker
(
  export BRIDGE_STOP_DRAIN_COOLDOWN=0
  o1="$(drain_claude)"; o2="$(drain_claude)"; o3="$(drain_claude)"
  printf '%s' "$o1" | grep -q '"decision": "block"' && echo "b1=block" >"$TMP_DIR/cap2.out" || echo "b1=idle" >"$TMP_DIR/cap2.out"
  printf '%s' "$o2" | grep -q '"decision": "block"' && echo "b2=block" >>"$TMP_DIR/cap2.out" || echo "b2=idle" >>"$TMP_DIR/cap2.out"
  printf '%s' "$o3" | grep -q '"decision": "block"' && echo "b3=block" >>"$TMP_DIR/cap2.out" || echo "b3=idle" >>"$TMP_DIR/cap2.out"
)
if grep -q "^b1=block$" "$TMP_DIR/cap2.out" \
   && grep -q "^b2=block$" "$TMP_DIR/cap2.out" \
   && grep -q "^b3=idle$" "$TMP_DIR/cap2.out"; then
  pass "consecutive cap (CAP=2): blocks twice then idles (runaway backstop)"
else
  fail "cap should block CAP times then idle (got: $(tr '\n' ' ' <"$TMP_DIR/cap2.out"))"
fi
QUEUE claim "$CAPTASK" --agent "$AGENT" >/dev/null
QUEUE done "$CAPTASK" --agent "$AGENT" --note "done" >/dev/null

# ============================================================
# Phase 7 — stop_hook_active → exit 0 (never stack)
# ============================================================
QUEUE create --to "$AGENT" --from bridge --title "active guard" --body "b" \
  --format shell >"$TMP_DIR/create-active.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-active.sh"
ACTASK="$TASK_ID"
reset_marker
OUT="$(drain_claude '{"stop_hook_active": true}')"
if [[ -z "$OUT" ]]; then
  pass "stop_hook_active: Claude Stop does NOT block (never stack on a prior block)"
else
  fail "stop_hook_active must short-circuit to no-block (got: '${OUT}')"
fi
# And codex honours it too.
OUT="$(drain_codex '{"stop_hook_active": true}')"
if printf '%s' "$OUT" | grep -q '"decision": "block"'; then
  fail "codex stop_hook_active must not block (got: '${OUT}')"
else
  pass "stop_hook_active: codex managed hook also short-circuits"
fi

# ============================================================
# Phase 8 — marker parse failure → fail-open exit 0 (no block)
# ============================================================
reset_marker
mkdir -p "$(dirname "$MARKER")"
printf 'this is not json {' >"$MARKER"
OUT="$(drain_claude)"
if [[ -z "$OUT" ]]; then
  pass "marker parse failure: fail-open, Claude Stop does NOT block"
else
  fail "a corrupt marker must fail open (no block) (got: '${OUT}')"
fi

# ============================================================
# Phase 9 — marker WRITE failure → fail-open exit 0 (no block)
# ============================================================
# Make the marker dir unwritable so the atomic write fails; the hook must
# fail open (NOT block) because it could not persist the guard state.
reset_marker
mkdir -p "$(dirname "$MARKER")"
chmod 000 "$(dirname "$MARKER")"
OUT="$(drain_claude)"
chmod 755 "$(dirname "$MARKER")"
if [[ -z "$OUT" ]]; then
  pass "marker write failure: fail-open, Claude Stop does NOT block (no marker → no loop)"
else
  fail "a marker write failure must fail open (no block) (got: '${OUT}')"
fi
QUEUE claim "$ACTASK" --agent "$AGENT" >/dev/null
QUEUE done "$ACTASK" --agent "$AGENT" --note "done" >/dev/null

# ============================================================
# Phase 10 — queue error → fail-open exit 0
# ============================================================
# Point the task DB at an unreadable path so queue_summary's subprocess errors.
(
  export BRIDGE_TASK_DB="$TMP_DIR/nonexistent-dir/does/not/exist.db"
  reset_marker
  OUT="$(drain_claude)"
  if [[ -z "$OUT" ]]; then
    echo "queue-error=ok" >"$TMP_DIR/qerr.out"
  else
    echo "queue-error=block:${OUT}" >"$TMP_DIR/qerr.out"
  fi
)
if grep -q "^queue-error=ok$" "$TMP_DIR/qerr.out"; then
  pass "queue error: fail-open, Claude Stop does NOT block"
else
  fail "a queue error must fail open (no block) ($(cat "$TMP_DIR/qerr.out"))"
fi

# ============================================================
# Phase 11 — codex managed hook drives the same drain + guard
# ============================================================
QUEUE create --to "$AGENT" --from bridge --title "codex drain" --body "b" \
  --format shell >"$TMP_DIR/create-codex.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-codex.sh"
CXTASK="$TASK_ID"
reset_marker
OUT="$(drain_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "queued work is waiting"; then
  pass "codex managed hook: queued task → decision:block (same shared drain)"
else
  fail "codex managed hook should block on queued work (got: '${OUT}')"
fi
# Same shared guard: a 2nd codex Stop on the unchanged key does NOT re-block.
OUT="$(drain_codex)"
if [[ "$OUT" == "{}" || -z "$OUT" ]]; then
  pass "codex managed hook: 2nd Stop on unchanged key does NOT re-block (shared guard)"
else
  fail "codex 2nd Stop on unchanged key must not re-block (got: '${OUT}')"
fi
# Anti-abandonment: claimed work still blocks the codex Stop (#1199 distinct path).
QUEUE claim "$CXTASK" --agent "$AGENT" >/dev/null
reset_marker
OUT="$(drain_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "continue the claimed task"; then
  pass "codex managed hook: open claimed work still blocks (anti-abandonment, #1199 path)"
else
  fail "codex managed hook should block 'continue the claimed task' (got: '${OUT}')"
fi

# ============================================================
# Phase 12 — daemon nudge-suppression stamp (no fail-count bump)
# ============================================================
# Re-queue so the drain takes the queued path and stamps last_nudge_key for the
# queued id. Read agent_state via the public `agb status`-style summary? The
# stamp is internal; assert it via the find-open helper + a direct check that
# the next daemon-step would suppress. We read the stamped fields through the
# CLI's own daemon nudge gate: a fresh daemon-step right after the stamp must
# NOT emit a nudge for this agent (last_nudge_ts >= activity, same key).
QUEUE update "$CXTASK" --status queued >/dev/null
reset_marker
SNAPSHOT="$TMP_DIR/snapshot.tsv"
NOW="$(date +%s)"
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\n'
  printf '%s\tclaude\t%s\t/tmp\t1\t%s\n' "$AGENT" "$AGENT" "$(( NOW - 600 ))"
} >"$SNAPSHOT"
# Drive the drain (this writes the self-continue stamp).
OUT="$(drain_claude)"
if printf '%s' "$OUT" | grep -q '"decision": "block"'; then
  pass "nudge-suppression precondition: drain blocked on the re-queued task"
else
  fail "drain should block to write the suppression stamp (got: '${OUT}')"
fi
# Verify nudge_fail_count did NOT increment (stays 0). We assert it via a
# second self-continue + a sentinel: note-self-continue must keep fail_count 0
# even when called repeatedly. Probe through a tiny standalone reader helper.
FAILCOUNT="$(python3 "$SCRIPT_DIR/9780-stop-inbox-drain-helpers/read-nudge-state.py" "$DB" "$AGENT")"
# read-nudge-state prints: "<last_nudge_ts> <nudge_fail_count> <last_nudge_key>"
NUDGE_FAIL="$(printf '%s' "$FAILCOUNT" | awk '{print $2}')"
NUDGE_KEY="$(printf '%s' "$FAILCOUNT" | awk '{print $3}')"
if [[ "$NUDGE_FAIL" == "0" ]]; then
  pass "nudge-suppression stamp: nudge_fail_count NOT incremented (stays 0)"
else
  fail "self-continue stamp must NOT bump nudge_fail_count (got: '${NUDGE_FAIL}')"
fi
if [[ "$NUDGE_KEY" == "$CXTASK" ]]; then
  pass "nudge-suppression stamp: last_nudge_key set to the queued id (${CXTASK})"
else
  fail "last_nudge_key should be the queued id ${CXTASK} (got: '${NUDGE_KEY}')"
fi
# And the daemon-step must now suppress a concurrent nudge for the same queue.
DSTEP="$(QUEUE daemon-step --snapshot "$SNAPSHOT" --idle-threshold 120 --format text)"
if printf '%s\n' "$DSTEP" | grep -qE "^${AGENT}[[:space:]]"; then
  fail "daemon-step must NOT nudge after a self-continue stamp (got: '${DSTEP}')"
else
  pass "daemon double-submit avoided: daemon-step suppresses the concurrent nudge"
fi

if (( failed )); then
  echo "[smoke:${SMOKE_NAME}] FAILED" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
