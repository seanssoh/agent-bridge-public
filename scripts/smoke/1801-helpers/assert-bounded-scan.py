#!/usr/bin/env python3
"""Assertion helper for scripts/smoke/1801-watchdog-bounded-broken-links.sh.

Extracted to a standalone file (footgun #11: no heredoc-stdin to a
subprocess capture). Invoked as:

    assert-bounded-scan.py <case> <scan-json> <agent-id>

where <case> is one of t1..t4. Exits 0 on success, non-zero with a
diagnostic on failure.
"""
from __future__ import annotations

import json
import sys


def _agent_row(scan_json: str, agent_id: str) -> dict:
    data = json.loads(scan_json)
    rows = [a for a in data.get("agents", []) if a.get("agent") == agent_id]
    if not rows:
        raise AssertionError(
            f"agent {agent_id!r} not in scan output "
            f"(agents={[a.get('agent') for a in data.get('agents', [])]})"
        )
    return rows[0]


def _fail(msg: str) -> None:
    print(f"[1801-assert] FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def case_t1(row: dict) -> None:
    """Complete scan + exclusions."""
    if row["broken_links_truncated"]:
        _fail("T1: broken_links_truncated should be False on a complete scan")
    if row["broken_links_scan_skipped"]:
        _fail("T1: broken_links_scan_skipped should be False on a complete scan")
    links = row["broken_links"]
    if not any("broken-top" in link for link in links):
        _fail(f"T1: genuine top-level broken link missing from {links}")
    if not any("broken-sub" in link for link in links):
        _fail(f"T1: genuine depth-1 broken link missing from {links}")
    if any("stale-" in link or ".cache" in link for link in links):
        _fail(f"T1: excluded .cache dir leaked into broken_links: {links}")


def case_t2(row: dict) -> None:
    """Truncated by max-entries (forced low)."""
    if not row["broken_links_truncated"]:
        _fail("T2: max-entries bound should set broken_links_truncated=True")
    if row["broken_links_scan_skipped"]:
        _fail("T2: a truncated scan is not a skipped scan")
    if not row["broken_links"]:
        _fail("T2: truncated scan must return a non-empty partial list (no silent cap)")
    if "entries" not in (row.get("broken_links_note") or ""):
        _fail(f"T2: note should name the entries bound, got {row.get('broken_links_note')!r}")
    # Real drift still surfaces (broken links found → warn), the scanner
    # limitation does not crash the row.
    if row["status"] not in {"warn", "error"}:
        _fail(f"T2: genuine broken links should drive warn/error, got status={row['status']!r}")


def case_t3(row: dict) -> None:
    """Truncated by max-depth (forced low); deep link not reported."""
    if not row["broken_links_truncated"]:
        _fail("T3: max-depth bound should set broken_links_truncated=True")
    links = row["broken_links"]
    if not any("broken-shallow" in link for link in links):
        _fail(f"T3: shallow broken link (within depth cap) should be reported, got {links}")
    if any("broken-deep" in link for link in links):
        _fail(f"T3: link below max-depth must NOT be reported, got {links}")


def case_t4(row: dict) -> None:
    """Skipped: HOME-scale workdir."""
    if not row["broken_links_scan_skipped"]:
        _fail("T4: HOME-scale workdir should set broken_links_scan_skipped=True")
    if row["broken_links_truncated"]:
        _fail("T4: a skipped scan is not a truncated scan")
    if row["broken_links"]:
        _fail(f"T4: a skipped scan returns an empty list, got {row['broken_links']}")
    note = row.get("broken_links_note") or ""
    if "HOME-scale" not in note:
        _fail(f"T4: skip note should explain the HOME-scale degrade, got {note!r}")
    # The agent must NOT be escalated for the scanner degrade. A skipped
    # scan with an otherwise well-formed profile classifies ok.
    if row["status"] not in {"ok"}:
        _fail(
            f"T4: agent must NOT be escalated for a scanner skip; "
            f"status should be ok, got {row['status']!r}"
        )


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: assert-bounded-scan.py <case> <scan-json> <agent-id>",
            file=sys.stderr,
        )
        return 2
    case, scan_json, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
    row = _agent_row(scan_json, agent_id)
    dispatch = {
        "t1": case_t1,
        "t2": case_t2,
        "t3": case_t3,
        "t4": case_t4,
    }
    fn = dispatch.get(case)
    if fn is None:
        print(f"[1801-assert] unknown case {case!r}", file=sys.stderr)
        return 2
    fn(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
