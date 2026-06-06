#!/usr/bin/env bash
# scripts/smoke/1596-stop-drain-cron-dispatch.sh — Stop drain skips daemon-owned
# `[cron-dispatch]` work (#1596). HIGH-RISK: the Stop-hook chain re-entry
# decision (every Claude/Codex turn-end).
#
# THE GAP. The shared Stop drain (hooks/bridge_hook_common.py::drain_top_actionable,
# consumed by BOTH check-inbox.py --format codex AND inbox-auto-drain.py) blocked
# the model for ANY open queued/claimed row — including daemon-owned
# `[cron-dispatch]` rows the bridge daemon owns and closes itself. The model woke
# only to find nothing to do (observed: `#10352 [cron-dispatch] picker-sweep`),
# burning a turn.
#
# THE FIX. _is_daemon_owned_cron_dispatch(row) excludes a row whose title starts
# with `[cron-dispatch]` OR whose created_by starts with `cron:`, with a
# `[cron-followup]`-title carve-out (real follow-up still blocks). The drain
# iterates the FULL queued/claimed list (find-open --all) and picks the top
# REMAINING actionable row (a real task behind a cron row still wins), then
# re-confirms that row still open as late as practical and FAILS OPEN if it
# vanished.
#
# This test pins, in an isolated BRIDGE_HOME (+ BRIDGE_ACTIVE_AGENT_DIR so the
# loop-guard marker lands in the fixture tree, never the live runtime), the
# acceptance matrix:
#   (a) empty queue                       → no block (both engines).
#   (b) real queued task                  → block.
#   (c) real claimed unfinished           → block (anti-abandonment).
#   (d) daemon `[cron-dispatch]` claimed  → NO block (daemon owns/closes it).
#   (e) `[cron-dispatch]` + real behind it → block on the REAL task, not the cron.
#   (f) `[cron-followup]`                 → block (actionable carve-out, even
#                                            though created_by starts `cron:`).
#   (g) race: selected row done before    → fail open (no block, no error).
#       block emission
#   (h) both engines over the same states → identical actionable verdicts.
#
# Footgun #11: all queue mutation goes through the real CLI; no python3
# heredoc-stdin and no `<<<` here-string. The case-(g) race needs a
# selected-row-vanishes hook, driven through a file-as-argv probe
# (1596-stop-drain-cron-dispatch-helpers/race-probe.py) — NOT an inline
# heredoc-in-capture (see scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="1596-stop-drain-cron-dispatch"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1596.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"
export BRIDGE_HOME="$REPO_ROOT"
export BRIDGE_STATE_DIR="$TMP_DIR/state"
# Pin the per-agent runtime state root into the fixture so the loop-guard marker
# NEVER lands in the operator's live ~/.agent-bridge tree.
export BRIDGE_ACTIVE_AGENT_DIR="$TMP_DIR/state/agents"
# Deterministic guard knobs (irrelevant to the predicate, but keep the marker
# from suppressing fresh-marker assertions).
export BRIDGE_STOP_DRAIN_CAP=3
export BRIDGE_STOP_DRAIN_COOLDOWN=300

AGENT="drain-cron-tester"
export BRIDGE_AGENT_ID="$AGENT"
MARKER="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT/inbox-drain-state.json"

QUEUE() { python3 "$REPO_ROOT/bridge-queue.py" "$@"; }

drain_claude() {
  printf '%s' "${1:-\{\}}" | python3 "$REPO_ROOT/hooks/inbox-auto-drain.py" 2>/dev/null
}
drain_codex() {
  printf '%s' "${1:-\{\}}" | python3 "$REPO_ROOT/hooks/check_inbox.py" --format codex 2>/dev/null
}

reset_marker() { rm -f "$MARKER" "$MARKER.tmp" 2>/dev/null || true; }

# Create a task, set TASK to its id. Optional 3rd arg = created_by (default
# "operator"). Goes through the real CLI shell-format so we never parse JSON in
# bash.
mk() {
  local title="$1" from="${2:-operator}"
  QUEUE create --to "$AGENT" --from "$from" --title "$title" --body "b" \
    --format shell >"$TMP_DIR/create.sh"
  # shellcheck disable=SC1090
  source "$TMP_DIR/create.sh"
  TASK="$TASK_ID"
}

# Close every open task assigned to the agent so each phase starts from a clean
# queue. Reads ids via the CLI's --all JSON through a file-as-argv id reader
# (no heredoc, no jq dependency).
close_all() {
  local ids
  # find-open --all returns rc=1 on an EMPTY queue (prints `[]`); under
  # `set -o pipefail` that would abort the smoke. Tolerate it — an empty queue
  # is a valid (and common) starting state for a phase.
  ids="$( { QUEUE find-open --agent "$AGENT" --all --format json || true; } \
    | python3 "$SCRIPT_DIR/1596-stop-drain-cron-dispatch-helpers/print-open-ids.py")"
  local id
  for id in $ids; do
    QUEUE claim "$id" --agent "$AGENT" >/dev/null 2>&1 || true
    QUEUE done "$id" --agent "$AGENT" --note "smoke cleanup" >/dev/null 2>&1 || true
  done
}

failed=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

# Assert the codex engine BLOCKS (decision:block) on the current seeded state.
assert_codex_block() {
  local label="$1" out
  reset_marker
  out="$(drain_codex)"
  if printf '%s' "$out" | grep -q '"decision": "block"'; then
    pass "$label (codex blocks)"
  else
    fail "$label — codex should block (got: '${out}')"
  fi
}
# Assert the codex engine does NOT block (emits the no-decision {}).
assert_codex_noblock() {
  local label="$1" out
  reset_marker
  out="$(drain_codex)"
  if [[ "$out" == "{}" ]]; then
    pass "$label (codex no-block {})"
  else
    fail "$label — codex should NOT block (got: '${out}')"
  fi
}
# Assert the Claude engine BLOCKS (decision:block) on the current seeded state.
assert_claude_block() {
  local label="$1" out
  reset_marker
  out="$(drain_claude)"
  if printf '%s' "$out" | grep -q '"decision": "block"'; then
    pass "$label (claude blocks)"
  else
    fail "$label — claude should block (got: '${out}')"
  fi
}
# Assert the Claude engine does NOT block (emits nothing / exit 0 silent).
assert_claude_noblock() {
  local label="$1" out
  reset_marker
  out="$(drain_claude)"
  if [[ -z "$out" ]]; then
    pass "$label (claude no-block silent)"
  else
    fail "$label — claude should NOT block (got: '${out}')"
  fi
}

# ============================================================
# (a) empty queue → no block (both engines)
# ============================================================
close_all
assert_codex_noblock  "(a) empty queue"
assert_claude_noblock "(a) empty queue"

# ============================================================
# (b) real queued task → block (both engines)
# ============================================================
close_all
mk "real user work" "operator"
assert_codex_block  "(b) real queued task"
assert_claude_block "(b) real queued task"

# ============================================================
# (c) real claimed unfinished → block (anti-abandonment)
# ============================================================
close_all
mk "real claimed work" "operator"
QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
assert_codex_block  "(c) real claimed unfinished"
assert_claude_block "(c) real claimed unfinished"

# ============================================================
# (d) daemon [cron-dispatch] claimed-only → NO block (both engines)
# ============================================================
close_all
mk "[cron-dispatch] picker-sweep (slot1)" "cron:picker-sweep"
QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
assert_codex_noblock  "(d) daemon [cron-dispatch] claimed-only"
assert_claude_noblock "(d) daemon [cron-dispatch] claimed-only"

# (d') REGRESSION GUARD (codex r1 finding #1): a real `[picker-sweep]`
# notification task is filed by a `cron:`-prefixed actor
# (scripts/picker-sweep.sh: --from "cron:picker-sweep") but is NOT a
# `[cron-dispatch]` row and is NOT daemon-closed — it MUST still block. The
# title is the SSOT; created_by `cron:` alone must NOT swallow it. A future
# patch that re-broadens the predicate to `created_by.startswith("cron:")`
# OR-rule on a TITLED row would regress this.
close_all
mk "[picker-sweep] 3 agent(s) auto-unstuck from interactive picker" "cron:picker-sweep"
assert_codex_block  "(d') real [picker-sweep] task (created_by=cron:) still blocks"
assert_claude_block "(d') real [picker-sweep] task (created_by=cron:) still blocks"

# (d'') the `created_by=cron:` rule is a DEFENSIVE FALLBACK for an untitled row
# only. A real cron-actor task ALWAYS carries a title, so this fallback never
# swallows genuine work; we cannot easily seed a blank title through the CLI
# (create rejects empty titles), so the untitled-fallback behaviour is pinned at
# the unit level instead — see _is_daemon_owned_cron_dispatch's direct probes in
# the (g) race helper and the predicate docstring.

# ============================================================
# (e) [cron-dispatch] + a real task behind it → block on the REAL task
# ============================================================
# (e1) cron-dispatch QUEUED (lower id) + real QUEUED behind → block cites real.
close_all
mk "[cron-dispatch] sweepq (slot1)" "cron:sweepq"; CRON_ID="$TASK"
mk "real queued behind cron" "operator"; REAL_ID="$TASK"
reset_marker
OUT="$(drain_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "real queued behind cron" \
   && ! printf '%s' "$OUT" | grep -q "cron-dispatch"; then
  pass "(e1) cron-dispatch queued + real queued behind → block on the REAL task (#${REAL_ID}, not #${CRON_ID})"
else
  fail "(e1) should block on the real queued task, never the cron row (got: '${OUT}')"
fi

# (e2) cron-dispatch CLAIMED + real CLAIMED behind → claimed path filters too.
close_all
mk "[cron-dispatch] sweepc (slot1)" "cron:sweepc"; QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
mk "real claimed behind cron" "operator"; QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
reset_marker
OUT="$(drain_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "real claimed behind cron" \
   && ! printf '%s' "$OUT" | grep -q "cron-dispatch"; then
  pass "(e2) cron-dispatch claimed + real claimed behind → block on the REAL claimed task"
else
  fail "(e2) should block on the real claimed task, never the cron row (got: '${OUT}')"
fi

# (e3) queued is ALL cron-dispatch but a real CLAIMED exists → fall through to
# the claimed anti-abandonment path (queued-all-daemon must NOT short-circuit
# the claimed path).
close_all
mk "[cron-dispatch] qonly (slot1)" "cron:qonly"
mk "real claimed fallthrough" "operator"; QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
reset_marker
OUT="$(drain_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "real claimed fallthrough"; then
  pass "(e3) queued all-cron + real claimed → falls through to claimed, blocks on the real task"
else
  fail "(e3) queued-all-daemon should fall through to the claimed real task (got: '${OUT}')"
fi

# ============================================================
# (f) [cron-followup] → block (actionable carve-out)
# ============================================================
# Note: the daemon files cron-followup with created_by="cron:<source-agent>",
# so the title carve-out MUST win over the created_by `cron:` rule.
close_all
mk "[cron-followup] nightly (run=abc123)" "cron:nightly"
assert_codex_block  "(f) [cron-followup] (created_by=cron:)"
assert_claude_block "(f) [cron-followup] (created_by=cron:)"

# ============================================================
# (g) race: selected row becomes done before block emission → fail open
# ============================================================
# Seed a real queued task, then drive the drain through the race probe which
# patches _row_still_open to report the row gone right before the block. The
# drain must return None (no block) and must NOT raise / emit an error banner.
close_all
mk "racey vanishing task" "operator"
reset_marker
RACE_OUT="$(python3 "$SCRIPT_DIR/1596-stop-drain-cron-dispatch-helpers/race-probe.py" "$AGENT" 2>"$TMP_DIR/race.err" || true)"
if [[ "$RACE_OUT" == "NONE" ]] && [[ ! -s "$TMP_DIR/race.err" ]]; then
  pass "(g) race: selected row gone before block → fail open (None, no block, no error)"
else
  fail "(g) race must fail open with no block / no error (out='${RACE_OUT}', err='$(cat "$TMP_DIR/race.err")')"
fi

# And end-to-end through the real engine: close the row out-of-band BEFORE the
# Stop hook runs; the late re-check must catch it and emit no block.
close_all
mk "closed before stop" "operator"
QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
QUEUE done "$TASK" --agent "$AGENT" --note "closed out-of-band" >/dev/null
assert_codex_noblock  "(g') row closed before Stop runs"
assert_claude_noblock "(g') row closed before Stop runs"

# ============================================================
# (i) queue READ failure → fail open (codex r1 finding #2)
# ============================================================
# A genuine queue read failure (DB open/SQLite error) exits nonzero with EMPTY
# stdout (+ traceback on stderr) — distinct from an empty result, which prints
# the literal `[]`. _open_rows_for must map empty-stdout to a READ ERROR (None →
# fail open: do NOT block, do NOT fall through to the claimed path), NOT to an
# empty list. Point BRIDGE_TASK_DB at an unreadable path and confirm no block /
# no error banner from BOTH engines.
(
  export BRIDGE_TASK_DB="$TMP_DIR/nonexistent-dir/does/not/exist.db"
  reset_marker
  cx="$(drain_codex)"
  reset_marker
  clx="$(drain_claude)"
  if [[ "$cx" == "{}" && -z "$clx" ]]; then
    echo "ok" >"$TMP_DIR/readfail.out"
  else
    echo "block: codex='${cx}' claude='${clx}'" >"$TMP_DIR/readfail.out"
  fi
)
if grep -q "^ok$" "$TMP_DIR/readfail.out"; then
  pass "(i) queue read failure → fail open (codex {} + claude silent, no fall-through, no banner)"
else
  fail "(i) a queue read failure must fail open, not block / fall through ($(cat "$TMP_DIR/readfail.out"))"
fi

# ============================================================
# (h) both engines: identical actionable verdicts over the same states
# ============================================================
# Drive BOTH engines over each canonical state with a fresh marker and assert
# their block / no-block verdicts agree (single shared predicate; engines differ
# only in OUTPUT shape — codex {} vs claude silent).
parity_state() {
  # $1 = label, $2 = expected verdict (block|noblock)
  local label="$1" expect="$2" cx clx cv cl
  reset_marker; cx="$(drain_codex)"
  reset_marker; clx="$(drain_claude)"
  printf '%s' "$cx" | grep -q '"decision": "block"' && cv=block || cv=noblock
  printf '%s' "$clx" | grep -q '"decision": "block"' && cl=block || cl=noblock
  if [[ "$cv" == "$cl" && "$cv" == "$expect" ]]; then
    pass "(h) parity ${label}: both engines agree → ${cv}"
  else
    fail "(h) parity ${label}: codex=${cv} claude=${cl} expected=${expect} (cx='${cx}' clx='${clx}')"
  fi
}
close_all
parity_state "empty" "noblock"
close_all; mk "parity real queued" "operator"
parity_state "real-queued" "block"
close_all; mk "[cron-dispatch] parity (slot1)" "cron:parity"; QUEUE claim "$TASK" --agent "$AGENT" >/dev/null
parity_state "cron-dispatch-claimed" "noblock"
close_all; mk "[cron-followup] parity (run=z)" "cron:parity"
parity_state "cron-followup" "block"

if (( failed )); then
  echo "[smoke:${SMOKE_NAME}] FAILED" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
