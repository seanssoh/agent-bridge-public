#!/usr/bin/env python3
"""bridge-audit.py — append/query structured Agent Bridge audit logs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


def rotation_limit_bytes() -> int:
    raw = os.environ.get("BRIDGE_AUDIT_ROTATE_BYTES", "").strip()
    if not raw:
        return 5 * 1024 * 1024
    try:
        value = int(raw)
    except ValueError:
        return 5 * 1024 * 1024
    return max(0, value)


def rotation_keep_files() -> int:
    raw = os.environ.get("BRIDGE_AUDIT_KEEP_FILES", "").strip()
    if not raw:
        return 30
    try:
        value = int(raw)
    except ValueError:
        return 30
    return max(1, value)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_json(text: str) -> dict[str, Any]:
    if not text:
        return {}
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise SystemExit("detail JSON must be an object")
    return payload


def parse_detail(items: list[str], detail_json: str | None) -> dict[str, Any]:
    detail = parse_json(detail_json or "")
    for item in items:
        if "=" not in item:
            raise SystemExit(f"detail must be key=value: {item}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise SystemExit(f"detail key is empty: {item}")
        detail[key] = value
    return detail


def canonical_hash_payload(payload: dict[str, Any]) -> str:
    clean = {key: value for key, value in payload.items() if key != "hash"}
    return json.dumps(clean, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def compute_hash(payload: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_hash_payload(payload).encode("utf-8")).hexdigest()


def rotation_candidates(path: Path) -> list[Path]:
    candidates: list[Path] = []
    rotated = sorted(
        path.parent.glob(f"{path.stem}.*{path.suffix}"),
        key=lambda item: item.name,
    )
    candidates.extend(rotated)
    if path.is_file():
        candidates.append(path)
    return candidates


def last_record_hash(path: Path) -> str:
    for candidate in reversed(rotation_candidates(path)):
        try:
            lines = candidate.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in reversed(lines):
            raw = raw.strip()
            if not raw:
                continue
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and isinstance(payload.get("hash"), str):
                return str(payload["hash"])
    return ""


def rotate_path(path: Path) -> None:
    limit = rotation_limit_bytes()
    if limit <= 0 or not path.exists():
        return
    try:
        current_size = path.stat().st_size
    except OSError:
        return
    if current_size < limit:
        return
    timestamp = datetime.now(timezone.utc).astimezone().strftime("%Y%m%d-%H%M%S")
    rotated = path.with_name(f"{path.stem}.{timestamp}{path.suffix}")
    try:
        path.rename(rotated)
    except OSError:
        return
    rotated_files = sorted(
        path.parent.glob(f"{path.stem}.*{path.suffix}"),
        key=lambda item: item.name,
    )
    keep = rotation_keep_files()
    excess = len(rotated_files) - keep
    for candidate in rotated_files[: max(0, excess)]:
        try:
            candidate.unlink()
        except OSError:
            continue


def append_record(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rotate_path(path)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=True) + "\n")


def cmd_write(args: argparse.Namespace) -> int:
    path = Path(args.file).expanduser()
    detail = parse_detail(args.detail, args.detail_json)
    record = {
        "ts": now_iso(),
        "actor": args.actor,
        "action": args.action,
        "target": args.target,
        "detail": detail,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "prev_hash": last_record_hash(path),
    }
    record["hash"] = compute_hash(record)
    append_record(path, record)
    if args.json:
        print(json.dumps(record, ensure_ascii=True))
    return 0


def parse_since(text: str | None) -> datetime | None:
    if not text:
        return None
    raw = text
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    parsed = datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        # Audit records are always tz-aware (see now_iso()), so a naive input
        # would TypeError on direct comparison. Assume operator-local tz so
        # `--since 2026-05-23T12:00` means 12:00 local time, matching the
        # record timestamps the operator sees in the audit log.
        local_tz = datetime.now(timezone.utc).astimezone().tzinfo
        parsed = parsed.replace(tzinfo=local_tz)
    return parsed


def iter_input_files(paths: Iterable[Path]) -> list[Path]:
    ordered: list[Path] = []
    seen: set[Path] = set()
    for base in paths:
      for candidate in rotation_candidates(base):
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            ordered.append(candidate)
    return ordered


def iter_records(paths: Iterable[Path]):
    for candidate in iter_input_files(paths):
        try:
            lines = candidate.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line_no, raw in enumerate(lines, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                yield candidate, line_no, payload


def matches_agent(record: dict[str, Any], agent: str) -> bool:
    if record.get("target") == agent:
        return True
    detail = record.get("detail")
    if not isinstance(detail, dict):
        return False
    for key in ("agent", "assigned_to", "source_agent", "target_agent"):
        if detail.get(key) == agent:
            return True
    return False


def record_matches(record: dict[str, Any], args: argparse.Namespace) -> bool:
    if args.action and record.get("action") != args.action:
        return False
    if args.actor and record.get("actor") != args.actor:
        return False
    if args.target and record.get("target") != args.target:
        return False
    if args.agent and not matches_agent(record, args.agent):
        return False
    if args.contains:
        haystack = json.dumps(record, ensure_ascii=True, sort_keys=True)
        if args.contains not in haystack:
            return False
    if args.since:
        ts = record.get("ts")
        if not isinstance(ts, str):
            return False
        try:
            ts_dt = parse_since(ts)
        except Exception:
            return False
        since_dt = parse_since(args.since)
        if since_dt is None or ts_dt is None or ts_dt < since_dt:
            return False
    return True


def emit_records(records: list[dict[str, Any]], as_json: bool) -> int:
    if as_json:
        print(json.dumps(records, ensure_ascii=True, indent=2))
        return 0
    for record in records:
        detail = record.get("detail")
        if not isinstance(detail, dict):
            detail = {}
        print(
            "\t".join(
                [
                    str(record.get("ts", "")),
                    str(record.get("actor", "")),
                    str(record.get("action", "")),
                    str(record.get("target", "")),
                    json.dumps(detail, ensure_ascii=True, sort_keys=True),
                ]
            )
        )
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    paths = [Path(item).expanduser() for item in args.file]
    records = [record for _path, _line_no, record in iter_records(paths) if record_matches(record, args)]
    limit = max(0, int(args.limit))
    if limit:
        records = records[-limit:]
    return emit_records(records, args.json)


def cmd_follow(args: argparse.Namespace) -> int:
    paths = [Path(item).expanduser() for item in args.file]
    seen: dict[str, int] = {}
    poll = max(0.2, float(args.poll_seconds))

    while True:
        emitted = False
        for candidate in iter_input_files(paths):
            key = str(candidate.resolve())
            try:
                lines = candidate.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            start = seen.get(key, 0)
            if start > len(lines):
                start = 0
            for raw in lines[start:]:
                line = raw.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or not record_matches(record, args):
                    continue
                emitted = True
                emit_records([record], args.json)
            seen[key] = len(lines)
        if not args.follow:
            return 0
        if emitted:
            sys.stdout.flush()
        time.sleep(poll)


def cmd_verify(args: argparse.Namespace) -> int:
    paths = [Path(item).expanduser() for item in args.file]
    previous_hash = ""
    checked = 0
    legacy = 0
    for source, line_no, record in iter_records(paths):
        record_hash = record.get("hash")
        prev_hash = record.get("prev_hash", "")
        if not isinstance(record_hash, str) or not isinstance(prev_hash, str):
            legacy += 1
            continue
        computed = compute_hash(record)
        if computed != record_hash:
            print(f"fail: hash mismatch at {source}:{line_no}")
            return 1
        if prev_hash != previous_hash:
            print(f"fail: chain break at {source}:{line_no}")
            return 1
        previous_hash = record_hash
        checked += 1

    if checked == 0:
        print(f"ok: no hashed audit records (legacy={legacy})")
        return 0
    print(f"ok: hash chain intact (hashed={checked}, legacy={legacy})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    write_parser = sub.add_parser("write")
    write_parser.add_argument("--file", required=True)
    write_parser.add_argument("--actor", required=True)
    write_parser.add_argument("--action", required=True)
    write_parser.add_argument("--target", required=True)
    write_parser.add_argument("--detail", action="append", default=[])
    write_parser.add_argument("--detail-json")
    write_parser.add_argument("--json", action="store_true")
    write_parser.set_defaults(handler=cmd_write)

    for name, handler in (("list", cmd_list), ("follow", cmd_follow), ("verify", cmd_verify)):
        item = sub.add_parser(name)
        item.add_argument("--file", action="append", required=True)
        if name != "verify":
            item.add_argument("--agent")
            item.add_argument("--action")
            item.add_argument("--actor")
            item.add_argument("--target")
            item.add_argument("--contains")
            item.add_argument("--since")
            item.add_argument("--limit", type=int, default=20)
            item.add_argument("--json", action="store_true")
        if name == "follow":
            item.add_argument("--follow", action="store_true")
            item.add_argument("--poll-seconds", type=float, default=1.0)
        item.set_defaults(handler=handler)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
