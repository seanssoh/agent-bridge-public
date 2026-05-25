#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-seed-marketplace-name.py — standalone helper
for `agb plugins seed` (bridge-plugins.sh).

Reads a marketplace.json and prints just the `name` field. Empty output
if the file is unreadable or has no name. File-as-argv per footgun #11
(no heredoc-stdin to subprocess); see KNOWN_ISSUES.md §26.

Usage:
  python3 lib/upgrade-helpers/plugins-seed-marketplace-name.py <marketplace.json>
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: plugins-seed-marketplace-name.py <marketplace.json>\n")
        return 2
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        sys.stderr.write(f"failed to read {path}: {exc}\n")
        return 1
    name = (payload.get("name") or "").strip()
    if name:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
