#!/usr/bin/env python3
"""Extract bash function definitions by name from a shell source file.

Used by smoke drivers to source specific functions out of bridge-agent.sh
without executing its top-level dispatch. Robust against `}` lines that
appear inside heredocs (e.g. embedded Python literal dicts).

Convention: a function definition starts with `name() {` (optional
`function` keyword) and ends with a line containing exactly `}`. The
extractor tracks heredoc state (`<<TAG`, `<<-TAG`, `<<'TAG'`, `<<"TAG"`,
ignoring `<<<` here-strings) so closing braces inside heredoc bodies do
not terminate the function early.

Usage: extract-shell-fn.py <source-file> <fn-name> [<fn-name> ...]
Outputs the concatenated function bodies to stdout.
"""
from __future__ import annotations

import re
import sys


_FN_PATTERN_TEMPLATE = r"^\s*(?:function\s+)?{name}\s*\(\)\s*\{{?\s*$"
_HEREDOC_OPEN = re.compile(
    r"<<-?\s*([\'\"]?)([A-Za-z_][A-Za-z0-9_]*)\1"
)
_HERESTRING = re.compile(r"<<<")


def _extract_one(lines: list[str], fn_name: str) -> str:
    pattern = re.compile(_FN_PATTERN_TEMPLATE.format(name=re.escape(fn_name)))
    start = None
    for i, line in enumerate(lines):
        if pattern.match(line):
            start = i
            break
    if start is None:
        sys.stderr.write(f"extract-shell-fn: function not found: {fn_name}\n")
        sys.exit(2)

    out: list[str] = []
    heredoc_tag: str | None = None
    for i in range(start, len(lines)):
        line = lines[i]
        out.append(line)

        if heredoc_tag is not None:
            if line.strip() == heredoc_tag:
                heredoc_tag = None
            continue

        # Detect a new heredoc opener while ignoring `<<<` here-strings.
        scan = _HERESTRING.sub("", line)
        match = _HEREDOC_OPEN.search(scan)
        if match:
            heredoc_tag = match.group(2)
            continue

        if i > start and line == "}":
            break

    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(
            "usage: extract-shell-fn.py <source-file> <fn-name> [<fn-name> ...]\n"
        )
        return 2
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for fn_name in sys.argv[2:]:
        sys.stdout.write(_extract_one(lines, fn_name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
