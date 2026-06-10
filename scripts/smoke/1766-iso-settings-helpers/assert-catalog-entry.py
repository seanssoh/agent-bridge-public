#!/usr/bin/env python3
"""#1766 smoke helper: assert the claude-settings-error picker catalog entry.

Argv-only (footgun #11 — no stdin/heredoc). Usage:

    assert-catalog-entry.py <catalog.json> <picker_id>

Asserts the named entry exists and has the #1766 contract:
  * enabled == true
  * engine == "claude"
  * policy == "auto_resolve"
  * keys select option 3 deterministically: ["select_first","down","down","confirm"]
  * its `match` fingerprint includes the verbatim Settings-Error strings.

Prints `ok` and exits 0 on success; prints a reason + exits 1 otherwise.
"""
import json
import sys

REQUIRED_MATCH = (
    "Settings Error",
    "Settings file could not be read",
    "Continue without these settings",
)
EXPECT_KEYS = ["select_first", "down", "down", "confirm"]


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: assert-catalog-entry.py <catalog.json> <picker_id>\n")
        return 2
    catalog_path, picker_id = argv[1], argv[2]
    try:
        catalog = json.load(open(catalog_path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"cannot load catalog: {exc}\n")
        return 1
    entry = None
    for e in catalog.get("entries", []):
        if e.get("picker_id") == picker_id:
            entry = e
            break
    if entry is None:
        sys.stderr.write(f"entry {picker_id!r} not found\n")
        return 1
    if entry.get("enabled") is not True:
        sys.stderr.write(f"{picker_id} not enabled\n")
        return 1
    if entry.get("engine") != "claude":
        sys.stderr.write(f"{picker_id} engine != claude\n")
        return 1
    if entry.get("policy") != "auto_resolve":
        sys.stderr.write(f"{picker_id} policy != auto_resolve\n")
        return 1
    if entry.get("keys") != EXPECT_KEYS:
        sys.stderr.write(f"{picker_id} keys != {EXPECT_KEYS} (got {entry.get('keys')})\n")
        return 1
    match = entry.get("match") or []
    for needle in REQUIRED_MATCH:
        if needle not in match:
            sys.stderr.write(f"{picker_id} match missing {needle!r}\n")
            return 1
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
