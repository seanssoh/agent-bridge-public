#!/usr/bin/env python3
"""v0166-lb-transient-peers-helper.py — driver for the Lane-B transient-peer
resilience smoke (#1732, codex design-consensus #11698).

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Every subcommand drives the
REAL production code paths against an ISOLATED outbox.db / reconcile.db / config
under a tmp BRIDGE_HOME — nothing is re-implemented here:

  - bridge-a2a.py:cmd_deliver / _deliver_one / _schedule_retry — the classic
    per-peer outbox drain + the transient-park / permanent-dead / expired-
    retention terminal behavior.
  - bridge-a2a.py:cmd_outbox (`list --json`) — the class-aware enrichment
    (peer_class / alarm_on_unreachable / stuck_alert_secs) the daemon reads.
  - bridge-daemon-helpers.py:cmd_a2a_stuck_decide — the class-aware alarm filter
    (transient suppressed; persistent unchanged).
  - bridge_reconcile_common.py:peer_reachability_step — the #1707 UP transition
    that wakes a transient peer's parked rows (NO inline deliver).
  - bridge_a2a_common.py:_OUTBOX_SCHEMA / wake_peer_outbox_for_resume / peer_*.

The point under test is the CLASSIC OUTBOX (not just the rooms FSM): rooms ride
the same per-peer outbox, so covering the classic path covers rooms too.

Subcommands (each prints `OK <cmd> ...` + exits 0 on pass; `FAIL ...` to stderr
+ exits 1 on a contract violation):
  transient-park           — transient peer + retryable failure past
                             delivery_max_attempts → row PARKED (status='retry',
                             NOT dead), backoff capped, lease cleared.
  transient-ttl-expiry     — a parked transient row older than the retention TTL
                             → dead(expired-transient-retention); `outbox gc`
                             then reclaims it.
  permanent-still-dead     — a PERMANENT failure (missing secret) on a transient
                             peer → still `dead` immediately (any class).
  reconnect-flush          — the #1707 peer-reachability UP transition wakes the
                             transient peer's parked retry rows → pending,
                             next_attempt_ts=0, leases cleared, with NO inline
                             deliver (the woken row stays pending, never acked,
                             by the reconcile step).
  alarm-class-aware        — cmd_a2a_stuck_decide suppresses the transient peer's
                             stuck alarm and keeps the persistent peer's alarm.
  default-persistent       — a peer with NO class opted in behaves byte-identical
                             to before: max-attempts → dead(maxattempts).
"""

import importlib.util
import io
import contextlib
import json
import os
import sqlite3
import sys

PEER_T = "laptop-transient"
PEER_P = "server-persistent"
SECRET = "x" * 40


def _load_modules(repo_root: str):
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_a2a_common as a2a  # noqa: E402 - path set above
    import bridge_reconcile_common as reconcile  # noqa: E402 - path set above
    spec = importlib.util.spec_from_file_location(
        "bridge_a2a_cli", os.path.join(repo_root, "bridge-a2a.py"))
    cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cli)
    spec_h = importlib.util.spec_from_file_location(
        "bridge_daemon_helpers", os.path.join(repo_root, "bridge-daemon-helpers.py"))
    helpers = importlib.util.module_from_spec(spec_h)
    spec_h.loader.exec_module(helpers)
    return a2a, reconcile, cli, helpers


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _write_config(a2a, cfg_path: str, *, peers: list) -> None:
    """A minimal valid sender config. Mode 0600 so load_config() accepts it."""
    cfg = {
        "bridge_id": "self-lb",
        "listen": {"port": 8787},
        # A short retention so the TTL-expiry case is deterministic without
        # waiting days; floored at MIN_TRANSIENT_RETENTION_SECONDS in the helper.
        "transient_retention_seconds": a2a.MIN_TRANSIENT_RETENTION_SECONDS,
        "delivery_max_attempts": 3,
        "delivery_backoff_ceiling_seconds": 15,
        "peers": peers,
    }
    with open(cfg_path, "w", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        json.dump(cfg, fh)
    os.chmod(cfg_path, 0o600)


def _peer_entry(peer_id: str, *, klass=None, secret=SECRET, port=9):
    # port 9 = discard/closed on loopback -> connection refused (instant,
    # retryable transport failure). No node_id/tailscale_name -> the default
    # resolver returns the literal address (no live tailscale call).
    entry = {"id": peer_id, "address": "127.0.0.1", "port": port}
    if secret is not None:
        entry["secret"] = secret
    if klass is not None:
        entry["class"] = klass
    return entry


def _seed_row(a2a, db_path: str, *, message_id, peer_id, attempts=0,
              status="pending", next_attempt_ts=None, created_ts=None,
              body="{}"):
    conn = _connect(db_path)
    conn.executescript(a2a._OUTBOX_SCHEMA)
    now = a2a.now_ts()
    if next_attempt_ts is None:
        next_attempt_ts = now - 5
    if created_ts is None:
        created_ts = now
    work = os.path.dirname(os.path.abspath(db_path))
    body_path = os.path.join(work, f"{message_id}-body.json")
    with open(body_path, "w", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        fh.write(body)
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, body_bytes, status, attempts, next_attempt_ts, "
        "lease_owner, lease_expires_ts, last_error, created_ts, updated_ts) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (message_id, peer_id, "agent-y", "normal", "t", body_path, "",
         len(body.encode("utf-8")), status, attempts, next_attempt_ts,
         None, 0, "", created_ts, now),
    )
    conn.commit()
    conn.close()
    return body_path


def _row(db_path: str, message_id: str) -> dict:
    conn = _connect(db_path)
    try:
        r = conn.execute(
            "SELECT status, attempts, next_attempt_ts, lease_owner, "
            "lease_expires_ts, last_error, created_ts FROM outbox "
            "WHERE message_id=?",
            (message_id,),
        ).fetchone()
    finally:
        conn.close()
    return dict(r) if r is not None else {}


def _run_deliver(cli):
    """Run the REAL cmd_deliver tick once (stderr captured)."""
    import argparse
    ns = argparse.Namespace(lease=120, timeout=2.0, batch=25)
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        cli.cmd_deliver(ns)
    return buf.getvalue()


def _fail(msg: str) -> int:
    print(f"FAIL {msg}", file=sys.stderr)
    return 1


# --------------------------------------------------------------------------


def cmd_transient_park(repo_root, db, cfg) -> int:
    a2a, _reconcile, cli, _helpers = _load_modules(repo_root)
    _write_config(a2a, cfg, peers=[_peer_entry(PEER_T, klass="transient")])
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    # Seed at attempts = max-1 so this single tick crosses delivery_max_attempts
    # (3). The peer's port 9 refuses -> retryable transport failure.
    _seed_row(a2a, db, message_id="m-park", peer_id=PEER_T, attempts=2)
    _run_deliver(cli)
    r = _row(db, "m-park")
    if r.get("status") != "retry":
        return _fail(f"transient-park: expected status=retry (parked), got {r!r}")
    if r.get("lease_owner") is not None:
        return _fail(f"transient-park: lease not cleared: {r!r}")
    if "parked" not in (r.get("last_error") or ""):
        return _fail(f"transient-park: last_error not marked parked: {r!r}")
    if int(r.get("attempts") or 0) < 3:
        return _fail(f"transient-park: attempts not advanced: {r!r}")
    # Capped backoff: next_attempt_ts must be in the near future (<= ceiling),
    # never dead and never a multi-hour idle.
    delta = int(r.get("next_attempt_ts") or 0) - a2a.now_ts()
    if delta <= 0 or delta > 60:
        return _fail(f"transient-park: next_attempt_ts not capped near-future: {delta}s")
    print(f"OK transient-park status=retry parked next_in~{delta}s attempts={r['attempts']}")
    return 0


def cmd_transient_ttl_expiry(repo_root, db, cfg) -> int:
    a2a, _reconcile, cli, _helpers = _load_modules(repo_root)
    _write_config(a2a, cfg, peers=[_peer_entry(PEER_T, klass="transient")])
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    # created_ts older than the retention TTL + at the max-attempts ceiling, so
    # the next attempt crosses the gate AND the row is past retention -> expire.
    old_created = a2a.now_ts() - (a2a.MIN_TRANSIENT_RETENTION_SECONDS + 100)
    _seed_row(a2a, db, message_id="m-ttl", peer_id=PEER_T, attempts=2,
              created_ts=old_created)
    _run_deliver(cli)
    r = _row(db, "m-ttl")
    if r.get("status") != "dead":
        return _fail(f"transient-ttl: expected dead, got {r!r}")
    if "expired-transient-retention" not in (r.get("last_error") or ""):
        return _fail(f"transient-ttl: wrong dead reason: {r!r}")
    # GC reclaims it (terminal row older than max-age). cmd_outbox gc computes
    # cutoff = now - max_age and deletes terminal rows with updated_ts < cutoff.
    # The row's updated_ts was just stamped `now`, so max_age=-1 -> cutoff=now+1
    # deterministically reclaims it (max_age=0 is falsy -> the 14-day default).
    import argparse
    gc_ns = argparse.Namespace(action="gc", max_age=-1, json=False,
                               message_id=None, max_rows=None)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cli.cmd_outbox(gc_ns)
    after = _row(db, "m-ttl")
    if after:
        return _fail(f"transient-ttl: GC did not reclaim the expired row: {after!r}")
    print("OK transient-ttl-expiry dead(expired-transient-retention) gc-reclaimed")
    return 0


def cmd_permanent_still_dead(repo_root, db, cfg) -> int:
    a2a, _reconcile, cli, _helpers = _load_modules(repo_root)
    # A transient peer WITHOUT a secret -> peer_send_secret raises -> _mark_dead
    # is hit BEFORE the max-attempts gate: a permanent failure dead-letters
    # immediately for ANY class. Use BRIDGE_A2A_DEV_INSECURE_BIND to get past the
    # config-level secret validation so the per-row permanent path is exercised.
    _write_config(a2a, cfg,
                  peers=[_peer_entry(PEER_T, klass="transient", secret=None)])
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_DEV_INSECURE_BIND"] = "1"  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"  # noqa: iso-helper-boundary
    try:
        # attempts=0: a permanent failure must NOT wait for max-attempts.
        _seed_row(a2a, db, message_id="m-perm", peer_id=PEER_T, attempts=0)
        _run_deliver(cli)
        r = _row(db, "m-perm")
    finally:
        for k in ("BRIDGE_A2A_DEV_INSECURE_BIND", "BRIDGE_A2A_ALLOW_TEST_BIND"):
            os.environ.pop(k, None)  # noqa: iso-helper-boundary
    if r.get("status") != "dead":
        return _fail(f"permanent-still-dead: expected dead, got {r!r}")
    if "expired-transient-retention" in (r.get("last_error") or ""):
        return _fail(f"permanent-still-dead: wrongly took the transient path: {r!r}")
    if "parked" in (r.get("last_error") or ""):
        return _fail(f"permanent-still-dead: wrongly parked a permanent failure: {r!r}")
    # _mark_dead does not advance attempts; a permanent failure dies on the very
    # first attempt without walking the max-attempts ladder. (Note: `or` would
    # mis-handle the legitimate 0 value — compare explicitly.)
    if int(r.get("attempts")) != 0:
        return _fail(f"permanent-still-dead: should die on attempt 0, got {r!r}")
    print(f"OK permanent-still-dead dead-immediately (transient peer) reason={r['last_error'][:40]!r}")
    return 0


def cmd_reconnect_flush(repo_root, db, cfg) -> int:
    a2a, reconcile, _cli, _helpers = _load_modules(repo_root)
    recon_db = os.path.join(os.path.dirname(os.path.abspath(db)), "reconcile.db")
    for p in (recon_db, recon_db + "-wal", recon_db + "-shm"):
        if os.path.exists(p):
            os.remove(p)
    _write_config(a2a, cfg, peers=[_peer_entry(PEER_T, klass="transient")])
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_RECONCILE_DB"] = recon_db  # noqa: iso-helper-boundary
    # A parked transient row: status='retry', a FUTURE next_attempt_ts (waiting
    # on backoff), a stale lease -> exactly the shape the flush must re-arm.
    now = a2a.now_ts()
    _seed_row(a2a, db, message_id="m-flush", peer_id=PEER_T, attempts=5,
              status="retry", next_attempt_ts=now + 9999)
    # Stamp a stale lease on it so we can prove the flush clears it.
    c = _connect(db)
    c.execute("UPDATE outbox SET lease_owner='dead-runner', lease_expires_ts=? "
              "WHERE message_id=?", (now + 9999, "m-flush"))
    c.commit()
    c.close()

    # Drive the REAL peer_reachability_step through a DOWN->UP transition. The
    # probe seam is injected so no real network is touched. Between ticks we
    # clear the per-peer backoff gate row (the documented v0165-l3 pattern) so
    # the next tick is eligible to probe; otherwise a backed-off DOWN peer is
    # SKIPPED and never sees the recovery.
    rconn = reconcile.open_reconcile_db()
    cfg_data = a2a.load_config()
    step_id = reconcile._peer_step_id(PEER_T)
    threshold = reconcile.peer_suspect_threshold()

    state = {"reachable": False}

    def _probe(_addr, _port, _timeout):
        return state["reachable"]

    orig = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = _probe
    try:
        # Drive the peer all the way to DOWN (a real non-UP state).
        for _ in range(threshold):
            rconn.execute("DELETE FROM reconcile_step WHERE step = ?", (step_id,))
            rconn.commit()
            reconcile.peer_reachability_step(cfg_data, rconn)
        st = reconcile._peer_state_row(rconn, PEER_T)[0]
        if st == reconcile.PEER_STATE_UP:
            return _fail(f"reconnect-flush: precondition not non-UP ({st})")
        # While DOWN, the parked row must NOT have been woken.
        mid = _row(db, "m-flush")
        if mid.get("status") != "retry":
            return _fail(f"reconnect-flush: row woken while peer DOWN: {mid!r}")
        # Flip to UP -> a single success drives the DOWN->UP transition that
        # fires the flush.
        state["reachable"] = True
        rconn.execute("DELETE FROM reconcile_step WHERE step = ?", (step_id,))
        rconn.commit()
        reconcile.peer_reachability_step(cfg_data, rconn)
    finally:
        reconcile._PEER_REACHABILITY_PROBE = orig
        rconn.close()

    r = _row(db, "m-flush")
    if r.get("status") != "pending":
        return _fail(f"reconnect-flush: row not woken to pending: {r!r}")
    if int(r.get("next_attempt_ts")) != 0:
        return _fail(f"reconnect-flush: next_attempt_ts not zeroed: {r!r}")
    if r.get("lease_owner") is not None:
        return _fail(f"reconnect-flush: lease not cleared: {r!r}")
    # NO inline deliver from the reconcile step: the row is pending (due), never
    # acked/sending by the reconcile step itself — the deliver loop owns that.
    if r.get("status") in ("acked", "sending"):
        return _fail(f"reconnect-flush: reconcile delivered inline (should not): {r!r}")
    print("OK reconnect-flush UP-transition woke parked row -> pending, ts=0, lease cleared, NO inline deliver")
    return 0


def cmd_alarm_class_aware(repo_root, db, cfg) -> int:
    a2a, _reconcile, cli, helpers = _load_modules(repo_root)
    _write_config(a2a, cfg, peers=[
        _peer_entry(PEER_T, klass="transient"),
        _peer_entry(PEER_P, klass="persistent"),
    ])
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    # Two equally-old stuck rows: one per peer. Both well past any threshold.
    old = a2a.now_ts() - 100000
    _seed_row(a2a, db, message_id="m-tr", peer_id=PEER_T, attempts=2,
              status="retry", next_attempt_ts=a2a.now_ts() + 10, created_ts=old)
    _seed_row(a2a, db, message_id="m-pr", peer_id=PEER_P, attempts=2,
              status="retry", next_attempt_ts=a2a.now_ts() + 10, created_ts=old)

    # Produce the enriched `outbox list --json` the daemon decider consumes.
    import argparse
    list_ns = argparse.Namespace(action="list", json=True, message_id=None,
                                 max_age=None, max_rows=None)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cli.cmd_outbox(list_ns)
    rows = json.loads(buf.getvalue())
    by_id = {r["message_id"]: r for r in rows}
    if by_id["m-tr"].get("alarm_on_unreachable") is not False:
        return _fail(f"alarm: transient row not marked alarm_on_unreachable=False: {by_id['m-tr']!r}")
    if by_id["m-pr"].get("alarm_on_unreachable") is not True:
        return _fail(f"alarm: persistent row not marked alarm_on_unreachable=True: {by_id['m-pr']!r}")
    if by_id["m-tr"].get("peer_class") != "transient":
        return _fail(f"alarm: transient peer_class wrong: {by_id['m-tr']!r}")

    # Write the rows to a temp JSON file + empty ledger, then run the REAL
    # cmd_a2a_stuck_decide and assert only the persistent row is emitted.
    work = os.path.dirname(os.path.abspath(db))
    list_path = os.path.join(work, "alarm-list.json")
    ledger_path = os.path.join(work, "alarm-ledger.json")
    with open(list_path, "w", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        json.dump(rows, fh)
    with open(ledger_path, "w", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        json.dump({}, fh)
    decide_ns = argparse.Namespace(
        now=a2a.now_ts(), stuck_secs=600, reemit_secs=3600,
        ledger_path=ledger_path, outbox_json_path=list_path)
    dbuf = io.StringIO()
    with contextlib.redirect_stdout(dbuf):
        helpers.cmd_a2a_stuck_decide(decide_ns)
    emitted = dbuf.getvalue()
    if "m-pr" not in emitted:
        return _fail(f"alarm: persistent row should alarm but did not: {emitted!r}")
    if "m-tr" in emitted:
        return _fail(f"alarm: transient row was NOT suppressed: {emitted!r}")
    print("OK alarm-class-aware transient suppressed, persistent alarmed")
    return 0


def cmd_default_persistent(repo_root, db, cfg) -> int:
    a2a, _reconcile, cli, _helpers = _load_modules(repo_root)
    # NO class key at all -> default persistent -> classic terminal dead at
    # max-attempts (byte-identical to before this PR).
    _write_config(a2a, cfg, peers=[_peer_entry(PEER_P)])  # no klass
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = db  # noqa: iso-helper-boundary
    os.environ["BRIDGE_A2A_CONFIG"] = cfg  # noqa: iso-helper-boundary
    _seed_row(a2a, db, message_id="m-def", peer_id=PEER_P, attempts=2)
    _run_deliver(cli)
    r = _row(db, "m-def")
    if r.get("status") != "dead":
        return _fail(f"default-persistent: expected classic dead, got {r!r}")
    if "max attempts" not in (r.get("last_error") or ""):
        return _fail(f"default-persistent: wrong dead reason (not classic maxattempts): {r!r}")
    if "parked" in (r.get("last_error") or "") or \
            "expired-transient-retention" in (r.get("last_error") or ""):
        return _fail(f"default-persistent: a no-class peer took a transient path: {r!r}")
    print("OK default-persistent dead(maxattempts) byte-identical (no class opt-in)")
    return 0


_DISPATCH = {
    "transient-park": cmd_transient_park,
    "transient-ttl-expiry": cmd_transient_ttl_expiry,
    "permanent-still-dead": cmd_permanent_still_dead,
    "reconnect-flush": cmd_reconnect_flush,
    "alarm-class-aware": cmd_alarm_class_aware,
    "default-persistent": cmd_default_persistent,
}


def main(argv) -> int:
    if len(argv) < 5:
        print("usage: helper <cmd> <repo_root> <db> <cfg>", file=sys.stderr)
        return 2
    cmd, repo_root, db, cfg = argv[1], argv[2], argv[3], argv[4]
    fn = _DISPATCH.get(cmd)
    if fn is None:
        print(f"FAIL unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    return fn(repo_root, db, cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
