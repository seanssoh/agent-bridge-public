#!/usr/bin/env python3
"""thread-recall — cross-session conversation search for the channel-owning agent.

thread-session v2, Pillar 1.

Both the main session and any thread sub-session are the SAME agent with
SEPARATE context windows. This helper lets either side search the other's
conversation history (main session jsonl + every thread session jsonl + thread
archives) so needed info can be synced on demand.

Read-only. No external transport. Scoped to the agent's OWN config dir corpus
only (never another agent's tree). Plain code — no LLM, no token cost.

Usage:
  thread_recall.py search --query "..." [--scope main|threads|all]
                          [--limit N] [--since ISO8601]
                          [--config-dir PATH] [--root PATH] [--json]

Defaults: --config-dir from $CLAUDE_CONFIG_DIR, --root from $THREAD_SESSION_ROOT
(both set in the thread-session child env), else derived from this script's path.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Iterable


# Conservative, format-specific secret redaction. A recall excerpt is echoed
# into the (child) prompt and may be posted to the public Discord thread, so a
# secret that once appeared in a past transcript line must not be re-surfaced.
# Patterns target only high-confidence credential formats so normal recall
# content (UUIDs, ids, dates, prose) is left intact. Matching/scoring runs on
# the raw text; only the displayed excerpt is redacted (so "a line exists" is
# still discoverable, the secret value is not).
_SECRET_PATTERNS = [
    (re.compile(r"\b[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}\b"), "[REDACTED:token]"),  # Discord bot token
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "[REDACTED:token]"),  # Slack
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), "[REDACTED:token]"),  # GitHub
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED:awskey]"),  # AWS access key id
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/-]{16,}=*"), r"\1 [REDACTED:token]"),  # Authorization
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "[REDACTED:privatekey]"),
    (  # KEY=secret / "secret": "..." for credential-ish key names only
        re.compile(
            r"(?i)\b([A-Za-z0-9_]*(?:token|secret|passwd|password|api[_-]?key|webhook|priv(?:ate)?[_-]?key)[A-Za-z0-9_]*)\b"
            r"\s*[:=]\s*[\"']?([A-Za-z0-9._~+/-]{8,})[\"']?"
        ),
        r"\1=[REDACTED]",
    ),
]


def redact_secrets(text: str) -> str:
    for pat, repl in _SECRET_PATTERNS:
        text = pat.sub(repl, text)
    return text


def default_config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        return Path(env)
    # scripts/ -> workdir -> agent home -> home/.claude
    return Path(__file__).resolve().parents[1].parent / "home" / ".claude"


def default_root() -> Path:
    env = os.environ.get("THREAD_SESSION_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1] / ".threads"


def load_thread_index(root: Path) -> dict[str, str]:
    """Map session_id (current + archived) -> thread_id, from the registry."""
    index: dict[str, str] = {}
    reg = root / "registry.json"
    try:
        data = json.loads(reg.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return index
    for tid, entry in (data.get("threads") or {}).items():
        sid = entry.get("session_id")
        if sid:
            index[sid] = tid
        if entry.get("initial_session_id"):
            index[entry["initial_session_id"]] = tid
        for link in entry.get("archive_chain") or []:
            for key in ("old_session_id", "new_session_id"):
                if link.get(key):
                    index[link[key]] = tid
    return index


def extract_text(obj: dict[str, Any]) -> tuple[str, str]:
    """Return (role, flattened_text) for a transcript line."""
    msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    role = msg.get("role") or obj.get("type") or "?"
    content = msg.get("content")
    if isinstance(content, str):
        return role, content
    parts: list[str] = []
    if isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                parts.append(str(c))
                continue
            ctype = c.get("type")
            if ctype == "text":
                parts.append(c.get("text", ""))
            elif ctype == "tool_use":
                parts.append(f"[tool_use:{c.get('name')}] {json.dumps(c.get('input', {}), ensure_ascii=False)[:200]}")
            elif ctype == "tool_result":
                r = c.get("content")
                if isinstance(r, list):
                    r = " ".join(x.get("text", "") if isinstance(x, dict) else str(x) for x in r)
                parts.append(f"[tool_result] {str(r)[:200]}")
    return role, " ".join(p for p in parts if p).strip()


def iter_corpus(config_dir: Path, root: Path, scope: str) -> Iterable[tuple[str, Path]]:
    """Yield (kind, jsonl_path). kind in {main, thread, archive}."""
    projects = config_dir / "projects"
    if projects.exists():
        for proj in sorted(projects.iterdir()):
            if not proj.is_dir():
                continue
            is_thread = proj.name.endswith("--threads")
            kind = "thread" if is_thread else "main"
            if scope == "main" and kind != "main":
                continue
            if scope == "threads" and kind != "thread":
                continue
            for jsonl in sorted(proj.glob("*.jsonl")):
                yield kind, jsonl
    if scope in ("threads", "all"):
        archive = root / "archive"
        if archive.exists():
            for jsonl in sorted(archive.glob("*.jsonl")):
                yield "archive", jsonl


def session_id_of(path: Path) -> str:
    # main/thread session files are named <session-id>.jsonl;
    # archives are named <session-id>-<n>.jsonl
    stem = path.stem
    return stem


def make_excerpt(text: str, tokens: list[str], width: int = 220) -> str:
    low = text.lower()
    pos = -1
    for tok in tokens:
        i = low.find(tok)
        if i >= 0 and (pos < 0 or i < pos):
            pos = i
    if pos < 0:
        return text[:width]
    start = max(0, pos - width // 3)
    snippet = text[start:start + width]
    return ("…" if start > 0 else "") + snippet.replace("\n", " ").strip()


def search(args: argparse.Namespace) -> int:
    config_dir = args.config_dir or default_config_dir()
    root = args.root or default_root()
    tokens = [t for t in args.query.lower().split() if t]
    if not tokens:
        print(json.dumps({"ok": False, "error": "empty query"}, ensure_ascii=False))
        return 1
    thread_index = load_thread_index(root)
    matches: list[dict[str, Any]] = []
    for kind, jsonl in iter_corpus(config_dir, root, args.scope):
        sid = session_id_of(jsonl)
        tid = thread_index.get(sid) or thread_index.get(sid.rsplit("-", 1)[0])
        try:
            fh = jsonl.open(encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = obj.get("timestamp") or obj.get("ts") or ""
                if args.since and ts and ts < args.since:
                    continue
                role, text = extract_text(obj)
                if not text:
                    continue
                low = text.lower()
                hit = sum(1 for tok in tokens if tok in low)
                if hit == 0:
                    continue
                freq = sum(low.count(tok) for tok in tokens)
                source = kind if kind != "thread" else (f"thread:{tid}" if tid else "thread")
                if kind == "archive":
                    source = f"archive:{tid}" if tid else "archive"
                matches.append({
                    "source": source,
                    "session_id": sid,
                    "ts": ts,
                    "role": role,
                    "score": hit,
                    "freq": freq,
                    "excerpt": redact_secrets(make_excerpt(text, tokens)),
                })
    matches.sort(key=lambda m: (m["score"], m["freq"], m["ts"]), reverse=True)
    top = matches[:args.limit]
    out = {"ok": True, "query": args.query, "scope": args.scope, "count": len(top), "total_hits": len(matches), "matches": top}
    if args.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        if not top:
            print(f"(no matches for: {args.query})")
        for m in top:
            print(f"[{m['source']} · {m['role']} · {m['ts'][:19]}] {m['excerpt']}")
        if len(matches) > len(top):
            print(f"… {len(matches) - len(top)} more (raise --limit)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Cross-session conversation search for the channel-owning agent (read-only).")
    p.add_argument("--config-dir", type=Path, default=None)
    p.add_argument("--root", type=Path, default=None)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("search")
    s.add_argument("--query", required=True)
    s.add_argument("--scope", choices=["main", "threads", "all"], default="all")
    s.add_argument("--limit", type=int, default=10)
    s.add_argument("--since", default="")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=search)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - surface as JSON, never leak a stack to a channel
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
