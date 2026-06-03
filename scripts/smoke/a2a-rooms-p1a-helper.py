#!/usr/bin/env python3
"""Helper for the a2a-rooms-p1a smoke.

Kept as a file-as-argv sidecar (not a heredoc fed into `python3 -`) so the
smoke shell never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11).
Imports the real rooms / a2a modules from the repo root so the smoke
exercises the canonical schema, envelope, and receiver-seam code.

Subcommands (argv[1]):
  json-field <key> <json>          print a top-level field (str/int) from JSON
  assert-member <show_json> <agent> exit 0 iff <agent> is a roster member
  assert-no-pending <show_json> <a> exit 0 iff <a> is NOT a pending request
  assert-gt <a> <b>                exit 0 iff int(a) > int(b)
  token-from-link <link>           print the raw token (t=...) from a link
  db-contains-token <db> <token>   exit 0 iff the raw token appears in the db
  write-roster <file> <agent...>   write a minimal roster local file
  members-csv <show_or_adopt_json> print members as a comma-joined agent list
  envelope-contract                run the envelope round-trip + back-compat
  receiver-seam <repo_root>        run the room_scoped_check fail-closed checks
  file-mode <path>                 print the octal file mode (e.g. 600)
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


def _load(arg: str) -> dict:
    return json.loads(arg)


def cmd_json_field(key: str, blob: str) -> int:
    val = _load(blob).get(key)
    if val is None:
        return 1
    print(val)
    return 0


def cmd_assert_member(show_json: str, agent: str) -> int:
    members = _load(show_json).get("members", [])
    return 0 if any(m.get("agent") == agent for m in members) else 1


def cmd_assert_no_pending(show_json: str, agent: str) -> int:
    pending = _load(show_json).get("pending_join_requests", [])
    return 1 if any(p.get("agent") == agent for p in pending) else 0


def cmd_assert_gt(a: str, b: str) -> int:
    return 0 if int(a) > int(b) else 1


def cmd_token_from_link(link: str) -> int:
    parsed = rooms.parse_invite_link(link)
    tok = parsed.get("t", "")
    if not tok:
        return 1
    print(tok)
    return 0


def cmd_db_contains_token(db: str, token: str) -> int:
    """Exit 0 iff the RAW token byte-sequence appears anywhere in the db.

    Dumps the whole db (SQL + values) and scans for the raw token. The
    contract is that ONLY sha256(token) is ever stored, so this must NOT
    find the raw token (the smoke asserts a non-zero exit).
    """
    conn = sqlite3.connect(db)
    try:
        dump = "\n".join(conn.iterdump())
    finally:
        conn.close()
    return 0 if token and token in dump else 1


def cmd_write_roster(path: str, agents: list[str]) -> int:
    lines = []
    if agents:
        lines.append(f'BRIDGE_ADMIN_AGENT_ID="{agents[0]}"')
    for ag in agents:
        lines.append(f'bridge_add_agent_id_if_missing "{ag}"')
        lines.append(f'BRIDGE_AGENT_ENGINE["{ag}"]="shell"')
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


def cmd_members_csv(blob: str) -> int:
    members = _load(blob).get("members", [])
    print(",".join(m.get("agent", "") for m in members))
    return 0


def cmd_envelope_contract() -> int:
    # v1 envelope (no room fields) — must parse unchanged + report not-room.
    e1 = a2a.build_envelope(
        message_id="m1", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="normal", title="t", body="b",
    )
    if "room_id" in e1 or "room_epoch" in e1:
        print("v1 envelope must not carry room fields", file=sys.stderr)
        return 1
    p1 = a2a.parse_envelope(json.dumps(e1).encode("utf-8"))
    if a2a.envelope_is_room_scoped(p1):
        print("v1 envelope must not be room-scoped", file=sys.stderr)
        return 1

    # room-scoped round-trip.
    e2 = a2a.build_envelope(
        message_id="m2", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="high", title="t", body="b",
        room_id="room-x", room_epoch=7,
    )
    p2 = a2a.parse_envelope(json.dumps(e2).encode("utf-8"))
    if not a2a.envelope_is_room_scoped(p2):
        print("room envelope must be room-scoped", file=sys.stderr)
        return 1
    if p2.get("room_id") != "room-x" or p2.get("room_epoch") != 7:
        print("room fields did not round-trip", file=sys.stderr)
        return 1

    # room_id present without room_epoch -> reject.
    bad1 = dict(e1)
    bad1["room_id"] = "room-x"
    if not _expect_reject(bad1, "room_id-without-epoch"):
        return 1
    # negative epoch -> reject.
    bad2 = dict(e1)
    bad2["room_id"] = "room-x"
    bad2["room_epoch"] = -1
    if not _expect_reject(bad2, "negative-epoch"):
        return 1
    # bool epoch -> reject.
    bad3 = dict(e1)
    bad3["room_id"] = "room-x"
    bad3["room_epoch"] = True
    if not _expect_reject(bad3, "bool-epoch"):
        return 1
    return 0


def _expect_reject(env: dict, label: str) -> bool:
    try:
        a2a.parse_envelope(json.dumps(env).encode("utf-8"))
    except a2a.A2AError:
        return True
    print(f"envelope {label} should have been rejected", file=sys.stderr)
    return False


def cmd_receiver_seam(repo_root: str) -> int:
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "bridge_handoffd", os.path.join(repo_root, "bridge-handoffd.py"),
    )
    hd = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(hd)

    cfg = {"bridge_id": "nodeA"}

    # 1) non-room message -> pass (no-op).
    e = a2a.build_envelope(
        message_id="m", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="normal", title="t", body="b",
    )
    ok, reason = hd.room_scoped_check(e, cfg)
    if not ok or reason != "not_room_scoped":
        print(f"non-room must pass, got {(ok, reason)}", file=sys.stderr)
        return 1

    # 2) room-scoped but NO rooms.db -> fail closed.
    e2 = a2a.build_envelope(
        message_id="m", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="normal", title="t", body="b",
        room_id="room-x", room_epoch=1,
    )
    ok, reason = hd.room_scoped_check(e2, cfg)
    if ok:
        print(f"room-scoped with no db must fail closed, got {(ok, reason)}",
              file=sys.stderr)
        return 1

    # Build a room with alice@nodeA (leader) + bob@nodeA member.
    conn = rooms.open_rooms()
    tok = rooms.mint_invite_token()
    rid = rooms.create_room(
        conn, name="t", leader_agent="alice", leader_node="nodeA", token=tok,
    )
    rooms.add_member(conn, rid, "bob", "nodeA")
    conn.close()

    # 3) both members -> pass.
    e3 = a2a.build_envelope(
        message_id="m", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="normal", title="t", body="b",
        room_id=rid, room_epoch=1,
    )
    ok, reason = hd.room_scoped_check(e3, cfg)
    if not ok or reason != "members_ok":
        print(f"both-members must pass, got {(ok, reason)}", file=sys.stderr)
        return 1

    # 4) target not a member -> fail closed.
    e4 = a2a.build_envelope(
        message_id="m", sender_bridge="nodeA", sender_agent="alice",
        target_agent="carol", priority="normal", title="t", body="b",
        room_id=rid, room_epoch=1,
    )
    ok, reason = hd.room_scoped_check(e4, cfg)
    if ok or reason != "target_not_member":
        print(f"target-not-member must fail closed, got {(ok, reason)}",
              file=sys.stderr)
        return 1

    # 5) unknown room -> fail closed.
    e5 = a2a.build_envelope(
        message_id="m", sender_bridge="nodeA", sender_agent="alice",
        target_agent="bob", priority="normal", title="t", body="b",
        room_id="room-nope", room_epoch=1,
    )
    ok, reason = hd.room_scoped_check(e5, cfg)
    if ok or reason != "room_unknown":
        print(f"unknown-room must fail closed, got {(ok, reason)}",
              file=sys.stderr)
        return 1
    return 0


def cmd_assert_cache_fresh(db: str, room_id: str) -> int:
    """Exit 0 iff the PERSISTED room_roster_cache row is fresh for room_id.

    Fresh = cache.epoch == rooms.epoch AND the cache's members_json equals the
    canonical current membership (same agent@node set). This is the F2
    contract: bump_epoch must re-persist room_roster_cache so no verb leaves it
    stale. Reads the actual SQLite rows — not roster_for()'s return value.
    """
    conn = sqlite3.connect(db)
    try:
        rooms_row = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id=?", (room_id,)
        ).fetchone()
        cache_row = conn.execute(
            "SELECT epoch, members_json FROM room_roster_cache WHERE room_id=?",
            (room_id,),
        ).fetchone()
        members_rows = conn.execute(
            "SELECT agent, node FROM room_members WHERE room_id=? "
            "ORDER BY agent, node", (room_id,)
        ).fetchall()
    finally:
        conn.close()
    if rooms_row is None:
        print(f"room {room_id} not in rooms table", file=sys.stderr)
        return 1
    if cache_row is None:
        print(f"room {room_id} has NO room_roster_cache row (stale/missing)",
              file=sys.stderr)
        return 1
    rooms_epoch = int(rooms_row[0])
    cache_epoch = int(cache_row[0])
    if cache_epoch != rooms_epoch:
        print(f"cache epoch {cache_epoch} != rooms epoch {rooms_epoch} (STALE)",
              file=sys.stderr)
        return 1
    try:
        cache_members = json.loads(cache_row[1])
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"cache members_json not parseable: {exc}", file=sys.stderr)
        return 1
    cache_agents = sorted(
        (m.get("agent"), m.get("node", "")) for m in cache_members
    )
    live_agents = sorted((r[0], r[1] or "") for r in members_rows)
    if cache_agents != live_agents:
        print(f"cache members {cache_agents} != live members {live_agents} "
              "(STALE)", file=sys.stderr)
        return 1
    return 0


def cmd_resolve_regime() -> int:
    """Print the resolved actor-auth regime + agent for the current process env.

    Used by the F1 teeth to prove the env uid-map / controller-uid seams are
    inert WITHOUT the paired test flags (a managed agent cannot spoof its
    identity). Output shape: "regime=<r> agent=<a> hard=<bool>".
    """
    a = rooms.resolve_os_actor(None)
    print(f"regime={a.regime} agent={a.agent} hard={a.hard}")
    return 0


def cmd_file_mode(path: str) -> int:
    mode = os.stat(path).st_mode & 0o777
    print(format(mode, "o"))
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: a2a-rooms-p1a-helper.py <subcommand> [args]",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "json-field":
        return cmd_json_field(rest[0], rest[1])
    if cmd == "assert-member":
        return cmd_assert_member(rest[0], rest[1])
    if cmd == "assert-no-pending":
        return cmd_assert_no_pending(rest[0], rest[1])
    if cmd == "assert-gt":
        return cmd_assert_gt(rest[0], rest[1])
    if cmd == "token-from-link":
        return cmd_token_from_link(rest[0])
    if cmd == "db-contains-token":
        return cmd_db_contains_token(rest[0], rest[1])
    if cmd == "write-roster":
        return cmd_write_roster(rest[0], rest[1:])
    if cmd == "members-csv":
        return cmd_members_csv(rest[0])
    if cmd == "envelope-contract":
        return cmd_envelope_contract()
    if cmd == "receiver-seam":
        return cmd_receiver_seam(rest[0])
    if cmd == "assert-cache-fresh":
        return cmd_assert_cache_fresh(rest[0], rest[1])
    if cmd == "resolve-regime":
        return cmd_resolve_regime()
    if cmd == "file-mode":
        return cmd_file_mode(rest[0])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
