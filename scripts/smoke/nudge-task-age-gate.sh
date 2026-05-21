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

set -euo pipefail

SMOKE_NAME="nudge-task-age-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-nudge.XXXXXX")"
trap 'rm -f /tmp/agb-nudge-*.tmp 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

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

failed=0

# --- Phase 1: fresh task — must NOT be a nudge candidate -------------
# Insert a queued task whose created_ts is NOW (fresh).
python3 - "$DB" "$AGENT" "$NOW" <<'PY'
import sqlite3, sys
db, agent, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
conn = sqlite3.connect(db)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute(
    """CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
      assigned_to TEXT NOT NULL, created_by TEXT NOT NULL,
      priority TEXT NOT NULL DEFAULT 'normal',
      status TEXT NOT NULL DEFAULT 'queued',
      created_ts INTEGER NOT NULL, updated_ts INTEGER NOT NULL,
      body_text TEXT, body_path TEXT, claimed_by TEXT,
      claimed_ts INTEGER, lease_until_ts INTEGER, closed_ts INTEGER)"""
)
conn.execute(
    "INSERT INTO tasks (title, assigned_to, created_by, status, created_ts, updated_ts)"
    " VALUES ('fresh task', ?, 'smoke', 'queued', ?, ?)",
    (agent, now, now),
)
conn.commit()
conn.close()
PY

OUT_FRESH="$(run_daemon_step)"
if grep -qE "^${AGENT}[[:space:]]" <<<"$OUT_FRESH"; then
  echo "  FAIL  fresh task emitted as nudge candidate (should be gated)" >&2
  echo "        output: ${OUT_FRESH}" >&2
  failed=1
else
  echo "  PASS  fresh queued task not nudged within redelivery window"
fi

# --- Phase 2: age the task past the window — must BE a candidate -----
AGED_TS=$(( NOW - 600 ))   # 600s old, well past the 60s redelivery window
python3 - "$DB" "$AGED_TS" <<'PY'
import sqlite3, sys
db, aged = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
conn.execute("UPDATE tasks SET created_ts = ?, updated_ts = ?", (aged, aged))
conn.commit()
conn.close()
PY

OUT_AGED="$(run_daemon_step)"
if grep -qE "^${AGENT}[[:space:]]" <<<"$OUT_AGED"; then
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
