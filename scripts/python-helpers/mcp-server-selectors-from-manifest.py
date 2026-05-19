#!/usr/bin/env python3
"""Print Claude `server:<name>` selectors from a plugin `.mcp.json` file."""

import json
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("")
        return 0

    path = Path(sys.argv[1])
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("")
        return 0

    servers = payload.get("mcpServers")
    if not isinstance(servers, dict):
        print("")
        return 0

    selectors: list[str] = []
    seen: set[str] = set()
    for name in servers:
        if not isinstance(name, str):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            continue
        selector = f"server:{name}"
        if selector in seen:
            continue
        seen.add(selector)
        selectors.append(selector)

    print(",".join(selectors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
