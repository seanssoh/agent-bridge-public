#!/usr/bin/env python3
"""Stop-chain assertions for upgrade-shared-settings-propagate (#9780).

File-as-argv helper so the smoke does not embed a python3 heredoc-stdin in a
command substitution (footgun #11 / scripts/lint-heredoc-ban.sh C1 deadlock
class). Two modes:

  has <settings.json> <needle>     → prints "yes"/"no" if a Stop hook command
                                      contains <needle>.
  order <settings.json>            → prints "yes" when the Stop chain order is
                                      surface-reply-enforce → inbox-auto-drain →
                                      session-stop, else "no".
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def _flat_stop_commands(settings_path: str) -> list[str]:
    data = json.loads(Path(settings_path).read_text(encoding="utf-8"))
    stop = data.get("hooks", {}).get("Stop", [])
    return [
        h.get("command", "")
        for grp in stop
        for h in grp.get("hooks", [])
    ]


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: stop-chain-probe.py <has|order> <settings.json> [needle]\n")
        return 2
    mode, settings_path = argv[1], argv[2]
    flat = _flat_stop_commands(settings_path)

    if mode == "has":
        if len(argv) != 4:
            sys.stderr.write("usage: stop-chain-probe.py has <settings.json> <needle>\n")
            return 2
        needle = argv[3]
        print("yes" if any(needle in c for c in flat) else "no")
        return 0

    if mode == "order":
        def idx(needle: str) -> int:
            for i, c in enumerate(flat):
                if needle in c:
                    return i
            return -1
        s = idx("surface-reply-enforce.py")
        d = idx("inbox-auto-drain.py")
        ss = idx("session-stop.py")
        print("yes" if -1 not in (s, d, ss) and s < d < ss else "no")
        return 0

    sys.stderr.write(f"unknown mode: {mode}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
