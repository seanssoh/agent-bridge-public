#!/usr/bin/env bash
# scripts/smoke/a2a-backpressure-openonly.sh
#
# Issues #10222/#10237: A2A inbound/outbound audit fixes. Pins the B1-B8
# invariants: open-only backpressure, pending-row idempotency, safe staging
# cleanup, outbox body cleanup, dedupe pruning, receiver hardening knobs, and
# Retry-After floor semantics.

set -euo pipefail

SMOKE_NAME="a2a-backpressure-openonly"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_unit() {
  python3 - "$SMOKE_REPO_ROOT" <<'PY'
from __future__ import annotations

import argparse
import importlib.util
import os
import random
import socket
import sqlite3
import sys
import time
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo))

spec = importlib.util.spec_from_file_location("bridge_handoffd", repo / "bridge-handoffd.py")
handoffd = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(handoffd)

spec_a2a = importlib.util.spec_from_file_location("bridge_a2a_cli", repo / "bridge-a2a.py")
bridge_a2a = importlib.util.module_from_spec(spec_a2a)
assert spec_a2a.loader is not None
spec_a2a.loader.exec_module(bridge_a2a)

import bridge_a2a_common as a2a  # noqa: E402

peer = "cm-prod-agentworkflow-vm01"
other_peer = "choi-mac"
now = a2a.now_ts()

a2a.ensure_handoff_dirs()
inbox = a2a.open_inbox()


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected}, got {actual}")


def dedupe(
    peer_id: str,
    message_id: str,
    task_id: int | str | None,
    *,
    first_seen: int | None = None,
    last_seen: int | None = None,
    body_hash: str = "0" * 64,
) -> None:
    inbox.execute(
        "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
        "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
        "VALUES (?, ?, ?, ?, ?, ?, 1)",
        (
            message_id,
            peer_id,
            body_hash,
            None if task_id is None else str(task_id),
            now if first_seen is None else first_seen,
            now if last_seen is None else last_seen,
        ),
    )
    inbox.commit()


def fake_handler() -> tuple[object, list[tuple[int, dict[str, object], dict[str, str]]]]:
    handler = object.__new__(handoffd.HandoffHandler)
    replies: list[tuple[int, dict[str, object], dict[str, str]]] = []
    handler._reply = lambda status, payload, extra_headers=None: replies.append(  # type: ignore[method-assign]
        (status, payload, extra_headers or {})
    )
    return handler, replies


# Fresh receiver startup before tasks.db exists: no historical capacity usage.
expect("missing task db", handoffd.count_open_remote_tasks(inbox, peer), 0)

task_db = Path(os.environ["BRIDGE_TASK_DB"])
task_db.parent.mkdir(parents=True, exist_ok=True)
sqlite3.connect(task_db).close()
expect("missing tasks table", handoffd.count_open_remote_tasks(inbox, peer), 0)

q = sqlite3.connect(task_db)
q.execute(
    "CREATE TABLE tasks("
    "id INTEGER PRIMARY KEY, status TEXT NOT NULL, created_by TEXT, "
    "created_ts INTEGER, body_text TEXT, body_path TEXT)"
)
q.executemany(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    [
        (1, "done", f"a2a:{peer}:agent", now, "", None),
        (2, "cancelled", f"a2a:{peer}:agent", now, "", None),
        (3, "done", f"a2a:{peer}:agent", now, "", None),
        (4, "queued", f"a2a:{peer}:agent", now, "", None),
        (5, "cancelled", f"a2a:{peer}:agent", now, "", None),
        (6, "claimed", f"a2a:{peer}:agent", now, "", None),
        (7, "blocked", f"a2a:{peer}:agent", now, "", None),
        (8, "queued", f"a2a:{other_peer}:agent", now, "", None),
    ],
)
q.commit()
q.close()

# All-time rows exceed the cap shape, but closed/missing/non-open rows do not
# consume current capacity.
dedupe(peer, "closed-1", 1)
dedupe(peer, "closed-2", 2)
dedupe(peer, "closed-3", 3)
dedupe(peer, "open-queued", 4)
dedupe(peer, "not-open-status", 5)
dedupe(peer, "deleted-task", 9999)
dedupe(
    peer,
    "stale-control-row-null-task",
    None,
    first_seen=now - handoffd.pending_retry_seconds() - 10,
    last_seen=now - handoffd.pending_retry_seconds() - 10,
    body_hash="e" * 64,
)
dedupe(other_peer, "other-peer-open", 8)
expect("all-time rows with one open task", handoffd.count_open_remote_tasks(inbox, peer), 1)

max_open = 3
if handoffd.count_open_remote_tasks(inbox, peer) >= max_open:
    raise AssertionError("historical closed rows would still reject below OPEN cap")

# Duplicate ledger rows pointing at the same task must not double-count.
dedupe(peer, "same-task-second-message", 4)
expect("same task counted once", handoffd.count_open_remote_tasks(inbox, peer), 1)

# BLOCK-1: the production call happens while the inbox connection holds
# BEGIN IMMEDIATE. Counting must not ATTACH/DETACH on that transaction.
inbox.execute("BEGIN IMMEDIATE")
try:
    expect(
        "count works while inbox write transaction is open",
        handoffd.count_open_remote_tasks(inbox, peer),
        1,
    )
finally:
    inbox.rollback()

# Once current OPEN tasks reach the cap, the receiver should reject.
dedupe(peer, "open-claimed", 6)
dedupe(peer, "open-blocked", 7)
open_count = handoffd.count_open_remote_tasks(inbox, peer)
expect("queued/claimed/blocked are open", open_count, 3)
if open_count < max_open:
    raise AssertionError("OPEN rows at cap would fail to reject")

expect("other peer scoped independently", handoffd.count_open_remote_tasks(inbox, other_peer), 1)

pending_peer = "pending-peer"
dedupe(pending_peer, "fresh-pending", None)
expect("fresh pending row reserves capacity", handoffd.count_open_remote_tasks(inbox, pending_peer), 1)
inbox.execute(
    "UPDATE inbox_dedupe SET last_seen_ts=? WHERE peer=? AND message_id=?",
    (now - handoffd.pending_retry_seconds() - 10, pending_peer, "fresh-pending"),
)
inbox.commit()
expect("stale pending row stops reserving capacity", handoffd.count_open_remote_tasks(inbox, pending_peer), 0)

# M3: stale-pending retries re-enter the same gates as a new enqueue.
stale_backpressure_msg = "stale-backpressure-gate"
dedupe(
    peer,
    stale_backpressure_msg,
    None,
    first_seen=now - handoffd.pending_retry_seconds() - 10,
    last_seen=now - handoffd.pending_retry_seconds() - 10,
    body_hash="e" * 64,
)
handler, replies = fake_handler()
handler._handle_dedupe_and_enqueue(
    {},
    {"id": peer, "caps": {"max_open_tasks": max_open}},
    {
        "message_id": stale_backpressure_msg,
        "sender": {"bridge": peer, "agent": "agent"},
        "target_agent": "target",
        "priority": "normal",
        "title": "stale cap",
        "body": "body",
    },
    "e" * 64,
    "127.0.0.1",
)
expect("stale pending backpressure gate response count", len(replies), 1)
expect("stale pending backpressure gate", replies[0][0], 429)

stale_room_msg = "stale-room-gate"
dedupe(
    peer,
    stale_room_msg,
    None,
    first_seen=now - handoffd.pending_retry_seconds() - 10,
    last_seen=now - handoffd.pending_retry_seconds() - 10,
    body_hash="d" * 64,
)
old_room_scoped_check = handoffd.room_scoped_check
handoffd.room_scoped_check = lambda _env, _cfg: (False, "unit-deny")  # type: ignore[assignment]
handler, replies = fake_handler()
try:
    handler._handle_dedupe_and_enqueue(
        {},
        {"id": peer},
        {
            "message_id": stale_room_msg,
            "sender": {"bridge": peer, "agent": "agent"},
            "target_agent": "target",
            "priority": "normal",
            "title": "stale room",
            "body": "body",
        },
        "d" * 64,
        "127.0.0.1",
    )
finally:
    handoffd.room_scoped_check = old_room_scoped_check  # type: ignore[assignment]
expect("stale pending room gate response count", len(replies), 1)
expect("stale pending room gate", replies[0][0], 403)

# M1: corrupt tasks.db on a capped path is a retryable 503, not a generic 500.
corrupt_task_db = task_db.parent / "corrupt-tasks.db"
corrupt_task_db.write_text("not sqlite", encoding="utf-8")
corrupt_peer = "corrupt-peer"
dedupe(corrupt_peer, "corrupt-open-row", 123)
old_task_db_env = os.environ["BRIDGE_TASK_DB"]
os.environ["BRIDGE_TASK_DB"] = str(corrupt_task_db)
handler, replies = fake_handler()
try:
    handler._handle_dedupe_and_enqueue(
        {},
        {"id": corrupt_peer, "caps": {"max_open_tasks": 1}},
        {
            "message_id": "corrupt-new",
            "sender": {"bridge": corrupt_peer, "agent": "agent"},
            "target_agent": "target",
            "priority": "normal",
            "title": "corrupt",
            "body": "body",
        },
        "f" * 64,
        "127.0.0.1",
    )
finally:
    os.environ["BRIDGE_TASK_DB"] = old_task_db_env
expect("corrupt tasks db response count", len(replies), 1)
expect("corrupt tasks db maps to retryable 503", replies[0][0], 503)
expect("corrupt tasks db carries Retry-After", replies[0][2].get("Retry-After"), "30")

# B3: pending dedupe rows recover an already-created task by the provenance
# marker instead of enqueueing a duplicate after a crash before final UPDATE.
recover_msg = "pending-recover"
recover_body = "\n".join([
    "<!-- A2A cross-bridge handoff — provenance -->",
    f"remote peer  : {peer}",
    "remote agent : agent",
    f"message id   : {recover_msg}",
    "",
])
q = sqlite3.connect(task_db)
q.execute(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    (42, "queued", f"a2a:{peer}:agent", now, recover_body, None),
)
q.commit()
q.close()
dedupe(peer, recover_msg, None, first_seen=now - 999, last_seen=now - 999)
expect(
    "pending row recovers existing task id",
    handoffd.recover_task_id_for_message(peer, recover_msg, first_seen_ts=now - 999),
    "42",
)

mismatch_sender = "sender-bridge-not-peer-id"
mismatch_msg = "pending-recover-sender-mismatch"
mismatch_body = "\n".join([
    "<!-- A2A cross-bridge handoff — provenance -->",
    f"remote peer  : {mismatch_sender}",
    "remote agent : agent",
    f"message id   : {mismatch_msg}",
    "",
])
q = sqlite3.connect(task_db)
q.execute(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    (44, "queued", f"a2a:{mismatch_sender}:agent", now, mismatch_body, None),
)
q.commit()
q.close()
expect(
    "pending recovery follows sender.bridge created_by prefix",
    handoffd.recover_task_id_for_message(
        peer, mismatch_msg, sender_bridge=mismatch_sender, first_seen_ts=now - 999
    ),
    "44",
)

# B4: inbound incoming/ files are promoted to durable queue/bodies before the
# transient incoming copy is unlinked; the reaper skips task-referenced legacy
# incoming files but removes unreferenced old ones.
large_text = "x" * (1024 * 1024 + 17)
staged = handoffd.stage_inbound_body(peer, "large-body", large_text)
durable = handoffd.promote_inbound_body_to_queue(staged)
if durable.read_text(encoding="utf-8") != large_text:
    raise AssertionError("promoted queue body content mismatch")
handoffd.cleanup_incoming_staged_body(staged)
if staged.exists():
    raise AssertionError("incoming staged copy was not removed")
if not durable.is_file():
    raise AssertionError("durable queue body copy was removed")

referenced_old = a2a.incoming_dir() / "referenced-old.md"
unreferenced_old = a2a.incoming_dir() / "unreferenced-old.md"
referenced_old.write_text("keep", encoding="utf-8")
unreferenced_old.write_text("delete", encoding="utf-8")
old_ts = now - 86400 * 3
os.utime(referenced_old, (old_ts, old_ts))
os.utime(unreferenced_old, (old_ts, old_ts))
q = sqlite3.connect(task_db)
q.execute(
    "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
    "VALUES (?, ?, ?, ?, ?, ?)",
    (43, "done", f"a2a:{peer}:agent", now, None, str(referenced_old)),
)
q.commit()
q.close()
expect("incoming reaper removed one file", handoffd.reap_unreferenced_incoming_staged_bodies(1), 1)
if not referenced_old.exists() or unreferenced_old.exists():
    raise AssertionError("incoming reaper reference guard failed")

# M2: if the incoming dir is reached through a symlink/non-canonical path but
# tasks.db stores the resolved body_path, the reaper must still keep the file.
real_incoming = a2a.incoming_dir()
linked_incoming = a2a.state_dir() / "incoming-link"
try:
    linked_incoming.symlink_to(real_incoming, target_is_directory=True)
except FileExistsError:
    pass
old_incoming_dir = a2a.incoming_dir
try:
    a2a.incoming_dir = lambda: linked_incoming  # type: ignore[assignment]
    linked_referenced = linked_incoming / "linked-referenced-old.md"
    linked_unreferenced = linked_incoming / "linked-unreferenced-old.md"
    linked_referenced.write_text("keep via symlink", encoding="utf-8")
    linked_unreferenced.write_text("delete via symlink", encoding="utf-8")
    os.utime(linked_referenced, (old_ts, old_ts))
    os.utime(linked_unreferenced, (old_ts, old_ts))
    q = sqlite3.connect(task_db)
    q.execute(
        "INSERT INTO tasks(id, status, created_by, created_ts, body_text, body_path) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (45, "done", f"a2a:{peer}:agent", now, None, str(linked_referenced.resolve())),
    )
    q.commit()
    q.close()
    expect(
        "incoming symlink reaper removed only unreferenced file",
        handoffd.reap_unreferenced_incoming_staged_bodies(1),
        1,
    )
    if not linked_referenced.exists() or linked_unreferenced.exists():
        raise AssertionError("incoming symlink reaper canonical guard failed")
finally:
    a2a.incoming_dir = old_incoming_dir  # type: ignore[assignment]

# B6: shared dedupe pruning keeps age-based GC and enforces a per-peer row cap.
cap_db = sqlite3.connect(":memory:")
cap_db.row_factory = sqlite3.Row
cap_db.executescript(a2a._INBOX_SCHEMA)
for i in range(5):
    cap_db.execute(
        "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, created_task_id, "
        "first_seen_ts, last_seen_ts, delivery_count) VALUES (?, ?, ?, NULL, ?, ?, 1)",
        (f"cap-{i}", "cap-peer", "1" * 64, now + i, now + i),
    )
age_removed, cap_removed = a2a.prune_inbox_dedupe(cap_db, max_age=0, max_rows_per_peer=2)
expect("per-peer cap exact removal", cap_removed, 3)
expect("per-peer cap no age removal", age_removed, 0)
remaining = cap_db.execute(
    "SELECT COUNT(*) AS n FROM inbox_dedupe WHERE peer='cap-peer'"
).fetchone()["n"]
expect("per-peer cap remaining rows", remaining, 2)
cap_db.close()

# B7: receiver hardening knobs are applied without trusting malformed config.
server = handoffd.HandoffServer(
    ("127.0.0.1", 0),
    handoffd.HandoffHandler,
    {"listen": {"request_timeout_seconds": "0.25", "max_concurrent_requests": "2"}},
)
try:
    expect("server request timeout config", server.request_timeout_seconds, 0.25)
    expect("server concurrency config", server.max_concurrent_requests, 2)
finally:
    server.server_close()
server = handoffd.HandoffServer(
    ("127.0.0.1", 0),
    handoffd.HandoffHandler,
    {"listen": {"request_timeout_seconds": "bad", "max_concurrent_requests": "bad"}},
)
try:
    expect("server malformed timeout fallback", server.request_timeout_seconds, handoffd.DEFAULT_REQUEST_TIMEOUT_SECONDS)
    expect("server malformed concurrency fallback", server.max_concurrent_requests, handoffd.DEFAULT_MAX_CONCURRENT_REQUESTS)
finally:
    server.server_close()

left, right = socket.socketpair()
try:
    reader = handoffd.RequestDeadlineReader(left, time.monotonic() + 0.05)
    right.sendall(b"POST")
    try:
        reader.readline(65537)
        raise AssertionError("slow header reader did not enforce total deadline")
    except socket.timeout:
        pass
finally:
    left.close()
    right.close()

# B5/B8: the acked transition unlinks the outgoing envelope; dead-letter now
# PRESERVES it (#1618: a `dead` row is operator-retryable, so the body must
# survive for `agb a2a outbox retry`); gc unlinks deleted terminal rows
# (acked AND dead); and Retry-After remains a floor after jitter.
outbox = a2a.open_outbox()
cfg = {
    "bridge_id": "local",
    "peers": [{
        "id": "remote",
        "address": "127.0.0.1",
        "port": 8787,
        "secret": "s" * 32,
    }],
}
ack_path = a2a.outgoing_dir() / "ack.json"
ack_path.write_text("{}", encoding="utf-8")
a2a.outbox_insert(
    outbox,
    message_id="ack-msg",
    peer="remote",
    target_agent="agent",
    priority="normal",
    title="ack",
    body_path=str(ack_path),
    body_sha256_hex=a2a.body_sha256(b"{}"),
    body_bytes=2,
)
row = outbox.execute("SELECT * FROM outbox WHERE message_id='ack-msg'").fetchone()
old_post = bridge_a2a._post_envelope
bridge_a2a._post_envelope = lambda **_kwargs: (200, {}, b'{"task_id":"777"}')
try:
    expect("deliver ack result", bridge_a2a._deliver_one(outbox, cfg, row, timeout=1), "acked(task=777)")
finally:
    bridge_a2a._post_envelope = old_post
if ack_path.exists():
    raise AssertionError("acked outbox body was not unlinked")

dead_path = a2a.outgoing_dir() / "dead.json"
dead_path.write_text("{}", encoding="utf-8")
a2a.outbox_insert(
    outbox,
    message_id="dead-msg",
    peer="remote",
    target_agent="agent",
    priority="normal",
    title="dead",
    body_path=str(dead_path),
    body_sha256_hex=a2a.body_sha256(b"{}"),
    body_bytes=2,
)
bridge_a2a._mark_dead(outbox, "dead-msg", "unit dead")
# #1618: dead-letter must PRESERVE the staged body so a manual `outbox retry`
# can actually resend the row (the prior code unlinked it here, so retry
# re-dead-lettered as dead(nobody)). gc/drop reclaim the dead body instead.
if not dead_path.exists():
    raise AssertionError("dead outbox body was unlinked (must be preserved for retry, #1618)")
# And gc must still reclaim the dead row's body once it ages past the cutoff.
outbox.execute(
    "UPDATE outbox SET updated_ts=? WHERE message_id='dead-msg'",
    (now - 100,),
)
outbox.commit()
bridge_a2a.cmd_outbox(argparse.Namespace(action="gc", message_id=None, json=False, max_age=1))
if dead_path.exists():
    raise AssertionError("outbox gc did not reclaim the aged dead body")

gc_path = a2a.outgoing_dir() / "gc.json"
gc_path.write_text("{}", encoding="utf-8")
a2a.outbox_insert(
    outbox,
    message_id="gc-msg",
    peer="remote",
    target_agent="agent",
    priority="normal",
    title="gc",
    body_path=str(gc_path),
    body_sha256_hex=a2a.body_sha256(b"{}"),
    body_bytes=2,
)
outbox.execute(
    "UPDATE outbox SET status='acked', updated_ts=? WHERE message_id='gc-msg'",
    (now - 100,),
)
outbox.commit()
bridge_a2a.cmd_outbox(argparse.Namespace(action="gc", message_id=None, json=False, max_age=1))
if gc_path.exists():
    raise AssertionError("outbox gc did not unlink terminal body")

retry_path = a2a.outgoing_dir() / "retry.json"
retry_path.write_text("{}", encoding="utf-8")
a2a.outbox_insert(
    outbox,
    message_id="retry-msg",
    peer="remote",
    target_agent="agent",
    priority="normal",
    title="retry",
    body_path=str(retry_path),
    body_sha256_hex=a2a.body_sha256(b"{}"),
    body_bytes=2,
)
old_random = random.random
random.random = lambda: 0.0
try:
    before = a2a.now_ts()
    bridge_a2a._schedule_retry(
        outbox,
        "retry-msg",
        1,
        {"delivery_max_attempts": 12},
        "unit retry",
        retry_after="300",
    )
finally:
    random.random = old_random
next_attempt = outbox.execute(
    "SELECT next_attempt_ts FROM outbox WHERE message_id='retry-msg'"
).fetchone()["next_attempt_ts"]
if next_attempt < before + 300:
    raise AssertionError("Retry-After floor was undercut by jitter")
outbox.close()
inbox.close()
PY
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "A2A audit B1-B8 invariants" run_unit
  smoke_log "passed"
}

main "$@"
