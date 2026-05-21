#!/usr/bin/env bash
# scripts/smoke/nudge-task-age-gate.sh — regression for issue #1014
# sub-bug A (2026-05-22).
#
# bridge-queue.py's daemon idle-nudge measured idle as agent-idle-
# duration (now - session_activity_ts). An agent parked idle past the
# 120s threshold — the normal state for an agent waiting for work — got
# an `ACTION REQUIRED` nudge on the very next daemon tick (~5s) for a
# task it was JUST pushed and is already acting on. The task-arrival
# push and the daemon idle-nudge are two uncoordinated mechanisms.
#
# Fix: the nudge scan gates a "new" queued task id on task-queued age.
# A queued task younger than the nudge redelivery window
# (BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS, default 60s) does not count
# as a fresh nudge trigger — the task-arrival push already covered it.
# Once the task ages past the window without progress, the nudge fires.
#
# This test pins:
#   1. A freshly-created queued task for an idle agent is NOT emitted as
#      a nudge candidate (within the redelivery window).
#   2. The SAME task, once its created_ts is aged past the window, IS
#      emitted as a nudge candidate.
#
# Footgun #11: the task is created via `bridge-queue.py create` and the
# created_ts backdate is done by the standalone file-as-argv helper
# nudge-task-age-gate-helpers/backdate-task-created-ts.py — no
# interpreter heredoc-stdin, no `<<<` here-string (see
# scripts/lint-heredoc-ban.sh).

set -euo pipefail

SMOKE_NAME="nudge-task-age-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HELPER_DIR="$SCRIPT_DIR/nudge-task-age-gate-helpers"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-nudge.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
SNAPSHOT="$TMP_DIR/snapshot.tsv"
export BRIDGE_TASK_DB="$DB"
export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=60

AGENT="nudge-tester"
IDLE_SECONDS=600          # idle far past the 120s idle threshold
THRESHOLD=120

# Snapshot: one active agent, idle past the threshold.
NOW="$(date +%s)"
ACTIVITY_TS=$(( NOW - IDLE_SECONDS ))
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
output_nudges_agent() {
  printf '%s\n' "$1" | grep -qE "^${AGENT}[[:space:]]"
}

failed=0

# --- Phase 1: fresh task — must NOT be a nudge candidate -------------
# Create a queued task via the real CLI; created_ts is NOW (fresh).
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from requester \
  --title "fresh task" \
  --body "fresh body" \
  --format shell >"$TMP_DIR/create-out.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-out.sh"
task_id="$TASK_ID"

OUT_FRESH="$(run_daemon_step)"
if output_nudges_agent "$OUT_FRESH"; then
  echo "  FAIL  fresh task emitted as nudge candidate (should be gated)" >&2
  echo "        output: ${OUT_FRESH}" >&2
  failed=1
else
  echo "  PASS  fresh queued task not nudged within redelivery window"
fi

# --- Phase 2: age the task past the window — must BE a candidate -----
# Backdate created_ts 600s into the past, well past the 60s window.
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$task_id"

OUT_AGED="$(run_daemon_step)"
if output_nudges_agent "$OUT_AGED"; then
  echo "  PASS  aged queued task IS nudged once past the redelivery window"
else
  echo "  FAIL  aged task not emitted as nudge candidate (should fire)" >&2
  echo "        output: ${OUT_AGED}" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
