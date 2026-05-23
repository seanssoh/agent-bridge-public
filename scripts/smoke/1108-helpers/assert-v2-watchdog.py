#!/usr/bin/env python3
"""1108 smoke helper — T1+T2 assertions on v2 workdir scan output."""
import json, sys

payload = json.loads(sys.argv[1])
agent_id = sys.argv[2]
expected_workdir = sys.argv[3]
rows = {row["agent"]: row for row in payload["agents"]}
assert agent_id in rows, (
    f"T2 FAIL: agent field is not the registry id. rows={list(rows)} "
    f"(expected key '{agent_id}'). "
    f"If 'workdir' appears as an agent name, the watchdog leaked the "
    f"basename of the resolved scan path through agent_dir.name."
)
row = rows[agent_id]
assert row["missing_files"] == [], (
    f"T1 FAIL: missing_files reported on v2 agent. row={row} — "
    f"pre-fix watchdog scanned `agents/<a>/` (tracked profile tree) "
    f"instead of v2 runtime `data/agents/<a>/workdir/`."
)
assert row["status"] == "ok", (
    f"T1 FAIL: status={row['status']} on v2 agent with full profile. "
    f"Expected `ok` — pre-fix bug shape produced `error` here."
)
print("T1+T2 PASS")
