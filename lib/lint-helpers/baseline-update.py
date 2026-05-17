#!/usr/bin/env python3
"""lib/lint-helpers/baseline-update.py — regenerate the heredoc baseline TSV.

Invoked from scripts/lint-heredoc-ban.sh --baseline-update via file-as-argv
(not heredoc-stdin) to keep this helper unaffected by Bash 5.3.9 footgun #11.

Args:
    sys.argv[1]  current audit TSV path (produced by scripts/audit-footgun-11.sh)
    sys.argv[2]  baseline TSV path (will be read for metadata merge AND written)

Behavior:
    For each (path, line, category, snippet_hash) in the current audit:
      - if snippet_hash exists in the prior baseline, keep its
        reason / owner / expires_or_phase columns (preserving hand-curated
        metadata across reformatting)
      - if it's new, leave reason/owner/expires_or_phase blank — the
        reviewer fills them in by hand before committing.
    Snippets that disappeared from the current audit are dropped.
    Rows are sorted by (path, line) for diff stability.

Exit code:
    0  on success
    2  on error
"""
from __future__ import annotations

import os
import sys


def read_tsv(path: str, expected_cols: int) -> list[list[str]]:
    rows: list[list[str]] = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if parts and parts[0] == "path":
                continue
            while len(parts) < expected_cols:
                parts.append("")
            rows.append(parts)
    return rows


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: baseline-update.py CURRENT_TSV BASELINE_TSV", file=sys.stderr)
        return 2
    current_path, baseline_path = argv[1], argv[2]

    # Baseline schema: path, line, category, snippet_hash, reason, owner, expires_or_phase
    baseline_rows = read_tsv(baseline_path, 7)
    meta_by_hash: dict[str, tuple[str, str, str]] = {}
    for row in baseline_rows:
        meta_by_hash[row[3]] = (row[4], row[5], row[6])

    # Audit schema: path, line, category, snippet_hash, reason, snippet
    current_rows = read_tsv(current_path, 6)

    def sort_key(row: list[str]) -> tuple[str, int]:
        try:
            return (row[0], int(row[1]))
        except (ValueError, IndexError):
            return (row[0], 0)

    current_rows.sort(key=sort_key)

    out_path = baseline_path + ".new"
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(
            "# scripts/lint-heredoc-ban.sh --baseline-check ratchets against "
            "this file.\n"
        )
        fh.write(
            "# Schema: path<TAB>line<TAB>category<TAB>snippet_hash<TAB>reason"
            "<TAB>owner<TAB>expires_or_phase\n"
        )
        fh.write("# Identity column is snippet_hash; line numbers are advisory.\n")
        fh.write(
            "path\tline\tcategory\tsnippet_hash\treason\towner\texpires_or_phase\n"
        )
        for row in current_rows:
            path, line, cat, snippet_hash = row[0], row[1], row[2], row[3]
            # SAFE sites are tracked-for-visibility only and never fail the
            # ratchet (baseline-check.py skips them). Excluding them from
            # the baseline keeps the file focused on what reviewers need to
            # care about and prevents unrelated SAFE-site churn from
            # generating diff noise on every refactor.
            if cat == "SAFE":
                continue
            audit_reason = row[4] if len(row) > 4 else ""
            if snippet_hash in meta_by_hash:
                reason, owner, phase = meta_by_hash[snippet_hash]
                if not reason:
                    reason = audit_reason
            else:
                reason = audit_reason
                owner = ""
                phase = ""
            fh.write(
                f"{path}\t{line}\t{cat}\t{snippet_hash}\t{reason}\t{owner}\t"
                f"{phase}\n"
            )

    os.replace(out_path, baseline_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
