#!/usr/bin/env python3
"""lib/lint-helpers/validate-jsonl.py — verify a JSON-lines file is valid
and every row has the expected keys.

Used by scripts/smoke/lint-heredoc-scanner-self.sh to validate audit script
--json output without using heredoc-stdin (footgun #11 avoidance).

Args:
    sys.argv[1]  jsonl file path
    sys.argv[2..]  required keys (one per arg)

Exit code:
    0  every line parses and every required key is present
    1  malformed line or missing key (details printed to stderr)
    2  argv error
"""
from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: validate-jsonl.py JSONL_PATH [KEY ...]", file=sys.stderr)
        return 2
    path = argv[1]
    required_keys = argv[2:]

    with open(path, encoding="utf-8") as fh:
        for i, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception as exc:
                print(f"INVALID JSON on line {i}: {exc}", file=sys.stderr)
                print(f"row: {line[:200]}", file=sys.stderr)
                return 1
            for k in required_keys:
                if k not in obj:
                    print(f"missing key {k!r} in row {i}: {line[:200]}", file=sys.stderr)
                    return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
