#!/usr/bin/env python3
"""Emit one #1738 config-caller binding record's stale-check fields.

Invoked by the daemon reconcile self-heal (`bridge_daemon_prune_orphan_config_
caller_bindings`, bridge-daemon.sh) to decide whether a PRESENT binding for a
live session is still CURRENT or has gone stale (#1738 r3 FIX 3 — the r3 pass
only re-published a MISSING binding; a present record with a wrong pane_pid or
stale identity was skipped and never repaired).

The shell caller passes the binding file path as argv[1]; we emit exactly one
tab-separated `<pane_pid>\\t<agent_id>\\t<admin_agent_id>\\t<owner_uid>` line so
the shell can compare those four fields against the LIVE pane_pid / the bound
agent / the current admin id / the expected pane-owner UID and republish on any
mismatch. A missing / unreadable / malformed record, or a non-integer pane_pid,
emits an empty pane_pid column, which the shell treats as "stale → republish"
(fail-toward-repair). `owner_uid` (#1738 r5 FIX C) is emitted as the 4th column
so the daemon self-heal can detect — and backfill — a legacy/pre-r5 record that
lacks it (the wrapper fails closed on a missing owner_uid on iso, so an unhealed
legacy record would otherwise stay denied indefinitely); a missing / non-integer
owner_uid emits an empty 4th column → the shell republishes to backfill it.

File-as-argv only (footgun #11 / lint-heredoc-ban): the path comes in on argv,
never stdin.
"""

from __future__ import annotations

import json
import sys


def _scrub(value: str) -> str:
    # Tabs/newlines in any field would corrupt the row split; strip them so the
    # row is always exactly `<pane_pid>\t<agent_id>\t<admin_agent_id>\t<owner_uid>`.
    return value.replace("\t", "").replace("\n", "")


def _int_field(raw: object) -> str:
    # Accept an int (the written shape) or a digit string; anything else (bool,
    # float, non-numeric) yields an empty column → the shell republishes
    # (fail-toward-repair). Used for both pane_pid and owner_uid.
    if isinstance(raw, bool):
        return ""
    if isinstance(raw, int):
        return str(raw)
    if isinstance(raw, str) and raw.strip().lstrip("-").isdigit():
        return raw.strip()
    return ""


def main() -> int:
    if len(sys.argv) < 2:
        print("\t\t\t")
        return 0
    path = sys.argv[1]
    pane_pid = ""
    agent_id = ""
    admin_agent_id = ""
    owner_uid = ""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            pane_pid = _int_field(data.get("pane_pid"))
            agent_id = str(data.get("agent_id", "") or "").strip()
            admin_agent_id = str(data.get("admin_agent_id", "") or "").strip()
            owner_uid = _int_field(data.get("owner_uid"))
    except (OSError, ValueError):
        pane_pid = agent_id = admin_agent_id = owner_uid = ""
    sys.stdout.write(
        _scrub(pane_pid)
        + "\t"
        + _scrub(agent_id)
        + "\t"
        + _scrub(admin_agent_id)
        + "\t"
        + _scrub(owner_uid)
        + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
