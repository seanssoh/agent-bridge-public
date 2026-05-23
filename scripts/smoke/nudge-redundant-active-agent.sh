#!/usr/bin/env bash
# scripts/smoke/nudge-redundant-active-agent.sh — regression for issue
# #1099 (the #1014 §A follow-up).
#
# PR #1019 added a `nudge_redelivery_seconds`-based age gate to
# `cmd_daemon_step`, but the gate was wired to the "no prior nudge
# history" branch only:
#
#     if not last_nudged_ids and not has_new_queue_ids:
#         continue
#
# Three guard paths in the candidate scan bypassed it for any agent
# with prior nudge history — the steady state for any active dynamic
# agent that has ever been nudged before:
#
#   Path 1 — `is_ready_agent` short-circuits the idle gate at
#            bridge-queue.py:2172 ("not is_ready_agent and idle < t"),
#            so a ready-agents-file member enters the scan even at
#            idle_seconds=1.
#   Path 2 — the never-nudged guard above is False when last_nudge_key
#            is non-empty.
#   Path 3 — the cooldown / activity-advance guards rely on
#            `has_new_queue_ids`, which was computed only over ids not
#            already in `last_nudged_ids`. Fresh-only ids therefore
#            passed those guards too.
#
# Net effect on a v0.14.5-beta4 install (issue #1099 evidence):
#
#   2026-05-23T12:51:54  daemon  session_nudge_sent  agb-dev-claude
#   {"claimed":"0","idle_seconds":"1","post_status":"done",
#    "queued":"1","task_id":"5653",
#    "title":"ACTION REQUIRED — queued tasks (1)"}
#
#   task #5653 lifecycle was created 12:51:45 / claimed 12:51:52 /
#   done 12:51:53 — the redundant ACTION REQUIRED nudge fired ~1s
#   into the post-arrival grace window, after the agent had already
#   started processing the task.
#
# The #1099 fix widens the age gate from agent-level to task-level: a
# queued task younger than `nudge_redelivery_seconds` is not a fresh
# nudge trigger regardless of `last_nudge_key` state. This smoke pins
# all three guard paths against that invariant, plus the disable knob
# (`BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0` → pre-#1019 behavior).
#
# Footgun #11: tasks are created via the real CLI and DB seeds /
# backdating happen via standalone file-as-argv helpers under
# nudge-task-age-gate-helpers/ — no python3 heredoc-stdin, no `<<<`
# here-string (see scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="nudge-redundant-active-agent"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HELPER_DIR="$SCRIPT_DIR/nudge-task-age-gate-helpers"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-nudge-redundant.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
SNAPSHOT_ACTIVE="$TMP_DIR/snapshot-active.tsv"
SNAPSHOT_IDLE="$TMP_DIR/snapshot-idle.tsv"
READY_FILE="$TMP_DIR/ready-agents.txt"
export BRIDGE_TASK_DB="$DB"

REDELIVERY=60
THRESHOLD=120

ACTIVE_AGENT="ready-history-agent"     # ready-agents-file member, fresh activity
IDLE_AGENT="idle-history-agent"        # non-ready, idle past threshold

NOW="$(date +%s)"

# --- Snapshot 1: active agent (idle_seconds≈1, ready-agents member) ---
# Models the issue #1099 evidence — agb-dev-claude with idle_seconds:1
# entering the scan via Path 1 (is_ready_agent bypass).
ACTIVE_TS=$(( NOW - 1 ))
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\n'
  printf '%s\tclaude\t%s\t/tmp\t1\t%s\n' "$ACTIVE_AGENT" "$ACTIVE_AGENT" "$ACTIVE_TS"
} > "$SNAPSHOT_ACTIVE"

# --- Snapshot 2: idle non-ready agent (idle past threshold) ----------
# Path 2/3: enters the scan via the idle gate (idle_seconds ≥ threshold),
# carries prior nudge history past cooldown.
IDLE_ACTIVITY_TS=$(( NOW - 600 ))   # idle far past 120s
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\n'
  printf '%s\tclaude\t%s\t/tmp\t1\t%s\n' "$IDLE_AGENT" "$IDLE_AGENT" "$IDLE_ACTIVITY_TS"
} > "$SNAPSHOT_IDLE"

# Ready-agents file lists ACTIVE_AGENT only.
printf '%s\n' "$ACTIVE_AGENT" > "$READY_FILE"

# Initialize the queue DB (creates tasks + agent_state tables). The
# seed-agent-nudge-history helper writes directly to agent_state, so
# we need the schema present before we can seed prior nudge history.
# A throwaway create+cancel is the path of least resistance — it
# triggers ensure_schema() via connect() exactly as production does.
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$ACTIVE_AGENT" \
  --from requester \
  --title "schema init" \
  --body "init" \
  --format shell >"$TMP_DIR/init.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/init.sh"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$TASK_ID" --actor requester >/dev/null
unset TASK_ID

run_daemon_step() {
  local snapshot="$1"
  shift
  python3 "$REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$snapshot" \
    --idle-threshold "$THRESHOLD" \
    --ready-agents-file "$READY_FILE" \
    --format text \
    "$@"
}

# True iff $1 lists the given agent ($2) as a nudge candidate.
output_nudges_agent() {
  local out="$1"
  local agent="$2"
  printf '%s\n' "$out" | grep -qE "^${agent}[[:space:]]"
}

failed=0

# ============================================================
# Phase 1 — Path 1: is_ready_agent bypass + prior nudge history
# ============================================================
# Seed prior nudge history (past cooldown — 1800s back > 900s default).
# `last_nudge_key=99999` is an irrelevant stale id; it just has to be
# non-empty so the `not last_nudged_ids` guard would have been False
# under the pre-#1099 form.
python3 "$HELPER_DIR/seed-agent-nudge-history.py" "$DB" "$ACTIVE_AGENT" \
  "$(( NOW - 1800 ))" "99999"

# Push a fresh task — created_ts is NOW, well within the 60s window.
export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS="$REDELIVERY"
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$ACTIVE_AGENT" \
  --from requester \
  --title "fresh task — path 1" \
  --body "fresh body" \
  --format shell >"$TMP_DIR/create-out-p1.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-out-p1.sh"
task_id_p1="$TASK_ID"

OUT_P1="$(run_daemon_step "$SNAPSHOT_ACTIVE")"
if output_nudges_agent "$OUT_P1" "$ACTIVE_AGENT"; then
  echo "  FAIL  Path 1: ready-agent with prior nudge history emitted as candidate for a fresh task" >&2
  echo "        output: ${OUT_P1}" >&2
  failed=1
else
  echo "  PASS  Path 1: ready-agent + prior history + fresh task → no candidate"
fi

# Positive control: age the same task past the window and re-run; must
# emit. Confirms the suppression is age-driven, not a blanket skip.
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$task_id_p1"
OUT_P1_AGED="$(run_daemon_step "$SNAPSHOT_ACTIVE")"
if output_nudges_agent "$OUT_P1_AGED" "$ACTIVE_AGENT"; then
  echo "  PASS  Path 1: ready-agent emits candidate once the queued task ages past the window"
else
  echo "  FAIL  Path 1: ready-agent should emit candidate for aged queued task" >&2
  echo "        output: ${OUT_P1_AGED}" >&2
  failed=1
fi

# Clean up task to keep Phase 2 isolated.
python3 "$REPO_ROOT/bridge-queue.py" cancel "$task_id_p1" --actor requester >/dev/null

# ============================================================
# Phase 2 — Paths 2/3: non-ready idle agent + prior history
# ============================================================
python3 "$HELPER_DIR/seed-agent-nudge-history.py" "$DB" "$IDLE_AGENT" \
  "$(( NOW - 1800 ))" "88888"

python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$IDLE_AGENT" \
  --from requester \
  --title "fresh task — paths 2/3" \
  --body "fresh body" \
  --format shell >"$TMP_DIR/create-out-p2.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-out-p2.sh"
task_id_p2="$TASK_ID"

OUT_P2="$(run_daemon_step "$SNAPSHOT_IDLE")"
if output_nudges_agent "$OUT_P2" "$IDLE_AGENT"; then
  echo "  FAIL  Paths 2/3: idle non-ready agent + prior history + fresh task emitted as candidate" >&2
  echo "        output: ${OUT_P2}" >&2
  failed=1
else
  echo "  PASS  Paths 2/3: idle non-ready agent + prior history + fresh task → no candidate"
fi

# Positive control: age the task past the window.
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$task_id_p2"
OUT_P2_AGED="$(run_daemon_step "$SNAPSHOT_IDLE")"
if output_nudges_agent "$OUT_P2_AGED" "$IDLE_AGENT"; then
  echo "  PASS  Paths 2/3: idle non-ready agent emits candidate once aged"
else
  echo "  FAIL  Paths 2/3: idle non-ready agent should emit candidate for aged task" >&2
  echo "        output: ${OUT_P2_AGED}" >&2
  failed=1
fi

python3 "$REPO_ROOT/bridge-queue.py" cancel "$task_id_p2" --actor requester >/dev/null

# ============================================================
# Phase 3 — gate disabled (BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0)
# ============================================================
# With the gate off, even a fresh task at an agent with prior nudge
# history must fire (preserves pre-#1019 end-to-end behavior). Use the
# idle non-ready agent — its idle_seconds passes the gate naturally.
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$IDLE_AGENT" \
  --from requester \
  --title "fresh task — gate disabled" \
  --body "fresh body" \
  --format shell >"$TMP_DIR/create-out-p3.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-out-p3.sh"
task_id_p3="$TASK_ID"

BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0 \
  OUT_P3="$(run_daemon_step "$SNAPSHOT_IDLE")"
if output_nudges_agent "$OUT_P3" "$IDLE_AGENT"; then
  echo "  PASS  gate-off: fresh task with prior history fires (pre-#1019 restored)"
else
  echo "  FAIL  gate-off: fresh task with prior history should fire when redelivery=0" >&2
  echo "        output: ${OUT_P3}" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
