#!/usr/bin/env python3
"""roster-excise-block.py — remove the managed-role block for an agent
from agent-roster.local.sh (or any other roster file passed by argv).

Invocation contract:
    sys.argv[1] = path to roster file (read-write).
    sys.argv[2] = agent name (matches the BEGIN/END marker).

Output: the roster path on stdout when the block was excised; raises
SystemExit with a non-zero exit code and a stderr message when the
BEGIN/END markers are missing or matched a non-unique count.

Behavior matches the writer in bridge-agent.sh's
`bridge_write_role_block` — the regex pins the literal markers used at
write time, with re.sub() used to excise rather than replace. Triple
newlines left behind by the removal are collapsed for readability.

Refs:
    - Footgun #11 / KNOWN_ISSUES.md §26: this body used to live as a
      `bridge_agent_manage_python <args> >/dev/null <<'PY' … PY`
      heredoc-stdin inline in `run_delete`. The Bash 5.3.9
      `heredoc_write` deadlock wedged every `agent delete` call (even
      without --orphan-tasks) before the roster mutation completed.
      Standalone helper invoked file-as-argv keeps the path off the
      broken surface, same precedent as PR #940's registry/list/show
      helpers under lib/agent-cli-helpers/.
"""

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: roster-excise-block.py <roster_path> <agent>",
            file=sys.stderr,
        )
        return 2

    path = Path(sys.argv[1])
    agent = sys.argv[2]
    text = path.read_text(encoding="utf-8")
    begin = f"# BEGIN AGENT BRIDGE MANAGED ROLE: {agent}"
    end = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
    if begin not in text or end not in text:
        print(
            f"managed block not found for {agent}: {path}",
            file=sys.stderr,
        )
        return 1

    pattern = re.compile(
        rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n.*?^# END AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n?",
        flags=re.MULTILINE | re.DOTALL,
    )
    # Mirror bridge-agent.sh:717 — verify the regex matches exactly once
    # before writing. subn returns (new_text, count); refuse to write
    # unless exactly one managed block was excised.
    new_text, count = pattern.subn("", text, count=1)
    if count != 1:
        print(
            f"managed block not found or matched {count} times for {agent}: {path}",
            file=sys.stderr,
        )
        return 1

    # Collapse the triple-newline left behind by block removal
    # (cosmetic).
    new_text = re.sub(r"\n{3,}", "\n\n", new_text)
    path.write_text(new_text, encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
