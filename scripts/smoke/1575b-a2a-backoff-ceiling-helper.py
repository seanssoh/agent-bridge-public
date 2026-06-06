#!/usr/bin/env python3
"""Helper for scripts/smoke/1575b-a2a-backoff-ceiling.sh (#1575 Part B).

Exercises the REAL source symbols (no re-implementation) so the smoke pins
the actual sender-side outbox backoff-ceiling behavior:

  - bridge_a2a_common.backoff_seconds(attempts, base=15, ceiling=...)
  - bridge_a2a_common.delivery_backoff_ceiling(cfg)  (config + env override)
  - bridge-a2a.py:_schedule_retry  (the ceiling + Retry-After clamp + jitter)

Subcommands:

  backoff <attempts> <ceiling>
      Print backoff_seconds(attempts, ceiling=<ceiling>) — the pre-jitter
      curve clamp. (base stays 15.)

  ceiling <config_json>
      Print delivery_backoff_ceiling(cfg) for the given JSON config object —
      honors BRIDGE_A2A_BACKOFF_CEILING_SECONDS from the environment.

  schedule <outbox_db> <attempts> [retry_after] [--config <json>]
      Seed a one-row outbox at the given attempt count, run the SAME
      _schedule_retry the deliver loop uses, and print the resulting
      next_attempt delay (next_attempt_ts - now) as JSON {"delay": N}. This
      is the end-to-end tooth: ceiling clamp + jitter + Retry-After clamp.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_a2a_common as a2a  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "bridge_a2a_cli", os.path.join(REPO_ROOT, "bridge-a2a.py"))
_cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cli)

PLACEHOLDER_SECRET = "k" + "0" * 31  # non-secret-shaped 32-char placeholder


def cmd_backoff(argv) -> int:
    attempts = int(argv[0])
    ceiling = int(argv[1])
    print(a2a.backoff_seconds(attempts, ceiling=ceiling))
    return 0


def cmd_ceiling(argv) -> int:
    cfg = json.loads(argv[0]) if argv and argv[0] else {}
    print(a2a.delivery_backoff_ceiling(cfg))
    return 0


def _seed_outbox(db_path: str, attempts: int) -> str:
    """Create a minimal outbox with one row at attempts-1 (so the +1 in
    _schedule_retry lands on `attempts`). Returns the message_id."""
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


def cmd_schedule(argv) -> int:
    db_path = argv[0]
    attempts = int(argv[1])
    retry_after = None
    cfg: dict = {}
    rest = list(argv[2:])
    i = 0
    while i < len(rest):
        if rest[i] == "--config":
            cfg = json.loads(rest[i + 1])
            i += 2
            continue
        retry_after = rest[i]
        i += 1

    message_id = _seed_outbox(db_path, attempts)
    conn = sqlite3.connect(db_path)
    before = a2a.now_ts()
    _cli._schedule_retry(
        conn, message_id, attempts, cfg,
        last_error="transport: simulated", retry_after=retry_after,
    )
    row = conn.execute(
        "SELECT status, next_attempt_ts FROM outbox WHERE message_id=?",
        (message_id,),
    ).fetchone()
    conn.close()
    status, next_ts = row[0], int(row[1])
    print(json.dumps({"status": status, "delay": next_ts - before}))
    return 0


def main(argv) -> int:
    if not argv:
        print("usage: 1575b-a2a-backoff-ceiling-helper.py <cmd> ...",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "backoff":
        return cmd_backoff(rest)
    if cmd == "ceiling":
        return cmd_ceiling(rest)
    if cmd == "schedule":
        return cmd_schedule(rest)
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
