#!/usr/bin/env python3
"""codex-sync-summary.py — render the Codex fleet-sync JSON envelope.

Fleet-credential Phase 2 (#1470). `bridge_auth_codex_sync_agents`
(bridge-auth.sh) drives the per-agent write-through, then needs to emit a
single structured JSON summary the daemon/CLI can audit. Building that JSON
inline as a `python3 - <<'PY' … PY` heredoc-stdin in command substitution
trips the Bash 5.3.9 read_comsub/heredoc_write deadlock the repo bans
(footgun #11 / KNOWN_ISSUES §26). This standalone helper takes everything
as argv (no stdin), so the bash caller invokes it as a plain command.

Invocation contract:
    codex-sync-summary.py <source_agent> <rc> \
        synced:<space-separated names> \
        unchanged:<space-separated names> \
        failed:<space-separated names>

Each of the last three argv items is a single string whose prefix names the
bucket and whose remainder (after the first colon) is the space-separated
agent list (possibly empty). Output: one pretty-printed JSON document.
"""

from __future__ import annotations

import json
import sys


def _bucket(arg: str, prefix: str) -> list[str]:
    if not arg.startswith(prefix + ":"):
        return []
    rest = arg[len(prefix) + 1 :].strip()
    if not rest:
        return []
    return [name for name in rest.split() if name]


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        print(
            "usage: codex-sync-summary.py <source_agent> <rc> "
            "synced:<names> unchanged:<names> failed:<names>",
            file=sys.stderr,
        )
        return 2
    source_agent = argv[1]
    try:
        rc = int(argv[2])
    except (TypeError, ValueError):
        rc = 1
    synced = _bucket(argv[3], "synced")
    unchanged = _bucket(argv[4], "unchanged")
    failed = _bucket(argv[5], "failed")

    if failed:
        status = "failed" if not (synced or unchanged) else "partial"
    elif synced:
        status = "ok"
    else:
        # Nothing changed (all dests already current) or no dests selected.
        status = "ok"

    print(
        json.dumps(
            {
                "status": status,
                "engine": "codex",
                "source_agent": source_agent,
                "rc": rc,
                "synced": synced,
                "unchanged": unchanged,
                "failed": failed,
            },
            ensure_ascii=True,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
