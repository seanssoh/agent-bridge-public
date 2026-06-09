#!/usr/bin/env python3
"""Helper for the v0165-l5-relay-roster smoke (#1695-P2: leader-relay + roster
anti-entropy). SECURITY — drives the REAL receiver (`do_POST`) + the durable
roster outbox + the reconcile heartbeat.

File-as-argv sidecar (NEVER heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical relay decision (`maybe_relay_room_message` / `_relay_resolve` /
`_relay_forward_send`), the canonical durable outbox + shared membership-change
broadcast, and the canonical `roster_epoch_reconcile` adapter — WITHOUT a live
socket / Tailscale.

Transport is stubbed exactly like the P4.2/P4.3 helpers:
  - The leader's RELAY forward POST is captured by the paired-flag relay hook
    (BRIDGE_ROOMS_TEST_RELAY_HOOK → this script's `relay-hook`), which writes the
    re-signed leader->target leg to $CAPTURE_FILE.
  - The leader's ROSTER broadcast POST (membership-change / heartbeat) is captured
    by the paired-flag roster hook (BRIDGE_ROOMS_TEST_POST_HOOK → `roster-hook`).
  - `deliver-to-receiver` reconstructs a minimal fake HTTP request and drives the
    REAL `do_POST`, so the full auth preamble + relay decision run end to end.

Subcommands (argv[1]):
  relay-hook <json>             (BRIDGE_ROOMS_TEST_RELAY_HOOK target) — write the
                                re-signed relay leg to $CAPTURE_FILE; echo a 200.
  roster-hook <json>            (BRIDGE_ROOMS_TEST_POST_HOOK target) — write the
                                roster broadcast to $CAPTURE_FILE; echo a 200.
  captured-field <file> <key>   print headers[X-AGB-*] | body.<key> | path.
  make-config <out> <this_node> <peers_csv> <secret> <addr> [allowlist_csv]
                                write a handoff config. peers_csv = node[,node...]
                                (every peer shares <secret>/<addr>). allowlist_csv
                                = agents this node delivers to locally.
  make-leader-db <db> <room_id> <leader_agent> <leader_node> <members_csv>
                                seed a leader rooms.db: a room + members
                                (members_csv = agent@node[:role],...).
  deliver-to-receiver <repo> <cfg_json> <captured> [overrides]
                                replay a captured /enqueue (or relay leg) through
                                the REAL do_POST; print status/delivered/relayed.
  relay-resolve-unit <db> <cfg_json>   unit-drive _relay_resolve across the relay
                                authorization teeth (leader/sender/target/loop).
  outbox-unit <db>              unit-drive the durable roster outbox + the shared
                                membership-change broadcast (enqueue/done/epoch).
  reconcile-unit <repo> <db> <cfg_json>  unit-drive roster_epoch_reconcile (no
                                rooms => noop; pending => rebroadcast/heartbeat).
  secret-scan <file>            FAIL if a captured payload leaks a secret/token.
"""

from __future__ import annotations

import importlib.util
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
# capture hooks (invoked as BRIDGE_ROOMS_TEST_RELAY_HOOK / _POST_HOOK)
# ---------------------------------------------------------------------------
def _write_capture(payload_json: str) -> int:
    capture = os.environ.get("CAPTURE_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("CAPTURE_FILE unset", file=sys.stderr)
        return 1
    Path(capture).write_text(payload_json, encoding="utf-8")
    print(json.dumps({"ok": True}))
    return 0


def cmd_relay_hook(payload_json: str) -> int:
    return _write_capture(payload_json)


def cmd_roster_hook(payload_json: str) -> int:
    return _write_capture(payload_json)


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
# config + leader rooms.db seeding
# ---------------------------------------------------------------------------
def cmd_make_config(out_path: str, this_node: str, peers_csv: str,
                    secret: str, address: str, allowlist_csv: str = "") -> int:
    allowlist = [a for a in allowlist_csv.split(",") if a] if allowlist_csv else []
    peers = []
    for node in (p for p in peers_csv.split(",") if p):
        peers.append({
            "id": node,
            "address": address,
            "secret": secret,
            "inbound_allowlist": allowlist,
        })
    cfg = {
        "bridge_id": this_node,
        "listen": {"host": "127.0.0.1", "port": 8787, "enqueue_path": "/enqueue"},
        "timestamp_skew_seconds": 300,
        "timestamp_skew_grace_seconds": 3600,
        "peers": peers,
    }
    Path(out_path).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    print(f"config {this_node} peers={[p['id'] for p in peers]}")
    return 0


def _parse_members_csv(members_csv: str) -> list:
    members: list = []
    for entry in members_csv.split(","):
        entry = entry.strip()
        if not entry:
            continue
        role = "member"
        if ":" in entry:
            entry, role = entry.rsplit(":", 1)
        agent, _, node = entry.partition("@")
        members.append({"agent": agent.strip(), "node": node.strip(),
                        "role": role.strip() or "member"})
    return members


def cmd_make_leader_db(db: str, room_id: str, leader_agent: str,
                       leader_node: str, members_csv: str) -> int:
    """Seed a LEADER rooms.db: a room (this node leads) + its members.

    The members_csv entries become authoritative room_members rows so the relay
    decision + the durable broadcast read membership from rooms.db (not a body).
    """
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        ts = rooms.now_ts()
        conn.execute(
            "INSERT OR REPLACE INTO rooms (room_id, name, leader_agent, "
            "leader_node, epoch, invite_token_sha256, invite_token_ts, "
            "invite_once, status, created_ts, updated_ts) "
            "VALUES (?, 'team', ?, ?, 1, '', 0, 0, 'active', ?, ?)",
            (room_id, leader_agent, leader_node, ts, ts),
        )
        for m in _parse_members_csv(members_csv):
            conn.execute(
                "INSERT OR REPLACE INTO room_members (room_id, agent, node, "
                "role, joined_ts) VALUES (?, ?, ?, ?, ?)",
                (room_id, m["agent"], m["node"], m["role"], ts),
            )
        # Refresh the leader's own roster cache so room_scoped_check works on it.
        rooms._recompute_roster_cache(conn, room_id, commit=False)
        conn.commit()
    finally:
        conn.close()
    print(f"leader-db room={room_id} leader={leader_agent}@{leader_node}")
    return 0


# ---------------------------------------------------------------------------
# build a member->leader room-scoped /enqueue (the inbound the leader relays)
# ---------------------------------------------------------------------------
def cmd_build_nonroom_forged_relay(out_path: str, sender_bridge: str,
                                   sender_agent: str, target_agent: str,
                                   forged_agent: str, forged_node: str) -> int:
    """Write a NON-room /enqueue with a FORGED relayed_via + relayed_from.

    Used to prove the provenance-spoof defense: a non-room envelope can never be
    a legitimate relay leg, so the receiver MUST ignore relayed_from and keep the
    REAL authenticated-peer provenance (no rewrite to the forged author).
    """
    # NO room_id (non-room), but a forged relayed_via + relayed_from claiming a
    # different author. build_envelope only emits relay markers when room-scoped,
    # so we inject them MANUALLY to simulate a hostile hand-crafted envelope.
    env = a2a.build_envelope(
        message_id=a2a.new_message_id(sender_bridge),
        sender_bridge=sender_bridge, sender_agent=sender_agent,
        target_agent=target_agent, priority="normal",
        title="forged", body="b")
    env["relayed_via"] = "some-leader-node"
    env["relayed_from"] = {"agent": forged_agent, "node": forged_node}
    doc = {
        "path": "/enqueue",
        "headers": {
            "X-AGB-Protocol": a2a.PROTOCOL_VERSION,
            "X-AGB-Peer": sender_bridge,
            "X-AGB-Message-Id": env["message_id"],
            "X-AGB-Timestamp": str(a2a.now_ts()),
        },
        "body": json.dumps(env, ensure_ascii=False),
    }
    Path(out_path).write_text(json.dumps(doc), encoding="utf-8")
    print(f"nonroom-forged from={sender_agent}@{sender_bridge} "
          f"forged={forged_agent}@{forged_node}")
    return 0


def cmd_build_member_enqueue(out_path: str, sender_bridge: str,
                             sender_agent: str, target_agent: str,
                             room_id: str, room_epoch: str,
                             relayed_via: str = "") -> int:
    """Write a captured-shape /enqueue doc for a member->leader room message.

    The smoke replays this through the leader's do_POST. The signature is added
    at replay time (the deliver-to-receiver `resign` path) so a single helper can
    drive both the authentic and the tampered cases.
    """
    env = a2a.build_envelope(
        message_id=a2a.new_message_id(sender_bridge),
        sender_bridge=sender_bridge, sender_agent=sender_agent,
        target_agent=target_agent, priority="normal",
        title="hello from a member", body="relay me to the other member",
        room_id=room_id, room_epoch=int(room_epoch),
        relayed_via=relayed_via,
    )
    doc = {
        "path": "/enqueue",
        "headers": {
            "X-AGB-Protocol": a2a.PROTOCOL_VERSION,
            "X-AGB-Peer": sender_bridge,
            "X-AGB-Message-Id": env["message_id"],
            "X-AGB-Timestamp": str(a2a.now_ts()),
        },
        "body": json.dumps(env, ensure_ascii=False),
    }
    Path(out_path).write_text(json.dumps(doc), encoding="utf-8")
    print(f"member-enqueue from={sender_agent}@{sender_bridge} target={target_agent}")
    return 0


# ---------------------------------------------------------------------------
# receiver-side replay against the REAL do_POST handler
# ---------------------------------------------------------------------------
def _load_handoffd(repo_root: str):
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
    """Replay a captured /enqueue (member->leader OR relay leg) through do_POST.

    `overrides_json` mutates the captured request:
      {"client_ip": "...", "headers": {...}, "body": "<json>",
       "recompute_hash": true, "resign": true}
    `resign` recomputes a VALID HMAC for the (mutated) body with the X-AGB-Peer's
    configured secret — to reach a path DOWNSTREAM of the HMAC gate.
    """
    hd = _load_handoffd(repo_root)
    cfg = json.loads(cfg_json)
    doc = json.loads(Path(captured).read_text(encoding="utf-8"))
    overrides = json.loads(overrides_json) if overrides_json else {}

    path = doc.get("path", "/enqueue")
    headers = dict(doc.get("headers", {}))
    body = doc.get("body", "{}")
    if "headers" in overrides:
        headers.update(overrides["headers"])
    if "body" in overrides:
        body = overrides["body"]
    body_bytes = body.encode("utf-8") if isinstance(body, str) else bytes(body)
    if "X-AGB-Timestamp" not in headers:
        headers["X-AGB-Timestamp"] = str(a2a.now_ts())
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

    # Capture a LOCAL delivery (the target member's node enqueues a real task).
    delivery: dict = {}

    def _fake_enqueue(*, target, sender_bridge, sender_agent, priority, title,
                      body_file):
        # ALSO capture the rendered body file (the staged provenance block) so a
        # tooth can assert the body provenance agrees with the queue attribution
        # (codex Phase-4 #1695-P2 body-provenance fix).
        body_text = ""
        try:
            body_text = Path(str(body_file)).read_text(encoding="utf-8")
        except (OSError, TypeError, ValueError):
            body_text = ""
        delivery.update({"target": target, "sender_bridge": sender_bridge,
                         "sender_agent": sender_agent, "priority": priority,
                         "title": title, "body_text": body_text})
        return True, "9999", "created task #9999", "created task #9999"

    hd.enqueue_via_bridge_task = _fake_enqueue  # type: ignore[assignment]

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path
    handler.headers = _FakeHeaders(headers)
    handler.rfile = _FakeRFile(body_bytes)
    handler.client_address = (client_ip, 0)
    handler.server = _FakeServer(cfg)

    reply: dict = {}

    def _capture_reply(status, payload, extra_headers=None):
        reply["status"] = status
        reply["payload"] = payload

    handler._reply = _capture_reply  # type: ignore[assignment]
    handler.do_POST()

    status = reply.get("status", 0)
    payload = reply.get("payload", {})
    relayed = bool(isinstance(payload, dict) and payload.get("relayed"))
    delivered = bool(delivery)
    # If DELIVERED_BODY_FILE is set, dump the rendered task body there so a tooth
    # can grep the multi-line provenance block cleanly.
    dump = os.environ.get("DELIVERED_BODY_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if dump:
        Path(dump).write_text(delivery.get("body_text", ""), encoding="utf-8")
    print(f"status={status} delivered={delivered} relayed={relayed} "
          f"body={json.dumps(payload)} delivery={json.dumps(delivery)}")
    return 0


# ---------------------------------------------------------------------------
# unit: _relay_resolve authorization teeth (no network)
# ---------------------------------------------------------------------------
def cmd_relay_resolve_unit(db: str, cfg_json: str) -> int:
    """Drive _relay_resolve across the relay authorization decision surface."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    hd = _load_handoffd(str(REPO_ROOT))
    cfg = json.loads(cfg_json)
    this_node = cfg["bridge_id"]

    def env_for(sender_agent, target_agent, room_id="room-x", epoch=1,
                relayed=False):
        return a2a.build_envelope(
            message_id="nodeM:1", sender_bridge="nodeM",
            sender_agent=sender_agent, target_agent=target_agent,
            priority="normal", title="t", body="b",
            room_id=room_id, room_epoch=epoch,
            relayed_via=(this_node if relayed else ""))

    out = []
    # valid relay: nodeM member 'alice' -> remote member 'carol'@nodeC
    tn, reason = hd._relay_resolve(env_for("alice", "carol"), cfg, "nodeM")
    out.append(f"valid={reason}:target={tn}")
    # non-member sender -> refused
    _tn, reason = hd._relay_resolve(env_for("mallory", "carol"), cfg, "nodeM")
    out.append(f"nonmember_sender={reason}")
    # target not a member -> refused
    _tn, reason = hd._relay_resolve(env_for("alice", "ghost"), cfg, "nodeM")
    out.append(f"nonmember_target={reason}")
    # already-relayed marker -> loop blocked
    _tn, reason = hd._relay_resolve(env_for("alice", "carol", relayed=True),
                                    cfg, "nodeM")
    out.append(f"loop={reason}")
    # not room-scoped -> not_applicable
    plain = a2a.build_envelope(
        message_id="nodeM:2", sender_bridge="nodeM", sender_agent="alice",
        target_agent="carol", priority="normal", title="t", body="b")
    _tn, reason = hd._relay_resolve(plain, cfg, "nodeM")
    out.append(f"plain={reason}")
    print(" ".join(out))
    return 0


# ---------------------------------------------------------------------------
# unit: durable roster outbox + shared membership-change broadcast (Part F)
# ---------------------------------------------------------------------------
def cmd_outbox_unit(db: str) -> int:
    """Drive the durable outbox: enqueue per remote member, epoch monotonicity,
    ack-clears-row, membership-from-rooms.db (not body)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    out = []
    try:
        ts = rooms.now_ts()
        conn.execute(
            "INSERT OR REPLACE INTO rooms (room_id, name, leader_agent, "
            "leader_node, epoch, invite_token_sha256, invite_token_ts, "
            "invite_once, status, created_ts, updated_ts) "
            "VALUES ('room-f', 'team', 'lead', 'nodeA', 5, '', 0, 0, 'active', ?, ?)",
            (ts, ts))
        for ag, nd in (("lead", "nodeA"), ("bob", "nodeB"), ("carol", "nodeC")):
            conn.execute(
                "INSERT OR REPLACE INTO room_members (room_id, agent, node, "
                "role, joined_ts) VALUES ('room-f', ?, ?, 'member', ?)",
                (ag, nd, ts))
        conn.commit()

        # enqueue at epoch 5 → durable rows for the two REMOTE member nodes only
        # (the leader's own node nodeA is excluded). Membership read from rooms.db.
        targets = rooms.enqueue_roster_broadcast(conn, "room-f", 5, "nodeA")
        out.append(f"targets={','.join(targets)}")
        pend = rooms.pending_roster_outbox(conn, "room-f")
        out.append(f"pending={len(pend)}")

        # epoch monotonicity: enqueue at a LOWER epoch must NOT lower the target.
        rooms.enqueue_roster_broadcast(conn, "room-f", 3, "nodeA")
        row = conn.execute(
            "SELECT epoch FROM room_roster_outbox WHERE room_id='room-f' "
            "AND member_node='nodeB'").fetchone()
        out.append(f"epoch_after_lower={int(row['epoch'])}")
        # enqueue at a HIGHER epoch raises it.
        rooms.enqueue_roster_broadcast(conn, "room-f", 9, "nodeA")
        row = conn.execute(
            "SELECT epoch FROM room_roster_outbox WHERE room_id='room-f' "
            "AND member_node='nodeB'").fetchone()
        out.append(f"epoch_after_higher={int(row['epoch'])}")

        # ack at >= epoch clears the row; an ack at a LOWER epoch does NOT.
        rooms.mark_roster_outbox_done(conn, "room-f", "nodeB", 3)
        row = conn.execute(
            "SELECT status FROM room_roster_outbox WHERE room_id='room-f' "
            "AND member_node='nodeB'").fetchone()
        out.append(f"low_ack_status={row['status']}")
        rooms.mark_roster_outbox_done(conn, "room-f", "nodeB", 9)
        row = conn.execute(
            "SELECT status FROM room_roster_outbox WHERE room_id='room-f' "
            "AND member_node='nodeB'").fetchone()
        out.append(f"high_ack_status={row['status']}")
        out.append(f"still_pending={len(rooms.pending_roster_outbox(conn, 'room-f'))}")

        # codex P2: a KICK passes the removed node via extra_nodes so it ALSO gets
        # a convergence target (it is no longer in room_members but must receive
        # the higher-epoch roster that drops it). Simulate kicking carol@nodeC:
        # remove the member (room_members keys on `node`), then enqueue with
        # extra_nodes=[nodeC].
        conn.execute(
            "DELETE FROM room_members WHERE room_id='room-f' AND agent='carol'")
        conn.commit()
        post_targets = rooms.enqueue_roster_broadcast(
            conn, "room-f", 10, "nodeA", extra_nodes=["nodeC"])
        out.append(f"kick_targets={','.join(post_targets)}")
        # nodeC (the removed node) is enqueued so it converges (drops the room).
        removed_row = conn.execute(
            "SELECT epoch, status FROM room_roster_outbox WHERE room_id='room-f' "
            "AND member_node='nodeC'").fetchone()
        out.append(f"removed_node_queued={removed_row is not None and removed_row['status']=='pending'}")
    finally:
        conn.close()
    print(" ".join(out))
    return 0


# ---------------------------------------------------------------------------
# unit: roster_epoch_reconcile heartbeat adapter (Part F)
# ---------------------------------------------------------------------------
def cmd_reconcile_unit(repo_root: str, db: str, cfg_json: str) -> int:
    """Drive roster_epoch_reconcile: no-rooms => noop; pending => rebroadcast."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_reconcile_common as reconcile  # noqa: E402
    cfg = json.loads(cfg_json)
    out = []

    # 1. NO rooms.db yet → step_noop (the Lane-0 fixture contract).
    res = reconcile.roster_epoch_reconcile(cfg, None)
    out.append(f"no_rooms={res.status}")

    # 2. A leader with a pending durable outbox row + a working relay/roster hook
    #    → the heartbeat re-broadcasts it (the post hook captures + acks 200 so
    #    the row clears). Seed the room + member + a pending outbox row.
    conn = rooms.open_rooms()
    try:
        ts = rooms.now_ts()
        conn.execute(
            "INSERT OR REPLACE INTO rooms (room_id, name, leader_agent, "
            "leader_node, epoch, invite_token_sha256, invite_token_ts, "
            "invite_once, status, created_ts, updated_ts) "
            "VALUES ('room-h', 'team', 'lead', ?, 2, '', 0, 0, 'active', ?, ?)",
            (cfg["bridge_id"], ts, ts))
        for ag, nd in (("lead", cfg["bridge_id"]), ("bob", "nodeB")):
            conn.execute(
                "INSERT OR REPLACE INTO room_members (room_id, agent, node, "
                "role, joined_ts) VALUES ('room-h', ?, ?, 'member', ?)",
                (ag, nd, ts))
        rooms._recompute_roster_cache(conn, "room-h", commit=False)
        rooms.enqueue_roster_broadcast(conn, "room-h", 2, cfg["bridge_id"])
        conn.commit()
    finally:
        conn.close()

    res = reconcile.roster_epoch_reconcile(cfg, None)
    out.append(f"pending_outcome={res.status}")
    # The post hook acked 200, so the row should now be cleared (no pending).
    conn = rooms.open_rooms()
    try:
        remaining = len(rooms.pending_roster_outbox(conn, "room-h"))
    finally:
        conn.close()
    out.append(f"remaining_after={remaining}")
    print(" ".join(out))
    return 0


# ---------------------------------------------------------------------------
# unit: durable outbox RETIREMENT — a never-acked node is retired, no zombie
# ---------------------------------------------------------------------------
def cmd_outbox_retire_unit(db: str) -> int:
    """Drive the bounded-retry RETIREMENT: a node that fails > the attempt cap is
    retired (not re-attempted forever); a later membership change re-arms it."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    out = []
    try:
        ts = rooms.now_ts()
        conn.execute(
            "INSERT OR REPLACE INTO rooms (room_id, name, leader_agent, "
            "leader_node, epoch, invite_token_sha256, invite_token_ts, "
            "invite_once, status, created_ts, updated_ts) "
            "VALUES ('room-r', 'team', 'lead', 'nodeA', 1, '', 0, 0, 'active', ?, ?)",
            (ts, ts))
        for ag, nd in (("lead", "nodeA"), ("bob", "nodeB")):
            conn.execute(
                "INSERT OR REPLACE INTO room_members (room_id, agent, node, "
                "role, joined_ts) VALUES ('room-r', ?, ?, 'member', ?)",
                (ag, nd, ts))
        conn.commit()
        rooms.enqueue_roster_broadcast(conn, "room-r", 1, "nodeA")
        # Fail it MAX_ATTEMPTS times → it retires (no permanent pending zombie).
        for _ in range(rooms.ROSTER_OUTBOX_MAX_ATTEMPTS):
            rooms.record_roster_outbox_failure(conn, "room-r", "nodeB",
                                               "node offline")
        row = conn.execute(
            "SELECT status, attempts FROM room_roster_outbox WHERE "
            "room_id='room-r' AND member_node='nodeB'").fetchone()
        out.append(f"after_cap_status={row['status']}")
        out.append(f"still_pending={len(rooms.pending_roster_outbox(conn, 'room-r'))}")
        # A later membership change re-arms the node (UPSERT resets to pending).
        rooms.enqueue_roster_broadcast(conn, "room-r", 2, "nodeA")
        row = conn.execute(
            "SELECT status, attempts FROM room_roster_outbox WHERE "
            "room_id='room-r' AND member_node='nodeB'").fetchone()
        out.append(f"rearmed_status={row['status']}:attempts={int(row['attempts'])}")
    finally:
        conn.close()
    print(" ".join(out))
    return 0


# ---------------------------------------------------------------------------
# secret-leak scan over a captured payload
# ---------------------------------------------------------------------------
def cmd_secret_scan(path: str) -> int:
    """FAIL if a captured relay/roster payload leaks a secret/token shape."""
    blob = Path(path).read_text(encoding="utf-8").lower()
    bad = ("secret", "token", "passwd", "password", "private_key", "key_seed",
           "invite_key", "test-pair-secret")
    hits = [b for b in bad if b in blob]
    if hits:
        print(f"FAIL secret-scan leaked={hits}", file=sys.stderr)
        return 1
    print("OK secret-scan clean")
    return 0


_COMMANDS = {
    "relay-hook": cmd_relay_hook,
    "roster-hook": cmd_roster_hook,
    "captured-field": cmd_captured_field,
    "make-config": cmd_make_config,
    "make-leader-db": cmd_make_leader_db,
    "build-member-enqueue": cmd_build_member_enqueue,
    "build-nonroom-forged-relay": cmd_build_nonroom_forged_relay,
    "deliver-to-receiver": cmd_deliver_to_receiver,
    "relay-resolve-unit": cmd_relay_resolve_unit,
    "outbox-unit": cmd_outbox_unit,
    "outbox-retire-unit": cmd_outbox_retire_unit,
    "reconcile-unit": cmd_reconcile_unit,
    "secret-scan": cmd_secret_scan,
}


def main(argv: list) -> int:
    if len(argv) < 2 or argv[1] not in _COMMANDS:
        sys.stderr.write(f"usage: {argv[0]} <{'|'.join(_COMMANDS)}> ...\n")
        return 2
    return _COMMANDS[argv[1]](*argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
