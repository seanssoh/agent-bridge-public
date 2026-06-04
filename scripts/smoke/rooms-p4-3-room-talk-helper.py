#!/usr/bin/env python3
"""Helper for the rooms-p4-3-room-talk smoke (A2A Rooms P4.3).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical sender (`agb room talk` — OS-actor-anchored, cached-epoch stamp,
room-scoped enqueue over the node-link), the canonical receiver (`do_POST`
enqueue path → the fail-closed `room_scoped_check` leader-MAC roster-cache gate
→ the dedupe ledger), and the canonical schema — WITHOUT a live socket or
Tailscale.

The transport is stubbed two ways (mirrors the P4.1/P4.2 helpers):
  - SENDER side (`room talk`): the cross-node enqueue POST is captured by the
    paired-flag test hook (BRIDGE_ROOMS_TEST_POST_HOOK → this script's
    `post-hook`), which writes the fully-signed request to $CAPTURE_FILE.
  - RECEIVER side: `deliver-talk-to-receiver` reconstructs a minimal fake HTTP
    request from that captured file and drives the REAL `do_POST` handler, so
    the actual auth preamble (protocol/peer/remote_addr/HMAC/skew/dedupe) + the
    envelope parse + the room-scoped membership gate + the enqueue boundary all
    run end to end. `enqueue_via_bridge_task` is monkeypatched to CAPTURE the
    delivery (and avoid shelling out to bridge-task.sh / touching a live queue),
    so a tooth can assert "delivered" vs "gated, never delivered".

Subcommands (argv[1]):
  post-hook <json>                 (BRIDGE_ROOMS_TEST_POST_HOOK target) — write
                                   the signed request JSON to $CAPTURE_FILE and
                                   echo a stub "{}" response.
  captured-field <file> <key>      print headers[X-AGB-*] or body.<key>.
  make-config <out> <this_node> <peer_node> <secret> <addr> [allowlist_csv]
                                   write a minimal handoff config the receiver
                                   loads (member node trusts the peer + allows
                                   the talk targets).
  seed-cache <db> <room_id> <epoch> <from_node> <members_csv>
                                   write a leader-MAC roster cache row directly
                                   (members_csv = agent@node[:role],... ).
  deliver-talk-to-receiver <repo_root> <cfg_json> <captured_file> [overrides]
                                   replay the captured room-scoped enqueue
                                   through the REAL do_POST handler; print
                                   "status=<n> delivered=<bool> body=<json>".
  membership-unit <db>             unit-drive roster_cache_membership_check
                                   across every tooth (member/non-member/epoch/
                                   no-cache/target).
  mutate-body <captured> <op> [arg]  print the captured envelope body JSON with
                                   one mutation applied (drop-room-id /
                                   drop-room-epoch / drop-both / set-sender-agent
                                   <a> / set-body <text>); used to drive teeth
                                   WITHOUT inline heredocs (heredoc-ban hygiene).
  json-quote <text>                print <text> as a JSON string literal (for
                                   embedding a mutated body into an overrides
                                   JSON without a shell heredoc).
  dedupe-isolation-unit <inbox_db> prove the inbox_dedupe ledger is scoped to
                                   the authenticated peer (a second peer reusing
                                   another peer's message_id does NOT collide).
  migration-failclosed-unit <db>   prove open_inbox FAILS CLOSED (raises) if the
                                   legacy->composite-PK migration did not take.
  staged-race-unit <repo> <cfgA> <cfgB>  prove the staged body file is
                                   peer-scoped: a competing same-message_id peer
                                   cannot clobber the staged body the bridge-task
                                   --body-file read returns.
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
    """Write the captured signed request to $CAPTURE_FILE; stub a 200 body."""
    capture = os.environ.get("CAPTURE_FILE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("CAPTURE_FILE unset", file=sys.stderr)
        return 1
    Path(capture).write_text(payload_json, encoding="utf-8")
    override = os.environ.get("POST_HOOK_ACK")  # noqa: iso-helper-boundary - env var, not a .env file
    if override is not None:
        print(override)
        return 0
    print(json.dumps({"ok": True, "task_id": "stub"}))
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
# config + cache helpers
# ---------------------------------------------------------------------------
def cmd_make_config(out_path: str, this_node: str, peer_node: str,
                    peer_secret: str, address: str,
                    allowlist_csv: str = "") -> int:
    allowlist = [a for a in allowlist_csv.split(",") if a] if allowlist_csv else []
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
                "inbound_allowlist": allowlist,
            }
        ],
    }
    Path(out_path).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
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
    members.sort(key=lambda m: (m["agent"], m["node"]))
    return members


def cmd_seed_cache(db: str, room_id: str, epoch: str, from_node: str,
                   members_csv: str) -> int:
    """Seed a leader-MAC roster cache row directly (the P4.2 outcome).

    Lets a P4.3 tooth set up the member-local cache the receiver gate reads,
    WITHOUT re-running the whole P4.2 broadcast (covered by its own smoke)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    members = _parse_members_csv(members_csv)
    members_json = json.dumps(members, separators=(",", ":"))
    conn = rooms.open_rooms()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
            "members_json, from_node, mac, fetched_ts) VALUES (?, ?, ?, ?, ?, ?)",
            (room_id, int(epoch), members_json, from_node, "leader-mac",
             rooms.now_ts()),
        )
        conn.commit()
    finally:
        conn.close()
    print(f"seeded cache room={room_id} epoch={epoch} members={len(members)}")
    return 0


# ---------------------------------------------------------------------------
# receiver-side replay against the REAL do_POST handler
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


def cmd_deliver_talk_to_receiver(repo_root: str, cfg_json: str, captured: str,
                                 overrides_json: str = "{}") -> int:
    """Replay a captured room-scoped enqueue through the REAL do_POST handler.

    `overrides_json` mutates the captured request (mirrors the P4.2 helper):
      {"client_ip": "...", "headers": {...}, "body": "<json>",
       "recompute_hash": true, "resign": true}
    `resign` recomputes the body hash AND a VALID HMAC for the (mutated) body
    using the peer's configured secret — to drive a path DOWNSTREAM of the HMAC
    gate (e.g. the membership gate) with a legitimately-signed mutated body.
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

    # Monkeypatch the enqueue boundary so a DELIVERED room message is captured
    # in-process (no bridge-task.sh shell-out / live queue). The gate runs
    # BEFORE this, so a gated message never reaches it (delivered stays False).
    delivery: dict = {}

    def _fake_enqueue(*, target, sender_bridge, sender_agent, priority, title,
                      body_file):
        delivery.update({
            "target": target, "sender_bridge": sender_bridge,
            "sender_agent": sender_agent, "priority": priority, "title": title,
        })
        # 4-tuple (ok, task_id, audit_detail, peer_detail) per P4.5.
        return True, "9999", "created task #9999", "created task #9999"

    hd.enqueue_via_bridge_task = _fake_enqueue  # type: ignore[assignment]

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path
    handler.headers = _FakeHeaders(headers)
    handler.rfile = _FakeRFile(body_bytes)
    handler.client_address = (client_ip, 0)
    handler.server = _FakeServer(cfg)

    captured_reply: dict = {}

    def _capture_reply(status, payload, extra_headers=None):
        captured_reply["status"] = status
        captured_reply["payload"] = payload

    handler._reply = _capture_reply  # type: ignore[assignment]
    handler.do_POST()

    status = captured_reply.get("status", 0)
    payload = captured_reply.get("payload", {})
    delivered = bool(delivery)
    print(f"status={status} delivered={delivered} "
          f"body={json.dumps(payload)} delivery={json.dumps(delivery)}")
    return 0


# ---------------------------------------------------------------------------
# unit-drive the membership gate directly (no HTTP at all)
# ---------------------------------------------------------------------------
def cmd_membership_unit(db: str) -> int:
    """Drive roster_cache_membership_check across every P4.3 tooth."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    room = "room-unit"
    members = [
        {"agent": "alice", "node": "nodeA", "role": "leader"},
        {"agent": "bob", "node": "nodeB", "role": "member"},
    ]
    conn.execute(
        "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, members_json, "
        "from_node, mac, fetched_ts) VALUES (?, ?, ?, ?, ?, ?)",
        (room, 3, json.dumps(members, separators=(",", ":")), "nodeA",
         "mac", rooms.now_ts()),
    )
    conn.commit()

    def chk(**kw):
        return rooms.roster_cache_membership_check(conn, room_id=kw["room"],
            room_epoch=kw["epoch"], sender_agent=kw["sa"], sender_node=kw["sn"],
            target_agent=kw["ta"], target_node=kw["tn"])

    try:
        # member sender + member target + matching epoch → OK
        print(f"member_ok={chk(room=room, epoch=3, sa='bob', sn='nodeB', ta='alice', tn='nodeA')}")
        # non-member sender → rejected
        print(f"nonmember_sender={chk(room=room, epoch=3, sa='mallory', sn='nodeB', ta='alice', tn='nodeA')}")
        # member agent on the WRONG (un-authenticated) node → rejected
        print(f"member_wrong_node={chk(room=room, epoch=3, sa='bob', sn='nodeZ', ta='alice', tn='nodeA')}")
        # target not a cached member → rejected
        print(f"target_not_member={chk(room=room, epoch=3, sa='bob', sn='nodeB', ta='ghost', tn='nodeA')}")
        # epoch BEHIND the cache → rejected fail-closed
        print(f"epoch_stale={chk(room=room, epoch=2, sa='bob', sn='nodeB', ta='alice', tn='nodeA')}")
        # epoch AHEAD of the cache → rejected fail-closed
        print(f"epoch_ahead={chk(room=room, epoch=4, sa='bob', sn='nodeB', ta='alice', tn='nodeA')}")
        # unknown room (no cache) → rejected fail-closed
        print(f"no_cache={chk(room='room-unknown', epoch=3, sa='bob', sn='nodeB', ta='alice', tn='nodeA')}")
    finally:
        conn.close()
    return 0


def cmd_mutate_body(captured: str, op: str, arg: str = "") -> int:
    """Print the captured envelope body JSON with one mutation applied.

    Lets the smoke drive its teeth without inline shell heredocs (so the
    heredoc-ban broad-match never trips on the .sh). The output is the mutated
    envelope body as a JSON string on stdout."""
    doc = json.loads(Path(captured).read_text(encoding="utf-8"))
    env = json.loads(doc.get("body", "{}"))
    if op == "drop-room-id":
        env.pop("room_id", None)
    elif op == "drop-room-epoch":
        env.pop("room_epoch", None)
    elif op == "drop-both":
        env.pop("room_id", None)
        env.pop("room_epoch", None)
    elif op == "set-sender-agent":
        env.setdefault("sender", {})["agent"] = arg
    elif op == "set-body":
        env["body"] = arg
    else:
        print(f"unknown mutate op: {op}", file=sys.stderr)
        return 2
    print(json.dumps(env, ensure_ascii=False))
    return 0


def cmd_json_quote(text: str) -> int:
    print(json.dumps(text))
    return 0


def cmd_dedupe_isolation_unit(inbox_db: str) -> int:
    """Prove the inbox_dedupe ledger is scoped to the AUTHENTICATED peer.

    A2A Rooms P4.3 (codex review, contract 6): a second authenticated peer
    reusing ANOTHER peer's sender-chosen message_id must NOT collide — it gets a
    FRESH dedupe namespace, never a spurious duplicate/conflict against the first
    peer's row. Drives the REAL `a2a.open_inbox()` (so the composite-PK schema +
    migration are exercised) and the canonical dedupe semantics."""
    os.environ["BRIDGE_A2A_INBOX_DB"] = inbox_db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = a2a.open_inbox()
    mid = "nodeA:shared-id"
    now = a2a.now_ts()
    try:
        # peerA reserves the id with body hash hA.
        conn.execute(
            "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
            "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
            "VALUES (?, ?, ?, ?, ?, ?, 1)",
            (mid, "nodeA", "hA", "task-A", now, now),
        )
        conn.commit()
        # peerC reuses the SAME message_id with a DIFFERENT body hash hC.
        # Under a global PK this INSERT would raise IntegrityError; under the
        # composite (peer, message_id) PK it is a FRESH, independent row.
        try:
            conn.execute(
                "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
                "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
                "VALUES (?, ?, ?, ?, ?, ?, 1)",
                (mid, "nodeC", "hC", "task-C", now, now),
            )
            conn.commit()
            inserted = True
        except sqlite3.IntegrityError:
            inserted = False
        # peerC's lookup must see ITS OWN row (hC), not peerA's (hA).
        c_row = conn.execute(
            "SELECT body_sha256 FROM inbox_dedupe WHERE peer=? AND message_id=?",
            ("nodeC", mid)).fetchone()
        a_row = conn.execute(
            "SELECT body_sha256 FROM inbox_dedupe WHERE peer=? AND message_id=?",
            ("nodeA", mid)).fetchone()
        print(f"peerC_insert_ok={inserted}")
        print(f"peerC_sees={c_row['body_sha256'] if c_row else None}")
        print(f"peerA_sees={a_row['body_sha256'] if a_row else None}")
    finally:
        conn.close()
    return 0


def _build_signed_enqueue(cfg: dict, peer_id: str, secret: str, *,
                          message_id: str, target: str, sender_agent: str,
                          title: str, body: str) -> tuple:
    """Build a fully-signed plain A2A enqueue request (headers + body bytes) for
    `peer_id`. Returns (path, headers, body_bytes)."""
    env = a2a.build_envelope(
        message_id=message_id, sender_bridge=peer_id, sender_agent=sender_agent,
        target_agent=target, priority="normal", title=title, body=body,
    )
    body_bytes = json.dumps(env, ensure_ascii=False).encode("utf-8")
    path = cfg.get("listen", {}).get("enqueue_path", "/enqueue")
    ts = str(a2a.now_ts())
    bh = a2a.body_sha256(body_bytes)
    canonical = a2a.canonical_string("POST", path, peer_id, message_id, ts, bh)
    headers = {
        "X-AGB-Protocol": a2a.PROTOCOL_VERSION,
        "X-AGB-Peer": peer_id,
        "X-AGB-Message-Id": message_id,
        "X-AGB-Timestamp": ts,
        "X-AGB-Body-SHA256": bh,
        "X-AGB-Signature": a2a.sign(secret, canonical),
        "Content-Length": str(len(body_bytes)),
    }
    return path, headers, body_bytes


def cmd_staged_race_unit(repo_root: str, cfg_a_json: str, cfg_b_json: str) -> int:
    """Prove the staged body file is PEER-SCOPED + collision-proof (codex P4.3
    r2): two peers reusing ONE message_id must NOT share/overwrite the staged
    file between stage-time and the bridge-task --body-file READ.

    Drives peer A's REAL do_POST. The fake enqueue ACTUALLY READS `body_file`,
    but FIRST — while peer A's body is staged and BEFORE peer A's read — it stages
    peer B's body under the SAME message_id (the competing concurrent peer). If
    the staged path were message_id-keyed, peer B's stage would overwrite peer
    A's file and peer A's read would return peer B's bytes. With peer-scoped O_EXCL
    staging the paths are distinct, so peer A reads its OWN body/provenance."""
    hd = _load_handoffd(repo_root)
    cfg_a = json.loads(cfg_a_json)
    cfg_b = json.loads(cfg_b_json)
    secret_a = next((p.get("secret", "") for p in cfg_a.get("peers", [])
                     if p.get("id") == "nodeA"), "")
    secret_b = next((p.get("secret", "") for p in cfg_b.get("peers", [])
                     if p.get("id") == "nodeB"), "")
    addr_a = next((p.get("address", "") for p in cfg_a.get("peers", [])
                   if p.get("id") == "nodeA"), "127.0.0.1")
    shared_id = "shared:race-id"

    # Build BOTH peers' signed enqueue requests carrying the SAME message_id but
    # DIFFERENT bodies/agents.
    path_a, headers_a, body_a = _build_signed_enqueue(
        cfg_a, "nodeA", secret_a, message_id=shared_id, target="bob",
        sender_agent="alice", title="from-A", body="PEER-A-BODY")
    path_b, headers_b, body_b = _build_signed_enqueue(
        cfg_b, "nodeB", secret_b, message_id=shared_id, target="bob",
        sender_agent="carol", title="from-B", body="PEER-B-BODY")

    captured: dict = {}

    def _racing_enqueue(*, target, sender_bridge, sender_agent, priority, title,
                        body_file):
        # The COMPETING peer B stages its body under the SAME message_id NOW —
        # after peer A staged, before peer A's read. Peer-scoped staging means
        # this writes a DIFFERENT file and cannot clobber peer A's.
        hd.stage_inbound_body("nodeB", shared_id,
                              hd.staged_body_text(json.loads(
                                  body_b.decode("utf-8"))))
        # NOW read what peer A's enqueue was handed.
        with open(body_file, encoding="utf-8") as fh:
            captured["read"] = fh.read()
        captured["sender_bridge"] = sender_bridge
        captured["sender_agent"] = sender_agent
        captured["body_file"] = str(body_file)
        # 4-tuple (ok, task_id, audit_detail, peer_detail) per P4.5.
        return True, "9999", "created task #9999", "created task #9999"

    hd.enqueue_via_bridge_task = _racing_enqueue  # type: ignore[assignment]

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path_a
    handler.headers = _FakeHeaders(headers_a)
    handler.rfile = _FakeRFile(body_a)
    handler.client_address = (addr_a, 0)
    handler.server = _FakeServer(cfg_a)
    reply: dict = {}
    handler._reply = lambda s, p, extra_headers=None: reply.update(  # type: ignore[assignment]
        {"status": s, "payload": p})
    handler.do_POST()

    read = captured.get("read", "")
    saw_a_body = "PEER-A-BODY" in read
    saw_b_body = "PEER-B-BODY" in read
    saw_a_prov = "remote agent : alice" in read
    print(f"status={reply.get('status')}")
    print(f"peerA_read_own_body={saw_a_body}")
    print(f"peerA_read_B_body={saw_b_body}")
    print(f"peerA_read_own_provenance={saw_a_prov}")
    print(f"sender_bridge={captured.get('sender_bridge')}")
    return 0


def cmd_migration_failclosed_unit(inbox_db: str) -> int:
    """Prove open_inbox FAILS CLOSED if the legacy->composite migration did not
    take (codex P4.3 r2). Seeds a legacy single-PK inbox.db, neutralizes the
    migration (simulating a rollback that left the legacy table intact), and
    asserts open_inbox raises rather than serving peer-scoped dedupe on a
    global-PK ledger."""
    # 1) a legacy single-column-PK inbox.db.
    conn = sqlite3.connect(inbox_db)
    conn.executescript(
        "CREATE TABLE inbox_dedupe (message_id TEXT PRIMARY KEY, peer TEXT NOT "
        "NULL, body_sha256 TEXT NOT NULL, created_task_id TEXT, first_seen_ts "
        "INTEGER NOT NULL, last_seen_ts INTEGER NOT NULL, delivery_count INTEGER "
        "NOT NULL DEFAULT 1);")
    conn.commit()
    conn.close()
    os.environ["BRIDGE_A2A_INBOX_DB"] = inbox_db  # noqa: iso-helper-boundary - env var, not a .env file
    # 2) neutralize the migration → legacy table persists after open.
    a2a._migrate_inbox_schema = lambda c: None  # type: ignore[assignment]
    try:
        a2a.open_inbox()
        print("failclosed=no:open_inbox returned a legacy-PK connection")
        return 0
    except a2a.A2AError as exc:
        print(f"failclosed=yes:{getattr(exc, 'code', '')}")
        return 0


def main(argv: list) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "post-hook":
        return cmd_post_hook(argv[2])
    if cmd == "captured-field":
        return cmd_captured_field(argv[2], argv[3])
    if cmd == "make-config":
        return cmd_make_config(*argv[2:])
    if cmd == "seed-cache":
        return cmd_seed_cache(argv[2], argv[3], argv[4], argv[5], argv[6])
    if cmd == "deliver-talk-to-receiver":
        return cmd_deliver_talk_to_receiver(*argv[2:])
    if cmd == "membership-unit":
        return cmd_membership_unit(argv[2])
    if cmd == "mutate-body":
        return cmd_mutate_body(argv[2], argv[3], argv[4] if len(argv) > 4 else "")
    if cmd == "json-quote":
        return cmd_json_quote(argv[2])
    if cmd == "dedupe-isolation-unit":
        return cmd_dedupe_isolation_unit(argv[2])
    if cmd == "migration-failclosed-unit":
        return cmd_migration_failclosed_unit(argv[2])
    if cmd == "staged-race-unit":
        return cmd_staged_race_unit(argv[2], argv[3], argv[4])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
