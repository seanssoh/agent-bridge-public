#!/usr/bin/env python3
"""G-beta4 T5 — restart.in-progress marker active excludes the agent
from the effective problem count.

Usage:
  assert-restart-skip.py <watchdog-json-file> <restart-agent>

Assertions:
  * The restart agent appears in the payload.
  * Its row has restart_in_progress=True.
  * The payload-level ``restart_in_progress_count`` is at least 1.
  * The restart agent's effective contribution to problem_count is 0:
    the row is excluded from the effective set whether or not the
    row's own status would have been ok/warn.

The third assertion is the regression bite: pre-fix the watchdog
counted the restart-mid agent as a problem and the daemon enqueued a
drift task that the next tick would obsolete.
"""
import json
import sys
from pathlib import Path

path, restart_agent = sys.argv[1], sys.argv[2]
payload = json.loads(Path(path).read_text(encoding="utf-8"))
rows = {row["agent"]: row for row in payload["agents"]}

assert restart_agent in rows, (
    f"FAIL: restart agent '{restart_agent}' missing. Rows: {list(rows)}"
)
row = rows[restart_agent]
assert row.get("restart_in_progress") is True, (
    f"FAIL: restart_in_progress should be True; row={row}"
)
assert payload.get("restart_in_progress_count", 0) >= 1, (
    f"FAIL: restart_in_progress_count={payload.get('restart_in_progress_count')!r}. "
    f"Expected >=1 with one mid-restart agent in the fixture."
)
# The restart-mid agent has a complete static-claude profile, so the
# row's own status would be "ok" anyway. The contract we're enforcing
# is the *exclusion* from problem_count regardless: the watchdog now
# uses an effective_problems list that excludes restart_in_progress
# rows, and any future scan_error / warn that happened to be marked
# restart_in_progress would still be excluded.
non_restart_problems = sum(
    1 for r in payload["agents"]
    if r.get("status") != "ok" and not r.get("restart_in_progress")
)
assert payload.get("problem_count") == non_restart_problems, (
    f"FAIL: payload problem_count={payload.get('problem_count')!r} but "
    f"non-restart problems={non_restart_problems}. "
    f"The exclusion contract for restart-in-progress rows is broken."
)

print("T5 PASS")
