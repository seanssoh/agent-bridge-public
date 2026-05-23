#!/usr/bin/env python3
"""
scripts/python-helpers/migrator-smoke-helpers.py

File-as-argv helpers for the legacy-install-migrator smoke test.
Invoked with a command name as first arg, path(s) as subsequent args.
No heredoc-stdin / here-string; footgun #11 safe.

Commands:
  manifest-agent-count   <manifest.json>
  manifest-cron-count    <manifest.json>
  apply-result-agents    <apply-result.json>
  cron-job-count         <cron/jobs.json>
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: migrator-smoke-helpers.py <command> [args...]", file=sys.stderr)
        return 2

    cmd = sys.argv[1]

    if cmd == "manifest-agent-count":
        path = sys.argv[2]
        m = json.loads(open(path).read())
        print(len(m.get("agents", [])))

    elif cmd == "manifest-cron-count":
        path = sys.argv[2]
        m = json.loads(open(path).read())
        print(len(m.get("cron_jobs", [])))

    elif cmd == "apply-result-agents":
        path = sys.argv[2]
        ar = json.loads(open(path).read())
        print(",".join(sorted(ar.get("applied_agents", []))))

    elif cmd == "cron-job-count":
        path = sys.argv[2]
        jobs = json.loads(open(path).read())
        count = len(jobs) if isinstance(jobs, list) else 0
        print(count)

    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
