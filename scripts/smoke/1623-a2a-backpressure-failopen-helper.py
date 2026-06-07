from __future__ import annotations

import importlib.util
import os
import sqlite3
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo))

spec = importlib.util.spec_from_file_location("bridge_handoffd", repo / "bridge-handoffd.py")
handoffd = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(handoffd)

import bridge_a2a_common as a2a  # noqa: E402

peer = "sean-macmini-m4"
now = a2a.now_ts()

a2a.ensure_handoff_dirs()
inbox = a2a.open_inbox()


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected}, got {actual}")


def dedupe(peer_id: str, message_id: str, task_id: int | str | None) -> None:
    inbox.execute(
        "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
        "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
        "VALUES (?, ?, ?, ?, ?, ?, 1)",
        (
            message_id,
            peer_id,
            "0" * 64,
            None if task_id is None else str(task_id),
            now,
            now,
        ),
    )
    inbox.commit()


def fake_handler():
    handler = object.__new__(handoffd.HandoffHandler)
    replies: list[tuple[int, dict[str, object], dict[str, str]]] = []
    handler._reply = lambda status, payload, extra_headers=None: replies.append(  # type: ignore[method-assign]
        (status, payload, extra_headers or {})
    )
    return handler, replies


def drive(message_id: str, body_hash: str, caps: dict[str, object] | None):
    """Run _handle_dedupe_and_enqueue capturing audits + replies.

    enqueue_via_bridge_task is stubbed to a deterministic success so the accept
    path does not depend on a real bridge-task subprocess. room_scoped_check is
    forced to pass (P1a default) so only the backpressure branch is exercised.
    """
    audit_events: list[tuple[str, dict[str, object]]] = []
    old_audit = handoffd.audit
    old_enqueue = handoffd.enqueue_via_bridge_task
    old_room = handoffd.room_scoped_check
    handoffd.audit = lambda event, **fields: audit_events.append((event, fields))  # type: ignore[assignment]
    handoffd.enqueue_via_bridge_task = lambda **_kwargs: (True, "8801", "", "")  # type: ignore[assignment]
    handoffd.room_scoped_check = lambda _env, _cfg: (True, "")  # type: ignore[assignment]
    handler, replies = fake_handler()
    try:
        handler._handle_dedupe_and_enqueue(
            {},
            {"id": peer, "caps": caps} if caps is not None else {"id": peer},
            {
                "message_id": message_id,
                "sender": {"bridge": peer, "agent": "agent"},
                "target_agent": "target",
                "priority": "normal",
                "title": "t",
                "body": "body",
            },
            body_hash,
            "127.0.0.1",
        )
    finally:
        handoffd.audit = old_audit  # type: ignore[assignment]
        handoffd.enqueue_via_bridge_task = old_enqueue  # type: ignore[assignment]
        handoffd.room_scoped_check = old_room  # type: ignore[assignment]
    return replies, [ev for ev, _ in audit_events]


task_db = Path(os.environ["BRIDGE_TASK_DB"])
task_db.parent.mkdir(parents=True, exist_ok=True)

# Build a real WAL-mode tasks.db with one OPEN remote task for this peer.
q = sqlite3.connect(task_db)
q.execute("PRAGMA journal_mode=WAL")
q.execute(
    "CREATE TABLE tasks("
    "id INTEGER PRIMARY KEY, status TEXT NOT NULL, created_by TEXT, "
    "created_ts INTEGER, body_text TEXT, body_path TEXT)"
)
q.execute(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    (1, "queued", f"a2a:{peer}:agent", now, "", None),
)
q.commit()
q.close()
dedupe(peer, "open-1", 1)

# --- Secondary hardening: read-only open of a WAL tasks.db must not raise
# "unable to open database file" across daemon write/idle cycles. ---
expect("WAL read-only count idle", handoffd.count_open_remote_tasks(inbox, peer), 1)
writer = sqlite3.connect(task_db)
writer.execute("PRAGMA journal_mode=WAL")
writer.execute("BEGIN IMMEDIATE")
writer.execute(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    (2, "done", f"a2a:{peer}:agent", now, "", None),
)
# Hold the writer open (daemon-mid-write window) and re-count read-only.
expect("WAL read-only count during concurrent write", handoffd.count_open_remote_tasks(inbox, peer), 1)
writer.commit()
writer.close()
expect("WAL read-only count after write", handoffd.count_open_remote_tasks(inbox, peer), 1)

# The query_only fallback must keep READ-ONLY intent: a write must raise, and
# the fallback (mode=rw, never mode=rwc) must NOT create a missing tasks.db.
ro_conn = handoffd._open_queue_db_readonly(task_db)
try:
    try:
        ro_conn.execute(
            "INSERT INTO tasks(id, status, created_by, created_ts, body_text, "
            "body_path) VALUES (9999, 'queued', 'x', 0, '', NULL)"
        )
        raise AssertionError("read-only open allowed a write to tasks.db")
    except sqlite3.OperationalError:
        pass  # query_only / mode=ro both reject writes with OperationalError
finally:
    ro_conn.close()

missing_db = task_db.parent / "does-not-exist.db"
try:
    handoffd._open_queue_db_readonly(missing_db).close()
    raise AssertionError("read-only open created a missing tasks.db (mode=rwc?)")
except sqlite3.OperationalError:
    pass
if missing_db.exists():
    raise AssertionError("read-only open created the missing db file on disk")

# --- (a) Count RAISES -> FAIL OPEN: accept (200) + backpressure_count_skip,
#         NOT 503. ---
old_count = handoffd.count_open_remote_tasks


def _raise_count(_conn, _peer):
    raise sqlite3.OperationalError("unable to open database file")


handoffd.count_open_remote_tasks = _raise_count  # type: ignore[assignment]
try:
    replies, events = drive("count-raises", "a" * 64, {"max_open_tasks": 1})
finally:
    handoffd.count_open_remote_tasks = old_count  # type: ignore[assignment]
expect("count-raises reply count", len(replies), 1)
expect("count-raises fails OPEN (accept, not 503)", replies[0][0], 200)
expect("count-raises accepted task id", replies[0][1].get("task_id"), "8801")
if "backpressure_count_skip" not in events:
    raise AssertionError("count-raises did not emit backpressure_count_skip audit")
if "backpressure_count_fail" in events:
    raise AssertionError("count-raises still emitted the old fail-closed audit")

# --- (b) Genuine over-cap -> 429 reject (unchanged). ---
# One OPEN task already exists for this peer (id=1); cap of 1 means at-capacity.
replies, events = drive("over-cap", "b" * 64, {"max_open_tasks": 1})
expect("over-cap reply count", len(replies), 1)
expect("over-cap still 429", replies[0][0], 429)
if "reject_backpressure" not in events:
    raise AssertionError("over-cap did not emit reject_backpressure audit")

# --- (c) Normal under-cap -> accept (200). ---
replies, events = drive("under-cap", "c" * 64, {"max_open_tasks": 10})
expect("under-cap reply count", len(replies), 1)
expect("under-cap accepts", replies[0][0], 200)
expect("under-cap accepted task id", replies[0][1].get("task_id"), "8801")
if "accept" not in events:
    raise AssertionError("under-cap did not emit accept audit")

inbox.close()
