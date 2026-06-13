#!/usr/bin/env python3
"""Probe helper for scripts/smoke/1820-rc4-iso-stale-group-preflight.sh.

File-as-argv (footgun #11): the smoke shells out to this rather than piping a
heredoc into `python3 -c`.

Mode: inspect a reconcile result JSON for the rc4 file-level iso skip behavior.
    1820-rc4-iso-stale-group-probe.py <result.json> <agent> <v2_mem> <baseline>
Prints one space-separated line:
    <errno13_in_warnings> <iso_count> <iso_first_action> <iso_first_reason> \
        <agent_iso_skip> <v2_drift>
where:
    errno13_in_warnings  1 if any warning detail mentions Errno 13 / "Permission
                         denied", else 0
    iso_count            len(result["isolation_v2_migration"])
    iso_first_action     action of the first iso entry, or "-"
    iso_first_reason     reason of the first iso entry, or "-"
    agent_iso_skip       1 if <agent> has an isolation_v2_migration entry with
                         reason file-owner-only, else 0 (proves the named agent —
                         e.g. the no-meta mdj case — was handled at file level)
    v2_drift             1 if <v2_mem> bytes differ from the <baseline> snapshot,
                         else 0 (byte-exact, trailing newline kept)
"""

from __future__ import annotations

import json
import sys


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _has_errno13(result: dict) -> bool:
    for w in result.get("warnings", []) or []:
        detail = str(w.get("detail", ""))
        if "Errno 13" in detail or "Permission denied" in detail:
            return True
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write("usage: <result.json> <agent> <v2_mem> <baseline>\n")
        return 2
    result_path, agent, v2_mem, baseline_file = argv
    result = _load(result_path)
    errno13 = 1 if _has_errno13(result) else 0
    iso = result.get("isolation_v2_migration") or []
    iso_count = len(iso)
    first_action = iso[0].get("action", "-") if iso else "-"
    first_reason = iso[0].get("reason", "-") if iso else "-"
    agent_iso_skip = 0
    for entry in iso:
        if entry.get("agent") == agent and entry.get("reason") == "file-owner-only":
            agent_iso_skip = 1
            break
    try:
        with open(v2_mem, "rb") as fh:
            cur = fh.read()
    except OSError:
        cur = None
    try:
        with open(baseline_file, "rb") as fh:
            base = fh.read()
    except OSError:
        base = None
    drift = 0 if (cur is not None and base is not None and cur == base) else 1
    sys.stdout.write(
        f"{errno13} {iso_count} {first_action} {first_reason} "
        f"{agent_iso_skip} {drift}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
