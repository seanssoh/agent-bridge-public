#!/usr/bin/env python3
"""Read agent_state nudge fields for the #9780 smoke (file-as-argv helper).

Standalone so the smoke never has to embed a python3 heredoc-stdin / `<<<`
here-string (footgun #11 / scripts/lint-heredoc-ban.sh).

Usage: read-nudge-state.py <tasks.db> <agent>
Prints one line: "<last_nudge_ts> <nudge_fail_count> <last_nudge_key>"
(missing row → "0 0 ").
"""
from __future__ import annotations

import sqlite3
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: read-nudge-state.py <tasks.db> <agent>\n")
        return 2
    db_path, agent = argv[1], argv[2]
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute(
            "SELECT last_nudge_ts, nudge_fail_count, last_nudge_key "
            "FROM agent_state WHERE agent = ?",
            (agent,),
        )
        row = cur.fetchone()
    finally:
        conn.close()
    if row is None:
        print("0 0 ")
        return 0
    last_nudge_ts = int(row[0] or 0)
    nudge_fail_count = int(row[1] or 0)
    last_nudge_key = str(row[2] or "")
    print(f"{last_nudge_ts} {nudge_fail_count} {last_nudge_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
