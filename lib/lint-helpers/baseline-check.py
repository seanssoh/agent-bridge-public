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

    # Key by (path, snippet_hash) — NOT snippet_hash alone. Common snippets
    # like `python3 - <<'PY'` share a normalized hash across many files; if
    # we keyed only by hash, a copy-pasted C1/C3 site at a brand new path
    # would silently bypass the ratchet because some existing baseline row
    # already has that hash. Per-(path, hash) lookup means a new occurrence
    # at a new path/line MUST appear as a new baseline row before merge
    # (r2 fix for codex PR #954 r1 finding P1 #1).
    #
    # We track OCCURRENCE COUNTS per (path, hash, category) tuple, not
    # just presence. If a file already has one baselined `python3 - <<'PY'`
    # site and a developer copy-pastes a SECOND identical opener into the
    # same file, the second site is a new heredoc-stdin subprocess that
    # needs review — the (path, hash) existence test alone would treat the
    # copy as already accepted (r3 fix for codex PR #954 r2 finding P2 #1).
    # Keying by (path, hash, category) also means the SAME hash appearing
    # with two different categories at different lines (one wrapped in a
    # cross-line capture, one not) is correctly recognized as TWO distinct
    # baselined sites and avoids a false "promoted" report.
    baseline_count_by_pkc: dict[tuple[str, str, str], int] = defaultdict(int)
    baseline_cats_by_ph: dict[tuple[str, str], set[str]] = defaultdict(set)
    for row in baseline_rows:
        # path, line, category, snippet_hash[, reason, owner, expires_or_phase]
        pkc = (row[0], row[3], row[2])
        baseline_count_by_pkc[pkc] += 1
        baseline_cats_by_ph[(row[0], row[3])].add(row[2])

    current_count_by_pkc: dict[tuple[str, str, str], int] = defaultdict(int)
    current_rows_by_pkc: dict[
        tuple[str, str, str], list[tuple[str, str, str, str, str, str]]
    ] = defaultdict(list)

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
        pkc = (path, snippet_hash, cat)
        ph = (path, snippet_hash)
        current_count_by_pkc[pkc] += 1
        current_rows_by_pkc[pkc].append(
            (path, line, cat, snippet_hash, reason, snippet)
        )
        if pkc not in baseline_count_by_pkc:
            if ph in baseline_cats_by_ph:
                # Hash is known at this path, but with a DIFFERENT category
                # — the surrounding context (capture wrapper) changed and
                # the site needs re-review. We report all old categories so
                # the reviewer can see what changed.
                old_cats = ",".join(sorted(baseline_cats_by_ph[ph]))
                promoted.append(
                    (path, line, cat, old_cats, snippet_hash, snippet)
                )
            else:
                # Brand new (path, hash) pair — every occurrence is a new
                # site.
                new_sites.append((path, line, cat, snippet_hash, reason, snippet))

    # Detect copy-paste overflow: a (path, hash, category) tuple already
    # present in the baseline but with MORE occurrences in the current
    # scan than baseline accounts for. Each surplus occurrence is itself
    # a new site that must be reviewed before it can ratchet in.
    for pkc, current_count in current_count_by_pkc.items():
        baseline_count = baseline_count_by_pkc.get(pkc, 0)
        if baseline_count == 0:
            # Already accounted for above (either new or promoted).
            continue
        if current_count == baseline_count:
            continue
        if current_count > baseline_count:
            surplus = current_count - baseline_count
            # Report the LAST `surplus` occurrences as overflow (the earliest
            # ones plausibly correspond to the original baselined rows; the
            # tail is the copy-paste). Line numbers in current rows are sorted
            # by scan order, so the tail is the right thing to flag.
            for entry in current_rows_by_pkc[pkc][-surplus:]:
                new_sites.append(entry)

    # Detect deletion drift: baseline accounts for MORE occurrences of a
    # (path, hash, category) tuple than the current scan contains. This is
    # progress (a site was extracted or removed) but leaves stale baseline
    # capacity that could mask a newly added copy of the same opener in a
    # later PR — the surplus would be silently absorbed by the unused
    # baseline rows. Force the contributor to run --baseline-update so the
    # TSV always matches reality (r4 fix for codex PR #954 r3 finding P2 #2).
    stale_baseline: list[tuple[str, str, str, int, int]] = []
    for pkc, baseline_count in baseline_count_by_pkc.items():
        current_count = current_count_by_pkc.get(pkc, 0)
        if current_count < baseline_count:
            path, snippet_hash, cat = pkc
            stale_baseline.append(
                (path, snippet_hash, cat, baseline_count, current_count)
            )

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

    if stale_baseline:
        fail = True
        print(
            "[lint-heredoc-ban] FAIL: baseline accounts for sites that no "
            "longer exist (run --baseline-update to tighten):",
            file=sys.stderr,
        )
        for path, snippet_hash, cat, baseline_count, current_count in stale_baseline:
            print(
                f"[lint-heredoc-ban]   {cat:4s} {path}  hash={snippet_hash[:12]}  "
                f"baseline={baseline_count} current={current_count} "
                f"(stale capacity={baseline_count - current_count})",
                file=sys.stderr,
            )
        print(
            "[lint-heredoc-ban] Stale capacity masks newly added copies "
            "of the same opener — silent deletion is prohibited. Run:",
            file=sys.stderr,
        )
        print(
            "[lint-heredoc-ban]   scripts/lint-heredoc-ban.sh --baseline-update",
            file=sys.stderr,
        )
        print(
            "[lint-heredoc-ban] then commit the resulting baseline diff.",
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
