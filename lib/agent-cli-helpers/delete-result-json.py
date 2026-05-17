#!/usr/bin/env python3
"""delete-result-json.py — render the `agent-bridge agent delete --json`
result envelope. Used by both the dry-run and apply branches in
`run_delete`.

Invocation contract (all required, all read from os.environ — same
shape as the original inline heredoc to avoid touching every caller):
    AGENT
    DELETED          ("0" | "1")
    DRY_RUN          ("0" | "1")
    PURGE_HOME       ("0" | "1")
    PURGE_CRONS      ("0" | "1")
    ORPHAN_TASKS     ("0" | "1")
    OPEN_COUNT       (str(int))
    CALLER_SOURCE
    BEFORE_SHA       (apply-only; "" on dry-run)
    AFTER_SHA        (apply-only; "" on dry-run)

Output: one JSON object on stdout. Mirrors the historical inline
payload exactly so on-disk parsers and the e2e harness see no schema
drift.

Refs:
    - Footgun #11 / KNOWN_ISSUES.md §26: the previous implementation
      used `python3 - <<'PY' … PY` heredoc-stdin. Standalone file
      invoked file-as-argv (zero positional args — payload is via
      env) keeps the path off the broken Bash 5.3.9 surface.
"""

import json
import os
import sys


def _flag(name: str) -> bool:
    return os.environ.get(name, "0") == "1"


def main() -> int:
    payload = {
        "agent": os.environ["AGENT"],
        "deleted": _flag("DELETED"),
        "dry_run": _flag("DRY_RUN"),
        "purge_home": _flag("PURGE_HOME"),
        "purge_crons": _flag("PURGE_CRONS"),
        "orphan_tasks": _flag("ORPHAN_TASKS"),
        "open_inbox_tasks": int(os.environ.get("OPEN_COUNT") or 0),
        "caller_source": os.environ["CALLER_SOURCE"],
    }
    before_sha = os.environ.get("BEFORE_SHA", "")
    after_sha = os.environ.get("AFTER_SHA", "")
    if before_sha or after_sha:
        # Apply-path emits both; preserve key order parity with the old
        # inline body (before_sha before after_sha).
        payload["before_sha"] = before_sha
        payload["after_sha"] = after_sha

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
