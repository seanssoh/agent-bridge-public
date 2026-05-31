#!/usr/bin/env python3
"""Validate Claude settings.json points at the expected apiKeyHelper."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print(
            "usage: validate-claude-apikeyhelper-settings.py <settings.json> <expected-helper>",
            file=sys.stderr,
        )
        return 2

    settings_path = Path(args[0])
    expected = Path(args[1]).expanduser().resolve(strict=False)
    payload: Any = json.loads(settings_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        return 1

    actual_raw = payload.get("apiKeyHelper")
    if not isinstance(actual_raw, str) or not actual_raw:
        return 1
    actual = Path(actual_raw).expanduser()
    if not actual.is_absolute():
        return 1
    if actual.resolve(strict=False) != expected:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
