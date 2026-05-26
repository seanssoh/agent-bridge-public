#!/usr/bin/env python3
"""Insert a `BRIDGE_AGENT_START_POLICY["<agent>"]="<value>"` line into the
managed role block for <agent> in a roster file.

Used by scripts/smoke/δ-1234-daemon-start-policy.sh (T1) to simulate
exactly what bridge-agent.sh:bridge_write_role_block emits on
`agent update --start-policy hold` without dragging in the full
agent-bridge runtime. Refs issue #1234 (Lane δ, v0.15.0-beta2).

Standalone helper (file-as-argv, no heredoc-stdin) — refs footgun #11.

Usage:
  insert-start-policy-line.py <roster_path> <agent> <value>
"""
from __future__ import annotations

import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "Usage: insert-start-policy-line.py <roster_path> <agent> <value>",
            file=sys.stderr,
        )
        return 2
    roster_path = Path(argv[1])
    agent = argv[2]
    value = argv[3]
    text = roster_path.read_text(encoding="utf-8")
    end_marker = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
    if end_marker not in text:
        print(
            f"managed block not found for agent {agent!r}: {roster_path}",
            file=sys.stderr,
        )
        return 1
    line = f'BRIDGE_AGENT_START_POLICY["{agent}"]="{value}"'
    new_text = text.replace(end_marker, f"{line}\n{end_marker}", 1)
    roster_path.write_text(new_text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
