#!/usr/bin/env python3
"""lib/lint-helpers/baseline-curate.py — apply Phase-1 default owner/phase
metadata to .lint-heredoc-baseline.tsv rows that still have blank metadata.

Called once by the operator when the baseline is first generated. After this,
new rows added by --baseline-update are flagged with blank owner/phase and
must be hand-filled in the PR that introduces them — silent acceptance is
prohibited (the lint script's --baseline-check enforces that any new
snippet_hash makes it into the baseline at all, and the PR review enforces
that the owner/phase columns are filled).

Args:
    sys.argv[1]  baseline TSV path

Defaults applied (only to rows whose owner column is blank):
    - scripts/install-daemon-*launchagent.sh / *systemd.sh
        owner=permanent, phase=permanent
        reason="static service-template generation (no live capture wedge)"
    - scripts/install-*launchagent.sh / *systemd.sh
        owner=permanent, phase=permanent
        reason="static service-template generation (no live capture wedge)"
    - scripts/smoke/*, scripts/smoke-test.sh, tests/**
        owner=patch-dev, phase="Phase 6 PR F"
        reason kept from audit
    - lib/bridge-*.sh, lib/upgrade-helpers/*.sh, bridge-*.sh, agent-bridge, agb
      categories C1/C2/C4:    owner=patch, phase="Phase 2 PR B"
      category C3:            owner=patch, phase="Phase 3 PR C"
      category H3:            owner=patch, phase="Phase 5 PR E (review per site)"
    - anything else:          owner=patch, phase="Phase 4 PR D"

The reason column is kept verbatim from the audit unless overwritten above.
"""
from __future__ import annotations

import sys


HEADER_PREFIX = ("#", "path")


def classify(path: str, category: str) -> tuple[str, str, str | None]:
    """Return (owner, phase, reason_override_or_None) for a row."""
    # Service-unit installers generate static text files. They use
    # `$(cat <<EOF ...)` to embed a fixed plist/systemd template into the
    # final on-disk file. There's no slow consumer in the capture chain.
    if "/install-daemon-" in path or "/install-watchdog-" in path or "/install-daemon-liveness" in path:
        return ("permanent", "permanent", "static service-template generation (no live capture wedge)")
    if path.startswith("scripts/install-") and (
        "launchagent" in path or "systemd" in path
    ):
        return ("permanent", "permanent", "static service-template generation (no live capture wedge)")

    if (
        path.startswith("scripts/smoke/")
        or path == "scripts/smoke-test.sh"
        or path.startswith("tests/")
    ):
        return ("patch-dev", "Phase 6 PR F", None)

    production_prefixes = (
        "lib/bridge-",
        "lib/upgrade-helpers/",
        "bridge-",
        "agent-bridge",
        "agb",
        "bootstrap-",
    )
    if any(path.startswith(p) for p in production_prefixes) or path in {
        "agent-bridge",
        "agb",
    }:
        if category in ("C1", "C2", "C4"):
            return ("patch", "Phase 2 PR B", None)
        if category == "C3":
            return ("patch", "Phase 3 PR C", None)
        if category == "H3":
            return ("patch", "Phase 5 PR E (review per site)", None)

    return ("patch", "Phase 4 PR D", None)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: baseline-curate.py BASELINE_TSV", file=sys.stderr)
        return 2
    path = argv[1]

    out_lines: list[str] = []
    changed = 0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.startswith(HEADER_PREFIX):
                out_lines.append(line + "\n")
                continue
            parts = line.split("\t")
            # path, line, category, snippet_hash, reason, owner, expires_or_phase
            while len(parts) < 7:
                parts.append("")
            path_col, _line_no, category, _hash, reason, owner, phase = parts[:7]
            if owner.strip() or phase.strip():
                # Already curated; preserve.
                out_lines.append(line + "\n")
                continue
            new_owner, new_phase, reason_override = classify(path_col, category)
            if reason_override is not None:
                reason = reason_override
            parts[4] = reason
            parts[5] = new_owner
            parts[6] = new_phase
            out_lines.append("\t".join(parts) + "\n")
            changed += 1

    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out_lines)

    print(f"[baseline-curate] applied defaults to {changed} row(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
