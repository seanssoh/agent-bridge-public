#!/usr/bin/env python3
"""Probe helper for scripts/smoke/1820-rc4-iso-mixed-host-skip.sh.

File-as-argv (footgun #11): the smoke shells out to this rather than piping a
heredoc into ``python3 -c``.

Per-AGENT inspection of a reconcile result JSON — the gate-2 #13364 mixed-host
contract. Given a result JSON and an agent id, print one space-separated line:

    1820-rc4-iso-mixed-host-skip-probe.py <result.json> <agent>

prints:

    <agent_perm_warning> <agent_iso_file_skip> <agent_data_skip_unreadable>

where (all scoped to <agent> ONLY):
    agent_perm_warning          1 if <agent> has a warning whose detail mentions
                                Errno 13 / "Permission denied", else 0
    agent_iso_file_skip         1 if <agent> has an isolation_v2_migration entry
                                with reason file-owner-only, else 0
    agent_data_skip_unreadable  1 if <agent> has a skipped[] entry whose reason
                                is v1_unreadable / v2_unreadable (the shared-mode
                                data-skip that pairs with the warning), else 0

The mixed-host assertion is: the ISO agent has (0, 1, 0) — a structured file-
owner-only skip, no warning, no data-skip; the SHARED agent has (1, 0, 1) — a
warning + unreadable data-skip, NOT downgraded.
"""

from __future__ import annotations

import json
import sys


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: <result.json> <agent>\n")
        return 2
    result_path, agent = argv
    result = _load(result_path)

    perm_warning = 0
    for w in result.get("warnings", []) or []:
        if w.get("agent") != agent:
            continue
        detail = str(w.get("detail", ""))
        if "Errno 13" in detail or "Permission denied" in detail:
            perm_warning = 1
            break

    iso_file_skip = 0
    for entry in result.get("isolation_v2_migration", []) or []:
        if entry.get("agent") == agent and entry.get("reason") == "file-owner-only":
            iso_file_skip = 1
            break

    data_skip = 0
    for s in result.get("skipped", []) or []:
        if s.get("agent") == agent and s.get("reason") in (
            "v1_unreadable",
            "v2_unreadable",
        ):
            data_skip = 1
            break

    sys.stdout.write(f"{perm_warning} {iso_file_skip} {data_skip}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
