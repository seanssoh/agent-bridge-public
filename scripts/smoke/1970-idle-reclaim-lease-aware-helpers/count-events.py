#!/usr/bin/env python3
# scripts/smoke/1970-idle-reclaim-lease-aware-helpers/count-events.py
#
# Standalone helper for the issue #1970 idle-reclaim-lease-aware smoke.
# Counts task_events rows of a given event_type for one task id, reading the
# queue DB directly so the smoke can assert "exactly ONE requeue event"
# (the double-requeue/event-churn regression guard) without jq.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) so the smoke stays clear of the footgun #11 heredoc-stdin
# deadlock class — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   count-events.py <db> <task-id> <event-type>
#
# Output (stdout): the integer count, then a newline. Exit 0 on success.

import sqlite3
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: count-events.py <db> <task-id> <event-type>", file=sys.stderr)
        return 2
    db_path, task_id_s, event_type = argv
    try:
        task_id = int(task_id_s)
    except ValueError:
        print(f"invalid task id: {task_id_s!r}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(db_path)
    try:
        (count,) = conn.execute(
            "SELECT COUNT(*) FROM task_events WHERE task_id = ? AND event_type = ?",
            (task_id, event_type),
        ).fetchone()
    finally:
        conn.close()
    print(int(count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
