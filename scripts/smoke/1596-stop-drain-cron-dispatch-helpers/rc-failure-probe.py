#!/usr/bin/env python3
"""rc-failure probe for issue #1596 (patch-dev re-review blocker): a FAILED
``find-open`` read (nonzero exit) that still carries a parseable, valid-looking
row on stdout must FAIL OPEN — the Stop drain must NOT trust the row and emit a
block. Checking only empty-stdout (the prior guard) missed the nonzero-rc +
non-empty-stdout shape (a partial / SQLite-warning read).

We import the real hooks module and monkeypatch ``queue_cli`` to return a fake
``CompletedProcess`` for two shapes, then assert ``_open_rows_for`` /
``drain_top_actionable`` / ``compute_drain_decision`` behave:

  1. rc=2 + a valid queued row on stdout (a real read FAILURE) → fail OPEN:
     ``_open_rows_for`` is None, ``drain_top_actionable`` is None, and
     ``compute_drain_decision`` emits NO block.
  2. rc=1 + the literal ``[]`` (the documented genuinely-EMPTY sentinel) → the
     read SUCCEEDS empty: ``_open_rows_for`` returns ``[]`` (NOT None), so the
     queued path can still fall through to the claimed anti-abandonment path.
     This guards the fix from over-rejecting the legitimate empty case.

Prints ``NONE`` only when BOTH halves hold; otherwise ``BLOCK`` (case 1 wrongly
blocked) or ``BADEMPTY`` (case 2 regressed the empty sentinel). Any exception
escaping the drain is a fail-open VIOLATION — we let it propagate so the smoke
sees a nonzero exit and FAILs the case.

Invoked file-as-argv from the smoke (footgun #11: no python3 heredoc-stdin).
``sys.argv[1]`` is the agent id.
"""
from __future__ import annotations

import os
import subprocess
import sys

_HELPERS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HELPERS_DIR)))
HOOKS_DIR = os.path.join(_REPO_ROOT, "hooks")
sys.path.insert(0, HOOKS_DIR)

import bridge_hook_common as b  # noqa: E402 — path injected above


def _fake_cli(returncode: int, stdout: str):
    def _run(args, **_kw):
        return subprocess.CompletedProcess(
            args=args, returncode=returncode, stdout=stdout, stderr="sqlite: simulated read warning"
        )
    return _run


def main() -> int:
    agent = sys.argv[1] if len(sys.argv) > 1 else ""
    if not agent:
        print("NONE")
        return 0

    # --- case 1: nonzero rc + a valid-looking queued row → must fail OPEN ---
    valid_row = (
        '[{"id": 4242, "status": "queued", "title": "real user task", '
        '"created_by": "operator", "priority": "high", "updated_ts": 1}]'
    )
    b.queue_cli = _fake_cli(2, valid_row)  # type: ignore[assignment]
    if b._open_rows_for(agent, ["queued"]) is not None:
        print("BLOCK")
        return 0
    if b.drain_top_actionable(agent) is not None:
        print("BLOCK")
        return 0
    if b.compute_drain_decision(agent, {}, reason_builder=b.codex_stop_reason) is not None:
        print("BLOCK")
        return 0

    # --- case 2: rc==1 + literal "[]" sentinel → genuinely empty, NOT a failure ---
    b.queue_cli = _fake_cli(1, "[]")  # type: ignore[assignment]
    if b._open_rows_for(agent, ["queued"]) != []:
        print("BADEMPTY")
        return 0

    print("NONE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
