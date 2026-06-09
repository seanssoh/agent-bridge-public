#!/usr/bin/env python3
"""codex-orphan-cleanup-summary.py — render a single REDACTED audit line from
a codex-orphan-cleanup report (issue #1567).

Reads the JSON report on stdin (emitted by `codex-orphan-cleanup.py --json`)
and prints ONE audit line carrying counts + pids + reclaimable RSS only — NO
--cwd / --bridge-home paths (which can carry operator usernames) and NO env.
The full detail lives in the persisted report file the shim references.

Invoked via `printf '%s' "$json" | python3 codex-orphan-cleanup-summary.py`
from codex-orphan-cleanup.sh. Stdin (not file-as-argv) is fine here: this is a
plain Python filter, NOT a heredoc-stdin subprocess inside bridge-upgrade.sh,
so it is outside the footgun #11 / lint-heredoc-ban surface.

On malformed / empty input it prints `total=0` and exits 0 so the shim's audit
line is always well-formed.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("total=0")
        return 0
    try:
        report = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print("total=0")
        return 0

    counts = report.get("counts", {}) or {}
    total = int(counts.get("total", 0) or 0)
    by_class = counts.get("by_class", {}) or {}
    rss_kb = int(report.get("reclaimable_rss_kb", 0) or 0)
    candidates = report.get("candidates", []) or []

    pids = ",".join(str(c.get("pid")) for c in candidates if c.get("pid") is not None)
    class_bits = " ".join(
        f"{klass}={count}" for klass, count in sorted(by_class.items())
    )

    parts = [f"total={total}"]
    if class_bits:
        parts.append(class_bits)
    parts.append(f"rss_kb={rss_kb}")
    if pids:
        parts.append(f"pids=[{pids}]")
    print(" ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
