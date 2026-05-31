#!/usr/bin/env bash
# scripts/smoke/1199-action-required-claimed-skip.sh — regression for
# issue #1199 (2026-06-01).
#
# THE BUG (operator's fresh repro). A `[task-complete]` task is delivered
# to an agent; the agent (or operator) runs `agb claim N`; and on the
# very next turn boundary the Stop hook (mark-idle.sh → check-inbox.py
# --format text) re-injects:
#
#   [Agent Bridge] 1 pending task(s) for <agent>.
#   Highest priority: Task #N [...] [task-complete] ...
#   ACTION REQUIRED: Use your Bash tool now ... claim the first one immediately.
#
# for the task the agent JUST claimed. "재넛지는 안 가져갈 때 하는 건데, 이미
# 가져갔는데 바로 하면 노이즈." Re-nudge is for when the agent did NOT pick the
# task up; firing immediately after a claim is pure noise.
#
# ROOT CAUSE. hooks/bridge_hook_common.py::queue_summary computed
#   pending = queued_count + claimed_count
# so a freshly-claimed task kept pending > 0 and re-fired the ACTION
# REQUIRED text nudge. (`blocked` was already excluded in PR #516/#518;
# only `claimed` remained.) The daemon-side ACTION-REQUIRED scan
# (bridge-queue.py::cmd_daemon_step + bridge-daemon-helpers.py::
# cmd_nudge_live_state) was already queued-only from #1099/#1106/#1252/
# #1322 — the residual #1199 lived in the HOOK path.
#
# THE FIX.
#   1. queue_summary returns queued-only `pending` (ACTION-REQUIRED
#      eligibility = genuinely-queued only). The text Stop-hook nudge
#      therefore never fires for a claimed/blocked task.
#   2. The "Highest priority" row is fetched with `find-open
#      --status-filter queued` so it can never cite a claimed/blocked
#      task even when one outranks the queued head by priority.
#   3. The codex Stop-hook anti-abandonment gate ("you still have open
#      claimed work — continue it, don't end the session") is preserved
#      separately via open_claimed_count / top_claimed_row. It is NOT an
#      ACTION REQUIRED nudge and never tells the agent to re-claim.
#
# This test pins, in an isolated BRIDGE_HOME:
#   (a) a genuinely-queued task IS ACTION-REQUIRED-eligible (text nudge
#       present + daemon-step candidate after the age gate);
#   (b) the operator's immediacy case — claim it → text nudge EMPTY and
#       the daemon-step scan produces NO candidate for it;
#   (c) a blocked task → no text nudge, no daemon-step candidate;
#   (d) codex Stop hook still blocks on a CLAIMED task ("continue the
#       claimed task") so excluding claimed from ACTION REQUIRED does not
#       let a session quietly abandon open claimed work;
#   (e) find-open --status-filter queued skips a higher-priority claimed
#       task and picks the queued head.
#
# Footgun #11: tasks are created/claimed/updated via the real CLI; the
# created_ts backdate reuses the standalone file-as-argv helper
# nudge-task-age-gate-helpers/backdate-task-created-ts.py — no python3
# heredoc-stdin, no `<<<` here-string (see scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="1199-action-required-claimed-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HELPER_DIR="$SCRIPT_DIR/nudge-task-age-gate-helpers"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1199.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
SNAPSHOT="$TMP_DIR/snapshot.tsv"
export BRIDGE_TASK_DB="$DB"
export BRIDGE_HOME="$REPO_ROOT"
export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=60

AGENT="claim-tester"
export BRIDGE_AGENT_ID="$AGENT"
THRESHOLD=120
NOW="$(date +%s)"

# Snapshot: one active agent, idle past the threshold (an agent parked at
# the prompt waiting for work — the normal state).
ACTIVITY_TS=$(( NOW - 600 ))
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\n'
  printf '%s\tclaude\t%s\t/tmp\t1\t%s\n' "$AGENT" "$AGENT" "$ACTIVITY_TS"
} > "$SNAPSHOT"

run_daemon_step() {
  python3 "$REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$SNAPSHOT" \
    --idle-threshold "$THRESHOLD" \
    --format text
}

# True iff $1 (daemon-step output) lists $AGENT as a nudge candidate.
daemon_step_nudges_agent() {
  printf '%s\n' "$1" | grep -qE "^${AGENT}[[:space:]]"
}

check_inbox_text() {
  printf '%s' '{}' | python3 "$REPO_ROOT/hooks/check_inbox.py" --format text 2>/dev/null
}

check_inbox_codex() {
  printf '%s' '{}' | python3 "$REPO_ROOT/hooks/check_inbox.py" --format codex 2>/dev/null
}

failed=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

# ============================================================
# Phase 1 — genuinely-queued task IS ACTION-REQUIRED-eligible
# ============================================================
# A [task-complete] task lands. Created fresh, then aged past the
# redelivery window so the daemon-step age gate lets it through.
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from bridge \
  --title "[task-complete] worker finished" \
  --body "completed_by: worker" \
  --format shell >"$TMP_DIR/create.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create.sh"
TASK="$TASK_ID"
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$TASK"

OUT="$(check_inbox_text)"
if printf '%s' "$OUT" | grep -q "ACTION REQUIRED"; then
  pass "queued task: text ACTION REQUIRED nudge fires"
else
  fail "queued task should produce the ACTION REQUIRED text nudge (got: '${OUT}')"
fi

OUT="$(run_daemon_step)"
if daemon_step_nudges_agent "$OUT"; then
  pass "queued task: daemon-step emits a nudge candidate (past age gate)"
else
  fail "queued task should be a daemon-step nudge candidate (got: '${OUT}')"
fi

# ============================================================
# Phase 2 — the immediacy bug: CLAIM it, must NOT re-nudge
# ============================================================
python3 "$REPO_ROOT/bridge-queue.py" claim "$TASK" --agent "$AGENT" >/dev/null

OUT="$(check_inbox_text)"
if [[ -z "$OUT" ]]; then
  pass "claimed task: NO immediate ACTION REQUIRED text re-nudge after claim"
else
  fail "claimed task must NOT re-nudge ACTION REQUIRED (got: '${OUT}')"
fi

OUT="$(run_daemon_step)"
if daemon_step_nudges_agent "$OUT"; then
  fail "claimed task must NOT be a daemon-step nudge candidate (got: '${OUT}')"
else
  pass "claimed task: daemon-step produces no nudge candidate"
fi

# Anti-abandonment: the codex Stop hook MUST still block on open claimed
# work ("continue the claimed task") — excluding claimed from ACTION
# REQUIRED must not let a session quietly end on open claimed work.
OUT="$(check_inbox_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"' \
   && printf '%s' "$OUT" | grep -q "continue the claimed task"; then
  pass "claimed task: codex Stop hook still blocks (anti-abandonment preserved)"
else
  fail "codex Stop hook should block 'continue the claimed task' on open claimed work (got: '${OUT}')"
fi

# ============================================================
# Phase 3 — blocked task: no ACTION REQUIRED anywhere
# ============================================================
python3 "$REPO_ROOT/bridge-queue.py" update "$TASK" --status blocked --note "waiting on X" >/dev/null

OUT="$(check_inbox_text)"
if [[ -z "$OUT" ]]; then
  pass "blocked task: NO ACTION REQUIRED text nudge"
else
  fail "blocked task must NOT produce ACTION REQUIRED text (got: '${OUT}')"
fi

OUT="$(run_daemon_step)"
if daemon_step_nudges_agent "$OUT"; then
  fail "blocked task must NOT be a daemon-step nudge candidate (got: '${OUT}')"
else
  pass "blocked task: daemon-step produces no nudge candidate"
fi

# codex Stop hook: blocked waits on external unblock, no claimed work →
# no block decision (empty {}).
OUT="$(check_inbox_codex)"
if printf '%s' "$OUT" | grep -q '"decision": "block"'; then
  fail "blocked-only queue should not block the codex Stop hook (got: '${OUT}')"
else
  pass "blocked task: codex Stop hook does not block (waits on external unblock)"
fi

# ============================================================
# Phase 4 — Highest-priority line never cites a claimed/blocked task
# ============================================================
# Close the prior task, then seed: one normal QUEUED + one urgent CLAIMED.
python3 "$REPO_ROOT/bridge-queue.py" update "$TASK" --status queued >/dev/null
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$TASK"

python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from bridge \
  --title "urgent claimed work" \
  --priority urgent \
  --body "x" \
  --format shell >"$TMP_DIR/create-urgent.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-urgent.sh"
URGENT="$TASK_ID"
python3 "$REPO_ROOT/bridge-queue.py" claim "$URGENT" --agent "$AGENT" >/dev/null

# Default find-open (no filter) would pick the urgent CLAIMED task.
DEFAULT_TOP="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$AGENT" --format id)"
QUEUED_TOP="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$AGENT" --status-filter queued --format id)"
CLAIMED_TOP="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$AGENT" --status-filter claimed --format id)"

if [[ "$DEFAULT_TOP" == "$URGENT" ]]; then
  pass "find-open default still ranks the urgent claimed task first (back-compat)"
else
  fail "find-open default should pick the urgent claimed task #${URGENT} (got #${DEFAULT_TOP})"
fi
if [[ "$QUEUED_TOP" == "$TASK" ]]; then
  pass "find-open --status-filter queued skips the claimed task, picks the queued head"
else
  fail "find-open --status-filter queued should pick queued #${TASK} (got #${QUEUED_TOP})"
fi
if [[ "$CLAIMED_TOP" == "$URGENT" ]]; then
  pass "find-open --status-filter claimed returns the claimed row (codex anti-abandon)"
else
  fail "find-open --status-filter claimed should pick #${URGENT} (got #${CLAIMED_TOP})"
fi

# And the text nudge's Highest-priority line must cite the QUEUED task,
# never the higher-priority claimed one.
OUT="$(check_inbox_text)"
if printf '%s' "$OUT" | grep -q "Highest priority: Task #${TASK} "; then
  pass "text nudge Highest-priority cites the queued task #${TASK}, not the urgent claimed one"
else
  fail "text nudge Highest-priority should cite queued #${TASK} (got: '${OUT}')"
fi

if (( failed )); then
  echo "[smoke:${SMOKE_NAME}] FAILED" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
