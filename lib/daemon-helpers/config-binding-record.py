#!/usr/bin/env python3
"""Emit one #1738 config-caller binding record's stale-check fields.

Invoked by the daemon reconcile self-heal (`bridge_daemon_prune_orphan_config_
caller_bindings`, bridge-daemon.sh) to decide whether a PRESENT binding for a
live session is still CURRENT or has gone stale (#1738 r3 FIX 3 — the r3 pass
only re-published a MISSING binding; a present record with a wrong pane_pid or
stale identity was skipped and never repaired).

The shell caller passes the binding file path as argv[1]; we emit exactly one
tab-separated `<pane_pid>\\t<agent_id>\\t<admin_agent_id>` line so the shell can
compare those three fields against the LIVE pane_pid / the bound agent / the
current admin id and republish on any mismatch. A missing / unreadable /
malformed record, or a non-integer pane_pid, emits an empty pane_pid column,
which the shell treats as "stale → republish" (fail-toward-repair).

File-as-argv only (footgun #11 / lint-heredoc-ban): the path comes in on argv,
never stdin.
"""

from __future__ import annotations

import json
import sys


def _scrub(value: str) -> str:
    # Tabs/newlines in any field would corrupt the row split; strip them so the
    # row is always exactly `<pane_pid>\t<agent_id>\t<admin_agent_id>`.
    return value.replace("\t", "").replace("\n", "")


def main() -> int:
    if len(sys.argv) < 2:
        print("\t\t")
        return 0
    path = sys.argv[1]
    pane_pid = ""
    agent_id = ""
    admin_agent_id = ""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            raw_pid = data.get("pane_pid")
            # Accept an int (the written shape) or a digit string; anything else
            # leaves pane_pid empty → the shell republishes (fail-toward-repair).
            if isinstance(raw_pid, bool):
                pane_pid = ""
            elif isinstance(raw_pid, int):
                pane_pid = str(raw_pid)
            elif isinstance(raw_pid, str) and raw_pid.strip().isdigit():
                pane_pid = raw_pid.strip()
            agent_id = str(data.get("agent_id", "") or "").strip()
            admin_agent_id = str(data.get("admin_agent_id", "") or "").strip()
    except (OSError, ValueError):
        pane_pid = agent_id = admin_agent_id = ""
    sys.stdout.write(
        _scrub(pane_pid) + "\t" + _scrub(agent_id) + "\t" + _scrub(admin_agent_id) + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
