#!/usr/bin/env python3
"""Negative-control helper for scripts/smoke/1631-nudge-helper-db-guard.sh.

Reads bridge-daemon-helpers.py (argv[1]), reverts the #1631 guarded queue-DB
opens (``_connect_queue_db_readonly(db_path)``) back to the pre-fix unguarded
``sqlite3.connect(db_path)``, and writes the result to argv[2]. The smoke then
runs the reverted copy at a bogus DB path to confirm it reproduces the bug
(creates an empty DB + returns rc 0) — proving the guard is what flips the
behavior and that the smoke fails if the fix is reverted.

Standalone file-as-argv (no heredoc-stdin) per footgun #11.
"""
from __future__ import annotations

import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: revert-db-guard.py <src.py> <dst.py>\n")
        return 2
    src_path, dst_path = argv[1], argv[2]
    with open(src_path, "r", encoding="utf-8") as fh:
        text = fh.read()
    reverted = text.replace(
        "_connect_queue_db_readonly(db_path)",
        "sqlite3.connect(db_path)",
    )
    if reverted == text:
        sys.stderr.write(
            "negative control: nothing to revert — guard call "
            "'_connect_queue_db_readonly(db_path)' not found\n"
        )
        return 1
    with open(dst_path, "w", encoding="utf-8") as fh:
        fh.write(reverted)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
