#!/usr/bin/env python3
"""List #1738 config-caller bindings as `<agent>\\t<session>` rows.

Invoked by the daemon reconcile prune (`bridge_daemon_prune_orphan_config_
caller_bindings`, bridge-daemon.sh). The shell caller passes the bindings dir as
argv[1]; we emit one tab-separated `<agent>\\t<session>` line per binding file so
the shell can check `bridge_tmux_session_exists <session>` and remove the
records whose session is gone (crash / reboot / `tmux kill-server` / SIGKILL
never call the orderly session-kill GC, leaving orphan bindings a PID-reuse
forger could ride).

`<agent>` is ALWAYS the file stem (the binding is written as `<agent>.json`, so
the stem is the authoritative agent name the shell hands back to
`bridge_remove_config_caller_binding`) — we never trust a record's stored
agent_id for the removal key. `<session>` is the record's stored session; a
record that is unreadable / malformed / has no session emits an empty session
column, which the shell treats as "not live" → prune (a binding with no
resolvable session is stale by definition).

File-as-argv only (footgun #11 / lint-heredoc-ban): the dir comes in on argv,
not stdin.
"""

from __future__ import annotations

import json
import os
import sys


def _emit(agent: str, session: str) -> None:
    # Tabs/newlines in either field would corrupt the row split; strip them so
    # the row is always exactly `<agent>\t<session>`.
    agent = agent.replace("\t", "").replace("\n", "")
    session = session.replace("\t", "").replace("\n", "")
    sys.stdout.write(agent + "\t" + session + "\n")


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    bindings_dir = sys.argv[1]
    try:
        names = os.listdir(bindings_dir)
    except OSError:
        return 0
    for name in sorted(names):
        if not name.endswith(".json"):
            continue
        agent = name[:-5]  # authoritative removal key = file stem
        if not agent:
            continue
        path = os.path.join(bindings_dir, name)
        session = ""
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                session = str(data.get("session", "") or "").strip()
        except (OSError, ValueError):
            session = ""  # unreadable / malformed → prune side
        _emit(agent, session)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
