#!/usr/bin/env python3
"""lib/lint-helpers/baseline-check.py — compare current heredoc audit to baseline.

Invoked from scripts/lint-heredoc-ban.sh --baseline-check via file-as-argv
(not heredoc-stdin) to keep this helper unaffected by Bash 5.3.9 footgun #11.

Args:
    sys.argv[1]  current audit TSV path (produced by scripts/audit-footgun-11.sh)
    sys.argv[2]  baseline TSV path        (.lint-heredoc-baseline.tsv)

Exit code:
    0  no new sites and no category drift
    1  one or more new sites or a category change for an existing snippet hash
    2  internal error (file missing, parse error)

Stdout:
    On pass: a single PASS line with per-category counts.
On stderr:
    On fail: structured FAIL lines naming each new/promoted site.
"""
from __future__ import annotations

import sys
from collections import defaultdict


def read_tsv(path: str, min_cols: int) -> list[list[str]]:
    rows: list[list[str]] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if parts and parts[0] == "path":
                    continue
                if len(parts) < min_cols:
                    continue
                rows.append(parts)
    except FileNotFoundError:
        print(f"[lint-heredoc-ban] FAIL: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return rows


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: baseline-check.py CURRENT_TSV BASELINE_TSV", file=sys.stderr)
        return 2
    current_path, baseline_path = argv[1], argv[2]

    current_rows = read_tsv(current_path, 6)
    baseline_rows = read_tsv(baseline_path, 4)

    baseline_cat_by_hash: dict[str, str] = {}
    for row in baseline_rows:
        # path, line, category, snippet_hash[, reason, owner, expires_or_phase]
        baseline_cat_by_hash[row[3]] = row[2]

    new_sites: list[tuple[str, str, str, str, str, str]] = []
    promoted: list[tuple[str, str, str, str, str, str]] = []
    counts: defaultdict[str, int] = defaultdict(int)

    for row in current_rows:
        path, line, cat, snippet_hash = row[0], row[1], row[2], row[3]
        reason = row[4] if len(row) > 4 else ""
        snippet = row[5] if len(row) > 5 else ""
        counts[cat] += 1
        if cat == "SAFE":
            continue
        if snippet_hash not in baseline_cat_by_hash:
            new_sites.append((path, line, cat, snippet_hash, reason, snippet))
        else:
            old_cat = baseline_cat_by_hash[snippet_hash]
            if old_cat != cat:
                promoted.append((path, line, cat, old_cat, snippet_hash, snippet))

    fail = False
    if new_sites:
        fail = True
        print(
            "[lint-heredoc-ban] FAIL: new heredoc-stdin sites not in baseline:",
            file=sys.stderr,
        )
        for path, line, cat, snippet_hash, reason, snippet in new_sites:
            print(
                f"[lint-heredoc-ban]   {cat:4s} {path}:{line}  ({reason})",
                file=sys.stderr,
            )
            print(
                f"[lint-heredoc-ban]        snippet: {snippet[:140]}",
                file=sys.stderr,
            )
            print(
                f"[lint-heredoc-ban]        hash:    {snippet_hash}",
                file=sys.stderr,
            )
        print("", file=sys.stderr)
        print(
            "[lint-heredoc-ban] To accept new site(s), do ONE of:",
            file=sys.stderr,
        )
        print(
            "[lint-heredoc-ban]   1) extract the heredoc to a standalone helper under "
            "lib/upgrade-helpers/ (file-as-argv pattern; see existing examples and "
            "PR #937).",
            file=sys.stderr,
        )
        print(
            "[lint-heredoc-ban]   2) for an intentional exception, run "
            "`scripts/lint-heredoc-ban.sh --baseline-update`, then EDIT "
            ".lint-heredoc-baseline.tsv to fill in reason/owner/phase columns for "
            "each new row. Silent acceptance is prohibited.",
            file=sys.stderr,
        )

    if promoted:
        fail = True
        print(
            "[lint-heredoc-ban] FAIL: existing sites changed category "
            "(re-review required):",
            file=sys.stderr,
        )
        for path, line, new_cat, old_cat, snippet_hash, snippet in promoted:
            print(
                f"[lint-heredoc-ban]   {path}:{line}  {old_cat} -> {new_cat}",
                file=sys.stderr,
            )
            print(
                f"[lint-heredoc-ban]        snippet: {snippet[:140]}",
                file=sys.stderr,
            )
            print(
                f"[lint-heredoc-ban]        hash:    {snippet_hash}",
                file=sys.stderr,
            )

    if not fail:
        print(
            "[lint-heredoc-ban] PASS: baseline ratchet "
            f"(current site counts: C1={counts['C1']}, C2={counts['C2']}, "
            f"C3={counts['C3']}, C4={counts['C4']}, "
            f"H3={counts['H3']}, SAFE={counts['SAFE']})"
        )
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
