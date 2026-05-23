#!/usr/bin/env python3
# scripts/smoke/nudge-task-age-gate-helpers/seed-agent-nudge-history.py
#
# Standalone helper for the issue #1099 nudge smoke. Inserts or updates
# `agent_state` so an agent appears to have prior nudge history with a
# given `last_nudge_ts` + `last_nudge_key`. Used to reproduce the three
# guard paths in `bridge-queue.py::cmd_daemon_step` that PR #1019 left
# open when the agent already has prior nudge history.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) per footgun #11 — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   seed-agent-nudge-history.py <db-path> <agent> <last-nudge-ts> <last-nudge-key>
#
# `last-nudge-key` may be empty (pass `""`) for the "never-nudged" path,
# but for #1099 the meaningful case is a non-empty comma-separated id
# list reflecting a prior nudge that has aged past cooldown.

import sqlite3
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: seed-agent-nudge-history.py <db> <agent> "
            "<last-nudge-ts> <last-nudge-key>",
            file=sys.stderr,
        )
        return 2
    db_path, agent, last_nudge_ts_raw, last_nudge_key = argv
    try:
        last_nudge_ts = int(last_nudge_ts_raw)
    except ValueError:
        print(f"invalid last-nudge-ts: {last_nudge_ts_raw!r}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(db_path)
    try:
        # `cmd_daemon_step` reads agent_state.last_nudge_ts /
        # .last_nudge_key for the per-row guards. We do NOT touch
        # .active / .session_activity_ts here — daemon-step's first pass
        # upserts those from the snapshot TSV. We only seed the prior-
        # nudge bookkeeping (and a sentinel last_seen_ts so the row
        # exists before the snapshot UPSERT in case the test relies on
        # it being present early).
        conn.execute(
            """
            INSERT INTO agent_state (
              agent, last_nudge_ts, last_nudge_key, last_seen_ts, active
            ) VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(agent) DO UPDATE SET
              last_nudge_ts = excluded.last_nudge_ts,
              last_nudge_key = excluded.last_nudge_key
            """,
            (agent, last_nudge_ts, last_nudge_key, last_nudge_ts),
        )
        conn.commit()
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
