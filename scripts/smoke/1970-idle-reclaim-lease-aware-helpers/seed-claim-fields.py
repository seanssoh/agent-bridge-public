#!/usr/bin/env python3
# scripts/smoke/1970-idle-reclaim-lease-aware-helpers/seed-claim-fields.py
#
# Standalone helper for the issue #1970 idle-reclaim-lease-aware smoke.
# Sets the claim-bookkeeping fields of one task to exact values so the
# daemon-step lease-aware stale-claim branch can be exercised at precise
# boundaries (claimed_ts age, lease_until_ts vs current_ts) without any
# sleeping. `bridge-queue.py claim` always stamps these to `now`, which is
# too coarse for the > / >= boundary cases the smoke pins.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) so the smoke stays clear of the footgun #11 heredoc-stdin
# deadlock class — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   seed-claim-fields.py <db> <task-id> <claimed-by> <claimed-ts> \
#       <lease-until-ts|NULL> <updated-ts>
#
# Forces status='claimed'. `lease-until-ts` of the literal NULL (any case)
# stores SQL NULL — the legacy / upgrade-window row shape.

import sqlite3
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print(
            "usage: seed-claim-fields.py <db> <task-id> <claimed-by> "
            "<claimed-ts> <lease-until-ts|NULL> <updated-ts>",
            file=sys.stderr,
        )
        return 2
    db_path, task_id_s, claimed_by, claimed_ts_s, lease_s, updated_ts_s = argv
    try:
        task_id = int(task_id_s)
        claimed_ts = int(claimed_ts_s)
        updated_ts = int(updated_ts_s)
    except ValueError as exc:
        print(f"invalid integer argument: {exc}", file=sys.stderr)
        return 2
    if lease_s.strip().upper() == "NULL":
        lease_until_ts: int | None = None
    else:
        try:
            lease_until_ts = int(lease_s)
        except ValueError:
            print(f"invalid lease-until-ts: {lease_s!r}", file=sys.stderr)
            return 2

    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            """
            UPDATE tasks
            SET status = 'claimed',
                claimed_by = ?,
                claimed_ts = ?,
                lease_until_ts = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (claimed_by, claimed_ts, lease_until_ts, updated_ts, task_id),
        )
        conn.commit()
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
