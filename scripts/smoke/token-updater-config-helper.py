#!/usr/bin/env python3
"""Helper for scripts/smoke/token-updater-config.sh (#21895 phase-1, sub-PR 1/4).

Kept tiny and heredoc-free (footgun #11): the smoke driver invokes discrete
verbs so no large Python body is fed to a subprocess over stdin.

Verbs:
  json-field <dotted.key>          read JSON from stdin, print the (dotted) field
  file-mode <path>                 print the octal mode bits (e.g. 600) of <path>
  deny-reason <ENV_KEY>            print bridge-config.py env_key_deny_reason(<key>)
"""
from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from pathlib import Path


def _get(payload: object, dotted: str) -> object:
    cur = payload
    for part in dotted.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def _load_bridge_config():
    repo = Path(__file__).resolve().parent.parent.parent
    spec = importlib.util.spec_from_file_location("bcfg_probe", str(repo / "bridge-config.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: token-updater-config-helper.py <verb> [args...]", file=sys.stderr)
        return 2
    verb = sys.argv[1]

    if verb == "json-field":
        dotted = sys.argv[2]
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            print("")
            return 0
        value = _get(payload, dotted)
        if isinstance(value, bool):
            print("True" if value else "False")
        elif value is None:
            print("")
        else:
            print(value)
        return 0

    if verb == "file-mode":
        path = sys.argv[2]
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except OSError:
            print("ABSENT")
            return 0
        print(oct(mode)[-3:])
        return 0

    if verb == "deny-reason":
        key = sys.argv[2]
        module = _load_bridge_config()
        reason = module.env_key_deny_reason(key)
        print(reason if reason is not None else "ALLOWED")
        return 0

    print(f"unknown verb: {verb}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
