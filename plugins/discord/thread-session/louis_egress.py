#!/usr/bin/env python3
"""louis-egress — single-point external egress relay for the one Louis.

thread-session v2, Pillar 2 (spec: shared/reports/2026-06-20-thread-session-v2-recall-egress-spec.md).

A thread sub-session must NOT send anything outside its own thread directly
(no agent-bridge A2A, no send helpers). Instead it `queue`s a structured egress
*intent*. The main Louis session `drain`s pending intents, performs the real
external action (risk-routed), and `resolve`s each with a result. The dispatcher
primes resolved results back into the thread on its next turn (`results --ack`),
so external-bound content is always synced through the single main voice.

This solves the guard false-positive (the child never runs an external-send
command) AND lets the guard harden to deny all child transport. Plain code.

Invariant: risk=gated intents (sends / money / publish / campaign / delegation)
still require Sean/Myo approval when the main session drains them — the relay is
a mechanism, never an approval bypass.

Subcommands: queue | drain | resolve | results
Default --root from $THREAD_SESSION_ROOT, else <workdir>/.threads.
"""
from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
from typing import Any

INTENT_TYPES = ("a2a_task", "a2a_urgent", "report", "note")
RESOLVED = ("sent", "done", "rejected")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def default_root() -> Path:
    env = os.environ.get("THREAD_SESSION_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1] / ".threads"


def safe_id(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in value)[:120]


def outbox_dir(root: Path) -> Path:
    return root / "outbox"


def thread_dir(root: Path, thread_id: str) -> Path:
    return outbox_dir(root) / safe_id(thread_id)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def iter_items(root: Path, thread_id: str | None = None):
    base = outbox_dir(root)
    if not base.exists():
        return
    dirs = [thread_dir(root, thread_id)] if thread_id else sorted(p for p in base.iterdir() if p.is_dir())
    for d in dirs:
        if not d.exists():
            continue
        for f in sorted(d.glob("*.json")):
            try:
                yield f, json.loads(f.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue


def cmd_queue(args: argparse.Namespace) -> int:
    root = args.root or default_root()
    d = thread_dir(root, args.thread_id)
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Atomically reserve a unique sequence/filename via O_CREAT|O_EXCL. Two
    # concurrent queues for the same thread can otherwise compute the same seq
    # (non-atomic glob count) and clobber each other → silently dropped intents
    # (= a lost external send). O_EXCL guarantees a single owner per filename;
    # we write directly to the reserved fd, so there is no shared temp file to
    # race on either. On collision, bump seq and retry.
    seq = len(list(d.glob("*.json"))) + 1
    while True:
        item_id = f"{safe_id(args.thread_id)}-{seq:04d}"
        path = d / f"{seq:04d}-{item_id}.json"
        try:
            fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            break
        except FileExistsError:
            seq += 1
    item = {
        "id": item_id,
        "created_at": utc_now(),
        "thread_id": args.thread_id,
        "source_session_id": args.source_session_id or "",
        "intent_type": args.intent_type,
        "to": args.to or "",
        "title": args.title or "",
        "body": args.body or "",
        "risk": args.risk,
        "status": "pending",
        "result": None,
        "resolved_at": None,
        "acked": False,
    }
    try:
        os.write(fd, (json.dumps(item, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    out = {"ok": True, "queued": item_id, "path": str(path), "risk": args.risk, "status": "pending"}
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_drain(args: argparse.Namespace) -> int:
    root = args.root or default_root()
    want = args.status
    items = [it for _f, it in iter_items(root, args.thread_id) if it.get("status") == want]
    items.sort(key=lambda it: it.get("created_at", ""))
    print(json.dumps({"ok": True, "status": want, "count": len(items), "items": items}, ensure_ascii=False))
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    root = args.root or default_root()
    for f, it in iter_items(root):
        if it.get("id") == args.id:
            it["status"] = args.status
            it["result"] = args.result or ""
            it["resolved_at"] = utc_now()
            atomic_write_json(f, it)
            print(json.dumps({"ok": True, "id": args.id, "status": args.status}, ensure_ascii=False))
            return 0
    print(json.dumps({"ok": False, "error": f"intent id not found: {args.id}"}, ensure_ascii=False), file=sys.stderr)
    return 1


def cmd_results(args: argparse.Namespace) -> int:
    root = args.root or default_root()
    out: list[dict[str, Any]] = []
    to_ack: list[tuple[Path, dict[str, Any]]] = []
    for f, it in iter_items(root, args.thread_id):
        if it.get("status") not in RESOLVED:
            continue
        if args.unacked and it.get("acked"):
            continue
        out.append(it)
        to_ack.append((f, it))
    out.sort(key=lambda it: it.get("resolved_at") or "")
    if args.ack:
        for f, it in to_ack:
            it["acked"] = True
            with contextlib.suppress(OSError):
                atomic_write_json(f, it)
    print(json.dumps({"ok": True, "count": len(out), "results": out}, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="External egress relay for the one Louis (child queues, main sends).")
    p.add_argument("--root", type=Path, default=None)
    sub = p.add_subparsers(dest="command", required=True)

    q = sub.add_parser("queue", help="(child) record an external-send intent")
    q.add_argument("--thread-id", required=True)
    q.add_argument("--intent-type", required=True, choices=INTENT_TYPES)
    q.add_argument("--to", default="")
    q.add_argument("--title", default="")
    q.add_argument("--body", default="")
    q.add_argument("--risk", choices=["low", "gated"], default="low")
    q.add_argument("--source-session-id", default="")
    q.set_defaults(func=cmd_queue)

    d = sub.add_parser("drain", help="(main) list intents by status")
    d.add_argument("--thread-id", default=None)
    d.add_argument("--status", default="pending", choices=["pending", *RESOLVED])
    d.set_defaults(func=cmd_drain)

    r = sub.add_parser("resolve", help="(main) mark an intent resolved")
    r.add_argument("--id", required=True)
    r.add_argument("--status", required=True, choices=list(RESOLVED))
    r.add_argument("--result", default="")
    r.set_defaults(func=cmd_resolve)

    res = sub.add_parser("results", help="(dispatcher) resolved results for a thread to prime back")
    res.add_argument("--thread-id", required=True)
    res.add_argument("--unacked", action="store_true")
    res.add_argument("--ack", action="store_true")
    res.set_defaults(func=cmd_results)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
