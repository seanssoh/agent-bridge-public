#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-marketplaces-pretty.py — read the JSON
output of plugins-marketplaces-json.py on stdin and emit a
human-readable table.

Used by `agb plugins marketplaces` (without --json). stdin-only (NOT a
heredoc-to-subprocess pattern — bridge-plugins.sh pipes JSON via `|`,
which is a regular pipe).
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"plugins-marketplaces-pretty: failed to parse stdin: {exc}\n")
        return 2
    count = payload.get("marketplace_count", 0)
    print(f"marketplace_count: {count}")
    entries = payload.get("marketplaces") or []
    if not entries:
        return 0
    print("marketplaces:")
    for entry in entries:
        mid = entry.get("id", "?")
        source = entry.get("source") or {}
        kind = source.get("kind", "") if isinstance(source, dict) else ""
        path = source.get("path", "") if isinstance(source, dict) else ""
        print(f"  - {mid}  source.kind={kind}  source.path={path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
