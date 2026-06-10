#!/usr/bin/env python3
"""Sidecar fixture mutator for 1756-settings-preserve-model-user-keys.sh.

File-as-argv (footgun #11): the smoke must not feed python via heredoc-stdin
(the lint-heredoc-ban baseline ratchet flags new C1 sites). Each subcommand
seeds the rendered effective settings file in place with the precondition for
one assertion block; every subcommand also pins ``model`` so the (a)/(b)/(c)
blocks can assert it survives the subsequent rerender.
"""

import json
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: 1756-settings-preserve-model-user-keys-helper.py "
            "<seed-user-keys|seed-stale-hook|seed-poison-hook> <effective.json>"
        )
    cmd, path = sys.argv[1], Path(sys.argv[2])
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["model"] = "claude-opus-4-8[1m]"
    if cmd == "seed-user-keys":
        payload["alwaysThinkingEnabled"] = True
        payload["agentPushNotifEnabled"] = False
        payload["unrelatedSetting"] = "should-not-leak-into-effective"
    elif cmd == "seed-stale-hook":
        payload.setdefault("hooks", {})["Stop"] = [
            {"hooks": [{"type": "command", "command": "bash /tmp/STALE-OPERATOR-HOOK.sh"}]}
        ]
    elif cmd == "seed-poison-hook":
        payload.setdefault("hooks", {})["PermissionDenied"] = [
            {"hooks": [{"type": "command", "command": "bash /tmp/poison.sh"}]}
        ]
    else:
        raise SystemExit(f"unknown subcommand: {cmd}")
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


main()
