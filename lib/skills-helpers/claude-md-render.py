#!/usr/bin/env python3
"""Render the bridge guidance block into a tmp ``CLAUDE.md`` copy.

Extracted from ``lib/bridge-skills.sh`` (#1151 r3). The previous inline
heredoc body lived inside an ``if ! python3 - ... <<'PY'`` capture site;
the surrounding shell used ``local _py_rc=$?`` to read the exit status,
but ``$?`` inside a ``then`` clause of ``if !`` is the rc of ``!`` (the
logical negation), not the original Python rc — so ``sys.exit(2)``
("already current, no-op") was silently misread as ``0`` and the
controller proceeded to the install branch with an unwritten ``dst``
tmpfile. r3 captures the rc without ``!`` and dispatches on it
explicitly.

Extracting to a standalone file also removes the
``"$BRIDGE_MANAGED_MARKER" <<'PY'`` heredoc-stdin site from
``lib/bridge-skills.sh`` (footgun #11 class — see the audit script docs).
Even though ``bridge_linux_sudo_root`` does NOT shell through ``bash -c``
on the immediate caller, the explicit-file pattern matches
``lib/upgrade-helpers/``, ``lib/cron-helpers/`` and ``lib/daemon-helpers/``
and avoids growing the lint baseline.

Invocation
----------
``python3 lib/skills-helpers/claude-md-render.py <src_tmp> <dst_tmp> \\
    <bridge_home> <marker_start> <marker_end> <managed_marker>``

* ``src_tmp`` — controller-owned tmp file holding the existing
  ``CLAUDE.md`` content (or an empty file when the original was
  missing).
* ``dst_tmp`` — controller-owned tmp file that receives the rendered
  output. Only written when content actually changes.
* ``bridge_home`` — value baked into the guidance block (paths to
  ``agb``, ``state/active-roster.md``, …).
* ``marker_start`` / ``marker_end`` — HTML-comment markers bounding
  the managed block.
* ``managed_marker`` — ``BRIDGE_MANAGED_MARKER`` string written inside
  the block as a recognition token.

Exit codes
----------
* ``0`` — rendered content differs from ``src_tmp``; ``dst_tmp`` is
  written.
* ``2`` — sentinel: rendered output is byte-identical to the input;
  the caller skips the install step (no-op fast path).
* ``64`` — usage error (wrong number of argv).
* ``1`` — any other failure (read/write error).

The caller MUST capture the rc without using ``if ! python3 ...``,
because Bash's ``$?`` semantics inside an ``if !`` ``then`` clause
report the rc of ``!`` rather than the original command.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 7:
        sys.stderr.write(
            f"usage: {argv[0]} <src_tmp> <dst_tmp> <bridge_home> "
            "<marker_start> <marker_end> <managed_marker>\n"
        )
        return 64

    src_tmp = Path(argv[1])
    dst_tmp = Path(argv[2])
    bridge_home = argv[3]
    marker_start = argv[4]
    marker_end = argv[5]
    managed_marker = argv[6]

    original = src_tmp.read_text(encoding="utf-8")
    block = f"""{marker_start}
<!-- {managed_marker} -->
## Agent Bridge
- When a task involves bridge coordination, use the `agent-bridge` skill before improvising commands.
- Do not guess bridge commands. Use `{bridge_home}/agb --help`, `{bridge_home}/agent-bridge --help`, or the local bridge skill reference.
- Your sender id is your current bridge agent id. Prefer `$BRIDGE_AGENT_ID`; if it is missing, verify the agent from `{bridge_home}/state/active-roster.md`.
- When you create or hand off work, set `--from "$BRIDGE_AGENT_ID"` when running outside a bridge-managed wrapper.
- Queue state is source of truth. Use `{bridge_home}/agb inbox|show|claim|done` instead of direct sqlite access.
- Do not invent subcommands such as `agb send`. If you are unsure, check the bridge skill or CLI help first.
{marker_end}"""

    pattern = re.compile(
        rf"{re.escape(marker_start)}.*?{re.escape(marker_end)}\n*", re.S
    )
    normalized = re.sub(pattern, "", original).rstrip()

    if normalized.startswith("# "):
        first, rest = (
            normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        )
        updated = f"{first}\n\n{block}\n\n{rest.lstrip()}"
    else:
        updated = f"{block}\n\n{normalized}\n" if normalized else f"{block}\n"

    if updated == original:
        # Sentinel: no-op fast path. Caller skips the install step.
        return 2

    dst_tmp.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
