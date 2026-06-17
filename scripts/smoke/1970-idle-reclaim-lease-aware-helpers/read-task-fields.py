#!/usr/bin/env python3
# scripts/smoke/1970-idle-reclaim-lease-aware-helpers/read-task-fields.py
#
# Standalone helper for the issue #1970 idle-reclaim-lease-aware smoke.
# Prints the lease-bookkeeping fields of one task that `agb show --format
# shell` does not surface (lease_until_ts / updated_ts / claimed_ts), so the
# smoke can assert the daemon-step / cmd_update lease boundaries precisely.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) so the smoke stays clear of the footgun #11 heredoc-stdin
# deadlock class — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   read-task-fields.py <db> <task-id>
#
# Output (stdout), one KEY=value line each (NULL prints as the literal NULL):
#   TASK_STATUS / TASK_CLAIMED_BY / TASK_CLAIMED_TS /
#   TASK_LEASE_UNTIL_TS / TASK_UPDATED_TS

import sqlite3
import sys


def _fmt(value: object) -> str:
    return "NULL" if value is None else str(value)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: read-task-fields.py <db> <task-id>", file=sys.stderr)
        return 2
    db_path, task_id_s = argv
    try:
        task_id = int(task_id_s)
    except ValueError:
        print(f"invalid task id: {task_id_s!r}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute(
            """
            SELECT status, claimed_by, claimed_ts, lease_until_ts, updated_ts
            FROM tasks WHERE id = ?
            """,
            (task_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        print(f"task not found: {task_id}", file=sys.stderr)
        return 1
    status, claimed_by, claimed_ts, lease_until_ts, updated_ts = row
    print(f"TASK_STATUS={_fmt(status)}")
    print(f"TASK_CLAIMED_BY={_fmt(claimed_by)}")
    print(f"TASK_CLAIMED_TS={_fmt(claimed_ts)}")
    print(f"TASK_LEASE_UNTIL_TS={_fmt(lease_until_ts)}")
    print(f"TASK_UPDATED_TS={_fmt(updated_ts)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
