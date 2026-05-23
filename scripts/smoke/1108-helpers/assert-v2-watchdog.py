#!/usr/bin/env python3
"""1108 smoke helper — T1+T2 assertions on v2 workdir scan output.

Restored the 5-assertion contract from the pre-r2 inline heredoc body
per codex r2 review: missing_files / status / missing_managed_claude_block
/ session_type / problem_count. expected_workdir is consumed in failure
messages so the helper can name the directory the watchdog should have
been scanning.
"""
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
    f"instead of v2 runtime `{expected_workdir}`."
)
assert row["status"] == "ok", (
    f"T1 FAIL: status={row['status']} on v2 agent with full profile in "
    f"{expected_workdir}. Expected `ok` — pre-fix bug shape produced "
    f"`error` here."
)
assert row.get("missing_managed_claude_block") is False, (
    f"T1 FAIL: missing_managed_claude_block={row.get('missing_managed_claude_block')!r}. "
    f"Watchdog must read the managed-block from {expected_workdir}/CLAUDE.md, "
    f"not the tracked profile tree."
)
assert row.get("session_type") == "static-claude", (
    f"T1 FAIL: session_type={row.get('session_type')!r}. Watchdog must "
    f"parse SESSION-TYPE.md from {expected_workdir}, not the tracked "
    f"profile tree."
)
assert payload.get("problem_count") == 0, (
    f"T1 FAIL: payload problem_count={payload.get('problem_count')!r}. "
    f"A fully-populated v2 agent in {expected_workdir} must report zero "
    f"problems."
)
print("T1+T2 PASS")
