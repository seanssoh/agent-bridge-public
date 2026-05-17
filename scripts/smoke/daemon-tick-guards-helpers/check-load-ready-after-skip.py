#!/usr/bin/env python3
"""scripts/smoke/daemon-tick-guards-helpers/check-load-ready-after-skip.py

PR #952 r3 P2 #2 in-source guard. Asserts that inside bridge-queue.py's
cmd_daemon_step, the first call to load_ready_agents(...) appears AFTER
the `if getattr(args, "skip_nudges", False):` short-circuit. If the call
order ever regresses (load before the skip check), a broken/blocking
ready-agents file would hang the maintenance-only path again.

Extracted from the smoke heredoc to dodge the Bash 5.3.9 heredoc-write
deadlock (CLAUDE.md footgun #11, lib/upgrade-helpers/ precedent).

Usage: check-load-ready-after-skip.py <path/to/bridge-queue.py>
Exit codes:
  0 — order is correct (load after skip)
  1 — regression (load before skip) or anchor missing
"""

from __future__ import annotations

import re
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "usage: check-load-ready-after-skip.py <bridge-queue.py>",
            file=sys.stderr,
        )
        return 1
    path = argv[1]
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 1

    # Carve out cmd_daemon_step's body so we don't pick up references in
    # neighbouring functions. The function ends at the next top-level
    # `def `; this regex captures everything up to that boundary.
    match = re.search(
        r"def cmd_daemon_step\(.*?\n(?=\Sdef |\Z)",
        src,
        re.DOTALL,
    )
    fn = match.group(0) if match else src

    load_idx = fn.find("load_ready_agents(")
    skip_idx = fn.find('if getattr(args, "skip_nudges", False):')
    if load_idx == -1:
        print(
            "anchor missing: load_ready_agents(...) call not found in "
            "cmd_daemon_step. Did the deferred-load branch get refactored "
            "away?",
            file=sys.stderr,
        )
        return 1
    if skip_idx == -1:
        print(
            "anchor missing: `if getattr(args, \"skip_nudges\", False):` "
            "not found in cmd_daemon_step. Did the --skip-nudges short-"
            "circuit get refactored away?",
            file=sys.stderr,
        )
        return 1
    if load_idx < skip_idx:
        print(
            "PR #952 r3 P2 #2 regression: load_ready_agents called BEFORE "
            f"the skip_nudges check (load_idx={load_idx}, "
            f"skip_idx={skip_idx}). r3 requires the load to live in the "
            "non-skip branch so a broken/blocking ready-agents file does "
            "not hang the maintenance-only path.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
