#!/usr/bin/env python3
"""Probe helper for scripts/smoke/1820-iso-reconcile-permission.sh.

File-as-argv (footgun #11): the smoke shells out to this rather than piping a
heredoc into `python3 -c`.

Two modes:

1. Default (3 positional args): inspect a reconcile result JSON.
       1820-iso-reconcile-permission-probe.py <result.json> <v2_mem> <baseline_file>
   Prints one space-separated line:
       <errno13_in_warnings> <iso_count> <iso_first_action> <v2_drift>
   where:
       errno13_in_warnings  1 if any warning detail mentions Errno 13 / "Permission denied"
       iso_count            len(result["isolation_v2_migration"])
       iso_first_action     action of the first iso entry, or "-"
       v2_drift             1 if <v2_mem> bytes differ from the <baseline_file>
                            snapshot, else 0 (byte-exact, trailing newline kept)

2. --shared-control <result.json> <v2_mem>: assert the shared-mode (non-iso)
   reconcile DATA path is unchanged. Exits 0 iff:
       * isolation_v2_migration is an empty list,
       * no warnings,
       * exactly one preserved entry with direction prefix_superset_v1,
       * the v2 MEMORY.md was adopted to the v1 superset content ("a\\nb\\n").
   Exits non-zero otherwise.
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


def _shared_control(result_path: str, v2_mem: str) -> int:
    result = _load(result_path)
    iso = result.get("isolation_v2_migration")
    if iso != []:
        sys.stderr.write(f"shared-control: isolation_v2_migration not empty: {iso!r}\n")
        return 1
    warns = result.get("warnings") or []
    if warns:
        sys.stderr.write(f"shared-control: unexpected warnings: {warns!r}\n")
        return 1
    preserved = result.get("preserved") or []
    dirs = [p.get("direction") for p in preserved]
    if dirs != ["prefix_superset_v1"]:
        sys.stderr.write(f"shared-control: expected [prefix_superset_v1], got {dirs!r}\n")
        return 1
    try:
        with open(v2_mem, encoding="utf-8") as fh:
            content = fh.read()
    except OSError as exc:
        sys.stderr.write(f"shared-control: cannot read v2 memory: {exc}\n")
        return 1
    if content != "a\nb\n":
        sys.stderr.write(f"shared-control: v2 memory not adopted to superset: {content!r}\n")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--shared-control":
        if len(argv) != 3:
            sys.stderr.write("usage: --shared-control <result.json> <v2_mem>\n")
            return 2
        return _shared_control(argv[1], argv[2])

    if len(argv) != 3:
        sys.stderr.write("usage: <result.json> <v2_mem> <baseline_file>\n")
        return 2
    result_path, v2_mem, baseline_file = argv
    result = _load(result_path)
    errno13 = 1 if _has_errno13(result) else 0
    iso = result.get("isolation_v2_migration") or []
    iso_count = len(iso)
    first_action = iso[0].get("action", "-") if iso else "-"
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
    sys.stdout.write(f"{errno13} {iso_count} {first_action} {drift}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
