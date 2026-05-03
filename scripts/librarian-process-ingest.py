#!/usr/bin/env python3
"""librarian-process-ingest.py — reference implementation.

Processes one `[librarian-ingest]` task body. The body is a markdown file
produced by `wiki-daily-ingest.sh` listing capture files (absolute paths, one
per `- ` bullet) grouped under headings like `### Daily notes`, `### Research
files`, `### Other (...)`.

For each capture file this script:
  1. loads the capture JSON and extracts the schema_version=1 envelope
     (`suggested_entities`, `suggested_concepts`, `suggested_slug`,
     `suggested_title`, `excerpt`)
  2. derives `kind` from the first entity path prefix
     (user/* → user, decisions/* → decision, projects/* → project,
     else → shared)
  3. derives `title` from `suggested_title` or the first heading in `excerpt`
  4. derives `summary` from `excerpt` (truncated)
  5. calls `bridge-knowledge promote --kind ... --capture ... --page ...
     --title ... --summary ... [--dry-run]`
  6. emits one JSONL result per capture to stdout

Hard rules (match CLAUDE.md contract):
  - max 10 captures per run (configurable, but capped)
  - min 3s between promote calls
  - first call of a non-dry-run batch MUST be a canary dry-run; if the canary
    fails the whole batch aborts

CLI:
  python3 librarian-process-ingest.py --task-body <path> [options]

Options:
  --task-body PATH         markdown produced by wiki-daily-ingest (required)
  --max N                  max captures per run (default 10, hard cap 10)
  --sleep SEC              sleep between promote calls (default 3)
  --dry-run                force --dry-run on every promote (no canary needed)
  --shared-root PATH       override shared root (default ~/.agent-bridge/shared)
  --bridge-knowledge PATH  path to bridge-knowledge.py (auto-detected)

Exit codes:
  0 = all captures processed (some may have failed; see JSONL)
  1 = canary failed, batch aborted
  2 = usage / IO error
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HARD_CAP = 10
SCHEMA_VERSION = "1"
# Map envelope entity prefix → bridge-knowledge promote --kind value.
#
# Stream C's task spec names the kinds as `user|shared|project|decision`, but
# the live `bridge-knowledge.py` KIND_ALIASES set (as of v0.3.0) only
# recognizes: people|agents|operating-rules|data-sources|tools|decision|
# project|playbook. We translate accordingly, keeping the envelope contract
# stable:
#   envelope says "user/..." → promote --kind people   (closest current alias)
#   envelope says "shared/..." → promote --kind operating-rules (wiki default)
# If Stream D or a later version adds explicit `user` and `shared` aliases,
# this mapping can be relaxed back to identity.
ENTITY_KIND_PREFIXES = {
    "user/": "people",
    "users/": "people",
    "people/": "people",
    "decisions/": "decision",
    "decision/": "decision",
    "projects/": "project",
    "project/": "project",
    "shared/": "operating-rules",
    "agents/": "agents",
    "tools/": "tools",
    "playbooks/": "playbook",
    "data-sources/": "data-sources",
}
DEFAULT_KIND = "operating-rules"
SUMMARY_MAX_CHARS = 2000


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Librarian ingest processor")
    parser.add_argument("--task-body", required=True,
                        help="markdown file listing capture paths")
    parser.add_argument("--max", type=int, default=HARD_CAP,
                        help=f"max captures per run (hard cap {HARD_CAP})")
    parser.add_argument("--sleep", type=float, default=3.0,
                        help="seconds between promote calls (default 3.0)")
    parser.add_argument("--dry-run", action="store_true",
                        help="force --dry-run on every promote")
    parser.add_argument("--shared-root",
                        default=os.environ.get("BRIDGE_SHARED_DIR",
                                               str(Path.home() / ".agent-bridge" / "shared")))
    parser.add_argument("--template-root",
                        default=os.environ.get("BRIDGE_TEMPLATE_ROOT",
                                               str(Path.home() / ".agent-bridge")))
    parser.add_argument("--team-name",
                        default=os.environ.get("BRIDGE_TEAM_NAME", "team"))
    parser.add_argument("--bridge-knowledge",
                        default=os.environ.get("BRIDGE_KNOWLEDGE",
                                               str(Path.home() / ".agent-bridge" / "bridge-knowledge.py")))
    return parser.parse_args(argv)


def extract_capture_paths(task_body: Path) -> list[Path]:
    """Pull `- /abs/path` bullets out of the ingest task body."""
    captures: list[Path] = []
    if not task_body.exists():
        return captures
    for line in task_body.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*-\s+(/[^\s]+)", line)
        if not m:
            continue
        path = Path(m.group(1))
        if path.suffix.lower() in {".md", ".json"}:
            captures.append(path)
    # dedupe preserving order
    seen: set[Path] = set()
    ordered: list[Path] = []
    for p in captures:
        if p in seen:
            continue
        seen.add(p)
        ordered.append(p)
    return ordered


def load_envelope(capture_path: Path) -> dict | None:
    """Load a capture file and return the structured envelope (schema_version='1').

    Supports two shapes:
      1. pure JSON file with envelope fields at root, with two sub-shapes:
         1a. legacy / direct emitters: the v1 envelope is the top-level
             object itself (schema_version=='1' at root).
         1b. bridge-memory capture wrapper: cmd_capture stores the v1
             envelope under "envelope" while keeping capture metadata
             (agent, user, source, created_at, channel, title) at the
             root and only promoting four fields (schema_version,
             suggested_slug, suggested_title, session_type, trigger).
             Required reader fields (excerpt, suggested_entities,
             suggested_concepts) are envelope-only, so we must unwrap
             to surface them.
      2. markdown file with a ```json ... ``` fenced envelope block
    Returns None if the envelope is missing or schema_version != '1'.
    """
    if not capture_path.exists():
        return None
    text = capture_path.read_text(encoding="utf-8", errors="replace")

    # shape 1: entire file is JSON
    if capture_path.suffix.lower() == ".json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        if not isinstance(data, dict):
            return None
        # shape 1b: bridge-memory wrapper with a nested v1 envelope. The
        # wrapper promotes schema_version to root, so we must prefer the
        # nested envelope before checking root — otherwise we would
        # return the wrapper (missing excerpt / suggested_entities /
        # suggested_concepts, which live envelope-only).
        inner = data.get("envelope")
        if isinstance(inner, dict) and inner.get("schema_version") == SCHEMA_VERSION:
            return inner
        # shape 1a: root-level v1 envelope (legacy / direct emitters).
        if data.get("schema_version") == SCHEMA_VERSION:
            return data
        return None

    # shape 2: fenced json block anywhere in the markdown
    fence = re.search(r"```json\s*\n(.*?)\n```", text, flags=re.S)
    if fence:
        try:
            data = json.loads(fence.group(1))
        except json.JSONDecodeError:
            return None
        if isinstance(data, dict) and data.get("schema_version") == SCHEMA_VERSION:
            return data
    return None


def infer_kind(envelope: dict) -> str:
    entities = envelope.get("suggested_entities") or []
    if isinstance(entities, list) and entities:
        first = str(entities[0]).strip().lstrip("/")
        for prefix, kind in ENTITY_KIND_PREFIXES.items():
            if first.startswith(prefix):
                return kind
    return DEFAULT_KIND


def infer_title(envelope: dict) -> str:
    title = (envelope.get("suggested_title") or "").strip()
    if title:
        return title
    excerpt = envelope.get("excerpt") or ""
    for line in excerpt.splitlines():
        m = re.match(r"^#+\s+(.+)$", line.strip())
        if m:
            return m.group(1).strip()
    return ""


def infer_summary(envelope: dict) -> str:
    excerpt = (envelope.get("excerpt") or "").strip()
    if len(excerpt) > SUMMARY_MAX_CHARS:
        excerpt = excerpt[:SUMMARY_MAX_CHARS] + "…"
    return excerpt


def infer_page(envelope: dict) -> str:
    slug = (envelope.get("suggested_slug") or "").strip()
    if slug:
        return slug
    entities = envelope.get("suggested_entities") or []
    if isinstance(entities, list) and entities:
        first = str(entities[0]).strip().lstrip("/")
        tail = first.split("/", 1)[1] if "/" in first else first
        return tail.rsplit(".", 1)[0]
    return ""


# Filesystem segments that, when present in the capture path, reliably
# imply a specific promote kind. Checked in order — first match wins.
# Mirrors ENTITY_KIND_PREFIXES but reads from disk layout instead of
# envelope metadata. Deterministic; no LLM.
#
# Research captures (`memory/research/**`) are **deliberately not
# mapped here**. The research subtree mixes papers, ingredients,
# frameworks, competitors, and regulations — each of which belongs
# under a different canonical location per wiki-entity-lifecycle.md
# (ingredients → entities/, papers → research/papers/, regulations →
# operating-rules/, etc.). Auto-collapsing all of them to a single
# promote kind is a semantic misroute. We let research captures fall
# through to the ambiguous-kind reject gate instead, which puts the
# categorization in human hands rather than guessing wrong. If a
# deployment has research subtypes it wants auto-routed, it can add
# explicit hints here with confidence in the target mapping.
PATH_KIND_HINTS = (
    ("/memory/projects/", "project"),
    ("/memory/decisions/", "decision"),
    ("/memory/playbooks/", "playbook"),
    ("/memory/tools/", "tools"),
    ("/memory/people/", "people"),
    ("/memory/users/", "people"),
    ("/memory/data-sources/", "data-sources"),
    ("/memory/shared/", "operating-rules"),
)


def infer_kind_from_path(capture_path: Path) -> str:
    """Derive a promote --kind from the capture's filesystem location.

    Returns "" when the path does not carry a recognizable hint, so the
    caller can fall back to explicit-reject behavior (CLAUDE.md §9)
    instead of silently defaulting to `operating-rules`.
    """
    path_str = str(capture_path)
    for needle, kind in PATH_KIND_HINTS:
        if needle in path_str:
            return kind
    return ""


def suggested_entity_from_path(capture_path: Path, kind: str) -> str:
    """Build a synthetic `<prefix>/<slug>` so promote routing has a page.

    Paired with `infer_kind_from_path`. Example:
      ``.../memory/projects/formulation-science.md`` + kind="project"
      → ``projects/formulation-science``
    """
    if not kind:
        return ""
    prefix_map = {
        "project": "projects",
        "decision": "decisions",
        "playbook": "playbooks",
        "tools": "tools",
        "people": "people",
        "data-sources": "data-sources",
        "operating-rules": "shared",
    }
    prefix = prefix_map.get(kind, kind)
    return f"{prefix}/{capture_path.stem}"


def build_envelope_from_fallback(capture_path: Path) -> dict:
    """Minimal envelope when schema_version=1 is absent.

    The librarian CLAUDE.md allows LLM fallback but this reference script
    stays deterministic. Inference order:

      1. Path-based hint (``memory/projects/*.md`` → kind=project, etc.).
         When matched we populate ``suggested_entities`` with a synthetic
         ``<prefix>/<stem>`` so downstream ``infer_kind`` picks up the
         non-default mapping. This rescues the common case where an
         agent writes a structured memory file without a PreCompact
         envelope.
      2. No hint → return an empty envelope. Callers treat this as
         ``ambiguous-kind`` and escalate per CLAUDE.md §9 rather than
         silently promoting to ``operating-rules``.
    """
    text = ""
    try:
        text = capture_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        pass
    envelope: dict = {
        "schema_version": SCHEMA_VERSION,
        "suggested_entities": [],
        "suggested_concepts": [],
        "suggested_slug": capture_path.stem,
        "suggested_title": capture_path.stem.replace("-", " ").title(),
        "excerpt": text[:1500],
        "_fallback": True,
    }
    path_kind = infer_kind_from_path(capture_path)
    if path_kind:
        synthetic_entity = suggested_entity_from_path(capture_path, path_kind)
        if synthetic_entity:
            envelope["suggested_entities"] = [synthetic_entity]
            envelope["_fallback_kind_hint"] = path_kind
    return envelope


def capture_id_for(shared_root: Path, capture_path: Path) -> str:
    """Return the capture id bridge-knowledge expects, or "" if the capture
    does not live under `<shared_root>/captures/inbox/<id>.json`.

    bridge-knowledge.cmd_promote's `--capture` takes an id (filename stem),
    not an absolute path; resolve_capture() looks under
    `<shared_root>/captures/inbox/` and `<shared_root>/captures/promoted/`.
    Librarian may be fed capture files from agent-local memory (not yet
    under shared_root) — in that case we skip `--capture` and fall through
    to the `--summary` path.
    """
    inbox = shared_root / "captures" / "inbox"
    if capture_path.parent == inbox and capture_path.suffix == ".json":
        return capture_path.stem
    return ""


def run_promote(
    bridge_knowledge: Path,
    shared_root: Path,
    template_root: Path,
    team_name: str,
    capture_path: Path,
    kind: str,
    page: str,
    title: str,
    summary: str,
    dry_run: bool,
) -> tuple[bool, str, str]:
    """Call bridge-knowledge promote; return (ok, stdout, stderr)."""
    cmd = [
        sys.executable, str(bridge_knowledge), "promote",
        "--kind", kind,
        "--summary", summary or title or "(no summary)",
        "--shared-root", str(shared_root),
        "--template-root", str(template_root),
        "--team-name", team_name,
        "--json",
    ]
    cap_id = capture_id_for(shared_root, capture_path)
    if cap_id:
        cmd.extend(["--capture", cap_id])
    if page:
        cmd.extend(["--page", page])
    if title:
        cmd.extend(["--title", title])
    if dry_run:
        cmd.append("--dry-run")
    try:
        completed = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, "", f"subprocess error: {exc}"
    return completed.returncode == 0, completed.stdout, completed.stderr


_DAILY_NOTE_STEM_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def is_daily_note_path(capture_path: Path) -> bool:
    """Detect captures that are agent daily-note files.

    Matches ``.../memory/YYYY-MM-DD.md``. These must never travel through
    the promote path — wiki-graph-rules.md §2 requires byte-equivalent
    replication via wiki-daily-copy.py instead. The 2026-04-19 incident
    happened because such captures landed here and got silent-promoted
    into operating-rules.md.
    """
    if not capture_path.name.endswith(".md"):
        return False
    if "/memory/" not in str(capture_path):
        return False
    return bool(_DAILY_NOTE_STEM_RE.match(capture_path.stem))


def process_one(
    capture_path: Path,
    bridge_knowledge: Path,
    shared_root: Path,
    template_root: Path,
    team_name: str,
    dry_run: bool,
) -> dict:
    result: dict = {
        "capture": str(capture_path),
        "status": "pending",
        "kind": "",
        "page": "",
        "title": "",
        "dry_run": dry_run,
    }

    # Rule #8: daily-note captures are always rejected here. They are
    # replicas, not promote candidates.
    if is_daily_note_path(capture_path):
        result["status"] = "rejected"
        result["reason"] = "daily-note-misrouted"
        result["error"] = (
            "capture path is agent daily note (memory/YYYY-MM-DD.md); "
            "wiki-daily-copy.py handles these, not promote"
        )
        return result

    envelope = load_envelope(capture_path)
    if envelope is None:
        envelope = build_envelope_from_fallback(capture_path)
        result["envelope"] = "fallback"
    else:
        result["envelope"] = "v1"

    kind = infer_kind(envelope)
    page = infer_page(envelope)
    title = infer_title(envelope)
    summary = infer_summary(envelope)

    # Rule #9: envelope fallback with no path-derived kind hint must NOT
    # silent-promote to DEFAULT_KIND (operating-rules). build_envelope_
    # from_fallback sets ``_fallback_kind_hint`` iff the capture path
    # matched a known layout hint; absence means we cannot classify
    # safely. Reject + escalate instead of dumping into a single-file
    # target.
    if (
        envelope.get("_fallback")
        and not envelope.get("_fallback_kind_hint")
    ):
        result["status"] = "rejected"
        result["reason"] = "ambiguous-kind"
        result["kind"] = kind  # for audit: what we would have used
        result["error"] = (
            "capture has no schema_version=1 envelope and no path-based "
            "kind hint; would have defaulted to operating-rules which is "
            "forbidden by librarian CLAUDE.md §9"
        )
        return result

    result["kind"] = kind
    result["page"] = page
    result["title"] = title

    ok, stdout, stderr = run_promote(
        bridge_knowledge, shared_root, template_root, team_name,
        capture_path, kind, page, title, summary, dry_run,
    )
    if ok:
        result["status"] = "ok"
        # parse promote JSON payload to expose target
        try:
            payload = json.loads(stdout or "{}")
            result["target"] = payload.get("relative_path") or payload.get("target", "")
            result["related_pages"] = payload.get("related_pages", [])
        except json.JSONDecodeError:
            result["target"] = ""
    else:
        result["status"] = "failed"
        result["error"] = (stderr or stdout or "").strip()[:400]
    return result


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    task_body = Path(args.task_body)
    shared_root = Path(args.shared_root)
    template_root = Path(args.template_root)
    team_name = args.team_name
    bridge_knowledge = Path(args.bridge_knowledge)

    if not bridge_knowledge.exists():
        print(f"bridge-knowledge not found: {bridge_knowledge}", file=sys.stderr)
        return 2
    if not task_body.exists():
        print(f"task body not found: {task_body}", file=sys.stderr)
        return 2

    captures = extract_capture_paths(task_body)
    cap = min(args.max, HARD_CAP)
    batch = captures[:cap]
    deferred = captures[cap:]

    if not batch:
        print(json.dumps({"status": "empty", "deferred": len(deferred)}))
        return 0

    # Canary: first call MUST be dry-run unless the whole run is dry.
    canary_cap = batch[0]
    canary_result = process_one(canary_cap, bridge_knowledge, shared_root,
                                template_root, team_name, dry_run=True)
    canary_result["canary"] = True
    print(json.dumps(canary_result, ensure_ascii=False))
    sys.stdout.flush()
    if canary_result["status"] != "ok":
        print(json.dumps({
            "status": "canary-failed",
            "halted": True,
            "remaining": len(batch) - 1,
        }, ensure_ascii=False))
        return 1

    # Real batch (start from index 0 because the canary was dry-run only).
    start_idx = 0 if not args.dry_run else 1  # if user forced --dry-run, don't redo
    for i in range(start_idx, len(batch)):
        if i > 0:
            time.sleep(max(0.0, args.sleep))
        res = process_one(batch[i], bridge_knowledge, shared_root,
                          template_root, team_name, dry_run=args.dry_run)
        print(json.dumps(res, ensure_ascii=False))
        sys.stdout.flush()

    if deferred:
        print(json.dumps({
            "status": "deferred",
            "deferred": [str(p) for p in deferred[:20]],
            "deferred_count": len(deferred),
        }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
