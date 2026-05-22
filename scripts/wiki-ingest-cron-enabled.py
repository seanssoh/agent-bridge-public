#!/usr/bin/env python3
"""wiki-ingest-cron-enabled.py — Lane B librarian-gate helper (issue #1042).

File-as-argv helper for scripts/wiki-daily-ingest.sh. Reads the JSON emitted
by `agb cron list --json` and decides whether the `wiki-daily-ingest` cron
is enabled.

Extracted to a standalone file (invoked ``python3 <file> <json>``) rather
than a ``python3 - <<'PY'`` heredoc-stdin: the heredoc-stdin form is banned
by scripts/lint-heredoc-ban.sh (footgun #11, the Bash 5.3.9
read_comsub/heredoc_write deadlock class).

Exit codes:
  0  — the wiki-daily-ingest cron is enabled, OR the inventory is
       unparseable / the cron is not registered (permissive: a healthy
       server install whose cron list is momentarily unavailable, or a
       pre-#1042 install that never registered the cron, must still ingest)
  1  — the wiki-daily-ingest cron is registered and explicitly disabled

Usage:
  wiki-ingest-cron-enabled.py '<cron-list-json>'
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        # No payload — permissive (caller already handles empty inventory).
        return 0
    try:
        data = json.loads(argv[1])
    except Exception:
        return 0  # unparseable → permissive
    jobs = data.get("jobs", []) if isinstance(data, dict) else []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        if job.get("name") == "wiki-daily-ingest":
            return 0 if job.get("enabled") else 1
    return 0  # cron not registered → permissive (pre-#1042 behaviour)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
