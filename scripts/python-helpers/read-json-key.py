#!/usr/bin/env python3
"""Print one top-level JSON value as shell-friendly text."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print("usage: read-json-key.py <json-file> <key>", file=sys.stderr)
        return 2

    path = Path(args[0])
    key = args[1]
    payload: Any = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or key not in payload:
        return 1

    value = payload[key]
    if isinstance(value, bool):
        print("true" if value else "false")
    elif value is None:
        return 1
    else:
        print(str(value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
