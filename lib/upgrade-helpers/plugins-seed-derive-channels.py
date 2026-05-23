#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-seed-derive-channels.py — standalone helper
for `agb plugins seed` (bridge-plugins.sh).

Reads a marketplace.json and prints a comma-separated `plugin:<name>@<mkt>`
list for every plugin entry. File-as-argv per footgun #11 (no
heredoc-stdin to subprocess); see KNOWN_ISSUES.md §26.

Usage:
  python3 lib/upgrade-helpers/plugins-seed-derive-channels.py <marketplace.json>
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: plugins-seed-derive-channels.py <marketplace.json>\n")
        return 2
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        sys.stderr.write(f"failed to read {path}: {exc}\n")
        return 1
    mkt_name = (payload.get("name") or "").strip()
    plugins = payload.get("plugins") or []
    items: list[str] = []
    for entry in plugins:
        name = (entry.get("name") or "").strip()
        if name and mkt_name:
            items.append(f"plugin:{name}@{mkt_name}")
    print(",".join(items))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
