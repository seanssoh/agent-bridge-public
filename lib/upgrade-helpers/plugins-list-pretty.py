#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-list-pretty.py — read the JSON output of
plugins-list-json.py on stdin and emit a human-readable table.

Used by `agb plugins list` (without --json) to keep the wire-format
(JSON helper) and human-format paths consistent. stdin-only (NOT a
heredoc-to-subprocess pattern — bridge-plugins.sh pipes JSON via `|`,
which is a regular pipe, not a heredoc).
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"plugins-list-pretty: failed to parse stdin: {exc}\n")
        return 2
    plugin_count = payload.get("plugin_count", 0)
    print(f"plugin_count: {plugin_count}")
    plugins = payload.get("plugins") or []
    if not plugins:
        return 0
    print("plugins:")
    for entry in plugins:
        spec = entry.get("spec") or f"{entry.get('name', '?')}@{entry.get('marketplace', '?')}"
        version = entry.get("version", "")
        install_path = entry.get("installPath", "")
        # Compact one-line per plugin — operators scanning the output
        # care about (spec, version, path).
        print(f"  - {spec}  version={version}  installPath={install_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
