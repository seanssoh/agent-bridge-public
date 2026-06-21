#!/usr/bin/env python3
"""Deterministic branch seed for new thread sessions."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Iterable


TOKEN_BYTES = 4
DEFAULT_EXCHANGES = 8
DEFAULT_BYTE_CAP = 12_000
DEFAULT_TOKEN_CAP = 3_000
NO_CONTEXT_TEXT = "상속할 최근 메인 맥락 없음."

SECRET_PATTERNS = [
    (re.compile(r"\b[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}\b"), "[REDACTED:token]"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "[REDACTED:token]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), "[REDACTED:token]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED:awskey]"),
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/-]{16,}=*"), r"\1 [REDACTED:token]"),
    (re.compile(r"(?i)\b([A-Za-z0-9_]*(?:token|secret|passwd|password|api[_-]?key|webhook|private[_-]?key)[A-Za-z0-9_]*)\b\s*[:=]\s*[\"']?([A-Za-z0-9._~+/-]{8,})[\"']?"), r"\1=[REDACTED]"),
]

PII_PATTERNS = [
    (re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE), "[REDACTED:email]"),
    (re.compile(r"\b(?:\+?82[-.\s]?)?0?1[016789][-.\s]?\d{3,4}[-.\s]?\d{4}\b"), "[REDACTED:phone]"),
    (re.compile(r"\b\d{3}[-.\s]?\d{2}[-.\s]?\d{4}\b"), "[REDACTED:id]"),
    (re.compile(r"\b(?:\d[ -]*?){13,19}\b"), "[REDACTED:number]"),
]


@dataclass
class SeedResult:
    text: str
    provenance: dict[str, Any]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def default_config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1].parent / "home" / ".claude"


def redact(text: str) -> tuple[str, bool]:
    changed = False
    for pattern, repl in [*SECRET_PATTERNS, *PII_PATTERNS]:
        new = pattern.sub(repl, text)
        if new != text:
            changed = True
            text = new
    return text, changed


def iter_main_jsonl(config_dir: Path) -> Iterable[Path]:
    projects = config_dir / "projects"
    if not projects.exists():
        return
    files: list[Path] = []
    for project in projects.iterdir():
        if not project.is_dir() or project.name.endswith("--threads"):
            continue
        files.extend(p for p in project.glob("*.jsonl") if p.is_file())
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    yield from files


def flatten_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
            continue
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            parts.append(str(item.get("text") or ""))
        # tool_use/tool_result intentionally stripped.
    return " ".join(p.strip() for p in parts if p and p.strip())


def extract_role_text(row: dict[str, Any]) -> tuple[str, str, str]:
    msg = row.get("message") if isinstance(row.get("message"), dict) else {}
    role = str(msg.get("role") or row.get("type") or "?")
    text = flatten_content(msg.get("content"))
    ts = str(row.get("timestamp") or row.get("ts") or "")
    return role, text.strip(), ts


def read_recent_messages(config_dir: Path, limit: int) -> tuple[Path | None, list[dict[str, str]]]:
    for jsonl in iter_main_jsonl(config_dir):
        rows: list[dict[str, str]] = []
        try:
            lines = jsonl.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            role, text, ts = extract_role_text(obj)
            if role not in {"user", "assistant"} or not text:
                continue
            rows.append({"role": role, "text": text, "ts": ts})
            if len(rows) >= limit:
                break
        if rows:
            rows.reverse()
            return jsonl, rows
    return None, []


def cap_text(text: str, byte_cap: int, token_cap: int) -> tuple[str, bool, int]:
    cap = min(byte_cap, token_cap * TOKEN_BYTES)
    raw = text.encode("utf-8")
    if len(raw) <= cap:
        return text, False, len(raw)
    clipped = raw[:cap].decode("utf-8", errors="ignore")
    return clipped.rstrip() + "\n[TRUNCATED]", True, cap


def build_seed_context(
    *,
    config_dir: Path,
    exchanges: int = DEFAULT_EXCHANGES,
    byte_cap: int = DEFAULT_BYTE_CAP,
    token_cap: int = DEFAULT_TOKEN_CAP,
) -> SeedResult:
    source, messages = read_recent_messages(config_dir, exchanges)
    if not messages:
        provenance = {
            "seed_source": str(source) if source else "",
            "seed_range": "empty",
            "message_count": 0,
            "redaction_applied": False,
            "truncated": False,
            "generated_at": utc_now(),
        }
        return SeedResult(NO_CONTEXT_TEXT, provenance)

    redaction_applied = False
    lines = ["[Inherited recent main context]", "This is deterministic extractive context from the main Louis session."]
    for msg in messages:
        clean, changed = redact(msg["text"])
        redaction_applied = redaction_applied or changed
        ts = f" {msg['ts'][:19]}" if msg.get("ts") else ""
        lines.append(f"- {msg['role']}{ts}: {clean}")
    rendered = "\n".join(lines)
    rendered, truncated, used_bytes = cap_text(rendered, byte_cap, token_cap)
    provenance = {
        "seed_source": str(source) if source else "",
        "seed_range": f"last_{len(messages)}_messages",
        "message_count": len(messages),
        "redaction_applied": redaction_applied,
        "truncated": truncated,
        "byte_cap": byte_cap,
        "token_cap": token_cap,
        "bytes": used_bytes,
        "tool_io_stripped": True,
        "generated_at": utc_now(),
    }
    return SeedResult(rendered, provenance)


def command_build(args: argparse.Namespace) -> int:
    seed = build_seed_context(
        config_dir=args.config_dir,
        exchanges=args.exchanges,
        byte_cap=args.byte_cap,
        token_cap=args.token_cap,
    )
    if args.json:
        print(json.dumps({"ok": True, "text": seed.text, "provenance": seed.provenance}, ensure_ascii=False, sort_keys=True))
    else:
        print(seed.text)
        print("\n[Seed provenance]")
        print(json.dumps(seed.provenance, ensure_ascii=False, sort_keys=True))
    return 0


def command_selftest(_args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory(prefix="seed-context-") as tmp:
        config = Path(tmp) / ".claude"
        project = config / "projects" / "main"
        project.mkdir(parents=True)
        jsonl = project / "session.jsonl"
        rows = [
            {"timestamp": "2026-06-20T00:00:00Z", "message": {"role": "user", "content": "email a@example.com token=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
            {"timestamp": "2026-06-20T00:01:00Z", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash", "input": {"cmd": "cat secret"}}, {"type": "text", "text": "Decision kept."}]}},
        ]
        jsonl.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows), encoding="utf-8")
        seed = build_seed_context(config_dir=config, exchanges=4, byte_cap=2000, token_cap=1000)
        assert "[REDACTED:email]" in seed.text
        assert "[REDACTED:token]" in seed.text
        assert "tool_use" not in seed.text
        assert seed.provenance["redaction_applied"] is True
        empty = build_seed_context(config_dir=Path(tmp) / "empty")
        assert NO_CONTEXT_TEXT in empty.text
    print(json.dumps({"ok": True, "selftest": "passed"}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build deterministic branch seed context for a new thread session.")
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--config-dir", type=Path, default=default_config_dir())
    build.add_argument("--exchanges", type=int, default=DEFAULT_EXCHANGES)
    build.add_argument("--byte-cap", type=int, default=DEFAULT_BYTE_CAP)
    build.add_argument("--token-cap", type=int, default=DEFAULT_TOKEN_CAP)
    build.add_argument("--json", action="store_true")
    build.set_defaults(func=command_build)
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
