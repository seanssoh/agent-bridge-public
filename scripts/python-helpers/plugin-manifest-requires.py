#!/usr/bin/env python3
"""Print a plugin manifest's optional `requires` channel specs, one per line.

Reads `.claude-plugin/plugin.json` at the path given as argv[1] and emits each
element of the (optional) top-level `"requires"` array on its own line. This is
the generic plugin-dependency hook consumed by `bridge_expand_channel_requires`
in lib/bridge-agents.sh: a plugin may declare other channel specs it needs (e.g.
`["plugin:ms365@agent-bridge"]`) and the agent-create path transitively pulls
them into the resolved channel set.

Invoked file-as-argv (NOT heredoc-stdin) to avoid the Bash 5.3.9
`read_comsub`/`heredoc_write` deadlock (footgun #11 / KNOWN_ISSUES.md §26).

Contract:
  * Missing file / unreadable / invalid JSON  -> print nothing, exit 0.
    (The caller treats "no requires" and "couldn't read" identically at the
    leaf level; an *unresolvable plugin dir* is handled one layer up by the
    bash resolver, which warns-and-continues. A manifest that exists but is
    corrupt is not operator-actionable here — emit nothing so create proceeds.)
  * `requires` absent or not a list          -> print nothing, exit 0.
  * `requires` present                        -> print each string element,
    trimmed, one per line, skipping empties and non-string entries.

No domain knowledge: this helper never inspects the plugin name or marketplace.
It only forwards whatever channel specs the manifest declares.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        return 0

    path = Path(sys.argv[1])
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0

    if not isinstance(payload, dict):
        return 0

    requires = payload.get("requires")
    if not isinstance(requires, list):
        return 0

    out: list[str] = []
    for entry in requires:
        if not isinstance(entry, str):
            continue
        spec = entry.strip()
        if spec:
            out.append(spec)

    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
