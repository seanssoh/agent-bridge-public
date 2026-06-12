#!/usr/bin/env python3
"""Helper for scripts/smoke/1826-cron-at-naive-tz.sh (Issue #1826).

Read a single `schedule` field (`at` or `tz`) for a named job out of a native
cron jobs file. Replaces the in-smoke `stored_at` / `stored_tz` /
`stored_at_file` heredoc-stdin Python (footgun #11): the file path, job title,
and field name arrive as file-as-argv arguments — never via heredoc stdin.

Args:
    sys.argv[1]  jobs_file  path to the native cron jobs JSON
    sys.argv[2]  title      job name to look up
    sys.argv[3]  field      schedule field to print ("at" or "tz")

Prints the field value (empty string if the job or field is absent), exactly
as the original inline readers did, so the smoke's assertions are unchanged.
"""
from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: read-schedule-field.py JOBS_FILE TITLE FIELD", file=sys.stderr)
        return 2
    jobs_file, title, field = argv[1], argv[2], argv[3]
    with open(jobs_file, encoding="utf-8") as fh:
        jobs = json.load(fh).get("jobs", [])
    for job in jobs:
        if job.get("name") == title:
            print((job.get("schedule") or {}).get(field, ""))
            break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
