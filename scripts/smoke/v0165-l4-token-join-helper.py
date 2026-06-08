#!/usr/bin/env python3
"""Helper for the v0165-l4-token-join smoke (A2A Rooms Lane 4, #1695).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical token-bootstrap admission path end to end WITHOUT a live socket or
Tailscale:

  - SENDER side: the cross-node `bridge-rooms.py join` POST is captured by the
    paired-flag test hook (post-hook subcommand), which writes the fully-signed
    request to a file. The joiner self-bootstraps a LOCAL leader peer from the
    token-signed reach= locator, so the signature uses the DERIVED per-pair key.
  - RECEIVER side: `deliver-to-receiver` reconstructs a minimal fake HTTP
    request and drives the REAL `_handle_room_join_request` against a LEADER cfg
    that has NO peer for the joiner yet. With BRIDGE_A2A_ROOM_AUTOJOIN=1 the
    receiver derives the SAME per-pair key from the stored seed, auto-registers
    the reverse peer under a TOCTOU lock, then runs the UNCHANGED preamble.

Subcommands (argv[1]):
  post-hook <json>                  (BRIDGE_ROOMS_TEST_POST_HOOK) — write the
                                    signed request to $CAPTURE_FILE.
  captured-field <file> <key>       print headers[X-AGB-*] / body.<key> / path.
  deliver-to-receiver <repo_root> <cfg_path> <captured_file> [overrides_json]
                                    replay through the real receiver; reads the
                                    leader cfg FROM A FILE PATH (so the receiver's
                                    auto-register disk write targets it); prints
                                    "status=<n> body=<json>".
  make-leader-config <out> <node> <addr>
                                    write a leader cfg with an EMPTY peers list.
  make-joiner-config <out> <node> <addr>
                                    write a joiner cfg with an EMPTY peers list.
  pending-rows <db> <room_id>       print each pending join row as JSON lines.
  peer-ids <cfg>                    print each peers[].id (one per line).
  peer-field <cfg> <peer_id> <key>  print one peers[] field (address/secret/...).
  config-text <cfg>                 print the raw config text (secret-scan).
  db-contains <db> <needle>         exit 0 iff <needle> in the db dump.
  file-tree-contains <dir> <needle> exit 0 iff <needle> under <dir>.
  set-token-ts <db> <room_id> <ts>  backdate invite_token_ts (drive TTL expiry).
  clear-key-seed <db> <room_id>     NULL the invite_key_seed (pre-bootstrap room).
  derive-pair-key <token> <room> <leader_node> <joiner_node>
                                    print the joiner-side derived per-pair key.
  token-hash-key <token> <room> <leader_node> <joiner_node>
                                    print a key WRONGLY derived from sha256(token)
                                    (the domain-separation negative control).
  concurrent-register <cfg> <n> <peer_id> <addr> <secret>
                                    fire N concurrent auto_register_room_peer_locked
                                    for the SAME peer; print the final peer count.
"""

from __future__ import annotations

import hashlib
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
# sender-side capture hook
# ---------------------------------------------------------------------------
def cmd_post_hook(payload_json: str) -> int:
    capture = os.environ.get("CAPTURE_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("CAPTURE_FILE unset", file=sys.stderr)
        return 1
    # Enrich the captured request with the socket source IP the receiver should
    # see (the joiner's CLIENT_IP), so `deliver-to-receiver` replays with the
    # correct remote_addr — the smoke proves the source check uses THIS socket
    # value, never a body-asserted address.
    doc = json.loads(payload_json)
    client_ip = os.environ.get("CLIENT_IP")  # noqa: iso-helper-boundary - env var, not a .env file
    if client_ip:
        doc["client_ip"] = client_ip
    Path(capture).write_text(json.dumps(doc), encoding="utf-8")
    print("{}")
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
    def __init__(self, cfg: dict, config_path):
        self.cfg = cfg
        # The auto-register disk write targets this path (a real leader cfg
        # file), so the TOCTOU-locked write + reload exercise the file path.
        self.config_path = Path(config_path) if config_path else None


def _drive_once(hd, cfg: dict, cfg_path: str, captured: str,
                overrides: dict) -> tuple[int, dict]:
    """Build + drive ONE request through the real handler against `cfg`. Returns
    (status, payload). `cfg` is mutated in place by the handler exactly as the
    live server's long-lived cfg would be (this is what the shared-cfg-poison
    test relies on)."""
    doc = json.loads(Path(captured).read_text(encoding="utf-8"))
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
    headers["Content-Length"] = str(len(body_bytes))
    client_ip = overrides.get("client_ip", doc.get("client_ip", "127.0.0.1"))

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path
    handler.headers = _FakeHeaders(headers)
    handler.rfile = _FakeRFile(body_bytes)
    handler.client_address = (client_ip, 0)
    handler.server = _FakeServer(cfg, cfg_path)

    captured_reply: dict = {}

    def _capture_reply(status, payload, extra_headers=None):
        captured_reply["status"] = status
        captured_reply["payload"] = payload

    handler._reply = _capture_reply  # type: ignore[assignment]
    handler._handle_room_join_request(cfg)
    return captured_reply.get("status", 0), captured_reply.get("payload", {})


def cmd_deliver_to_receiver(repo_root: str, cfg_path: str, captured: str,
                            overrides_json: str = "{}") -> int:
    hd = _load_handoffd(repo_root)
    # Load the leader cfg FROM DISK so the receiver's auto-register write+reload
    # round-trips against the same file the handler is told about.
    cfg = a2a.load_config(Path(cfg_path))
    overrides = json.loads(overrides_json) if overrides_json else {}
    status, payload = _drive_once(hd, cfg, cfg_path, captured, overrides)
    print(f"status={status} body={json.dumps(payload)}")
    return 0


def cmd_deliver_two_shared_cfg(repo_root: str, cfg_path: str, captured1: str,
                               overrides1_json: str, captured2: str,
                               overrides2_json: str) -> int:
    """codex r2 P1 regression: drive TWO requests through the SAME long-lived cfg
    object (loaded once), to prove a bad-signature bootstrap does NOT poison the
    SHARED in-memory cfg. Request 1 is the attack (e.g. a bad-signature forgery);
    request 2 is a LATER legitimate join for the same peer. Prints both statuses
    + the peer count remaining in the shared cfg after request 1."""
    hd = _load_handoffd(repo_root)
    cfg = a2a.load_config(Path(cfg_path))
    ov1 = json.loads(overrides1_json) if overrides1_json else {}
    ov2 = json.loads(overrides2_json) if overrides2_json else {}
    s1, _ = _drive_once(hd, cfg, cfg_path, captured1, ov1)
    # The shared cfg's peer count immediately AFTER the (rejected) request 1 — a
    # poison would have left a peer here even though request 1 was a 401.
    peers_after_1 = [p for p in cfg.get("peers", [])
                     if isinstance(p, dict)]
    s2, _ = _drive_once(hd, cfg, cfg_path, captured2, ov2)
    print(f"req1_status={s1}")
    print(f"shared_cfg_peers_after_req1={len(peers_after_1)}")
    print(f"req2_status={s2}")
    return 0


# ---------------------------------------------------------------------------
# config builders + inspection
# ---------------------------------------------------------------------------
def _write_cfg(out_path: str, this_node: str, address: str) -> int:
    cfg = {
        "bridge_id": this_node,
        "listen": {"host": "127.0.0.1", "address": address, "port": 8787,
                   "enqueue_path": "/enqueue"},
        "timestamp_skew_seconds": 300,
        "timestamp_skew_grace_seconds": 3600,
        "peers": [],
    }
    Path(out_path).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    return 0


def cmd_make_leader_config(out_path: str, node: str, address: str) -> int:
    return _write_cfg(out_path, node, address)


def cmd_make_joiner_config(out_path: str, node: str, address: str) -> int:
    return _write_cfg(out_path, node, address)


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


def cmd_peer_ids(cfg_path: str) -> int:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
    for p in cfg.get("peers", []):
        if isinstance(p, dict):
            print(p.get("id", ""))
    return 0


def cmd_peer_field(cfg_path: str, peer_id: str, key: str) -> int:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
    for p in cfg.get("peers", []):
        if isinstance(p, dict) and p.get("id") == peer_id:
            print(p.get(key, ""))
            return 0
    print("", end="")
    return 0


def cmd_config_text(cfg_path: str) -> int:
    print(Path(cfg_path).read_text(encoding="utf-8"))
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


def cmd_set_token_ts(db: str, room_id: str, ts: str) -> int:
    conn = sqlite3.connect(db)
    try:
        conn.execute("UPDATE rooms SET invite_token_ts=? WHERE room_id=?",
                     (int(ts), room_id))
        conn.commit()
    finally:
        conn.close()
    return 0


def cmd_clear_key_seed(db: str, room_id: str) -> int:
    conn = sqlite3.connect(db)
    try:
        conn.execute("UPDATE rooms SET invite_key_seed=NULL WHERE room_id=?",
                     (room_id,))
        conn.commit()
    finally:
        conn.close()
    return 0


def cmd_derive_pair_key(token: str, room: str, leader_node: str,
                        joiner_node: str) -> int:
    print(a2a.room_pair_key_from_token(
        token, room_id=room, leader_node=leader_node, joiner_node=joiner_node))
    return 0


def cmd_token_hash_key(token: str, room: str, leader_node: str,
                       joiner_node: str) -> int:
    """The NEGATIVE control: derive a key from the WIRE-VISIBLE sha256(token)
    instead of the raw token. Domain separation guarantees this != the real
    pair key, so a peer signing with it will FAIL the receiver's HMAC."""
    th = hashlib.sha256(token.encode("utf-8")).hexdigest()
    seed = a2a.hkdf_extract(b"a2a-room-pair-seed-v1", bytes.fromhex(th))
    info = b"\n".join([b"a2a-room-pair-key-v1", room.encode(),
                       leader_node.encode(), joiner_node.encode()])
    print(a2a.hkdf_expand(seed, info, 32).hex())
    return 0


def _concurrent_register_worker(cfg_path: str, peer_id: str, addr: str,
                                secret: str) -> None:
    """Module-level worker (picklable under the spawn start method on macOS) that
    contends on the TOCTOU lock from a separate OS process."""
    import bridge_a2a_common as _a2a
    _a2a.auto_register_room_peer_locked(
        Path(cfg_path), peer_id=peer_id, address=addr, port=8787,
        secret=secret, inbound_allowlist=["lead"], transport="")


def cmd_concurrent_register(cfg_path: str, n: str, peer_id: str, addr: str,
                            secret: str) -> int:
    """Fire N concurrent auto_register_room_peer_locked for the SAME peer from
    separate OS processes; assert exactly ONE peer row + no corruption (the
    TOCTOU file lock serializes the disk writes). Uses a real multi-process
    contention (not threads) so the advisory FILE lock is the only serializer."""
    import multiprocessing as mp

    procs = [
        mp.Process(target=_concurrent_register_worker,
                   args=(cfg_path, peer_id, addr, secret))
        for _ in range(int(n))
    ]
    for p in procs:
        p.start()
    for p in procs:
        p.join()
    # Re-read the on-disk config: it must be valid JSON with exactly one entry
    # for peer_id (no duplicate / no corruption).
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
    matches = [p for p in cfg.get("peers", [])
               if isinstance(p, dict) and p.get("id") == peer_id]
    print(f"peer_count={len(matches)}")
    if matches:
        print(f"secret_intact={matches[0].get('secret') == secret}")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: v0165-l4-token-join-helper.py <subcommand> [args]",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    table = {
        "post-hook": lambda: cmd_post_hook(rest[0]),
        "captured-field": lambda: cmd_captured_field(rest[0], rest[1]),
        "deliver-to-receiver": lambda: cmd_deliver_to_receiver(
            rest[0], rest[1], rest[2], rest[3] if len(rest) > 3 else "{}"),
        "deliver-two-shared-cfg": lambda: cmd_deliver_two_shared_cfg(
            rest[0], rest[1], rest[2], rest[3], rest[4], rest[5]),
        "make-leader-config": lambda: cmd_make_leader_config(
            rest[0], rest[1], rest[2]),
        "make-joiner-config": lambda: cmd_make_joiner_config(
            rest[0], rest[1], rest[2]),
        "pending-rows": lambda: cmd_pending_rows(rest[0], rest[1]),
        "peer-ids": lambda: cmd_peer_ids(rest[0]),
        "peer-field": lambda: cmd_peer_field(rest[0], rest[1], rest[2]),
        "config-text": lambda: cmd_config_text(rest[0]),
        "db-contains": lambda: cmd_db_contains(rest[0], rest[1]),
        "file-tree-contains": lambda: cmd_file_tree_contains(rest[0], rest[1]),
        "set-token-ts": lambda: cmd_set_token_ts(rest[0], rest[1], rest[2]),
        "clear-key-seed": lambda: cmd_clear_key_seed(rest[0], rest[1]),
        "derive-pair-key": lambda: cmd_derive_pair_key(
            rest[0], rest[1], rest[2], rest[3]),
        "token-hash-key": lambda: cmd_token_hash_key(
            rest[0], rest[1], rest[2], rest[3]),
        "concurrent-register": lambda: cmd_concurrent_register(
            rest[0], rest[1], rest[2], rest[3], rest[4]),
    }
    fn = table.get(cmd)
    if fn is None:
        print(f"unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    return fn()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
