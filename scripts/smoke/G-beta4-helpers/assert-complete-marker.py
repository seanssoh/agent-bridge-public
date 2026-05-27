#!/usr/bin/env python3
"""G-beta4 T10 — bridge_init_write_onboarding_complete_marker schema +
sibling pending-marker removal.

Usage:
  assert-complete-marker.py <state-dir>/agents/<agent> <agent>

Assertions:
  * <state-dir>/agents/<agent>/onboarding-complete exists, mode 0600.
  * Body contains agent=<expected>, written=<int>, reason=onboarding-
    complete.
  * Sibling onboarding-pending marker (if it existed pre-write) has
    been removed.
"""
import os
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print(
        "usage: assert-complete-marker.py <agent-state-dir> <agent>",
        file=sys.stderr,
    )
    sys.exit(2)

agent_state_dir = Path(sys.argv[1])
expected_agent = sys.argv[2]

complete = agent_state_dir / "onboarding-complete"
pending = agent_state_dir / "onboarding-pending"

assert complete.is_file(), (
    f"FAIL: complete marker missing at {complete}"
)
mode = os.stat(complete).st_mode & 0o7777
assert mode == 0o600, (
    f"FAIL: complete marker mode={oct(mode)}; expected 0o600"
)
text = complete.read_text(encoding="utf-8")
fields = {}
for line in text.splitlines():
    if "=" in line:
        k, _, v = line.partition("=")
        fields[k.strip()] = v.strip()
assert fields.get("agent") == expected_agent, (
    f"FAIL: complete marker agent field={fields.get('agent')!r}; "
    f"expected {expected_agent!r}"
)
assert fields.get("reason") == "onboarding-complete", (
    f"FAIL: complete marker reason field={fields.get('reason')!r}; "
    f"expected 'onboarding-complete'"
)
written = fields.get("written", "")
assert re.fullmatch(r"\d+", written) and int(written) > 0, (
    f"FAIL: complete marker written field={written!r}; "
    f"expected positive integer"
)

assert not pending.exists(), (
    f"FAIL: pending marker still present at {pending} after complete "
    f"marker was written (writer should clean up the sibling)"
)

print("T10 PASS — complete marker schema + pending sibling removal")
