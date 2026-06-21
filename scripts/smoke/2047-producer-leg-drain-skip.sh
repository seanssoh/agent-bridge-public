#!/usr/bin/env bash
# scripts/smoke/2047-producer-leg-drain-skip.sh — producer-only legs skip the
# consumer inbox-auto-drain Stop hook (#2047). HIGH-RISK: the Stop-hook chain.
#
# THE BUG. A non-consuming "producer-only" sub/thread session only ENQUEUES a
# task to its parent main session and is transport-guarded off from
# `agb`/`agent-bridge` queue consumption. When it shares the main session's
# CLAUDE_CONFIG_DIR it inherits the main's consumer Stop hooks (including
# inbox-auto-drain.py) AND shares the main's BRIDGE_AGENT_ID. The drain
# decision keyed only on BRIDGE_AGENT_ID fires, sees the agent's queued work,
# and blocks demanding `agb` claim/done the producer leg structurally cannot
# perform → it loops instead of finishing quietly.
#
# THE FIX. compute_drain_decision detects a producer-only leg via the
# BRIDGE_AGENT_LEG marker (the dispatcher-set, non-consuming-leg signal named
# in the issue) and early-returns None (no block) so the leg Stops cleanly. A
# normal consumer main session (no marker) still gets the drain block —
# unchanged.
#
# This test pins, in an isolated BRIDGE_HOME (+ BRIDGE_ACTIVE_AGENT_DIR so the
# marker lands in the fixture tree, never the live runtime), with the SAME
# agent + the SAME queued task across both legs so the only variable is the
# producer-leg marker:
#   (a) producer-only leg (BRIDGE_AGENT_LEG=producer) + queued work
#         → Claude Stop emits NOTHING (skip, no drain demand).
#         → codex managed Stop emits {} (skip).
#   (b) consumer main session (no BRIDGE_AGENT_LEG) + the SAME queued work
#         → Claude Stop emits decision:block (drain demanded — UNCHANGED).
#   (c) MUTATION GUARD: with the producer marker set, the Claude leg MUST be
#       silent. If the producer-skip is reverted this leg falsely blocks → the
#       (a) assertion fails. The (b) assertion guards the inverse (a blanket
#       skip that drops the real consumer drain).
#   (d) alternate spellings of the marker (producer-only / non-consuming /
#       enqueue-only) also skip; an unrecognized value (e.g. consumer/main)
#       does NOT skip (defends the never-mis-skip-a-consumer invariant).
#
# Footgun #11: all queue mutation goes through the real CLI; no python3
# heredoc-stdin and no `<<<` here-string (see scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="2047-producer-leg-drain-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-2047.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"
export BRIDGE_HOME="$REPO_ROOT"
export BRIDGE_STATE_DIR="$TMP_DIR/state"
# Pin the per-agent runtime state root + audit log into the fixture so neither
# the loop-guard marker nor the producer-skip audit row ever lands in the
# operator's live ~/.agent-bridge tree.
export BRIDGE_ACTIVE_AGENT_DIR="$TMP_DIR/state/agents"
export BRIDGE_AUDIT_LOG="$TMP_DIR/audit.jsonl"
# Deterministic guard knobs (mirror 9780).
export BRIDGE_STOP_DRAIN_CAP=2
export BRIDGE_STOP_DRAIN_COOLDOWN=300

AGENT="producer-leg-tester"
export BRIDGE_AGENT_ID="$AGENT"
MARKER="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT/inbox-drain-state.json"

QUEUE() { python3 "$REPO_ROOT/bridge-queue.py" "$@"; }

# Claude Stop hook: BRIDGE_AGENT_LEG is read from the AMBIENT env, so each
# caller sets/unsets it inline. We DON'T export it globally — the consumer-leg
# phase needs it absent.
drain_claude() {
  printf '%s' '{}' | python3 "$REPO_ROOT/hooks/inbox-auto-drain.py" 2>/dev/null
}
drain_codex() {
  printf '%s' '{}' | python3 "$REPO_ROOT/hooks/check_inbox.py" --format codex 2>/dev/null
}

reset_marker() { rm -f "$MARKER" "$MARKER.tmp" 2>/dev/null || true; }

failed=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

# ============================================================
# Setup — one genuinely-actionable queued task for $AGENT.
# Both legs see the SAME row; the only variable is the marker.
# ============================================================
QUEUE create --to "$AGENT" --from bridge --title "enqueued by producer" --body "b" \
  --format shell >"$TMP_DIR/create.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create.sh"
TASK="$TASK_ID"

# ============================================================
# Phase (a) — producer-only leg → Claude Stop SKIPS (no block)
# ============================================================
reset_marker
OUT="$(BRIDGE_AGENT_LEG=producer drain_claude)"
if [[ -z "$OUT" ]]; then
  pass "producer-only leg (BRIDGE_AGENT_LEG=producer): Claude Stop SKIPS the drain (no demand)"
else
  fail "producer-only leg must NOT block — it can't drain (got: '${OUT}')"
fi
# And the loop-guard marker must NOT be written: the producer skip short-circuits
# BEFORE the marker read/init, so a producer leg never even touches guard state.
if [[ ! -f "$MARKER" ]]; then
  pass "producer-only leg: no guard marker written (skip happens before marker init)"
else
  fail "producer-only leg should not write a guard marker (path: ${MARKER})"
fi
# Observable: the skip emits a one-line audit row.
if [[ -f "$BRIDGE_AUDIT_LOG" ]] \
   && grep -q '"action": "stop_drain_producer_leg_skip"' "$BRIDGE_AUDIT_LOG"; then
  pass "producer-only leg: skip is observable (stop_drain_producer_leg_skip audit row)"
else
  fail "producer-only leg skip should emit an audit row (log: ${BRIDGE_AUDIT_LOG})"
fi

# codex managed Stop hook honours the same skip (emits {} for no-block).
reset_marker
# The Codex managed Stop contract emits EXACTLY {} for the no-block case
# (check_inbox.py --format codex), so assert {} strictly — an empty stdout would
# mean the hook took a different (silent) path than the codex no-block contract.
OUT="$(BRIDGE_AGENT_LEG=producer drain_codex | tr -d '[:space:]')"
if [[ "$OUT" == "{}" ]]; then
  pass "producer-only leg: codex managed Stop also SKIPS (emits {} per the codex no-block contract)"
else
  fail "codex managed Stop must emit {} (skip) for a producer leg (got: '${OUT}')"
fi

# ============================================================
# Phase (b) — consumer main session → Claude Stop STILL BLOCKS
# (no BRIDGE_AGENT_LEG marker in env; SAME queued task)
# ============================================================
reset_marker
# Defensive: make sure the marker is not leaking from a parent env.
unset BRIDGE_AGENT_LEG
OUT="$(drain_claude)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "claim the highest-priority"; then
  pass "consumer main session (no marker): Claude Stop STILL emits decision:block (drain preserved)"
else
  fail "consumer main session must still be told to drain (got: '${OUT}')"
fi
# A real consumer DOES initialise the loop-guard marker (atomic-persist-before-block).
if [[ -f "$MARKER" ]]; then
  pass "consumer main session: guard marker written (drain path fully exercised)"
else
  fail "consumer drain should write the guard marker (path: ${MARKER})"
fi

# ============================================================
# Phase (c) — explicit "consumer"/"main" values are NOT producer legs
# (defends the never-mis-skip-a-consumer invariant)
# ============================================================
for VAL in consumer main ""; do
  reset_marker
  OUT="$(BRIDGE_AGENT_LEG="$VAL" drain_claude)"
  if printf '%s' "$OUT" | grep -q '"decision": "block"'; then
    pass "BRIDGE_AGENT_LEG='${VAL}' is NOT a producer leg → consumer drain still blocks"
  else
    fail "BRIDGE_AGENT_LEG='${VAL}' must NOT be treated as producer-only (got: '${OUT}')"
  fi
done

# ============================================================
# Phase (d) — alternate producer spellings also skip
# ============================================================
for VAL in producer-only producer_only non-consuming enqueue-only; do
  reset_marker
  OUT="$(BRIDGE_AGENT_LEG="$VAL" drain_claude)"
  if [[ -z "$OUT" ]]; then
    pass "BRIDGE_AGENT_LEG='${VAL}' recognized as producer-only → drain skipped"
  else
    fail "BRIDGE_AGENT_LEG='${VAL}' should skip the drain (got: '${OUT}')"
  fi
done

# Cleanup the task so a re-run starts clean (best-effort).
QUEUE claim "$TASK" --agent "$AGENT" >/dev/null 2>&1 || true
QUEUE done "$TASK" --agent "$AGENT" --note "done" >/dev/null 2>&1 || true

if (( failed )); then
  echo "[smoke:${SMOKE_NAME}] FAILED" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
