#!/usr/bin/env python3
"""Helper for the rooms-p4-2-roster-broadcast smoke (A2A Rooms P4.2).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical leader (cross-approve gate + signed roster broadcast), the canonical
member-side receiver (`_handle_room_roster_broadcast` fail-closed auth preamble
+ the anti-rogue-leader / monotonic-epoch / atomic-cache contracts), and the
canonical schema — WITHOUT a live socket or Tailscale.

The transport is stubbed two ways (mirrors the P4.1 helper):
  - SENDER side (the leader's `room approve` broadcast): the cross-node POST is
    captured by the paired-flag test hook (BRIDGE_ROOMS_TEST_POST_HOOK = the
    rooms-p4-2-post-hook.sh wrapper -> this script's `post-hook`), which writes
    the fully-signed request to a file.
  - RECEIVER side: `deliver-roster-to-receiver` reconstructs a minimal fake HTTP
    request from that captured file and drives the REAL member-side handler, so
    the actual auth preamble (protocol/peer/remote_addr/HMAC/skew/dedupe) + the
    member-side acceptance logic + the cache write run end to end. The peer uses
    a literal `address` so resolve_peer_address returns it verbatim — no
    Tailscale.

Subcommands (argv[1]):
  post-hook <json>                 (BRIDGE_ROOMS_TEST_POST_HOOK target) — write
                                   the signed request JSON to $CAPTURE_FILE and
                                   echo a stub "{}" response.
  captured-field <file> <key>      print headers[X-AGB-*] or body.<key> (a list/
                                   dict value is JSON-encoded).
  deliver-roster-to-receiver <repo_root> <cfg_json> <captured_file> [overrides]
                                   replay the captured roster broadcast through
                                   the real member-side receiver handler; print
                                   "status=<n> body=<json>".
  make-config <out_path> <this_node> <peer_node> <peer_secret> <address>
                                   write a minimal handoff config the receiver
                                   loads (member node trusts the leader peer).
  make-member-db <db> <room_id> <leader_node> [member_agent] [member_node]
                                   seed a member-local rooms.db with an OUTBOUND
                                   join intent (the FIRST-ROSTER binding anchor)
                                   so a first roster for <room_id> is acceptable.
  cache-rows <db> [room_id]        print each room_roster_cache row as JSON.
  set-cache-epoch <db> <room_id> <epoch>  force the cached epoch (drive monotonic).
  cross-approve-gate <db>          unit-drive approve_cross_node: refuse w/o a
                                   verified pending row; admit with one.
  local-add-no-gate <db>           unit-drive approve_join (local path admits a
                                   local agent with NO verified-row requirement).
  member-accept-unit <db>          unit-drive accept_roster_broadcast contracts
                                   (not-leader / no-binding / first-bind / higher
                                   epoch / stale / duplicate / leader-pin).
  empty-leader-takeover-unit <db>  unit-drive the empty-from_node takeover refusal.
  dedupe-race-unit <db>            unit-drive the atomic dedupe/cache TOCTOU
                                   contract (same-id/diff-body → conflict, no
                                   cache write; same-id/same-body → duplicate).
  duplicate-burns-id-unit <db>     unit-drive the duplicate-branch id-burn (a
                                   same-state DUPLICATE still reserves the id, so
                                   a later same-id/diff-body reuse is a conflict).
  db-contains <db> <needle>        exit 0 iff <needle> appears in the db dump.
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
    """Write the captured signed request to $CAPTURE_FILE; stub a response body.

    The stub response models what a real leader/member receiver returns for the
    request's endpoint, so the SENDER-side CLI logic that keys off the ack body
    is exercised: a `room join` post (X-AGB-Protocol == room-join) gets a
    pending ack (so the CLI records its FIRST-ROSTER local binding); a roster
    broadcast post gets an applied ack. $POST_HOOK_ACK may override the body.
    """
    capture = os.environ.get("CAPTURE_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("CAPTURE_FILE unset", file=sys.stderr)
        return 1
    Path(capture).write_text(payload_json, encoding="utf-8")
    override = os.environ.get("POST_HOOK_ACK")  # noqa: iso-helper-boundary - env var, not a .env file
    if override is not None:
        print(override)
        return 0
    try:
        doc = json.loads(payload_json)
        proto = doc.get("headers", {}).get("X-AGB-Protocol", "")
    except (ValueError, json.JSONDecodeError):
        proto = ""
    if proto == a2a.ROOM_JOIN_PROTOCOL_VERSION:
        # Model the leader's pending ack so the member CLI records its binding.
        print(json.dumps({"ok": True, "status": rooms.JOIN_PENDING}))
    else:
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
    if isinstance(val, (list, dict)):
        print(json.dumps(val, separators=(",", ":")))
    else:
        print(val)
    return 0


# ---------------------------------------------------------------------------
# receiver-side replay against the REAL member-side handler
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


def cmd_deliver_roster_to_receiver(repo_root: str, cfg_json: str, captured: str,
                                   overrides_json: str = "{}") -> int:
    """Replay a captured signed roster broadcast through the REAL member-side
    receiver handler. `overrides_json` lets a tooth mutate the captured request:
      {"client_ip": "...", "headers": {...override...},
       "body": "<replacement json string>", "recompute_hash": true,
       "resign": true}
    `resign` recomputes BOTH the body hash AND a VALID HMAC for the (mutated)
    body using the peer's configured secret — to exercise a path DOWNSTREAM of
    the HMAC gate (e.g. the body parser, or a contract check) with a
    legitimately-signed body. `recompute_hash` recomputes only the body hash
    (used to drive the same-id-different-body 409 WITHOUT tripping the body-hash
    gate, while leaving the OLD signature -> still a 401 if not resigned).
    """
    hd = _load_handoffd(repo_root)
    cfg = json.loads(cfg_json)
    doc = json.loads(Path(captured).read_text(encoding="utf-8"))
    overrides = json.loads(overrides_json) if overrides_json else {}

    path = doc.get("path", a2a.ROOM_ROSTER_PATH)
    headers = dict(doc.get("headers", {}))
    body = doc.get("body", "{}")

    if "headers" in overrides:
        headers.update(overrides["headers"])
    if "body" in overrides:
        body = overrides["body"]
    body_bytes = body.encode("utf-8") if isinstance(body, str) else bytes(body)
    if overrides.get("recompute_hash"):
        headers["X-AGB-Body-SHA256"] = a2a.body_sha256(body_bytes)
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
    handler._handle_room_roster_broadcast(cfg)

    status = captured_reply.get("status", 0)
    payload = captured_reply.get("payload", {})
    print(f"status={status} body={json.dumps(payload)}")
    return 0


# ---------------------------------------------------------------------------
# config + db helpers
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


def cmd_make_member_db(db: str, room_id: str, leader_node: str,
                       member_agent: str = "bob",
                       member_node: str = "nodeB") -> int:
    """Seed a member-local rooms.db that holds an OUTBOUND join intent for
    <room_id> naming <leader_node> — the FIRST-ROSTER binding anchor. Mirrors
    what `room join` records via rooms.record_local_join_intent."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        rooms.record_local_join_intent(
            conn, room_id, member_agent, member_node, leader_node=leader_node)
    finally:
        conn.close()
    return 0


def cmd_cache_rows(db: str, room_id: str = "") -> int:
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    try:
        if room_id:
            rows = conn.execute(
                "SELECT room_id, epoch, members_json, from_node, mac, "
                "fetched_ts FROM room_roster_cache WHERE room_id=?",
                (room_id,)).fetchall()
        else:
            rows = conn.execute(
                "SELECT room_id, epoch, members_json, from_node, mac, "
                "fetched_ts FROM room_roster_cache").fetchall()
    finally:
        conn.close()
    for r in rows:
        print(json.dumps({k: r[k] for k in r.keys()}))
    return 0


def cmd_set_cache_epoch(db: str, room_id: str, epoch: str) -> int:
    conn = sqlite3.connect(db)
    try:
        conn.execute("UPDATE room_roster_cache SET epoch=? WHERE room_id=?",
                     (int(epoch), room_id))
        conn.commit()
    finally:
        conn.close()
    return 0


def cmd_db_contains(db: str, needle: str) -> int:
    conn = sqlite3.connect(db)
    try:
        dump = "\n".join(conn.iterdump())
    finally:
        conn.close()
    return 0 if needle and needle in dump else 1


# ---------------------------------------------------------------------------
# unit drivers — leader-side gate
# ---------------------------------------------------------------------------
def cmd_cross_approve_gate(db: str) -> int:
    """Prove approve_cross_node REQUIRES a verified pending row (contract 1)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        room_id = rooms.create_room(
            conn, name="t", leader_agent="alice", leader_node="nodeA",
            token="tok")
        # 1) No pending row at all -> refused.
        try:
            rooms.approve_cross_node(conn, room_id, "bob", "nodeB")
            print("no_row=ADMITTED")  # should not happen
        except rooms.RoomsError as exc:
            print(f"no_row=refused:{exc.code}")
        # 2) A row that is pending but NOT verified (a local P1 row) -> refused.
        rooms.post_join_request(conn, room_id, "carl", "nodeB")
        try:
            rooms.approve_cross_node(conn, room_id, "carl", "nodeB")
            print("unverified_row=ADMITTED")
        except rooms.RoomsError as exc:
            print(f"unverified_row=refused:{exc.code}")
        # 3) A verified pending row (what the P4.1 receiver creates) -> admitted.
        rooms.record_verified_cross_node_join_request(
            conn, room_id, "bob", "nodeB", via_node="nodeB")
        epoch = rooms.approve_cross_node(conn, room_id, "bob", "nodeB")
        admitted = rooms.is_member(conn, room_id, "bob", "nodeB")
        print(f"verified_row=admitted:epoch={epoch}:member={admitted}")
        # 4) The membership add did NOT also admit carl (the unverified one).
        print(f"carl_member={rooms.is_member(conn, room_id, 'carl', 'nodeB')}")
    finally:
        conn.close()
    return 0


def cmd_local_add_no_gate(db: str) -> int:
    """Prove approve_join (the LOCAL leader-add path) admits a LOCAL agent with
    NO verified-pending-row requirement — the two paths stay distinct
    (contract 1/6, the no-P4.1-regression tooth)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        room_id = rooms.create_room(
            conn, name="t", leader_agent="alice", leader_node="nodeA",
            token="tok")
        # A local agent (node == leader node) admitted via approve_join with NO
        # pending row at all — the local path does NOT claim the token gate.
        epoch = rooms.approve_join(conn, room_id, "dave", "nodeA")
        admitted = rooms.is_member(conn, room_id, "dave", "nodeA")
        print(f"local_add=admitted:epoch={epoch}:member={admitted}")
        # And approve_cross_node would have REFUSED the same (no verified row),
        # proving the two paths are genuinely distinct.
        try:
            rooms.approve_cross_node(conn, room_id, "erin", "nodeA")
            print("cross_path_for_local=ADMITTED")
        except rooms.RoomsError as exc:
            print(f"cross_path_for_local=refused:{exc.code}")
    finally:
        conn.close()
    return 0


# ---------------------------------------------------------------------------
# unit driver — member-side acceptance contracts
# ---------------------------------------------------------------------------
def _accept(conn, *, room_id, room_epoch, members, leader_node, peer_id, mid):
    """accept_roster_broadcast wrapper that supplies a per-call dedupe key.

    `mid` is a UNIQUE message id per logical delivery; the body_sha256 is derived
    from the actual canonical body bytes so a same-id replay of identical content
    is a real duplicate while different content under the same id is a conflict —
    exactly what the receiver sees on the wire."""
    body = a2a.build_room_roster_broadcast(
        room_id=room_id, room_epoch=room_epoch, members=members,
        leader_node=leader_node)
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    return rooms.accept_roster_broadcast(
        conn, room_id=room_id, room_epoch=room_epoch, members=members,
        leader_node=leader_node, peer_id=peer_id, message_id=mid,
        body_sha256=a2a.body_sha256(body_bytes))


def cmd_member_accept_unit(db: str) -> int:
    """Drive accept_roster_broadcast's full contract surface directly (a unit
    test of the security-critical acceptance logic). One line per case. Each
    logical delivery uses a UNIQUE message id so dedupe does not collide across
    cases (the dedupe-race case has its own dedicated driver)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        room_id = "room-unit"
        leader = "nodeA"
        members_v2 = [
            {"agent": "alice", "node": "nodeA", "role": "leader"},
            {"agent": "bob", "node": "nodeB", "role": "member"},
        ]

        # (3a) NOT-leader: an authenticated peer that is NOT the leader_node ->
        # rejected, persists nothing — EVEN with a local binding present.
        rooms.record_local_join_intent(
            conn, room_id, "bob", "nodeB", leader_node=leader)
        out = _accept(conn, room_id=room_id, room_epoch=2, members=members_v2,
                      leader_node=leader, peer_id="nodeZ", mid="nodeZ:u1")
        print(f"not_leader={out}")
        print(f"not_leader_no_cache={rooms.get_roster_cache(conn, room_id) is None}")

        # (3c) FIRST roster with NO local binding -> refused (rogue-leader mint
        # prevented). Use a DIFFERENT room with no local intent.
        out = _accept(conn, room_id="room-rogue", room_epoch=5,
                      members=members_v2, leader_node=leader, peer_id=leader,
                      mid="nodeA:u2")
        print(f"no_binding={out}")
        print("no_binding_no_cache="
              f"{rooms.get_roster_cache(conn, 'room-rogue') is None}")

        # (3c) FIRST roster WITH a local binding (recorded above) -> accepted.
        out = _accept(conn, room_id=room_id, room_epoch=2, members=members_v2,
                      leader_node=leader, peer_id=leader, mid="nodeA:u3")
        cache = rooms.get_roster_cache(conn, room_id)
        print(f"first_bind={out}:epoch={cache['epoch']}")

        # (3d) a STRICTLY-higher epoch updates.
        members_v3 = members_v2 + [
            {"agent": "carol", "node": "nodeC", "role": "member"}]
        out = _accept(conn, room_id=room_id, room_epoch=3, members=members_v3,
                      leader_node=leader, peer_id=leader, mid="nodeA:u4")
        cache = rooms.get_roster_cache(conn, room_id)
        has_carol = "carol" in cache["members_json"]
        print(f"higher_epoch={out}:epoch={cache['epoch']}:has_carol={has_carol}")

        # (3d) a LOWER epoch is IGNORED (stale) — the cache keeps epoch 3.
        out = _accept(conn, room_id=room_id, room_epoch=2, members=members_v2,
                      leader_node=leader, peer_id=leader, mid="nodeA:u5")
        cache = rooms.get_roster_cache(conn, room_id)
        still_carol = "carol" in cache["members_json"]
        print(f"lower_epoch={out}:epoch={cache['epoch']}:still_carol={still_carol}")

        # (3d) the SAME epoch with DIFFERENT members is IGNORED (a forge/replay),
        # NOT accepted — the cache is unchanged.
        out = _accept(conn, room_id=room_id, room_epoch=3, members=members_v2,
                      leader_node=leader, peer_id=leader, mid="nodeA:u6")
        cache = rooms.get_roster_cache(conn, room_id)
        same_still_carol = "carol" in cache["members_json"]
        print(f"same_epoch_diff={out}:still_carol={same_still_carol}")

        # (3d) a BYTE-IDENTICAL re-broadcast at the SAME epoch is an idempotent
        # duplicate (accepted-as-noop). Use the SAME message id + body as the
        # higher_epoch write (u4) so the dedupe ledger recognizes it as a replay.
        out = _accept(conn, room_id=room_id, room_epoch=3, members=members_v3,
                      leader_node=leader, peer_id=leader, mid="nodeA:u4")
        print(f"idempotent_dup={out}")

        # (3a' codex P4.2 r1 BLOCKING) LEADER-TAKEOVER of an EXISTING cache: a
        # DIFFERENT configured peer (nodeC) self-claims leadership (peer_id ==
        # leader_node == nodeC, so the literal 3a check passes) AND signs a
        # strictly-HIGHER epoch. Without leader-pinning this would overwrite the
        # cache. It MUST be refused (ROSTER_LEADER_MISMATCH) and leave the cache
        # pinned to the original leader nodeA at the original epoch.
        rogue_members = [
            {"agent": "mallory", "node": "nodeC", "role": "leader"}]
        out = _accept(conn, room_id=room_id, room_epoch=99,
                      members=rogue_members, leader_node="nodeC",
                      peer_id="nodeC", mid="nodeC:u7")
        cache = rooms.get_roster_cache(conn, room_id)
        print(f"takeover={out}:from_node={cache['from_node']}:"
              f"epoch={cache['epoch']}:"
              f"has_mallory={'mallory' in cache['members_json']}")
    finally:
        conn.close()
    return 0


def cmd_empty_leader_takeover_unit(db: str) -> int:
    """Prove a SINGLE-NODE/local room (cache from_node="") cannot be taken over
    by a remote peer self-claiming leadership (codex P4.2 r2 BLOCKING). One line
    of output: outcome + the (unchanged) cached from_node + epoch."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        # A local room: leader_node="" → cache seeded with from_node="" at epoch 0.
        room_id = rooms.create_room(
            conn, name="local", leader_agent="alice", leader_node="", token="t")
        before = rooms.get_roster_cache(conn, room_id)
        # A remote peer nodeC (non-empty authenticated peer_id) self-claims
        # leadership at a higher epoch. Must be refused (leader_mismatch).
        out = _accept(
            conn, room_id=room_id, room_epoch=99,
            members=[{"agent": "mallory", "node": "nodeC", "role": "leader"}],
            leader_node="nodeC", peer_id="nodeC", mid="nodeC:empty1")
        after = rooms.get_roster_cache(conn, room_id)
        unchanged = (str(before["from_node"]) == str(after["from_node"])
                     and int(before["epoch"]) == int(after["epoch"]))
        print(f"empty_takeover={out}:from_node='{after['from_node']}':"
              f"epoch={after['epoch']}:unchanged={unchanged}:"
              f"has_mallory={'mallory' in after['members_json']}")
    finally:
        conn.close()
    return 0


def cmd_dedupe_race_unit(db: str) -> int:
    """Drive the atomic dedupe/cache TOCTOU contract directly (codex P4.2 r3
    BLOCKING). Two deliveries reuse the SAME (peer, message_id) with DIFFERENT
    bodies; the SECOND must be a CONFLICT with NO cache mutation (the cache still
    holds the FIRST body). Then a byte-identical replay of the FIRST is a
    DUPLICATE (no double-apply). One line per case.

    The two bodies differ only in members (mallory vs trent), so a successful
    takeover would be observable as the cache flipping to the second body. The
    SAME message_id forces the second through the dedupe-conflict branch BEFORE
    the cache write — proving the write does not precede the conflict detection.
    """
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        room_id = "room-race"
        leader = "nodeM"  # the (single) leader peer for this room
        # The member chose this room+leader locally (first-roster binding).
        rooms.record_local_join_intent(
            conn, room_id, "self", "nodeSelf", leader_node=leader)
        members_a = [{"agent": "mallory", "node": "nodeM", "role": "leader"}]
        members_b = [{"agent": "trent", "node": "nodeM", "role": "leader"}]
        mid = "nodeM:race-X"

        # Delivery 1: (peer=nodeM, id=race-X, bodyA) → first-bind ACCEPTED.
        out1 = _accept(conn, room_id=room_id, room_epoch=1, members=members_a,
                       leader_node=leader, peer_id=leader, mid=mid)
        print(f"first_accept={out1}")
        # Delivery 2: SAME (peer, id) but DIFFERENT body (bodyB) at a HIGHER
        # epoch — would otherwise pass leader-pin + monotonic-epoch and WRITE.
        # The atomic dedupe reservation must catch it as a CONFLICT FIRST, with
        # NO cache mutation.
        out2 = _accept(conn, room_id=room_id, room_epoch=2, members=members_b,
                       leader_node=leader, peer_id=leader, mid=mid)
        cache = rooms.get_roster_cache(conn, room_id)
        print(f"reuse_diff_body={out2}:epoch={cache['epoch']}:"
              f"has_mallory={'mallory' in cache['members_json']}:"
              f"has_trent={'trent' in cache['members_json']}")
        # Delivery 3: a byte-identical replay of delivery 1 → idempotent DUPLICATE
        # (no double-apply), cache unchanged.
        out3 = _accept(conn, room_id=room_id, room_epoch=1, members=members_a,
                       leader_node=leader, peer_id=leader, mid=mid)
        print(f"replay_same_body={out3}")
    finally:
        conn.close()
    return 0


def cmd_duplicate_burns_id_unit(db: str) -> int:
    """Drive the DUPLICATE-branch id-burn contract (codex P4.2 r3 deeper edge).

    The byte-identical-existing-cache ROSTER_DUPLICATE branch MUST still reserve
    the (peer, message_id) in the dedupe ledger, so a LATER same-id/DIFFERENT-body
    reuse is a CONFLICT (not a fresh accept). Sequence (one line per case):
      1. accept (peer, idX, bodyA, epoch 1) → ACCEPTED (first-bind).
      2. deliver a byte-identical roster under a NEW id idY (same bytes/epoch) →
         the cache already matches → DUPLICATE branch → MUST burn idY.
      3. assert a dedupe row for idY now EXISTS (the id was burned).
      4. deliver (peer, SAME idY, DIFFERENT body bodyB naming rogue 'trent',
         HIGHER epoch, would otherwise pass leader-pin + monotonic-epoch) →
         MUST be ROSTER_DEDUPE_CONFLICT, cache epoch unchanged, no 'trent'.
    """
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        room_id = "room-dupburn"
        leader = "nodeM"
        rooms.record_local_join_intent(
            conn, room_id, "self", "nodeSelf", leader_node=leader)
        members_a = [{"agent": "mallory", "node": "nodeM", "role": "leader"}]
        members_b = [{"agent": "trent", "node": "nodeM", "role": "leader"}]
        id_x = "nodeM:burn-X"
        id_y = "nodeM:burn-Y"

        out1 = _accept(conn, room_id=room_id, room_epoch=1, members=members_a,
                       leader_node=leader, peer_id=leader, mid=id_x)
        print(f"first_accept={out1}")
        # Byte-identical roster under a DIFFERENT id → reaches the DUPLICATE
        # branch (cache already matches) → must BURN id_y.
        out2 = _accept(conn, room_id=room_id, room_epoch=1, members=members_a,
                       leader_node=leader, peer_id=leader, mid=id_y)
        burned = conn.execute(
            "SELECT 1 FROM room_join_dedupe WHERE peer=? AND message_id=?",
            (leader, id_y)).fetchone() is not None
        print(f"same_state_reuse_id={out2}:dedupe_after_same_state={burned}")
        # Later: SAME id_y, DIFFERENT body, HIGHER epoch → must be CONFLICT.
        out3 = _accept(conn, room_id=room_id, room_epoch=2, members=members_b,
                       leader_node=leader, peer_id=leader, mid=id_y)
        cache = rooms.get_roster_cache(conn, room_id)
        print(f"later_same_id_diff_body={out3}:cache_epoch={cache['epoch']}:"
              f"has_trent={'trent' in cache['members_json']}")
    finally:
        conn.close()
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: rooms-p4-2-roster-broadcast-helper.py <subcommand> [args]",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "post-hook":
        return cmd_post_hook(rest[0])
    if cmd == "captured-field":
        return cmd_captured_field(rest[0], rest[1])
    if cmd == "deliver-roster-to-receiver":
        return cmd_deliver_roster_to_receiver(
            rest[0], rest[1], rest[2], rest[3] if len(rest) > 3 else "{}")
    if cmd == "make-config":
        return cmd_make_config(rest[0], rest[1], rest[2], rest[3], rest[4])
    if cmd == "make-member-db":
        return cmd_make_member_db(
            rest[0], rest[1], rest[2],
            rest[3] if len(rest) > 3 else "bob",
            rest[4] if len(rest) > 4 else "nodeB")
    if cmd == "cache-rows":
        return cmd_cache_rows(rest[0], rest[1] if len(rest) > 1 else "")
    if cmd == "set-cache-epoch":
        return cmd_set_cache_epoch(rest[0], rest[1], rest[2])
    if cmd == "cross-approve-gate":
        return cmd_cross_approve_gate(rest[0])
    if cmd == "local-add-no-gate":
        return cmd_local_add_no_gate(rest[0])
    if cmd == "member-accept-unit":
        return cmd_member_accept_unit(rest[0])
    if cmd == "empty-leader-takeover-unit":
        return cmd_empty_leader_takeover_unit(rest[0])
    if cmd == "dedupe-race-unit":
        return cmd_dedupe_race_unit(rest[0])
    if cmd == "duplicate-burns-id-unit":
        return cmd_duplicate_burns_id_unit(rest[0])
    if cmd == "db-contains":
        return cmd_db_contains(rest[0], rest[1])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
