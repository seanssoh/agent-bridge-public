#!/usr/bin/env python3
"""Test fixture for scripts/smoke/2067-reminder-unclaimed-exempt.sh (case M).

Extracted to a standalone script (NOT an inline interpreter heredoc — footgun
#11 / lint-heredoc-ban) so the non-vacuous mutation can strip the exemption
block from a COPY of lib/daemon-helpers/unclaimed-task-filter.py and prove the
guard is load-bearing.

argv[1] = source helper path, argv[2] = mutated output path.
Exits 3 if the exemption block is not found exactly once.
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Remove the multi-line `if (r.get("created_by") ... startswith(...)):\n continue`
# exemption block (the daemon blocked-aging reminder skip).
pattern = re.compile(
    r'\n        if \(r\.get\("created_by"\) or ""\) == "daemon" and str\(\n'
    r'            r\.get\("title"\) or ""\n'
    r'        \)\.startswith\(BLOCKED_REMINDER_TITLE_PREFIX\):\n'
    r'            continue\n'
)
new, n = pattern.subn("\n", src)
if n != 1:
    sys.stderr.write(
        f"mutation: expected to strip 1 exemption block, stripped {n}\n"
    )
    sys.exit(3)
open(sys.argv[2], "w", encoding="utf-8").write(new)
