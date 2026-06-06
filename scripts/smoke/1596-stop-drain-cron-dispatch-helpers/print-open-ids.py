#!/usr/bin/env python3
"""Read a `bridge-queue.py find-open --all --format json` array on stdin and
print each task id on its own line (space/newline separated).

Used by scripts/smoke/1596-stop-drain-cron-dispatch.sh's close_all() to drain
the fixture queue between phases WITHOUT a python3 heredoc-stdin in the smoke
(footgun #11) and without a jq dependency. Any parse error prints nothing
(exit 0) so cleanup is best-effort and never aborts the smoke.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        return 0
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError:
        return 0
    if not isinstance(rows, list):
        return 0
    for row in rows:
        if isinstance(row, dict):
            try:
                task_id = int(row.get("id", 0) or 0)
            except (TypeError, ValueError):
                continue
            if task_id:
                print(task_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
