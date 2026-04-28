#!/usr/bin/env python3
"""daily-note-reconcile.py — idempotent jsonl→daily-note merger.

PR-1 of 4 in the issue #390 memory-pipeline rewiring sequence.

Reads a single Claude session jsonl transcript, extracts the meaningful
conversation turns for a target date, and merges them into the agent's
daily note at ``<memory-dir>/<YYYY-MM-DD>.md`` idempotently.

The script is a thin entrypoint: callers (Stop hook in PR-2, cron payload
rewrite in PR-3, ad-hoc operator invocation) pass the jsonl path
explicitly. PR-1 does NOT discover sessions on its own.

Daily note format
-----------------
We re-use the section convention already established by
``bridge-memory.py daily-append``:

* A ``<!-- bridge-daily-meta: {...} -->`` block on line 1 (JSON meta).
* A ``# YYYY-MM-DD — <agent>`` H1 title.
* One ``## Session <session_id> — <writer>`` H2 per session.
* Below each H2 we render ``### turn <N> · <role> · <iso-ts>`` H3
  blocks holding the turn text.

Idempotency contract
--------------------
The meta block carries a ``reconciled_fingerprints`` map keyed by
session_id whose value is a list of per-turn sha1 fingerprints already
merged. On each run we recompute fingerprints from the jsonl, diff
against the manifest, and emit ONLY the new turns. Re-running with the
same (agent, jsonl, date) is a no-op (mtime may bump; content is byte
stable). A hand-edit that corrupts the manifest is tolerated — we treat
the corrupt entry as ``no fingerprints known`` and proceed; the next run
will re-stabilise.

Date interpretation
-------------------
``--date YYYY-MM-DD`` is interpreted in **UTC**. Claude session jsonl
timestamps are emitted in ISO-8601 with a ``Z`` suffix (UTC), and we
match against UTC day boundaries. Operators who want local-day boundary
behaviour pass the local day explicitly.

Turn extraction filters
-----------------------
* Include: assistant ``text`` blocks; user ``text``/``str`` content that
  is NOT one of Claude's scaffolding wrappers
  (``<local-command-…>``, ``<system-reminder>``, ``<command-name>``…).
* Exclude: assistant ``thinking`` (internal reasoning, not
  operator-visible); ``tool_use`` blocks (the operator can read the
  jsonl for tool transcripts); ``tool_result`` blocks (often huge,
  low-signal).
* Long turns are truncated to 2000 head + 500 tail with a
  ``[... truncated, see jsonl ...]`` marker.

Caller contract
---------------
* rc=0 on success (including "no turns for date" — informational).
* rc=2 on jsonl missing/unreadable, bad CLI args, or write failure.
* JSON summary on stdout when ``--json`` is set.
* ``--dry-run`` prints unified diff (or "no changes") and never writes.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import difflib
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any


DAILY_META_MARKER = "<!-- bridge-daily-meta: "
DAILY_META_END = " -->"
DAILY_META_RE = re.compile(
    r"^<!-- bridge-daily-meta: (?P<json>\{.*\}) -->\s*$",
    re.MULTILINE,
)
DAILY_SECTION_HEADER_RE = re.compile(
    r"^## Session (?P<session>[A-Za-z0-9_-]+)(?P<tail>.*)$",
    re.MULTILINE,
)

# Wrappers Claude emits for non-conversation scaffolding. These appear
# inside string user content but are not what the operator typed.
SCAFFOLDING_PREFIXES = (
    "<local-command-",
    "<system-reminder>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
)

WRITER_LABEL = "reconcile"
TURN_HEAD_LIMIT = 2000
TURN_TAIL_LIMIT = 500
TRUNCATION_MARKER = "\n\n[... truncated, see jsonl ...]\n\n"


# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------


def _eprint(verbose: bool, *parts: Any) -> None:
    if verbose:
        sys.stderr.write("[daily-note-reconcile] " + " ".join(str(p) for p in parts) + "\n")


def _today_utc() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")


def _now_iso_utc() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso_ts(raw: str) -> _dt.datetime | None:
    """Parse ISO-8601 with trailing ``Z`` (Claude jsonl convention)."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        # ``fromisoformat`` accepts ``+00:00`` but not ``Z`` until 3.11.
        norm = raw.replace("Z", "+00:00")
        ts = _dt.datetime.fromisoformat(norm)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=_dt.timezone.utc)
        return ts.astimezone(_dt.timezone.utc)
    except ValueError:
        return None


def _date_of(ts: _dt.datetime | None) -> str | None:
    if ts is None:
        return None
    return ts.strftime("%Y-%m-%d")


def _is_scaffolding(text: str) -> bool:
    s = text.lstrip()
    return any(s.startswith(p) for p in SCAFFOLDING_PREFIXES)


def _truncate(text: str) -> str:
    if len(text) <= TURN_HEAD_LIMIT + TURN_TAIL_LIMIT + len(TRUNCATION_MARKER):
        return text
    head = text[:TURN_HEAD_LIMIT].rstrip()
    tail = text[-TURN_TAIL_LIMIT:].lstrip()
    return f"{head}{TRUNCATION_MARKER}{tail}"


def _fingerprint(role: str, text: str, ts_raw: str) -> str:
    h = hashlib.sha1()
    h.update(role.encode("utf-8"))
    h.update(b"\x1f")
    h.update(text.encode("utf-8"))
    h.update(b"\x1f")
    h.update((ts_raw or "").encode("utf-8"))
    return h.hexdigest()[:16]  # 16 hex chars is plenty; keeps manifest small


# ----------------------------------------------------------------------
# jsonl extraction
# ----------------------------------------------------------------------


def extract_turns(
    jsonl_path: Path,
    target_date: str,
    verbose: bool = False,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Return (turns, session_ids_seen).

    Each turn is a dict with: ``session_id``, ``role``, ``text``,
    ``timestamp`` (raw string), ``timestamp_iso`` (parsed UTC ISO),
    ``fingerprint``.

    Malformed lines are skipped (with a warning when verbose).
    """
    turns: list[dict[str, Any]] = []
    session_ids: list[str] = []
    seen_sids: set[str] = set()

    with jsonl_path.open("r", encoding="utf-8", errors="replace") as fh:
        for lineno, raw_line in enumerate(fh, start=1):
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                rec = json.loads(raw_line)
            except json.JSONDecodeError as exc:
                _eprint(verbose, f"skip line {lineno}: {exc}")
                continue
            if not isinstance(rec, dict):
                continue

            rec_type = rec.get("type")
            if rec_type not in ("user", "assistant"):
                continue

            ts_raw = rec.get("timestamp") or ""
            ts = _parse_iso_ts(ts_raw)
            day = _date_of(ts)
            if day != target_date:
                continue

            sid = rec.get("sessionId") or ""
            if not sid:
                continue
            if sid not in seen_sids:
                seen_sids.add(sid)
                session_ids.append(sid)

            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            role = msg.get("role") or rec_type
            content = msg.get("content")

            text_chunks: list[str] = []
            if isinstance(content, str):
                if not _is_scaffolding(content):
                    text_chunks.append(content)
            elif isinstance(content, list):
                for blk in content:
                    if not isinstance(blk, dict):
                        continue
                    btype = blk.get("type")
                    if btype == "text":
                        t = blk.get("text") or ""
                        if t and not _is_scaffolding(t):
                            text_chunks.append(t)
                    # thinking, tool_use, tool_result intentionally skipped.
            if not text_chunks:
                continue

            text = "\n\n".join(c.strip() for c in text_chunks if c.strip())
            if not text:
                continue
            text = _truncate(text)

            fp = _fingerprint(role, text, ts_raw)
            turns.append({
                "session_id": sid,
                "role": role,
                "text": text,
                "timestamp": ts_raw,
                "timestamp_iso": ts.isoformat() if ts else "",
                "fingerprint": fp,
            })

    return turns, session_ids


# ----------------------------------------------------------------------
# daily note read / parse / assemble
# ----------------------------------------------------------------------


def _read_meta_block(text: str) -> tuple[dict[str, Any], str]:
    match = DAILY_META_RE.search(text)
    if not match:
        return {}, text
    try:
        meta = json.loads(match.group("json"))
    except json.JSONDecodeError:
        return {}, text
    if not isinstance(meta, dict):
        return {}, text
    start, end = match.span(0)
    remainder = text[:start] + text[end:].lstrip("\n")
    return meta, remainder


def _render_meta_block(meta: dict[str, Any]) -> str:
    return DAILY_META_MARKER + json.dumps(meta, ensure_ascii=False) + DAILY_META_END


def _split_sections(body: str) -> list[tuple[str | None, str]]:
    parts: list[tuple[str | None, str]] = []
    last_idx = 0
    last_session: str | None = None
    for match in DAILY_SECTION_HEADER_RE.finditer(body):
        if match.start() > last_idx:
            parts.append((last_session, body[last_idx:match.start()]))
        last_session = match.group("session")
        last_idx = match.start()
    parts.append((last_session, body[last_idx:]))
    return parts


def _parse_daily_note(text: str, date: str, agent: str) -> tuple[dict[str, Any], str, list[tuple[str | None, str]]]:
    meta, body = _read_meta_block(text)
    title_match = re.match(r"^\s*(#\s[^\n]+)\n?", body)
    if title_match:
        title = title_match.group(1)
        body = body[title_match.end():]
    else:
        title = f"# {date} — {agent}"
    if not meta:
        meta = {
            "schema_version": 1,
            "session_ids": [],
            "writer_mix": {},
            "reconciled_fingerprints": {},
            "last_reconciled_at": _now_iso_utc(),
        }
    sections = _split_sections(body.lstrip("\n"))
    return meta, title, sections


def _assemble_daily_note(title: str, meta: dict[str, Any], sections: list[tuple[str | None, str]]) -> str:
    chunks: list[str] = [_render_meta_block(meta), "", title.rstrip(), ""]
    rendered_preamble = False
    for session_id, text in sections:
        text = text.rstrip("\n")
        if not text.strip():
            continue
        if session_id is None and not rendered_preamble:
            chunks.append(text)
            chunks.append("")
            rendered_preamble = True
        elif session_id is not None:
            chunks.append(text)
            chunks.append("")
    return "\n".join(chunks).rstrip() + "\n"


def _render_turn_block(idx: int, turn: dict[str, Any]) -> str:
    role = turn["role"]
    ts = turn.get("timestamp_iso") or turn.get("timestamp") or ""
    body = turn["text"].rstrip()
    return f"### turn {idx} · {role} · {ts}\n\n{body}\n"


def _build_section_text(session_id: str, ordered_turns: list[dict[str, Any]]) -> str:
    header = f"## Session {session_id} — {WRITER_LABEL}"
    if not ordered_turns:
        return header + "\n"
    parts = [header, ""]
    for idx, turn in enumerate(ordered_turns, start=1):
        parts.append(_render_turn_block(idx, turn))
    return "\n".join(parts).rstrip() + "\n"


def _ensure_memory_dir(memory_dir: Path) -> None:
    memory_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(memory_dir, 0o700)
    except OSError:
        # Non-fatal — operator may have a stricter umask or readonly fs
        # in tests; the dir already exists, the reconcile can proceed.
        pass


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8",
        dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp",
        delete=False,
    )
    try:
        tmp.write(text)
        tmp.flush()
        os.fsync(tmp.fileno())
    finally:
        tmp.close()
    os.replace(tmp.name, path)


# ----------------------------------------------------------------------
# core reconcile
# ----------------------------------------------------------------------


def reconcile(
    agent: str,
    jsonl_path: Path,
    date: str,
    memory_dir: Path,
    dry_run: bool,
    verbose: bool,
) -> dict[str, Any]:
    note_path = memory_dir / f"{date}.md"

    turns, sessions_in_jsonl = extract_turns(jsonl_path, date, verbose=verbose)

    if not turns:
        sys.stderr.write(f"no turns for {date} in {jsonl_path}\n")
        return {
            "status": "ok",
            "agent": agent,
            "date": date,
            "note_path": str(note_path),
            "turns_total": 0,
            "turns_new": 0,
            "sessions": [],
            "applied": "noop",
            "dry_run": dry_run,
            "no_turns": True,
        }

    # Read existing daily note (may not exist).
    if note_path.exists():
        existing_text = note_path.read_text(encoding="utf-8")
    else:
        existing_text = ""

    if existing_text:
        meta, title, sections = _parse_daily_note(existing_text, date, agent)
    else:
        meta = {
            "schema_version": 1,
            "session_ids": [],
            "writer_mix": {},
            "reconciled_fingerprints": {},
            "last_reconciled_at": _now_iso_utc(),
        }
        title = f"# {date} — {agent}"
        sections = []

    # Tolerate corrupt manifest fields.
    raw_manifest = meta.get("reconciled_fingerprints")
    if not isinstance(raw_manifest, dict):
        _eprint(verbose, "manifest malformed — treating as empty")
        raw_manifest = {}
    manifest: dict[str, list[str]] = {}
    for k, v in raw_manifest.items():
        if isinstance(k, str) and isinstance(v, list):
            manifest[k] = [str(x) for x in v if isinstance(x, (str, int))]

    session_ids = list(meta.get("session_ids") or [])
    writer_mix = dict(meta.get("writer_mix") or {})

    # Group turns by session_id, in jsonl order.
    by_session: dict[str, list[dict[str, Any]]] = {}
    for t in turns:
        by_session.setdefault(t["session_id"], []).append(t)

    # Determine new turns per session.
    new_turn_count = 0
    sessions_summary: list[dict[str, Any]] = []
    for sid in sessions_in_jsonl:
        existing_fps = set(manifest.get(sid, []))
        session_turns = by_session.get(sid, [])
        new_turns = [t for t in session_turns if t["fingerprint"] not in existing_fps]

        if not new_turns:
            sessions_summary.append({
                "session_id": sid,
                "turns_in_jsonl": len(session_turns),
                "turns_new": 0,
            })
            continue

        # Find existing section for this session (if any) and append new
        # turn blocks. Otherwise create a new section.
        existing_section_idx: int | None = None
        for idx, (existing_sid, _text) in enumerate(sections):
            if existing_sid == sid:
                existing_section_idx = idx
                break

        if existing_section_idx is None:
            # Build full section from scratch — number turns from 1.
            section_text = _build_section_text(sid, new_turns)
            sections.append((sid, section_text))
            if sid not in session_ids:
                session_ids.append(sid)
            writer_mix[WRITER_LABEL] = writer_mix.get(WRITER_LABEL, 0) + 1
        else:
            # Count existing ### turn blocks under this section to keep
            # numbering monotonic across re-runs.
            _existing_sid, existing_text = sections[existing_section_idx]
            existing_turn_count = len(re.findall(r"^### turn \d+\s+·", existing_text, re.MULTILINE))
            appended_blocks = []
            for offset, turn in enumerate(new_turns, start=1):
                appended_blocks.append(_render_turn_block(existing_turn_count + offset, turn))
            updated_text = existing_text.rstrip("\n") + "\n\n" + "\n".join(appended_blocks).rstrip() + "\n"
            sections[existing_section_idx] = (sid, updated_text)

        # Extend the manifest.
        manifest.setdefault(sid, []).extend(t["fingerprint"] for t in new_turns)
        new_turn_count += len(new_turns)
        sessions_summary.append({
            "session_id": sid,
            "turns_in_jsonl": len(session_turns),
            "turns_new": len(new_turns),
        })

    # Update meta.
    meta["schema_version"] = meta.get("schema_version", 1)
    meta["session_ids"] = session_ids
    meta["writer_mix"] = writer_mix
    meta["reconciled_fingerprints"] = manifest
    meta["last_reconciled_at"] = _now_iso_utc()

    new_text = _assemble_daily_note(title, meta, sections)

    # Decide outcome.
    if new_turn_count == 0:
        applied = "noop"
    elif existing_text:
        applied = "updated"
    else:
        applied = "created"

    if dry_run:
        if existing_text == new_text:
            sys.stdout.write("no changes\n")
        else:
            diff = difflib.unified_diff(
                existing_text.splitlines(keepends=True),
                new_text.splitlines(keepends=True),
                fromfile=str(note_path) + ".old",
                tofile=str(note_path) + ".new",
                lineterm="",
            )
            sys.stdout.write("".join(diff))
            if not new_text.endswith("\n"):
                sys.stdout.write("\n")
        return {
            "status": "ok",
            "agent": agent,
            "date": date,
            "note_path": str(note_path),
            "turns_total": len(turns),
            "turns_new": new_turn_count,
            "sessions": sessions_summary,
            "applied": applied,
            "dry_run": True,
        }

    if applied != "noop":
        _ensure_memory_dir(memory_dir)
        _atomic_write(note_path, new_text)

    return {
        "status": "ok",
        "agent": agent,
        "date": date,
        "note_path": str(note_path),
        "turns_total": len(turns),
        "turns_new": new_turn_count,
        "sessions": sessions_summary,
        "applied": applied,
        "dry_run": False,
    }


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------


def _resolve_memory_dir(args: argparse.Namespace) -> Path:
    if args.memory_dir:
        return Path(args.memory_dir).expanduser()
    # Default: agents/<agent>/memory/ relative to bridge home.
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    if args.transcripts_home:
        # PR #426 Track C parity: when an isolated agent's transcripts
        # live under a different home, the daily note typically lives
        # under that same home's bridge tree. Caller can override
        # explicitly via --memory-dir; this is a soft default.
        bridge_home = str(Path(args.transcripts_home).expanduser() / ".agent-bridge")
    return Path(bridge_home) / "agents" / args.agent / "memory"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="daily-note-reconcile.py",
        description=(
            "Idempotent jsonl→daily-note merger. "
            "PR-1 of 4 in the issue #390 memory-pipeline rewiring."
        ),
    )
    parser.add_argument("--agent", required=True, help="Agent id (matches bridge runtime).")
    parser.add_argument("--jsonl", required=True, help="Path to a Claude session jsonl.")
    parser.add_argument(
        "--date",
        default=None,
        help="Target date YYYY-MM-DD (UTC). Default: today (UTC).",
    )
    parser.add_argument(
        "--memory-dir",
        default=None,
        help="Daily-note directory. Default: <BRIDGE_HOME>/agents/<agent>/memory/.",
    )
    parser.add_argument(
        "--transcripts-home",
        default=None,
        help="Optional isolated home root (PR #426 Track C). Used to derive a default memory dir; ignored if --memory-dir is set.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print diff/no-changes instead of writing.")
    parser.add_argument("--verbose", action="store_true", help="Debug breadcrumbs to stderr.")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary on stdout.")

    args = parser.parse_args(argv)

    if not args.agent.strip():
        sys.stderr.write("agent name is empty\n")
        return 2

    date = args.date or _today_utc()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        sys.stderr.write(f"invalid --date {date!r} (expected YYYY-MM-DD)\n")
        return 2

    jsonl_path = Path(args.jsonl).expanduser()
    if not jsonl_path.exists():
        sys.stderr.write(f"jsonl not found: {jsonl_path}\n")
        return 2
    if not jsonl_path.is_file():
        sys.stderr.write(f"jsonl is not a file: {jsonl_path}\n")
        return 2
    try:
        # Touch readability without slurping the whole file.
        with jsonl_path.open("rb") as _probe:
            _probe.read(1)
    except OSError:
        # Do NOT echo the path beyond this — minimal info leak.
        sys.stderr.write("jsonl unreadable\n")
        return 2

    memory_dir = _resolve_memory_dir(args)

    try:
        result = reconcile(
            agent=args.agent,
            jsonl_path=jsonl_path,
            date=date,
            memory_dir=memory_dir,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )
    except OSError as exc:
        sys.stderr.write(f"reconcile write failed: {exc}\n")
        return 2

    if args.json:
        sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(
            f"{result['applied']} agent={result['agent']} date={result['date']} "
            f"turns_new={result['turns_new']} note={result['note_path']}\n"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
