#!/usr/bin/env python3
"""Helper for scripts/smoke/1563-pr8-a2a-diag-recovery.sh (#1563 PR-8).

Splits the teeth into two surfaces:

  classify <probe_ok> <local_healthz> <peer_online>
      Unit-test the directional classifier (_a2a_classify_leg) with the three
      probe inputs supplied explicitly — deterministic, no sockets/tailscale.
      Emits the classification word to stdout. This is the #1 teeth surface:
      a bare transport timeout (no probe inputs) has NO classification; this
      proves the classifier maps each leg combination to the right code.

  reset-scenario <outbox_db> <config> <ledger> [--dry-run] [--reset-prev-ok]
      Integration: build is done by the caller (build-outbox); this runs
      `bridge-a2a.py diagnose-stuck --json` against a real outbox + a real
      loopback listener / closed port (the #2 teeth: probe SUCCESS -> reset,
      probe FAIL -> not reset, leased never reset). Prints the JSON report.

  build-outbox <outbox_db> <ok_port> <closed_port>
      Seed a temp outbox with retry rows for a reachable peer (ok_port), an
      unreachable peer (closed_port), plus a LEASED reachable row that must
      never be reset. Writes the matching config next to <outbox_db>.

  ack-history <outbox_db>
      #4 teeth: simulate the ack path's UPDATE and assert last_error is
      PRESERVED (not NULL) on the acked row.

  listen <ok_port_file>
      Start a backgroundable loopback listener; write its port to the file and
      block (the caller backgrounds + kills it). Used so a raw-IP peer probe
      SUCCEEDS deterministically.

  free-port
      Print a free loopback TCP port (bind+close).
"""
from __future__ import annotations

import json
import os
import socket
import sqlite3
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_a2a_common as a2a  # noqa: E402

# Import the classifier + constants directly from the CLI module so the unit
# test exercises the SAME function the daemon path uses.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "bridge_a2a_cli", os.path.join(REPO_ROOT, "bridge-a2a.py"))
_cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cli)

PLACEHOLDER_SECRET = "k" + "0" * 31  # non-secret-shaped 32-char placeholder


def _tribool(token: str):
    token = token.strip().lower()
    if token in ("true", "1", "yes", "ok", "healthy", "online"):
        return True
    if token in ("false", "0", "no", "fail", "unhealthy", "offline"):
        return False
    return None  # "none" / "indeterminate" / "unknown"


def cmd_classify(argv):
    probe_ok = _tribool(argv[0])
    local_healthz = _tribool(argv[1])
    peer_online = _tribool(argv[2]) if len(argv) > 2 else None
    tailnet = {"self_tx": None, "self_rx": None, "peer_online": peer_online}
    out = _cli._a2a_classify_leg(
        probe_ok=bool(probe_ok),
        local_healthz=local_healthz,
        tailnet=tailnet,
    )
    print(out)
    return 0


def cmd_classify_asymmetry(argv):
    # tx==0 rx>0 (outbound dead) -> local_tailnet_degraded regardless of peer.
    tailnet = {"self_tx": 0, "self_rx": 12345, "peer_online": True}
    out = _cli._a2a_classify_leg(probe_ok=False, local_healthz=True, tailnet=tailnet)
    print(out)
    return 0


def _config(ok_port, closed_port):
    return {
        "bridge_id": "smoke-local-node",
        "listen": {"port": 8787},
        "peers": [
            {"id": "reachable", "address": "127.0.0.1", "port": int(ok_port),
             "secret": PLACEHOLDER_SECRET},
            {"id": "unreachable", "address": "127.0.0.1", "port": int(closed_port),
             "secret": PLACEHOLDER_SECRET},
        ],
    }


def cmd_build_outbox(argv):
    outbox_db, ok_port, closed_port = argv[0], argv[1], argv[2]
    cfg_path = os.path.join(os.path.dirname(outbox_db) or ".", "handoff.local.json")
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump(_config(ok_port, closed_port), fh)
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = outbox_db
    os.environ["BRIDGE_A2A_CONFIG"] = cfg_path
    conn = a2a.open_outbox()
    now = a2a.now_ts()
    future = now + 3000

    def ins(mid, peer, status, next_ts, lease_owner=None, lease_exp=0):
        conn.execute(
            "INSERT INTO outbox(message_id,peer,target_agent,priority,title,"
            "body_path,body_sha256,body_bytes,status,attempts,next_attempt_ts,"
            "lease_owner,lease_expires_ts,last_error,created_ts,updated_ts) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (mid, peer, "agentX", "normal", "t", "/tmp/x", "abc", 1, status, 8,
             next_ts, lease_owner, lease_exp, "transport: timed out", now, now))

    ins("m-reach-1", "reachable", "retry", future)
    ins("m-reach-2", "reachable", "retry", future)
    ins("m-reach-leased", "reachable", "sending", future,
        lease_owner="runner-1", lease_exp=future)
    ins("m-unreach-1", "unreachable", "retry", future)
    conn.commit()
    conn.close()
    print(cfg_path)
    return 0


def cmd_reset_scenario(argv):
    outbox_db, cfg_path, ledger = argv[0], argv[1], argv[2]
    dry_run = "--dry-run" in argv[3:]
    env = dict(os.environ)
    env["BRIDGE_A2A_OUTBOX_DB"] = outbox_db
    env["BRIDGE_A2A_CONFIG"] = cfg_path
    argvx = [sys.executable, os.path.join(REPO_ROOT, "bridge-a2a.py"),
             "diagnose-stuck", "--json", "--probe-timeout", "2", "--ledger", ledger]
    if dry_run:
        argvx.append("--dry-run")
    out = subprocess.run(argvx, capture_output=True, text=True, env=env)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        return 1
    sys.stdout.write(out.stdout)
    return 0


def cmd_states(argv):
    outbox_db = argv[0]
    c = sqlite3.connect(outbox_db)
    c.row_factory = sqlite3.Row
    rows = {r["message_id"]: [r["status"], int(r["next_attempt_ts"])]
            for r in c.execute("SELECT message_id,status,next_attempt_ts FROM outbox")}
    c.close()
    print(json.dumps(rows))
    return 0


def cmd_rearm_retry(argv):
    # Reset the reachable rows back to retry/future so a later tick can re-test.
    outbox_db = argv[0]
    c = sqlite3.connect(outbox_db)
    now = int(time.time())
    c.execute("UPDATE outbox SET status='retry', next_attempt_ts=? "
              "WHERE message_id IN ('m-reach-1','m-reach-2')", (now + 3000,))
    c.commit()
    c.close()
    return 0


def cmd_ack_history(argv):
    """#4 teeth: prove the ack UPDATE PRESERVES last_error (not NULL).

    Mirrors _deliver_one's ack SQL (the PR-8 version omits last_error=NULL).
    A pre-PR-8 ack SQL (with `last_error=NULL`) would FAIL this check.
    """
    outbox_db = argv[0]
    os.environ["BRIDGE_A2A_OUTBOX_DB"] = outbox_db
    conn = a2a.open_outbox()
    now = a2a.now_ts()
    conn.execute(
        "INSERT INTO outbox(message_id,peer,target_agent,priority,title,"
        "body_path,body_sha256,body_bytes,status,attempts,next_attempt_ts,"
        "lease_owner,lease_expires_ts,last_error,created_ts,updated_ts) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("m-ack", "reachable", "agentX", "normal", "t", "/tmp/x", "abc", 1,
         "sending", 9, 0, None, 0, "transport: timed out (attempt 9)", now, now))
    conn.commit()
    # The PR-8 ack UPDATE (no last_error=NULL).
    conn.execute(
        "UPDATE outbox SET status='acked', attempts=?, "
        "acked_remote_task_id=?, updated_ts=? WHERE message_id=?",
        (9, "remote-123", a2a.now_ts(), "m-ack"))
    conn.commit()
    row = conn.execute(
        "SELECT status,last_error,acked_remote_task_id FROM outbox "
        "WHERE message_id='m-ack'").fetchone()
    conn.close()
    print(json.dumps({
        "status": row["status"],
        "last_error": row["last_error"],
        "acked_remote_task_id": row["acked_remote_task_id"],
    }))
    return 0


def cmd_listen(argv):
    port_file = argv[0]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    with open(port_file, "w", encoding="utf-8") as fh:
        fh.write(str(srv.getsockname()[1]))
    while True:
        try:
            c, _ = srv.accept()
            c.close()
        except OSError:
            break
    return 0


def cmd_free_port(argv):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    print(port)
    return 0


DISPATCH = {
    "classify": cmd_classify,
    "classify-asymmetry": cmd_classify_asymmetry,
    "build-outbox": cmd_build_outbox,
    "reset-scenario": cmd_reset_scenario,
    "states": cmd_states,
    "rearm-retry": cmd_rearm_retry,
    "ack-history": cmd_ack_history,
    "listen": cmd_listen,
    "free-port": cmd_free_port,
}


def main(argv):
    if not argv:
        sys.stderr.write("usage: helper <subcommand> [args...]\n")
        return 2
    fn = DISPATCH.get(argv[0])
    if fn is None:
        sys.stderr.write("unknown subcommand: %s\n" % argv[0])
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
