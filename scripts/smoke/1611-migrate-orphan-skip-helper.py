#!/usr/bin/env python3
"""Tiny JSON probe for the #1611 migrate-orphan-skip smoke.

Keeps the shell smoke free of a jq dependency. The migrate-agents payload
is fed on argv (for list-has / sources-has) or stdin (for field).

Usage:
  field <key>                 # read payload from stdin, print payload[key]
  list-has <json> <key> <val> # exit 0 iff val in payload[key] (a list)
  sources-has <val>           # read payload from stdin; print yes/no if
                              #   val in payload["roster_sources"]
"""

from __future__ import annotations

import json
import sys


def _load(text: str) -> dict:
    # The migrator prints an indented JSON object as the only stdout block.
    return json.loads(text)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: field|list-has|sources-has ...", file=sys.stderr)
        return 2

    mode = argv[0]

    if mode == "field":
        if len(argv) != 2:
            print("usage: field <key>", file=sys.stderr)
            return 2
        payload = _load(sys.stdin.read())
        value = payload.get(argv[1])
        if isinstance(value, (dict, list)):
            print(json.dumps(value))
        else:
            print(value)
        return 0

    if mode == "list-has":
        if len(argv) != 4:
            print("usage: list-has <json> <key> <val>", file=sys.stderr)
            return 2
        payload = _load(argv[1])
        items = payload.get(argv[2]) or []
        return 0 if argv[3] in items else 1

    if mode == "sources-has":
        if len(argv) != 2:
            print("usage: sources-has <val>", file=sys.stderr)
            return 2
        payload = _load(sys.stdin.read())
        sources = payload.get("roster_sources") or []
        print("yes" if argv[1] in sources else "no")
        return 0

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
