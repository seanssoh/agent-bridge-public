#!/usr/bin/env python3
"""Revert helper for scripts/smoke/1693-read-viewers.sh.

Produces a copy of hooks/tool-policy.py with issue #1693's read-intent
viewer additions REMOVED from ``_READ_INTENT_BASH_COMMANDS`` (and, for the
Part-2 teeth, with the narrowed short-needle prefix set restored to the
broad ``_PATH_PREFIX_CHARS``). The smoke re-runs its ALLOW assertions
against this reverted policy and requires them to FAIL (i.e. the reverted
policy DENIES the read), proving the smoke genuinely exercises the fix and
would catch a regression that removed it.

Standalone script invoked with file-as-argv (footgun #11 — no interpreter
here-string / heredoc-stdin).

Usage: 1693-read-viewers-revert.py <src-policy> <dst-policy>
"""
from __future__ import annotations

import sys

# The exact viewer string literals issue #1693 adds to
# _READ_INTENT_BASH_COMMANDS. Removing their `"name",` lines reverts Part 1.
_ADDED_VIEWERS = (
    "strings",
    "hexdump",
    "comm",
    "fold",
    "expand",
    "paste",
    "csvlook",
)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: 1693-read-viewers-revert.py <src> <dst>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as fh:
        lines = fh.readlines()

    out = []
    removed = 0
    part2_reverted = 0
    for line in lines:
        stripped = line.strip()
        # Drop the bare `"viewer",` frozenset entries this PR added.
        if stripped in {f'"{v}",' for v in _ADDED_VIEWERS}:
            removed += 1
            continue
        # Part-2 revert: restore the pre-#1693 broad-prefix behavior so the
        # short-needle prose over-fire returns. The fix replaced the inline
        # `command[idx - 1] in _PATH_PREFIX_CHARS` test with a call to
        # `_short_needle_at_write_position(command, idx)` (which excludes the
        # prose-punctuation chars). Swap that call back to the broad single-
        # char check so the reverted policy denies the prose quote mention
        # again — the smoke asserts that flip.
        if "if _short_needle_at_write_position(command, idx):" in line:
            indent = line[: len(line) - len(line.lstrip())]
            line = f"{indent}if command[idx - 1] in _PATH_PREFIX_CHARS:\n"
            part2_reverted += 1
        out.append(line)

    if removed != len(_ADDED_VIEWERS):
        print(
            f"revert helper: expected to remove {len(_ADDED_VIEWERS)} viewer "
            f"lines, removed {removed} (policy drifted?)",
            file=sys.stderr,
        )
        return 3
    if part2_reverted != 1:
        print(
            f"revert helper: expected to revert 1 short-needle prefix check, "
            f"reverted {part2_reverted} (policy drifted?)",
            file=sys.stderr,
        )
        return 3

    with open(dst, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
