#!/usr/bin/env python3
"""Issue #1931 (DATA-LOSS): decide whether a home->workdir entrypoint copy would
clobber an operator-customized workdir CLAUDE.md / AGENTS.md with the placeholder
template, and if so produce the managed-block-only refresh that preserves the
operator's custom contract.

Background. The upgrade-time rematerialize pass mirrors the engine instruction
entrypoint (CLAUDE.md for claude, AGENTS.md for codex) home -> workdir whenever
the bytes differ. That is correct when the HOME copy carries the agent's real
identity (the operator edited the authoritative home). But on installs where the
operator only customized the WORKDIR copy (the live, attached-cwd file) and left
the HOME copy as the unrendered/placeholder template, the differ-then-copy gate
silently overwrote the customized workdir entrypoint with the placeholder,
dropping the agent's role / queue protocol / rules sections (#1931 reproduction:
`# patch — Manager/admin role` workdir clobbered by `# <Agent Name> — <Role>`
home).

This helper is the #1817 "operator-customized contract is sacred" pattern applied
to the WORKDIR entrypoint. Invoked by argv (no heredoc stdin, footgun #11):

    preserve-customized-entrypoint.py <src_entrypoint> <dst_entrypoint>

Emits exactly one JSON object on stdout describing the decision:

    {"decision": "proceed"}
        The normal home->workdir copy is safe (src is not a placeholder, or dst
        is absent / itself a placeholder / already byte-identical handling is the
        caller's job). The caller performs its usual copy.

    {"decision": "preserve", "refresh": true,  "refreshed_b64": "<...>"}
        Src is a placeholder and dst is operator-customized. The managed
        DOC-MIGRATION block was spliced from src into dst; write the decoded
        bytes to dst (managed-block-only update). The operator's custom contract
        below the END marker survives byte-for-byte.

    {"decision": "preserve", "refresh": false}
        Src is a placeholder and dst is operator-customized, but the managed
        block could not be spliced (src has no managed markers, or dst already
        carries the identical managed block). Keep dst untouched; the caller
        records it preserved and warns. Never clobber.

    {"decision": "backup", ...}
        Reserved for a future "replace is unavoidable" path; this helper never
        returns it today because a placeholder source is never a legitimate
        replacement for a customized workdir entrypoint.

`refreshed_b64` is base64 of the UTF-8 bytes so the JSON stays single-line and
binary-safe across the shell boundary.
"""

from __future__ import annotations

import base64
import json
import re
import sys
from pathlib import Path

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"


def _managed_start_pattern(start_marker: str) -> str:
    """Stamp-tolerant regex for the managed-block BEGIN marker (#1816).

    The renderer (bridge-docs.py) stamps the engine version onto the BEGIN
    marker as ` v=<version>` before the closing `-->`. Match the stable prefix
    plus an OPTIONAL ` v=<stamp>`, so both the stamped template source and a
    legacy unstamped workdir copy are recognized. Mirrors
    bridge-upgrade.py::_managed_start_pattern exactly so the workdir
    managed-block refresh stays byte-identical to the home-side refresh.
    """
    suffix = " -->"
    if start_marker.endswith(suffix):
        prefix = start_marker[: -len(suffix)]
        return re.escape(prefix) + r"(?: v=[^\n>]*)?" + re.escape(suffix)
    return re.escape(start_marker)

# Unrendered template placeholders. The create-time scaffold substitutes every
# one of these (see bridge-upgrade.py::render_template / bridge-agents.sh
# bridge_render_template_string). A copy that STILL carries any of them in its
# head region was never rendered for a concrete agent -> it is the placeholder
# template, not an authored identity. Matched only in the head block so an
# incidental later literal mention can never flip the classification.
_PLACEHOLDER_TOKENS = (
    "<Agent Name>",
    "<Role>",
    "<agent-id>",
    "<한 줄 역할 설명>",
    "<표시 이름>",
    "<핵심 책임>",
)


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def _head(text: str, lines: int = 8) -> str:
    return "\n".join(text.splitlines()[:lines])


def is_placeholder_entrypoint(text: str) -> bool:
    """True iff <text> is the unrendered entrypoint placeholder template.

    The defining signal is an unsubstituted placeholder token in the head region
    (the `# <Agent Name> — <Role>` heading and the `<한 줄 역할 설명>` /
    `<표시 이름>` skeleton that the create-time render fills in). An authored
    entrypoint — the operator's customized copy OR a rendered-then-edited one —
    has had these substituted, so it matches none of them.
    """
    if not text.strip():
        return False
    head = _head(text)
    return any(token in head for token in _PLACEHOLDER_TOKENS)


def extract_managed_block(text: str) -> str:
    match = re.search(
        rf"{_managed_start_pattern(MANAGED_START)}.*?{re.escape(MANAGED_END)}",
        text,
        re.S,
    )
    return match.group(0).strip() if match else ""


def refresh_managed_block(original: str, managed_block: str) -> str:
    """Splice <managed_block> into <original>, mirroring
    bridge-upgrade.py::refresh_managed_block exactly so the workdir managed-block
    update is byte-identical to the home-side refresh."""
    if not managed_block:
        return original
    block = managed_block.rstrip() + "\n"
    pattern = re.compile(
        rf"{_managed_start_pattern(MANAGED_START)}.*?{re.escape(MANAGED_END)}\n*",
        re.S,
    )
    if pattern.search(original):
        updated = pattern.sub(block + "\n", original, count=1)
        return updated if updated.endswith("\n") else updated + "\n"

    normalized = original.rstrip()
    if normalized.startswith("# "):
        first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        rest = rest.lstrip()
        updated = f"{first}\n\n{block}\n"
        if rest:
            updated += f"{rest}\n"
        return updated

    if normalized:
        return f"{block}\n{normalized}\n"
    return block


def decide(src_text: str, dst_text: str) -> dict[str, object]:
    # Only the placeholder-over-customized case is special. Everything else is
    # the caller's normal copy gate.
    if not is_placeholder_entrypoint(src_text):
        return {"decision": "proceed"}
    if not dst_text.strip():
        # Empty/absent dst is handled by the caller's create-if-absent path; a
        # placeholder source seeding an empty workdir is the legitimate fresh
        # scaffold (no operator content to lose).
        return {"decision": "proceed"}
    if is_placeholder_entrypoint(dst_text):
        # Both sides are the placeholder: nothing operator-authored to protect,
        # let the caller refresh normally so the managed block still lands.
        return {"decision": "proceed"}

    # Src is the placeholder, dst is operator-customized. NEVER clobber. Try to
    # refresh only the managed DOC-MIGRATION block in dst (so the upgrade's new
    # doc-migration line still lands) while preserving the operator's contract.
    managed_block = extract_managed_block(src_text)
    if managed_block:
        refreshed = refresh_managed_block(dst_text, managed_block)
        if refreshed != dst_text:
            return {
                "decision": "preserve",
                "refresh": True,
                "refreshed_b64": base64.b64encode(refreshed.encode("utf-8")).decode("ascii"),
            }
    # No managed markers in the source, or dst already carries the identical
    # block: keep dst exactly as-is. The caller records it preserved and warns.
    return {"decision": "preserve", "refresh": False}


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(json.dumps({"decision": "proceed", "error": "usage: preserve-customized-entrypoint.py <src> <dst>"}))
        return 0
    src_text = _read(Path(argv[1]))
    dst_text = _read(Path(argv[2]))
    print(json.dumps(decide(src_text, dst_text), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
