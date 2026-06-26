#!/usr/bin/env python3
"""bridge-memory.py — bridge-native markdown memory wiki helpers."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

# Shared disposable-`claude -p` launch hardening (#17957). `_llm_summarize`
# below runs in the agent's real config-dir, so without this it would auto-load
# the singleton telegram/discord plugins and steal the admin's live poller. The
# overlay suppresses ONLY those singleton channels and preserves all other
# plugins/MCP.
_BRIDGE_MEMORY_LIB_DIR = Path(__file__).resolve().parent / "lib"
if _BRIDGE_MEMORY_LIB_DIR.is_dir() and str(_BRIDGE_MEMORY_LIB_DIR) not in sys.path:  # noqa: raw-pathlib-controller-only — import-time controller-side lib dir probe
    sys.path.insert(0, str(_BRIDGE_MEMORY_LIB_DIR))

try:
    from bridge_disposable_claude import singleton_channel_suppression_argv  # noqa: E402
except ImportError as _exc:
    # A relocated copy of this script (e.g. #1894's run-as-iso transcript scan,
    # which copies only this file without the adjacent lib/) must still import —
    # but it must NOT silently spawn a disposable `claude -p` that could steal
    # the admin's telegram/discord poller. Bind a fail-closed proxy: code paths
    # that never spawn (scan-transcripts, harvest-daily, …) import fine; any
    # path that actually reaches the spawn raises loudly instead of launching
    # the child unsuppressed.
    _BRIDGE_DISPOSABLE_IMPORT_ERROR = _exc

    def singleton_channel_suppression_argv() -> list[str]:  # noqa: E402
        raise RuntimeError(
            "lib/bridge_disposable_claude.py is required to launch a disposable "
            "`claude -p` with the singleton channel plugins suppressed (#17957) "
            f"but was not importable: {_BRIDGE_DISPOSABLE_IMPORT_ERROR}"
        )


USER_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SEARCH_SCOPES = ("wiki", "all", "user", "daily", "shared", "project", "decision", "raw")
QUERY_SCOPES = ("all", "wiki", "user", "daily", "shared", "project", "decision", "raw")
INDEX_KIND = "bridge-wiki-fts-v1"
INDEX_KIND_WIKI_HYBRID_V2 = "bridge-wiki-hybrid-v2"
KNOWN_INDEX_KINDS = (INDEX_KIND, INDEX_KIND_WIKI_HYBRID_V2)


@dataclass
class UserSpec:
    user_id: str
    display_name: str


def die(message: str) -> None:
    raise SystemExit(message)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _iter_readable(path: Path, entries_fn) -> list:
    """Enumerate `entries_fn(path)`, graceful-skipping an unreadable dir.

    A controller-run index rebuild may walk an iso agent's `0700`
    (iso-UID-only) home, where `iterdir`/`glob`/`rglob` raise
    `PermissionError`. That boundary is correct isolation, not a bug, so a
    rebuild that cannot read a subtree should skip it with a warning and
    keep indexing the readable docs (Issue #1947). Genuine logic errors are
    not caught here — only the OS read/permission boundary.
    """
    try:
        return list(entries_fn(path))
    except OSError as exc:
        print(f"note: skipping unreadable path {path}: {exc}", file=sys.stderr)
        return []


def write_text(path: Path, text: str, dry_run: bool) -> None:
    """Atomic + locked text write.

    Writes to a same-directory tempfile, fsyncs, and renames into place.
    Serializes concurrent writers by holding an exclusive flock on a
    sibling `<name>.lock` file — this prevents two summarize runs for the
    same week/month from clobbering each other.
    """
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
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
        finally:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def append_text(path: Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handle.write(text)
            handle.flush()
        finally:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def _safe_excerpt(path: Path, limit: int) -> str | None:
    """Read first `limit` chars from `path`. Returns None on any OSError or decode issue."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return text[:limit]


def load_template_files(template_root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for item in template_root.rglob("*"):
        if item.is_file():
            files[str(item.relative_to(template_root))] = read_text(item)
    return files


def parse_user_spec(raw: str) -> UserSpec:
    if ":" in raw:
        user_id, display_name = raw.split(":", 1)
    else:
        user_id, display_name = raw, raw
    user_id = user_id.strip()
    display_name = display_name.strip() or user_id
    if not user_id:
        die("empty user id is not allowed")
    if not USER_ID_RE.match(user_id):
        die(f"invalid user id: {user_id}")
    return UserSpec(user_id=user_id, display_name=display_name)


def normalize_user_specs(values: list[str]) -> list[UserSpec]:
    if not values:
        return [UserSpec(user_id="default", display_name="default")]
    seen: set[str] = set()
    result: list[UserSpec] = []
    for raw in values:
        spec = parse_user_spec(raw)
        if spec.user_id in seen:
            continue
        seen.add(spec.user_id)
        result.append(spec)
    return result


def ensure_file_from_template(
    home: Path,
    relpath: str,
    template_files: dict[str, str],
    dry_run: bool,
    created: list[str],
) -> None:
    target = home / relpath
    if target.exists():
        return
    content = template_files.get(relpath)
    if content is None:
        return
    write_text(target, content, dry_run)
    created.append(relpath)


def patch_user_profile(path: Path, display_name: str, dry_run: bool) -> None:
    if not path.exists():
        return
    text = read_text(path)
    text = text.replace("- Name:\n", f"- Name: {display_name}\n")
    text = text.replace("- Preferred name:\n", f"- Preferred name: {display_name}\n")
    write_text(path, text, dry_run)


def ensure_memory_layout(home: Path, template_root: Path, dry_run: bool) -> list[str]:
    template_files = load_template_files(template_root)
    created: list[str] = []
    for relpath in (
        "MEMORY-SCHEMA.md",
        "MEMORY.md",
        "SOUL.md",
        "CLAUDE.md",
        "TOOLS.md",
        "SKILLS.md",
        "memory/index.md",
        "memory/log.md",
    ):
        ensure_file_from_template(home, relpath, template_files, dry_run, created)

    for relpath in (
        "memory/shared/.gitkeep",
        "memory/projects/.gitkeep",
        "memory/decisions/.gitkeep",
        "raw/captures/inbox/.gitkeep",
        "raw/captures/ingested/.gitkeep",
    ):
        target = home / relpath
        if target.exists():
            continue
        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
        created.append(relpath)

    return created


def ensure_user_partition(
    home: Path,
    template_root: Path,
    user: UserSpec,
    dry_run: bool,
    created: list[str],
) -> None:
    users_root = home / "users"
    default_root = template_root / "users" / "default"
    target_root = users_root / user.user_id
    if target_root.exists():
        patch_user_profile(target_root / "USER.md", user.display_name, dry_run)
        return
    if not default_root.exists():
        die(f"missing template user skeleton: {default_root}")
    if not dry_run:
        shutil.copytree(default_root, target_root)
    created.append(f"users/{user.user_id}/")
    patch_user_profile(target_root / "USER.md", user.display_name, dry_run)


def remove_default_partition_if_needed(home: Path, users: list[UserSpec], dry_run: bool) -> None:
    if any(user.user_id == "default" for user in users):
        return
    default_root = home / "users" / "default"
    if not default_root.exists():
        return
    if not dry_run:
        shutil.rmtree(default_root)


def update_memory_index(home: Path, users: list[UserSpec], dry_run: bool) -> None:
    path = home / "memory" / "index.md"
    if not path.exists():
        return
    lines = read_text(path).splitlines()
    out: list[str] = []
    inserted = False
    for line in lines:
        if line.strip().startswith("- `../users/") and line.strip() != "- `../users/`":
            continue
        out.append(line)
        if line.strip() == "- `../users/`":
            for user in users:
                out.append(f"- `../users/{user.user_id}/`")
            inserted = True
    if not inserted and "- `../users/`" not in lines:
        out.extend(["", "## Users", "- `../users/`"])
        for user in users:
            out.append(f"- `../users/{user.user_id}/`")
    write_text(path, "\n".join(out).rstrip() + "\n", dry_run)


def cmd_init(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    users = normalize_user_specs(args.user or [])
    created = ensure_memory_layout(home, template_root, args.dry_run)
    for user in users:
        ensure_user_partition(home, template_root, user, args.dry_run, created)
    remove_default_partition_if_needed(home, users, args.dry_run)
    update_memory_index(home, users, args.dry_run)
    payload = {
        "agent": args.agent,
        "home": str(home),
        "dry_run": args.dry_run,
        "users": [user.__dict__ for user in users],
        "created": created,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"home: {home}")
        print(f"dry_run: {'yes' if args.dry_run else 'no'}")
        print(f"users: {json.dumps([user.__dict__ for user in users], ensure_ascii=False)}")
        print(f"created: {len(created)}")
    return 0


def slugify(text: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-").lower()
    return slug or "capture"


ENVELOPE_SCHEMA_VERSIONS = {"1"}


def _sniff_envelope(text: str) -> dict | None:
    """Return parsed envelope dict if `text` carries a structured capture.

    Two accepted shapes (both produced by hooks/pre-compact.py):
        1) Pure JSON body whose top-level `schema_version` is known.
        2) A short head line (e.g. `schema_version=1 | excerpt=...`)
           followed by a blank line, then a JSON object body.
    Anything else returns None and the caller falls back to text-only.
    """
    if not text:
        return None
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            data = json.loads(stripped)
        except (json.JSONDecodeError, ValueError):
            data = None
        if isinstance(data, dict) and str(data.get("schema_version") or "") in ENVELOPE_SCHEMA_VERSIONS:
            return data
    brace_idx = text.find("\n{")
    if brace_idx != -1:
        candidate = text[brace_idx + 1:].strip()
        try:
            data = json.loads(candidate)
        except (json.JSONDecodeError, ValueError):
            return None
        if isinstance(data, dict) and str(data.get("schema_version") or "") in ENVELOPE_SCHEMA_VERSIONS:
            return data
    return None


def capture_payload(args: argparse.Namespace) -> dict:
    now = datetime.now().astimezone()
    capture_id = now.strftime("%Y%m%dT%H%M%S%z")
    capture_id = f"{capture_id[:15]}-{slugify(args.title or args.source or args.agent)}"
    payload: dict = {
        "capture_id": capture_id,
        "agent": args.agent,
        "user": args.user,
        "source": args.source,
        "author": args.author,
        "channel": args.channel,
        "title": args.title,
        "text": args.text,
        "created_at": now.isoformat(),
    }
    envelope = _sniff_envelope(args.text or "")
    if envelope is not None:
        payload["envelope"] = envelope
        payload["schema_version"] = envelope.get("schema_version")
        for key in ("suggested_slug", "suggested_title", "session_type", "trigger"):
            value = envelope.get(key)
            if value and key not in payload:
                payload[key] = value
    return payload


def write_capture_payload(home: Path, payload: dict, dry_run: bool) -> Path:
    inbox_dir = home / "raw" / "captures" / "inbox"
    path = inbox_dir / f"{payload['capture_id']}.json"
    if not dry_run:
        inbox_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def cmd_capture(args: argparse.Namespace) -> int:
    home = Path(args.home)
    ensure_memory_layout(home, Path(args.template_root), args.dry_run)
    payload = capture_payload(args)
    path = write_capture_payload(home, payload, args.dry_run)
    result = {
        "capture_id": payload["capture_id"],
        "agent": args.agent,
        "user": args.user,
        "path": str(path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"capture_id: {payload['capture_id']}")
        print(f"path: {path}")
        print(f"user: {args.user}")
    return 0


def resolve_capture_paths(home: Path, capture_id: str | None, latest: bool, all_items: bool) -> list[Path]:
    inbox_dir = home / "raw" / "captures" / "inbox"
    candidates = sorted(inbox_dir.glob("*.json"))
    if capture_id:
        path = inbox_dir / f"{capture_id}.json"
        if not path.exists():
            die(f"capture not found: {capture_id}")
        return [path]
    if latest:
        if not candidates:
            return []
        return [candidates[-1]]
    if all_items:
        return candidates
    die("specify --capture, --latest, or --all")


def resolve_any_capture_path(home: Path, capture_id: str) -> Path:
    for directory in (
        home / "raw" / "captures" / "inbox",
        home / "raw" / "captures" / "ingested",
    ):
        path = directory / f"{capture_id}.json"
        if path.exists():
            return path
    die(f"capture not found: {capture_id}")


def ensure_daily_note(path: Path, date_str: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {date_str}\n\n## Captures\n", dry_run)


def relative_link(from_path: Path, to_path: Path) -> str:
    return str(Path(shutil.os.path.relpath(to_path, from_path.parent)))


def append_ingest_entry(
    daily_path: Path,
    capture: dict,
    processed_path: Path,
    dry_run: bool,
) -> None:
    created_at = datetime.fromisoformat(capture["created_at"])
    date_label = created_at.strftime("%Y-%m-%d %H:%M %Z").strip()
    raw_link = relative_link(daily_path, processed_path)
    block = (
        f"\n### {date_label} — {capture.get('author') or 'unknown'}\n"
        f"- Source: {capture.get('source') or 'unknown'}\n"
        f"- Channel: {capture.get('channel') or '-'}\n"
        f"- Raw capture: `{raw_link}`\n"
        f"- Note: {capture.get('text') or ''}\n"
    )
    append_text(daily_path, block, dry_run)


def append_memory_log(path: Path, capture: dict, daily_rel: str, dry_run: bool) -> None:
    created_at = datetime.now().astimezone().isoformat()
    line = (
        f"- {created_at} kind=ingest target=`{daily_rel}` "
        f"source=`{capture['capture_id']}` summary=\"{capture.get('source') or 'capture'} -> daily memory\"\n"
    )
    append_text(path, line, dry_run)


def append_memory_event(path: Path, line: str, dry_run: bool) -> None:
    append_text(path, line.rstrip() + "\n", dry_run)


def ingest_capture_payload(
    home: Path,
    template_root: Path,
    capture: dict,
    capture_path: Path,
    dry_run: bool,
) -> dict:
    user = UserSpec(user_id=capture.get("user") or "default", display_name=capture.get("user") or "default")
    ensure_user_partition(home, template_root, user, dry_run, [])
    created_at = datetime.fromisoformat(capture["created_at"])
    date_str = created_at.date().isoformat()
    daily_path = home / "users" / user.user_id / "memory" / f"{date_str}.md"
    ensure_daily_note(daily_path, date_str, dry_run)
    processed_dir = home / "raw" / "captures" / "ingested"
    processed_path = processed_dir / capture_path.name
    append_ingest_entry(daily_path, capture, processed_path, dry_run)
    append_memory_log(home / "memory" / "log.md", capture, str(daily_path.relative_to(home)), dry_run)
    if not dry_run:
        processed_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(capture_path), str(processed_path))
    return {
        "capture_id": capture["capture_id"],
        "user": user.user_id,
        "daily_note": str(daily_path),
        "processed_path": str(processed_path),
    }


def cmd_ingest(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)
    capture_paths = resolve_capture_paths(home, args.capture, args.latest, args.all)
    ingested: list[dict] = []
    for path in capture_paths:
        capture = json.loads(read_text(path))
        ingested.append(ingest_capture_payload(home, template_root, capture, path, args.dry_run))
    payload = {
        "agent": args.agent,
        "count": len(ingested),
        "items": ingested,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"ingested: {len(ingested)}")
        for item in ingested:
            print(f"- {item['capture_id']} -> {item['daily_note']}")
    return 0


def ensure_section(path: Path, section: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path)
    else:
        text = f"# {section}\n"
    if f"## {section}\n" in text or text.startswith(f"# {section}\n"):
        if not path.exists():
            write_text(path, text, dry_run)
        return
    if not text.endswith("\n"):
        text += "\n"
    text += f"\n## {section}\n"
    write_text(path, text, dry_run)


def append_under_section(path: Path, section: str, block: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path)
    else:
        text = ""
    marker = f"\n## {section}\n"
    if text.startswith(f"# {section}\n"):
        text = text.rstrip() + "\n\n" + block
    elif marker in text:
        text = text.rstrip() + "\n" + block
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        if text:
            text += "\n"
        text += f"## {section}\n{block}"
    write_text(path, text.rstrip() + "\n", dry_run)


def page_title_from_slug(slug: str) -> str:
    return slug.replace("-", " ").replace("_", " ").strip().title() or "Memory Page"


def ensure_page(path: Path, title: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {title}\n\n## Notes\n", dry_run)


def build_page_promotion_block(
    created_at: str,
    title: str,
    summary: str,
    capture: dict | None,
) -> str:
    lines = [f"### {created_at} — {title}", "", summary]
    detail_text = (capture or {}).get("text", "").strip()
    if detail_text and detail_text != summary.strip():
        lines.extend(["", "#### Details", "", detail_text])
    if capture:
        lines.extend(["", "#### Source"])
        lines.append(f"- Capture: `{capture['capture_id']}`")
        if capture.get("source"):
            lines.append(f"- Source: {capture['source']}")
        if capture.get("author"):
            lines.append(f"- Author: {capture['author']}")
        if capture.get("channel"):
            lines.append(f"- Channel: {capture['channel']}")
    return "\n".join(lines).rstrip() + "\n"


def build_agent_pref_block(
    created_at: str,
    title: str,
    summary: str,
    capture: dict | None,
) -> str:
    # Issue #162 Phase 2: agent-role rule format per
    # docs/agent-runtime/user-preference-injection.md §2. Each promotion is
    # a self-contained `## <title> (YYYY-MM-DD, scope: agent)` section.
    # Why / How-to-apply fall back to `(see source)` when the capture body
    # does not carry explicit keys — Phase 2 deliberately avoids new CLI
    # flags and keeps the Source attribution at the real capture id so it
    # traces back to the canonical raw/captures/* payload.
    date_str = created_at[:10]
    rule_body = summary.strip() or "(see source)"
    source_ref = "(inline)"
    if capture:
        source_ref = f"capture `{capture['capture_id']}`"
        if capture.get("source"):
            source_ref += f" ({capture['source']})"
    lines = [
        "",
        f"## {title} ({date_str}, scope: agent)",
        "",
        f"**Rule:** {rule_body}",
        "**Why:** (see source)",
        "**How to apply:** (see source)",
        f"**Source:** {source_ref}",
        "",
    ]
    return "\n".join(lines)


def ensure_active_preferences_page(path: Path, dry_run: bool) -> None:
    # Issue #162 Phase 2: file is created lazily on first promote only —
    # NOT at scaffold time. bridge-docs.py's Runtime Canon renderer keys
    # the CLAUDE pointer on file existence, so agents without promoted
    # role-specific preferences pay zero startup overhead.
    if path.exists():
        return
    intro = (
        "# Active Preferences\n\n"
        "이 파일은 이 에이전트 역할에만 적용되는 운영 규칙을 담는다.\n"
        "새 규칙은 `agent-bridge memory promote --kind agent-pref ...` 로 추가한다 — 직접 편집하지 말 것.\n"
    )
    write_text(path, intro, dry_run)


def append_agent_pref_block(path: Path, block: str, dry_run: bool) -> None:
    existing = read_text(path) if path.exists() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    write_text(path, existing + block, dry_run)


def _load_bridge_docs_module():
    # Hyphenated filename workaround mirroring bridge-migrate.py. Always
    # load the bridge-docs.py that lives alongside this script so we get
    # the current render_agent_bridge_block behaviour, not whatever old
    # copy might sit under BRIDGE_HOME.
    script = Path(__file__).resolve().parent / "bridge-docs.py"
    spec = importlib.util.spec_from_file_location("_bridge_docs_memory", str(script))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load bridge-docs.py from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_bridge_docs_memory"] = module
    spec.loader.exec_module(module)
    return module


def cmd_promote(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)

    capture = None
    if args.capture:
        capture = json.loads(read_text(resolve_any_capture_path(home, args.capture)))
    user_id = args.user or (capture.get("user") if capture else "default") or "default"
    user = UserSpec(user_id=user_id, display_name=user_id)
    if args.kind != "agent-pref":
        # Issue #162 Phase 2 (codex review finding): agent-pref is
        # user-agnostic and lives only in ACTIVE-PREFERENCES.md. Scaffolding
        # a users/<uid>/ partition for this kind produces unrelated state
        # churn — skip the partition ensure for that kind specifically.
        ensure_user_partition(home, template_root, user, args.dry_run, [])

    summary = args.summary or (capture.get("text") if capture else "")
    if not summary:
        die("promotion summary is required")

    created_at = datetime.now().astimezone().isoformat()
    kind = args.kind
    title = args.title or args.page or (capture.get("title") if capture else "") or kind
    block_lines = [
        f"- {created_at}: {summary}",
    ]
    if capture:
        block_lines.append(f"  - source capture: `{capture['capture_id']}`")
        if capture.get("source"):
            block_lines.append(f"  - source: {capture['source']}")
    block = "\n".join(block_lines) + "\n"

    target_path: Path
    if kind == "user":
        target_path = home / "users" / user.user_id / "MEMORY.md"
        append_under_section(target_path, "Promotions", block, args.dry_run)
    elif kind == "user-profile":
        # Issue #162 Phase 1: shared user profile is the canonical surface
        # for persistent user preferences. Writing through the agent's
        # symlinked `users/<uid>/USER.md` hits the canonical
        # `shared/users/<uid>/USER.md`, so every other agent linked to the
        # same user sees the preference at next session start without a
        # separate promotion chain. The "Stable Preferences" section is
        # intentionally distinct from the hand-edited "Stable preferences"
        # bullet in the Identity/Working Notes skeleton so promoted
        # entries do not fight the operator's manual edits.
        target_path = home / "users" / user.user_id / "USER.md"
        append_under_section(
            target_path, "Stable Preferences", block, args.dry_run
        )
    elif kind == "agent-pref":
        # Issue #162 Phase 2: agent-role-specific operating rules. Unlike
        # user-profile (cross-agent for a given user via shared symlink),
        # these stay scoped to this single agent's home. File is created
        # lazily on first promote and lives at the agent home root so
        # bridge-docs.py's Runtime Canon bullet is keyed on presence.
        target_path = home / "ACTIVE-PREFERENCES.md"
        ensure_active_preferences_page(target_path, args.dry_run)
        append_agent_pref_block(
            target_path,
            build_agent_pref_block(created_at, title, summary, capture),
            args.dry_run,
        )
        # Issue #162 Phase 2 (codex review finding): the Runtime Canon
        # pointer in CLAUDE.md is keyed on file existence, so the first
        # promote MUST trigger a managed-block re-render — otherwise the
        # rule does not auto-load until the next `agent-bridge upgrade`
        # or `setup agent` run, breaking the Phase 2 "auto-loaded once
        # promoted" contract.
        if not args.dry_run:
            bridge_docs = _load_bridge_docs_module()
            backup_root = home / "state" / "promote-backups"
            backup_root.mkdir(parents=True, exist_ok=True)
            bridge_docs.normalize_claude(home, args.dry_run, backup_root)
    else:
        page_slug = slugify(args.page or title)
        if kind == "shared":
            target_path = home / "memory" / "shared" / f"{page_slug}.md"
        elif kind == "project":
            target_path = home / "memory" / "projects" / f"{page_slug}.md"
        elif kind == "decision":
            target_path = home / "memory" / "decisions" / f"{page_slug}.md"
        else:
            die(f"unsupported promote kind: {kind}")
        ensure_page(target_path, page_title_from_slug(page_slug), args.dry_run)
        append_under_section(
            target_path,
            "Notes",
            build_page_promotion_block(created_at, title, summary, capture),
            args.dry_run,
        )

    log_line = (
        f"- {created_at} kind=promote target=`{target_path.relative_to(home)}` "
        f"summary=\"{summary.strip()}\""
    )
    if capture:
        log_line += f" source=`{capture['capture_id']}`"
    append_memory_event(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "kind": kind,
        "user": user.user_id,
        "target": str(target_path),
        "capture": capture["capture_id"] if capture else "",
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"kind: {kind}")
        print(f"user: {user.user_id}")
        print(f"target: {target_path}")
        if capture:
            print(f"capture: {capture['capture_id']}")
    return 0


def promote_capture_or_summary(
    home: Path,
    template_root: Path,
    agent: str,
    kind: str,
    user_id: str,
    capture: dict | None,
    page: str,
    title: str,
    summary: str,
    dry_run: bool,
) -> dict:
    promote_args = argparse.Namespace(
        agent=agent,
        home=str(home),
        template_root=str(template_root),
        kind=kind,
        user=user_id,
        capture=capture["capture_id"] if capture else "",
        page=page,
        title=title,
        summary=summary,
        dry_run=dry_run,
        json=True,
    )
    from io import StringIO
    import contextlib

    buffer = StringIO()
    with contextlib.redirect_stdout(buffer):
        cmd_promote(promote_args)
    return json.loads(buffer.getvalue())


def cmd_remember(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)

    capture_args = argparse.Namespace(
        agent=args.agent,
        user=args.user,
        source=args.source,
        author=args.author,
        channel=args.channel,
        title=args.title,
        text=args.text,
    )
    capture = capture_payload(capture_args)
    capture_path = write_capture_payload(home, capture, args.dry_run)
    ingested = ingest_capture_payload(home, template_root, capture, capture_path, args.dry_run)

    promotion = None
    if args.kind != "none":
        promotion = promote_capture_or_summary(
            home=home,
            template_root=template_root,
            agent=args.agent,
            kind=args.kind,
            user_id=args.user,
            capture=capture,
            page=args.page,
            title=args.title,
            summary=args.summary or args.text,
            dry_run=args.dry_run,
        )

    payload = {
        "agent": args.agent,
        "capture_id": capture["capture_id"],
        "user": args.user,
        "source": args.source,
        "daily_note": ingested["daily_note"],
        "processed_path": ingested["processed_path"],
        "promotion": promotion or {},
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"capture_id: {capture['capture_id']}")
        print(f"user: {args.user}")
        print(f"daily_note: {ingested['daily_note']}")
        print(f"processed_path: {ingested['processed_path']}")
        if promotion:
            print(f"promotion: {promotion['kind']} -> {promotion['target']}")
    return 0


def cmd_lint(args: argparse.Namespace) -> int:
    home = Path(args.home)
    problems: list[str] = []
    warnings: list[str] = []

    for relpath in (
        "SOUL.md",
        "CLAUDE.md",
        "MEMORY-SCHEMA.md",
        "MEMORY.md",
        "memory/index.md",
        "memory/log.md",
    ):
        if not (home / relpath).exists():
            problems.append(f"missing: {relpath}")

    users_root = home / "users"
    user_dirs = sorted(path for path in users_root.iterdir() if path.is_dir()) if users_root.exists() else []
    if not user_dirs:
        problems.append("missing: users/<user-id> partitions")
    for user_dir in user_dirs:
        if not (user_dir / "USER.md").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/USER.md")
        if not (user_dir / "MEMORY.md").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/MEMORY.md")
        if not (user_dir / "memory").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/memory/")

    index_path = home / "memory" / "index.md"
    if index_path.exists():
        index_text = read_text(index_path)
        for user_dir in user_dirs:
            expected = f"../users/{user_dir.name}/"
            if expected not in index_text:
                warnings.append(f"index_missing_user_ref: {expected}")

    inbox_dir = home / "raw" / "captures" / "inbox"
    pending_captures = sorted(path.name for path in inbox_dir.glob("*.json")) if inbox_dir.exists() else []
    if pending_captures:
        warnings.append(f"pending_captures: {len(pending_captures)}")

    payload = {
        "agent": args.agent,
        "ok": len(problems) == 0,
        "problems": problems,
        "warnings": warnings,
        "pending_captures": pending_captures,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"ok: {'yes' if not problems else 'no'}")
        if problems:
            for item in problems:
                print(f"- {item}")
        else:
            print("- no problems")
        if warnings:
            print("warnings:")
            for item in warnings:
                print(f"- {item}")
        print(f"pending_captures: {len(pending_captures)}")
    return 0


def tokenize_query(text: str) -> list[str]:
    tokens = [item.lower() for item in re.findall(r"[A-Za-z0-9._-]+", text) if len(item) >= 2]
    if not tokens and text.strip():
        tokens = [text.strip().lower()]
    seen: set[str] = set()
    unique: list[str] = []
    for token in tokens:
        if token in seen:
            continue
        seen.add(token)
        unique.append(token)
    return unique


def user_daily_sort_key(path: Path) -> tuple[int, str]:
    try:
        date_str = path.stem
        return (0, date_str)
    except Exception:
        return (1, path.name)


def iter_search_candidates(home: Path, scope: str, user_id: str | None) -> list[tuple[str, Path]]:
    candidates: list[tuple[str, Path]] = []
    include_wiki = scope in ("wiki", "all")

    if include_wiki or scope == "user":
        if user_id:
            user_root = home / "users" / user_id
            if user_root.exists():
                candidates.extend(
                    [
                        ("user-profile", user_root / "USER.md"),
                        ("user-memory", user_root / "MEMORY.md"),
                    ]
                )
        else:
            users_root = home / "users"
            if users_root.exists():
                for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
                    candidates.extend(
                        [
                            ("user-profile", user_root / "USER.md"),
                            ("user-memory", user_root / "MEMORY.md"),
                        ]
                    )

    if include_wiki or scope == "daily":
        if user_id:
            daily_root = home / "users" / user_id / "memory"
            if daily_root.exists():
                for path in sorted(daily_root.glob("*.md"), key=user_daily_sort_key, reverse=True):
                    candidates.append(("daily", path))
        else:
            users_root = home / "users"
            if users_root.exists():
                for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
                    daily_root = user_root / "memory"
                    if not daily_root.exists():
                        continue
                    for path in sorted(daily_root.glob("*.md"), key=user_daily_sort_key, reverse=True):
                        candidates.append(("daily", path))

    if include_wiki:
        candidates.extend(
            [
                # Issue #162 Phase 2: agent-role rules (if any) are high-signal
                # for "what are my operating constraints" searches. File is
                # optional — iter loop below filters non-existent paths.
                ("agent-pref", home / "ACTIVE-PREFERENCES.md"),
                ("agent-memory", home / "MEMORY.md"),
                ("wiki-index", home / "memory" / "index.md"),
                ("wiki-log", home / "memory" / "log.md"),
            ]
        )

    if include_wiki or scope == "shared":
        shared_root = home / "memory" / "shared"
        if shared_root.exists():
            for path in sorted(shared_root.glob("*.md")):
                candidates.append(("shared", path))

    if include_wiki or scope == "project":
        project_root = home / "memory" / "projects"
        if project_root.exists():
            for path in sorted(project_root.glob("*.md")):
                candidates.append(("project", path))

    if include_wiki or scope == "decision":
        decision_root = home / "memory" / "decisions"
        if decision_root.exists():
            for path in sorted(decision_root.glob("*.md")):
                candidates.append(("decision", path))

    if scope in ("all", "raw"):
        for raw_dir in (
            home / "raw" / "captures" / "inbox",
            home / "raw" / "captures" / "ingested",
        ):
            if not raw_dir.exists():
                continue
            for path in sorted(raw_dir.glob("*.json"), reverse=True):
                candidates.append(("raw", path))

    filtered: list[tuple[str, Path]] = []
    seen_paths: set[Path] = set()
    for kind, path in candidates:
        if path in seen_paths or not path.exists():
            continue
        seen_paths.add(path)
        filtered.append((kind, path))
    return filtered


def search_score(kind: str, path: Path, text: str, tokens: list[str]) -> tuple[int, list[str]]:
    lower = text.lower()
    hits: list[str] = []
    score = 0
    for token in tokens:
        count = lower.count(token)
        if count <= 0:
            continue
        hits.append(token)
        score += count * 8
        if token in path.name.lower():
            score += 10
    base_scores = {
        "user-profile": 80,
        "agent-pref": 75,
        "user-memory": 70,
        "daily": 60,
        "agent-memory": 55,
        "shared": 50,
        "project": 45,
        "decision": 45,
        "wiki-index": 30,
        "wiki-log": 20,
        "raw": 10,
    }
    score += base_scores.get(kind, 0)
    return score, hits


def build_snippet(text: str, tokens: list[str]) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    for line in lines:
        lower = line.lower()
        if any(token in lower for token in tokens):
            return line[:240]
    return lines[0][:240]


def cmd_search(args: argparse.Namespace) -> int:
    home = Path(args.home)
    tokens = tokenize_query(args.query)
    if not tokens:
        die("search query is empty")

    results: list[dict] = []
    for kind, path in iter_search_candidates(home, args.scope, args.user):
        text = read_text(path)
        score, hits = search_score(kind, path, text, tokens)
        if score <= 0 or not hits:
            continue
        results.append(
            {
                "kind": kind,
                "path": str(path),
                "relative_path": str(path.relative_to(home)),
                "score": score,
                "hits": hits,
                "snippet": build_snippet(text, tokens),
            }
        )

    results.sort(key=lambda item: (-item["score"], item["relative_path"]))
    limited = results[: args.limit]
    payload = {
        "agent": args.agent,
        "query": args.query,
        "tokens": tokens,
        "scope": args.scope,
        "user": args.user or "",
        "count": len(limited),
        "total_matches": len(results),
        "results": limited,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        if args.user:
            print(f"user: {args.user}")
        print(f"matches: {len(limited)} / {len(results)}")
        for item in limited:
            print(f"- [{item['kind']}] {item['relative_path']} (score={item['score']})")
            if item["snippet"]:
                print(f"  {item['snippet']}")
    return 0


def collect_index_documents(home: Path, shared_root: Path | None = None, include_cascade: bool = False) -> list[dict]:
    documents: list[dict] = []

    def _exists_readable(path: Path) -> bool:
        # Issue #1947: a controller-run rebuild may probe a path under an iso
        # agent's 0700 home; `exists()` then raises PermissionError. Treat an
        # unreadable path as "skip" (warn + drop) rather than aborting.
        try:
            return path.exists()
        except OSError as exc:
            print(f"note: skipping unreadable path {path}: {exc}", file=sys.stderr)
            return False

    def add_markdown(path: Path, kind: str, user_id: str = "") -> None:
        if _exists_readable(path):
            documents.append({"path": path, "kind": kind, "user_id": user_id, "format": "markdown"})

    def add_json(path: Path, kind: str) -> None:
        if _exists_readable(path):
            documents.append({"path": path, "kind": kind, "user_id": "", "format": "json"})

    add_markdown(home / "SOUL.md", "agent-soul")
    add_markdown(home / "CLAUDE.md", "agent-contract")
    add_markdown(home / "MEMORY-SCHEMA.md", "memory-schema")
    add_markdown(home / "MEMORY.md", "agent-memory")
    # Issue #162 Phase 2: add_markdown is a no-op when the file is absent,
    # so unused agents do not pollute the index and indexed agents surface
    # role-specific rules under `memory search` without further wiring.
    add_markdown(home / "ACTIVE-PREFERENCES.md", "agent-pref")
    add_markdown(home / "memory" / "index.md", "wiki-index")
    add_markdown(home / "memory" / "log.md", "wiki-log")

    for subdir, kind in (("shared", "shared"), ("projects", "project"), ("decisions", "decision")):
        root = home / "memory" / subdir
        if _exists_readable(root):
            for path in sorted(_iter_readable(root, lambda r: r.glob("*.md"))):
                add_markdown(path, kind)

    users_root = home / "users"
    if _exists_readable(users_root):
        for user_root in sorted(
            path for path in _iter_readable(users_root, lambda r: r.iterdir()) if path.is_dir()
        ):
            user_id = user_root.name
            add_markdown(user_root / "USER.md", "user-profile", user_id=user_id)
            add_markdown(user_root / "MEMORY.md", "user-memory", user_id=user_id)
            daily_root = user_root / "memory"
            if _exists_readable(daily_root):
                for path in sorted(_iter_readable(daily_root, lambda r: r.glob("*.md"))):
                    add_markdown(path, "daily", user_id=user_id)

    for raw_root, kind in (
        (home / "raw" / "captures" / "ingested", "raw-ingested"),
        (home / "raw" / "captures" / "inbox", "raw-inbox"),
    ):
        if _exists_readable(raw_root):
            for path in sorted(_iter_readable(raw_root, lambda r: r.glob("*.json"))):
                add_json(path, kind)

    if include_cascade:
        # v2 cascade sources — weekly + monthly summaries produced by the
        # `summarize` subcommands.
        #
        # Note: ingested captures are ALREADY collected by the base flow
        # above as kind="raw-ingested". We do NOT re-add them here because
        # `documents.path` is a PRIMARY KEY and the same file would cause a
        # UNIQUE constraint violation on rebuild. The v2 search path maps
        # both "raw-ingested" and "capture-ingested" via the consumer's
        # `--source` filter, so no content is lost by skipping the re-add.
        for cascade_dir, kind in (
            (home / "memory" / "weekly", "memory-weekly"),
            (home / "memory" / "monthly", "memory-monthly"),
        ):
            if _exists_readable(cascade_dir):
                for path in sorted(_iter_readable(cascade_dir, lambda r: r.glob("*.md"))):
                    add_markdown(path, kind)

    if shared_root is not None:
        wiki_root = shared_root / "wiki"
        if _exists_readable(wiki_root):
            for path in sorted(_iter_readable(wiki_root, lambda r: r.rglob("*.md"))):
                # Skip workspace + audit scratch areas — they are noisy
                # and change on every hygiene run.
                rel = path.relative_to(shared_root)
                if rel.parts[:2] in (("wiki", "_workspace"), ("wiki", "_audit")):
                    continue
                add_markdown(path, "wiki")

    return documents


def chunk_markdown_text(text: str) -> list[tuple[int, int, str]]:
    lines = text.splitlines()
    chunks: list[tuple[int, int, str]] = []
    current: list[str] = []
    start_line = 1

    def flush(end_line: int) -> None:
        nonlocal current, start_line
        compact = "\n".join(line.rstrip() for line in current).strip()
        if compact:
            chunks.append((start_line, end_line, compact))
        current = []

    for lineno, line in enumerate(lines, start=1):
        if line.startswith("#"):
            if current:
                flush(lineno - 1)
            current = [line]
            start_line = lineno
            continue
        if line.strip() == "":
            if current:
                current.append(line)
                flush(lineno)
            else:
                start_line = lineno + 1
            continue
        if not current:
            current = [line]
            start_line = lineno
        else:
            current.append(line)
    if current:
        flush(len(lines) if lines else start_line)
    return chunks


def chunk_json_capture(path: Path) -> tuple[int, int, str, str]:
    payload = json.loads(read_text(path))
    lines = [
        f"capture_id: {payload.get('capture_id', '')}",
        f"user: {payload.get('user', '')}",
        f"source: {payload.get('source', '')}",
        f"author: {payload.get('author', '')}",
        f"channel: {payload.get('channel', '')}",
        f"title: {payload.get('title', '')}",
        f"text: {payload.get('text', '')}",
        f"created_at: {payload.get('created_at', '')}",
    ]
    return 1, len(lines), "\n".join(lines).strip(), payload.get("user", "") or ""


def ensure_index_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS documents (
            path TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            format TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            indexed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            source TEXT NOT NULL,
            model TEXT NOT NULL DEFAULT 'bridge-wiki-fts-v1',
            kind TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            text TEXT NOT NULL,
            embedding TEXT NOT NULL DEFAULT '[]'
        );
        """
    )


def recreate_index_fts(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        DROP TRIGGER IF EXISTS chunks_ai;
        DROP TRIGGER IF EXISTS chunks_ad;
        DROP TRIGGER IF EXISTS chunks_au;
        DROP TABLE IF EXISTS chunks_fts;
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            path UNINDEXED,
            source UNINDEXED,
            model UNINDEXED,
            kind UNINDEXED,
            user_id UNINDEXED,
            content='chunks',
            content_rowid='id'
        );
        CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
          INSERT INTO chunks_fts(rowid, text, path, source, model, kind, user_id)
          VALUES (new.id, new.text, new.path, new.source, new.model, new.kind, new.user_id);
        END;
        CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text, path, source, model, kind, user_id)
          VALUES ('delete', old.id, old.text, old.path, old.source, old.model, old.kind, old.user_id);
        END;
        CREATE TRIGGER chunks_au AFTER UPDATE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text, path, source, model, kind, user_id)
          VALUES ('delete', old.id, old.text, old.path, old.source, old.model, old.kind, old.user_id);
          INSERT INTO chunks_fts(rowid, text, path, source, model, kind, user_id)
          VALUES (new.id, new.text, new.path, new.source, new.model, new.kind, new.user_id);
        END;
        """
    )


def build_fts_query(raw: str) -> str | None:
    tokens = re.findall(r"\w+", raw, flags=re.UNICODE)
    tokens = [token.strip() for token in tokens if token.strip()]
    if not tokens:
        return None
    return " AND ".join(f'"{token.replace(chr(34), "")}"' for token in tokens)


def default_index_db_path(bridge_home: Path, agent: str) -> Path:
    return bridge_home / "runtime" / "memory" / f"{agent}.sqlite"


def cmd_rebuild_index(args: argparse.Namespace) -> int:
    home = Path(args.home)
    bridge_home = Path(args.bridge_home)
    index_kind = getattr(args, "index_kind", INDEX_KIND) or INDEX_KIND
    if index_kind not in KNOWN_INDEX_KINDS:
        die(f"unknown --index-kind: {index_kind!r}. known: {', '.join(KNOWN_INDEX_KINDS)}")
    shared_root = Path(args.shared_root) if getattr(args, "shared_root", None) else None
    include_cascade = index_kind == INDEX_KIND_WIKI_HYBRID_V2
    if include_cascade and shared_root is None:
        # v2 without shared wiki still works (memory-only), but we warn.
        print(
            "note: --index-kind bridge-wiki-hybrid-v2 without --shared-root ingests local "
            "agent home only; pass --shared-root <path> to include shared/wiki/*",
            file=sys.stderr,
        )
    db_path = Path(args.db_path) if args.db_path else default_index_db_path(bridge_home, args.agent)
    indexed_at = datetime.now().astimezone().isoformat()
    documents = collect_index_documents(home, shared_root=shared_root, include_cascade=include_cascade)

    chunk_count = 0
    skipped_count = 0
    if not args.dry_run:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(db_path)
        try:
            # Drop stale content tables first so a DB built against an older
            # schema does not break the new FTS triggers (which reference
            # columns that may not have existed before).
            conn.executescript(
                """
                DROP TRIGGER IF EXISTS chunks_ai;
                DROP TRIGGER IF EXISTS chunks_ad;
                DROP TRIGGER IF EXISTS chunks_au;
                DROP TABLE IF EXISTS chunks_fts;
                DROP TABLE IF EXISTS chunks;
                DROP TABLE IF EXISTS documents;
                DROP TABLE IF EXISTS meta;
                """
            )
            ensure_index_schema(conn)
            recreate_index_fts(conn)
            for doc in documents:
                path = doc["path"]
                # Paths may live under `home` (legacy) or under `shared_root`
                # (v2 wiki cascade). Store a stable relative form anchored at
                # whichever root the file actually came from.
                try:
                    relpath = str(path.relative_to(home))
                except ValueError:
                    if shared_root is not None:
                        try:
                            # Tag shared paths with a `shared:` prefix so they
                            # don't collide with agent-local paths in the
                            # documents PRIMARY KEY.
                            relpath = "shared:" + str(path.relative_to(shared_root))
                        except ValueError:
                            relpath = str(path)
                    else:
                        relpath = str(path)
                try:
                    if doc["format"] == "markdown":
                        text = read_text(path)
                        chunks = chunk_markdown_text(text)
                        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                        size_bytes = len(text.encode("utf-8"))
                        user_id = doc["user_id"]
                    else:
                        start_line, end_line, text, capture_user = chunk_json_capture(path)
                        chunks = [(start_line, end_line, text)]
                        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                        size_bytes = len(text.encode("utf-8"))
                        user_id = capture_user or doc["user_id"]
                except OSError as exc:
                    # Issue #1947: a single doc owned by an iso UID (0600/0700)
                    # may be unreadable to the controller running the rebuild.
                    # Skip it with a warning instead of aborting the rebuild.
                    print(f"note: skipping unreadable doc {path}: {exc}", file=sys.stderr)
                    skipped_count += 1
                    continue

                conn.execute(
                    """
                    INSERT INTO documents(path, kind, user_id, format, sha256, size_bytes, indexed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (relpath, doc["kind"], user_id, doc["format"], digest, size_bytes, indexed_at),
                )
                for start_line, end_line, text in chunks:
                    if not text.strip():
                        continue
                    # v2 uses the same schema; differs only in source-kind
                    # diversity and the meta.index_kind value. Embeddings are
                    # left empty; if/when a Gemini-backed embedder runs, it
                    # can UPDATE embedding in-place. Search falls back to
                    # keyword-only until embeddings exist (see
                    # `_index_has_embeddings` in tools/memory-manager.py).
                    # `chunks.source` is set to `doc["kind"]` so memory-manager
                    # search can filter via `--source`.
                    conn.execute(
                        """
                        INSERT INTO chunks(path, source, model, kind, user_id, start_line, end_line, text, embedding)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]')
                        """,
                        (relpath, doc["kind"], index_kind, doc["kind"], user_id, start_line, end_line, text),
                    )
                    chunk_count += 1

            conn.executemany(
                "INSERT INTO meta(key, value) VALUES (?, ?)",
                {
                    "index_kind": index_kind,
                    "agent": args.agent,
                    "home": str(home),
                    "shared_root": str(shared_root) if shared_root else "",
                    "indexed_at": indexed_at,
                    "document_count": str(len(documents) - skipped_count),
                    "chunk_count": str(chunk_count),
                }.items(),
            )
            conn.commit()
        finally:
            conn.close()
    else:
        for doc in documents:
            try:
                if doc["format"] == "markdown":
                    chunk_count += len(chunk_markdown_text(read_text(doc["path"])))
                else:
                    # Issue #1947: actually read the JSON capture (as the
                    # non-dry-run path does via chunk_json_capture) so an
                    # unreadable JSON doc is skipped here too — otherwise the
                    # dry-run count would diverge from the real rebuild.
                    chunk_json_capture(doc["path"])
                    chunk_count += 1
            except OSError as exc:
                # Issue #1947: match the non-dry-run skip so a dry-run over an
                # iso tree the controller cannot read reports rather than aborts.
                print(f"note: skipping unreadable doc {doc['path']}: {exc}", file=sys.stderr)
                skipped_count += 1

    payload = {
        "agent": args.agent,
        "db_path": str(db_path),
        "index_kind": index_kind,
        "shared_root": str(shared_root) if shared_root else "",
        "document_count": len(documents) - skipped_count,
        "chunk_count": chunk_count,
        "skipped_count": skipped_count,
        "indexed_at": indexed_at,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"db_path: {db_path}")
        print(f"index_kind: {index_kind}")
        if shared_root:
            print(f"shared_root: {shared_root}")
        print(f"document_count: {len(documents) - skipped_count}")
        print(f"chunk_count: {chunk_count}")
        if skipped_count:
            print(f"skipped_count: {skipped_count}")
        print(f"dry_run: {'yes' if args.dry_run else 'no'}")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    home = Path(args.home)
    bridge_home = Path(args.bridge_home)
    db_path = Path(args.db_path) if args.db_path else default_index_db_path(bridge_home, args.agent)
    if not db_path.exists():
        fallback = argparse.Namespace(**vars(args))
        fallback.scope = "all" if args.scope == "all" else args.scope
        return cmd_search(fallback)

    fts_query = build_fts_query(args.query)
    if not fts_query:
        die("query is empty")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        clauses = ["chunks_fts MATCH ?"]
        params: list[object] = [fts_query]
        if args.user:
            # Issue #162 Phase 2 (codex review finding): agent-pref rows
            # are indexed with empty user_id (kind is user-agnostic), so a
            # naive `user_id = ?` filter drops them for any --user query.
            # cmd_search does not apply this clause and correctly returns
            # agent-pref; mirror that behaviour here by letting agent-pref
            # rows through regardless of the user filter.
            clauses.append("(chunks.user_id = ? OR chunks.kind = 'agent-pref')")
            params.append(args.user)
        if args.scope != "all":
            if args.scope == "wiki":
                clauses.append("chunks.kind NOT LIKE 'raw-%'")
            elif args.scope == "raw":
                clauses.append("chunks.kind LIKE 'raw-%'")
            elif args.scope == "user":
                clauses.append("chunks.kind IN ('user-profile', 'user-memory')")
            elif args.scope == "daily":
                clauses.append("chunks.kind = 'daily'")
            elif args.scope == "shared":
                clauses.append("chunks.kind = 'shared'")
            elif args.scope == "project":
                clauses.append("chunks.kind = 'project'")
            elif args.scope == "decision":
                clauses.append("chunks.kind = 'decision'")
        params.append(int(args.limit))
        rows = conn.execute(
            f"""
            SELECT
              chunks.kind,
              chunks.user_id,
              chunks.path,
              chunks.start_line,
              chunks.end_line,
              bm25(chunks_fts) AS rank,
              snippet(chunks_fts, 0, '', '', ' ... ', 20) AS snippet
            FROM chunks_fts
            JOIN chunks ON chunks.id = chunks_fts.rowid
            WHERE {' AND '.join(clauses)}
            ORDER BY rank ASC
            LIMIT ?
            """,
            params,
        ).fetchall()
    finally:
        conn.close()

    results = []
    for row in rows:
        rank = row["rank"]
        if isinstance(rank, (int, float)):
            score = (-float(rank) / (1 + -float(rank))) if float(rank) < 0 else 1 / (1 + float(rank))
        else:
            score = 0.0
        results.append(
            {
                "kind": row["kind"],
                "user_id": row["user_id"],
                "path": str(home / row["path"]),
                "relative_path": row["path"],
                "start_line": row["start_line"],
                "end_line": row["end_line"],
                "score": score,
                "snippet": (row["snippet"] or "").strip(),
            }
        )

    payload = {
        "agent": args.agent,
        "query": args.query,
        "scope": args.scope,
        "user": args.user or "",
        "backend": "index",
        "db_path": str(db_path),
        "count": len(results),
        "results": results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        print("backend: index")
        print(f"matches: {len(results)}")
        for item in results:
            print(f"- [{item['kind']}] {item['relative_path']}:{item['start_line']}-{item['end_line']} (score={item['score']:.4f})")
            if item["snippet"]:
                print(f"  {item['snippet']}")
    return 0


# ---------------------------------------------------------------------------
# summarize weekly / monthly (cascading summarizer)
# ---------------------------------------------------------------------------

def _parse_iso_week(value: str) -> tuple[int, int]:
    """Parse `YYYY-W##` into (year, week_number). Raise SystemExit on bad format."""
    match = re.fullmatch(r"(\d{4})-W(\d{2})", value.strip())
    if not match:
        die(f"invalid --week (expected YYYY-W##): {value}")
    return int(match.group(1)), int(match.group(2))


def _previous_iso_week() -> tuple[int, int]:
    today = datetime.now().astimezone().date()
    monday_this = today - timedelta(days=today.isoweekday() - 1)
    prev_any_day = monday_this - timedelta(days=3)  # safely inside last week
    year, week, _ = prev_any_day.isocalendar()
    return year, week


def _iso_week_range(year: int, week: int) -> tuple[datetime, datetime]:
    monday = datetime.fromisocalendar(year, week, 1)
    sunday = datetime.fromisocalendar(year, week, 7)
    return monday, sunday


def _daily_notes_base(home: Path, user: str) -> Path:
    """Resolve the daily-notes root.

    Contract (issue #220): the canonical daily-note root is `<home>/memory`
    for every user, including `default`. There is no per-user variant — the
    actual writer (`_daily_note_path` / `cmd_daily_append`) takes no `user`
    argument and always lands in `<home>/memory/<date>.md`. The `user`
    parameter is retained on the read-side summarizer API for backwards
    compatibility but it no longer changes the resolved path. A
    multi-tenant install that has manually staged daily notes under
    `<home>/users/<user>/memory/` should run `bridge-memory.py
    migrate-canonical --user <user>` to fold them into the shared root.
    """
    del user  # unified path; argument retained for API stability
    return home / "memory"


def _collect_daily_notes(home: Path, user: str, start: datetime, end: datetime) -> list[Path]:
    base = _daily_notes_base(home, user)
    if not base.exists():
        return []
    out: list[Path] = []
    cur = start.date()
    while cur <= end.date():
        candidate = base / f"{cur.isoformat()}.md"
        if candidate.exists():
            out.append(candidate)
        cur = cur + timedelta(days=1)
    return out


def _collect_ingested_captures(home: Path, start: datetime, end: datetime) -> list[Path]:
    ingested = home / "raw" / "captures" / "ingested"
    if not ingested.exists():
        return []
    out: list[Path] = []
    for path in sorted(ingested.glob("*.json")):
        try:
            payload = json.loads(read_text(path))
        except (OSError, json.JSONDecodeError):
            continue
        created_raw = payload.get("created_at") or ""
        try:
            ts = datetime.fromisoformat(created_raw)
        except ValueError:
            continue
        if ts.tzinfo is not None:
            ts = ts.replace(tzinfo=None)
        if start <= ts <= end:
            out.append(path)
    return out


def _llm_summarize(prompt: str, model: str = "") -> str | None:
    """Best-effort LLM summarization via claude CLI. Returns None on any failure."""
    claude = shutil.which("claude")
    if not claude:
        return None
    command = [claude, "-p", *singleton_channel_suppression_argv(), "--no-session-persistence", "--dangerously-skip-permissions", "--output-format", "text"]
    if model:
        command.extend(["--model", model])
    command.append(prompt)
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=90, check=True)
        return completed.stdout.strip() or None
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def _fallback_merge(sources: list[Path]) -> str:
    """Heading-based fallback merge when no LLM is available."""
    chunks: list[str] = []
    for path in sources:
        try:
            text = read_text(path)
        except OSError:
            continue
        headings = [line for line in text.splitlines() if line.startswith("#")]
        if headings:
            chunks.append(f"### {path.name}\n" + "\n".join(headings[:10]))
    return "\n\n".join(chunks) if chunks else "(no source headings available)"


def cmd_summarize_weekly(args: argparse.Namespace) -> int:
    home = Path(args.home)
    user = args.user or "default"
    if args.week:
        year, week = _parse_iso_week(args.week)
    else:
        year, week = _previous_iso_week()
    start, end = _iso_week_range(year, week)

    daily_notes = _collect_daily_notes(home, user, start, end)
    ingested = _collect_ingested_captures(home, start, end)

    header = f"# {year}-W{week:02d} Weekly Summary\n\n"
    header += f"Range: {start.date().isoformat()} .. {end.date().isoformat()}\n"
    header += f"Agent: {args.agent}\n"
    header += f"User: {user}\n\n"

    if args.llm and daily_notes + ingested:
        chunks: list[str] = []
        for p in (daily_notes + ingested[:8]):
            excerpt = _safe_excerpt(p, 2000)
            if excerpt is not None:
                chunks.append(f"## {p.name}\n{excerpt}")
        excerpt_text = "\n\n".join(chunks)
        prompt = (
            "Summarize this agent's week. Extract: (1) major events, "
            "(2) explicit user/operator decisions, (3) numeric results "
            "that changed, (4) unresolved items carried to next week. "
            "Return plain markdown with these four sub-sections.\n\n"
            f"{excerpt_text}"
        )
        body = _llm_summarize(prompt, args.llm_model) or _fallback_merge(daily_notes + ingested)
    else:
        body = _fallback_merge(daily_notes + ingested)

    out_path = home / "memory" / "weekly" / f"{year}-W{week:02d}.md"
    write_text(out_path, header + body + "\n", args.dry_run)

    log_line = (
        f"- {datetime.now().astimezone().isoformat(timespec='seconds')} "
        f"kind=summarize-weekly target=`{out_path.relative_to(home)}` "
        f"sources={len(daily_notes)}+{len(ingested)}\n"
    )
    append_text(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "user": user,
        "year": year,
        "week": week,
        "range": [start.date().isoformat(), end.date().isoformat()],
        "daily_note_count": len(daily_notes),
        "ingested_count": len(ingested),
        "output": str(out_path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"weekly: {out_path}")
        print(f"sources: daily={len(daily_notes)} ingested={len(ingested)}")
    return 0


def cmd_summarize_monthly(args: argparse.Namespace) -> int:
    home = Path(args.home)
    user = args.user or "default"
    if args.month:
        match = re.fullmatch(r"(\d{4})-(\d{2})", args.month.strip())
        if not match:
            die(f"invalid --month (expected YYYY-MM): {args.month}")
        year, month = int(match.group(1)), int(match.group(2))
    else:
        today = datetime.now().astimezone().date()
        first_this = today.replace(day=1)
        last_prev = first_this - timedelta(days=1)
        year, month = last_prev.year, last_prev.month

    month_start = datetime(year, month, 1).astimezone()
    if month == 12:
        month_end = datetime(year + 1, 1, 1).astimezone() - timedelta(seconds=1)
    else:
        month_end = datetime(year, month + 1, 1).astimezone() - timedelta(seconds=1)

    weekly_dir = home / "memory" / "weekly"
    weekly_notes: list[Path] = []
    if weekly_dir.exists():
        for path in sorted(weekly_dir.glob("*.md")):
            match = re.fullmatch(r"(\d{4})-W(\d{2})\.md", path.name)
            if not match:
                continue
            wy, ww = int(match.group(1)), int(match.group(2))
            try:
                week_start = datetime.fromisocalendar(wy, ww, 1).astimezone()
                week_end = (datetime.fromisocalendar(wy, ww, 7)
                            .astimezone() + timedelta(hours=23, minutes=59, seconds=59))
            except ValueError:
                continue
            # Include the week if *any* day of it falls inside the target month.
            if week_end < month_start or week_start > month_end:
                continue
            weekly_notes.append(path)

    daily_notes = _collect_daily_notes(home, user, month_start, month_end)

    header = f"# {year}-{month:02d} Monthly Summary\n\n"
    header += f"Agent: {args.agent}\nUser: {user}\n\n"

    if args.llm and (weekly_notes or daily_notes):
        chunks: list[str] = []
        for p in (weekly_notes + daily_notes[:10]):
            excerpt = _safe_excerpt(p, 2500)
            if excerpt is not None:
                chunks.append(f"## {p.name}\n{excerpt}")
        excerpt_text = "\n\n".join(chunks)
        prompt = (
            "Summarize this agent's month. Extract: (1) monthly trends, "
            "(2) major decisions, (3) recurring patterns, (4) in-flight "
            "long-running projects. Flag any daily notes older than 60 "
            "days as candidates for archive-only retention. Return plain "
            "markdown with these sub-sections.\n\n"
            f"{excerpt_text}"
        )
        body = _llm_summarize(prompt, args.llm_model) or _fallback_merge(weekly_notes + daily_notes)
    else:
        body = _fallback_merge(weekly_notes + daily_notes)

    out_path = home / "memory" / "monthly" / f"{year}-{month:02d}.md"
    write_text(out_path, header + body + "\n", args.dry_run)

    log_line = (
        f"- {datetime.now().astimezone().isoformat(timespec='seconds')} "
        f"kind=summarize-monthly target=`{out_path.relative_to(home)}` "
        f"sources={len(weekly_notes)}w+{len(daily_notes)}d\n"
    )
    append_text(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "user": user,
        "year": year,
        "month": month,
        "weekly_count": len(weekly_notes),
        "daily_count": len(daily_notes),
        "output": str(out_path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"monthly: {out_path}")
        print(f"sources: weekly={len(weekly_notes)} daily={len(daily_notes)}")
    return 0


_RECONCILE_MARKERS = (
    # phrase must look like an explicit contradiction statement, not a bare word.
    "is no longer",
    "is incorrect",
    "is deprecated",
    "superseded by",
    "was wrong",
    "should be",
    "actually,",
)


def _unique_report_path(out_dir: Path, ts: str, suffix: str) -> Path:
    """Return a non-colliding report path under `out_dir`. Adds `-pid-N` as needed."""
    pid = os.getpid()
    candidate = out_dir / f"{ts}-{pid}-{suffix}.json"
    counter = 0
    while candidate.exists():
        counter += 1
        candidate = out_dir / f"{ts}-{pid}-{counter}-{suffix}.json"
    return candidate


def _resolve_bridge_bin() -> Path | None:
    """Resolve the `agent-bridge` CLI binary, honoring BRIDGE_HOME and install-relative layout."""
    candidates: list[Path] = []
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        candidates.append(Path(env_home) / "agent-bridge")
    script_dir = Path(__file__).resolve().parent
    candidates.append(script_dir / "agent-bridge")
    candidates.append(Path.home() / ".agent-bridge" / "agent-bridge")
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c
    return None


def _reconcile_task_exists(agent: str) -> bool:
    """Return True if there is an existing open reconcile task for `agent`."""
    binary = _resolve_bridge_bin()
    if binary is None:
        return False
    try:
        completed = subprocess.run(
            [str(binary), "inbox", "patch", "--json"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    try:
        rows = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError:
        return False
    needle = f"[reconcile] {agent}"
    for row in rows if isinstance(rows, list) else []:
        title = (row.get("title") or "") if isinstance(row, dict) else ""
        status = (row.get("status") or "") if isinstance(row, dict) else ""
        if status in {"queued", "claimed", "blocked"} and title.startswith(needle):
            return True
    return False


def cmd_reconcile(args: argparse.Namespace) -> int:
    """Flag candidate memory/wiki contradictions (heuristic).

    Limitation (by design): this is a *candidate* flagger driven by explicit
    contradiction phrases in the agent's memory notes that are absent from the
    canonical wiki page. False positives are possible (editorial prose) and
    false negatives are common (semantic contradictions without marker words).
    Use output as input for human review, not as a final verdict.
    """
    home = Path(args.home)
    shared_root = Path(args.shared_root) if args.shared_root else None
    now = datetime.now().astimezone()
    ts = now.strftime("%Y%m%dT%H%M%S")
    out_dir = home / "raw" / "captures" / "conflicts"
    out_path = _unique_report_path(out_dir, ts, "reconcile")

    conflicts: list[dict] = []
    if shared_root and shared_root.exists():
        wiki_pages = list((shared_root / "wiki").rglob("*.md")) if (shared_root / "wiki").exists() else []
        mem_pages = list((home / "memory").rglob("*.md"))
        wiki_stems: dict[str, Path] = {}
        for p in wiki_pages:
            # Prefer the first occurrence; if a stem collides, don't stomp.
            wiki_stems.setdefault(p.stem, p)
        for mp in mem_pages:
            if mp.stem not in wiki_stems:
                continue
            try:
                mem_text = read_text(mp).lower()
                wiki_text = read_text(wiki_stems[mp.stem]).lower()
            except (OSError, UnicodeDecodeError):
                continue
            hits: list[str] = []
            for marker in _RECONCILE_MARKERS:
                if marker in mem_text and marker not in wiki_text:
                    hits.append(marker)
            if hits:
                conflicts.append({
                    "stem": mp.stem,
                    "memory_path": str(mp),
                    "wiki_path": str(wiki_stems[mp.stem]),
                    "markers": hits,
                })

    report = {
        "agent": args.agent,
        "timestamp": ts,
        "pid": os.getpid(),
        "shared_root": str(shared_root) if shared_root else None,
        "conflict_count": len(conflicts),
        "conflicts": conflicts,
        "caveat": "heuristic flagger; requires human review",
    }
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
        # Atomic write.
        tmp = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8",
            dir=str(out_dir), prefix=f".{out_path.name}.", suffix=".tmp",
            delete=False,
        )
        try:
            tmp.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            tmp.flush()
            os.fsync(tmp.fileno())
        finally:
            tmp.close()
        os.replace(tmp.name, out_path)

    task_created = False
    task_skipped_reason: str | None = None
    if conflicts and args.create_task and not args.dry_run:
        if _reconcile_task_exists(args.agent):
            task_skipped_reason = "existing open reconcile task"
        else:
            binary = _resolve_bridge_bin()
            if binary is None:
                task_skipped_reason = "agent-bridge binary not found"
            else:
                try:
                    completed = subprocess.run(
                        [
                            str(binary),
                            "task", "create",
                            "--to", "patch",
                            "--priority", "normal",
                            "--title", f"[reconcile] {args.agent}: {len(conflicts)} memory/wiki conflict(s)",
                            "--body", f"Reconcile report: {out_path}\nConflicts: {len(conflicts)}",
                        ],
                        check=False,
                        timeout=15,
                        capture_output=True,
                        text=True,
                    )
                    if completed.returncode == 0:
                        task_created = True
                    else:
                        task_skipped_reason = (
                            f"task create exited with rc={completed.returncode}: "
                            f"{(completed.stderr or completed.stdout or '').strip()[:200]}"
                        )
                except (OSError, subprocess.TimeoutExpired) as exc:
                    task_skipped_reason = f"task create failed: {exc}"

    report["task_created"] = task_created
    if task_skipped_reason:
        report["task_skipped_reason"] = task_skipped_reason

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"conflicts: {len(conflicts)}")
        print(f"report: {out_path}")
        if task_skipped_reason:
            print(f"task: skipped ({task_skipped_reason})")
        elif task_created:
            print("task: created")
    return 0 if not conflicts else 2


# ---------------------------------------------------------------------------
# migrate-canonical (issue #220) — fold legacy `<home>/users/<user>/memory/`
# daily notes into the unified `<home>/memory/` root. Idempotent. Default is
# dry-run; --apply performs the move and writes a `_migration_log.json`
# manifest under `<home>/memory/`.
# ---------------------------------------------------------------------------


_MIGRATION_LOG_NAME = "_migration_log.json"


def _migration_legacy_root(home: Path, user: str) -> Path:
    user_id = user or "default"
    return home / "users" / user_id / "memory"


def _migration_collect_candidates(legacy_root: Path) -> list[Path]:
    """Return *.md files in the legacy root, excluding the manifest itself."""
    if not legacy_root.exists() or not legacy_root.is_dir():
        return []
    out: list[Path] = []
    for path in sorted(legacy_root.glob("*.md")):
        if path.name == _MIGRATION_LOG_NAME:
            continue
        out.append(path)
    return out


def _migration_collision_target(canonical_root: Path, source: Path) -> Path:
    """Return `<date>.legacy.md` in the canonical root, suffixed if needed."""
    stem = source.stem
    base = canonical_root / f"{stem}.legacy.md"
    if not base.exists():
        return base
    counter = 1
    while True:
        candidate = canonical_root / f"{stem}.legacy.{counter}.md"
        if not candidate.exists():
            return candidate
        counter += 1


def cmd_migrate_canonical(args: argparse.Namespace) -> int:
    """Migrate legacy `<home>/users/<user>/memory/*.md` → `<home>/memory/*.md`.

    Default mode is dry-run (no `--apply`). Idempotent: a second run on a
    converged install reports `moved=[]`. On collision (the same date note
    exists in both roots) the legacy file is renamed to
    `<date>.legacy.md` in the canonical root and an admin task is filed
    best-effort. The migration manifest lands at
    `<home>/memory/_migration_log.json` on `--apply`.
    """
    home = Path(args.home).expanduser()
    user = args.user or "default"
    apply = bool(args.apply)

    # Issue #220 follow-up safeguard (codex review of PR #296): _resolve_bridge_bin
    # always routes admin task creation through the LIVE BRIDGE_HOME's binary,
    # so an --apply against a non-live --home will still file collision tasks
    # in the live queue (the fixer accidentally triggered task #1373 this way).
    # Refuse --apply when --home looks like the live install unless the operator
    # explicitly asserts they meant it via --i-know-this-is-live.
    if apply and not bool(getattr(args, "i_know_this_is_live", False)):
        live_home_env = os.environ.get("BRIDGE_HOME")
        live_home = Path(live_home_env).expanduser().resolve() if live_home_env else (Path.home() / ".agent-bridge").resolve()
        if home.resolve() == live_home:
            sys.stderr.write(
                f"[migrate-canonical] refusing --apply against live BRIDGE_HOME ({live_home}); "
                f"pass --i-know-this-is-live to override.\n"
            )
            return 2

    legacy_root = _migration_legacy_root(home, user)
    canonical_root = home / "memory"

    candidates = _migration_collect_candidates(legacy_root)
    moved: list[dict] = []
    collisions: list[dict] = []
    skipped: list[dict] = []

    if apply:
        canonical_root.mkdir(parents=True, exist_ok=True)

    for src in candidates:
        target = canonical_root / src.name
        try:
            size = src.stat().st_size
        except OSError:
            size = 0
        if target.exists():
            collision_target = _migration_collision_target(canonical_root, src)
            collisions.append({
                "from": str(src),
                "to": str(collision_target),
                "reason": "canonical_exists",
            })
            if apply:
                try:
                    os.replace(src, collision_target)
                except OSError as exc:
                    skipped.append({"path": str(src), "reason": f"rename_failed: {exc}"})
        else:
            moved.append({"from": str(src), "to": str(target), "bytes": size})
            if apply:
                try:
                    os.replace(src, target)
                except OSError as exc:
                    # Roll back the moved-list entry: the file did not actually move.
                    moved.pop()
                    skipped.append({"path": str(src), "reason": f"rename_failed: {exc}"})

    manifest = {
        "schema": "memory-canonical-migration-v1",
        "home": str(home),
        "user": user,
        "legacy_root": str(legacy_root),
        "canonical_root": str(canonical_root),
        "ran_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "dry_run": not apply,
        "moved": moved,
        "collisions": collisions,
        "skipped": skipped,
    }

    manifest_path: Path | None = None
    if apply:
        canonical_root.mkdir(parents=True, exist_ok=True)
        manifest_path = canonical_root / _MIGRATION_LOG_NAME
        # Merge with prior manifest so multi-run history survives.
        prior_runs: list[dict] = []
        if manifest_path.exists():
            try:
                prior = json.loads(manifest_path.read_text(encoding="utf-8"))
                if isinstance(prior, dict):
                    prior_runs = list(prior.get("runs") or [])
                    # Single-run legacy file → fold the prior single record into runs[].
                    if not prior_runs and prior.get("schema") == manifest["schema"]:
                        prior_runs = [prior]
            except (OSError, json.JSONDecodeError):
                prior_runs = []
        manifest["runs"] = prior_runs + [{
            "ran_at": manifest["ran_at"],
            "moved": moved,
            "collisions": collisions,
            "skipped": skipped,
        }]
        tmp = manifest_path.with_suffix(manifest_path.suffix + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, manifest_path)

    # Best-effort admin task on collisions (apply only).
    task_created = False
    task_skipped_reason: str | None = None
    if apply and collisions:
        binary = _resolve_bridge_bin()
        if binary is None:
            task_skipped_reason = "agent-bridge binary not found"
        else:
            try:
                completed = subprocess.run(
                    [
                        str(binary),
                        "task", "create",
                        "--to", "patch",
                        "--priority", "normal",
                        "--title",
                        f"[memory-canonical] {len(collisions)} collision(s) under {home.name}",
                        "--body",
                        f"Migration manifest: {manifest_path}\n"
                        f"Legacy root: {legacy_root}\n"
                        f"Collisions: {len(collisions)} (legacy renamed to <date>.legacy.md)",
                    ],
                    check=False,
                    timeout=15,
                    capture_output=True,
                    text=True,
                )
                if completed.returncode == 0:
                    task_created = True
                else:
                    task_skipped_reason = (
                        f"task create exited with rc={completed.returncode}: "
                        f"{(completed.stderr or completed.stdout or '').strip()[:200]}"
                    )
            except (OSError, subprocess.TimeoutExpired) as exc:
                task_skipped_reason = f"task create failed: {exc}"

    payload = dict(manifest)
    payload["manifest_path"] = str(manifest_path) if manifest_path else ""
    payload["task_created"] = task_created
    if task_skipped_reason:
        payload["task_skipped_reason"] = task_skipped_reason

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        mode = "apply" if apply else "dry-run"
        print(f"mode: {mode}")
        print(f"legacy_root: {legacy_root}")
        print(f"canonical_root: {canonical_root}")
        print(f"moved: {len(moved)}")
        print(f"collisions: {len(collisions)}")
        print(f"skipped: {len(skipped)}")
        if manifest_path:
            print(f"manifest: {manifest_path}")
        if task_skipped_reason:
            print(f"task: skipped ({task_skipped_reason})")
        elif task_created:
            print("task: created")

    # Exit code: 0 on clean, 2 on collisions (so cron / CI can flag).
    return 0 if not collisions else 2


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


def _kst_now() -> datetime:
    """Current time in the Asia/Seoul zone, independent of host tz."""
    from datetime import timezone, timedelta
    try:
        from zoneinfo import ZoneInfo  # Python 3.9+
        return datetime.now(ZoneInfo("Asia/Seoul"))
    except Exception:
        # Fallback for interpreters without tzdata: KST is fixed +09:00,
        # no DST, so a hard offset is safe.
        return datetime.now(timezone(timedelta(hours=9)))


def _now_iso_kst() -> str:
    """ISO8601 timestamp in Asia/Seoul (+09:00), regardless of host tz."""
    return _kst_now().strftime("%Y-%m-%dT%H:%M:%S+09:00")


def _today_kst() -> str:
    return _kst_now().strftime("%Y-%m-%d")


def _daily_note_path(home: Path, date: str) -> Path:
    return Path(home) / "memory" / f"{date}.md"


def _read_meta_block(text: str) -> tuple[dict, str]:
    """Return (meta_dict, remainder_after_meta_line). Empty dict if no meta."""
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
    # strip the meta line + trailing newline if any
    remainder = text[:start] + text[end:].lstrip("\n")
    return meta, remainder


def _render_meta_block(meta: dict) -> str:
    return DAILY_META_MARKER + json.dumps(meta, ensure_ascii=False, sort_keys=False) + DAILY_META_END


def _split_sections(body: str) -> list[tuple[str | None, str]]:
    """Return [(session_id or None, section_text)]. Preamble comes first as (None, text)."""
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


def _assemble_daily_note(title: str, meta: dict, sections: list[tuple[str | None, str]]) -> str:
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


def _ensure_daily_note_skeleton(path: Path, date: str, agent: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "schema_version": 1,
        "session_ids": [],
        "writer_mix": {},
        "last_reconciled_at": _now_iso_kst(),
    }
    text = (
        _render_meta_block(meta) + "\n"
        f"\n# {date} — {agent}\n\n"
    )
    path.write_text(text, encoding="utf-8")


def _parse_daily_note(text: str, date: str, agent: str) -> tuple[dict, str, list[tuple[str | None, str]]]:
    meta, body = _read_meta_block(text)
    # Extract title (first H1) if present.
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
            "last_reconciled_at": _now_iso_kst(),
        }
    sections = _split_sections(body.lstrip("\n"))
    return meta, title, sections


def _session_section_header(session_id: str, writer: str) -> str:
    return f"## Session {session_id} — {writer}"


def cmd_current_session_id(args: argparse.Namespace) -> int:
    """Best-effort session_id for the agent calling this script.

    Returns the UUID of the most recently modified JSONL under the
    Claude project directory that matches `--home`. Claude scopes
    transcripts by the git root of the session cwd, so `--home` here is
    the **session workdir** (the cwd the agent was spawned in), not the
    agent's bridge runtime home — those can differ when an agent is
    pointed at an external project checkout. The wrap-up slash command
    template passes `BRIDGE_AGENT_WORKDIR` for exactly that reason.
    Claude Code exposes the session id via hook stdin but has no
    documented env var for slash commands, so we read from disk.

    Issue #412 Track C: under linux-user isolation `~/.claude/projects/`
    resolves to the isolated UID's home, but `--home` is the
    controller-side path passed in from the wrap-up command. The two
    don't agree on what "this agent's project dir" means, so the scan
    looks under a slug the isolated UID has never written. Callers under
    isolation pass `--transcripts-home <isolated-home>/.claude/projects`
    (or just `<isolated-home>`) to override the projects-dir root.
    Mirrors the harvester's --transcripts-home pattern.
    """
    import os as _os
    if args.transcripts_home:
        # Operator may pass either the projects-dir directly
        # (`/home/<os_user>/.claude/projects`) or the user home
        # (`/home/<os_user>`). Accept both: when the path ends in
        # `.claude/projects` use it as-is; otherwise treat it as $HOME
        # equivalent and append `.claude/projects`.
        override = Path(args.transcripts_home).expanduser()
        if override.name == "projects" and override.parent.name == ".claude":
            projects_dir = override
        else:
            projects_dir = override / ".claude" / "projects"
    else:
        projects_dir = Path(args.claude_projects).expanduser()
    home = Path(args.home).expanduser().resolve()
    # Match Anthropic's ~/.claude/projects/ slug convention (see
    # bridge-agent.sh:bridge_ensure_auto_memory_isolation).
    project_slug = str(home).replace(_os.sep, "-").replace(".", "-")
    project_dir = projects_dir / project_slug
    if not project_dir.is_dir():
        sys.stderr.write(
            f"[bridge-memory] no Claude project dir at {project_dir}. "
            f"Is BRIDGE_AGENT_ID={args.agent} and --home={args.home} correct?\n"
        )
        return 1
    candidates: list[tuple[float, str]] = []
    for jsonl in project_dir.glob("*.jsonl"):
        try:
            candidates.append((jsonl.stat().st_mtime, jsonl.stem))
        except OSError:
            continue
    if not candidates:
        sys.stderr.write(
            f"[bridge-memory] no transcripts found in {project_dir}. "
            "Has any session run from this home yet?\n"
        )
        return 1
    candidates.sort(reverse=True)
    print(candidates[0][1])
    return 0


def cmd_daily_append(args: argparse.Namespace) -> int:
    """Append or replace a session section inside the agent's daily note.

    writer=session sections may replace an earlier section with the same
    session_id (re-runs). writer=cron sections never overwrite anything
    a session has already written.
    """
    home = Path(args.home).expanduser()
    date = args.date or _today_kst()
    note_path = _daily_note_path(home, date)

    if args.content_from_stdin:
        content = sys.stdin.read()
    elif args.content_file:
        content = Path(args.content_file).expanduser().read_text(encoding="utf-8")
    else:
        sys.stderr.write("daily-append requires --content-from-stdin or --content-file\n")
        return 2

    content = content.rstrip() + "\n"

    _ensure_daily_note_skeleton(note_path, date, args.agent)
    raw = note_path.read_text(encoding="utf-8")
    meta, title, sections = _parse_daily_note(raw, date, args.agent)

    header = _session_section_header(args.session_id, args.writer)
    section_text = f"{header}\n\n{content}"

    session_ids = list(meta.get("session_ids") or [])
    writer_mix = dict(meta.get("writer_mix") or {})

    existing_index: int | None = None
    existing_writer: str | None = None
    for idx, (sid, text) in enumerate(sections):
        if sid == args.session_id:
            existing_index = idx
            header_match = re.match(r"^## Session \S+\s+—\s+(\S+)", text)
            existing_writer = header_match.group(1) if header_match else None
            break

    # writer_mix counts *sections* per writer, so increments happen only
    # when a new section is materialised, not on re-runs that just
    # rewrite the body. A replace that also changes writer decrements
    # the previous writer before incrementing the new one; a same-writer
    # replace is a net no-op.
    applied = "appended"
    materialised_new_section = False
    if existing_index is not None:
        if args.writer == "cron" and existing_writer == "session":
            applied = "skipped (session writer already present)"
        else:
            old_session, _ = sections[existing_index]
            sections[existing_index] = (old_session, section_text)
            applied = "replaced"
            if existing_writer and existing_writer != args.writer:
                writer_mix[existing_writer] = max(0, writer_mix.get(existing_writer, 0) - 1)
                writer_mix[args.writer] = writer_mix.get(args.writer, 0) + 1
    else:
        sections.append((args.session_id, section_text))
        materialised_new_section = True

    if materialised_new_section:
        if args.session_id not in session_ids:
            session_ids.append(args.session_id)
        writer_mix[args.writer] = writer_mix.get(args.writer, 0) + 1

    meta["session_ids"] = session_ids
    meta["writer_mix"] = writer_mix
    meta["last_reconciled_at"] = _now_iso_kst()
    meta.setdefault("schema_version", 1)

    assembled = _assemble_daily_note(title, meta, sections)
    tmp = note_path.with_suffix(note_path.suffix + ".tmp")
    tmp.write_text(assembled, encoding="utf-8")
    import os as _os
    _os.replace(tmp, note_path)

    report = {
        "agent": args.agent,
        "date": date,
        "note_path": str(note_path),
        "session_id": args.session_id,
        "writer": args.writer,
        "applied": applied,
        "session_count": len(session_ids),
        "writer_mix": writer_mix,
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(f"{applied} session {args.session_id[:12]} writer={args.writer} in {note_path}")
    return 0


# ---------------------------------------------------------------------------
# harvest-daily (issue #216) — detection-only per-agent daily note harvester.
# Pure observation: no LLM, no daily-note mutation, no downstream compat.
# ---------------------------------------------------------------------------


DAILY_TAG_LINE_RE = re.compile(r"(^tags:\s+.+$)|(^#\S+(\s+#\S+)*\s*$)", re.MULTILINE)
DAILY_BULLET_RE = re.compile(r"^\s*([-*+]|\d+\.)\s+\S", re.MULTILINE)


def _harvest_now_iso(tz_name: str) -> str:
    from datetime import timezone as _tz, timedelta as _td
    try:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo(tz_name)).isoformat(timespec="seconds")
    except Exception:
        return datetime.now(_tz(_td(hours=9))).isoformat(timespec="seconds")


def _harvest_tz_zone(tz_name: str):
    from datetime import timezone as _tz, timedelta as _td
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(tz_name)
    except Exception:
        return _tz(_td(hours=9))


def _harvest_default_date(tz_name: str) -> str:
    zone = _harvest_tz_zone(tz_name)
    return (datetime.now(zone) - timedelta(days=1)).date().isoformat()


def _harvest_date_window(date_str: str, tz_name: str) -> tuple[datetime, datetime]:
    zone = _harvest_tz_zone(tz_name)
    y, m, d = (int(x) for x in date_str.split("-"))
    start = datetime(y, m, d, 0, 0, 0, tzinfo=zone)
    end = start + timedelta(days=1) - timedelta(microseconds=1)
    return start, end


def _workdir_slug_candidates(workdir_path: str) -> list[str]:
    # Replicates lib/bridge-state.sh::workdir_slug_candidates. Claude projects
    # encode slashes (always) and sometimes dots into dashes.
    slash_only = workdir_path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", workdir_path)
    out = [slash_only]
    if slash_and_dot != slash_only:
        out.append(slash_and_dot)
    return out


def _harvest_state_dir(args: argparse.Namespace) -> Path:
    if args.state_dir:
        return Path(args.state_dir).expanduser()
    env = os.environ.get("BRIDGE_STATE_DIR")
    if env:
        return Path(env).expanduser() / "memory-daily"
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    return Path(bridge_home).expanduser() / "state" / "memory-daily"


def _per_agent_manifest_dir(args: argparse.Namespace, agent: str) -> Path:
    # PR-C contract: under v2 layout the per-agent manifest lives inside the
    # agent's private root ($BRIDGE_AGENT_ROOT_V2/<agent>/runtime/memory-daily),
    # while admin aggregates live under shared/. Callers pass the resolved
    # per-agent dir via --per-agent-state-dir; absent that flag we keep the
    # legacy <state_dir>/<agent> shape so non-v2 installs are untouched.
    override = getattr(args, "per_agent_state_dir", None)
    if override:
        return Path(override).expanduser()
    return _harvest_state_dir(args) / agent


def _shared_aggregate_dir(args: argparse.Namespace) -> Path:
    # PR-C contract: admin aggregates may live under the shared root
    # ($BRIDGE_SHARED_ROOT/memory-daily/aggregate) so the per-agent root
    # remains opaque to other isolated UIDs. Callers pass the resolved
    # shared aggregate dir via --shared-aggregate-dir; absent that flag we
    # keep the legacy <state_dir>/shared/aggregate shape.
    override = getattr(args, "shared_aggregate_dir", None)
    if override:
        return Path(override).expanduser()
    return _harvest_state_dir(args) / "shared" / "aggregate"


def _harvest_task_db(args: argparse.Namespace) -> Path:
    env = os.environ.get("BRIDGE_TASK_DB")
    if env:
        return Path(env).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    return Path(bridge_home).expanduser() / "state" / "tasks.db"


def _atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    data = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    with tmp.open("w", encoding="utf-8") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def _merge_aggregate_state(path: Path, merger) -> None:
    # Shared aggregate files are read-modify-write from per-agent cron runs;
    # fcntl.flock on a sibling .lock keeps concurrent merges serialized.
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
            current: dict = {}
            if path.exists():
                try:
                    current = json.loads(path.read_text(encoding="utf-8"))
                    if not isinstance(current, dict):
                        current = {}
                except (OSError, json.JSONDecodeError):
                    current = {}
            merged = merger(current)
            tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
            data = json.dumps(merged, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
            with tmp.open("w", encoding="utf-8") as fh:
                fh.write(data)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        finally:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def _manifest_path(args: argparse.Namespace, agent: str, date: str) -> Path:
    return _per_agent_manifest_dir(args, agent) / f"{date}.json"


def _load_manifest(args: argparse.Namespace, agent: str, date: str) -> dict | None:
    path = _manifest_path(args, agent, date)
    if not path.exists():
        return None
    try:
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    # Corrupt — rotate aside and start fresh.
    try:
        stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
        path.rename(path.with_name(path.name + f".corrupt.{stamp}"))
    except OSError:
        pass
    return None


def _write_manifest(args: argparse.Namespace, agent: str, date: str, data: dict) -> Path:
    path = _manifest_path(args, agent, date)
    _atomic_write_json(path, data)
    return path


def _parse_daily_meta(text: str) -> dict:
    match = DAILY_META_RE.search(text)
    if not match:
        return {}
    try:
        meta = json.loads(match.group("json"))
    except json.JSONDecodeError:
        return {}
    return meta if isinstance(meta, dict) else {}


def _strip_frontmatter(text: str) -> str:
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    tail = text[end + 4:]
    return tail.lstrip("\n")


def _semantic_nonempty(path: Path) -> tuple[bool, int]:
    try:
        stat = path.stat()
    except OSError:
        return False, 0
    size = stat.st_size
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False, size

    body = _strip_frontmatter(raw)
    # Drop meta marker line.
    body = DAILY_META_RE.sub("", body)
    # Drop H1 title line.
    body = re.sub(r"^\s*#\s[^\n]*\n?", "", body, count=1)
    # Drop session headers (`## Session ...`).
    body = DAILY_SECTION_HEADER_RE.sub("", body)
    # Drop Related/auto block (best-effort).
    body = re.sub(r"^##\s+Related.*?(?=^##\s|\Z)", "", body, flags=re.MULTILINE | re.DOTALL)

    has_bullet = bool(DAILY_BULLET_RE.search(body))
    content_line = False
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#") or stripped.startswith("<!--"):
            continue
        if len(stripped) >= 12:
            content_line = True
            break

    nonempty = has_bullet or content_line
    if size < 128 and not nonempty:
        return False, size
    return nonempty, size


def _probe_daily_note(home: Path, date: str) -> dict:
    path = _daily_note_path(home, date)
    if not path.exists():
        return {
            "path": str(path),
            "status": "missing",
            "size_bytes": 0,
            "has_meta_marker": False,
            "meta_schema_version": 0,
            "session_count": 0,
            "writer_mix": {},
            "has_tag_line": False,
            "semantic_nonempty": False,
        }
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        raw = ""
    meta = _parse_daily_meta(raw)
    nonempty, size = _semantic_nonempty(path)
    session_count = len(DAILY_SECTION_HEADER_RE.findall(raw))
    writer_mix = meta.get("writer_mix") if isinstance(meta.get("writer_mix"), dict) else {}
    return {
        "path": str(path),
        "status": "present" if nonempty else ("semantic-empty" if size > 0 else "missing"),
        "size_bytes": size,
        "has_meta_marker": bool(DAILY_META_RE.search(raw)),
        "meta_schema_version": int(meta.get("schema_version") or 0),
        "session_count": session_count,
        "writer_mix": writer_mix,
        "has_tag_line": bool(DAILY_TAG_LINE_RE.search(raw)),
        "semantic_nonempty": nonempty,
    }


def _probe_legacy(home: Path, date: str) -> tuple[bool, list[dict]]:
    """Probe the legacy `<home>/users/default/memory/<date>.md` path.

    Issue #220: the canonical write target is unified at `<home>/memory/`.
    The legacy probe stays around for one release so the harvester does not
    file false-positive backfill tasks on installs that were partially
    migrated. Set `BRIDGE_MEMORY_LEGACY_PROBE=0` to disable it once the
    migrate-canonical sweep is known to have run; defaults to enabled
    for backwards compatibility (target removal: v0.7).
    """
    enabled = os.environ.get("BRIDGE_MEMORY_LEGACY_PROBE", "1").strip().lower()
    if enabled in ("0", "false", "no", "off"):
        return False, []
    candidate = home / "users" / "default" / "memory" / f"{date}.md"
    checked: list[dict] = []
    present = False
    non_empty = False
    if candidate.exists():
        present = True
        try:
            text = candidate.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        non_empty = len(text.strip()) > 0
    checked.append({"path": str(candidate), "present": present, "non_empty": non_empty})
    return (present and non_empty), checked


# Self-signal filter — see issue #728.
# The memory-daily harvester must not count its own cron-dispatch events,
# prior-round backfill placeholders, or no-op "checked ok" markers as
# "real activity" — otherwise an idle librarian slot perpetually re-queues
# a backfill that consists only of its own self-signals.
SELF_SIGNAL_PATTERNS = (
    re.compile(r"^\[memory-daily\] backfill "),       # prior-round backfill task
    re.compile(r"^\[memory-daily-skip-admin\] "),     # admin skip aggregate
    re.compile(r"^\[memory-daily-escalated\] "),      # escalation aggregate
    re.compile(r" checked ok\s*$"),                   # no-op placeholder
    re.compile(r"^\[cron-followup\] memory-daily-"),  # cron failure followup
)
SELF_SIGNAL_FROM_PREFIXES = ("memory-daily", "cron-dispatch", "cron-followup")


def _is_system_sender(from_field: str) -> bool:
    """True only if the sender is a known memory-daily / cron internal source.

    The librarian harvester only wants to suppress events authored by its own
    cron / dispatch chain. Any non-empty sender that does *not* match a known
    system prefix is treated as human (or other-agent) work and must never be
    classified as a self-signal — see issue #728 (codex r2).
    """
    if not from_field:
        return False
    return any(from_field.startswith(p) for p in SELF_SIGNAL_FROM_PREFIXES)


def _is_self_signal_event(event: dict) -> bool:
    """Return True if a queue/transcript event should not count as real activity.

    Accepts a dict with optional ``title``, ``from`` (or ``source`` /
    ``created_by``), and ``payload_kind`` keys. Events without those keys
    (e.g. transcript-session summaries from ``_scan_transcripts``) fall
    through and return False, so the helper is a safe no-op for shapes that
    lack metadata.

    The sender is a hard gate: a human-authored task whose title happens to
    match a self-signal pattern (e.g. ``"weekly recap — checked ok"``) must
    not be silently dropped. Only events whose ``from`` / ``source`` /
    ``created_by`` matches a known internal prefix are even considered for
    title-regex or payload-kind suppression.
    """
    title = event.get("title") or ""
    from_field = (
        event.get("from")
        or event.get("source")
        or event.get("created_by")
        or ""
    )

    # Sender gate — short-circuit before any title/payload inspection.
    # A non-system sender (human, other agent, anonymous) is never a
    # self-signal, regardless of title shape.
    if not _is_system_sender(from_field):
        return False

    if any(p.search(title) for p in SELF_SIGNAL_PATTERNS):
        return True

    payload_kind = event.get("payload_kind") or ""
    if payload_kind in {"text", "agentTurn"} and "memory-daily" in title.lower():
        return True

    # Sender is a system agent (memory-daily / cron-dispatch / cron-followup)
    # but title did not match a known pattern. The bare cron-dispatch wake
    # case from issue #728 lands here — still a self-signal.
    return True


def _scan_transcripts(
    workdir: str,
    start: datetime,
    end: datetime,
    transcripts_home: Path | None = None,
) -> list[dict]:
    if not workdir:
        return []
    results: list[dict] = []
    seen: set[str] = set()
    # Under linux-user isolation the target agent's transcripts live under
    # its OS-user home, not the controller's. Callers resolve the right base.
    base_home = transcripts_home if transcripts_home is not None else Path.home()
    projects_root = base_home / ".claude" / "projects"
    if not projects_root.is_dir():
        return results
    start_ts = start.timestamp()
    end_ts = end.timestamp()
    for slug in _workdir_slug_candidates(workdir):
        project_dir = projects_root / slug
        if not project_dir.is_dir():
            continue
        for jsonl in sorted(project_dir.glob("*.jsonl")):
            key = str(jsonl)
            if key in seen:
                continue
            seen.add(key)
            try:
                stat = jsonl.stat()
            except OSError:
                continue
            first_ts: float | None = None
            last_ts: float | None = None
            counts = {"user": 0, "assistant": 0, "tool_use": 0, "tool_result": 0, "thinking": 0}
            try:
                with jsonl.open("r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(event, dict):
                            continue
                        etype = event.get("type") or event.get("role") or ""
                        if etype in counts:
                            counts[etype] += 1
                        else:
                            # tool_use / tool_result sometimes nested under `message.content[*].type`.
                            content = event.get("message", {}).get("content") if isinstance(event.get("message"), dict) else None
                            if isinstance(content, list):
                                for chunk in content:
                                    if isinstance(chunk, dict):
                                        ctype = chunk.get("type")
                                        if ctype in counts:
                                            counts[ctype] += 1
                        ts_raw = event.get("timestamp") or event.get("ts") or event.get("time")
                        ts_val: float | None = None
                        if isinstance(ts_raw, (int, float)):
                            ts_val = float(ts_raw)
                            if ts_val > 1e12:
                                ts_val = ts_val / 1000.0
                        elif isinstance(ts_raw, str):
                            try:
                                ts_val = datetime.fromisoformat(ts_raw.replace("Z", "+00:00")).timestamp()
                            except ValueError:
                                ts_val = None
                        if ts_val is not None:
                            if first_ts is None or ts_val < first_ts:
                                first_ts = ts_val
                            if last_ts is None or ts_val > last_ts:
                                last_ts = ts_val
            except OSError:
                continue
            if first_ts is None:
                first_ts = stat.st_mtime
            if last_ts is None:
                last_ts = stat.st_mtime
            # Window overlap: session overlaps [start, end] if first_ts <= end and last_ts >= start.
            if first_ts <= end_ts and last_ts >= start_ts:
                results.append({
                    "path": str(jsonl),
                    "size_bytes": stat.st_size,
                    "mtime": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
                    "first_ts": datetime.fromtimestamp(first_ts).isoformat(timespec="seconds"),
                    "last_ts": datetime.fromtimestamp(last_ts).isoformat(timespec="seconds"),
                    "event_counts": counts,
                })
    # Filter self-signals (issue #728). Transcript dicts have no title/from
    # fields so this is a no-op for typical session summaries — but the wire-up
    # keeps both scan helpers symmetric and ready for future event-shape changes.
    return [r for r in results if not _is_self_signal_event(r)]


def cmd_scan_transcripts(args: argparse.Namespace) -> int:
    """Emit the bounded transcript scan for one date as a JSON list (issue #1894).

    Read-only companion to ``harvest-daily``. Under linux-user isolation the
    controller UID cannot read the iso agent's ``~/.claude/projects`` tree
    (mode 2700, iso-owned), so the harvest stub runs THIS subcommand as the
    iso UID (via the sudoers ``bash`` allowlist) and marshals the resulting
    list back to the controller-UID ``harvest-daily`` via ``--transcripts-json``.
    The controller keeps owning every queue-DB / manifest / aggregate write
    (Design A, #786) — only the transcript read crosses the boundary.

    Output: ``json.dumps(_scan_transcripts(...))`` to stdout (a list of
    session dicts, identical to what the controller would have produced).
    """
    workdir = args.workdir
    if not workdir:
        sys.stderr.write("scan-transcripts: --workdir is required\n")
        return 2
    tz_name = args.tz or "Asia/Seoul"
    if args.date:
        try:
            date = _parse_harvest_date_arg(args.date, arg_name="--date").date().isoformat()
        except ValueError as exc:
            sys.stderr.write(f"scan-transcripts: {exc}\n")
            return 2
    else:
        date = _harvest_default_date(tz_name)
    start_dt, end_dt = _harvest_date_window(date, tz_name)
    transcripts_home = (
        Path(args.transcripts_home).expanduser() if args.transcripts_home else None
    )
    sessions = _scan_transcripts(
        workdir, start_dt, end_dt, transcripts_home=transcripts_home
    )
    print(json.dumps(sessions, ensure_ascii=True))
    return 0


def _load_scanned_transcripts(path: Path) -> list[dict]:
    """Load a pre-scanned transcript list emitted by ``scan-transcripts`` (#1894).

    Degrades to ``[]`` (never raises) when the file is missing, unreadable, or
    not a JSON list of dicts — the controller-side harvest must continue and
    classify on the other activity signals rather than crash on a bad handoff.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    return [r for r in data if isinstance(r, dict)]


def _scan_queue_events(db_path: Path, agent: str, start: datetime, end: datetime) -> list[int]:
    if not db_path.exists():
        return []
    start_s = int(start.timestamp())
    end_s = int(end.timestamp())
    try:
        conn = sqlite3.connect(str(db_path))
        try:
            # Join into ``tasks`` so we can drop self-signals (issue #728):
            # cron-dispatch wakes, prior-round [memory-daily] backfill placeholders,
            # admin aggregate skip/escalation tasks, and cron-followup chains
            # must not count as "real activity" for the harvester classifier.
            cur = conn.execute(
                """
                SELECT DISTINCT te.task_id, t.title, t.created_by
                FROM task_events te
                JOIN tasks t ON t.id = te.task_id
                WHERE te.event_type IN ('claimed','done')
                  AND te.actor = ?
                  AND te.created_ts BETWEEN ? AND ?
                ORDER BY te.task_id
                """,
                (agent, start_s, end_s),
            )
            rows = cur.fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return []
    filtered: list[int] = []
    for row in rows:
        task_id = int(row[0])
        event = {"title": row[1] or "", "from": row[2] or ""}
        if _is_self_signal_event(event):
            continue
        filtered.append(task_id)
    return filtered


def _task_status(db_path: Path, task_id: int) -> tuple[str | None, int | None]:
    if not db_path.exists() or task_id <= 0:
        return None, None
    try:
        conn = sqlite3.connect(str(db_path))
        try:
            cur = conn.execute(
                "SELECT status, closed_ts FROM tasks WHERE id = ?", (task_id,),
            )
            row = cur.fetchone()
            if not row:
                return None, None
            return row[0], (int(row[1]) if row[1] is not None else None)
        finally:
            conn.close()
    except sqlite3.Error:
        return None, None


def _scan_ingested_captures(home: Path, start: datetime, end: datetime) -> tuple[list[str], list[str]]:
    ingested = home / "raw" / "captures" / "ingested"
    medium: list[str] = []
    weak: list[str] = []
    if not ingested.exists():
        return medium, weak
    start_naive = start.replace(tzinfo=None)
    end_naive = end.replace(tzinfo=None)
    for path in sorted(ingested.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        created_raw = payload.get("created_at") or ""
        try:
            ts = datetime.fromisoformat(str(created_raw))
        except ValueError:
            continue
        ts_naive = ts.replace(tzinfo=None) if ts.tzinfo else ts
        if not (start_naive <= ts_naive <= end_naive):
            continue
        source = str(payload.get("source") or "")
        if source == "pre-compact-hook":
            weak.append(str(path))
        else:
            medium.append(str(path))
    return medium, weak


def _scan_git(workdir: Path, start: datetime, end: datetime) -> list[str]:
    if not workdir.exists() or not (workdir / ".git").exists():
        return []
    try:
        result = subprocess.run(
            [
                "git", "-C", str(workdir), "log",
                f"--since={start.isoformat()}",
                f"--until={end.isoformat()}",
                "--format=%H",
            ],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if result.returncode != 0:
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]
    except (OSError, subprocess.TimeoutExpired):
        return []


def _classify_source_confidence(
    strong: list, medium_tasks: list, medium_captures: list, weak_captures: list, git_commits: list,
) -> str:
    if strong:
        return "strong"
    if medium_tasks or medium_captures:
        return "medium"
    if weak_captures or git_commits:
        return "weak"
    return "none"


def _gate_disabled(agent: str) -> bool:
    # Mirror lib/bridge-agents.sh::bridge_agent_memory_daily_refresh_enabled via
    # an env-var probe. The authoritative gate check runs in the stub when
    # bash lib is sourced; Python is a fallback for direct invocation.
    env_key = f"BRIDGE_AGENT_MEMORY_DAILY_REFRESH_{agent}"
    val = os.environ.get(env_key, "").strip().lower()
    if val in ("0", "false", "no", "off"):
        return True
    return False


def _render_backfill_body(agent: str, date: str, activity: dict, daily_note: dict) -> str:
    lines = [
        f"# memory-daily backfill — {agent} / {date}",
        "",
        "Harvester detected activity for this date but canonical daily note is missing or semantic-empty.",
        "",
        f"- canonical path: `{daily_note.get('path')}`",
        f"- canonical status: `{daily_note.get('status')}`",
        f"- size_bytes: {daily_note.get('size_bytes')}",
        "",
        "## Activity snapshot",
        "",
    ]
    strong = activity.get("strong", {}).get("transcript_sessions", [])
    if strong:
        lines.append(f"- strong: {len(strong)} transcript session(s)")
    medium = activity.get("medium", {})
    if medium.get("queue_task_ids"):
        lines.append(f"- medium: queue tasks {medium['queue_task_ids']}")
    if medium.get("ingested_captures_non_precompact"):
        lines.append(f"- medium: {len(medium['ingested_captures_non_precompact'])} ingested capture(s)")
    weak = activity.get("weak", {})
    if weak.get("precompact_captures"):
        lines.append(f"- weak: {len(weak['precompact_captures'])} precompact capture(s)")
    if weak.get("git_commits"):
        lines.append(f"- weak: {len(weak['git_commits'])} git commit(s)")
    lines.append("")
    lines.append("Please reconstruct the daily note from transcript / captures / commits above.")
    return "\n".join(lines) + "\n"


def _queue_backfill(agent: str, date: str, home: Path, workdir: str, activity: dict, daily_note: dict, dry_run: bool) -> int | None:
    # Defensive guard (issue #728): if every post-filter activity bucket is
    # empty, do not enqueue another backfill — that is exactly the self-signal
    # loop the filter is meant to break. The decision logic upstream already
    # short-circuits on source_confidence == "none", but we re-check here so a
    # future caller that bypasses the classifier still cannot trigger the loop.
    strong = (activity.get("strong") or {}).get("transcript_sessions") or []
    medium = activity.get("medium") or {}
    weak = activity.get("weak") or {}
    total_events = (
        len(strong)
        + len(medium.get("queue_task_ids") or [])
        + len(medium.get("ingested_captures_non_precompact") or [])
        + len(weak.get("precompact_captures") or [])
        + len(weak.get("git_commits") or [])
    )
    if total_events == 0:
        sys.stderr.write(
            f"memory-daily: slot={date} agent={agent} "
            f"reason=no-real-activity-after-self-signal-filter\n"
        )
        return None
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    task_cli = Path(bridge_home).expanduser() / "bridge-task.sh"
    if not task_cli.exists() or dry_run:
        return None
    title = f"[memory-daily] backfill {agent} / {date}"
    body = _render_backfill_body(agent, date, activity, daily_note)
    tmp = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix="memory-daily-backfill-", suffix=".md", delete=False,
    )
    try:
        tmp.write(body)
        tmp.flush()
        tmp.close()
        try:
            result = subprocess.run(
                [
                    "bash", str(task_cli), "create",
                    "--to", agent,
                    "--from", agent,
                    "--title", title,
                    "--body-file", tmp.name,
                    "--priority", "normal",
                ],
                capture_output=True, text=True, timeout=30, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        # Parse task id from stdout. bridge-task.sh create typically emits `task #<id> ...`.
        match = re.search(r"#(\d+)", result.stdout + " " + result.stderr)
        if match:
            return int(match.group(1))
        return None
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


def _find_open_aggregate_task(db_path: Path, title_prefix: str) -> int | None:
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(str(db_path))
        try:
            cur = conn.execute(
                """
                SELECT id FROM tasks
                WHERE title LIKE ?
                  AND status IN ('queued','claimed','blocked')
                ORDER BY id DESC LIMIT 1
                """,
                (title_prefix + "%",),
            )
            row = cur.fetchone()
            return int(row[0]) if row else None
        finally:
            conn.close()
    except sqlite3.Error:
        return None


def _aggregate_upsert_task(title: str, body: str, existing_id: int | None, dry_run: bool) -> int | None:
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    task_cli = Path(bridge_home).expanduser() / "bridge-task.sh"
    if not task_cli.exists() or dry_run:
        return existing_id
    tmp = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix="memory-daily-agg-", suffix=".md", delete=False,
    )
    try:
        tmp.write(body)
        tmp.flush()
        tmp.close()
        if existing_id is not None:
            try:
                subprocess.run(
                    [
                        "bash", str(task_cli), "update", str(existing_id),
                        "--body-file", tmp.name,
                    ],
                    capture_output=True, text=True, timeout=30, check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                pass
            return existing_id
        try:
            result = subprocess.run(
                [
                    "bash", str(task_cli), "create",
                    "--to", "patch",
                    "--from", "memory-daily",
                    "--title", title,
                    "--body-file", tmp.name,
                    "--priority", "normal",
                ],
                capture_output=True, text=True, timeout=30, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        match = re.search(r"#(\d+)", result.stdout + " " + result.stderr)
        return int(match.group(1)) if match else None
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


def _render_aggregate_body(schema_label: str, state: dict) -> str:
    lines = [
        f"# memory-daily aggregate — {schema_label}",
        "",
        f"last_notified_at: `{state.get('last_notified_at') or ''}`",
        f"window_start: `{state.get('window_start') or ''}`",
        "",
        "## By day",
        "",
    ]
    by_day = state.get("by_day") or {}
    for date in sorted(by_day.keys()):
        day = by_day[date]
        agents = day.get("agents") or []
        lines.append(f"- {date}: {', '.join(agents) if agents else '(none)'}")
    lines.append("")
    return "\n".join(lines) + "\n"


def _update_permission_aggregate(args: argparse.Namespace, agent: str, date: str, now_iso: str, db_path: Path, dry_run: bool) -> int | None:
    # Shared aggregate lives under shared/aggregate/ so linux-user isolation
    # can grant write there without opening up the per-agent manifest tree
    # (issue #219). Legacy root-level files are migrated in controller
    # context by bridge_linux_prepare_agent_isolation and bootstrap-memory-system.sh.
    # Under v2 the shared aggregate dir is resolved via --shared-aggregate-dir
    # so admin aggregates can live outside the per-agent private root.
    agg_path = _shared_aggregate_dir(args) / "admin-aggregate-skip.json"
    title_prefix = "[memory-daily-skip-admin]"

    def merger(current: dict) -> dict:
        merged = dict(current) if isinstance(current, dict) else {}
        merged.setdefault("schema", "memory-daily-admin-aggregate-v1")
        merged.setdefault("window_start", now_iso)
        by_day = merged.get("by_day") or {}
        day_entry = by_day.get(date) or {"agents": [], "first_seen_at": now_iso, "last_seen_at": now_iso}
        if agent not in day_entry.get("agents", []):
            day_entry.setdefault("agents", []).append(agent)
        day_entry["last_seen_at"] = now_iso
        by_day[date] = day_entry
        merged["by_day"] = by_day
        merged["last_notified_at"] = now_iso
        return merged

    _merge_aggregate_state(agg_path, merger)
    # Post-merge: decide whether to upsert the aggregate task.
    try:
        state = json.loads(agg_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        state = {}
    existing_id = state.get("open_task_id")
    if not existing_id:
        existing_id = _find_open_aggregate_task(db_path, title_prefix)
    body = _render_aggregate_body("permission-skip", state)
    by_day = state.get("by_day") or {}
    title = f"{title_prefix} {len(by_day)} agent-day(s) skipped (sudo missing)"
    new_id = _aggregate_upsert_task(title, body, existing_id, dry_run)
    if new_id is not None:
        def merger2(current: dict) -> dict:
            merged = dict(current) if isinstance(current, dict) else {}
            merged["open_task_id"] = new_id
            return merged
        _merge_aggregate_state(agg_path, merger2)
    return new_id


def _update_escalation_aggregate(args: argparse.Namespace, agent: str, date: str, now_iso: str, db_path: Path, dry_run: bool) -> int | None:
    # See _update_permission_aggregate for the shared/aggregate rationale.
    agg_path = _shared_aggregate_dir(args) / "admin-aggregate-escalated.json"
    title_prefix = "[memory-daily-escalated]"

    def merger(current: dict) -> dict:
        merged = dict(current) if isinstance(current, dict) else {}
        merged.setdefault("schema", "memory-daily-admin-aggregate-v1")
        merged.setdefault("window_start", now_iso)
        by_day = merged.get("by_day") or {}
        day_entry = by_day.get(date) or {"agents": [], "first_seen_at": now_iso, "last_seen_at": now_iso}
        if agent not in day_entry.get("agents", []):
            day_entry.setdefault("agents", []).append(agent)
        day_entry["last_seen_at"] = now_iso
        by_day[date] = day_entry
        merged["by_day"] = by_day
        merged["last_notified_at"] = now_iso
        return merged

    _merge_aggregate_state(agg_path, merger)
    try:
        state = json.loads(agg_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        state = {}
    existing_id = state.get("open_task_id")
    if not existing_id:
        existing_id = _find_open_aggregate_task(db_path, title_prefix)
    body = _render_aggregate_body("escalated", state)
    by_day = state.get("by_day") or {}
    title = f"{title_prefix} {len(by_day)} agent-day chain(s) >3 attempts"
    new_id = _aggregate_upsert_task(title, body, existing_id, dry_run)
    if new_id is not None:
        def merger2(current: dict) -> dict:
            merged = dict(current) if isinstance(current, dict) else {}
            merged["open_task_id"] = new_id
            return merged
        _merge_aggregate_state(agg_path, merger2)
    return new_id


def _build_result_payload(
    status: str,
    summary: str,
    findings: list[str],
    actions_taken: list[str],
    artifacts: list[str],
    needs_human_followup: bool,
    recommended_next_steps: list[str],
    confidence: str,
) -> dict:
    return {
        "status": status,
        "summary": summary,
        "findings": findings,
        "actions_taken": actions_taken,
        "needs_human_followup": needs_human_followup,
        "recommended_next_steps": recommended_next_steps,
        "artifacts": artifacts,
        "confidence": confidence,
        # PR1.1 — `delivery_intent` is schema-required by the cron-runner
        # (`bridge-cron-runner.py:RESULT_SCHEMA`). The memory-daily harvester
        # writes its authoritative sidecar before the disposable child
        # returns; without this field the runner's `validate_result` would
        # reject the sidecar (Codex r1 P1) and the daemon's session-refresh
        # gate could miss the queue-backfill action. memory-daily reporting
        # is intentionally silent — the daemon already owns the parent
        # session-refresh path.
        "delivery_intent": "silent",
    }


def _parse_harvest_date_arg(value: str, *, arg_name: str = "date") -> "datetime":
    """Parse a YYYY-MM-DD argument used by harvest-daily flags.

    Returns a naive ``datetime`` at midnight (callers compare via .date()).
    Raises ``ValueError`` on malformed input — caller surfaces via stderr.

    The strict round-trip check rejects non-zero-padded forms (e.g.
    ``2026-4-5``) that Python's ``strptime`` would otherwise accept
    silently. Keeps the parse symmetric with the watermark file format and
    downstream lex compares (issue #322 r1 deferred finding).
    """
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        raise ValueError(
            f"{arg_name}: date must be strict YYYY-MM-DD with zero-padded "
            f"month and day, got {value!r}"
        ) from None
    if value != parsed.date().isoformat():
        raise ValueError(
            f"{arg_name}: date must be strict YYYY-MM-DD with zero-padded "
            f"month and day, got {value!r}"
        )
    return parsed


def cmd_harvest_daily(args: argparse.Namespace) -> int:
    """Detection-only daily note harvester (issue #216).

    Single-date dispatcher (`--date` or default). When ``--from`` is supplied,
    iterates over a date range, optionally skipping dates that already have a
    sidecar harvest manifest via ``--missing-only``, and emits an aggregate
    ``{"results": [...]}`` JSON to stdout. The single-date stdout shape is
    unchanged. ``--missing-only`` also applies to the single-date path: when
    the manifest already exists for the target date, exit 0 with a stderr line
    and no harvest run.
    """
    agent = args.agent
    workdir = args.workdir
    tz_name = args.tz or "Asia/Seoul"

    if not workdir:
        sys.stderr.write("harvest-daily: --workdir is required (no fallback)\n")
        return 2

    date_from = getattr(args, "date_from", None)
    date_to = getattr(args, "date_to", None)
    missing_only = bool(getattr(args, "missing_only", False))
    state_dir = _harvest_state_dir(args)

    # --- Range-mode validation + dispatch ----------------------------------
    if date_to and not date_from:
        sys.stderr.write("harvest-daily: --to requires --from\n")
        return 2

    if date_from:
        try:
            from_dt = _parse_harvest_date_arg(date_from, arg_name="--from")
        except ValueError as exc:
            sys.stderr.write(f"harvest-daily: {exc}\n")
            return 2
        today_dt = datetime.strptime(_today_date_str(tz_name), "%Y-%m-%d")
        if date_to:
            try:
                to_dt = _parse_harvest_date_arg(date_to, arg_name="--to")
            except ValueError as exc:
                sys.stderr.write(f"harvest-daily: {exc}\n")
                return 2
        else:
            to_dt = today_dt
        if from_dt > to_dt:
            sys.stderr.write(
                f"harvest-daily: --from {from_dt.date().isoformat()} is later than "
                f"--to {to_dt.date().isoformat()}\n"
            )
            return 2
        if to_dt > today_dt:
            sys.stderr.write(
                f"harvest-daily: --to {to_dt.date().isoformat()} is in the future "
                f"(today={today_dt.date().isoformat()} tz={tz_name})\n"
            )
            return 2
        span = (to_dt - from_dt).days + 1
        target_dates = [
            (from_dt + timedelta(days=i)).date().isoformat() for i in range(span)
        ]
        results: list[dict] = []
        rc_max = 0
        ok_count = 0
        fail_count = 0
        skipped_count = 0
        for tdate in target_dates:
            if missing_only and _manifest_path(args, agent, tdate).exists():
                # Sidecar manifest is the SSOT for "this date has been
                # harvested" — Lane B reads the same path. Manual-note-without-
                # manifest dates must still be harvested.
                results.append({
                    "date": tdate,
                    "skipped": "exists",
                })
                skipped_count += 1
                continue
            try:
                payload = _harvest_one_date(args, tdate)
            except Exception as exc:  # noqa: BLE001 — per-date isolation
                sys.stderr.write(
                    f"[bridge-memory] harvest-daily date={tdate} failed: {exc}\n"
                )
                results.append({
                    "date": tdate,
                    "error": f"{type(exc).__name__}: {exc}",
                })
                rc_max = max(rc_max, 1)
                fail_count += 1
                continue
            results.append({"date": tdate, "result": payload})
            ok_count += 1
        sys.stderr.write(
            f"[bridge-memory] harvest-daily range complete: "
            f"{ok_count + fail_count + skipped_count} dates, "
            f"{ok_count} succeeded, {fail_count} failed, "
            f"{skipped_count} skipped\n"
        )
        aggregate = {
            "schema": "memory-daily-harvest-range-v1",
            "agent": agent,
            "from": from_dt.date().isoformat(),
            "to": to_dt.date().isoformat(),
            "missing_only": missing_only,
            "count": len(results),
            "results": results,
        }
        sidecar_out = getattr(args, "sidecar_out", None)
        if sidecar_out:
            try:
                _atomic_write_json(Path(sidecar_out).expanduser(), aggregate)
            except OSError as exc:
                sys.stderr.write(f"harvest-daily: sidecar write failed: {exc}\n")
                return 2
        try:
            print(json.dumps(aggregate, ensure_ascii=True))
        except OSError:
            pass
        return rc_max

    # --- Single-date path --------------------------------------------------
    # `--missing-only` is propagated here too (Option A — symmetric semantics
    # with the range path). When the manifest already exists, skip the harvest
    # run and exit 0 with a stderr breadcrumb. This lets operators run
    # `harvest-daily --date YYYY-MM-DD --missing-only` opportunistically.
    if args.date:
        try:
            single_date = _parse_harvest_date_arg(
                args.date, arg_name="--date"
            ).date().isoformat()
        except ValueError as exc:
            sys.stderr.write(f"harvest-daily: {exc}\n")
            return 2
    else:
        single_date = _harvest_default_date(tz_name)
    if missing_only and _manifest_path(args, agent, single_date).exists():
        sys.stderr.write(
            f"[bridge-memory] harvest-daily date={single_date} already harvested "
            f"(manifest exists); --missing-only skip\n"
        )
        return 0
    payload = _harvest_one_date(args, single_date)
    return _emit_result(args, payload)


def _today_date_str(tz_name: str) -> str:
    zone = _harvest_tz_zone(tz_name)
    return datetime.now(zone).date().isoformat()


def _harvest_one_date(args: argparse.Namespace, date: str) -> dict:
    """Per-date harvest body. Returns the RESULT_SCHEMA payload (no emit)."""
    agent = args.agent
    home = Path(args.home).expanduser()
    workdir = args.workdir
    tz_name = args.tz or "Asia/Seoul"
    state_dir = _harvest_state_dir(args)
    db_path = _harvest_task_db(args)
    now_iso = _harvest_now_iso(tz_name)
    run_id = os.environ.get("CRON_RUN_ID", "")

    # --- Skipped-permission branch -----------------------------------------
    # Stub detected linux-user isolation but could not assume the target OS
    # user (e.g. passwordless sudo missing). Record state=skipped-permission,
    # merge (agent,date) into admin-aggregate-skip, and exit success so the
    # cron run surfaces a structured skip rather than an engine error.
    if args.skipped_permission:
        prev = _load_manifest(args, agent, date) or {}
        prev_task = prev.get("task") or {}
        manifest = {
            "schema": "memory-daily-manifest-v1",
            "agent": agent,
            "date": date,
            "timezone": tz_name,
            "state": "skipped-permission",
            "first_detected_at": prev.get("first_detected_at") or now_iso,
            "last_checked_at": now_iso,
            "resolved_at": prev.get("resolved_at"),
            "attempts": int(prev.get("attempts") or 0),
            "aggregate_notified_at": now_iso,
            "run_id": run_id,
            "daily_note": {
                "path": str(_daily_note_path(home, date)),
                "status": "missing",
                "size_bytes": 0,
                "has_meta_marker": False,
                "meta_schema_version": 0,
                "session_count": 0,
                "writer_mix": {},
                "has_tag_line": False,
                "semantic_nonempty": False,
            },
            "legacy_paths_checked": [],
            "legacy_note_present": False,
            "activity": {
                "strong": {"transcript_sessions": []},
                "medium": {"queue_task_ids": [], "ingested_captures_non_precompact": []},
                "weak": {"precompact_captures": [], "git_commits": []},
            },
            "decision": {
                "source_confidence": "none",
                "action": "skip",
                "reason_code": "permission",
            },
            "task": {
                "current_task_id": prev_task.get("current_task_id"),
                "current_task_status": prev_task.get("current_task_status"),
                "last_task_id": prev_task.get("last_task_id"),
                "last_task_closed_at": prev_task.get("last_task_closed_at"),
                "requeue_after": None,
            },
        }
        manifest_path = _manifest_path(args, agent, date)
        if not args.dry_run:
            manifest_path = _write_manifest(args, agent, date, manifest)
            _update_permission_aggregate(
                args, agent, date, now_iso, db_path, args.dry_run,
            )
        summary = f"memory-daily sudo wrap unavailable for {agent}/{date}"
        if args.os_user:
            summary += f" (os_user={args.os_user})"
        findings = [
            f"skipped-permission for agent={agent}"
            + (f" os_user={args.os_user}" if args.os_user else "")
        ]
        payload = _build_result_payload(
            status="skipped",
            summary=summary,
            findings=findings,
            actions_taken=["skip-permission"],
            artifacts=[str(manifest_path)],
            needs_human_followup=True,
            recommended_next_steps=[
                "configure passwordless sudo for target os_user",
                "re-run bootstrap-memory-system.sh --apply",
            ],
            confidence="high",
        )
        return payload

    # --- Gate check ---------------------------------------------------------
    if args.disabled_gate or _gate_disabled(agent):
        prev = _load_manifest(args, agent, date) or {}
        manifest = {
            "schema": "memory-daily-manifest-v1",
            "agent": agent,
            "date": date,
            "timezone": tz_name,
            "state": "disabled",
            "first_detected_at": prev.get("first_detected_at") or now_iso,
            "last_checked_at": now_iso,
            "resolved_at": prev.get("resolved_at"),
            "attempts": prev.get("attempts") or 0,
            "aggregate_notified_at": prev.get("aggregate_notified_at"),
            "run_id": run_id,
            "daily_note": {
                "path": str(_daily_note_path(home, date)),
                "status": "missing",
                "size_bytes": 0,
                "has_meta_marker": False,
                "meta_schema_version": 0,
                "session_count": 0,
                "writer_mix": {},
                "has_tag_line": False,
                "semantic_nonempty": False,
            },
            "legacy_paths_checked": [],
            "legacy_note_present": False,
            "activity": {"strong": {"transcript_sessions": []}, "medium": {"queue_task_ids": [], "ingested_captures_non_precompact": []}, "weak": {"precompact_captures": [], "git_commits": []}},
            "decision": {"source_confidence": "none", "action": "skip", "reason_code": "disabled"},
            "task": {"current_task_id": None, "current_task_status": None, "last_task_id": prev.get("task", {}).get("last_task_id"), "last_task_closed_at": prev.get("task", {}).get("last_task_closed_at"), "requeue_after": None},
        }
        manifest_path = _manifest_path(args, agent, date)
        if not args.dry_run:
            manifest_path = _write_manifest(args, agent, date, manifest)
        payload = _build_result_payload(
            status="disabled",
            summary=f"memory-daily gate off for {agent}/{date}",
            findings=[f"gate disabled for agent={agent}"],
            actions_taken=[],
            artifacts=[str(manifest_path)],
            needs_human_followup=False,
            recommended_next_steps=[],
            confidence="high",
        )
        return payload

    # --- Probe canonical + legacy ------------------------------------------
    daily_note = _probe_daily_note(home, date)
    legacy_present, legacy_checked = _probe_legacy(home, date)

    # --- Activity scan ------------------------------------------------------
    start_dt, end_dt = _harvest_date_window(date, tz_name)
    # Issue #1894: under linux-user isolation the controller UID cannot read
    # the iso agent's ~/.claude/projects tree, so the harvest stub runs the
    # transcript scan AS the iso UID (`scan-transcripts`) and hands the result
    # back here via --transcripts-json. When that file is present we consume
    # it verbatim instead of re-scanning from the controller context (which
    # would hit Permission denied and return []). Everything else in this
    # function still runs as the controller UID (Design A, #786).
    transcripts_json = getattr(args, "transcripts_json", None)
    if transcripts_json:
        transcripts = _load_scanned_transcripts(Path(transcripts_json).expanduser())
    else:
        transcripts_home = (
            Path(args.transcripts_home).expanduser() if args.transcripts_home else None
        )
        transcripts = _scan_transcripts(workdir, start_dt, end_dt, transcripts_home=transcripts_home)
    queue_tasks = _scan_queue_events(db_path, agent, start_dt, end_dt)
    medium_caps, weak_caps = _scan_ingested_captures(home, start_dt, end_dt)
    git_commits = _scan_git(Path(workdir).expanduser(), start_dt, end_dt)

    source_confidence = _classify_source_confidence(
        transcripts, queue_tasks, medium_caps, weak_caps, git_commits,
    )

    # --- Load previous manifest for carry-over / dedupe ---------------------
    prev = _load_manifest(args, agent, date) or {}
    prev_task = prev.get("task") or {}
    prev_state = prev.get("state")
    attempts = int(prev.get("attempts") or 0)
    first_detected_at = prev.get("first_detected_at") or now_iso

    # --- Resolution / dedupe -----------------------------------------------
    new_state: str | None = None
    action: str = "no-op"
    reason_code: str | None = None
    actions_taken: list[str] = []
    current_task_id = prev_task.get("current_task_id")
    current_task_status: str | None = None
    resolved_at = prev.get("resolved_at")
    should_requeue = False
    cooldown_block = False

    if prev_state == "queued" and daily_note["semantic_nonempty"]:
        new_state = "resolved"
        action = "ok"
        resolved_at = now_iso
    elif prev_state == "queued" and current_task_id:
        status, closed_ts = _task_status(db_path, int(current_task_id))
        current_task_status = status
        if status in ("queued", "claimed", "blocked"):
            cooldown_block = True
        elif status in ("done", "cancelled"):
            if closed_ts is not None:
                age_s = int(datetime.now(_harvest_tz_zone(tz_name)).timestamp()) - closed_ts
                if age_s < 24 * 3600:
                    cooldown_block = True
                else:
                    if not daily_note["semantic_nonempty"]:
                        should_requeue = True

    # --- Decision -----------------------------------------------------------
    if new_state is None:
        if daily_note["semantic_nonempty"]:
            new_state = "checked"
            action = "ok"
        elif legacy_present:
            new_state = "checked"
            action = "no-op"
            reason_code = "legacy_note_present"
        elif source_confidence in ("strong", "medium"):
            if cooldown_block:
                new_state = "queued"
                action = "no-op"
                reason_code = "dedupe_cooldown"
            else:
                new_state = "queued"
                action = "queue-backfill"
                actions_taken = ["queue-backfill"]
        elif source_confidence == "weak":
            new_state = "checked"
            action = "no-op"
            reason_code = "weak_only_activity"
        else:
            new_state = "checked"
            action = "no-op"
            reason_code = "no_activity"

    # Attempts tracking + escalation
    if action == "queue-backfill":
        if prev_state != "queued":
            attempts = 1
        elif should_requeue:
            attempts += 1
        else:
            attempts = max(1, attempts)
        if attempts > 3:
            new_state = "escalated"

    # --- Actions ------------------------------------------------------------
    new_task_id: int | None = None
    if action == "queue-backfill" and (prev_state != "queued" or should_requeue):
        activity_dict = {
            "strong": {"transcript_sessions": transcripts},
            "medium": {"queue_task_ids": queue_tasks, "ingested_captures_non_precompact": medium_caps},
            "weak": {"precompact_captures": weak_caps, "git_commits": git_commits},
        }
        new_task_id = _queue_backfill(agent, date, home, workdir, activity_dict, daily_note, args.dry_run)

    last_task_id = prev_task.get("last_task_id")
    last_task_closed_at = prev_task.get("last_task_closed_at")
    if should_requeue and current_task_id:
        last_task_id = current_task_id
        last_task_closed_at = prev_task.get("last_task_closed_at")
    if new_task_id:
        current_task_id = new_task_id
        current_task_status = "queued"

    # --- Escalation aggregate ----------------------------------------------
    aggregate_notified_at = prev.get("aggregate_notified_at")
    if new_state == "escalated":
        _update_escalation_aggregate(args, agent, date, now_iso, db_path, args.dry_run)
        aggregate_notified_at = now_iso

    # --- Build manifest -----------------------------------------------------
    manifest = {
        "schema": "memory-daily-manifest-v1",
        "agent": agent,
        "date": date,
        "timezone": tz_name,
        "state": new_state,
        "first_detected_at": first_detected_at,
        "last_checked_at": now_iso,
        "resolved_at": resolved_at,
        "attempts": attempts,
        "aggregate_notified_at": aggregate_notified_at,
        "run_id": run_id,
        "daily_note": daily_note,
        "legacy_paths_checked": legacy_checked,
        "legacy_note_present": legacy_present,
        "activity": {
            "strong": {"transcript_sessions": transcripts},
            "medium": {
                "queue_task_ids": queue_tasks,
                "ingested_captures_non_precompact": medium_caps,
            },
            "weak": {
                "precompact_captures": weak_caps,
                "git_commits": git_commits,
            },
        },
        "decision": {
            "source_confidence": source_confidence,
            "action": action,
            "reason_code": reason_code,
        },
        "task": {
            "current_task_id": current_task_id,
            "current_task_status": current_task_status,
            "last_task_id": last_task_id,
            "last_task_closed_at": last_task_closed_at,
            "requeue_after": None,
        },
    }

    manifest_path = _manifest_path(args, agent, date)
    if not args.dry_run:
        manifest_path = _write_manifest(args, agent, date, manifest)

    # --- Build result payload ----------------------------------------------
    status_map = {
        ("checked", "ok"): "ok",
        ("checked", "no-op"): "noop",
        ("queued", "queue-backfill"): "queued",
        ("queued", "no-op"): "queued",
        ("resolved", "ok"): "ok",
        ("escalated", "queue-backfill"): "queued",
        ("escalated", "no-op"): "queued",
    }
    status = status_map.get((new_state, action), "noop")
    summary_bits = [f"{agent}/{date}", new_state, action]
    if reason_code:
        summary_bits.append(f"reason={reason_code}")
    summary = " ".join(summary_bits)
    findings = [
        f"canonical={daily_note['status']} size={daily_note['size_bytes']}",
        f"source_confidence={source_confidence}",
        f"transcripts={len(transcripts)} queue_tasks={len(queue_tasks)} medium_caps={len(medium_caps)} weak_caps={len(weak_caps)} git_commits={len(git_commits)}",
    ]
    if legacy_present:
        findings.append("legacy_note_present=true")
    if cooldown_block:
        findings.append("dedupe_cooldown=true")
    artifacts = [str(manifest_path)]
    confidence = "high" if source_confidence in ("strong", "none") else "medium"

    payload = _build_result_payload(
        status=status,
        summary=summary,
        findings=findings,
        actions_taken=actions_taken,
        artifacts=artifacts,
        needs_human_followup=(new_state == "escalated"),
        recommended_next_steps=(
            ["investigate escalation chain"] if new_state == "escalated" else []
        ),
        confidence=confidence,
    )
    return payload


def _emit_result(args: argparse.Namespace, payload: dict) -> int:
    sidecar_out = getattr(args, "sidecar_out", None)
    if sidecar_out:
        try:
            _atomic_write_json(Path(sidecar_out).expanduser(), payload)
        except OSError as exc:
            sys.stderr.write(f"harvest-daily: sidecar write failed: {exc}\n")
            return 2
    try:
        if args.json:
            print(json.dumps(payload, ensure_ascii=True))
        else:
            print(f"{payload['status']} {payload['summary']} actions={payload['actions_taken']}")
    except OSError:
        pass
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--agent", required=True)
    init_parser.add_argument("--home", required=True)
    init_parser.add_argument("--template-root", required=True)
    init_parser.add_argument("--user", action="append")
    init_parser.add_argument("--dry-run", action="store_true")
    init_parser.add_argument("--json", action="store_true")
    init_parser.set_defaults(func=cmd_init)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--agent", required=True)
    capture_parser.add_argument("--home", required=True)
    capture_parser.add_argument("--template-root", required=True)
    capture_parser.add_argument("--user", default="default")
    capture_parser.add_argument("--source", required=True)
    capture_parser.add_argument("--author")
    capture_parser.add_argument("--channel")
    capture_parser.add_argument("--title")
    group = capture_parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--text-file")
    capture_parser.add_argument("--dry-run", action="store_true")
    capture_parser.add_argument("--json", action="store_true")
    capture_parser.set_defaults(func=cmd_capture)

    ingest_parser = subparsers.add_parser("ingest")
    ingest_parser.add_argument("--agent", required=True)
    ingest_parser.add_argument("--home", required=True)
    ingest_parser.add_argument("--template-root", required=True)
    selector = ingest_parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--capture")
    selector.add_argument("--latest", action="store_true")
    selector.add_argument("--all", action="store_true")
    ingest_parser.add_argument("--dry-run", action="store_true")
    ingest_parser.add_argument("--json", action="store_true")
    ingest_parser.set_defaults(func=cmd_ingest)

    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--agent", required=True)
    promote_parser.add_argument("--home", required=True)
    promote_parser.add_argument("--template-root", required=True)
    promote_parser.add_argument(
        "--kind",
        choices=("user", "user-profile", "agent-pref", "shared", "project", "decision"),
        required=True,
        help=(
            "user = per-user memory bucket; "
            "user-profile = Stable Preferences section of shared/users/<uid>/USER.md "
            "(auto-loaded at every session start, cross-agent via canonical USER.md); "
            "agent-pref = agent-role rules in this agent's ACTIVE-PREFERENCES.md "
            "(file-exists-only load, zero overhead when unused); "
            "shared|project|decision = agent-local wiki pages"
        ),
    )
    promote_parser.add_argument("--user")
    promote_parser.add_argument("--capture")
    promote_parser.add_argument("--page")
    promote_parser.add_argument("--title")
    promote_parser.add_argument("--summary")
    promote_parser.add_argument("--dry-run", action="store_true")
    promote_parser.add_argument("--json", action="store_true")
    promote_parser.set_defaults(func=cmd_promote)

    remember_parser = subparsers.add_parser("remember")
    remember_parser.add_argument("--agent", required=True)
    remember_parser.add_argument("--home", required=True)
    remember_parser.add_argument("--template-root", required=True)
    remember_parser.add_argument("--user", default="default")
    remember_parser.add_argument("--source", required=True)
    remember_parser.add_argument("--author")
    remember_parser.add_argument("--channel")
    remember_parser.add_argument("--title")
    remember_parser.add_argument("--text", required=True)
    remember_parser.add_argument("--kind", choices=("none", "user", "shared", "project", "decision"), default="user")
    remember_parser.add_argument("--page", default="")
    remember_parser.add_argument("--summary", default="")
    remember_parser.add_argument("--dry-run", action="store_true")
    remember_parser.add_argument("--json", action="store_true")
    remember_parser.set_defaults(func=cmd_remember)

    lint_parser = subparsers.add_parser("lint")
    lint_parser.add_argument("--agent", required=True)
    lint_parser.add_argument("--home", required=True)
    lint_parser.add_argument("--json", action="store_true")
    lint_parser.set_defaults(func=cmd_lint)

    rebuild_parser = subparsers.add_parser("rebuild-index")
    rebuild_parser.add_argument("--agent", required=True)
    rebuild_parser.add_argument("--home", required=True)
    rebuild_parser.add_argument("--bridge-home", required=True)
    rebuild_parser.add_argument("--db-path")
    rebuild_parser.add_argument(
        "--index-kind",
        choices=list(KNOWN_INDEX_KINDS),
        default=INDEX_KIND,
        help="index kind to build (default: bridge-wiki-fts-v1)",
    )
    rebuild_parser.add_argument(
        "--shared-root",
        help="path to shared/ root; required for full v2 wiki cascade ingestion",
    )
    rebuild_parser.add_argument("--dry-run", action="store_true")
    rebuild_parser.add_argument("--json", action="store_true")
    rebuild_parser.set_defaults(func=cmd_rebuild_index)

    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("--agent", required=True)
    search_parser.add_argument("--home", required=True)
    search_parser.add_argument("--query", required=True)
    search_parser.add_argument("--user")
    search_parser.add_argument("--scope", choices=SEARCH_SCOPES, default="wiki")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--json", action="store_true")
    search_parser.set_defaults(func=cmd_search)

    query_parser = subparsers.add_parser("query")
    query_parser.add_argument("--agent", required=True)
    query_parser.add_argument("--home", required=True)
    query_parser.add_argument("--bridge-home", required=True)
    query_parser.add_argument("--db-path")
    query_parser.add_argument("--query", required=True)
    query_parser.add_argument("--user")
    query_parser.add_argument("--scope", choices=QUERY_SCOPES, default="all")
    query_parser.add_argument("--limit", type=int, default=10)
    query_parser.add_argument("--json", action="store_true")
    query_parser.set_defaults(func=cmd_query)

    # -----------------------------------------------------------------
    # summarize — two-level subcommand: `summarize weekly` / `summarize monthly`.
    # -----------------------------------------------------------------
    summarize_parser = subparsers.add_parser("summarize")
    summarize_sub = summarize_parser.add_subparsers(dest="level", required=True)

    weekly_parser = summarize_sub.add_parser("weekly")
    weekly_parser.add_argument("--agent", required=True)
    weekly_parser.add_argument("--home", required=True)
    weekly_parser.add_argument("--user", default="default")
    weekly_parser.add_argument("--week", help="YYYY-W## (defaults to previous ISO week)")
    weekly_parser.add_argument("--llm", action="store_true", help="use claude CLI to generate summary")
    weekly_parser.add_argument("--llm-model", default="")
    weekly_parser.add_argument("--dry-run", action="store_true")
    weekly_parser.add_argument("--json", action="store_true")
    weekly_parser.set_defaults(func=cmd_summarize_weekly)

    monthly_parser = summarize_sub.add_parser("monthly")
    monthly_parser.add_argument("--agent", required=True)
    monthly_parser.add_argument("--home", required=True)
    monthly_parser.add_argument("--user", default="default")
    monthly_parser.add_argument("--month", help="YYYY-MM (defaults to previous month)")
    monthly_parser.add_argument("--llm", action="store_true")
    monthly_parser.add_argument("--llm-model", default="")
    monthly_parser.add_argument("--dry-run", action="store_true")
    monthly_parser.add_argument("--json", action="store_true")
    monthly_parser.set_defaults(func=cmd_summarize_monthly)

    reconcile_parser = subparsers.add_parser("reconcile")
    reconcile_parser.add_argument("--agent", required=True)
    reconcile_parser.add_argument("--home", required=True)
    reconcile_parser.add_argument("--shared-root", help="path to ~/.agent-bridge/shared (or test fixture)")
    reconcile_parser.add_argument("--create-task", action="store_true", help="file a patch task on conflict")
    reconcile_parser.add_argument("--dry-run", action="store_true")
    reconcile_parser.add_argument("--json", action="store_true")
    reconcile_parser.set_defaults(func=cmd_reconcile)

    migrate_parser = subparsers.add_parser(
        "migrate-canonical",
        help=(
            "fold legacy <home>/users/<user>/memory/*.md into <home>/memory/ "
            "(issue #220); default is dry-run, pass --apply to move"
        ),
    )
    migrate_parser.add_argument("--home", required=True, help="agent home root, e.g. ~/.agent-bridge/agents/<agent>")
    migrate_parser.add_argument("--user", default="default", help="legacy user partition (default: default)")
    migrate_parser.add_argument("--apply", action="store_true", help="actually move files (default is dry-run)")
    migrate_parser.add_argument(
        "--i-know-this-is-live",
        dest="i_know_this_is_live",
        action="store_true",
        help="permit --apply against the live BRIDGE_HOME (refused by default to prevent accidental admin-task fires)",
    )
    migrate_parser.add_argument("--json", action="store_true")
    migrate_parser.set_defaults(func=cmd_migrate_canonical)

    csi_parser = subparsers.add_parser(
        "current-session-id",
        help="print the most recently active session id for the given agent",
    )
    csi_parser.add_argument("--agent", required=True)
    csi_parser.add_argument(
        "--home",
        required=True,
        help="real agent home path; the Claude project slug is derived from this",
    )
    csi_parser.add_argument(
        "--claude-projects",
        default=str(Path.home() / ".claude" / "projects"),
    )
    csi_parser.add_argument(
        "--transcripts-home",
        help=(
            "override base for ~/.claude/projects scan — accepts either an "
            "explicit `<base>/.claude/projects` path or the isolated UID's "
            "home directory. Mirrors the harvest-daily pattern; required "
            "for current-session-id under linux-user isolation since `~` "
            "resolves to the isolated UID's home but --home is the "
            "controller-side path (issue #412 Track C)."
        ),
    )
    csi_parser.set_defaults(func=cmd_current_session_id)

    da_parser = subparsers.add_parser(
        "daily-append",
        help="append or replace a session section in today's daily note",
    )
    da_parser.add_argument("--agent", required=True)
    da_parser.add_argument("--home", required=True, help="agent home root, e.g. ~/.agent-bridge/agents/<agent>")
    da_parser.add_argument("--session-id", required=True)
    da_parser.add_argument("--writer", choices=("session", "cron"), default="session")
    da_parser.add_argument("--date", help="YYYY-MM-DD override; defaults to today (Asia/Seoul)")
    src = da_parser.add_mutually_exclusive_group()
    src.add_argument("--content-from-stdin", action="store_true")
    src.add_argument("--content-file")
    da_parser.add_argument("--json", action="store_true")
    da_parser.set_defaults(func=cmd_daily_append)

    hd_parser = subparsers.add_parser(
        "harvest-daily",
        help="Detection-only daily note harvester (issue #216)",
    )
    hd_parser.add_argument("--agent", required=True)
    hd_parser.add_argument("--home", required=True, help="agent profile home root")
    hd_parser.add_argument("--workdir", required=True, help="agent workdir (no fallback)")
    hd_date_group = hd_parser.add_mutually_exclusive_group()
    hd_date_group.add_argument(
        "--date", help="YYYY-MM-DD; defaults to yesterday in --tz",
    )
    hd_date_group.add_argument(
        "--from", dest="date_from", default=None,
        help="Start date YYYY-MM-DD (inclusive); pair with --to. Mutually exclusive with --date.",
    )
    hd_parser.add_argument(
        "--to", dest="date_to", default=None,
        help="End date YYYY-MM-DD (inclusive); requires --from. Defaults to today in --tz.",
    )
    hd_parser.add_argument(
        "--missing-only", dest="missing_only", action="store_true", default=False,
        help=(
            "Skip dates whose sidecar harvest manifest already exists. "
            "Applies to both range mode (--from/--to) and single-date mode "
            "(--date or default)."
        ),
    )
    hd_parser.add_argument("--tz", default="Asia/Seoul")
    hd_parser.add_argument("--state-dir", help="override $BRIDGE_STATE_DIR/memory-daily")
    hd_parser.add_argument(
        "--per-agent-state-dir",
        help=(
            "override the per-agent manifest directory (PR-C v2: "
            "$BRIDGE_AGENT_ROOT_V2/<agent>/runtime/memory-daily). When set, "
            "the agent name is NOT appended — the directory is used verbatim."
        ),
    )
    hd_parser.add_argument(
        "--shared-aggregate-dir",
        help=(
            "override the shared admin-aggregate directory (PR-C v2: "
            "$BRIDGE_SHARED_ROOT/memory-daily/aggregate). When set, the "
            "directory is used verbatim and admin-aggregate-*.json are "
            "written directly under it."
        ),
    )
    hd_parser.add_argument("--sidecar-out", help="authoritative RESULT_SCHEMA JSON path")
    hd_parser.add_argument("--dry-run", action="store_true")
    hd_parser.add_argument("--json", action="store_true")
    hd_parser.add_argument(
        "--disabled-gate", action="store_true",
        help="force disabled branch (stub detected gate off)",
    )
    hd_parser.add_argument(
        "--skipped-permission", action="store_true",
        help="stub could not assume target OS user; record skipped-permission + update aggregate",
    )
    hd_parser.add_argument(
        "--os-user",
        help="target OS user for linux-user isolation (audit / aggregate note)",
    )
    hd_parser.add_argument(
        "--transcripts-home",
        help="override base for ~/.claude/projects scan (resolved by stub for linux-user isolation)",
    )
    hd_parser.add_argument(
        "--transcripts-json",
        help=(
            "path to a pre-scanned transcript list (JSON array) produced by "
            "`scan-transcripts`. Issue #1894: under linux-user isolation the "
            "stub runs the scan AS the iso UID and passes the result here so "
            "the controller-UID harvest does not re-read the iso-owned "
            "~/.claude/projects tree. When set, --transcripts-home is ignored."
        ),
    )
    hd_parser.set_defaults(func=cmd_harvest_daily)

    # scan-transcripts (issue #1894): read-only iso-UID transcript scan. Emits
    # the same list _scan_transcripts produces so the controller can ingest it
    # via harvest-daily --transcripts-json without re-reading the iso tree.
    st_parser = subparsers.add_parser(
        "scan-transcripts",
        help="Emit the bounded transcript scan for one date as JSON (issue #1894)",
    )
    st_parser.add_argument("--workdir", required=True, help="agent workdir (no fallback)")
    st_parser.add_argument(
        "--date", help="YYYY-MM-DD; defaults to yesterday in --tz",
    )
    st_parser.add_argument("--tz", default="Asia/Seoul")
    st_parser.add_argument(
        "--transcripts-home",
        help="override base for ~/.claude/projects scan (the iso UID's home)",
    )
    st_parser.set_defaults(func=cmd_scan_transcripts)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "text_file", None):
        args.text = Path(args.text_file).read_text(encoding="utf-8")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
