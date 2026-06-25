#!/usr/bin/env python3
"""Helper for scripts/smoke/2109-rooms-admin-migration.sh — #2109 (#2079 durable
half): robust room_members.admin migration + local-admin backfill + leader-only
roster re-broadcast.

Runs the make-or-break tests IN-PROCESS against the real bridge_rooms_common
module. Each test is MUTATION-PROVEN: it asserts the exact before/after state, so
widening the narrowed `_migrate_schema` except, inferring a remote admin from
local config, writing 0 instead of -1 on an empty admin config, or letting a
non-leader bump/enqueue all make a test FAIL.

Every test prints exactly one line:  `RESULT <name> PASS`  or  `RESULT <name>
FAIL: <detail>`. The shell wrapper greps those. No network, no live tick, no real
Tailscale — pure module calls against rooms.db files under BRIDGE_HOME.
"""
from __future__ import annotations

import os
import sqlite3
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_rooms_common as rooms  # noqa: E402

_FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"RESULT {name} PASS")
    else:
        print(f"RESULT {name} FAIL: {detail}")
        _FAILURES.append(name)


def _fresh_db() -> str:
    """A fresh rooms.db path under BRIDGE_HOME (so the test-bind guard passes)."""
    d = tempfile.mkdtemp(prefix="rooms-2109-", dir=os.environ["_2109_TMP"])
    db = os.path.join(d, "rooms.db")
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    return db


def _set_admin(admin_id: str) -> None:
    if admin_id:
        os.environ["BRIDGE_ADMIN_AGENT_ID"] = admin_id
    else:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
    # Never let a stray roster file leak in: pin the roster overrides to absent.
    os.environ.pop("BRIDGE_ROSTER_LOCAL_FILE", None)
    os.environ.pop("BRIDGE_ROSTER_FILE", None)


def _seed_room(conn: sqlite3.Connection, room_id: str, leader_agent: str,
               leader_node: str) -> None:
    ts = rooms.now_ts()
    conn.execute(
        "INSERT INTO rooms (room_id, name, leader_agent, leader_node, epoch, "
        "invite_token_sha256, invite_token_ts, invite_once, status, "
        "created_ts, updated_ts) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (room_id, "", leader_agent, leader_node, 0, "x", ts, 0, "active", ts, ts),
    )
    conn.commit()


def _seed_member(conn: sqlite3.Connection, room_id: str, agent: str, node: str,
                 role: str = "member", admin: int = rooms.ADMIN_COL_UNKNOWN) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO room_members (room_id, agent, node, role, "
        "joined_ts, admin) VALUES (?,?,?,?,?,?)",
        (room_id, agent, node, role, rooms.now_ts(), int(admin)),
    )
    conn.commit()


def _member_admin(conn: sqlite3.Connection, room_id: str, agent: str,
                  node: str) -> int:
    row = conn.execute(
        "SELECT admin FROM room_members WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    return int(row["admin"]) if row is not None else -999


# --------------------------------------------------------------------------
# Part 1 — migration robustness (_migrate_schema narrowed except)
# --------------------------------------------------------------------------

def test_migrate_adds_admin_column() -> None:
    _set_admin("")
    db = _fresh_db()
    conn = rooms.open_rooms()  # runs _migrate_schema
    try:
        ok = rooms._table_has_column(conn, "room_members", "admin")
        ok2 = rooms._table_has_column(conn, "room_join_requests", "joiner_admin")
        check("migrate_adds_admin_column", ok and ok2,
              f"admin={ok} joiner_admin={ok2}")
    finally:
        conn.close()


def test_migrate_duplicate_rerun_noop() -> None:
    """A second open (column already present) is a clean no-op, not an error."""
    _set_admin("")
    db = _fresh_db()
    c1 = rooms.open_rooms()
    c1.close()
    try:
        c2 = rooms.open_rooms()  # re-runs _migrate_schema; must not raise
        c2.close()
        check("migrate_duplicate_rerun_noop", True)
    except Exception as exc:  # noqa: BLE001
        check("migrate_duplicate_rerun_noop", False, repr(exc))


def test_migrate_nonduplicate_error_reraises() -> None:
    """A NON-duplicate OperationalError (e.g. database is locked) must propagate
    out of _migrate_schema, NOT be swallowed (#2109 gap 1)."""
    # Build a connection on a fresh db that has the base tables but is MISSING
    # the admin column, then make ALTER fail with a lock by holding a write txn
    # from a second connection.
    _set_admin("")
    d = tempfile.mkdtemp(prefix="rooms-2109-lock-", dir=os.environ["_2109_TMP"])
    db = os.path.join(d, "rooms.db")
    # Create the base schema WITHOUT the migrated columns so _migrate_schema has
    # real ALTERs to run.
    base = sqlite3.connect(db)
    base.executescript(
        "CREATE TABLE rooms (room_id TEXT PRIMARY KEY, leader_agent TEXT NOT NULL);"
        "CREATE TABLE room_members (room_id TEXT NOT NULL, agent TEXT NOT NULL, "
        "node TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT 'member', "
        "joined_ts INTEGER NOT NULL, PRIMARY KEY (room_id, agent, node));"
        "CREATE TABLE room_join_requests (room_id TEXT NOT NULL, agent TEXT NOT NULL, "
        "node TEXT NOT NULL DEFAULT '', requested_ts INTEGER NOT NULL, "
        "status TEXT NOT NULL DEFAULT 'pending');"
    )
    base.commit()
    # A migration connection with a SHORT busy timeout so the lock surfaces fast.
    mig = sqlite3.connect(db, timeout=0.0)
    mig.row_factory = sqlite3.Row
    mig.execute("PRAGMA busy_timeout=0")
    # Hold an EXCLUSIVE write lock on `base` so the ALTER on `mig` is blocked.
    base.isolation_level = None
    base.execute("BEGIN EXCLUSIVE")
    base.execute("INSERT INTO rooms (room_id, leader_agent) VALUES ('r','a')")
    raised = ""
    try:
        rooms._migrate_schema(mig)
    except sqlite3.OperationalError as exc:
        raised = str(exc).lower()
    except Exception as exc:  # noqa: BLE001
        raised = "UNEXPECTED:" + repr(exc)
    finally:
        try:
            base.execute("COMMIT")
        except Exception:  # noqa: BLE001
            pass
        base.close()
        mig.close()
    # The lock error must have RE-RAISED (it is NOT "duplicate column name").
    ok = ("lock" in raised) and ("duplicate column name" not in raised)
    check("migrate_nonduplicate_error_reraises", ok,
          f"raised={raised!r}")


# --------------------------------------------------------------------------
# Part 2 — local-admin backfill (local authority only)
# --------------------------------------------------------------------------

def test_backfill_local_admin_and_nonadmin() -> None:
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "patchy", "nodeA")
        _seed_member(conn, "r1", "patchy", "nodeA", role="leader")
        _seed_member(conn, "r1", "worker", "nodeA")
        changed = rooms.backfill_local_admin(conn, "nodeA")
        admin_bit = _member_admin(conn, "r1", "patchy", "nodeA")
        worker_bit = _member_admin(conn, "r1", "worker", "nodeA")
        ok = (admin_bit == rooms.ADMIN_COL_ADMIN
              and worker_bit == rooms.ADMIN_COL_NON_ADMIN
              and "r1" in changed)
        check("backfill_local_admin_and_nonadmin", ok,
              f"admin={admin_bit} worker={worker_bit} changed={changed}")
    finally:
        conn.close()


def test_backfill_leaves_remote_rows_untouched() -> None:
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "patchy", "nodeA")
        _seed_member(conn, "r1", "patchy", "nodeA", role="leader")
        # A REMOTE row whose agent name HAPPENS to equal the local admin id —
        # local config must NEVER classify a remote endpoint.
        _seed_member(conn, "r1", "patchy", "nodeB")
        rooms.backfill_local_admin(conn, "nodeA")
        remote_bit = _member_admin(conn, "r1", "patchy", "nodeB")
        check("backfill_leaves_remote_rows_untouched",
              remote_bit == rooms.ADMIN_COL_UNKNOWN,
              f"remote bit={remote_bit} (must stay -1)")
    finally:
        conn.close()


def test_backfill_empty_config_leaves_unknown() -> None:
    _set_admin("")  # no configured admin id anywhere
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "leadguy", "nodeA")
        _seed_member(conn, "r1", "leadguy", "nodeA", role="leader")
        _seed_member(conn, "r1", "worker", "nodeA")
        changed = rooms.backfill_local_admin(conn, "nodeA")
        a = _member_admin(conn, "r1", "leadguy", "nodeA")
        b = _member_admin(conn, "r1", "worker", "nodeA")
        ok = (a == rooms.ADMIN_COL_UNKNOWN and b == rooms.ADMIN_COL_UNKNOWN
              and not changed)
        check("backfill_empty_config_leaves_unknown", ok,
              f"lead={a} worker={b} changed={changed} (both must stay -1, no 0)")
    finally:
        conn.close()


def test_backfill_corrects_stale_classification() -> None:
    """A STALE admin=1 on a member that is no longer the configured admin must be
    corrected to non-admin (recompute is over ALL local rows, not just -1)."""
    _set_admin("newadmin")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "newadmin", "nodeA")
        _seed_member(conn, "r1", "newadmin", "nodeA", role="leader",
                     admin=rooms.ADMIN_COL_NON_ADMIN)  # stale: should be admin
        _seed_member(conn, "r1", "oldadmin", "nodeA",
                     admin=rooms.ADMIN_COL_ADMIN)  # stale: should be non-admin
        changed = rooms.backfill_local_admin(conn, "nodeA")
        new_bit = _member_admin(conn, "r1", "newadmin", "nodeA")
        old_bit = _member_admin(conn, "r1", "oldadmin", "nodeA")
        ok = (new_bit == rooms.ADMIN_COL_ADMIN
              and old_bit == rooms.ADMIN_COL_NON_ADMIN
              and "r1" in changed)
        check("backfill_corrects_stale_classification", ok,
              f"new={new_bit} old={old_bit} changed={changed}")
    finally:
        conn.close()


def test_backfill_singlenode_empty_node() -> None:
    """On a single-node install local rows carry node='' and local_node=''."""
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "patchy", "")
        _seed_member(conn, "r1", "patchy", "", role="leader")
        _seed_member(conn, "r1", "worker", "")
        changed = rooms.backfill_local_admin(conn, "")
        a = _member_admin(conn, "r1", "patchy", "")
        b = _member_admin(conn, "r1", "worker", "")
        ok = (a == rooms.ADMIN_COL_ADMIN and b == rooms.ADMIN_COL_NON_ADMIN
              and "r1" in changed)
        check("backfill_singlenode_empty_node", ok,
              f"admin={a} worker={b} changed={changed}")
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Part 3 — leader-only rebroadcast via the durable path
# --------------------------------------------------------------------------

def test_leader_bumps_and_enqueues() -> None:
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "patchy", "nodeA")
        _seed_member(conn, "r1", "patchy", "nodeA", role="leader")
        _seed_member(conn, "r1", "worker", "nodeA")
        # A REMOTE member so the outbox has a real convergence target.
        _seed_member(conn, "r1", "remoteguy", "nodeB")
        epoch_before = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        cfg = {"bridge_id": "nodeA"}
        summary = rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)
        epoch_after = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        outbox = conn.execute(
            "SELECT member_node, status FROM room_roster_outbox WHERE room_id='r1'"
        ).fetchall()
        nodes = {r["member_node"] for r in outbox}
        ok = (summary["rebroadcast_rooms"] == 1
              and epoch_after == epoch_before + 1
              and nodes == {"nodeB"})  # only the remote node is a target
        check("leader_bumps_and_enqueues", ok,
              f"summary={summary} epoch {epoch_before}->{epoch_after} outbox={nodes}")
    finally:
        conn.close()


def test_nonleader_does_not_bump() -> None:
    """This node is NOT the room's leader → it backfills its own local member
    bits but must NOT bump the epoch or enqueue a broadcast (no forging)."""
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        # Leader is on nodeB; THIS node is nodeA (a member, not the leader).
        _seed_room(conn, "r1", "bossB", "nodeB")
        _seed_member(conn, "r1", "bossB", "nodeB", role="leader")
        _seed_member(conn, "r1", "patchy", "nodeA")  # local admin member
        epoch_before = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        cfg = {"bridge_id": "nodeA"}
        summary = rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)
        epoch_after = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        # Local bit WAS backfilled (correct for local reads)...
        local_bit = _member_admin(conn, "r1", "patchy", "nodeA")
        # ...but NO bump and NO outbox row (we are not the leader).
        try:
            outbox = conn.execute(
                "SELECT COUNT(*) c FROM room_roster_outbox WHERE room_id='r1'"
            ).fetchone()["c"]
        except sqlite3.OperationalError:
            outbox = 0
        ok = (summary["rebroadcast_rooms"] == 0
              and epoch_after == epoch_before
              and local_bit == rooms.ADMIN_COL_ADMIN
              and outbox == 0)
        check("nonleader_does_not_bump", ok,
              f"summary={summary} epoch {epoch_before}->{epoch_after} "
              f"local_bit={local_bit} outbox_rows={outbox}")
    finally:
        conn.close()


def test_no_change_no_bump() -> None:
    """A second call with already-correct bits bumps nothing (idempotent)."""
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    try:
        _seed_room(conn, "r1", "patchy", "nodeA")
        _seed_member(conn, "r1", "patchy", "nodeA", role="leader")
        _seed_member(conn, "r1", "remoteguy", "nodeB")
        cfg = {"bridge_id": "nodeA"}
        rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)  # first: classifies
        epoch_mid = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        summary2 = rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)  # idempotent
        epoch_after = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        ok = (summary2["backfilled_rooms"] == 0
              and summary2["rebroadcast_rooms"] == 0
              and epoch_after == epoch_mid)
        check("no_change_no_bump", ok,
              f"summary2={summary2} epoch {epoch_mid}->{epoch_after}")
    finally:
        conn.close()


def test_enqueue_failure_rolls_back_bit_and_retries() -> None:
    """codex r1: if enqueue_roster_broadcast raises, the admin bit UPDATE must
    ROLL BACK (stay -1) so the NEXT tick re-detects the change and retries — never
    leave a corrected-but-never-broadcast bit (the lost-rebroadcast gap)."""
    _set_admin("patchy")
    db = _fresh_db()
    conn = rooms.open_rooms()
    real_enqueue = rooms.enqueue_roster_broadcast
    try:
        _seed_room(conn, "r1", "patchy", "nodeA")
        _seed_member(conn, "r1", "patchy", "nodeA", role="leader")  # admin, -1
        _seed_member(conn, "r1", "remoteguy", "nodeB")              # remote target
        cfg = {"bridge_id": "nodeA"}

        # Inject a transient enqueue failure for the FIRST attempt.
        def boom(*a, **k):
            raise sqlite3.OperationalError("simulated transient enqueue failure")
        rooms.enqueue_roster_broadcast = boom
        raised = False
        try:
            rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)
        except sqlite3.OperationalError:
            raised = True
        # The bit must have ROLLED BACK to -1 (NOT durably written to 1), and the
        # epoch must NOT have advanced, and NO outbox row may exist.
        bit_after_fail = _member_admin(conn, "r1", "patchy", "nodeA")
        epoch_after_fail = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        try:
            outbox_after_fail = conn.execute(
                "SELECT COUNT(*) c FROM room_roster_outbox WHERE room_id='r1'"
            ).fetchone()["c"]
        except sqlite3.OperationalError:
            outbox_after_fail = 0
        rolled_back = (raised
                       and bit_after_fail == rooms.ADMIN_COL_UNKNOWN
                       and epoch_after_fail == 0
                       and outbox_after_fail == 0)

        # Now the enqueue works again → the retry tick must re-apply the bit,
        # bump the epoch, and enqueue the durable outbox row (convergence is NOT
        # lost despite the earlier failure).
        rooms.enqueue_roster_broadcast = real_enqueue
        summary = rooms.reclassify_and_rebroadcast_local_admin(cfg, conn)
        bit_after_retry = _member_admin(conn, "r1", "patchy", "nodeA")
        epoch_after_retry = conn.execute(
            "SELECT epoch FROM rooms WHERE room_id='r1'").fetchone()["epoch"]
        outbox_nodes = {
            r["member_node"] for r in conn.execute(
                "SELECT member_node FROM room_roster_outbox WHERE room_id='r1' "
                "AND status='pending'").fetchall()
        }
        recovered = (summary["rebroadcast_rooms"] == 1
                     and bit_after_retry == rooms.ADMIN_COL_ADMIN
                     and epoch_after_retry == 1
                     and outbox_nodes == {"nodeB"})
        check("enqueue_failure_rolls_back_bit_and_retries",
              rolled_back and recovered,
              f"rolled_back={rolled_back} (bit={bit_after_fail} epoch={epoch_after_fail} "
              f"outbox={outbox_after_fail}) recovered={recovered} "
              f"(summary={summary} bit={bit_after_retry} epoch={epoch_after_retry} "
              f"outbox={outbox_nodes})")
    finally:
        rooms.enqueue_roster_broadcast = real_enqueue
        conn.close()


def main() -> int:
    os.environ["BRIDGE_A2A_ALLOW_TEST_BIND"] = "1"
    with tempfile.TemporaryDirectory(prefix="2109-root-") as root:
        os.environ["_2109_TMP"] = root
        # Pin BRIDGE_HOME under the temp root so the test-bind guard accepts the
        # rooms.db paths (they live under BRIDGE_HOME).
        os.environ["BRIDGE_HOME"] = root
        os.environ["BRIDGE_STATE_DIR"] = os.path.join(root, "state")
        for fn in (
            test_migrate_adds_admin_column,
            test_migrate_duplicate_rerun_noop,
            test_migrate_nonduplicate_error_reraises,
            test_backfill_local_admin_and_nonadmin,
            test_backfill_leaves_remote_rows_untouched,
            test_backfill_empty_config_leaves_unknown,
            test_backfill_corrects_stale_classification,
            test_backfill_singlenode_empty_node,
            test_leader_bumps_and_enqueues,
            test_nonleader_does_not_bump,
            test_no_change_no_bump,
            test_enqueue_failure_rolls_back_bit_and_retries,
        ):
            try:
                fn()
            except Exception as exc:  # noqa: BLE001
                check(fn.__name__, False, "UNCAUGHT:" + repr(exc))
    if _FAILURES:
        print("OVERALL FAIL: " + ", ".join(_FAILURES))
        return 1
    print("OVERALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
