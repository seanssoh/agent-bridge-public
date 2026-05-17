#!/usr/bin/env bash
# scripts/smoke/agent-delete-task-gc.sh — refs #4797.
#
# Before this fix, `agent-bridge agent delete <name> --orphan-tasks` left
# every queued/claimed task assigned to the deleted agent in status
# `blocked` (an open status). Those rows accumulated in `agb task
# summary` for the now-defunct agent name and never aged out — the
# operator host had 27-day-old crm-cli, 22-day admin-smoke, etc. ghost
# rows.
#
# After the fix, `--orphan-tasks` closes every open row (queued /
# claimed / blocked) assigned to the agent to terminal status
# `cancelled` with `closed_ts` set, and emits a `cancelled` task_event
# whose note records the trigger.
#
# Cases:
#   C1. agent delete --orphan-tasks closes one queued, one claimed, one
#       blocked task to `cancelled` with `closed_ts` populated, leaves
#       `[cron-dispatch]%` rows untouched, and writes a `cancelled`
#       task_event whose note mentions `--orphan-tasks`.
#   C2. agent delete WITHOUT --orphan-tasks against an agent that has
#       open inbox rows is denied with a clear reason and the rows are
#       left untouched (no status change, no closed_ts).
#   C3. agent delete --orphan-tasks against an agent that has zero open
#       rows is a no-op on the task DB (no spurious task_events) and
#       still removes the managed-role block from the roster.
#
# Isolated BRIDGE_HOME via smoke_setup_bridge_home — never touches the
# operator's live runtime.

set -euo pipefail

SMOKE_NAME="agent-delete-task-gc"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

ADMIN="testadmin"
GHOST="ghostworker"

write_roster_fixture() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${ADMIN}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${ADMIN}
bridge_add_agent_id_if_missing ${ADMIN}
BRIDGE_AGENT_DESC["${ADMIN}"]='admin role'
BRIDGE_AGENT_ENGINE["${ADMIN}"]='claude'
BRIDGE_AGENT_SESSION["${ADMIN}"]='${ADMIN}'
BRIDGE_AGENT_WORKDIR["${ADMIN}"]='${BRIDGE_AGENT_HOME_ROOT}/${ADMIN}'
BRIDGE_AGENT_SOURCE["${ADMIN}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${ADMIN}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${ADMIN}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${ADMIN}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${GHOST}
bridge_add_agent_id_if_missing ${GHOST}
BRIDGE_AGENT_DESC["${GHOST}"]='ghost worker (about to be deleted)'
BRIDGE_AGENT_ENGINE["${GHOST}"]='claude'
BRIDGE_AGENT_SESSION["${GHOST}"]='${GHOST}'
BRIDGE_AGENT_WORKDIR["${GHOST}"]='${BRIDGE_AGENT_HOME_ROOT}/${GHOST}'
BRIDGE_AGENT_SOURCE["${GHOST}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${GHOST}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${GHOST}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${GHOST}
EOF
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$ADMIN" "$BRIDGE_AGENT_HOME_ROOT/$GHOST"
}

# Initialize the queue schema by running a no-op task summary against the
# isolated DB. `cmd_summary` opens the connection through `connect()`,
# which runs CREATE TABLE IF NOT EXISTS for every queue table.
init_task_db() {
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" summary >/dev/null
}

# Drop every row from tasks/task_events between tests so assertions on
# row counts are not polluted by an earlier test's residue. The schema
# itself is left in place (cheaper than a full DB recreate).
reset_task_db() {
  [[ -f "$BRIDGE_TASK_DB" ]] || return 0
  python3 - "$BRIDGE_TASK_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
try:
    with conn:
        conn.execute("DELETE FROM task_events")
        conn.execute("DELETE FROM tasks")
finally:
    conn.close()
PY
}

# Insert task rows directly via sqlite3 (Python). We hand-pick statuses so
# the test does not depend on the wider claim/handoff state machine.
seed_tasks_for_ghost() {
  python3 - "$BRIDGE_TASK_DB" "$GHOST" <<'PY'
import sqlite3
import sys
import time

db, agent = sys.argv[1], sys.argv[2]
now = int(time.time())
conn = sqlite3.connect(db)
try:
    with conn:
        # queued
        conn.execute(
            """
            INSERT INTO tasks (title, assigned_to, created_by, priority,
              status, created_ts, updated_ts, body_text)
            VALUES (?, ?, 'tester', 'normal', 'queued', ?, ?, 'queued body')
            """,
            ("ghost queued task", agent, now, now),
        )
        # claimed
        conn.execute(
            """
            INSERT INTO tasks (title, assigned_to, created_by, priority,
              status, created_ts, updated_ts, body_text, claimed_by,
              claimed_ts, lease_until_ts)
            VALUES (?, ?, 'tester', 'normal', 'claimed', ?, ?,
              'claimed body', ?, ?, ?)
            """,
            ("ghost claimed task", agent, now, now, agent, now, now + 900),
        )
        # blocked
        conn.execute(
            """
            INSERT INTO tasks (title, assigned_to, created_by, priority,
              status, created_ts, updated_ts, body_text)
            VALUES (?, ?, 'tester', 'normal', 'blocked', ?, ?,
              'blocked body')
            """,
            ("ghost blocked task", agent, now, now),
        )
        # cron-dispatch noise — must NOT be touched.
        conn.execute(
            """
            INSERT INTO tasks (title, assigned_to, created_by, priority,
              status, created_ts, updated_ts, body_text)
            VALUES (?, ?, 'cron', 'normal', 'queued', ?, ?, 'cron body')
            """,
            ("[cron-dispatch] hourly", agent, now, now),
        )
        # already-done — must NOT be touched.
        conn.execute(
            """
            INSERT INTO tasks (title, assigned_to, created_by, priority,
              status, created_ts, updated_ts, body_text, closed_ts)
            VALUES (?, ?, 'tester', 'normal', 'done', ?, ?, 'done body',
              ?)
            """,
            ("ghost finished task", agent, now - 7200, now - 3600, now - 3600),
        )
finally:
    conn.close()
PY
}

run_delete() {
  BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
  BRIDGE_CALLER_SOURCE="operator-tui" \
  BRIDGE_AGENT_ID="$ADMIN" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" delete "$@"
}

# Helper — count rows matching a status filter for the ghost agent.
count_rows_by_status() {
  local status="$1"
  python3 - "$BRIDGE_TASK_DB" "$GHOST" "$status" <<'PY'
import sqlite3
import sys

db, agent, status = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
try:
    row = conn.execute(
        """
        SELECT COUNT(*) FROM tasks
        WHERE assigned_to = ?
          AND status = ?
          AND title NOT LIKE '[cron-dispatch]%'
        """,
        (agent, status),
    ).fetchone()
    print(int(row[0] or 0))
finally:
    conn.close()
PY
}

count_cron_rows_untouched() {
  python3 - "$BRIDGE_TASK_DB" "$GHOST" <<'PY'
import sqlite3
import sys

db, agent = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
try:
    row = conn.execute(
        """
        SELECT COUNT(*) FROM tasks
        WHERE assigned_to = ?
          AND title LIKE '[cron-dispatch]%'
          AND status = 'queued'
        """,
        (agent,),
    ).fetchone()
    print(int(row[0] or 0))
finally:
    conn.close()
PY
}

count_cancelled_events_with_note() {
  python3 - "$BRIDGE_TASK_DB" "$GHOST" <<'PY'
import sqlite3
import sys

db, agent = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
try:
    row = conn.execute(
        """
        SELECT COUNT(*) FROM task_events
        WHERE event_type = 'cancelled'
          AND actor = 'agent-delete'
          AND to_agent = ?
          AND note_text LIKE '%--orphan-tasks%'
        """,
        (agent,),
    ).fetchone()
    print(int(row[0] or 0))
finally:
    conn.close()
PY
}

count_total_open_for_ghost_in_summary() {
  # Mirror the queued+claimed+blocked rollup `agb task summary` performs
  # for a single agent (bridge-queue.py:agent_summary_rows). Returns the
  # number that would render in the dashboard.
  python3 - "$BRIDGE_TASK_DB" "$GHOST" <<'PY'
import sqlite3
import sys

db, agent = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
try:
    row = conn.execute(
        """
        SELECT COUNT(*) FROM tasks
        WHERE assigned_to = ?
          AND status IN ('queued', 'claimed', 'blocked')
          AND title NOT LIKE '[cron-dispatch]%'
        """,
        (agent,),
    ).fetchone()
    print(int(row[0] or 0))
finally:
    conn.close()
PY
}

# ---------------------------------------------------------------------------
# C1 — --orphan-tasks closes every open row to `cancelled` with closed_ts.
# ---------------------------------------------------------------------------
test_orphan_tasks_closes_open_rows() {
  write_roster_fixture
  init_task_db
  reset_task_db
  seed_tasks_for_ghost

  # Pre-conditions.
  smoke_assert_eq "3" "$(count_total_open_for_ghost_in_summary)" \
    "C1 pre: 3 open rows for ghost (queued+claimed+blocked, cron excluded)"

  run_delete "$GHOST" --orphan-tasks --json >/dev/null

  # Post-conditions: every open row gone, all three are now cancelled.
  smoke_assert_eq "0" "$(count_total_open_for_ghost_in_summary)" \
    "C1 post: dashboard rollup empty (no queued/claimed/blocked left)"
  smoke_assert_eq "3" "$(count_rows_by_status cancelled)" \
    "C1 post: queued + claimed + blocked all cancelled"
  smoke_assert_eq "1" "$(count_cron_rows_untouched)" \
    "C1 post: [cron-dispatch] row left untouched"

  # closed_ts must be populated on every cancelled row (mirrors the
  # cancel path in bridge-queue.py).
  python3 - "$BRIDGE_TASK_DB" "$GHOST" <<'PY' || smoke_fail "C1: closed_ts not set on a cancelled row"
import sqlite3
import sys

db, agent = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
try:
    rows = conn.execute(
        """
        SELECT id, closed_ts FROM tasks
        WHERE assigned_to = ?
          AND status = 'cancelled'
          AND title NOT LIKE '[cron-dispatch]%'
        """,
        (agent,),
    ).fetchall()
    if not rows:
        raise SystemExit("no cancelled rows for ghost")
    for tid, closed_ts in rows:
        if not closed_ts or int(closed_ts) <= 0:
            raise SystemExit(f"task {tid} has empty closed_ts")
finally:
    conn.close()
PY

  # task_events: every cancellation emitted an audit event with a note
  # mentioning --orphan-tasks (refs #4797 trigger string).
  smoke_assert_eq "3" "$(count_cancelled_events_with_note)" \
    "C1 post: three cancelled task_events with --orphan-tasks note"

  # Roster block excised.
  if grep -q "BEGIN AGENT BRIDGE MANAGED ROLE: ${GHOST}" "$BRIDGE_ROSTER_LOCAL_FILE"; then
    smoke_fail "C1 post: ghost managed-role block was not excised"
  fi
}

# ---------------------------------------------------------------------------
# C2 — without --orphan-tasks, delete is refused and DB is untouched.
# ---------------------------------------------------------------------------
test_refuse_without_orphan_tasks_flag() {
  write_roster_fixture
  init_task_db
  reset_task_db
  seed_tasks_for_ghost

  local rc=0 out
  out="$(run_delete "$GHOST" 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "C2: delete without --orphan-tasks should have failed (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "--orphan-tasks" "C2 refusal mentions --orphan-tasks remedy"

  # All three open rows must still be open (none cancelled).
  smoke_assert_eq "3" "$(count_total_open_for_ghost_in_summary)" \
    "C2: open rows unchanged after refusal"
  smoke_assert_eq "0" "$(count_rows_by_status cancelled)" \
    "C2: nothing was cancelled by the refused call"

  # Roster block still present.
  grep -q "BEGIN AGENT BRIDGE MANAGED ROLE: ${GHOST}" "$BRIDGE_ROSTER_LOCAL_FILE" \
    || smoke_fail "C2: ghost managed-role block must remain after refusal"
}

# ---------------------------------------------------------------------------
# C3 — --orphan-tasks against an agent with no open rows is a no-op on the
# task DB but still removes the managed-role block.
# ---------------------------------------------------------------------------
test_orphan_tasks_with_no_open_rows() {
  write_roster_fixture
  init_task_db
  reset_task_db
  # Intentionally do NOT seed tasks — ghost has zero rows.

  run_delete "$GHOST" --orphan-tasks --json >/dev/null

  smoke_assert_eq "0" "$(count_rows_by_status cancelled)" \
    "C3: no spurious cancelled rows produced"
  smoke_assert_eq "0" "$(count_cancelled_events_with_note)" \
    "C3: no spurious task_events produced"

  if grep -q "BEGIN AGENT BRIDGE MANAGED ROLE: ${GHOST}" "$BRIDGE_ROSTER_LOCAL_FILE"; then
    smoke_fail "C3: ghost managed-role block was not excised"
  fi
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "agent-delete-task-gc"

  smoke_run "C1 --orphan-tasks closes queued+claimed+blocked to cancelled" \
    test_orphan_tasks_closes_open_rows
  smoke_run "C2 refuse delete without --orphan-tasks when open rows exist" \
    test_refuse_without_orphan_tasks_flag
  smoke_run "C3 --orphan-tasks no-op on empty inbox still removes roster block" \
    test_orphan_tasks_with_no_open_rows

  smoke_log "passed"
}

main "$@"
