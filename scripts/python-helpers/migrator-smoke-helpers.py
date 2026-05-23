#!/usr/bin/env python3
"""
scripts/python-helpers/migrator-smoke-helpers.py

File-as-argv helpers for the legacy-install-migrator smoke test.
Invoked with a command name as first arg, path(s) as subsequent args.
No heredoc-stdin / here-string; footgun #11 safe.

Commands:
  manifest-agent-count          <manifest.json>
  manifest-cron-count           <manifest.json>
  manifest-first-cron-env-keys  <manifest.json>   (csv of payload.env keys
                                                   for the first cron job)
  apply-result-agents           <apply-result.json>
  apply-result-field            <apply-result.json> <field>
  cron-job-count                <cron/jobs.json>
  file-octal-mode               <path>
"""

from __future__ import annotations

import json
import os
import stat
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

    elif cmd == "manifest-first-cron-env-keys":
        path = sys.argv[2]
        m = json.loads(open(path).read())
        jobs = m.get("cron_jobs", []) or []
        if not jobs:
            print("")
            return 0
        env = (jobs[0].get("payload") or {}).get("env") or {}
        print(",".join(sorted(env.keys())))

    elif cmd == "apply-result-field":
        path = sys.argv[2]
        field = sys.argv[3]
        ar = json.loads(open(path).read())
        val = ar.get(field, "")
        if isinstance(val, (list, dict)):
            print(json.dumps(val))
        else:
            print(val)

    elif cmd == "file-octal-mode":
        path = sys.argv[2]
        st = os.stat(path)
        # Print as 4-digit octal (e.g. 0600) for stable smoke matching.
        print(f"{stat.S_IMODE(st.st_mode):04o}")

    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
