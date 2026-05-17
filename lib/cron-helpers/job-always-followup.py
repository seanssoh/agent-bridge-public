#!/usr/bin/env python3
"""job-always-followup.py — emit "1" if the given job declares
`alwaysFollowup` (or the snake_case alias `always_followup`) in its
metadata, "0" otherwise.

Invocation contract:
    sys.argv[1] = job_id.
    sys.argv[2] = path to BRIDGE_NATIVE_CRON_JOBS_FILE (jobs JSON).

Output: "1" or "0" on stdout. Missing/unparseable files emit "0".

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$job_id" "$BRIDGE_NATIVE_CRON_JOBS_FILE" <<'PY'`
heredoc-stdin in bridge_cron_job_always_followup. Moved to a standalone
file invoked with file-as-argv to remove the heredoc-stdin path —
same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    job_id = sys.argv[1]
    jobs_file = Path(sys.argv[2]).expanduser()

    if not jobs_file.exists():
        print("0")
        return 0

    try:
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
    except Exception:
        print("0")
        return 0

    for job in data.get("jobs", []):
        if job.get("id") == job_id:
            metadata = job.get("metadata") or {}
            if metadata.get("alwaysFollowup") or metadata.get("always_followup"):
                print("1")
            else:
                print("0")
            return 0

    print("0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
