#!/usr/bin/env python3
"""next-actions-tsv-to-json.py — issue #1360.

Convert a `bridge_agent_next_actions_tsv` TSV blob into the JSON shape
the `agent show --json` envelope embeds at `.next_actions`.

Invocation contract (1 positional argument — file path):
    sys.argv[1] = path to a tempfile containing the TSV blob produced
                  by bridge_agent_next_actions_tsv.

Output (stdout, single line, no trailing newline beyond json.dumps default):
    JSON array of {"run": str, "reason": str, "placeholder_safe": bool}.

Footgun #11 (KNOWN_ISSUES.md §26): this body used to live as
`python3 - "$tsv" <<'PY' ... PY` inline in lib/bridge-agents.sh's
`bridge_agent_next_actions_json` shell function. Codex r1 review on
PR #1364 flagged the heredoc-stdin pattern as a reintroduction of the
Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock class. The contract
documented at bridge-agent.sh:2041-2045 — "no heredoc-stdin to
subprocess in this hot path" — applies equally to any helper that the
`show` data pipeline calls. Moved to a standalone file invoked via
`python3 next-actions-tsv-to-json.py <tsv-path>` so the parent shell
function spools the TSV to a tempfile and passes the path as argv,
matching the show-format-json.py precedent (same dir, same pattern).
"""

import csv
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: next-actions-tsv-to-json.py <tsv-file>",
            file=sys.stderr,
        )
        return 2

    tsv_path = sys.argv[1]
    with open(tsv_path, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))

    payload = []
    for row in rows:
        entry = {
            "run": row["run"],
            "reason": row["reason"],
            "placeholder_safe": row["placeholder_safe"] == "yes",
        }
        payload.append(entry)

    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
