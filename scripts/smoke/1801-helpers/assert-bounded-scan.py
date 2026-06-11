#!/usr/bin/env python3
"""Assertion helper for scripts/smoke/1801-watchdog-bounded-broken-links.sh.

Extracted to a standalone file (footgun #11: no heredoc-stdin to a
subprocess capture). Invoked as:

    assert-bounded-scan.py <case> <scan-json> <agent-id>

where <case> is one of t1..t4, t6, or t7 (t5 is asserted inline in the
smoke shell on the markdown body). Exits 0 on success, non-zero with a
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


def case_t6(row: dict) -> None:
    """#1801 r2: exclude .claude/worktrees from the walk.

    The workdir holds a genuine top-level broken link plus a populated
    ``.claude/worktrees/<x>/`` full of broken symlinks. max-entries is forced
    low in the shell so that WITHOUT the worktrees exclusion the bounded walk
    would burn its budget inside the worktree volume and set truncated=true
    while MISSING the genuine top-level link. The exclusion must (a) keep the
    genuine top-level link reported, (b) NOT report any worktree entry, and
    (c) NOT spuriously set truncated."""
    links = row["broken_links"]
    if not any("genuine-top" in link for link in links):
        _fail(
            f"T6: genuine top-level broken link must still be reported with "
            f"the worktrees exclusion, got {links}"
        )
    if any("worktrees" in link or "wt-broken" in link for link in links):
        _fail(
            f"T6: .claude/worktrees entries must NOT be walked/reported, "
            f"got {links}"
        )
    if row["broken_links_truncated"]:
        _fail(
            "T6: truncated must NOT be set — pruning .claude/worktrees keeps "
            "the walk within budget; a true here means the worktree volume "
            f"still consumed the budget. note={row.get('broken_links_note')!r}"
        )
    if row["broken_links_scan_skipped"]:
        _fail("T6: a normal bounded workdir must not be scan_skipped")


def case_t7(rows: list[dict]) -> None:
    """#1801 r2: within-pass dedupe of a shared workdir.

    Two agents share one realpath workdir. Assert BOTH rows are present, BOTH
    carry the same (correct) broken_links, and exactly one row is annotated
    with the ``shared workdir, scanned via <first>`` provenance note (the
    second agent reusing the first's walk). The walked-once proof itself is
    asserted on the dedupe instrumentation in the shell."""
    if len(rows) != 2:
        _fail(f"T7: expected exactly 2 shared-workdir rows, got {len(rows)}")
    # Both rows must report the genuine broken link in the shared workdir.
    for r in rows:
        if not any("shared-broken" in link for link in r["broken_links"]):
            _fail(
                f"T7: agent {r['agent']!r} row must report the shared "
                f"workdir's broken link, got {r['broken_links']}"
            )
        if r["broken_links_truncated"] or r["broken_links_scan_skipped"]:
            _fail(
                f"T7: shared workdir is a normal bounded scan; "
                f"agent {r['agent']!r} must be complete (not truncated/skipped)"
            )
    # The two rows must agree on the link set (dedupe must not diverge them).
    link_sets = [sorted(r["broken_links"]) for r in rows]
    if link_sets[0] != link_sets[1]:
        _fail(
            f"T7: both shared-workdir rows must carry the SAME broken_links; "
            f"got {link_sets[0]} vs {link_sets[1]}"
        )
    # Exactly one row is the reused (second) agent carrying the share note.
    shared = [
        r
        for r in rows
        if "shared workdir, scanned via" in (r.get("broken_links_note") or "")
    ]
    if len(shared) != 1:
        notes = [r.get("broken_links_note") for r in rows]
        _fail(
            f"T7: exactly one row must carry the shared-workdir provenance "
            f"note (the reused agent); got {len(shared)} (notes={notes})"
        )


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
            "usage: assert-bounded-scan.py <case> <scan-json> <agent-id>\n"
            "  (t7: <agent-id> is a comma-joined pair 'agentA,agentB')",
            file=sys.stderr,
        )
        return 2
    case, scan_json, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
    # t7 asserts across the two agents that share one workdir; its agent-id
    # arg is a comma-joined pair. Every other case asserts on a single row.
    if case == "t7":
        agent_ids = [a for a in agent_id.split(",") if a]
        rows = [_agent_row(scan_json, a) for a in agent_ids]
        case_t7(rows)
        return 0
    row = _agent_row(scan_json, agent_id)
    dispatch = {
        "t1": case_t1,
        "t2": case_t2,
        "t3": case_t3,
        "t4": case_t4,
        "t6": case_t6,
    }
    fn = dispatch.get(case)
    if fn is None:
        print(f"[1801-assert] unknown case {case!r}", file=sys.stderr)
        return 2
    fn(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
