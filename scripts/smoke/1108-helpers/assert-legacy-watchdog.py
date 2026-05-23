#!/usr/bin/env python3
"""1108 smoke helper — T3 assertions on legacy (no-workdir-in-registry) scan output."""
import json, sys

payload = json.loads(sys.argv[1])
agent_id = sys.argv[2]
rows = {row["agent"]: row for row in payload["agents"]}
assert agent_id in rows, rows
row = rows[agent_id]
assert row["status"] == "ok", (
    f"T3 FAIL: legacy fallback broken. status={row['status']} on a "
    f"well-formed legacy agent (no workdir in registry). The "
    f"watchdog must keep scanning <agent_home_root>/<name>/ when the "
    f"registry has no workdir. row={row}"
)
assert row["missing_files"] == [], row
print("T3 PASS")
