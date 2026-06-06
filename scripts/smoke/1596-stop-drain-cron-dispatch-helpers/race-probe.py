#!/usr/bin/env python3
"""Race probe for issue #1596 case (g): the SELECTED Stop-drain row becomes done
between selection and block emission → the drain must FAIL OPEN (no block) and
must never raise into the Stop path.

We import the real hooks module, monkeypatch ``_row_still_open`` to report the
chosen row gone (the late re-check seeing a closed/vanished row), then drive
``compute_drain_decision`` exactly as the Codex Stop hook does. The probe prints
``NONE`` when the drain correctly returns no decision (fail open) and ``BLOCK``
if it wrongly emitted a block. Any exception escaping the drain is a fail-open
VIOLATION — we let it propagate so the smoke sees a non-empty stderr + nonzero
exit and FAILs the case.

Invoked file-as-argv from the smoke (footgun #11: no python3 heredoc-stdin).
``sys.argv[1]`` is the agent id; the queue env (BRIDGE_TASK_DB / BRIDGE_HOME /
BRIDGE_ACTIVE_AGENT_DIR / ...) is inherited from the smoke.
"""
from __future__ import annotations

import os
import sys

# this file: <repo>/scripts/smoke/1596-stop-drain-cron-dispatch-helpers/race-probe.py
# → repo root is FOUR dirname() hops up; hooks/ lives there.
_HELPERS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HELPERS_DIR)))
HOOKS_DIR = os.path.join(_REPO_ROOT, "hooks")
sys.path.insert(0, HOOKS_DIR)

import bridge_hook_common as b  # noqa: E402 — path injected above


def main() -> int:
    agent = sys.argv[1] if len(sys.argv) > 1 else ""
    if not agent:
        print("NONE")
        return 0

    # Simulate the race: by the time the late re-check runs, the selected row
    # has been closed/removed. _row_still_open is the as-late-as-practical
    # confirmation; force it to report "gone".
    b._row_still_open = lambda _agent, _task_id: False  # type: ignore[attr-defined]

    decision = b.compute_drain_decision(
        agent,
        {},
        reason_builder=b.codex_stop_reason,
    )
    print("NONE" if decision is None else "BLOCK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
