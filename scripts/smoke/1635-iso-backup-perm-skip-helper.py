#!/usr/bin/env python3
"""Tiny JSON probe for the #1635 iso-backup-perm-skip smoke.

Keeps the shell smoke free of a jq dependency. The `backup-live` payload is
fed on argv (for list-has-path) or stdin (for field).

Usage:
  field <key>                 # read payload from stdin, print payload[key]
  list-has-path <json> <key> <substr>
                              # exit 0 iff some payload[key][i]["path"]
                              #   contains substr (a list of {path,...})
  manifest-state <manifest_path> <relpath>
                              # print the `state` of the manifest entry whose
                              #   path == relpath, or "MISSING" if absent
"""

from __future__ import annotations

import json
import sys


def _load(text: str) -> dict:
    # backup-live prints an indented JSON object as the only stdout block.
    return json.loads(text)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: field|list-has-path ...", file=sys.stderr)
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

    if mode == "list-has-path":
        if len(argv) != 4:
            print("usage: list-has-path <json> <key> <substr>", file=sys.stderr)
            return 2
        payload = _load(argv[1])
        items = payload.get(argv[2]) or []
        for item in items:
            if isinstance(item, dict) and argv[3] in str(item.get("path", "")):
                return 0
        return 1

    if mode == "manifest-state":
        if len(argv) != 3:
            print("usage: manifest-state <manifest_path> <relpath>", file=sys.stderr)
            return 2
        with open(argv[1], encoding="utf-8") as handle:
            manifest = json.load(handle)
        for entry in manifest.get("entries") or []:
            if isinstance(entry, dict) and entry.get("path") == argv[2]:
                print(entry.get("state"))
                return 0
        print("MISSING")
        return 0

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
