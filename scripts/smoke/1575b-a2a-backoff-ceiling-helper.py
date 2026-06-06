#!/usr/bin/env python3
"""Helper for scripts/smoke/1575b-a2a-backoff-ceiling.sh (#1575 Part B).

Exercises the real source symbols, not a reimplementation:

  - bridge_a2a_common.backoff_seconds(attempts, base=15, ceiling=...)
  - bridge_a2a_common.delivery_backoff_ceiling(cfg)
  - bridge_a2a_common.delivery_max_retry_after_seconds(cfg)
  - bridge-a2a.py:_schedule_retry
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_a2a_common as a2a  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "bridge_a2a_cli", os.path.join(REPO_ROOT, "bridge-a2a.py"))
_cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cli)


def cmd_backoff(argv: list[str]) -> int:
    attempts = int(argv[0])
    ceiling = int(argv[1])
    print(a2a.backoff_seconds(attempts, ceiling=ceiling))
    return 0


def _cfg(raw: str | None) -> dict[str, Any]:
    if raw:
        loaded = json.loads(raw)
        if isinstance(loaded, dict):
            return loaded
    return {}


def cmd_ceiling(argv: list[str]) -> int:
    print(a2a.delivery_backoff_ceiling(_cfg(argv[0] if argv else None)))
    return 0


def cmd_max_retry_after(argv: list[str]) -> int:
    print(a2a.delivery_max_retry_after_seconds(_cfg(argv[0] if argv else None)))
    return 0


def _seed_outbox(db_path: str, attempts: int) -> str:
    """Create a minimal outbox with one row at attempts-1."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(a2a._OUTBOX_SCHEMA)
    message_id = "m-1575b"
    now = a2a.now_ts()
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "created_ts, updated_ts) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (message_id, "peer-x", "agent-y", "normal", "t", "/dev/null", "",
         "sending", max(0, attempts - 1), 0, now, now),
    )
    conn.commit()
    conn.close()
    return message_id


def cmd_schedule(argv: list[str]) -> int:
    db_path = argv[0]
    attempts = int(argv[1])
    retry_after = None
    cfg: dict[str, Any] = {}
    rest = list(argv[2:])
    i = 0
    while i < len(rest):
        if rest[i] == "--config":
            cfg = _cfg(rest[i + 1])
            i += 2
            continue
        retry_after = rest[i]
        i += 1

    message_id = _seed_outbox(db_path, attempts)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    fixed_now = 2_000_000_000
    old_now = a2a.now_ts
    a2a.now_ts = lambda: fixed_now
    try:
        _cli._schedule_retry(
            conn, message_id, attempts, cfg,
            last_error="transport: simulated", retry_after=retry_after,
        )
        row = conn.execute(
            "SELECT status, next_attempt_ts FROM outbox WHERE message_id=?",
            (message_id,),
        ).fetchone()
    finally:
        a2a.now_ts = old_now
        conn.close()
    print(json.dumps({"status": row["status"], "delay": int(row["next_attempt_ts"]) - fixed_now}))
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: 1575b-a2a-backoff-ceiling-helper.py <cmd> ...",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "backoff":
        return cmd_backoff(rest)
    if cmd == "ceiling":
        return cmd_ceiling(rest)
    if cmd == "max-ra":
        return cmd_max_retry_after(rest)
    if cmd == "schedule":
        return cmd_schedule(rest)
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
