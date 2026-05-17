#!/usr/bin/env python3
"""orphan-tasks-gc.py — close every open queue row assigned to an agent
that is being deleted via `agent-bridge agent delete <name> --orphan-tasks`.

Invocation contract:
    sys.argv[1] = path to BRIDGE_TASK_DB (SQLite file).
    sys.argv[2] = agent name (matches tasks.assigned_to).
    sys.argv[3] = completion note to attach to each emitted task_event row.

Behavior:
    For every row in `tasks` where assigned_to=<agent> and status IN
    ('queued', 'claimed', 'blocked') and title NOT LIKE
    '[cron-dispatch]%', update status to terminal `cancelled` with
    claimed_by/claimed_ts/lease_until_ts cleared and closed_ts populated
    (mirrors the cancel path in bridge-queue.py). Insert a `cancelled`
    task_event with actor='agent-delete' carrying the supplied note so
    `agb task show <id>` and the audit timeline both record *why* the
    row closed. Idempotent: rows already in a terminal status are
    skipped by the WHERE clause.

Refs:
    - queue task #4797: before this code path the orphan path marked
      rows `blocked` (an open status, see bridge-queue.py:22). That left
      ghost agents accumulating in `agb task summary` for weeks.
    - Footgun #11 / KNOWN_ISSUES.md §26: this body used to live as a
      `python3 - … <<'PY' … PY` heredoc-stdin inline in bridge-agent.sh.
      The Bash 5.3.9 `heredoc_write` deadlock wedged the orphan-tasks
      branch the moment any caller exercised it. Moved to a standalone
      file invoked with file-as-argv to remove the heredoc-stdin path,
      same precedent as lib/upgrade-helpers/recorded-source-root.py and
      lib/agent-cli-helpers/registry-format-json.py.
"""

import sqlite3
import sys
import time


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: orphan-tasks-gc.py <db_path> <agent> <note>",
            file=sys.stderr,
        )
        return 2

    db_path = sys.argv[1]
    agent = sys.argv[2]
    note = sys.argv[3]
    now_ts = int(time.time())

    conn = sqlite3.connect(db_path)
    try:
        with conn:
            rows = conn.execute(
                """
                SELECT id FROM tasks
                WHERE assigned_to = ?
                  AND status IN ('queued', 'claimed', 'blocked')
                  AND title NOT LIKE '[cron-dispatch]%'
                """,
                (agent,),
            ).fetchall()
            for (task_id,) in rows:
                conn.execute(
                    """
                    UPDATE tasks
                    SET status = 'cancelled',
                        claimed_by = NULL,
                        claimed_ts = NULL,
                        lease_until_ts = NULL,
                        updated_ts = ?,
                        closed_ts = ?
                    WHERE id = ?
                      AND status IN ('queued', 'claimed', 'blocked')
                      AND title NOT LIKE '[cron-dispatch]%'
                    """,
                    (now_ts, now_ts, task_id),
                )
                conn.execute(
                    """
                    INSERT INTO task_events (
                      task_id, event_type, actor, created_ts, note_text,
                      note_path, from_agent, to_agent
                    ) VALUES (?, 'cancelled', 'agent-delete', ?, ?, NULL, NULL, ?)
                    """,
                    (task_id, now_ts, note, agent),
                )
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
