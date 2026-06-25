#!/usr/bin/env python3
"""bridge-knowledge.py — bridge-level team knowledge wiki helpers."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

# Shared disposable-`claude -p` launch hardening (#17957). The LLM-review /
# related-page spawns below run in the agent's real config-dir, so without this
# they would auto-load the singleton telegram/discord plugins and steal the
# admin's live poller. The overlay suppresses ONLY those singleton channels and
# preserves all other plugins/MCP.
_BRIDGE_KNOWLEDGE_LIB_DIR = Path(__file__).resolve().parent / "lib"
if _BRIDGE_KNOWLEDGE_LIB_DIR.is_dir() and str(_BRIDGE_KNOWLEDGE_LIB_DIR) not in sys.path:  # noqa: raw-pathlib-controller-only — import-time controller-side lib dir probe
    sys.path.insert(0, str(_BRIDGE_KNOWLEDGE_LIB_DIR))

from bridge_disposable_claude import singleton_channel_suppression_argv  # noqa: E402


WIKI_FILES = (
    "index.md",
    "people.md",
    "agents.md",
    "operating-rules.md",
    "data-sources.md",
    "tools.md",
)
WIKI_DIRS = (
    "decisions",
    "projects",
    "playbooks",
)
RAW_DIRS = (
    "raw/captures/inbox",
    "raw/captures/promoted",
    "raw/channel-events",
    "raw/cron-results",
    "indexes",
)
SEARCH_SCOPES = ("wiki", "raw", "all")
PRIMARY_OPERATOR_HEADING = "## Primary Operator"
PRIMARY_OPERATOR_START = "<!-- BEGIN PRIMARY OPERATOR -->"
PRIMARY_OPERATOR_END = "<!-- END PRIMARY OPERATOR -->"
KIND_ALIASES = {
    "people": "people",
    "person": "people",
    "agents": "agents",
    "agent": "agents",
    "rules": "operating-rules",
    "operating-rules": "operating-rules",
    "data-source": "data-sources",
    "data-sources": "data-sources",
    "tools": "tools",
    "tool": "tools",
    "decision": "decision",
    "project": "project",
    "playbook": "playbook",
}


def die(message: str) -> None:
    raise SystemExit(message)


def now() -> datetime:
    return datetime.now().astimezone()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str, dry_run: bool = False) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def append_text(path: Path, text: str, dry_run: bool = False) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-").lower()
    return slug or "note"


def template_path(template_root: Path, relpath: str) -> Path:
    return template_root / "shared" / "wiki" / relpath


def read_template(template_root: Path, relpath: str, team_name: str) -> str:
    path = template_path(template_root, relpath)
    if path.exists():
        return read_text(path).replace("{{TEAM_NAME}}", team_name)
    title = relpath[:-3].replace("-", " ").replace("_", " ").title()
    return f"# {title}\n\n## Notes\n"


def wiki_root(shared_root: Path) -> Path:
    return shared_root / "wiki"


def raw_root(shared_root: Path) -> Path:
    return shared_root / "raw"


def ensure_layout(shared_root: Path, template_root: Path, team_name: str, dry_run: bool) -> list[str]:
    created: list[str] = []
    root = wiki_root(shared_root)
    for relpath in WIKI_FILES:
        target = root / relpath
        if not target.exists():
            write_text(target, read_template(template_root, relpath, team_name), dry_run)
            created.append(str(target.relative_to(shared_root)))
    for dirname in WIKI_DIRS:
        keep = root / dirname / ".gitkeep"
        if not keep.exists():
            write_text(keep, "", dry_run)
            created.append(str(keep.relative_to(shared_root)))
    for dirname in RAW_DIRS:
        keep = shared_root / dirname / ".gitkeep"
        if not keep.exists():
            write_text(keep, "", dry_run)
            created.append(str(keep.relative_to(shared_root)))
    return created


def cmd_init(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    template_root = Path(args.template_root)
    created = ensure_layout(shared_root, template_root, args.team_name, args.dry_run)
    payload = {
        "shared_root": str(shared_root),
        "wiki_root": str(wiki_root(shared_root)),
        "team_name": args.team_name,
        "created": created,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"wiki_root: {payload['wiki_root']}")
        print(f"team_name: {args.team_name}")
        print(f"created: {len(created)}")
    return 0


def capture_payload(args: argparse.Namespace) -> dict[str, str]:
    stamp = now()
    base = slugify(args.title or args.source or "capture")
    capture_id = f"{stamp.strftime('%Y%m%dT%H%M%S%z')}-{base}"
    return {
        "capture_id": capture_id,
        "source": args.source,
        "author": args.author or "",
        "channel": args.channel or "",
        "title": args.title or "",
        "text": args.text,
        "created_at": stamp.isoformat(),
    }


def write_capture(shared_root: Path, payload: dict[str, str], dry_run: bool) -> Path:
    path = raw_root(shared_root) / "captures" / "inbox" / f"{payload['capture_id']}.json"
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n", dry_run)
    return path


def cmd_capture(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    payload = capture_payload(args)
    path = write_capture(shared_root, payload, args.dry_run)
    result = {
        "capture_id": payload["capture_id"],
        "path": str(path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"capture_id: {payload['capture_id']}")
        print(f"path: {path}")
    return 0


def resolve_capture(shared_root: Path, capture_id: str) -> tuple[Path, dict[str, str]]:
    for folder in ("inbox", "promoted"):
        path = raw_root(shared_root) / "captures" / folder / f"{capture_id}.json"
        if path.exists():
            return path, json.loads(read_text(path))
    die(f"capture not found: {capture_id}")


def normalize_kind(kind: str) -> str:
    normalized = KIND_ALIASES.get(kind)
    if not normalized:
        die(f"unsupported knowledge kind: {kind}")
    return normalized


def page_title(slug: str) -> str:
    return slug.replace("-", " ").replace("_", " ").strip().title() or "Knowledge Page"


def target_for_kind(shared_root: Path, kind: str, page: str, title: str) -> Path:
    root = wiki_root(shared_root)
    if kind in {"people", "agents", "operating-rules", "data-sources", "tools"}:
        return root / f"{kind}.md"
    slug = slugify(page or title or kind)
    if kind == "decision":
        return root / "decisions" / f"{slug}.md"
    if kind == "project":
        return root / "projects" / f"{slug}.md"
    if kind == "playbook":
        return root / "playbooks" / f"{slug}.md"
    die(f"unsupported knowledge kind: {kind}")


def ensure_page(path: Path, title: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {title}\n\n## Notes\n", dry_run)


def append_note(path: Path, block: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path).rstrip()
    else:
        text = ""
    if "## Notes" not in text:
        text = text.rstrip() + "\n\n## Notes"
    text = text.rstrip() + "\n\n" + block.rstrip() + "\n"
    write_text(path, text, dry_run)


def build_note(args: argparse.Namespace, capture: dict[str, str] | None, summary: str) -> str:
    title = args.title or args.page or (capture or {}).get("title") or args.kind
    lines = [f"### {now().isoformat(timespec='seconds')} — {title}", "", summary.strip()]
    details = (capture or {}).get("text", "").strip()
    if details and details != summary.strip():
        lines.extend(["", "#### Source Detail", "", details])
    if capture:
        lines.extend(["", "#### Source"])
        lines.append(f"- Capture: {capture['capture_id']}")
        if capture.get("source"):
            lines.append(f"- Source: {capture['source']}")
        if capture.get("author"):
            lines.append(f"- Author: {capture['author']}")
        if capture.get("channel"):
            lines.append(f"- Channel: {capture['channel']}")
    return "\n".join(lines)


def append_log(shared_root: Path, line: str, dry_run: bool) -> None:
    log_path = wiki_root(shared_root) / "log.md"
    if not log_path.exists():
        write_text(log_path, "# Knowledge Log\n\n", dry_run)
    append_text(log_path, line.rstrip() + "\n", dry_run)


def iter_wiki_markdown_files(shared_root: Path) -> list[Path]:
    root = wiki_root(shared_root)
    if not root.exists():
        return []
    return sorted(path for path in root.rglob("*.md") if path.is_file())


def markdown_title(path: Path) -> str:
    for raw in read_text(path).splitlines():
        line = raw.strip()
        if line.startswith("# "):
            return line[2:].strip()
    return page_title(path.stem)


def normalize_title(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip().lower())


def markdown_links(text: str) -> list[str]:
    targets: list[str] = []
    for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", text):
        target = match.group(1).strip()
        if not target:
            continue
        targets.append(target)
    return targets


def is_external_link(target: str) -> bool:
    lower = target.lower()
    return (
        lower.startswith("http://")
        or lower.startswith("https://")
        or lower.startswith("mailto:")
        or lower.startswith("tel:")
        or lower.startswith("#")
    )


def resolve_markdown_link(base: Path, target: str) -> Path | None:
    if is_external_link(target):
        return None
    raw_target = target.split("#", 1)[0].strip()
    if not raw_target:
        return None
    candidate = (base.parent / raw_target).resolve()
    return candidate


def first_paragraph(path: Path) -> str:
    lines = read_text(path).splitlines()
    paragraphs: list[str] = []
    current: list[str] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            if current:
                paragraphs.append(" ".join(current).strip())
                current = []
            continue
        if line.startswith("#"):
            continue
        current.append(line)
    if current:
        paragraphs.append(" ".join(current).strip())
    return paragraphs[0] if paragraphs else ""


def lint_wiki(shared_root: Path, stale_days: int) -> dict[str, object]:
    root = wiki_root(shared_root)
    wiki_files = iter_wiki_markdown_files(shared_root)
    file_set = {path.resolve() for path in wiki_files}
    broken_links: list[dict[str, str]] = []
    orphan_pages: list[str] = []
    stale_pages: list[dict[str, object]] = []
    duplicate_titles: list[dict[str, object]] = []
    inbound_links: dict[Path, set[Path]] = {}
    now_ts = now()

    title_map: dict[str, list[Path]] = {}
    for path in wiki_files:
        title_map.setdefault(normalize_title(markdown_title(path)), []).append(path)

    for normalized_title, paths in sorted(title_map.items()):
        if len(paths) <= 1:
            continue
        duplicate_titles.append(
            {
                "title": markdown_title(paths[0]),
                "files": [str(path.relative_to(shared_root)) for path in paths],
            }
        )

    for path in wiki_files:
        try:
            text = read_text(path)
        except UnicodeDecodeError:
            continue
        for target in markdown_links(text):
            resolved = resolve_markdown_link(path, target)
            if resolved is None:
                continue
            if not resolved.exists():
                broken_links.append(
                    {
                        "source": str(path.relative_to(shared_root)),
                        "target": target,
                    }
                )
                continue
            if resolved.suffix == ".md" and resolved in file_set:
                inbound_links.setdefault(resolved, set()).add(path.resolve())

        age = now_ts - datetime.fromtimestamp(path.stat().st_mtime).astimezone()
        if age > timedelta(days=stale_days):
            stale_pages.append(
                {
                    "path": str(path.relative_to(shared_root)),
                    "days_old": int(age.total_seconds() // 86400),
                }
            )

    for path in wiki_files:
        if path.parent == root:
            continue
        if path.name == "log.md":
            continue
        if not inbound_links.get(path.resolve()):
            orphan_pages.append(str(path.relative_to(shared_root)))

    return {
        "broken_links": broken_links,
        "orphan_pages": orphan_pages,
        "duplicate_titles": duplicate_titles,
        "stale_pages": sorted(stale_pages, key=lambda item: item["path"]),
        "wiki_files": [str(path.relative_to(shared_root)) for path in wiki_files],
    }


def maybe_run_llm_review(shared_root: Path, requested: bool, model: str) -> dict[str, object]:
    if not requested:
        return {"requested": False, "status": "disabled", "findings": []}

    claude = shutil.which("claude")
    if not claude:
        return {
            "requested": True,
            "status": "unavailable",
            "findings": [],
            "message": "claude CLI is not installed",
        }

    sections: list[str] = []
    budget = 12000
    for path in iter_wiki_markdown_files(shared_root):
        title = markdown_title(path)
        body = first_paragraph(path)
        snippet = body[:400]
        block = f"## {path.relative_to(shared_root)}\nTitle: {title}\nSummary: {snippet}\n"
        if budget - len(block) < 0:
            break
        sections.append(block)
        budget -= len(block)

    prompt = (
        "Review this team knowledge wiki summary for contradictions or materially conflicting facts.\n"
        "Return strict JSON with shape {\"findings\": [{\"summary\": str, \"files\": [str]}]}.\n"
        "If you find no contradictions, return {\"findings\": []}.\n\n"
        + "\n".join(sections)
    )
    command = [claude, "-p", *singleton_channel_suppression_argv(), "--no-session-persistence", "--dangerously-skip-permissions", "--output-format", "text"]
    if model:
        command.extend(["--model", model])
    command.append(prompt)

    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        return {
            "requested": True,
            "status": "error",
            "findings": [],
            "message": str(exc),
        }

    stdout = completed.stdout.strip()
    try:
        payload = json.loads(stdout)
        findings = payload.get("findings") if isinstance(payload, dict) else []
        if not isinstance(findings, list):
            findings = []
        return {
            "requested": True,
            "status": "ok",
            "findings": findings,
            "raw": stdout,
        }
    except json.JSONDecodeError:
        return {
            "requested": True,
            "status": "parse-error",
            "findings": [],
            "raw": stdout,
        }


def maybe_move_capture(shared_root: Path, capture_path: Path, dry_run: bool) -> Path:
    inbox_dir = raw_root(shared_root) / "captures" / "inbox"
    promoted_dir = raw_root(shared_root) / "captures" / "promoted"
    if capture_path.parent != inbox_dir:
        return capture_path
    target = promoted_dir / capture_path.name
    if not dry_run:
        promoted_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(capture_path), str(target))
    return target


def extract_managed_block(text: str, start: str, end: str) -> str:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
    match = pattern.search(text)
    return match.group(0) if match else ""


def parse_csv_field(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_handles_field(value: str) -> dict[str, str]:
    handles: dict[str, str] = {}
    for raw_item in value.split(";"):
        item = raw_item.strip()
        if not item:
            continue
        if "=" in item:
            surface, handle = item.split("=", 1)
        elif ":" in item:
            surface, handle = item.split(":", 1)
        else:
            continue
        surface = surface.strip().lower()
        handle = handle.strip()
        if surface and handle:
            handles[surface] = handle
    return handles


def serialize_handles(handles: dict[str, str]) -> str:
    if not handles:
        return ""
    return "; ".join(f"{surface}={handle}" for surface, handle in sorted(handles.items()))


def parse_operator_profile(text: str) -> dict[str, object]:
    block = extract_managed_block(text, PRIMARY_OPERATOR_START, PRIMARY_OPERATOR_END)
    if not block:
        return {
            "configured": False,
            "role": "primary operator",
            "user_id": "",
            "display_name": "",
            "preferred_address": "",
            "aliases": [],
            "channel_handles": {},
            "communication_preferences": "",
            "decision_scope": "",
            "escalation_relevance": "",
            "updated_at": "",
        }
    fields: dict[str, str] = {}
    for line in block.splitlines():
        match = re.match(r"^- ([^:]+):\s*(.*)$", line.strip())
        if match:
            fields[match.group(1).strip()] = match.group(2).strip()
    display_name = fields.get("Display name", "")
    return {
        "configured": bool(display_name),
        "role": fields.get("Role", "primary operator"),
        "user_id": fields.get("User ID", ""),
        "display_name": display_name,
        "preferred_address": fields.get("Preferred address", ""),
        "aliases": parse_csv_field(fields.get("Aliases", "")),
        "channel_handles": parse_handles_field(fields.get("Channel handles", "")),
        "communication_preferences": fields.get("Communication preferences", ""),
        "decision_scope": fields.get("Decision scope", ""),
        "escalation_relevance": fields.get("Escalation relevance", ""),
        "updated_at": fields.get("Updated at", ""),
    }


def render_operator_profile(payload: dict[str, object]) -> str:
    lines = [
        PRIMARY_OPERATOR_START,
        "- Role: primary operator",
        f"- User ID: {payload['user_id']}",
        f"- Display name: {payload['display_name']}",
        f"- Preferred address: {payload['preferred_address']}",
        f"- Aliases: {', '.join(payload['aliases'])}",
        f"- Channel handles: {serialize_handles(payload['channel_handles'])}",
        f"- Communication preferences: {payload['communication_preferences']}",
        f"- Decision scope: {payload['decision_scope']}",
        f"- Escalation relevance: {payload['escalation_relevance']}",
        f"- Updated at: {payload['updated_at']}",
        PRIMARY_OPERATOR_END,
    ]
    return "\n".join(lines)


def upsert_operator_profile(path: Path, payload: dict[str, object], dry_run: bool) -> None:
    block = render_operator_profile(payload)
    text = read_text(path) if path.exists() else "# People\n"
    pattern = re.compile(
        re.escape(PRIMARY_OPERATOR_START) + r".*?" + re.escape(PRIMARY_OPERATOR_END),
        re.DOTALL,
    )
    if pattern.search(text):
        updated = pattern.sub(block, text, count=1)
    elif PRIMARY_OPERATOR_HEADING in text:
        updated = text.replace(PRIMARY_OPERATOR_HEADING, f"{PRIMARY_OPERATOR_HEADING}\n\n{block}", 1)
    elif "## Notes" in text:
        updated = text.replace("## Notes", f"{PRIMARY_OPERATOR_HEADING}\n\n{block}\n\n## Notes", 1)
    else:
        updated = text.rstrip() + f"\n\n{PRIMARY_OPERATOR_HEADING}\n\n{block}\n"
    write_text(path, updated.rstrip() + "\n", dry_run)


def normalize_handle(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        die(f"invalid handle format (expected surface=value): {raw}")
    surface, handle = raw.split("=", 1)
    surface = surface.strip().lower()
    handle = handle.strip()
    if not surface or not handle:
        die(f"invalid handle format (expected surface=value): {raw}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", surface):
        die(f"invalid handle surface: {surface}")
    return surface, handle


def cmd_operator_set(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    target = wiki_root(shared_root) / "people.md"
    ensure_page(target, "People", args.dry_run)
    existing = parse_operator_profile(read_text(target) if target.exists() else "")
    handles = dict(existing["channel_handles"])
    if args.handle:
        handles = {}
        for raw_handle in args.handle:
            surface, handle = normalize_handle(raw_handle)
            handles[surface] = handle
    aliases = args.alias if args.alias else list(existing["aliases"])
    payload: dict[str, object] = {
        "configured": True,
        "role": "primary operator",
        "user_id": args.user or str(existing["user_id"]) or "owner",
        "display_name": args.name.strip(),
        "preferred_address": (
            args.preferred_address.strip()
            if args.preferred_address
            else str(existing["preferred_address"]) or args.name.strip()
        ),
        "aliases": aliases,
        "channel_handles": handles,
        "communication_preferences": (
            args.communication_preferences.strip()
            if args.communication_preferences
            else str(existing["communication_preferences"])
        ),
        "decision_scope": (
            args.decision_scope.strip()
            if args.decision_scope
            else str(existing["decision_scope"])
        ),
        "escalation_relevance": (
            args.escalation_relevance.strip()
            if args.escalation_relevance
            else str(existing["escalation_relevance"])
        ),
        "updated_at": now().isoformat(timespec="seconds"),
    }
    upsert_operator_profile(target, payload, args.dry_run)
    append_log(
        shared_root,
        f"- {now().isoformat(timespec='seconds')} updated primary operator -> {target.relative_to(shared_root)}",
        args.dry_run,
    )
    result = {
        **payload,
        "path": str(target),
        "relative_path": str(target.relative_to(shared_root)),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print("role: primary operator")
        print(f"user_id: {payload['user_id']}")
        print(f"display_name: {payload['display_name']}")
        print(f"relative_path: {target.relative_to(shared_root)}")
    return 0


def cmd_operator_show(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    target = wiki_root(shared_root) / "people.md"
    payload = parse_operator_profile(read_text(target) if target.exists() else "")
    result = {
        **payload,
        "path": str(target),
        "relative_path": str(target.relative_to(shared_root)),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"configured: {'true' if payload['configured'] else 'false'}")
        if payload["configured"]:
            print("role: primary operator")
            print(f"user_id: {payload['user_id']}")
            print(f"display_name: {payload['display_name']}")
            print(f"preferred_address: {payload['preferred_address']}")
            if payload["channel_handles"]:
                print(f"channel_handles: {serialize_handles(payload['channel_handles'])}")
        print(f"path: {target}")
    return 0


# ---------------------------------------------------------------------------
# LLM-assisted related-page proposer. Called from cmd_promote when
# --llm-review is set. Returns a list of {page, rationale} suggestions.
# ---------------------------------------------------------------------------

def propose_related_pages(
    shared_root: Path,
    capture: dict | None,
    summary: str,
    model: str = "",
    limit: int = 15,
) -> list[dict]:
    """Ask the local Claude Code CLI which wiki pages are most likely affected.

    Backend: invokes `claude` CLI with `--output-format text` and a strict-JSON
    prompt. Returns empty list if `claude` is not on PATH, if the CLI fails,
    or if the response is not valid JSON — existing promote behavior is the
    fallback, so this never blocks the command.
    """
    claude = shutil.which("claude")
    if not claude:
        return []

    wiki = wiki_root(shared_root)
    if not wiki.exists():
        return []

    pages: list[str] = []
    budget = 6000
    for path in iter_wiki_markdown_files(shared_root):
        title = markdown_title(path)
        line = f"- {path.relative_to(shared_root)} — {title}"
        if budget - len(line) < 0:
            break
        pages.append(line)
        budget -= len(line)

    capture_excerpt = ""
    if capture:
        capture_excerpt = (capture.get("text") or "")[:1500]

    prompt = (
        f"Given this new knowledge capture:\n\n"
        f"Summary: {summary[:800]}\n\n"
        f"Capture body: {capture_excerpt}\n\n"
        f"Candidate wiki pages:\n" + "\n".join(pages) + "\n\n"
        f"List the {limit} most-likely-related pages. Return strict JSON: "
        f"{{\"suggestions\": [{{\"page\": \"<relative path>\", \"rationale\": \"<1 sentence>\"}}]}}. "
        f"Return {{\"suggestions\": []}} if nothing applies."
    )
    command = [claude, "-p", *singleton_channel_suppression_argv(), "--no-session-persistence", "--dangerously-skip-permissions", "--output-format", "text"]
    if model:
        command.extend(["--model", model])
    command.append(prompt)

    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []

    try:
        data = json.loads(completed.stdout.strip())
    except json.JSONDecodeError:
        return []
    suggestions = data.get("suggestions") if isinstance(data, dict) else []
    return suggestions[:limit] if isinstance(suggestions, list) else []


def cmd_promote(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    kind = normalize_kind(args.kind)
    capture = None
    capture_path = None
    if args.capture:
        capture_path, capture = resolve_capture(shared_root, args.capture)
    summary = args.summary or (capture or {}).get("text", "")
    if not summary.strip():
        die("--summary is required when --capture is not provided")
    target = target_for_kind(shared_root, kind, args.page, args.title or (capture or {}).get("title", ""))
    ensure_page(target, page_title(target.stem), args.dry_run)
    append_note(target, build_note(args, capture, summary), args.dry_run)
    promoted_capture_path = ""
    if capture_path:
        promoted_capture_path = str(maybe_move_capture(shared_root, capture_path, args.dry_run))
    append_log(
        shared_root,
        f"- {now().isoformat(timespec='seconds')} promoted {kind} -> {target.relative_to(shared_root)}",
        args.dry_run,
    )

    # --llm-review: propose 10-15 related wiki pages; record suggestions
    # in the promotion log so downstream reviewers can pick them up.
    related: list[dict] = []
    if getattr(args, "llm_review", False):
        related = propose_related_pages(
            shared_root,
            capture,
            summary,
            model=getattr(args, "llm_model", "") or "",
            limit=getattr(args, "llm_limit", 15),
        )
        if related:
            related_block = "\n".join(
                f"  - suggested: {item.get('page')} ({item.get('rationale')})" for item in related
            )
            append_log(
                shared_root,
                related_block,
                args.dry_run,
            )

    payload = {
        "kind": kind,
        "target": str(target),
        "relative_path": str(target.relative_to(shared_root)),
        "capture": args.capture or "",
        "promoted_capture_path": promoted_capture_path,
        "related_pages": related,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"kind: {kind}")
        print(f"target: {target}")
        if args.capture:
            print(f"capture: {args.capture}")
        if related:
            print(f"related ({len(related)}):")
            for item in related:
                print(f"- {item.get('page')}: {item.get('rationale')}")
    return 0


def iter_search_files(shared_root: Path, scope: str) -> list[Path]:
    files: list[Path] = []
    if scope in {"wiki", "all"}:
        files.extend(sorted(wiki_root(shared_root).rglob("*.md")))
    if scope in {"raw", "all"}:
        files.extend(sorted(raw_root(shared_root).rglob("*.json")))
        files.extend(sorted(raw_root(shared_root).rglob("*.md")))
    return [path for path in files if path.is_file()]


def line_matches(line: str, query: str, tokens: list[str]) -> bool:
    lower = line.lower()
    query_lower = query.lower()
    if query_lower in lower:
        return True
    return bool(tokens) and all(token in lower for token in tokens)


# ---------------------------------------------------------------------------
# Hybrid search wrap: bridge-knowledge search optionally delegates to
# tools/memory-manager.py's vector+BM25 engine. When a bridge-wiki-hybrid-v2
# index exists for the resolved agent, hybrid is selected automatically
# (reported as engine="hybrid-auto"). `--hybrid` forces hybrid explicitly.
# `--legacy-text` forces legacy regex and beats auto-detection — operators
# who hardcoded legacy in scripts keep that escape hatch.
# ---------------------------------------------------------------------------

# Mapping from bridge-knowledge `--scope` to memory-manager `--source` filters.
# Every value in `SEARCH_SCOPES` must appear here. `_resolve_scope_sources`
# raises rather than silently returning an empty filter for unknown scopes
# so a deliberately narrowed search never broadens on a typo.
_SCOPE_TO_SOURCES: dict[str, list[str]] = {
    "wiki": ["wiki", "memory-weekly", "memory-monthly"],
    "raw":  ["capture-ingested"],
    "all":  [],  # no filter → memory-manager searches every configured source
}


def _resolve_scope_sources(scope: str) -> list[str]:
    """Return the `--source` filters for a given `--scope`.

    Raises KeyError for unmapped scopes so callers do not silently broaden
    a deliberately narrowed search into an unfiltered one. The CLI
    `choices=SEARCH_SCOPES` guard means this only fires when the mapping
    and the `SEARCH_SCOPES` constant diverge.
    """
    assert set(SEARCH_SCOPES).issubset(_SCOPE_TO_SOURCES.keys()), \
        "every SEARCH_SCOPES value must appear in _SCOPE_TO_SOURCES"
    return _SCOPE_TO_SOURCES[scope]


def _memory_manager_script(shared_root: Path | None = None) -> Path:
    """Resolve the memory-manager.py path.

    Resolution order:
    1. `shared_root`'s install root: `<install>/tools/memory-manager.py`
       where `<install>` is `shared_root.parent` (e.g. `shared_root=~/.agent-bridge/shared`
       → install=`~/.agent-bridge`).
    2. `BRIDGE_HOME` env var.
    3. `~/.agent-bridge` fallback.
    """
    if shared_root is not None:
        try:
            install_root = shared_root.parent
            candidate = install_root / "tools" / "memory-manager.py"
            if candidate.exists():
                return candidate
        except (OSError, ValueError):
            pass
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        candidate = Path(env_home) / "tools" / "memory-manager.py"
        if candidate.exists():
            return candidate
    return Path.home() / ".agent-bridge" / "tools" / "memory-manager.py"


def _resolve_hybrid_agent(args: argparse.Namespace) -> str:
    """Pick the agent id that `tools/memory-manager.py search --agent ...` receives.

    Resolution order:
    1. Explicit CLI flag `--agent` (added to `search` subparser).
    2. `BRIDGE_AGENT_ID` environment variable.
    3. `BRIDGE_AGENT` environment variable (legacy fallback name).
    4. The last directory component of `args.shared_root` — *only* when that
       looks like an agent-home layout (`<bridge-home>/agents/<name>`).
    5. Hard fallback: the string "default" — memory-manager will then
       surface "unknown agent" rather than silently hitting a random DB.
    """
    agent = getattr(args, "agent", "") or ""
    if agent:
        return agent
    for env_var in ("BRIDGE_AGENT_ID", "BRIDGE_AGENT"):
        value = os.environ.get(env_var, "")
        if value:
            return value
    try:
        shared_root = Path(args.shared_root).resolve()
        parts = shared_root.parts
        if len(parts) >= 2 and parts[-2] == "agents":
            return parts[-1]
    except (OSError, ValueError):
        pass
    return "default"


def _v2_index_available(agent: str) -> bool:
    """Return True iff a bridge-wiki-hybrid-v2 index exists for `agent`.

    Lookup order for the index DB:
      1. `$BRIDGE_HOME/runtime/memory/<agent>.sqlite`
      2. `~/.agent-bridge/runtime/memory/<agent>.sqlite`

    Criteria (all must hold):
      - File exists and is non-empty.
      - `meta` table has `index_kind = 'bridge-wiki-hybrid-v2'`.
      - `chunks` table has at least one row.

    Any exception (missing sqlite3, corrupt DB, permission denied,
    unexpected schema) falls back to False — auto-hybrid never hijacks a
    call that the legacy engine could handle.
    """
    try:
        import sqlite3  # local import so bridge-knowledge stays lazy
    except ImportError:
        return False
    candidates: list[Path] = []
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        candidates.append(Path(env_home) / "runtime" / "memory" / f"{agent}.sqlite")
    candidates.append(Path.home() / ".agent-bridge" / "runtime" / "memory" / f"{agent}.sqlite")
    seen: set[str] = set()
    for db_path in candidates:
        key = str(db_path)
        if key in seen:
            continue
        seen.add(key)
        try:
            if not db_path.exists() or db_path.stat().st_size == 0:
                continue
            uri = f"file:{db_path}?mode=ro"
            conn = sqlite3.connect(uri, uri=True, timeout=2)
        except Exception:
            continue
        try:
            row = conn.execute(
                "SELECT value FROM meta WHERE key = 'index_kind'"
            ).fetchone()
            if not row or row[0] != "bridge-wiki-hybrid-v2":
                continue
            chunks = conn.execute("SELECT 1 FROM chunks LIMIT 1").fetchone()
            if chunks is None:
                continue
            return True
        except Exception:
            continue
        finally:
            try:
                conn.close()
            except Exception:
                pass
    return False


def search_via_memory_manager(args: argparse.Namespace) -> list[dict] | None:
    """Delegate search to the hybrid engine. Returns None on any failure.

    Honors `args.scope` by mapping to memory-manager's `--source` filter.
    Resolves `memory-manager.py` from `args.shared_root` so multi-install setups
    don't accidentally query the wrong index. `--agent` is resolved via
    `_resolve_hybrid_agent` so callers outside `patch` aren't forced to set
    `BRIDGE_AGENT_ID`.
    """
    shared_root = Path(args.shared_root)
    script = _memory_manager_script(shared_root)
    if not script.exists():
        return None
    python_bin = sys.executable or "python3"
    cmd = [
        python_bin, str(script),
        "search",
        "--agent", _resolve_hybrid_agent(args),
        "--max-results", str(args.limit),
        "--json",
    ]
    try:
        sources = _resolve_scope_sources(args.scope)
    except KeyError:
        # Scope not mapped — refuse to broaden the search silently.
        return None
    for src in sources:
        cmd.extend(["--source", src])
    # memory-manager takes the query as a trailing positional argument.
    cmd.append(args.query)
    try:
        completed = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=True)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None
    results = payload.get("results")
    if not isinstance(results, list):
        return None
    normalized: list[dict] = []
    for item in results:
        raw_path = item.get("path", "")
        try:
            rel = str(Path(raw_path).resolve().relative_to(shared_root.resolve()))
        except (OSError, ValueError):
            rel = raw_path  # fallback — path is outside shared_root
        normalized.append({
            "path": raw_path,
            "relative_path": rel,
            "line": int(item.get("startLine") or 0),
            "snippet": item.get("snippet", ""),
            "score": float(item.get("score") or 0.0),
            "source": "hybrid",
        })
    return normalized


def cmd_search(args: argparse.Namespace) -> int:
    # Engine selection precedence:
    #   1. `--legacy-text` → always legacy (explicit opt-out, beats auto).
    #   2. `--hybrid`      → explicit opt-in (tagged "hybrid").
    #   3. Auto-detect: if a v2 index exists for the resolved agent,
    #      use hybrid (tagged "hybrid-auto"). Else legacy.
    #
    # Rationale: operators who hardcoded legacy in scripts keep
    # `--legacy-text` as an escape hatch. Fresh callers on v2-indexed
    # agents get hybrid automatically without having to flip `--hybrid`
    # on every invocation.
    engine_choice = "legacy-text"
    engine_reported = "legacy-text"
    if getattr(args, "legacy_text", False):
        engine_choice = "legacy-text"
        engine_reported = "legacy-text"
    elif getattr(args, "hybrid", False):
        engine_choice = "hybrid"
        engine_reported = "hybrid"
    else:
        try:
            agent_id = _resolve_hybrid_agent(args)
        except Exception:
            agent_id = ""
        if agent_id and _v2_index_available(agent_id):
            engine_choice = "hybrid"
            engine_reported = "hybrid-auto"
        else:
            engine_choice = "legacy-text"
            engine_reported = "legacy-text"

    if engine_choice == "hybrid":
        hybrid = search_via_memory_manager(args)
        if hybrid is not None:
            payload = {
                "query": args.query,
                "scope": args.scope,
                "engine": engine_reported,
                "count": len(hybrid),
                "results": hybrid,
            }
            if args.json:
                print(json.dumps(payload, ensure_ascii=False, indent=2))
            else:
                print(f"query: {args.query}")
                print(f"engine: {engine_reported}")
                print(f"matches: {len(hybrid)}")
                for item in hybrid:
                    print(f"- {item['relative_path']}:{item['line']} (score={item['score']:.3f}) {item['snippet']}")
            return 0
        # Hybrid fell through (memory-manager unreachable or errored).
        # Fall back to legacy so callers always get *some* answer.

    shared_root = Path(args.shared_root)
    tokens = [token for token in re.split(r"\s+", args.query.lower().strip()) if token]
    results: list[dict[str, object]] = []
    for path in iter_search_files(shared_root, args.scope):
        try:
            lines = read_text(path).splitlines()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(lines, start=1):
            if line_matches(line, args.query, tokens):
                results.append(
                    {
                        "path": str(path),
                        "relative_path": str(path.relative_to(shared_root)),
                        "line": number,
                        "snippet": line.strip(),
                    }
                )
                break
        if len(results) >= args.limit:
            break
    payload = {
        "query": args.query,
        "scope": args.scope,
        "engine": "legacy-text",
        "count": len(results),
        "results": results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        print(f"engine: legacy-text")
        print(f"matches: {len(results)}")
        for item in results:
            print(f"- {item['relative_path']}:{item['line']} {item['snippet']}")
    return 0


def cmd_lint(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    required = [wiki_root(shared_root) / item for item in WIKI_FILES]
    required.extend(wiki_root(shared_root) / item for item in WIKI_DIRS)
    required.extend(shared_root / item for item in RAW_DIRS)
    missing = [str(path.relative_to(shared_root)) for path in required if not path.exists()]
    lint_details = lint_wiki(shared_root, args.stale_days)
    llm_review = maybe_run_llm_review(shared_root, args.llm_review, args.llm_model)
    problems = []
    problems.extend(f"missing: {item}" for item in missing)
    problems.extend(
        f"broken_link: {item['source']} -> {item['target']}" for item in lint_details["broken_links"]
    )
    problems.extend(f"orphan_page: {item}" for item in lint_details["orphan_pages"])
    problems.extend(
        f"duplicate_title: {item['title']} ({', '.join(item['files'])})"
        for item in lint_details["duplicate_titles"]
    )
    warnings = [
        f"stale_page: {item['path']} ({item['days_old']}d)"
        for item in lint_details["stale_pages"]
    ]
    if llm_review.get("requested") and llm_review.get("status") != "ok":
        warnings.append(f"llm_review: {llm_review.get('status')}")
    ok = len(problems) == 0
    payload = {
        "ok": ok,
        "shared_root": str(shared_root),
        "wiki_root": str(wiki_root(shared_root)),
        "missing": missing,
        "problems": problems,
        "warnings": warnings,
        **lint_details,
        "llm_review": llm_review,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"ok: {'true' if ok else 'false'}")
        if problems:
            print("problems:")
            for item in problems:
                print(f"- {item}")
        if warnings:
            print("warnings:")
            for item in warnings:
                print(f"- {item}")
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--shared-root", required=True)
        subparser.add_argument("--template-root", required=True)
        subparser.add_argument("--team-name", default="Team")
        subparser.add_argument("--dry-run", action="store_true")
        subparser.add_argument("--json", action="store_true")

    init_parser = subparsers.add_parser("init")
    add_common(init_parser)
    init_parser.set_defaults(func=cmd_init)

    capture_parser = subparsers.add_parser("capture")
    add_common(capture_parser)
    capture_parser.add_argument("--source", required=True)
    capture_parser.add_argument("--author", default="")
    capture_parser.add_argument("--channel", default="")
    capture_parser.add_argument("--title", default="")
    text_group = capture_parser.add_mutually_exclusive_group(required=True)
    text_group.add_argument("--text")
    text_group.add_argument("--text-file")
    capture_parser.set_defaults(func=cmd_capture)

    promote_parser = subparsers.add_parser("promote")
    add_common(promote_parser)
    promote_parser.add_argument("--kind", required=True)
    promote_parser.add_argument("--capture", default="")
    promote_parser.add_argument("--page", default="")
    promote_parser.add_argument("--title", default="")
    promote_parser.add_argument("--summary", default="")
    promote_parser.add_argument("--llm-review", action="store_true",
        help="propose 10-15 related wiki pages via claude CLI")
    promote_parser.add_argument("--llm-model", default="")
    promote_parser.add_argument("--llm-limit", type=int, default=15,
        help="max related-page suggestions (default 15)")
    promote_parser.set_defaults(func=cmd_promote)

    operator_set_parser = subparsers.add_parser("operator-set")
    add_common(operator_set_parser)
    operator_set_parser.add_argument("--user", default="")
    operator_set_parser.add_argument("--name", required=True)
    operator_set_parser.add_argument("--preferred-address", default="")
    operator_set_parser.add_argument("--alias", action="append", default=[])
    operator_set_parser.add_argument("--handle", action="append", default=[])
    operator_set_parser.add_argument("--communication-preferences", default="")
    operator_set_parser.add_argument("--decision-scope", default="")
    operator_set_parser.add_argument("--escalation-relevance", default="")
    operator_set_parser.set_defaults(func=cmd_operator_set)

    operator_show_parser = subparsers.add_parser("operator-show")
    add_common(operator_show_parser)
    operator_show_parser.set_defaults(func=cmd_operator_show)

    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("--shared-root", required=True)
    search_parser.add_argument("--query", required=True)
    search_parser.add_argument("--scope", choices=SEARCH_SCOPES, default="wiki")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--json", action="store_true")
    search_parser.add_argument("--hybrid", action="store_true",
        help="force hybrid vector+BM25 search via tools/memory-manager.py "
             "(default: auto-hybrid when a bridge-wiki-hybrid-v2 index exists, "
             "else legacy regex)")
    search_parser.add_argument("--agent", default="",
        help="agent id for hybrid dispatch and v2-index auto-detect "
             "(defaults to BRIDGE_AGENT_ID env or shared-root tail)")
    search_parser.add_argument("--legacy-text", action="store_true",
        help="force legacy regex engine (opt-out of auto-hybrid when v2 index "
             "is present); highest precedence flag")
    search_parser.set_defaults(func=cmd_search)

    lint_parser = subparsers.add_parser("lint")
    lint_parser.add_argument("--shared-root", required=True)
    lint_parser.add_argument("--stale-days", type=int, default=90)
    lint_parser.add_argument("--llm-review", action="store_true")
    lint_parser.add_argument("--llm-model", default="")
    lint_parser.add_argument("--json", action="store_true")
    lint_parser.set_defaults(func=cmd_lint)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "text_file", None):
        args.text = Path(args.text_file).read_text(encoding="utf-8")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
