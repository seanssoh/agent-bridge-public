#!/usr/bin/env python3
"""Apply typed channels-CSV mutations for `agent-bridge agent update`.

Extracted from `lib/bridge-agent-update.sh` as part of issue #815 (Wave A):
the previous source-time `$(cat <<'PY' ... PY)` capture caused Bash to
block in `heredoc_write` while sourcing the module on a stale runtime,
hanging the CLI hot path. Moving the body into a real file removes the
source-time read entirely.

Reads BRIDGE_AGENT_UPDATE_CH_CURRENT from the environment for the
starting channels CSV, and TSV mutation ops on stdin:

    channels-set\t<csv>
    channels-add\t<token>
    channels-remove\t<token>

Stdout: two lines.
    line 1: <new csv>
    line 2: <JSON action array>
"""

import json
import os
import sys


def split_csv(raw: str) -> list[str]:
    if not raw:
        return []
    return [item.strip() for item in raw.split(",") if item.strip()]


def join_csv(items: list[str]) -> str:
    return ",".join(items)


def main() -> int:
    value = os.environ.get("BRIDGE_AGENT_UPDATE_CH_CURRENT", "")
    items = split_csv(value)
    actions: list[str] = []

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        op, payload = parts[0], parts[1]
        if op == "channels-set":
            new_items = split_csv(payload)
            if new_items != items:
                items = new_items
                actions.append("channels-set")
            continue
        if op == "channels-add":
            if payload and payload not in items:
                items.append(payload)
                actions.append(f"channels-add {payload}")
            continue
        if op == "channels-remove":
            if payload and payload in items:
                items.remove(payload)
                actions.append(f"channels-remove {payload}")
            continue
        print(f"unknown channels op: {op}", file=sys.stderr)
        return 2

    print(join_csv(items))
    print(json.dumps(actions, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
