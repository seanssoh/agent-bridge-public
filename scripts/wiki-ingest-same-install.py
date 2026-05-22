#!/usr/bin/env python3
"""wiki-ingest-same-install.py — Lane B same-install guard (issue #1042).

File-as-argv helper for scripts/wiki-daily-ingest.sh. Proves that the AGB
binary, the resolved task DB, and the state root all resolve under the
intended $BRIDGE_HOME before a [librarian-ingest] task is created — so a
hermetic smoke/repro run with a temp BRIDGE_HOME cannot leak a
fixture-derived task into a different install's live queue.

Extracted to a standalone file (invoked ``python3 <file> <args>``) rather
than a ``python3 - <<'PY'`` heredoc-stdin: the heredoc-stdin form is the
Bash 5.3.9 read_comsub/heredoc_write deadlock class (footgun #11) and is
banned by scripts/lint-heredoc-ban.sh.

A plain path-prefix string compare is not enough — symlinks and ``..``
segments could defeat it — so every path is canonicalised first.

Exit codes:
  0  — BRIDGE_AGB, the task DB, and the state root all canonicalise under
       BRIDGE_HOME (same install — safe to enqueue)
  1  — at least one resolves outside BRIDGE_HOME (cross-install — refuse)

Usage:
  wiki-ingest-same-install.py <bridge_home> <bridge_agb> <task_db> <state_dir>
"""

from __future__ import annotations

import os
import sys


def _canon(path: str) -> str:
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        # Missing arguments — fail closed (treat as cross-install).
        return 1
    home, agb, task_db, state_dir = argv[1:5]
    home_c = _canon(home)

    def under(path: str) -> bool:
        pc = _canon(path)
        return pc == home_c or pc.startswith(home_c + os.sep)

    # All three live-install anchors must resolve under $BRIDGE_HOME.
    return 0 if (under(agb) and under(task_db) and under(state_dir)) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
