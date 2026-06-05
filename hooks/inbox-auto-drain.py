#!/usr/bin/env python3
"""Stop hook: auto-drain the agent's inbox at turn end (#9780).

When a Claude turn ends with genuinely-actionable queue work, emit
``{"decision":"block","reason":...}`` so Claude Code re-enters the turn and
drains the inbox (claim → process → done) instead of going idle until an
external ``[Agent Bridge]`` push or a human wakes the agent. When there is no
actionable work, the hook stays silent (exit 0) and the session idles normally.

This is the BLOCKING counterpart to ``check-inbox.py --format text`` (which
mark-idle.sh already surfaces as additionalContext only). It is wired AFTER
``surface-reply-enforce.py`` in the Claude Stop chain so it can never shadow the
channel-reply enforcement block, and BEFORE ``session-stop.py``.

The infinite-Stop-loop guard, the never-block-when-empty invariant, the
``stop_hook_active`` short-circuit, the atomic-persist-before-block marker, the
fail-open-on-error contract, and the daemon double-submit coordination stamp all
live in ``bridge_hook_common.compute_drain_decision`` so the Codex managed Stop
hook (``check-inbox.py --format codex``) reuses the exact same guard. See
``bridge_hook_common`` §"Stop/turn-end inbox auto-drain (#9780)".

PR #449 contract: a Stop hook MUST always exit 0 — a non-zero exit surfaces an
operator banner. Every failure path here returns 0 and never blocks.
"""
from __future__ import annotations

import json
import os
import sys

from bridge_hook_common import claude_drain_reason, compute_drain_decision


def load_event() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def main() -> int:
    try:
        # Stop hook runs AS the agent; it reads its own BRIDGE_AGENT_ID to
        # identify itself and writes its own per-agent marker under
        # BRIDGE_ACTIVE_AGENT_DIR (same-UID, no controller→iso crossing). The
        # `os.environ` token false-matches the ratchet's `.env` boundary
        # pattern — the identical false-positive is already noqa'd in
        # bridge_hook_common.py and baselined in check_inbox.py.
        agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env pattern; Stop hook self-identity read, not a controller→iso artifact
        if not agent:
            return 0  # TUI-only / admin session — not a bridge agent context.

        event = load_event()
        decision = compute_drain_decision(
            agent,
            event,
            reason_builder=claude_drain_reason,
        )
        if decision is None:
            return 0  # no actionable work, guard suppressed, or failed open.

        sys.stdout.write(json.dumps(decision, ensure_ascii=False))
        sys.stdout.flush()
    except Exception:  # noqa: BLE001 — Stop hook must never raise / non-zero.
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
