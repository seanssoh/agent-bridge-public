#!/usr/bin/env python3
"""Shared Agent Bridge inbox check hook."""

from __future__ import annotations

import argparse
import json
import os
import sys

from bridge_hook_common import (
    codex_stop_reason,
    open_claimed_count,
    queue_attention_message,
    queue_summary,
    top_claimed_row,
)


def load_event() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "codex"), default="text")
    args = parser.parse_args(argv)

    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent:
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    if args.format == "codex":
        event = load_event()
        if bool(event.get("stop_hook_active")):
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
            return 0

    pending, row = queue_summary(agent)

    if args.format == "codex":
        # The codex Stop hook has two distinct concerns:
        #   1. genuinely-queued work waiting → block + "claim it" (uses the
        #      queued-only `pending`/`row` from queue_summary).
        #   2. open claimed work the agent holds → block + "continue it"
        #      (issue #1199: this is NOT an ACTION REQUIRED nudge and must
        #      not survive in the queued `pending` count, or the agent gets
        #      re-nudged to re-claim a task it just claimed). We keep the
        #      anti-abandonment gate via the separate claimed lookups so a
        #      session cannot quietly end on open claimed work.
        if pending > 0 and row is not None:
            stop_row = row
        else:
            claimed_row = top_claimed_row(agent) if open_claimed_count(agent) > 0 else None
            stop_row = claimed_row
        if stop_row is None:
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
            return 0
        json.dump(
            {
                "decision": "block",
                "reason": codex_stop_reason(agent, stop_row),
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    # Text path (Claude Stop hook via mark-idle.sh): ACTION REQUIRED nudge is
    # a queued-work call-to-action only. A claimed/blocked task never fires it
    # (issue #1199 — no immediate re-nudge of a just-claimed task).
    if pending == 0 or row is None:
        return 0

    sys.stdout.write(queue_attention_message(agent, pending, row))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
