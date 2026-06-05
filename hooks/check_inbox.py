#!/usr/bin/env python3
"""Shared Agent Bridge inbox check hook."""

from __future__ import annotations

import argparse
import json
import os
import sys

from bridge_hook_common import (
    codex_stop_reason,
    compute_drain_decision,
    queue_attention_message,
    queue_summary,
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
        # The Codex managed Stop hook (`check-inbox.py --format codex` via
        # bridge-hooks.py) is the Codex turn-end inbox-drain. It reuses the
        # SHARED #9780 guard in compute_drain_decision so it gets the same
        # infinite-Stop-loop protection (per-agent marker keyed on
        # id+status+updated_ts, consecutive cap + cooldown), the
        # stop_hook_active short-circuit, the never-block-when-empty invariant,
        # the atomic-persist-before-block contract, the fail-open-on-error
        # behaviour, and the daemon double-submit suppression stamp.
        #
        # drain_top_actionable() inside compute_drain_decision keeps the two
        # distinct concerns intact (#1199): queued head first (claim it), else
        # open claimed work (continue it) — never a re-claim nudge of a
        # just-claimed task. codex_stop_reason supplies the engine-specific
        # instruction text over that shared guard.
        event = load_event()
        # compute_drain_decision already fails open (returns None) on its own
        # error paths, but a Stop hook MUST exit 0 / emit the codex "no
        # decision" {} on ANY unexpected error — check_inbox.py main has no
        # outer try/except, so a raise here would surface a Stop-hook error
        # banner. Wrap so any escape degrades to the safe no-block {}.
        try:
            decision = compute_drain_decision(
                agent,
                event,
                reason_builder=codex_stop_reason,
            )
        except Exception:  # noqa: BLE001 — Stop hook must never raise / nonzero
            decision = None
        if decision is None:
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
            return 0
        json.dump(decision, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    pending, row = queue_summary(agent)

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
