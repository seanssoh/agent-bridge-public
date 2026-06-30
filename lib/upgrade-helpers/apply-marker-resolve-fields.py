#!/usr/bin/env python3
"""apply-marker-resolve-fields.py — flatten an apply-marker `resolve` decision
into a single tab-separated line for the Bash apply path (Issue #2211).

bridge-upgrade.sh resolves a pending interrupted-apply marker via
`bridge-upgrade.py apply-marker --op resolve`, which emits a JSON decision. The
Bash side needs five scalar fields without an in-shell JSON parser; this helper
reads the captured decision JSON and prints exactly:

    decision<TAB>backup_root<TAB>transaction<TAB>reason<TAB>guidance

with literal TAB separators and a trailing newline. Missing fields are empty.
TAB/newline characters inside any value are collapsed to a single space so the
`cut -f` consumer never mis-splits.

Invocation contract:
    sys.argv[1] = path to the captured resolve-decision JSON file

Output (stdout): the 5-field TSV line. On ANY error (missing file, bad JSON,
non-object) it emits the fail-safe `none` decision with empty fields so the
caller proceeds as a normal (non-resume) apply rather than crashing.

Footgun #11: this is a standalone file-as-argv helper precisely so the apply
path never grows a `python3 - <<'PY'` heredoc-stdin (which wedges Bash 5.3.9).
"""

from __future__ import annotations

import json
import sys


def _scrub(value: object) -> str:
    """Stringify + collapse TAB/newline runs to single spaces (TSV-safe)."""
    text = "" if value is None else str(value)
    for ch in ("\t", "\r", "\n"):
        text = text.replace(ch, " ")
    return text


def main() -> int:
    fields = ["none", "", "", "", ""]
    try:
        path = sys.argv[1]
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            fields = [
                _scrub(data.get("decision") or "none"),
                _scrub(data.get("backup_root")),
                _scrub(data.get("transaction")),
                _scrub(data.get("reason")),
                _scrub(data.get("guidance")),
            ]
    except Exception:  # noqa: BLE001 — fail-safe to the `none` default line.
        fields = ["none", "", "", "", ""]
    sys.stdout.write("\t".join(fields) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
