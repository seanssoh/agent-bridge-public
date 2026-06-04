#!/usr/bin/env python3
"""Helper for the rooms-p4-1-cross-node-join smoke (A2A Rooms P4.1).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical sender (signing + OS-actor joiner id), the canonical receiver
(`_handle_room_join_request` fail-closed stack + token verify + pending-row
persist), and the canonical schema — WITHOUT a live socket or Tailscale.

The transport is stubbed two ways:
  - SENDER side: the cross-node `bridge-rooms.py join` POST is captured by the
    paired-flag test hook (BRIDGE_ROOMS_TEST_POST_HOOK = this script's
    `post-hook` subcommand), which writes the fully-signed request to a file.
  - RECEIVER side: `deliver-to-receiver` reconstructs a minimal fake HTTP
    request from that captured file and drives the REAL handler method, so the
    actual auth preamble (protocol/peer/remote_addr/HMAC/skew/dedupe) + token
    verify + persistence run end to end. The peer uses a literal `address`
    (no node_id/tailscale_name) so resolve_peer_address returns it verbatim —
    no Tailscale.

Subcommands (argv[1]):
  post-hook <json>                 (used as BRIDGE_ROOMS_TEST_POST_HOOK) — write
                                   the signed request JSON to $CAPTURE_FILE and
                                   echo a stub "{}" response.
  captured-field <file> <key>      print headers[X-AGB-*] or body.<key> from a
                                   captured request file.
  deliver-to-receiver <repo_root> <cfg_json> <captured_file> [overrides_json]
                                   replay the captured request through the real
                                   receiver handler; print "status=<n> body=<json>".
  make-config <out_path> <this_node> <peer_node> <peer_secret> <address>
                                   write a minimal handoff config (loopback test
                                   bind) the receiver loads.
  pending-rows <db> <room_id>      print each pending join row as JSON lines.
  dedupe-rows <db>                 print each room_join_dedupe row as JSON lines.
  db-contains <db> <needle>        exit 0 iff <needle> appears in the db dump.
  file-tree-contains <dir> <needle> exit 0 iff <needle> appears under <dir>.
  drop-dedupe-table <db>           DROP room_join_dedupe (simulate unmigrated P1 db).
  set-token-ts <db> <room_id> <ts> backdate invite_token_ts (drive TTL expiry).
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402
import bridge_rooms_common as rooms  # noqa: E402


# ---------------------------------------------------------------------------
# sender-side capture hook (invoked as BRIDGE_ROOMS_TEST_POST_HOOK)
# ---------------------------------------------------------------------------
def cmd_post_hook(payload_json: str) -> int:
    """Write the signed cross-node request to $CAPTURE_FILE; stub a 200 body.

    The CLI sender calls us with the JSON {path, headers, body}. We persist it
    verbatim (so the smoke can assert on the OS-actor joiner id + hash-only
    body, and replay it into the receiver). stdout is the stubbed response body.
    """
    capture = os.environ.get("CAPTURE_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("CAPTURE_FILE unset", file=sys.stderr)
        return 1
    Path(capture).write_text(payload_json, encoding="utf-8")
    print("{}")  # stub response body
    return 0


def cmd_captured_field(path: str, key: str) -> int:
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    if key.startswith("header:"):
        val = doc.get("headers", {}).get(key[len("header:"):], "")
    elif key.startswith("body:"):
        body = json.loads(doc.get("body", "{}"))
        val = body.get(key[len("body:"):], "")
    elif key == "path":
        val = doc.get("path", "")
    else:
        print(f"unknown captured key: {key}", file=sys.stderr)
        return 1
    print(val)
    return 0


# ---------------------------------------------------------------------------
# receiver-side replay against the REAL handler
# ---------------------------------------------------------------------------
def _load_handoffd(repo_root: str):
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "bridge_handoffd", os.path.join(repo_root, "bridge-handoffd.py"))
    hd = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(hd)
    return hd


class _FakeHeaders:
    def __init__(self, headers: dict):
        self._h = headers

    def get(self, key, default=None):
        return self._h.get(key, default)


class _FakeRFile:
    def __init__(self, data: bytes):
        self._data = data

    def read(self, n: int = -1) -> bytes:
        if n < 0 or n >= len(self._data):
            out, self._data = self._data, b""
            return out
        out, self._data = self._data[:n], self._data[n:]
        return out


class _FakeServer:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.config_path = ""


def cmd_deliver_to_receiver(repo_root: str, cfg_json: str, captured: str,
                            overrides_json: str = "{}") -> int:
    """Replay a captured signed request through the REAL receiver handler.

    `overrides_json` lets a tooth mutate the captured request to drive an edge:
      {"client_ip": "...", "headers": {...override...},
       "body": "<replacement json string>", "recompute_hash": true}
    When `recompute_hash` is true the X-AGB-Body-SHA256 header is recomputed for
    the (possibly mutated) body — used to simulate a 'same id, different body'
    duplicate-conflict WITHOUT also tripping the body-hash gate.
    """
    hd = _load_handoffd(repo_root)
    cfg = json.loads(cfg_json)
    doc = json.loads(Path(captured).read_text(encoding="utf-8"))
    overrides = json.loads(overrides_json) if overrides_json else {}

    path = doc.get("path", a2a.ROOM_JOIN_PATH)
    headers = dict(doc.get("headers", {}))
    body = doc.get("body", "{}")

    if "headers" in overrides:
        headers.update(overrides["headers"])
    if "body" in overrides:
        body = overrides["body"]
    body_bytes = body.encode("utf-8") if isinstance(body, str) else bytes(body)
    if overrides.get("recompute_hash"):
        headers["X-AGB-Body-SHA256"] = a2a.body_sha256(body_bytes)
    # `resign`: recompute BOTH the body hash AND a VALID HMAC signature for the
    # (mutated) body using the peer's configured secret. Used to test a code
    # path DOWNSTREAM of the HMAC gate (e.g. the body PARSER) with a legitimately
    # signed but malformed body — so the test exercises the parser, not the
    # signature gate. It mirrors exactly what an authenticated node B could send.
    if overrides.get("resign"):
        peer_secret = ""
        for p in cfg.get("peers", []):
            if p.get("id") == headers.get("X-AGB-Peer", ""):
                peer_secret = p.get("secret", "")
                break
        body_hash = a2a.body_sha256(body_bytes)
        headers["X-AGB-Body-SHA256"] = body_hash
        canonical = a2a.canonical_string(
            "POST", path, headers.get("X-AGB-Peer", ""),
            headers.get("X-AGB-Message-Id", ""),
            headers.get("X-AGB-Timestamp", ""), body_hash)
        headers["X-AGB-Signature"] = a2a.sign(peer_secret, canonical)
    headers["Content-Length"] = str(len(body_bytes))

    # The authenticated peer address: the receiver resolves the peer's literal
    # `address`; the client_ip must match. Default to the peer's configured
    # address so the remote_addr gate passes; a tooth can override.
    peer_id = headers.get("X-AGB-Peer", "")
    peer_addr = ""
    for p in cfg.get("peers", []):
        if p.get("id") == peer_id:
            peer_addr = p.get("address", "")
            break
    client_ip = overrides.get("client_ip", peer_addr or "127.0.0.1")

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path
    handler.headers = _FakeHeaders(headers)
    handler.rfile = _FakeRFile(body_bytes)
    handler.client_address = (client_ip, 0)
    handler.server = _FakeServer(cfg)

    captured_reply = {}

    def _capture_reply(status, payload, extra_headers=None):
        captured_reply["status"] = status
        captured_reply["payload"] = payload

    handler._reply = _capture_reply  # type: ignore[assignment]
    handler._handle_room_join_request(cfg)

    status = captured_reply.get("status", 0)
    payload = captured_reply.get("payload", {})
    print(f"status={status} body={json.dumps(payload)}")
    return 0


# ---------------------------------------------------------------------------
# config + db inspection
# ---------------------------------------------------------------------------
def cmd_make_config(out_path: str, this_node: str, peer_node: str,
                    peer_secret: str, address: str) -> int:
    cfg = {
        "bridge_id": this_node,
        "listen": {"host": "127.0.0.1", "port": 8787,
                   "enqueue_path": "/enqueue"},
        "timestamp_skew_seconds": 300,
        "timestamp_skew_grace_seconds": 3600,
        "peers": [
            {
                "id": peer_node,
                "address": address,
                "secret": peer_secret,
                "inbound_allowlist": [],
            }
        ],
    }
    Path(out_path).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    return 0


def cmd_pending_rows(db: str, room_id: str) -> int:
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT room_id, agent, node, status, verified, via_node, "
            "ttl_expiry FROM room_join_requests WHERE room_id=? "
            "ORDER BY agent, node", (room_id,)
        ).fetchall()
    finally:
        conn.close()
    for r in rows:
        print(json.dumps({k: r[k] for k in r.keys()}))
    return 0


def cmd_dedupe_rows(db: str) -> int:
    """Print each room_join_dedupe row as a JSON line (P4.1 r2 ledger)."""
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT message_id, peer, body_sha256, created_ts "
            "FROM room_join_dedupe ORDER BY created_ts"
        ).fetchall()
    finally:
        conn.close()
    for r in rows:
        print(json.dumps({k: r[k] for k in r.keys()}))
    return 0


def cmd_db_contains(db: str, needle: str) -> int:
    conn = sqlite3.connect(db)
    try:
        dump = "\n".join(conn.iterdump())
    finally:
        conn.close()
    return 0 if needle and needle in dump else 1


def cmd_file_tree_contains(directory: str, needle: str) -> int:
    base = Path(directory)
    if not base.exists():
        return 1
    for p in base.rglob("*"):
        if p.is_file():
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if needle and needle in text:
                print(f"FOUND in {p}", file=sys.stderr)
                return 0
    return 1


def cmd_atomic_race_reclassify(db: str) -> int:
    """Unit-drive record_verified_cross_node_join_request_atomic's race branch
    (codex r3 #1). Proves a message_id PK collision is RECLASSIFIED to
    duplicate/conflict (never an unhandled raise / 500).

    We bypass the in-call pre-check by INSERTing the dedupe row through a SECOND
    connection AFTER the function under test would have pre-checked — emulated
    here by seeding the row first, then calling the function (its own pre-check
    catches the seeded row → duplicate). To exercise the IntegrityError catch
    branch specifically, we monkeypatch the pre-check SELECT to miss once, so the
    INSERT collides and the except-branch re-queries. Output: a line per case.
    """
    import bridge_rooms_common as r

    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    conn.executescript(r._ROOMS_SCHEMA)
    conn.commit()
    mid = "nodeB:race-1"
    body = "a" * 64
    # Seed a winner row (same body) directly.
    conn.execute(
        "INSERT INTO room_join_dedupe (message_id, peer, body_sha256, "
        "created_ts) VALUES (?, ?, ?, ?)", (mid, "nodeB", body, 1))
    conn.commit()
    # Pre-check path: the function sees the seeded row → DUPLICATE (same body).
    out1 = r.record_verified_cross_node_join_request_atomic(
        conn, message_id=mid, body_sha256=body, peer="nodeB",
        room_id="room-x", agent="z", node="nodeB", via_node="nodeB")
    print(f"precheck_same_body={out1}")
    # Pre-check path with a DIFFERENT body → CONFLICT.
    out2 = r.record_verified_cross_node_join_request_atomic(
        conn, message_id=mid, body_sha256="b" * 64, peer="nodeB",
        room_id="room-x", agent="z", node="nodeB", via_node="nodeB")
    print(f"precheck_diff_body={out2}")

    # IntegrityError branch: a thin proxy makes the FIRST pre-check SELECT for a
    # NEW id miss (simulating the concurrent winner's row not yet visible to this
    # reader), so the function proceeds to INSERT and collides on the PK, which
    # it must catch + re-query + reclassify (NOT raise). `sqlite3.Connection`
    # methods are read-only, so we wrap rather than monkeypatch.
    mid2 = "nodeB:race-2"
    conn.execute(
        "INSERT INTO room_join_dedupe (message_id, peer, body_sha256, "
        "created_ts) VALUES (?, ?, ?, ?)", (mid2, "nodeB", body, 1))
    conn.commit()

    class _Empty:
        def fetchone(self):
            return None

    class _RaceProxy:
        """Delegates to the real connection but forces the FIRST dedupe pre-check
        SELECT to return empty, so the function's INSERT hits the live PK row."""

        def __init__(self, real):
            self._real = real
            self._first_select = True

        def execute(self, sql, params=()):
            if (self._first_select
                    and sql.strip().startswith(
                        "SELECT body_sha256 FROM room_join_dedupe")):
                self._first_select = False
                return _Empty()
            return self._real.execute(sql, params)

        def commit(self):
            return self._real.commit()

        def rollback(self):
            return self._real.rollback()

    out3 = r.record_verified_cross_node_join_request_atomic(
        _RaceProxy(conn), message_id=mid2, body_sha256=body, peer="nodeB",
        room_id="room-x", agent="z", node="nodeB", via_node="nodeB")
    print(f"integrityerror_reclassified={out3}")
    conn.close()
    return 0


def cmd_drop_dedupe_table(db: str) -> int:
    """DROP room_join_dedupe to simulate an UPGRADED P1 rooms.db whose RW-open
    migration has not yet recreated the table (codex P4.1 r3 #2 tooth)."""
    conn = sqlite3.connect(db)
    try:
        conn.execute("DROP TABLE IF EXISTS room_join_dedupe")
        conn.commit()
    finally:
        conn.close()
    return 0


def cmd_set_token_ts(db: str, room_id: str, ts: str) -> int:
    conn = sqlite3.connect(db)
    try:
        conn.execute("UPDATE rooms SET invite_token_ts=? WHERE room_id=?",
                     (int(ts), room_id))
        conn.commit()
    finally:
        conn.close()
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: rooms-p4-1-cross-node-join-helper.py <subcommand> [args]",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "post-hook":
        return cmd_post_hook(rest[0])
    if cmd == "captured-field":
        return cmd_captured_field(rest[0], rest[1])
    if cmd == "deliver-to-receiver":
        return cmd_deliver_to_receiver(rest[0], rest[1], rest[2],
                                       rest[3] if len(rest) > 3 else "{}")
    if cmd == "make-config":
        return cmd_make_config(rest[0], rest[1], rest[2], rest[3], rest[4])
    if cmd == "pending-rows":
        return cmd_pending_rows(rest[0], rest[1])
    if cmd == "dedupe-rows":
        return cmd_dedupe_rows(rest[0])
    if cmd == "db-contains":
        return cmd_db_contains(rest[0], rest[1])
    if cmd == "file-tree-contains":
        return cmd_file_tree_contains(rest[0], rest[1])
    if cmd == "drop-dedupe-table":
        return cmd_drop_dedupe_table(rest[0])
    if cmd == "atomic-race-reclassify":
        return cmd_atomic_race_reclassify(rest[0])
    if cmd == "set-token-ts":
        return cmd_set_token_ts(rest[0], rest[1], rest[2])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
