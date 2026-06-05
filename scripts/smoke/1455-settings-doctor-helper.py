#!/usr/bin/env python3
"""File-as-argv JSON inspector for scripts/smoke/1455-settings-two-tree-doctor.sh.

Exists so the smoke can interrogate `bridge-doctor.py --json` output without any
heredoc-stdin `python3 -` subprocess (footgun #11 / lint-heredoc-ban). Every
subcommand takes the doctor-output JSON file as an explicit argv path and prints
a single line the Bash smoke compares with `smoke_assert_eq`.

Subcommands (argv[1]):
  count <json> <kind>
      Print the number of findings whose `kind` == <kind>.
  agents <json> <kind>
      Print a comma-sorted list of `agent` ids for findings of <kind>
      (empty string when none) — lets the smoke assert exactly which
      agents fired without ordering flakiness.
  field <json> <kind> <agent> <evidence-key>
      Print evidence[<key>] (or the top-level finding field as fallback) for
      the first <kind> finding matching <agent>; "__MISSING__" when absent.
      Booleans render as lowercase true/false.
  has-traceback <json>
      Print "yes" if the raw text contains a Python "Traceback", else "no".
      (Guards against a detector blowing up mid-walk.)

Read-only: never writes, never mutates the doctor output.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def _load(path: str) -> list[dict[str, Any]]:
    text = Path(path).read_text(encoding="utf-8") or "[]"
    data = json.loads(text)
    if not isinstance(data, list):
        raise SystemExit("doctor output is not a JSON array")
    return data


def _of_kind(data: list[dict[str, Any]], kind: str) -> list[dict[str, Any]]:
    return [r for r in data if isinstance(r, dict) and r.get("kind") == kind]


def _fmt(val: Any) -> str:
    if isinstance(val, bool):
        return "true" if val else "false"
    return str(val)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        raise SystemExit("usage: 1455-settings-doctor-helper.py <subcmd> ...")
    sub = argv[1]

    if sub == "has-traceback":
        raw = Path(argv[2]).read_text(encoding="utf-8")
        print("yes" if "Traceback" in raw else "no")
        return 0

    if sub == "count":
        data = _load(argv[2])
        print(len(_of_kind(data, argv[3])))
        return 0

    if sub == "agents":
        data = _load(argv[2])
        ids = sorted(str(r.get("agent") or "") for r in _of_kind(data, argv[3]))
        print(",".join(ids))
        return 0

    if sub == "field":
        data = _load(argv[2])
        kind, agent, key = argv[3], argv[4], argv[5]
        matches = [r for r in _of_kind(data, kind) if r.get("agent") == agent]
        if not matches:
            print("__MISSING__")
            return 0
        ev = matches[0].get("evidence") or {}
        if isinstance(ev, dict) and key in ev:
            print(_fmt(ev[key]))
        elif key in matches[0]:
            print(_fmt(matches[0][key]))
        else:
            print("__MISSING__")
        return 0

    raise SystemExit(f"unknown subcommand: {sub}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
