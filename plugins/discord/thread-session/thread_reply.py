#!/usr/bin/env python3
"""Prepare or record main-to-thread replies keyed by correlation event."""
from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, Iterator


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def default_root() -> Path:
    env = os.environ.get("THREAD_SESSION_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1] / ".threads"


def ledger_path(root: Path) -> Path:
    return root / "correlation.json"


def lock_path(root: Path) -> Path:
    return root / "correlation.lock"


def audit_path(root: Path) -> Path:
    return root / "reply.log.jsonl"


@contextlib.contextmanager
def file_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a+") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def load_ledger(root: Path) -> dict[str, Any]:
    data = json.loads(ledger_path(root).read_text(encoding="utf-8"))
    if not isinstance(data.get("events"), dict):
        raise RuntimeError("correlation ledger has no events object")
    return data


def write_ledger(root: Path, ledger: dict[str, Any]) -> None:
    ledger["updated_at"] = utc_now()
    atomic_write_json(ledger_path(root), ledger)


def append_audit(root: Path, row: dict[str, Any]) -> None:
    row = {"ts": utc_now(), **row}
    audit_path(root).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with audit_path(root).open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def find_event(events: dict[str, Any], *, event_id: str = "", task_id: int | None = None) -> tuple[str, dict[str, Any]]:
    if event_id:
        event = events.get(event_id)
        if not event:
            raise RuntimeError(f"thread event not found: {event_id}")
        return event_id, event
    if task_id is None:
        raise RuntimeError("one of --event-id or --task-id is required")
    for eid, event in events.items():
        if int(event.get("task_id") or -1) == task_id:
            return eid, event
    raise RuntimeError(f"thread event for task_id not found: {task_id}")


def read_body(args: argparse.Namespace) -> str:
    if args.body_file:
        return Path(args.body_file).expanduser().read_text(encoding="utf-8")
    return args.body or ""


def command_prepare(args: argparse.Namespace) -> int:
    root = args.root
    with file_lock(lock_path(root)):
        ledger = load_ledger(root)
        event_id, event = find_event(ledger["events"], event_id=args.event_id, task_id=args.task_id)
        target = event.get("reply_target") or {}
        if not target.get("thread_id"):
            raise RuntimeError(f"reply target missing thread_id for event {event_id}")
        body = read_body(args)
        out = {
            "ok": True,
            "event_id": event_id,
            "task_id": event.get("task_id"),
            "reply_target": target,
            "body": body,
            "status": event.get("status"),
        }
        if args.mark_sent or args.mark_failed:
            event["updated_at"] = utc_now()
            event["reply_text_sha256"] = hashlib.sha256(body.encode("utf-8")).hexdigest() if body else ""
            if args.mark_failed:
                event["status"] = "reply_failed"
                event["reply_error"] = args.error or "reply failed"
                append_audit(root, {"event": "reply_failed", "event_id": event_id, "task_id": event.get("task_id"), "error": event["reply_error"], "reply_target": target})
            else:
                event["status"] = "reply_sent"
                event["replied_at"] = utc_now()
                append_audit(root, {"event": "reply_sent", "event_id": event_id, "task_id": event.get("task_id"), "reply_target": target})
            write_ledger(root, ledger)
            out["status"] = event["status"]
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    return 0


def command_selftest(_args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory(prefix="thread-reply-") as tmp:
        root = Path(tmp) / ".threads"
        root.mkdir()
        event_id = "event1"
        atomic_write_json(
            ledger_path(root),
            {
                "schema_version": 1,
                "events": {
                    event_id: {
                        "event_id": event_id,
                        "task_id": 77,
                        "status": "queued",
                        "reply_target": {"transport": "discord", "channel_id": "thread-1", "thread_id": "thread-1"},
                    }
                },
            },
        )
        args = argparse.Namespace(root=root, event_id="", task_id=77, body="done", body_file=None, mark_sent=True, mark_failed=False, error="")
        command_prepare(args)
        ledger = load_ledger(root)
        assert ledger["events"][event_id]["status"] == "reply_sent"
        args = argparse.Namespace(root=root, event_id=event_id, task_id=None, body="fail", body_file=None, mark_sent=False, mark_failed=True, error="locked")
        command_prepare(args)
        ledger = load_ledger(root)
        assert ledger["events"][event_id]["status"] == "reply_failed"
        assert audit_path(root).exists()
    print(json.dumps({"ok": True, "selftest": "passed"}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Prepare or mark a reply to a registered thread correlation event.")
    parser.add_argument("--root", type=Path, default=default_root())
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    target = prepare.add_mutually_exclusive_group(required=True)
    target.add_argument("--event-id", default="")
    target.add_argument("--task-id", type=int)
    body = prepare.add_mutually_exclusive_group()
    body.add_argument("--body")
    body.add_argument("--body-file", type=Path)
    mark = prepare.add_mutually_exclusive_group()
    mark.add_argument("--mark-sent", action="store_true")
    mark.add_argument("--mark-failed", action="store_true")
    prepare.add_argument("--error", default="")
    prepare.set_defaults(func=command_prepare)
    selftest = sub.add_parser("selftest")
    selftest.set_defaults(func=command_selftest)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
