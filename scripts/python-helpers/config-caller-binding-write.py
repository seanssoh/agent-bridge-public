#!/usr/bin/env python3
"""Write a #1738 config-caller binding record (file-as-argv, no heredoc-stdin).

Invoked by `bridge_publish_config_caller_binding` (lib/bridge-state.sh) after
`tmux new-session` succeeds. Reads its inputs from the environment so the shell
caller never has to embed a heredoc / here-string (footgun #11 /
lint-heredoc-ban) and so values are JSON-escaped safely by `json.dump`.

The record carries the launched session's tmux `pane_pid`; `bridge-config.py`
walks its own process ancestry and matches the parent chain against this
`pane_pid` to authorize a `config set` / `config set-env` mutation without
trusting spoofable process env. Written to a temp path (`BRIDGE_BIND_TMP`); the
shell caller atomically `mv`s it into place and chmods 0644.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    tmp = os.environ.get("BRIDGE_BIND_TMP", "").strip()
    if not tmp:
        print("config-caller-binding-write: BRIDGE_BIND_TMP unset", file=sys.stderr)
        return 2

    raw_pane_pid = os.environ.get("BRIDGE_BIND_PANE_PID", "").strip()
    try:
        pane_pid = int(raw_pane_pid)
    except (TypeError, ValueError):
        print(
            f"config-caller-binding-write: non-integer pane_pid {raw_pane_pid!r}",
            file=sys.stderr,
        )
        return 2

    record = {
        "version": 1,
        "agent_id": os.environ.get("BRIDGE_BIND_AGENT", "").strip(),
        "admin_agent_id": os.environ.get("BRIDGE_BIND_ADMIN", "").strip(),
        "session": os.environ.get("BRIDGE_BIND_SESSION", "").strip(),
        "pane_pid": pane_pid,
        "engine": os.environ.get("BRIDGE_BIND_ENGINE", "").strip(),
        "updated_at": os.environ.get("BRIDGE_BIND_UPDATED", "").strip(),
    }

    # #1738 r5 FIX C: record the OS UID that the bound agent's pane process runs
    # as, resolved by the CONTROLLER (`bridge_publish_config_caller_binding`)
    # from the bound agent's OS user. `bridge-config.py` re-resolves the live
    # pane PID's owner UID and requires it to equal this value — an attacker on
    # linux-user isolation runs as a different OS user and cannot own a process
    # as the admin UID, so a forged/camped "live" pid is rejected at the kernel
    # boundary. Only an INTEGER value is recorded; a missing / non-integer input
    # is omitted, and the wrapper then falls back to the caller's own euid (the
    # safe shared-UID value). The record is controller-owned on iso, so the
    # value is not agent-forgeable.
    raw_owner_uid = os.environ.get("BRIDGE_BIND_OWNER_UID", "").strip()
    if raw_owner_uid.lstrip("-").isdigit():
        record["owner_uid"] = int(raw_owner_uid)

    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh, ensure_ascii=True, sort_keys=True)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
