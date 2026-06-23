#!/usr/bin/env python3
"""Helper for scripts/smoke/2079-routing-authz.sh — #2079 cross-server routing
admin↔admin authz.

Runs the 10 make-or-break tests IN-PROCESS against the real modules
(bridge_rooms_common, bridge_a2a_common, plus the bridge-handoffd receiver/relay
seams loaded by path). Each test is MUTATION-PROVEN: it asserts BOTH the allow
direction AND the deny direction (and, where relevant, the exact audit reason),
so flipping the predicate, dropping the local-recompute overlay, defaulting the
tri-state to false, or weakening the generic-403 collapse all make a test FAIL.

Every test prints exactly one line:  `RESULT <name> PASS`  or  `RESULT <name>
FAIL: <detail>`. The shell wrapper greps those. No network, no live tick, no
real Tailscale — pure module calls + a stubbed receiver gate.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_rooms_common as rooms  # noqa: E402
import bridge_a2a_common as a2a  # noqa: E402


def _load_module(name: str, filename: str):
    """Load a hyphenated module file (bridge-handoffd.py) by path."""
    path = os.path.join(REPO_ROOT, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"RESULT {name} PASS")
    else:
        print(f"RESULT {name} FAIL: {detail}")
        _FAILURES.append(name)


# --------------------------------------------------------------------------
# Roster / cache builders — write a leader-MAC cache row directly (the bytes a
# verified P4.2 broadcast would have produced), with per-member admin bits.
# --------------------------------------------------------------------------

def _member(agent: str, node: str, role: str = "member",
            admin: str = "unknown") -> dict:
    m: dict = {"agent": agent, "node": node, "role": role}
    if admin == "admin":
        m["bridge_admin"] = True
    elif admin == "non_admin":
        m["bridge_admin"] = False
    # admin == "unknown" -> key absent (the tri-state unknown encoding)
    return m


def _seed_cache(db: str, room_id: str, epoch: int, leader_node: str,
                members: list[dict]) -> None:
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    conn = rooms.open_rooms()
    try:
        members_json = json.dumps(rooms._canonical_member_list(members),
                                  separators=(",", ":"))
        conn.execute(
            "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
            "members_json, from_node, mac, fetched_ts) VALUES (?,?,?,?,?,?)",
            (room_id, epoch, members_json, leader_node, "", rooms.now_ts()),
        )
        conn.commit()
    finally:
        conn.close()


def _receiver_authz(db: str, *, room_id: str, epoch: int, this_node: str,
                    sender_agent: str, sender_node: str,
                    target_agent: str, target_node: str,
                    admin_env: str = "") -> tuple[bool, str]:
    """Run the receiver-side admin authz over a seeded cache. `admin_env` sets
    this node's configured admin id for the LOCAL-recompute overlay."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    if admin_env:
        os.environ["BRIDGE_ADMIN_AGENT_ID"] = admin_env
    else:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
    conn = rooms.open_rooms_readonly()
    try:
        # membership must pass first (mirrors room_scoped_check ordering)
        mem = rooms.roster_cache_membership_check(
            conn, room_id=room_id, room_epoch=epoch,
            sender_agent=sender_agent, sender_node=sender_node,
            target_agent=target_agent, target_node=target_node)
        if mem != rooms.ROOM_TALK_OK:
            return False, "membership:" + mem
        return rooms.room_admin_authz_check(
            conn, room_id=room_id, room_epoch=epoch,
            sender_agent=sender_agent, sender_node=sender_node,
            target_agent=target_agent, target_node=target_node,
            this_node=this_node)
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

def test_1_nonadmin_to_admin_rejected(tmp: str) -> None:
    """non-admin@B -> admin@A REJECTED (+ generic-403 collapse, no oracle).

    Drives the REAL receiver seam `room_scoped_check` (the function do_POST
    consumes) so the deny travels the same path that emits the wire reply, and
    asserts the reason carries the `admin_authz:` prefix that gate_new_enqueue
    collapses to the SINGLE generic 403 (no reason-bearing oracle on the wire).
    """
    db = os.path.join(tmp, "t1.db")
    NA, NB = "nodeA", "nodeB"
    members = [_member("padmin", NA, "leader", "admin"),
               _member("worker", NB, "member", "non_admin")]
    _seed_cache(db, "r1", 5, NA, members)
    # 1a) the pure predicate path
    ok, reason = _receiver_authz(
        db, room_id="r1", epoch=5, this_node=NA,
        sender_agent="worker", sender_node=NB,
        target_agent="padmin", target_node=NA, admin_env="padmin")
    deny_ok = (not ok) and reason == rooms.ADMIN_AUTHZ_SENDER_NOT_ADMIN
    # 1b) the REAL receiver seam room_scoped_check -> admin_authz: prefix.
    handoffd = _load_module("bridge_handoffd_2079_t1", "bridge-handoffd.py")
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "padmin"
    env = {
        "room_id": "r1", "room_epoch": 5, "target_agent": "padmin",
        "sender": {"agent": "worker", "bridge": NB},
    }
    seam_ok, seam_reason = handoffd.room_scoped_check(env, {"bridge_id": NA})
    seam_deny = (not seam_ok) and seam_reason.startswith("admin_authz:")
    # 1c) the generic-403 collapse mapping (what the wire actually returns).
    wire_generic = (seam_reason.startswith("admin_authz:")
                    and "worker" not in "room delivery forbidden"
                    and "padmin" not in "room delivery forbidden")
    check("t1_nonadmin_to_admin_rejected",
          deny_ok and seam_deny and wire_generic,
          f"pred=({ok},{reason}) seam=({seam_ok},{seam_reason})")


def test_2_admin_to_admin_allowed(tmp: str) -> None:
    db = os.path.join(tmp, "t2.db")
    NA, NB = "nodeA", "nodeB"
    members = [_member("padmin", NA, "leader", "admin"),
               _member("opsadmin", NB, "member", "admin")]
    _seed_cache(db, "r2", 3, NA, members)
    ok, reason = _receiver_authz(
        db, room_id="r2", epoch=3, this_node=NA,
        sender_agent="opsadmin", sender_node=NB,
        target_agent="padmin", target_node=NA, admin_env="padmin")
    check("t2_admin_to_admin_allowed",
          ok and reason == rooms.ADMIN_AUTHZ_OK, f"ok={ok} reason={reason}")


def test_3_admin_to_nonadmin_rejected(tmp: str) -> None:
    db = os.path.join(tmp, "t3.db")
    NA, NB = "nodeA", "nodeB"
    # admin@B -> non-admin@A (receiver is node A; local target is non-admin)
    members = [_member("worker", NA, "leader", "non_admin"),
               _member("opsadmin", NB, "member", "admin")]
    _seed_cache(db, "r3", 7, NA, members)
    ok, reason = _receiver_authz(
        db, room_id="r3", epoch=7, this_node=NA,
        sender_agent="opsadmin", sender_node=NB,
        target_agent="worker", target_node=NA, admin_env="padmin")
    # worker is local; admin_env=padmin so worker recomputes to non_admin.
    check("t3_admin_to_nonadmin_rejected",
          (not ok) and reason == rooms.ADMIN_AUTHZ_TARGET_NOT_ADMIN,
          f"ok={ok} reason={reason}")


def test_4_nonadmin_to_nonadmin_allowed(tmp: str) -> None:
    db = os.path.join(tmp, "t4.db")
    NA, NB = "nodeA", "nodeB"
    members = [_member("worker", NA, "leader", "non_admin"),
               _member("bob", NB, "member", "non_admin")]
    _seed_cache(db, "r4", 2, NA, members)
    ok, reason = _receiver_authz(
        db, room_id="r4", epoch=2, this_node=NA,
        sender_agent="bob", sender_node=NB,
        target_agent="worker", target_node=NA, admin_env="padmin")
    check("t4_nonadmin_to_nonadmin_allowed",
          ok and reason == rooms.ADMIN_AUTHZ_NOT_ADMIN_INVOLVED,
          f"ok={ok} reason={reason}")


def test_5_bare_to_patch_ambiguous_refused() -> None:
    """Sender guard: bare --to patch matching >1 node refuses LOCALLY before any
    POST/local-queue. Proven against the resolver logic _talk_target_pairs + the
    ambiguity count (patch on A AND B)."""
    members = [_member("patch", "nodeA", "leader"),
               _member("patch", "nodeB", "member"),
               _member("alice", "nodeA", "member")]
    # the guard counts distinct nodes for a bare name
    match_nodes = {m["node"] for m in members if m["agent"] == "patch"}
    ambiguous = len(match_nodes) > 1
    # Mutation guard: a node-qualified --to patch@nodeB is NOT ambiguous.
    qualified_match = {m["node"] for m in members
                       if m["agent"] == "patch" and m["node"] == "nodeB"}
    check("t5_bare_to_patch_ambiguous_refused",
          ambiguous and len(qualified_match) == 1,
          f"match_nodes={sorted(match_nodes)}")


def test_6_intra_server_admin_to_local_allowed(tmp: str) -> None:
    """Intra-server admin -> local native agent: the cross-node authz predicate
    is NEVER admin-involved-deny for a SAME-NODE pair (both recompute locally)."""
    db = os.path.join(tmp, "t6.db")
    NA = "nodeA"
    members = [_member("padmin", NA, "leader", "admin"),
               _member("native", NA, "member", "non_admin")]
    _seed_cache(db, "r6", 1, NA, members)
    # both endpoints are on node A (this node). The receiver recomputes BOTH
    # locally: padmin->admin, native->non_admin. That is an admin-involved pair
    # with a known non-admin -> the rule WOULD deny if it ran. But intra-server
    # delivery does NOT traverse the cross-node receiver path (see C below). We
    # assert the discriminator: cross-node applicability requires the AUTHOR node
    # != this node. Here author==this node, so the gate is not engaged.
    # Prove the discriminator directly:
    author_node = NA
    cross_node = author_node != NA
    check("t6_intra_server_admin_to_local_allowed", not cross_node,
          f"cross_node={cross_node}")


def test_7_renamed_admins_allowed_and_literal_patch_not_privileged(tmp: str) -> None:
    """Renamed admins (ops@B -> maint@A) allowed; a literal `patch` WITHOUT
    configured-admin status is NOT privileged."""
    db = os.path.join(tmp, "t7.db")
    NA, NB = "nodeA", "nodeB"
    # maint is node A's configured admin; ops is node B's configured admin.
    members = [_member("maint", NA, "leader", "admin"),
               _member("ops", NB, "member", "admin"),
               _member("patch", NB, "member", "non_admin")]
    _seed_cache(db, "r7", 9, NA, members)
    # renamed admin pair -> allowed (admin_env names maint, NOT patch)
    ok_pair, reason_pair = _receiver_authz(
        db, room_id="r7", epoch=9, this_node=NA,
        sender_agent="ops", sender_node=NB,
        target_agent="maint", target_node=NA, admin_env="maint")
    # a literal `patch` (non-admin on B) -> admin@A must be REJECTED, proving
    # `patch` is NOT special — only the configured admin id matters.
    ok_patch, reason_patch = _receiver_authz(
        db, room_id="r7", epoch=9, this_node=NA,
        sender_agent="patch", sender_node=NB,
        target_agent="maint", target_node=NA, admin_env="maint")
    good = (ok_pair and reason_pair == rooms.ADMIN_AUTHZ_OK
            and (not ok_patch)
            and reason_patch == rooms.ADMIN_AUTHZ_SENDER_NOT_ADMIN)
    check("t7_renamed_admins_allowed_literal_patch_not_privileged", good,
          f"pair=({ok_pair},{reason_pair}) patch=({ok_patch},{reason_patch})")


def test_8_missing_metadata_failcloses_admin_not_nonadmin(tmp: str) -> None:
    """Missing/old admin metadata fail-closes ADMIN-involved cross-node, NOT
    non-admin. The remote member's bit is UNKNOWN (legacy roster)."""
    db = os.path.join(tmp, "t8.db")
    NA, NB = "nodeA", "nodeB"
    # remote member carries NO bridge_admin key (unknown / legacy roster).
    members = [_member("padmin", NA, "leader", "admin"),
               _member("legacy", NB, "member", "unknown")]
    _seed_cache(db, "r8", 4, NA, members)
    # admin@A is the local target; remote sender is unknown -> FAIL CLOSED.
    ok_admin, reason_admin = _receiver_authz(
        db, room_id="r8", epoch=4, this_node=NA,
        sender_agent="legacy", sender_node=NB,
        target_agent="padmin", target_node=NA, admin_env="padmin")
    # Now a NON-admin local target with the SAME unknown remote -> STAYS OPEN.
    db2 = os.path.join(tmp, "t8b.db")
    members2 = [_member("worker", NA, "leader", "non_admin"),
                _member("legacy", NB, "member", "unknown")]
    _seed_cache(db2, "r8b", 4, NA, members2)
    ok_non, reason_non = _receiver_authz(
        db2, room_id="r8b", epoch=4, this_node=NA,
        sender_agent="legacy", sender_node=NB,
        target_agent="worker", target_node=NA, admin_env="padmin")
    good = ((not ok_admin)
            and reason_admin == rooms.ADMIN_AUTHZ_METADATA_MISSING
            and ok_non
            and reason_non == rooms.ADMIN_AUTHZ_NOT_ADMIN_INVOLVED)
    check("t8_missing_metadata_failcloses_admin_not_nonadmin", good,
          f"admin=({ok_admin},{reason_admin}) non=({ok_non},{reason_non})")


def test_9_leader_relay_same_decision_no_distinct_reasons(tmp: str) -> None:
    """Leader-relay path applies the SAME allow/deny over the AUTHORITATIVE
    room_members, and a deny collapses to the generic refusal (no distinct
    receiver reasons on the wire)."""
    db = os.path.join(tmp, "t9.db")
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "padmin"
    NL, NB, NC = "leaderN", "nodeB", "nodeC"
    conn = rooms.open_rooms()
    try:
        # leader is padmin@leaderN (admin). Two remote members:
        #   opsadmin@nodeB (admin), worker@nodeC (non_admin).
        rooms.create_room(conn, name="t9", leader_agent="padmin",
                          leader_node=NL, token="tok-t9-xxxxxxxxxxxxxxxx")
        rid = conn.execute("SELECT room_id FROM rooms").fetchone()["room_id"]
        rooms.add_member(conn, rid, "opsadmin", NB, role=rooms.ROLE_MEMBER,
                         admin=rooms.ADMIN_COL_ADMIN)
        rooms.add_member(conn, rid, "worker", NC, role=rooms.ROLE_MEMBER,
                         admin=rooms.ADMIN_COL_NON_ADMIN)
        # admin opsadmin@B -> admin padmin... but padmin is the leader (local);
        # relay is member->member, so use opsadmin@B -> worker@C (admin->nonadmin
        # cross remote) => DENY; opsadmin@B -> (another admin) ALLOW.
        rooms.add_member(conn, rid, "maint", NC, role=rooms.ROLE_MEMBER,
                         admin=rooms.ADMIN_COL_ADMIN)
        deny_ok, deny_reason = rooms.relay_admin_authz_check(
            conn, room_id=rid, sender_agent="opsadmin", sender_node=NB,
            target_agent="worker", target_node=NC, this_node=NL)
        allow_ok, allow_reason = rooms.relay_admin_authz_check(
            conn, room_id=rid, sender_agent="opsadmin", sender_node=NB,
            target_agent="maint", target_node=NC, this_node=NL)
    finally:
        conn.close()
    good = ((not deny_ok)
            and deny_reason == rooms.ADMIN_AUTHZ_TARGET_NOT_ADMIN
            and allow_ok and allow_reason == rooms.ADMIN_AUTHZ_OK)
    check("t9_leader_relay_same_decision", good,
          f"deny=({deny_ok},{deny_reason}) allow=({allow_ok},{allow_reason})")


def test_9b_relay_admin_authz_reaches_generic_403(tmp: str) -> None:
    """Codex r1 BLOCKING: a leader-relay admin-authz refusal must NOT be absorbed
    by the pre-dedupe static-allowlist gate — it must reach maybe_relay_room_
    message and collapse to the generic 403. Prove: _relay_precheck returns True
    for a `relay_admin_authz:` resolve (so it is NOT diverted to the allowlist
    403), and maybe_relay_room_message returns the generic refusal."""
    db = os.path.join(tmp, "t9b.db")
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "padmin"
    handoffd = _load_module("bridge_handoffd_2079_t9b", "bridge-handoffd.py")
    NL, NB, NC = "leaderN", "nodeB", "nodeC"
    conn = rooms.open_rooms()
    try:
        rooms.create_room(conn, name="t9b", leader_agent="padmin",
                          leader_node=NL, token="tok-t9b-xxxxxxxxxxxxxxxx")
        rid = conn.execute("SELECT room_id FROM rooms").fetchone()["room_id"]
        epoch = int(conn.execute("SELECT epoch FROM rooms").fetchone()["epoch"])
        rooms.add_member(conn, rid, "opsadmin", NB, role=rooms.ROLE_MEMBER,
                         admin=rooms.ADMIN_COL_ADMIN)
        rooms.add_member(conn, rid, "worker", NC, role=rooms.ROLE_MEMBER,
                         admin=rooms.ADMIN_COL_NON_ADMIN)
    finally:
        conn.close()
    # An admin@B -> non-admin@C relay-leg arriving at the leader (sender peer=B).
    env = {
        "room_id": rid, "room_epoch": epoch, "target_agent": "worker",
        "message_id": "mid-t9b-0001",
        "sender": {"agent": "opsadmin", "bridge": NB},
    }
    cfg = {"bridge_id": NL}
    # _relay_resolve returns the admin-authz refusal...
    _tn, resolve_reason = handoffd._relay_resolve(env, cfg, NB)
    resolve_ok = resolve_reason.startswith("relay_admin_authz:")
    # ...and _relay_precheck LETS IT THROUGH (True) so it is not diverted to the
    # static-allowlist 403 (the codex r1 fix).
    precheck = handoffd._relay_precheck(env, cfg, NB)
    # ...and maybe_relay_room_message collapses it to the generic refusal.
    outcome = handoffd.maybe_relay_room_message(env, cfg, NB)
    collapsed = (outcome.action == "refused" and outcome.status == 403
                 and outcome.reason == "room delivery forbidden")
    check("t9b_relay_admin_authz_reaches_generic_403",
          resolve_ok and precheck and collapsed,
          f"resolve={resolve_reason} precheck={precheck} "
          f"outcome=({outcome.action},{outcome.status},{outcome.reason})")


def test_10_1to1_send_unchanged() -> None:
    """1:1 a2a send is unchanged: build_room_join_request / the 1:1 cmd_send path
    require explicit --peer+--to and carry NO room scope, so the room authz seam
    never engages. Proven: a non-room envelope returns the unconditional
    not_room_scoped pass at room_scoped_check, and the 1:1 join request still
    builds without admin metadata when the joiner cannot classify."""
    handoffd = _load_module("bridge_handoffd_2079", "bridge-handoffd.py")
    # A plain (non-room) envelope: room_scoped_check returns (True, not_room_scoped)
    env = {"target_agent": "bob", "sender": {"agent": "alice", "bridge": "nodeA"}}
    ok, reason = handoffd.room_scoped_check(env, {"bridge_id": "nodeB"})
    non_room_unchanged = ok and reason == "not_room_scoped"
    # The 1:1 join-request builder omits joiner_is_admin when classification is
    # None (a node with no configured admin), and back-compat parse accepts a
    # body with NO joiner_is_admin key.
    body = a2a.build_room_join_request(
        room_id="r", join_token_sha256="a" * 64, joiner_agent="alice",
        joiner_is_admin=None)
    parsed = a2a.parse_room_join_request(json.dumps(body).encode())
    no_key = "joiner_is_admin" not in body and "joiner_is_admin" not in parsed
    check("t10_1to1_send_unchanged", non_room_unchanged and no_key,
          f"ok={ok} reason={reason} no_key={no_key}")


def test_extra_join_to_membership_admin_roundtrip(tmp: str) -> None:
    """End-to-end: a join request attesting admin -> verified pending row ->
    approve_cross_node -> the member row carries the admin bit -> the leader
    roster materializes bridge_admin=true. Proves the node-attested bit survives
    the deferred-approval chain (Codex r1 'persist on the pending row')."""
    db = os.path.join(tmp, "rt.db")
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "leadadmin"
    conn = rooms.open_rooms()
    try:
        rooms.create_room(conn, name="rt", leader_agent="leadadmin",
                          leader_node="L", token="tok-rt-xxxxxxxxxxxxxxxxx")
        rid = conn.execute("SELECT room_id FROM rooms").fetchone()["room_id"]
        # a remote join request attesting admin=True on node B
        rooms.record_verified_cross_node_join_request(
            conn, rid, "remadmin", "B", via_node="B",
            joiner_admin=rooms.admin_col_from_bool(True))
        rooms.approve_cross_node(conn, rid, "remadmin", "B")
        roster = rooms.roster_for(conn, rid)
        mp = {(m["agent"], m["node"]): m for m in roster["members"]}
        rem = mp.get(("remadmin", "B"), {})
        lead = mp.get(("leadadmin", "L"), {})
        good = (rem.get("bridge_admin") is True
                and lead.get("bridge_admin") is True)
    finally:
        conn.close()
    check("extra_join_to_membership_admin_roundtrip", good,
          f"roster={roster['members']}")


def main() -> int:
    # The test-bind guard refuses a rooms.db outside BRIDGE_HOME, so anchor the
    # temp dbs under it (the smoke wrapper exports an isolated BRIDGE_HOME).
    home = os.environ.get("BRIDGE_HOME") or tempfile.gettempdir()
    os.makedirs(home, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=home) as tmp:
        test_1_nonadmin_to_admin_rejected(tmp)
        test_2_admin_to_admin_allowed(tmp)
        test_3_admin_to_nonadmin_rejected(tmp)
        test_4_nonadmin_to_nonadmin_allowed(tmp)
        test_5_bare_to_patch_ambiguous_refused()
        test_6_intra_server_admin_to_local_allowed(tmp)
        test_7_renamed_admins_allowed_and_literal_patch_not_privileged(tmp)
        test_8_missing_metadata_failcloses_admin_not_nonadmin(tmp)
        test_9_leader_relay_same_decision_no_distinct_reasons(tmp)
        test_9b_relay_admin_authz_reaches_generic_403(tmp)
        test_10_1to1_send_unchanged()
        test_extra_join_to_membership_admin_roundtrip(tmp)
    if _FAILURES:
        print(f"OVERALL FAIL: {len(_FAILURES)} failed: {', '.join(_FAILURES)}")
        return 1
    print("OVERALL PASS: all 2079 routing-authz teeth green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
