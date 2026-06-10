#!/usr/bin/env python3
"""Sidecar fixture mutator + asserter for 1756-settings-preserve-model-user-keys.sh.

File-as-argv (footgun #11): the smoke must not feed python via heredoc-stdin
(the lint-heredoc-ban baseline ratchet flags new C1 sites). The ``seed-*``
subcommands seed the rendered effective settings file in place with the
precondition for one assertion block; every seed subcommand also pins ``model``
so the (a)/(b)/(c) blocks can assert it survives the subsequent rerender. The
``assert-plugin-state`` subcommand (#1756 r2) checks an exact
``enabledPlugins[<spec>]`` boolean value in a rendered file — used by the
adoption-fold launched-channel repair case (e) instead of a heredoc-stdin probe.
"""

import json
import sys
from pathlib import Path


def _assert_plugin_state(path: Path, spec: str, expected: str) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))  # raises -> smoke fails loudly
    enabled = data.get("enabledPlugins", {})
    if not isinstance(enabled, dict):
        raise SystemExit(f"enabledPlugins is not an object: {enabled!r}")
    want = expected == "true"
    actual = enabled.get(spec)
    if actual is not want:
        raise SystemExit(
            f"enabledPlugins[{spec}] is {actual!r}, want {want!r}"
        )


def _seed(cmd: str, path: Path) -> None:
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


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: 1756-settings-preserve-model-user-keys-helper.py "
            "<seed-user-keys|seed-stale-hook|seed-poison-hook|assert-plugin-state> ..."
        )
    cmd = sys.argv[1]
    if cmd == "assert-plugin-state":
        if len(sys.argv) != 5:
            raise SystemExit(
                "usage: ... assert-plugin-state <effective.json> <spec> <true|false>"
            )
        _assert_plugin_state(Path(sys.argv[2]), sys.argv[3], sys.argv[4])
        return
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: ... <seed-user-keys|seed-stale-hook|seed-poison-hook> <effective.json>"
        )
    _seed(cmd, Path(sys.argv[2]))


main()
