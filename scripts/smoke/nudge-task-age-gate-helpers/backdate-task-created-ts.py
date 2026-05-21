#!/usr/bin/env python3
# scripts/smoke/nudge-task-age-gate-helpers/backdate-task-created-ts.py
#
# Standalone helper for the issue #1014-A nudge smokes. Backdates the
# `created_ts` (and `updated_ts`) of one or more queued tasks in a
# bridge queue DB so the daemon idle-nudge's task-queued-age gate treats
# them as aged past the redelivery window.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) so the nudge smokes stay clear of the footgun #11
# heredoc-stdin deadlock class — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   backdate-task-created-ts.py <db-path> <created-ts> <task-id> [<task-id> ...]
#   backdate-task-created-ts.py <db-path> <created-ts> --all
#
# With --all every row in `tasks` is backdated; otherwise only the
# listed task ids. Exits non-zero on a usage error or a DB failure.

import sqlite3
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: backdate-task-created-ts.py <db> <created-ts> "
            "(<task-id> ... | --all)",
            file=sys.stderr,
        )
        return 2
    db_path = argv[0]
    try:
        created_ts = int(argv[1])
    except ValueError:
        print(f"invalid created-ts: {argv[1]!r}", file=sys.stderr)
        return 2
    targets = argv[2:]

    conn = sqlite3.connect(db_path)
    try:
        if targets == ["--all"]:
            conn.execute(
                "UPDATE tasks SET created_ts = ?, updated_ts = ?",
                (created_ts, created_ts),
            )
        else:
            try:
                task_ids = [int(t) for t in targets]
            except ValueError:
                print(f"invalid task id in {targets!r}", file=sys.stderr)
                return 2
            for task_id in task_ids:
                conn.execute(
                    "UPDATE tasks SET created_ts = ?, updated_ts = ? "
                    "WHERE id = ?",
                    (created_ts, created_ts, task_id),
                )
        conn.commit()
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
