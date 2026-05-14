#!/usr/bin/env python3
"""Extract a GitHub repo slug for a marketplace from known_marketplaces.json.

Issue #853 (controller-side marketplace silent drift): Claude Code's
`claude plugin marketplace list` can silently stop enumerating a
marketplace even though the underlying `known_marketplaces.json` row
still names the source repo. When an isolated agent's roster declares a
plugin from such a marketplace, `claude plugin install` on the controller
side fails with `Plugin "<name>" not found in marketplace "<mkt>"` and
the operator has no actionable signal until they compare the two
manually.

This helper extracts the `source.repo` value for a single marketplace
entry so the bash caller can run `claude plugin marketplace add <repo>`
to self-heal before retrying the install. The lookup is intentionally
narrow: only `source.source == "github"` entries are honoured. Directory
sources, the special agent-bridge marketplace, and entries missing a
parseable repo slug print the empty string — callers treat that as
"cannot self-heal; degrade to the existing legacy install-and-warn
path."

Lives as a standalone helper (rather than inline in
`lib/bridge-agents.sh`) to bypass the bash heredoc-read class that has
wedged hot-path shell-outs on recent Homebrew Bash builds. (Forbidden
pattern strings intentionally omitted from this comment so the footgun
#11 self-audit grep recipe does not flag a textual mention as a real
callsite.)

Args (positional):
    sys.argv[1] — path to known_marketplaces.json
    sys.argv[2] — marketplace name (e.g. "cosmax-marketplace")

Stdout: the GitHub repo slug (e.g. "COSMAX-PI-Dev-Team/claude-plugin-
registry") if the marketplace entry has a github-source repo declared,
or the empty string otherwise. Always exits 0.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    catalog_path = Path(sys.argv[1])
    marketplace = sys.argv[2]

    try:
        payload = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("")
        return 0

    if not isinstance(payload, dict):
        print("")
        return 0

    entry = payload.get(marketplace)
    if not isinstance(entry, dict):
        print("")
        return 0

    source = entry.get("source")
    if not isinstance(source, dict):
        print("")
        return 0

    # Only github-source marketplaces are eligible for the
    # `claude plugin marketplace add <slug>` self-heal path. The
    # directory-source agent-bridge marketplace re-adds via
    # bridge_ensure_agent_bridge_claude_marketplace (separate code path)
    # and other directory sources require operator action anyway because
    # the controller cannot derive an `add` argument from the cached
    # entry alone.
    if source.get("source") != "github":
        print("")
        return 0

    repo = source.get("repo")
    if not isinstance(repo, str) or not repo.strip():
        print("")
        return 0

    print(repo.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
