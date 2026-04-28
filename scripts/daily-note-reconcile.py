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

JSON output schema (when ``--json`` is set, stdout is one parseable JSON document)
---------------------------------------------------------------------------------
``{
    "outcome": "merged" | "noop" | "dry-run" | "error",
    "agent": "<id>",
    "date": "YYYY-MM-DD",
    "session_id": "<id or empty string>",
    "jsonl": "<path>",
    "memory_dir": "<path>",
    "note_path": "<path>",
    "turns_total": <int>,           # turns extracted from jsonl matching --date
    "turns_filtered": <int>,        # turns dropped to dedupe / type-guard
    "turns_new": <int>,             # turns actually appended to the daily note
    "manifest_size_before": <int>,  # total fingerprints across all sessions
    "manifest_size_after": <int>,
    "sessions": [<per-session summary>],
    "applied": "noop" | "updated" | "created",
    "dry_run": <bool>,
    "diff": "<unified diff text or empty>",  # only populated for --dry-run
    "human_summary": "<one-line human-readable summary>",
    "warnings": ["..."],            # quarantine / type-guard / recovery breadcrumbs
    "error": "<message or null>"
}``

Concurrency safety
------------------
The read/parse/render/write cycle is wrapped in an ``fcntl.flock`` against
a sentinel file (``<memory-dir>/.daily-note-reconcile.lock``). Concurrent
invocations (cron + Stop hook + ad-hoc operator) serialise on this lock.

Path safety
-----------
``--agent`` is allowlisted to ``[A-Za-z0-9_-]{1,64}``. ``--memory-dir``
defaults to ``<BRIDGE_HOME>/agents/<agent>/memory``; if an explicit
override is provided, the resolved path MUST be inside the resolved
``BRIDGE_HOME`` (or the operator's ``--bridge-root``-equivalent default
home), otherwise the script exits with rc=2.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as _dt
import difflib
import fcntl
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
# Matches "### turn N · <role> · <iso-ts>" block headers used inside
# session sections. Captures role + timestamp so we can re-fingerprint
# body turns when the manifest is missing/corrupt (Item 1c+3b recovery).
DAILY_TURN_HEADER_RE = re.compile(
    r"^### turn (?P<idx>\d+)\s+·\s+(?P<role>[^·\n]+?)\s+·\s+(?P<ts>[^\n]*?)\s*$",
    re.MULTILINE,
)
# Quarantine block markers used when meta parsing fails or finds stray
# meta-region lines (Item 2b).
QUARANTINE_OPEN = "<!-- daily-note-reconcile-quarantine -->"
QUARANTINE_CLOSE = "<!-- /daily-note-reconcile-quarantine -->"
QUARANTINE_RE = re.compile(
    r"\n?<!-- daily-note-reconcile-quarantine -->\n(?P<body>.*?)\n<!-- /daily-note-reconcile-quarantine -->\n?",
    re.DOTALL,
)
# Allowlist for --agent (Item 6). Matches the bridge runtime's existing
# agent id convention; rejects "..", "/", whitespace, etc.
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
AGENT_ID_MAX_LEN = 64

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


def _warn(*parts: Any) -> None:
    """Always-on stderr warning (independent of --verbose)."""
    sys.stderr.write("[daily-note-reconcile] warn: " + " ".join(str(p) for p in parts) + "\n")


def _safe_str(value: Any, label: str, warnings: list[str] | None = None) -> str | None:
    """Coerce ``value`` to a string only if it is already one (Item 5a/c).

    Non-string values trigger a stderr warning and return ``None`` so the
    caller can skip the affected turn instead of crashing inside
    ``.lstrip()`` / ``.encode()``.
    """
    if value is None:
        return None
    if isinstance(value, str):
        return value
    msg = f"{label} not a string ({type(value).__name__}); skipping turn"
    _warn(msg)
    if warnings is not None:
        warnings.append(msg)
    return None


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


def _is_scaffolding(text: Any) -> bool:
    if not isinstance(text, str):
        return False
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
    h.update((role if isinstance(role, str) else "").encode("utf-8"))
    h.update(b"\x1f")
    h.update((text if isinstance(text, str) else "").encode("utf-8"))
    h.update(b"\x1f")
    h.update((ts_raw if isinstance(ts_raw, str) else "").encode("utf-8"))
    return h.hexdigest()[:16]  # 16 hex chars is plenty; keeps manifest small


# ----------------------------------------------------------------------
# jsonl extraction
# ----------------------------------------------------------------------


def extract_turns(
    jsonl_path: Path,
    target_date: str,
    verbose: bool = False,
    warnings: list[str] | None = None,
) -> tuple[list[dict[str, Any]], list[str], int]:
    """Return (turns, session_ids_seen, dropped_count).

    Each turn is a dict with: ``session_id``, ``role``, ``text``,
    ``timestamp`` (raw string), ``timestamp_iso`` (parsed UTC ISO),
    ``fingerprint``.

    ``dropped_count`` counts turns rejected by the type-guard (Item 5a/c)
    or by within-batch dedupe (Item 3c). Malformed jsonl lines are
    skipped (with a verbose-only breadcrumb).
    """
    turns: list[dict[str, Any]] = []
    session_ids: list[str] = []
    seen_sids: set[str] = set()
    seen_in_batch: set[str] = set()
    dropped = 0

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

            ts_raw_value = rec.get("timestamp")
            ts_raw = ts_raw_value if isinstance(ts_raw_value, str) else ""
            ts = _parse_iso_ts(ts_raw)
            day = _date_of(ts)
            if day != target_date:
                continue

            sid_value = rec.get("sessionId")
            sid = sid_value if isinstance(sid_value, str) else ""
            if not sid:
                continue
            if sid not in seen_sids:
                seen_sids.add(sid)
                session_ids.append(sid)

            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue

            # Item 5a/c — guard role: must be a string. If non-string,
            # warn and skip the turn instead of crashing later.
            raw_role = msg.get("role")
            if raw_role is None:
                raw_role = rec_type
            role = _safe_str(raw_role, "role", warnings)
            if role is None:
                dropped += 1
                continue

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
                        # Item 5a/c — guard text: must be a string.
                        t = _safe_str(blk.get("text"), "text", warnings)
                        if t is None:
                            dropped += 1
                            continue
                        if t and not _is_scaffolding(t):
                            text_chunks.append(t)
                    # thinking, tool_use, tool_result intentionally skipped.
            if not text_chunks:
                continue

            text = "\n\n".join(c.strip() for c in text_chunks if c.strip())
            if not text:
                continue
            text = _truncate(text)

            # Fingerprint against the SAME timestamp string the
            # renderer writes (timestamp_iso when parseable, else the
            # raw value). This keeps the manifest-recovery path
            # (Item 1c+3b) byte-stable: re-fingerprinting a rendered
            # body produces the same hash the extractor produced.
            ts_for_fp = ts.isoformat() if ts else ts_raw
            fp = _fingerprint(role, text, ts_for_fp)

            # Item 3c — dedupe within the input batch. Two records with
            # identical (role, text, ts) collapse to a single appended
            # entry; without this, a stuttered cron emit could duplicate
            # the turn N times within the same run.
            if fp in seen_in_batch:
                dropped += 1
                continue
            seen_in_batch.add(fp)

            turns.append({
                "session_id": sid,
                "role": role,
                "text": text,
                "timestamp": ts_raw,
                "timestamp_iso": ts.isoformat() if ts else "",
                "fingerprint": fp,
            })

    return turns, session_ids, dropped


# ----------------------------------------------------------------------
# daily note read / parse / assemble
# ----------------------------------------------------------------------


def _read_meta_block(text: str) -> tuple[dict[str, Any], str, list[str], bool]:
    """Parse the meta envelope.

    Returns ``(meta, remainder, quarantined_lines, meta_was_corrupt)``.

    ``quarantined_lines`` collects meta-region content that was NOT a
    parseable bridge-daily-meta envelope but appeared above the title
    (Item 2b). These are surfaced to the operator via the quarantine
    block instead of leaking into the rendered body.

    ``meta_was_corrupt`` is True when a marker was present but the JSON
    failed to parse (or wasn't a dict). The caller treats this as a
    signal that manifest recovery from the body should be attempted
    (Item 1c).
    """
    match = DAILY_META_RE.search(text)
    if match:
        raw_json = match.group("json")
        try:
            meta = json.loads(raw_json)
            meta_corrupt = False
        except json.JSONDecodeError:
            meta = None
            meta_corrupt = True
        if not isinstance(meta, dict):
            meta = None
            meta_corrupt = True

        start, end = match.span(0)
        pre = text[:start]
        post = text[end:].lstrip("\n")

        # Item 2b — anything before the (first) meta marker that isn't
        # blank is "stray meta-region content". Quarantine those lines
        # so they don't bleed into the rendered body.
        quarantined: list[str] = []
        if pre.strip():
            for line in pre.splitlines():
                if line.strip():
                    quarantined.append(line)

        if meta_corrupt:
            # Quarantine the corrupt meta marker itself so the operator
            # can recover whatever was in there if needed.
            quarantined.append(match.group(0))
            meta = {}

        return meta, post, quarantined, meta_corrupt

    # No structured match. Item 2b — fall back to a line-level scan: if
    # any line resembles a meta marker (``<!-- bridge-daily-meta:`` or
    # the closing ``-->`` after one) it failed to parse cleanly, so we
    # quarantine those lines and rebuild the envelope from scratch.
    quarantined = []
    cleaned_lines: list[str] = []
    in_meta_remnant = False
    for line in text.splitlines(keepends=True):
        bare = line.rstrip("\n")
        if bare.lstrip().startswith(DAILY_META_MARKER):
            quarantined.append(bare)
            # Track whether this line already closes the marker; if not,
            # we'll keep collecting until we find ``-->``.
            in_meta_remnant = " -->" not in bare
            continue
        if in_meta_remnant:
            quarantined.append(bare)
            if "-->" in bare:
                in_meta_remnant = False
            continue
        cleaned_lines.append(line)
    if quarantined:
        return {}, "".join(cleaned_lines), quarantined, True
    return {}, text, [], False


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


def _strip_quarantine_block(body: str) -> tuple[str, list[str]]:
    """Detach an existing quarantine block from ``body`` (if any).

    Returns ``(body_without_quarantine, prior_quarantine_lines)``.
    Idempotency: re-running on a previously quarantined note keeps the
    quarantined content stable rather than re-wrapping it each pass.
    """
    match = QUARANTINE_RE.search(body)
    if not match:
        return body, []
    inner = match.group("body").rstrip("\n").splitlines()
    cleaned = body[: match.start()] + body[match.end():]
    return cleaned, inner


def _parse_daily_note(
    text: str,
    date: str,
    agent: str,
) -> tuple[dict[str, Any], str, list[tuple[str | None, str]], list[str], bool]:
    meta, body, quarantined_lines, meta_corrupt = _read_meta_block(text)
    # Detach any existing quarantine block from the bottom so we don't
    # parse it as a body section / re-double-wrap it.
    body, prior_quarantine = _strip_quarantine_block(body)
    if prior_quarantine:
        quarantined_lines = list(quarantined_lines) + list(prior_quarantine)
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
    return meta, title, sections, quarantined_lines, meta_corrupt


def _assemble_daily_note(
    title: str,
    meta: dict[str, Any],
    sections: list[tuple[str | None, str]],
    quarantined_lines: list[str] | None = None,
) -> str:
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
    body = "\n".join(chunks).rstrip() + "\n"
    if quarantined_lines:
        # Item 2b — append a clearly-delimited quarantine block at the
        # very bottom so operators can recover hand-edits or malformed
        # meta-region content the parser refused.
        body += "\n" + QUARANTINE_OPEN + "\n"
        body += "\n".join(quarantined_lines).rstrip("\n") + "\n"
        body += QUARANTINE_CLOSE + "\n"
    return body


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
# concurrency lock (Item 2a + 7c)
# ----------------------------------------------------------------------


@contextlib.contextmanager
def daily_note_lock(memory_dir: Path):
    """Hold an exclusive ``fcntl.flock`` on a sentinel file in
    ``memory_dir`` while the read/parse/render/write cycle runs.

    Concurrent invocations (cron + Stop hook + ad-hoc operator firing in
    the same second) serialise on this lock instead of clobbering each
    other's updates with the atomic-rename pattern. The sentinel is a
    sibling of the daily note — never the note itself, since the atomic
    rename would invalidate any lock held on the note's inode.
    """
    memory_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(memory_dir, 0o700)
    except OSError:
        pass
    lock_path = memory_dir / ".daily-note-reconcile.lock"
    fp = open(lock_path, "w")
    try:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fp.fileno(), fcntl.LOCK_UN)
    finally:
        fp.close()


# ----------------------------------------------------------------------
# manifest recovery (Item 1c + 3b)
# ----------------------------------------------------------------------


def recover_manifest_from_body(
    sections: list[tuple[str | None, str]],
    target_session: str,
) -> list[str]:
    """Re-fingerprint already-rendered turn blocks for ``target_session``
    so a missing/corrupt manifest doesn't cause duplicate-on-first-run.

    The renderer writes ``### turn N · <role> · <iso-ts>\\n\\n<text>\\n``
    blocks. We walk the body of the matching session section, extract
    each block's ``role`` + ``text`` + ``ts``, and recompute the same
    fingerprint the extractor would emit.

    Best-effort: if a block doesn't parse cleanly we skip it and keep
    going. The caller should treat the returned list as a *floor*, not
    a guarantee — first re-run after recovery may still append a turn
    that the extractor parses slightly differently than the body
    rendering. That's a one-time event; subsequent runs stabilise.
    """
    fingerprints: list[str] = []
    for sid, body in sections:
        if sid != target_session:
            continue
        # Find every "### turn N · role · ts" header inside this section.
        matches = list(DAILY_TURN_HEADER_RE.finditer(body))
        for i, m in enumerate(matches):
            role = m.group("role").strip()
            ts = m.group("ts").strip()
            block_start = m.end()
            block_end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
            text = body[block_start:block_end].strip("\n").rstrip()
            # Strip the leading blank line emitted by _render_turn_block.
            text = text.lstrip("\n")
            fingerprints.append(_fingerprint(role, text, ts))
    return fingerprints


# ----------------------------------------------------------------------
# core reconcile
# ----------------------------------------------------------------------


def _manifest_total(manifest: dict[str, list[str]]) -> int:
    return sum(len(v) for v in manifest.values())


def _empty_result(
    agent: str,
    date: str,
    note_path: Path,
    jsonl_path: Path,
    memory_dir: Path,
    dry_run: bool,
    warnings: list[str],
) -> dict[str, Any]:
    return {
        "status": "ok",
        "outcome": "noop",
        "agent": agent,
        "date": date,
        "session_id": "",
        "jsonl": str(jsonl_path),
        "memory_dir": str(memory_dir),
        "note_path": str(note_path),
        "turns_total": 0,
        "turns_filtered": 0,
        "turns_new": 0,
        "manifest_size_before": 0,
        "manifest_size_after": 0,
        "sessions": [],
        "applied": "noop",
        "dry_run": dry_run,
        "no_turns": True,
        "diff": "",
        "human_summary": f"noop agent={agent} date={date} turns_new=0 note={note_path}",
        "warnings": warnings,
        "error": None,
    }


def reconcile(
    agent: str,
    jsonl_path: Path,
    date: str,
    memory_dir: Path,
    dry_run: bool,
    verbose: bool,
) -> dict[str, Any]:
    note_path = memory_dir / f"{date}.md"
    warnings: list[str] = []

    turns, sessions_in_jsonl, dropped = extract_turns(
        jsonl_path, date, verbose=verbose, warnings=warnings,
    )

    if not turns:
        sys.stderr.write(f"no turns for {date} in {jsonl_path}\n")
        result = _empty_result(agent, date, note_path, jsonl_path, memory_dir, dry_run, warnings)
        result["turns_filtered"] = dropped
        return result

    # Item 2a + 7c — hold an exclusive flock on a memory_dir-local
    # sentinel so concurrent reconciles don't lose each others' updates.
    with daily_note_lock(memory_dir):
        # Read existing daily note (may not exist).
        if note_path.exists():
            existing_text = note_path.read_text(encoding="utf-8")
        else:
            existing_text = ""

        quarantined_lines: list[str] = []
        meta_corrupt = False
        if existing_text:
            meta, title, sections, quarantined_lines, meta_corrupt = _parse_daily_note(
                existing_text, date, agent,
            )
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

        if meta_corrupt:
            msg = "meta envelope corrupt — rebuilding from manifest recovery"
            _warn(msg)
            warnings.append(msg)

        # Tolerate corrupt manifest fields.
        raw_manifest = meta.get("reconciled_fingerprints")
        manifest_was_invalid = not isinstance(raw_manifest, dict)
        if manifest_was_invalid:
            _eprint(verbose, "manifest malformed — treating as empty")
            raw_manifest = {}
        manifest: dict[str, list[str]] = {}
        for k, v in raw_manifest.items():
            if isinstance(k, str) and isinstance(v, list):
                manifest[k] = [str(x) for x in v if isinstance(x, (str, int))]

        manifest_size_before = _manifest_total(manifest)

        session_ids = list(meta.get("session_ids") or [])
        writer_mix = dict(meta.get("writer_mix") or {})

        # Group turns by session_id, in jsonl order.
        by_session: dict[str, list[dict[str, Any]]] = {}
        for t in turns:
            by_session.setdefault(t["session_id"], []).append(t)

        # Determine new turns per session.
        new_turn_count = 0
        recovered_any = False
        sessions_summary: list[dict[str, Any]] = []
        for sid in sessions_in_jsonl:
            # Item 1c + 3b — if the manifest is missing/corrupt for this
            # session BUT the body already has rendered turn blocks,
            # rebuild the manifest from the body before treating any
            # turn as "new". Without this, the first run after a manifest
            # loss duplicates every turn.
            session_manifest = manifest.get(sid)
            if (not session_manifest) and existing_text and sections:
                recovered = recover_manifest_from_body(sections, sid)
                if recovered:
                    msg = (
                        f"recovered {len(recovered)} fingerprint(s) from body "
                        f"for session {sid}"
                    )
                    _warn(msg)
                    warnings.append(msg)
                    manifest[sid] = list(recovered)
                    recovered_any = True

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
                _existing_sid, existing_section_text = sections[existing_section_idx]
                existing_turn_count = len(re.findall(
                    r"^### turn \d+\s+·", existing_section_text, re.MULTILINE,
                ))
                appended_blocks = []
                for offset, turn in enumerate(new_turns, start=1):
                    appended_blocks.append(_render_turn_block(existing_turn_count + offset, turn))
                updated_text = (
                    existing_section_text.rstrip("\n")
                    + "\n\n"
                    + "\n".join(appended_blocks).rstrip()
                    + "\n"
                )
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

        new_text = _assemble_daily_note(title, meta, sections, quarantined_lines)

        if quarantined_lines:
            msg = (
                f"quarantined {len(quarantined_lines)} stray meta-region line(s); "
                f"see <!-- daily-note-reconcile-quarantine --> block in {note_path}"
            )
            _warn(msg)
            warnings.append(msg)

        manifest_size_after = _manifest_total(manifest)

        # Decide outcome.
        if new_turn_count == 0:
            applied = "noop"
        elif existing_text:
            applied = "updated"
        else:
            applied = "created"

        # If we touched the file purely to add a quarantine block, fix
        # a corrupt meta envelope, or persist a recovered manifest, treat
        # that as "updated" so the operator can see the change AND so we
        # don't skip the write below (which would leave the recovery
        # in-memory only and re-trigger on the next run).
        if applied == "noop" and existing_text and (
            quarantined_lines or meta_corrupt or recovered_any
        ):
            if existing_text != new_text or recovered_any:
                applied = "updated"

        primary_session = sessions_in_jsonl[0] if sessions_in_jsonl else ""

        if dry_run:
            diff_text = ""
            if existing_text == new_text:
                # Note: human prose moved to human_summary / stderr in the
                # JSON path. Keep the legacy text path for human callers.
                pass
            else:
                diff_text = "".join(difflib.unified_diff(
                    existing_text.splitlines(keepends=True),
                    new_text.splitlines(keepends=True),
                    fromfile=str(note_path) + ".old",
                    tofile=str(note_path) + ".new",
                    lineterm="",
                ))
                if diff_text and not diff_text.endswith("\n"):
                    diff_text += "\n"
            human_summary = (
                f"dry-run agent={agent} date={date} "
                f"turns_new={new_turn_count} note={note_path}"
            )
            return {
                "status": "ok",
                "outcome": "dry-run",
                "agent": agent,
                "date": date,
                "session_id": primary_session,
                "jsonl": str(jsonl_path),
                "memory_dir": str(memory_dir),
                "note_path": str(note_path),
                "turns_total": len(turns),
                "turns_filtered": dropped,
                "turns_new": new_turn_count,
                "manifest_size_before": manifest_size_before,
                "manifest_size_after": manifest_size_after,
                "sessions": sessions_summary,
                "applied": applied,
                "dry_run": True,
                "diff": diff_text,
                "human_summary": human_summary,
                "warnings": warnings,
                "error": None,
            }

        if applied != "noop":
            _ensure_memory_dir(memory_dir)
            _atomic_write(note_path, new_text)

        outcome = "merged" if applied != "noop" else "noop"
        human_summary = (
            f"{applied} agent={agent} date={date} "
            f"turns_new={new_turn_count} note={note_path}"
        )
        return {
            "status": "ok",
            "outcome": outcome,
            "agent": agent,
            "date": date,
            "session_id": primary_session,
            "jsonl": str(jsonl_path),
            "memory_dir": str(memory_dir),
            "note_path": str(note_path),
            "turns_total": len(turns),
            "turns_filtered": dropped,
            "turns_new": new_turn_count,
            "manifest_size_before": manifest_size_before,
            "manifest_size_after": manifest_size_after,
            "sessions": sessions_summary,
            "applied": applied,
            "dry_run": False,
            "diff": "",
            "human_summary": human_summary,
            "warnings": warnings,
            "error": None,
        }


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------


def _sanitize_agent_id(raw: str) -> str:
    """Allowlist ``[A-Za-z0-9_-]{1,64}`` for --agent (Item 6).

    Rejects path traversal payloads (``..``), separators (``/``, ``\\``),
    whitespace, and unicode lookalikes. Raised ``ValueError`` is caught
    in ``main`` and surfaced as a non-zero exit + stderr message
    (matching the existing CLI failure shape).
    """
    if not isinstance(raw, str) or not raw:
        raise ValueError("agent id required")
    if len(raw) > AGENT_ID_MAX_LEN:
        raise ValueError(f"agent id too long (>{AGENT_ID_MAX_LEN} chars)")
    if not AGENT_ID_RE.match(raw):
        # Truncate echoed value to keep error logs bounded.
        raise ValueError(
            f"agent id invalid (must match [A-Za-z0-9_-]+): {raw[:50]!r}"
        )
    return raw


def _bridge_home(args: argparse.Namespace) -> Path:
    """Resolve the bridge runtime root used as the path-traversal anchor.

    Honours ``--transcripts-home`` (PR #426 Track C parity), then
    ``BRIDGE_HOME``, then ``~/.agent-bridge``. The returned path is
    always ``Path.resolve()``'d so the relative-to check below is
    symlink-stable.
    """
    if args.transcripts_home:
        return (Path(args.transcripts_home).expanduser() / ".agent-bridge").resolve()
    raw = os.environ.get("BRIDGE_HOME")
    if raw:
        return Path(raw).expanduser().resolve()
    return (Path.home() / ".agent-bridge").resolve()


def _resolve_memory_dir(args: argparse.Namespace, agent: str) -> Path:
    """Resolve the daily-note directory.

    Default: ``<BRIDGE_HOME>/agents/<agent>/memory``. If ``--memory-dir``
    is provided, the resolved path MUST live inside the resolved bridge
    home (Item 6 — closes ``--memory-dir /etc/passwd``-style escapes).
    Raises ``ValueError`` on a containment violation.
    """
    bridge_root = _bridge_home(args)
    if not args.memory_dir:
        return bridge_root / "agents" / agent / "memory"
    candidate = Path(args.memory_dir).expanduser().resolve()
    try:
        candidate.relative_to(bridge_root)
    except ValueError as exc:
        raise ValueError(
            f"--memory-dir must resolve within BRIDGE_HOME ({bridge_root}); "
            f"got {candidate}"
        ) from exc
    return candidate


def _emit_json_error(jsonl_path: str, agent: str, date: str, message: str) -> None:
    """Print a stable JSON error envelope to stdout (Item 9c).

    Used when ``--json`` is set and a CLI / argument validation failure
    would otherwise emit prose to stderr only. We still mirror the
    message to stderr for human callers.
    """
    payload = {
        "status": "error",
        "outcome": "error",
        "agent": agent,
        "date": date,
        "session_id": "",
        "jsonl": jsonl_path,
        "memory_dir": "",
        "note_path": "",
        "turns_total": 0,
        "turns_filtered": 0,
        "turns_new": 0,
        "manifest_size_before": 0,
        "manifest_size_after": 0,
        "sessions": [],
        "applied": "noop",
        "dry_run": False,
        "diff": "",
        "human_summary": message,
        "warnings": [],
        "error": message,
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stderr.write(message + "\n")


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

    # Item 6 — sanitize agent id BEFORE we use it in any path. We pass
    # ``args.agent`` (raw) into the JSON error envelope so the operator
    # can correlate, then bail.
    try:
        agent = _sanitize_agent_id(args.agent)
    except ValueError as exc:
        if args.json:
            _emit_json_error(args.jsonl, args.agent or "", args.date or "", str(exc))
        else:
            sys.stderr.write(str(exc) + "\n")
        return 2

    date = args.date or _today_utc()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        msg = f"invalid --date {date!r} (expected YYYY-MM-DD)"
        if args.json:
            _emit_json_error(args.jsonl, agent, args.date or "", msg)
        else:
            sys.stderr.write(msg + "\n")
        return 2

    jsonl_path = Path(args.jsonl).expanduser()
    if not jsonl_path.exists():
        msg = f"jsonl not found: {jsonl_path}"
        if args.json:
            _emit_json_error(str(jsonl_path), agent, date, msg)
        else:
            sys.stderr.write(msg + "\n")
        return 2
    if not jsonl_path.is_file():
        msg = f"jsonl is not a file: {jsonl_path}"
        if args.json:
            _emit_json_error(str(jsonl_path), agent, date, msg)
        else:
            sys.stderr.write(msg + "\n")
        return 2
    try:
        # Touch readability without slurping the whole file.
        with jsonl_path.open("rb") as _probe:
            _probe.read(1)
    except OSError:
        msg = "jsonl unreadable"
        if args.json:
            _emit_json_error(str(jsonl_path), agent, date, msg)
        else:
            # Do NOT echo the path beyond this — minimal info leak.
            sys.stderr.write(msg + "\n")
        return 2

    try:
        memory_dir = _resolve_memory_dir(args, agent)
    except ValueError as exc:
        if args.json:
            _emit_json_error(str(jsonl_path), agent, date, str(exc))
        else:
            sys.stderr.write(str(exc) + "\n")
        return 2

    try:
        result = reconcile(
            agent=agent,
            jsonl_path=jsonl_path,
            date=date,
            memory_dir=memory_dir,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )
    except OSError as exc:
        msg = f"reconcile write failed: {exc}"
        if args.json:
            _emit_json_error(str(jsonl_path), agent, date, msg)
        else:
            sys.stderr.write(msg + "\n")
        return 2

    # Item 9c — when --json is set, stdout is one parseable JSON document.
    # Human-readable summary / diff goes into the JSON body
    # (``human_summary`` + ``diff``). Diffs in the legacy ``--dry-run``
    # (no --json) path still print to stdout for human callers.
    if args.json:
        sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
        return 0

    if args.dry_run:
        diff_text = result.get("diff") or ""
        if diff_text:
            sys.stdout.write(diff_text)
            if not diff_text.endswith("\n"):
                sys.stdout.write("\n")
        else:
            sys.stdout.write("no changes\n")
        return 0

    sys.stdout.write(
        f"{result['applied']} agent={result['agent']} date={result['date']} "
        f"turns_new={result['turns_new']} note={result['note_path']}\n"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
