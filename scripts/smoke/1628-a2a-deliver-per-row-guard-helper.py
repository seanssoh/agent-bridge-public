#!/usr/bin/env python3
"""Helper for scripts/smoke/1628-a2a-deliver-per-row-guard.sh (#1628).

Exercises the REAL deliver loop, not a reimplementation:

  - bridge-a2a.py:cmd_deliver  — the serve-tick outbox drain loop
  - bridge-a2a.py:_deliver_one — the per-row attempt (reads body_path.read_bytes())
  - bridge-a2a.py:_schedule_retry — the transient demotion the guard reuses
  - bridge_a2a_common._OUTBOX_SCHEMA / load_config / outbox_db_path

Root cause under test (#1628): the per-candidate `_deliver_one` call ran with NO
per-row try/except. `_deliver_one` does `body_path.read_bytes()` outside any
local catch, so an unreadable body (e.g. an iso-owned 0660 envelope the runner
cannot read -> PermissionError) or a transient OSError unwound the WHOLE batch.
The poisoned row was left leased as 'sending' and every other healthy DUE row on
that tick was skipped (never even claimed). The fix wraps `_deliver_one` in a
per-row guard: on an unexpected error the row is demoted to the existing
transient `retry` path (lease cleared, backoff ladder walked, max-attempts
ceiling still eventually dead-letters) and the batch CONTINUES.

This helper builds a 2-row outbox — one unreadable-body row ordered FIRST (so an
un-guarded loop aborts on it) plus one healthy row ordered SECOND — runs the REAL
`cmd_deliver`, and dumps the post-tick state so the smoke can prove the healthy
row was still reached.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
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

BAD_ID = "m-1628-bad"     # unreadable body -> _deliver_one raises PermissionError
GOOD_ID = "m-1628-good"   # readable body, peer points at a refused port -> retry
PEER_ID = "peer-1628"
SECRET = "x" * 32


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _write_config(cfg_path: str) -> None:
    """A minimal valid sender config: one provisioned (secret-bearing) peer that
    resolves to a literal loopback address on a refused port. Mode 0600 so
    load_config() accepts it (it refuses group/world-readable secret files)."""
    cfg = {
        "bridge_id": "self-1628",
        "listen": {"port": 8787},
        "peers": [
            {
                "id": PEER_ID,
                # No node_id / tailscale_name -> the default tailscale resolver
                # returns this literal address unchanged (raw-IP back-compat),
                # so no live `tailscale status` call is made.
                "address": "127.0.0.1",
                "port": 9,  # discard/closed -> connection refused (instant)
                "secret": SECRET,
            }
        ],
    }
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh)
    os.chmod(cfg_path, 0o600)


def _seed_two_rows(db_path: str, bad_body: str, good_body: str) -> None:
    conn = _connect(db_path)
    conn.executescript(a2a._OUTBOX_SCHEMA)
    now = a2a.now_ts()
    # Bad row ordered FIRST (smaller next_attempt_ts): an un-guarded loop aborts
    # on it before the good row is ever claimed.
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "lease_owner, lease_expires_ts, last_error, created_ts, updated_ts) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (BAD_ID, PEER_ID, "agent-y", "normal", "t", bad_body, "",
         "pending", 0, now - 10, None, 0, "", now, now),
    )
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "lease_owner, lease_expires_ts, last_error, created_ts, updated_ts) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (GOOD_ID, PEER_ID, "agent-y", "normal", "t", good_body, "",
         "pending", 0, now - 5, None, 0, "", now, now),
    )
    conn.commit()
    conn.close()


def _row(db_path: str, message_id: str) -> dict[str, Any]:
    conn = _connect(db_path)
    try:
        r = conn.execute(
            "SELECT status, attempts, lease_owner, lease_expires_ts, last_error "
            "FROM outbox WHERE message_id=?",
            (message_id,),
        ).fetchone()
    finally:
        conn.close()
    return dict(r) if r is not None else {}


def cmd_run(args: argparse.Namespace) -> dict[str, Any]:
    """Seed a poisoned-first + healthy-second batch, run the REAL deliver tick,
    and report the post-tick state of both rows plus the returned delivered count.
    """
    work = os.path.dirname(os.path.abspath(args.db))
    bad_body = os.path.join(work, "bad-body.json")
    good_body = os.path.join(work, "good-body.json")
    with open(bad_body, "w", encoding="utf-8") as fh:
        fh.write('{"envelope": "bad"}')
    with open(good_body, "w", encoding="utf-8") as fh:
        fh.write('{"envelope": "good"}')
    # Make the bad body unreadable so _deliver_one's body_path.read_bytes()
    # raises PermissionError — the exact #1628 trigger.
    os.chmod(bad_body, 0o000)

    _seed_two_rows(args.db, bad_body, good_body)

    cfg_path = os.path.join(work, "handoff.local.json")
    _write_config(cfg_path)
    os.environ["BRIDGE_A2A_CONFIG"] = cfg_path  # _run_deliver sets the outbox db

    rc, raised, log = _run_deliver(args.db)
    # Restore perms so the temp dir can be cleaned up.
    with contextlib.suppress(OSError):
        os.chmod(bad_body, 0o600)

    bad = _row(args.db, BAD_ID)
    good = _row(args.db, GOOD_ID)
    return {
        "rc": rc,
        "raised": raised,
        "euid": os.geteuid(),
        "bad_status": bad.get("status"),
        "bad_lease_owner": bad.get("lease_owner"),
        "bad_last_error": bad.get("last_error"),
        "good_status": good.get("status"),
        "good_attempts": good.get("attempts"),
        "processed_log": log,
    }


def _run_deliver(db_path: str) -> tuple[int, str, str]:
    """Run the REAL cmd_deliver, capturing its info()/print() stream so the
    caller can assert on the end-of-tick "processed N" line. Returns
    (rc, raised, captured_log)."""
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db_path
    ns = argparse.Namespace(lease=120, timeout=1.0, batch=25)
    raised = ""
    buf = io.StringIO()
    try:
        # cmd_deliver's info() prints to stderr; capture both so the processed
        # line is observable, and keep our JSON the only thing on real stdout.
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc = _cli.cmd_deliver(ns)
    except Exception as exc:  # noqa: BLE001 - capture an un-guarded abort
        rc = -1
        raised = f"{type(exc).__name__}: {exc}"
    return rc, raised, buf.getvalue()


def cmd_all_bad(args: argparse.Namespace) -> dict[str, Any]:
    """A batch whose ONLY due row is poisoned must still log "processed", not
    the misleading "no due outbox entries" — the demoted row counts toward the
    processed total (#1628 review finding 2)."""
    work = os.path.dirname(os.path.abspath(args.db))
    bad_body = os.path.join(work, "only-bad-body.json")
    with open(bad_body, "w", encoding="utf-8") as fh:
        fh.write('{"envelope": "bad"}')
    os.chmod(bad_body, 0o000)

    conn = _connect(args.db)
    conn.executescript(a2a._OUTBOX_SCHEMA)
    now = a2a.now_ts()
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, status, attempts, next_attempt_ts, "
        "lease_owner, lease_expires_ts, last_error, created_ts, updated_ts) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (BAD_ID, PEER_ID, "agent-y", "normal", "t", bad_body, "",
         "pending", 0, now - 10, None, 0, "", now, now),
    )
    conn.commit()
    conn.close()

    cfg_path = os.path.join(work, "handoff.local.json")
    _write_config(cfg_path)
    os.environ["BRIDGE_A2A_CONFIG"] = cfg_path

    rc, raised, log = _run_deliver(args.db)
    with contextlib.suppress(OSError):
        os.chmod(bad_body, 0o600)
    bad = _row(args.db, BAD_ID)
    return {
        "rc": rc,
        "raised": raised,
        "euid": os.geteuid(),
        "bad_status": bad.get("status"),
        "logged_no_due": "no due outbox entries" in log,
        "logged_processed": "processed 1 outbox entr" in log,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="1628-a2a-deliver-per-row-guard-helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_run = sub.add_parser("run")
    p_run.add_argument("db")
    p_run.set_defaults(func=cmd_run)

    p_all_bad = sub.add_parser("all-bad")
    p_all_bad.add_argument("db")
    p_all_bad.set_defaults(func=cmd_all_bad)

    args = parser.parse_args(argv)
    print(json.dumps(args.func(args)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
