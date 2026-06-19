#!/usr/bin/env python3
"""wiki-ingest-librarian-live.py — Lane B librarian liveness gate (issue #1983).

File-as-argv helper for scripts/wiki-daily-ingest.sh. Answers the single
question the Lane B target selection actually needs: is the `librarian`
agent currently LIVE (active/running), not merely present in the roster?

`agb agent show librarian` only proves the role *exists*. A stopped-but-
present librarian still satisfies `agent show`, so keying target selection on
existence chose `librarian` even when it was down — and `agb task create --to
librarian` then failed (an inactive agent needs `--force`), the failure was
swallowed by `|| true`, and the run/audit log falsely claimed a successful
enqueue while Lane B captures were silently dropped (#1983). The designed
`$BRIDGE_ADMIN_AGENT` fallback never engaged.

This helper reads the same `agb agent list --json` payload the script already
fetches and reports librarian's liveness via its `active` flag — the canonical
liveness signal the rest of the bridge uses (bridge_agent_is_active) — so the
fallback genuinely engages when librarian is stopped.

Extracted to a standalone file (invoked ``python3 <file> <json>``) rather than
a ``python3 - <<'PY'`` heredoc-stdin: the heredoc-stdin form is the Bash 5.3.9
read_comsub/heredoc_write deadlock class (footgun #11) and is tracked by
scripts/lint-heredoc-ban.sh.

Exit codes:
  0  — a roster entry named `librarian` is present AND active (live).
  1  — librarian is absent, inactive, or the payload cannot be parsed.

Usage:
  wiki-ingest-librarian-live.py <agent_list_json>
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 1
    try:
        data = json.loads(argv[1])
    except (ValueError, TypeError):
        return 1
    if not isinstance(data, list):
        return 1
    for entry in data:
        if not isinstance(entry, dict):
            continue
        if entry.get("agent") != "librarian":
            continue
        return 0 if bool(entry.get("active")) else 1
    # No librarian entry in the roster — not live.
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
