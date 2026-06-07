#!/usr/bin/env python3
"""Helper for scripts/smoke/1618-outbox-retry-resets-attempts.sh (#1618).

Exercises the REAL source symbols, not a reimplementation:

  - bridge-a2a.py:cmd_outbox  (action="retry") — the manual-requeue path
  - bridge-a2a.py:_schedule_retry — the serve-tick reschedule
  - bridge_a2a_common._OUTBOX_SCHEMA / backoff_seconds / delivery_backoff_ceiling

Root cause under test (#1618): `outbox retry` of a dead row already set
next_attempt_ts=0 ("send now"); the bug was that it PRESERVED `attempts`, so a
dead row at the delivery_max_attempts ceiling got exactly one serve tick before
re-dead-lettering / a ceiling-length backoff. The fix resets attempts=0 so a
manual retry walks the backoff ladder from the base interval again.
"""
from __future__ import annotations

import argparse
import contextlib
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

MESSAGE_ID = "m-1618"


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _seed(db_path: str, status: str, attempts: int) -> None:
    """Create a one-row outbox at the given status/attempts (ceiling-pinned)."""
    conn = _connect(db_path)
    conn.executescript(a2a._OUTBOX_SCHEMA)
    now = a2a.now_ts()
    # A previously dead-lettered row: a future-dated next_attempt_ts (a real
    # ceiling-length backoff) so the smoke can prove retry resets BOTH the
    # schedule (->0) and the counter (->0).
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "lease_owner, lease_expires_ts, last_error, created_ts, updated_ts) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (MESSAGE_ID, "peer-x", "agent-y", "normal", "t", "/dev/null", "",
         status, attempts, now + 86400, "stale-runner", now + 30,
         "max attempts (12): transport: simulated", now, now),
    )
    conn.commit()
    conn.close()


def _row(db_path: str) -> dict[str, Any]:
    conn = _connect(db_path)
    try:
        r = conn.execute(
            "SELECT status, attempts, next_attempt_ts, lease_owner, "
            "lease_expires_ts FROM outbox WHERE message_id=?",
            (MESSAGE_ID,),
        ).fetchone()
    finally:
        conn.close()
    return dict(r) if r is not None else {}


def cmd_retry(args: argparse.Namespace) -> int:
    """Seed a dead row at attempts, run the REAL `outbox retry`, dump the row."""
    _seed(args.db, args.status, args.attempts)
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = args.db
    ns = argparse.Namespace(action="retry", message_id=MESSAGE_ID,
                            json=False, max_age=None)
    # cmd_outbox prints "requeued <id>" to stdout; keep our JSON the only thing
    # on stdout by diverting the CLI's own print() to stderr.
    with contextlib.redirect_stdout(sys.stderr):
        rc = _cli.cmd_outbox(ns)
    out = _row(args.db)
    out["rc"] = rc
    print(json.dumps(out))
    return 0


def cmd_retry_missing(args: argparse.Namespace) -> int:
    """A retry of an ACKED row must not match the dead/retry filter (rc!=0)."""
    _seed(args.db, "acked", 3)
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = args.db
    ns = argparse.Namespace(action="retry", message_id=MESSAGE_ID,
                            json=False, max_age=None)
    with contextlib.redirect_stdout(sys.stderr):
        rc = _cli.cmd_outbox(ns)
    out = _row(args.db)
    out["rc"] = rc
    print(json.dumps(out))
    return 0


def _seed_with_managed_body(db_path: str, body_dir: str) -> str:
    """Seed a 'sending' row whose body_path is a REAL managed envelope under
    outgoing_dir(), so a dead-letter transition exercises the unlink guard."""
    os.makedirs(body_dir, exist_ok=True)
    body_path = os.path.join(body_dir, "m-1618.json")
    with open(body_path, "w", encoding="utf-8") as fh:
        fh.write('{"envelope": "stub"}')
    conn = _connect(db_path)
    conn.executescript(a2a._OUTBOX_SCHEMA)
    now = a2a.now_ts()
    # One attempt below the ceiling so the next _schedule_retry tick dead-letters.
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "created_ts, updated_ts) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (MESSAGE_ID, "peer-x", "agent-y", "normal", "t", body_path, "",
         "sending", 11, 0, now, now),
    )
    conn.commit()
    conn.close()
    return body_path


def cmd_dead_letter_body(args: argparse.Namespace) -> int:
    """Drive a REAL max-attempts dead-letter, then a manual retry, and prove the
    staged body survives so the retried row is actually sendable (#1618)."""
    # outgoing_dir() = state_dir()/handoff/outgoing; pin state under the temp db.
    state_dir = os.path.dirname(os.path.abspath(args.db))
    os.environ["BRIDGE_STATE_DIR"] = state_dir
    body_dir = str(a2a.outgoing_dir())
    body_path = _seed_with_managed_body(args.db, body_dir)

    # Sanity: the body is inside the managed root the unlink guard enforces.
    in_managed = False
    try:
        import pathlib
        pathlib.Path(body_path).resolve().relative_to(
            a2a.outgoing_dir().resolve())
        in_managed = True
    except ValueError:
        in_managed = False

    conn = _connect(args.db)
    # attempts already 11; the serve tick makes it 12 >= max(12) -> dead-letter.
    try:
        outcome = _cli._schedule_retry(
            conn, MESSAGE_ID, 12, {}, last_error="transport: simulated")
    finally:
        conn.close()
    body_after_dead = os.path.isfile(body_path)

    # Now the operator retries the dead row.
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = args.db
    ns = argparse.Namespace(action="retry", message_id=MESSAGE_ID,
                            json=False, max_age=None)
    with contextlib.redirect_stdout(sys.stderr):
        rc = _cli.cmd_outbox(ns)
    row = _row(args.db)
    body_after_retry = os.path.isfile(body_path)
    print(json.dumps({
        "in_managed": in_managed,
        "dead_outcome": outcome,
        "body_after_dead": body_after_dead,
        "retry_rc": rc,
        "status": row.get("status"),
        "attempts": row.get("attempts"),
        "body_after_retry": body_after_retry,
    }))
    return 0


def cmd_reschedule(args: argparse.Namespace) -> int:
    """After a reset (attempts=0), one failed serve tick must reschedule at the
    BASE interval, not the ceiling, and must NOT immediately re-dead-letter."""
    _seed(args.db, "pending", 0)
    conn = _connect(args.db)
    fixed_now = 2_000_000_000
    old_now = a2a.now_ts
    a2a.now_ts = lambda: fixed_now
    try:
        # Mirror the serve-tick increment (bridge-a2a.py:786): a post-reset row
        # at attempts=0 becomes attempts=1 for the first new send.
        outcome = _cli._schedule_retry(
            conn, MESSAGE_ID, 1, {}, last_error="transport: simulated")
        r = conn.execute(
            "SELECT status, attempts, next_attempt_ts FROM outbox "
            "WHERE message_id=?", (MESSAGE_ID,)).fetchone()
    finally:
        a2a.now_ts = old_now
        conn.close()
    print(json.dumps({
        "outcome": outcome,
        "status": r["status"],
        "attempts": int(r["attempts"]),
        "delay": int(r["next_attempt_ts"]) - fixed_now,
    }))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="1618-outbox-retry-resets-attempts-helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_retry = sub.add_parser("retry")
    p_retry.add_argument("db")
    p_retry.add_argument("--status", default="dead")
    p_retry.add_argument("--attempts", type=int, default=12)
    p_retry.set_defaults(func=cmd_retry)

    p_missing = sub.add_parser("retry-missing")
    p_missing.add_argument("db")
    p_missing.set_defaults(func=cmd_retry_missing)

    p_resched = sub.add_parser("reschedule")
    p_resched.add_argument("db")
    p_resched.set_defaults(func=cmd_reschedule)

    p_body = sub.add_parser("dead-letter-body")
    p_body.add_argument("db")
    p_body.set_defaults(func=cmd_dead_letter_body)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
