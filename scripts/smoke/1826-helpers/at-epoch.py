#!/usr/bin/env python3
"""Helper for scripts/smoke/1826-cron-at-naive-tz.sh (Issue #1826).

Compute the absolute UTC epoch (seconds) the scheduler will honor for a job's
stored `at` value, via the production scheduler's own `parse_iso` enumeration
path. Replaces the in-smoke `at_epoch` / `SEOUL_EPOCH` heredoc-stdin Python
(footgun #11): the repo root, jobs file, and job title arrive as file-as-argv
arguments — never via heredoc stdin.

Args:
    sys.argv[1]  repo_root  Agent Bridge source checkout root
    sys.argv[2]  jobs_file  path to the native cron jobs JSON
    sys.argv[3]  title      job name to look up

Prints the integer UTC epoch the scheduler resolves for the stored `at`.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import timezone


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: at-epoch.py REPO_ROOT JOBS_FILE TITLE", file=sys.stderr)
        return 2
    repo, jobs_file, title = argv[1], argv[2], argv[3]

    spec = importlib.util.spec_from_file_location(
        "bridge_cron_scheduler", f"{repo}/bridge-cron-scheduler.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["bridge_cron_scheduler"] = mod
    spec.loader.exec_module(mod)

    with open(jobs_file, encoding="utf-8") as fh:
        job = next(
            j for j in json.load(fh).get("jobs", []) if j.get("name") == title
        )
    occ = mod.parse_iso((job.get("schedule") or {}).get("at"))
    print(int(occ.astimezone(timezone.utc).timestamp()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
