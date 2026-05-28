#!/usr/bin/env python3
"""G-beta4 T1 — fresh_install_only signal + per-row fresh_install flag.

Usage:
  assert-fresh-install.py <watchdog-json-file> <admin-agent> <complete-agent>

Assertions:
  * Both agents appear in the payload.
  * The admin agent (has onboarding-pending marker) row has
    fresh_install=True.
  * The complete agent (no marker, old mtime) row has
    fresh_install=False.
  * The payload-level ``fresh_install_only`` boolean exists. We do NOT
    assert its value here (the fixture has multiple problem types and
    the field is True only when *every* effective problem is fresh —
    that's already covered by the broader assert; here we just gate
    the field's presence so a future refactor cannot silently remove
    it).
"""
import json
import sys
from pathlib import Path

path, admin_agent, complete_agent = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.loads(Path(path).read_text(encoding="utf-8"))
rows = {row["agent"]: row for row in payload["agents"]}

for agent in (admin_agent, complete_agent):
    assert agent in rows, (
        f"FAIL: agent '{agent}' missing from payload. Rows: {list(rows)}"
    )

admin_row = rows[admin_agent]
assert admin_row.get("fresh_install") is True, (
    f"FAIL: admin agent fresh_install should be True (marker present); "
    f"row={admin_row}"
)

complete_row = rows[complete_agent]
assert complete_row.get("fresh_install") is False, (
    f"FAIL: complete agent fresh_install should be False (no marker + "
    f"old mtime); row={complete_row}"
)

assert "fresh_install_only" in payload, (
    f"FAIL: payload missing 'fresh_install_only' field. "
    f"Keys: {sorted(payload.keys())}"
)

print("T1 PASS")
