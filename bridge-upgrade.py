#!/usr/bin/env python3
"""Helpers for smart Agent Bridge upgrade flows."""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import uuid
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from stat import S_ISFIFO, S_ISSOCK
import tempfile
from typing import Any, Iterator

MANAGED_CLAUDE_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_CLAUDE_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"

# Issue #517: admin-only pair-programming SOP block. Generalized
# extract/refresh helpers below take delimiter args so the same logic
# rerenders both blocks idempotently.


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def write_bytes(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if mode is not None:
        os.chmod(path, mode)


def tracked_files_modes(source_root: Path) -> dict[str, int]:
    # {relpath: git_mode_in_octal_int} from `git ls-files -s -z`. Using
    # the git index (not the working tree) is required because a dev's
    # checkout can have drifted filesystem permissions (e.g. 0744 / 0700
    # inherited from umask or editor rewrites) even when git tracks the
    # file as 100755. Anything that decides "should this be executable
    # downstream" must consult the index, not `stat`.
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-files", "-z", "-s"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    modes: dict[str, int] = {}
    if proc.returncode != 0:
        return modes
    # Record format: "<mode> <hash> <stage>\t<relpath>\0"
    for record in proc.stdout.split(b"\x00"):
        if not record:
            continue
        try:
            header, relpath_bytes = record.split(b"\t", 1)
        except ValueError:
            continue
        parts = header.split(b" ")
        if not parts:
            continue
        try:
            mode_octal = int(parts[0].decode("ascii"), 8)
            relpath = relpath_bytes.decode("utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        modes[relpath] = mode_octal
    return modes


_tracked_modes_cache: dict[str, dict[str, int]] = {}


def git_tracked_exec_bits(source_root: Path, relpath: str) -> int:
    # 100755 is the only tracked-executable regular-file mode in git.
    # 100644 (regular) and 120000 (symlink) carry no exec bit downstream.
    # Cache per source_root so a single analyze/apply cycle does not
    # fork `git ls-files` per path.
    key = str(source_root)
    modes = _tracked_modes_cache.get(key)
    if modes is None:
        modes = tracked_files_modes(source_root)
        _tracked_modes_cache[key] = modes
    return 0o111 if modes.get(relpath) == 0o100755 else 0


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
        return
    if path.exists():
        shutil.rmtree(path)


def conflict_backup_path(live_path: Path) -> Path:
    return live_path.with_name(f"{live_path.name}.upgrade-conflict")


def git_head(source_root: Path) -> str:
    return (
        subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True).strip()
    )


def git_ref(source_root: Path) -> str:
    for command in (
        ["git", "-C", str(source_root), "describe", "--tags", "--exact-match", "HEAD"],
        ["git", "-C", str(source_root), "rev-parse", "--abbrev-ref", "HEAD"],
    ):
        proc = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    return ""


def read_source_version(source_root: Path) -> str:
    version_path = source_root / "VERSION"
    try:
        version = version_path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (FileNotFoundError, IndexError):
        return "0.0.0-dev"
    return version or "0.0.0-dev"


def read_target_version(target_root: Path) -> str:
    """Read the live install's `VERSION` file, mirror of `read_source_version`.

    Returns "" when the file is missing or empty so callers can distinguish
    "no live VERSION recorded" (fresh / corrupt install) from a real
    semver string. Issue #666: used by `analyze_live` to recover from a
    missing/unreachable `base_ref` on a real cross-version upgrade by
    treating content-drifted files as `upstream_only` instead of
    `unknown_base_live_diff` (which silently keeps live and never copies).
    """
    version_path = target_root / "VERSION"
    try:
        version = version_path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (FileNotFoundError, IndexError, OSError):
        return ""
    return version


def load_json_arg(value: str = "", file_path: str = "") -> dict[str, Any]:
    if file_path:
        return json.loads(Path(file_path).read_text(encoding="utf-8"))
    if value:
        return json.loads(value)
    return {}


def git_file_bytes(source_root: Path, ref: str, relpath: str) -> bytes | None:
    proc = subprocess.run(
        ["git", "-C", str(source_root), "show", f"{ref}:{relpath}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def sha256_bytes(data: bytes | None) -> str:
    if data is None:
        return ""
    return hashlib.sha256(data).hexdigest()


def is_text_bytes(data: bytes | None) -> bool:
    if data is None:
        return True
    if b"\x00" in data:
        return False
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def tracked_files(source_root: Path) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(source_root), "ls-files", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return [item for item in proc.stdout.decode("utf-8").split("\x00") if item]


def should_skip_relpath(relpath: str) -> bool:
    if relpath in {"agent-roster.local.sh"}:
        return True
    for prefix in ("logs/", "shared/", "state/", "backups/", "worktrees/"):
        if relpath.startswith(prefix):
            return True
    if relpath in {"logs", "shared", "state", "backups", "worktrees"}:
        return True
    if relpath.startswith("agents/"):
        allowed_prefixes = (
            "agents/_template/",
            "agents/.claude/",
        )
        allowed_files = {
            "agents/README.md",
            "agents/SYNC-MODEL.md",
            "agents/CUTOVER-WAVES.md",
            "agents/WORKSPACE-MIGRATION-PLAN.md",
        }
        if relpath in allowed_files:
            return False
        if any(relpath.startswith(prefix) for prefix in allowed_prefixes):
            return False
        return True
    return False


def render_template(text: str, agent_id: str, display_name: str, role_text: str, engine: str, session_type: str) -> str:
    runtime = "Claude Code CLI" if engine == "claude" else "Codex CLI"
    replacements = {
        "<Agent Name>": display_name,
        "<agent-id>": agent_id,
        "<Role>": role_text,
        "<Role Summary>": role_text,
        "<Runtime>": runtime,
        "<Boss>": "관리자 에이전트",
        "<한 줄 역할 설명>": role_text,
        "<표시 이름>": display_name,
        "<Session Type>": session_type,
        "<핵심 책임>": role_text,
        "<주 요청자>": "관리자 에이전트",
        "<Claude Code CLI | Codex CLI>": runtime,
        "<반드시 지킬 운영 규칙>": "큐를 source of truth로 삼고, claim/done note를 생략하지 않는다.",
        "<위험 작업 제한>": "크리티컬 변경 전에는 dry-run 또는 관련 상태 확인을 먼저 수행한다.",
        "<보고 방식>": "결과는 요청자 채널 또는 task queue로 반드시 남긴다.",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def extract_managed_block(text: str, start_marker: str, end_marker: str) -> str:
    match = re.search(
        rf"{re.escape(start_marker)}.*?{re.escape(end_marker)}",
        text,
        re.S,
    )
    return match.group(0).strip() if match else ""


def refresh_managed_block(
    original: str, managed_block: str, start_marker: str, end_marker: str
) -> str:
    if not managed_block:
        return original
    block = managed_block.rstrip() + "\n"
    pattern = re.compile(
        rf"{re.escape(start_marker)}.*?{re.escape(end_marker)}\n*",
        re.S,
    )
    if pattern.search(original):
        updated = pattern.sub(block + "\n", original, count=1)
        return updated if updated.endswith("\n") else updated + "\n"

    normalized = original.rstrip()
    if normalized.startswith("# "):
        first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        rest = rest.lstrip()
        updated = f"{first}\n\n{block}\n"
        if rest:
            updated += f"{rest}\n"
        return updated

    if normalized:
        return f"{block}\n{normalized}\n"
    return block


def extract_managed_claude_block(text: str) -> str:
    return extract_managed_block(text, MANAGED_CLAUDE_START, MANAGED_CLAUDE_END)


def refresh_managed_claude_block(original: str, managed_block: str) -> str:
    return refresh_managed_block(original, managed_block, MANAGED_CLAUDE_START, MANAGED_CLAUDE_END)


def discover_agent_dirs(agent_root: Path) -> list[Path]:
    if not agent_root.exists():
        return []
    results: list[Path] = []
    for path in sorted(agent_root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        results.append(path)
    return results


def detect_display_name(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        match = re.search(r"^#\s+(.+?)\s+—\s+.+$", claude_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    soul_path = agent_dir / "SOUL.md"
    if soul_path.exists():
        match = re.search(r"^#\s+(.+?)\s+Soul$", soul_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    return agent_dir.name


def detect_role_text(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        text = claude_path.read_text(encoding="utf-8", errors="ignore")
        match = re.search(r"^#\s+.+?\s+—\s+(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
        match = re.search(r"- \*\*역할\*\*:\s*(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
    return "Bridge-managed agent"


def detect_session_type(agent_dir: Path, admin_agent: str) -> str:
    session_path = agent_dir / "SESSION-TYPE.md"
    if session_path.exists():
        match = re.search(r"Session Type:\s*([A-Za-z0-9._-]+)", session_path.read_text(encoding="utf-8", errors="ignore"))
        if match:
            return match.group(1).strip()
    if agent_dir.name == admin_agent:
        return "admin"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and "Codex CLI" in claude_path.read_text(encoding="utf-8", errors="ignore"):
        return "static-codex"
    return "static-claude"


def detect_engine(agent_dir: Path, session_type: str) -> str:
    if session_type == "static-codex":
        return "codex"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and "Codex CLI" in claude_path.read_text(encoding="utf-8", errors="ignore"):
        return "codex"
    return "claude"


@dataclass
class AgentMigrationResult:
    agent: str
    added_files: list[str]
    created_dirs: list[str]
    updated_files: list[str]
    session_type: str
    engine: str


def migrate_agent_home(agent_dir: Path, template_root: Path, admin_agent: str, dry_run: bool) -> AgentMigrationResult:
    agent = agent_dir.name
    session_type = detect_session_type(agent_dir, admin_agent)
    engine = detect_engine(agent_dir, session_type)
    display_name = detect_display_name(agent_dir)
    role_text = detect_role_text(agent_dir)
    added_files: list[str] = []
    created_dirs: list[str] = []
    updated_files: list[str] = []

    for path in sorted(template_root.rglob("*")):
        rel = path.relative_to(template_root)
        if rel.parts and rel.parts[0] == "session-types":
            continue
        # v0.8.2 (#652): skip the `memory/` subtree. The per-agent memory
        # wiki is the agent's working data, not template content — it is
        # created on first agent launch by the agent's own initializer.
        # For per-UID isolated agents the controller cannot stat into the
        # 0700-mode `memory/` tree at all (PermissionError on
        # `target.exists()`), which would otherwise abort the entire
        # multi-agent migration loop in `cmd_migrate_agents` before any
        # other agent gets touched.
        if rel.parts and rel.parts[0] == "memory":
            continue
        target = agent_dir / rel
        if path.is_dir():
            if not target.exists():
                created_dirs.append(rel.as_posix())
                if not dry_run:
                    target.mkdir(parents=True, exist_ok=True)
            continue
        if rel.as_posix() == "CLAUDE.md" and target.exists():
            continue
        if target.exists():
            continue
        added_files.append(rel.as_posix())
        if dry_run:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        rendered = render_template(path.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type)
        target.write_text(rendered, encoding="utf-8")

    session_template = template_root / "session-types" / f"{session_type}.md"
    session_target = agent_dir / "SESSION-TYPE.md"
    if not session_target.exists() and session_template.exists():
        added_files.append("SESSION-TYPE.md")
        if not dry_run:
            session_target.parent.mkdir(parents=True, exist_ok=True)
            session_target.write_text(
                render_template(session_template.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type),
                encoding="utf-8",
            )

    claude_template = template_root / "CLAUDE.md"
    claude_target = agent_dir / "CLAUDE.md"
    if claude_template.exists() and claude_target.exists():
        rendered = render_template(claude_template.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type)
        managed_block = extract_managed_claude_block(rendered)
        if managed_block:
            original = claude_target.read_text(encoding="utf-8", errors="ignore")
            refreshed = refresh_managed_claude_block(original, managed_block)
            if refreshed != original:
                updated_files.append("CLAUDE.md")
                if not dry_run:
                    claude_target.write_text(refreshed, encoding="utf-8")

    # Issue #4769 (reverts #517): no longer auto-inject the admin
    # pair-programming SOP managed block here. The block described a
    # `<admin>-dev` codex pair that was itself auto-created by the
    # removed admin-pair backfill helper; both halves of the feature
    # retire together. Operators who explicitly register a sibling
    # dev agent can author their own pair-programming SOP in the
    # admin's CLAUDE.md.

    return AgentMigrationResult(
        agent=agent,
        added_files=added_files,
        created_dirs=created_dirs,
        updated_files=updated_files,
        session_type=session_type,
        engine=engine,
    )


def cmd_migrate_agents(args: argparse.Namespace) -> int:
    template_root = Path(args.source_root).expanduser() / "agents" / "_template"
    agent_root = Path(args.target_root).expanduser() / "agents"
    admin_agent = (args.admin_agent or "").strip()
    results: list[AgentMigrationResult] = []
    skipped_isolated: list[dict[str, str]] = []
    for path in discover_agent_dirs(agent_root):
        try:
            results.append(migrate_agent_home(path, template_root, admin_agent, args.dry_run))
        except PermissionError as exc:
            # v0.8.2 (#652): per-UID isolated agent home is not stat-able
            # by the controller. Skip with a structured result instead of
            # aborting the entire multi-agent loop. The agent's own first
            # launch under v0.8.0+ rebuilds whatever it needs in its
            # memory tree; the upgrader's contract for isolated agents is
            # that the controller never enters per-agent owner-only
            # subtrees. The `memory/` template-skip above prevents the
            # common path; this catch is defense-in-depth for any future
            # template addition that re-introduces a 0700 path.
            skipped_isolated.append({
                "agent": path.name,
                "reason": f"PermissionError: {exc.filename or '<unknown path>'} (per-UID isolated tree)",
            })
    payload = {
        "agent_count": len(results) + len(skipped_isolated),
        "migrated_count": len(results),
        "skipped_isolated_count": len(skipped_isolated),
        "skipped_isolated": skipped_isolated,
        "agents_with_additions": sum(1 for item in results if item.added_files or item.created_dirs or item.updated_files),
        "added_files": sum(len(item.added_files) for item in results),
        "created_dirs": sum(len(item.created_dirs) for item in results),
        "updated_files": sum(len(item.updated_files) for item in results),
        "agents": [asdict(item) for item in results],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def conflict_backup_relpath(relpath: str) -> str:
    return (Path(relpath).parent / conflict_backup_path(Path(relpath)).name).as_posix()


def build_backup_entries(
    target_root: Path,
    analysis_payload: dict[str, Any],
    migration_payload: dict[str, Any],
) -> list[dict[str, str]]:
    entries: dict[str, dict[str, str]] = {}

    def remember(relpath: str, expected_kind: str = "file") -> None:
        relpath = relpath.strip().lstrip("./")
        if not relpath:
            return
        live_path = target_root / relpath
        if live_path.exists() or live_path.is_symlink():
            kind = "dir" if live_path.is_dir() and not live_path.is_symlink() else "file"
            entries[relpath] = {"path": relpath, "state": "present", "kind": kind}
            return
        current = entries.get(relpath)
        if current and current.get("state") == "present":
            return
        entries[relpath] = {"path": relpath, "state": "absent", "kind": expected_kind}

    for item in analysis_payload.get("files", []):
        strategy = str(item.get("strategy") or "")
        relpath = str(item.get("path") or "")
        if strategy not in {"deploy_upstream", "manual_merge"}:
            continue
        remember(relpath, "file")
        if str(item.get("classification") or "") == "merge_required":
            remember(conflict_backup_relpath(relpath), "file")

    for agent_payload in migration_payload.get("agents", []):
        agent = str(agent_payload.get("agent") or "").strip()
        if not agent:
            continue
        prefix = f"agents/{agent}"
        for relpath in agent_payload.get("updated_files", []):
            remember(f"{prefix}/{relpath}", "file")
        for relpath in agent_payload.get("added_files", []):
            remember(f"{prefix}/{relpath}", "file")
        for relpath in agent_payload.get("created_dirs", []):
            remember(f"{prefix}/{relpath}", "dir")

    remember("state/upgrade/last-upgrade.json", "file")
    return [entries[key] for key in sorted(entries)]


def copy_live_backup(target_root: Path, backup_root: Path, entries: list[dict[str, str]] | None = None) -> None:
    backup_live = backup_root / "live"
    backup_live.mkdir(parents=True, exist_ok=True)
    if entries:
        for entry in entries:
            if entry.get("state") != "present":
                continue
            relpath = str(entry["path"])
            src = target_root / relpath
            dst = backup_live / relpath
            if not src.exists() and not src.is_symlink():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir() and not src.is_symlink():
                shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
        return
    for child in sorted(target_root.iterdir()):
        if child.name == "backups":
            continue
        dst = backup_live / child.name
        if child.is_dir():
            shutil.copytree(child, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(child, dst, follow_symlinks=False)


# --- daily-backup constants -------------------------------------------------
#
# All daily-backup behavior funnels through `create_daily_backup_archive` and
# `cmd_daily_backup_live` below. The constants here exist so smoke tests and
# operators can grep the surface area in one place.

# Path-prefix excludes (root-anchored under target_root). The tar walk drops
# the entire subtree whenever a path's leading components match any tuple.
DAILY_BACKUP_HARDCODED_ROOT_EXCLUDES: tuple[tuple[str, ...], ...] = (
    ("logs",),
    ("worktrees",),
    ("runtime", "assets"),
    ("runtime", "media"),
    ("runtime", "extensions"),
    (".claude", "worktrees"),
    # state/backup-snapshots/ is excluded from the *walk* so prior days'
    # SQL dumps do not bloat each tarball; today's dump is added back as
    # an explicit member after the walk completes.
    ("state", "backup-snapshots"),
)

# Path-part excludes: drop any path that contains one of these components at
# any depth (mirrors the legacy __pycache__ skip). Cheap defense against
# committing or backing up vendored / generated trees.
DAILY_BACKUP_PATH_PART_EXCLUDES: tuple[str, ...] = ("__pycache__", "node_modules")

# Raw sqlite databases that must never enter the tarball — they're handled
# via online snapshot dumps instead. Keep the list small and explicit; new
# entries should land with a deliberate review of their restore semantics.
DAILY_BACKUP_RAW_SQLITE_EXCLUDES: tuple[str, ...] = (
    "state/tasks.db",
    "state/tasks.db-wal",
    "state/tasks.db-shm",
    "state/tasks.db-journal",
)

# (relpath under target_root, dump filename stem). One entry per database we
# snapshot. Add new ones only after measuring size + verifying restore path.
DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS: tuple[tuple[str, str], ...] = (
    ("state/tasks.db", "tasks"),
)

DAILY_BACKUP_SNAPSHOT_DIR_REL = "state/backup-snapshots"
DAILY_BACKUP_LOCK_FILENAME = ".daily-backup.lock"
DAILY_BACKUP_TMP_GLOB = "*.tgz.tmp.*"
DAILY_BACKUP_FREE_SPACE_FLOOR_BYTES = 100 * 1024 * 1024  # 100 MiB


def daily_backup_archive_name(day: date) -> str:
    return f"agent-bridge-{day.isoformat()}.tgz"


def parse_daily_backup_archive_date(name: str) -> date | None:
    match = re.fullmatch(r"agent-bridge-(\d{4}-\d{2}-\d{2})\.tgz", name)
    if not match:
        return None
    try:
        return date.fromisoformat(match.group(1))
    except ValueError:
        return None


def daily_backup_sqlite_snapshot_filename(stem: str, day: date) -> str:
    return f"{stem}-{day.isoformat()}.sql.gz"


def parse_daily_backup_sqlite_snapshot_date(stem: str, name: str) -> date | None:
    pattern = re.compile(rf"{re.escape(stem)}-(\d{{4}}-\d{{2}}-\d{{2}})\.sql\.gz")
    match = pattern.fullmatch(name)
    if not match:
        return None
    try:
        return date.fromisoformat(match.group(1))
    except ValueError:
        return None


def _parse_extra_excluded_roots(value: str | None) -> list[tuple[str, ...]]:
    # Accepts colon- or comma-separated relpaths from
    # BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS. Each entry is normalized into a
    # tuple of path parts the walk-time skip can match against. Empty or
    # whitespace-only entries are dropped.
    if not value:
        return []
    raw_entries: list[str] = []
    for piece in value.replace(",", ":").split(":"):
        piece = piece.strip().strip("/")
        if not piece:
            continue
        raw_entries.append(piece)
    parsed: list[tuple[str, ...]] = []
    for entry in raw_entries:
        parts = tuple(part for part in Path(entry).parts if part not in ("", "."))
        if parts:
            parsed.append(parts)
    return parsed


def resolve_daily_backup_excluded_roots(
    target_root: Path,
    backup_dir: Path,
    *,
    extra_excludes_env: str | None = None,
) -> list[tuple[str, ...]]:
    excluded: list[tuple[str, ...]] = list(DAILY_BACKUP_HARDCODED_ROOT_EXCLUDES)
    try:
        relative_backup_dir = backup_dir.resolve().relative_to(target_root.resolve())
    except ValueError:
        relative_backup_dir = None
    if relative_backup_dir is not None and relative_backup_dir.parts:
        excluded.append(relative_backup_dir.parts)
    if extra_excludes_env is None:
        extra_excludes_env = os.environ.get("BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS", "")
    excluded.extend(_parse_extra_excluded_roots(extra_excludes_env))
    return excluded


def should_skip_daily_backup_relpath(
    relpath: Path,
    excluded_roots: list[tuple[str, ...]],
    *,
    path_part_excludes: tuple[str, ...] = DAILY_BACKUP_PATH_PART_EXCLUDES,
) -> bool:
    parts = relpath.parts
    if not parts:
        return False
    for skip_part in path_part_excludes:
        if skip_part in parts:
            return True
    relpath_posix = relpath.as_posix()
    for raw_relpath in DAILY_BACKUP_RAW_SQLITE_EXCLUDES:
        if relpath_posix == raw_relpath:
            return True
    for root_parts in excluded_roots:
        if len(parts) >= len(root_parts) and parts[: len(root_parts)] == root_parts:
            return True
    return False


def iter_daily_backup_members(
    target_root: Path,
    backup_dir: Path,
    *,
    extra_excludes_env: str | None = None,
) -> list[tuple[Path, str]]:
    excluded_roots = resolve_daily_backup_excluded_roots(
        target_root, backup_dir, extra_excludes_env=extra_excludes_env
    )
    members: list[tuple[Path, str]] = []

    for root, dirnames, filenames in os.walk(target_root, topdown=True, followlinks=False):
        root_path = Path(root)
        rel_root = root_path.relative_to(target_root)

        kept_dirs: list[str] = []
        for dirname in sorted(dirnames):
            rel_dir = rel_root / dirname if rel_root.parts else Path(dirname)
            if should_skip_daily_backup_relpath(rel_dir, excluded_roots):
                continue
            kept_dirs.append(dirname)
            members.append((root_path / dirname, rel_dir.as_posix()))
        dirnames[:] = kept_dirs

        for filename in sorted(filenames):
            rel_file = rel_root / filename if rel_root.parts else Path(filename)
            if should_skip_daily_backup_relpath(rel_file, excluded_roots):
                continue
            members.append((root_path / filename, rel_file.as_posix()))

    return members


def _resolve_grace_seconds(override: int | None = None) -> int:
    # bug #507: stale-tmp reaper must not unlink an in-flight peer's tmp
    # file, so only files older than (daemon_timeout + grace) are removed.
    # Issue #745: default raised 180 -> 360 to track the daemon-side
    # BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS default bump (120 -> 300) plus
    # the original 60s slack.
    if override is not None:
        return max(0, int(override))
    raw = os.environ.get("BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS", "")
    if raw.isdigit():
        return max(0, int(raw))
    return 360


def reap_stale_daily_backup_tmp(
    backup_dir: Path,
    *,
    grace_seconds: int | None = None,
    now_ts: float | None = None,
) -> list[str]:
    if not backup_dir.exists():
        return []
    grace = _resolve_grace_seconds(grace_seconds)
    now_ts = now_ts if now_ts is not None else _now_seconds()
    reaped: list[str] = []
    for path in backup_dir.glob(DAILY_BACKUP_TMP_GLOB):
        if not path.is_file():
            continue
        try:
            mtime = path.stat().st_mtime
        except FileNotFoundError:
            continue
        if (now_ts - mtime) < grace:
            continue
        try:
            path.unlink()
        except FileNotFoundError:
            continue
        except OSError:
            # Permission / busy file: leave it; cleanup helper will surface
            # it to the operator. Don't escalate from inside the backup
            # write path.
            continue
        reaped.append(str(path))
    return reaped


def _now_seconds() -> float:
    # Indirected so tests can monkeypatch the clock.
    return datetime.now(timezone.utc).timestamp()


def _resolve_free_bytes_override() -> int | None:
    raw = os.environ.get("BRIDGE_DAILY_BACKUP_FREE_BYTES_OVERRIDE", "")
    if raw == "":
        return None
    try:
        return max(0, int(raw))
    except ValueError:
        return None


def _previous_archive_size_bytes(backup_dir: Path) -> int:
    largest = 0
    if not backup_dir.exists():
        return largest
    for path in backup_dir.iterdir():
        if not path.is_file():
            continue
        if parse_daily_backup_archive_date(path.name) is None:
            continue
        try:
            size = path.stat().st_size
        except FileNotFoundError:
            continue
        if size > largest:
            largest = size
    return largest


def check_daily_backup_free_space(
    backup_dir: Path,
    *,
    floor_bytes: int = DAILY_BACKUP_FREE_SPACE_FLOOR_BYTES,
) -> tuple[bool, int, int]:
    """Return (ok, free_bytes, needed_bytes).

    needed = max(prev_largest_archive * 1.5, floor_bytes). On a fresh install
    with no prior archives, the floor governs. The caller is expected to
    short-circuit with `outcome=skipped_disk_full` when ok=False.
    """
    override = _resolve_free_bytes_override()
    if override is not None:
        free_bytes = override
    else:
        backup_dir.mkdir(parents=True, exist_ok=True)
        try:
            free_bytes = shutil.disk_usage(backup_dir).free
        except (FileNotFoundError, PermissionError):
            free_bytes = 0
    prev = _previous_archive_size_bytes(backup_dir)
    needed = max(int(prev * 1.5), floor_bytes)
    return (free_bytes >= needed, int(free_bytes), int(needed))


@contextlib.contextmanager
def acquire_daily_backup_lock(backup_dir: Path) -> Iterator[bool]:
    """Yield True if exclusive lock acquired, False if another writer holds it.

    Uses fcntl.flock on a sentinel file inside backup_dir. Non-blocking — a
    contended attempt yields False and the caller should report
    `outcome=skipped_concurrent` rather than fight the peer.
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    lock_path = backup_dir / DAILY_BACKUP_LOCK_FILENAME
    handle = None
    try:
        handle = open(lock_path, "a+")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                yield False
                return
            raise
        yield True
    finally:
        if handle is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            handle.close()


def _atomic_replace(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)


def _fsync_path(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def dump_sqlite_snapshot(
    target_root: Path,
    today: date,
    *,
    tmp_root: Path | None = None,  # kept for back-compat; ignored intentionally
) -> list[dict[str, Any]]:
    """Hot-snapshot each entry in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS.

    Returns a list of {src_relpath, snapshot_relpath, snapshot_path,
    snapshot_bytes, source_present} dicts. A missing source DB (fresh
    install) is silently skipped — daily backup must still succeed.

    Implementation (PR #508 r2 fixes):

    1. Use `sqlite3.Connection.backup()` into a process-private temp DB
       first, then `iterdump` the temp copy. Raw `iterdump` against the
       live DB issues multiple SELECTs and can interleave with concurrent
       writer commits, producing a mixed dump. `.backup()` is the
       canonical online snapshot API and gives us a transactionally-
       consistent point-in-time copy.

    2. The gzipped `.partial` is staged as a sibling of the final path
       (inside `state/backup-snapshots/`), so `os.replace` is always on
       the same filesystem — no EXDEV when `BRIDGE_DAILY_BACKUP_DIR`
       lives on a different mount than the bridge home. The `tmp_root`
       parameter is kept for caller-side scratch (the temp DB) and the
       partial stays adjacent to the final.
    """
    snapshots: list[dict[str, Any]] = []
    final_dir = target_root / DAILY_BACKUP_SNAPSHOT_DIR_REL
    final_dir.mkdir(parents=True, exist_ok=True)
    # Temp DB lives in caller's tmp_root if given (out of the tar walk),
    # otherwise next to the final dump. Either path works because the
    # temp DB is unlinked before this function returns.
    db_tmp_dir = tmp_root if tmp_root is not None else final_dir
    db_tmp_dir.mkdir(parents=True, exist_ok=True)

    for src_relpath, stem in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS:
        src_path = target_root / src_relpath
        snapshot_name = daily_backup_sqlite_snapshot_filename(stem, today)
        final_path = final_dir / snapshot_name
        snapshot_relpath = f"{DAILY_BACKUP_SNAPSHOT_DIR_REL}/{snapshot_name}"
        entry: dict[str, Any] = {
            "src_relpath": src_relpath,
            "snapshot_relpath": snapshot_relpath,
            "snapshot_path": str(final_path),
            "snapshot_bytes": 0,
            "source_present": src_path.exists(),
        }
        if not src_path.exists():
            # Fresh install: nothing to dump, daily backup proceeds.
            snapshots.append(entry)
            continue

        # Sibling-of-final partial → atomic replace stays on the same fs.
        partial_path = final_dir / f".{snapshot_name}.partial.{uuid.uuid4().hex}"
        # Online-snapshot temp DB lives in db_tmp_dir; out of band.
        tmp_db_path = db_tmp_dir / f".{stem}-snapshot.{uuid.uuid4().hex}.sqlite"
        src_conn: sqlite3.Connection | None = None
        tmp_conn: sqlite3.Connection | None = None
        try:
            # mode=ro so verify-tasks-db / live writers aren't disturbed
            # by any side-effect of opening rw. .backup() works against
            # an ro source.
            src_uri = f"file:{src_path}?mode=ro"
            src_conn = sqlite3.connect(src_uri, uri=True)
            tmp_conn = sqlite3.connect(str(tmp_db_path))
            src_conn.backup(tmp_conn)
            # Now iterdump the consistent temp copy, not the live DB.
            with gzip.open(partial_path, "wt", encoding="utf-8", compresslevel=6) as gz:
                for line in tmp_conn.iterdump():
                    gz.write(line)
                    gz.write("\n")
            _fsync_path(partial_path)
            _atomic_replace(partial_path, final_path)
            _fsync_path(final_path)
            entry["snapshot_bytes"] = final_path.stat().st_size
        except Exception as exc:  # pragma: no cover — surfaced to caller
            entry["error"] = f"{type(exc).__name__}: {exc}"
            with contextlib.suppress(FileNotFoundError):
                partial_path.unlink()
        finally:
            if tmp_conn is not None:
                with contextlib.suppress(Exception):
                    tmp_conn.close()
            if src_conn is not None:
                with contextlib.suppress(Exception):
                    src_conn.close()
            with contextlib.suppress(FileNotFoundError):
                tmp_db_path.unlink()
        snapshots.append(entry)
    return snapshots


def prune_sqlite_snapshots(
    target_root: Path, retain_days: int, today: date
) -> list[str]:
    if retain_days < 1:
        retain_days = 1
    final_dir = target_root / DAILY_BACKUP_SNAPSHOT_DIR_REL
    if not final_dir.exists():
        return []
    cutoff = today - timedelta(days=retain_days - 1)
    pruned: list[str] = []
    stems = {stem for _, stem in DAILY_BACKUP_SQLITE_SNAPSHOT_TARGETS}
    for path in sorted(final_dir.iterdir()):
        if not path.is_file():
            continue
        # Only prune snapshots we recognize. Hand-placed files (e.g. an
        # operator-saved dump) are left alone.
        kept = False
        for stem in stems:
            parsed = parse_daily_backup_sqlite_snapshot_date(stem, path.name)
            if parsed is not None:
                if parsed < cutoff:
                    with contextlib.suppress(FileNotFoundError):
                        path.unlink()
                    pruned.append(str(path))
                kept = True
                break
        if not kept and path.name.endswith(".partial"):
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            pruned.append(str(path))
    return pruned


def create_daily_backup_archive(
    target_root: Path,
    backup_dir: Path,
    today: date,
    *,
    extra_excludes_env: str | None = None,
) -> dict[str, Any]:
    """Build today's daily archive end-to-end.

    Returns a structured result with `outcome` ∈ {created, skipped_disk_full,
    skipped_concurrent, error_<reason>}. Caller is responsible for surfacing
    the result as JSON; this function never raises into its caller for
    expected failure modes (disk full, lock contention, missing source DB).
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    archive_path = backup_dir / daily_backup_archive_name(today)

    result: dict[str, Any] = {
        "outcome": "error_unknown",
        "archive_path": str(archive_path),
        "snapshots": [],
        "free_bytes": 0,
        "needed_bytes": 0,
        "reaped_tmp": [],
    }

    with acquire_daily_backup_lock(backup_dir) as got_lock:
        if not got_lock:
            result["outcome"] = "skipped_concurrent"
            return result

        # bug #507 (1): glob-delete stale tmp files left by killed peers,
        # but only those older than the grace window so we don't trample
        # an active concurrent writer (defense-in-depth — the lock above
        # already enforces single-writer).
        result["reaped_tmp"] = reap_stale_daily_backup_tmp(backup_dir)

        # bug #507 (2): pre-flight free-space check. On a chronically-full
        # disk every retry would otherwise spawn another GB-scale tmp file
        # and fail.
        ok, free_bytes, needed_bytes = check_daily_backup_free_space(backup_dir)
        result["free_bytes"] = free_bytes
        result["needed_bytes"] = needed_bytes
        if not ok:
            result["outcome"] = "skipped_disk_full"
            return result

        # bug #507 (6): hot-snapshot tasks.db (and any future sqlite in
        # SQLITE_SNAPSHOT_TARGETS) into a temp dir outside the tar walk;
        # the resulting .sql.gz is gzip-friendly and ~10–20× smaller than
        # the raw .db. Today's snapshot will be added back to the tar as
        # an explicit member after the walk.
        with tempfile.TemporaryDirectory(
            prefix="agb-snap-", dir=backup_dir.parent
        ) as snap_tmp_str:
            snap_tmp = Path(snap_tmp_str)
            snapshots = dump_sqlite_snapshot(target_root, today, tmp_root=snap_tmp)
        result["snapshots"] = snapshots

        # PR #508 r3 (Codex blocker): if a source DB exists but its
        # snapshot failed (corruption, locked beyond timeout, FS error),
        # the tarball would otherwise ship with neither the raw .db
        # (excluded from the tar walk) nor the .sql.gz dump — a silently
        # empty queue snapshot that the daemon would still mark
        # `created`, clearing failure state and pruning prior good
        # backups. Treat that as a hard failure: surface
        # `error_sqlite_snapshot`, do NOT write a tarball, do NOT prune.
        # Missing source DB (`source_present=False`) stays non-fatal —
        # fresh installs must keep working.
        snapshot_errors = [
            entry for entry in snapshots
            if entry.get("source_present") and entry.get("error")
        ]
        if snapshot_errors:
            first = snapshot_errors[0]
            result["outcome"] = "error_sqlite_snapshot"
            result["error_detail"] = (
                f"{first.get('src_relpath', 'unknown')}: {first.get('error', 'unknown')}"
            )
            result["snapshot_errors"] = [
                {"src_relpath": e.get("src_relpath"), "error": e.get("error")}
                for e in snapshot_errors
            ]
            return result

        tmp_path = backup_dir / f"{archive_path.name}.tmp.{os.getpid()}"
        # Erase any prior tmp owned by this exact PID (rare, but possible
        # on PID reuse after a crash between two attempts in the same
        # second). The grace-gated reaper above won't catch a fresh tmp.
        with contextlib.suppress(FileNotFoundError):
            tmp_path.unlink()

        # Issue #785: under v0.9.7 unified isolation, files inside
        # `agents/<X>/` are owned by `agent-bridge-<X>:ab-agent-<X>` with
        # `0640/0700`. The controller (`ec2-user`) can `readdir` the parent
        # (2750 SetGID) but cannot `open` the inner files. Without a
        # per-member catch the first EACCES aborts the whole archive after
        # writing 0 bytes. Mirrors the `agent_migration` PermissionError
        # pattern (above) — accumulate skip records, surface in JSON.
        skipped_isolated: list[dict[str, str]] = []
        try:
            with tarfile.open(
                tmp_path, "w:gz", format=tarfile.PAX_FORMAT, dereference=False
            ) as archive:
                for src_path, arcname in iter_daily_backup_members(
                    target_root, backup_dir, extra_excludes_env=extra_excludes_env
                ):
                    try:
                        stat_result = os.lstat(src_path)
                    except FileNotFoundError:
                        continue
                    except PermissionError:
                        skipped_isolated.append({"path": str(src_path), "stage": "lstat"})
                        continue
                    if S_ISSOCK(stat_result.st_mode) or S_ISFIFO(stat_result.st_mode):
                        continue
                    try:
                        archive.add(src_path, arcname=arcname, recursive=False)
                    except PermissionError:
                        skipped_isolated.append({"path": str(src_path), "stage": "add"})
                        continue
                    except OSError as exc:
                        # CPython usually raises PermissionError, but
                        # tarfile.add may surface raw OSError(EACCES) for
                        # certain paths; treat both as the same isolation
                        # boundary.
                        if exc.errno == errno.EACCES:
                            skipped_isolated.append({"path": str(src_path), "stage": "add"})
                            continue
                        raise

                # Explicitly add today's snapshot dumps. The walk excluded
                # state/backup-snapshots/ so prior days' dumps don't bloat
                # this archive. Snapshots are written by the controller so
                # EACCES is unlikely, but defend symmetrically with the main
                # loop in case a future snapshot path becomes isolated.
                for entry in snapshots:
                    snap_path = Path(entry["snapshot_path"])
                    if not snap_path.exists():
                        continue
                    try:
                        archive.add(
                            snap_path,
                            arcname=entry["snapshot_relpath"],
                            recursive=False,
                        )
                    except PermissionError:
                        skipped_isolated.append({"path": str(snap_path), "stage": "add_snapshot"})
                        continue
                    except OSError as exc:
                        if exc.errno == errno.EACCES:
                            skipped_isolated.append({"path": str(snap_path), "stage": "add_snapshot"})
                            continue
                        raise
        except OSError as exc:
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            if exc.errno == errno.ENOSPC:
                result["outcome"] = "skipped_disk_full"
                # disk_usage may have raced; report what we know.
                with contextlib.suppress(Exception):
                    result["free_bytes"] = shutil.disk_usage(backup_dir).free
            else:
                result["outcome"] = f"error_oserror_{exc.errno or 'unknown'}"
            return result
        except Exception as exc:  # pragma: no cover — bubble for diagnostics
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            result["outcome"] = f"error_{type(exc).__name__.lower()}"
            result["error_detail"] = str(exc)
            return result

        try:
            _fsync_path(tmp_path)
            _atomic_replace(tmp_path, archive_path)
            _fsync_path(archive_path)
        except OSError as exc:
            with contextlib.suppress(FileNotFoundError):
                tmp_path.unlink()
            result["outcome"] = f"error_oserror_{exc.errno or 'unknown'}"
            return result

        result["outcome"] = "created"
        try:
            result["archive_bytes"] = archive_path.stat().st_size
        except FileNotFoundError:
            result["archive_bytes"] = 0
        if skipped_isolated:
            # Bound the path list so operator JSON stays grep-able even when
            # an isolated agent home has thousands of files (e.g. venv).
            result["skipped_isolated_count"] = len(skipped_isolated)
            if len(skipped_isolated) <= 60:
                result["skipped_isolated"] = skipped_isolated
            else:
                result["skipped_isolated"] = (
                    skipped_isolated[:50]
                    + [{"path": "...", "stage": "truncated"}]
                    + skipped_isolated[-10:]
                )
        return result


def prune_daily_backup_archives(backup_dir: Path, retain_days: int, today: date) -> list[str]:
    if retain_days < 1:
        retain_days = 1
    if not backup_dir.exists():
        return []

    cutoff = today - timedelta(days=retain_days - 1)
    pruned: list[str] = []
    for path in sorted(backup_dir.iterdir()):
        if not path.is_file():
            continue
        parsed = parse_daily_backup_archive_date(path.name)
        if parsed is not None and parsed < cutoff:
            path.unlink(missing_ok=True)
            pruned.append(str(path))
    # Bug #507: tmp cleanup belongs to reap_stale_daily_backup_tmp(), which
    # is age-gated to avoid stealing a concurrent writer's in-flight file.
    # The legacy unconditional `.tmp.*` unlink that lived here was the
    # exact behavior that made reap's grace gate useless.
    return pruned


def remove_existing_target_children(target_root: Path) -> int:
    removed = 0
    for child in sorted(target_root.iterdir()):
        if child.name == "backups":
            continue
        removed += 1
        if child.is_symlink() or child.is_file():
            child.unlink(missing_ok=True)
        else:
            shutil.rmtree(child)
    return removed


def restore_live_backup(target_root: Path, backup_root: Path) -> int:
    backup_live = backup_root / "live"
    if not backup_live.exists():
        raise FileNotFoundError(f"backup snapshot missing: {backup_live}")
    manifest = load_json(backup_root / "manifest.json", {})
    entries = manifest.get("entries") or []
    if entries:
        removed = 0
        for entry in entries:
            if entry.get("state") != "present":
                continue
            relpath = str(entry["path"])
            src = backup_live / relpath
            dst = target_root / relpath
            if not src.exists() and not src.is_symlink():
                continue
            remove_path(dst)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir() and not src.is_symlink():
                shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
        for entry in sorted(
            (item for item in entries if item.get("state") == "absent"),
            key=lambda item: str(item.get("path") or "").count("/"),
            reverse=True,
        ):
            dst = target_root / str(entry["path"])
            if dst.exists() or dst.is_symlink():
                remove_path(dst)
                removed += 1
        return removed
    removed = remove_existing_target_children(target_root)
    for child in sorted(backup_live.iterdir()):
        dst = target_root / child.name
        if child.is_dir():
            shutil.copytree(child, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(child, dst, follow_symlinks=False)
    return removed


def upgrade_state_path(target_root: Path) -> Path:
    return target_root / "state" / "upgrade" / "last-upgrade.json"


def load_upgrade_state(target_root: Path) -> dict[str, Any]:
    return load_json(upgrade_state_path(target_root), {})


def latest_backup_root(target_root: Path) -> Path | None:
    backups_dir = target_root / "backups"
    if not backups_dir.exists():
        return None
    candidates = [path for path in backups_dir.iterdir() if path.is_dir() and path.name.startswith("upgrade-")]
    if not candidates:
        return None
    return sorted(candidates)[-1]


def latest_backup_manifest(target_root: Path) -> dict[str, Any]:
    root = latest_backup_root(target_root)
    if root is None:
        return {}
    return load_json(root / "manifest.json", {})


def resolve_base_ref(target_root: Path, explicit_ref: str) -> str:
    if explicit_ref:
        return explicit_ref
    state = load_upgrade_state(target_root)
    base_ref = str(state.get("source_head") or "").strip()
    if base_ref:
        return base_ref
    manifest = latest_backup_manifest(target_root)
    return str(manifest.get("source_head") or "").strip()


def analyze_live(source_root: Path, target_root: Path, base_ref: str) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    counts = {
        "missing_live": 0,
        "unchanged": 0,
        "upstream_only": 0,
        "live_only": 0,
        "merge_required": 0,
        "unknown_base_live_diff": 0,
        "mode_drift": 0,
    }

    # Issue #666: when the source release ref differs from the live VERSION
    # (a real cross-version upgrade) but `base_ref` could not be resolved
    # / its commit is unreachable in this source clone, the previous
    # classifier sent every content-drifted file to `unknown_base_live_diff`
    # → `keep_live` and copied 0 files. Result: rc=0 + installed metadata
    # bumped + live runtime stayed on the prior version (silent failed
    # upgrade). Compute the version-mismatch flag once up-front so per-file
    # classification can fall back to `upstream_only` (deploy_upstream)
    # when there is no usable `base` *and* we know upstream is a different
    # release — preserving the "rerun same version → keep operator edits"
    # contract by gating on the version mismatch, not just on `base is None`.
    source_version = read_source_version(source_root)
    target_version = read_target_version(target_root)
    # `read_source_version` falls back to the dev sentinel "0.0.0-dev" when
    # the source checkout has no `VERSION` file (a dev clone, not a real
    # release). Treating that as a real version would flip every
    # content-drifted file to `upstream_only` on a same-version rerun from
    # a dev clone, force-deploying over operator edits. Treat the sentinel
    # as "unknown" for `versions_differ` only; do NOT change the function's
    # return value because other callers (payload["version"], the
    # `--version` default in cmd_perform_replace) still need a non-empty
    # string.
    versions_differ = (
        bool(source_version)
        and bool(target_version)
        and source_version != target_version
        and source_version != "0.0.0-dev"
    )

    for relpath in tracked_files(source_root):
        if should_skip_relpath(relpath):
            continue
        source_path = source_root / relpath
        live_path = target_root / relpath
        upstream = source_path.read_bytes()
        live = live_path.read_bytes() if live_path.exists() else None
        base = git_file_bytes(source_root, base_ref, relpath) if base_ref else None

        if live is None:
            classification = "missing_live"
            strategy = "deploy_upstream"
        elif upstream == live:
            # Content matches. Check whether the exec bit also matches
            # source — a mode-only drift (live 0644 vs upstream 0755 or
            # vice versa) is still a drift worth repairing, even though
            # the bytes agree. Without this the previous content-only
            # classifier skipped the file entirely, leaving the live
            # install with the wrong permission. Source-of-truth is the
            # git index, not source_path.stat() — a dev checkout may
            # have drifted filesystem perms (0744 / 0700) while git
            # still tracks 100755, and using stat would propagate the
            # bad worktree mode to every downstream install.
            source_exec = git_tracked_exec_bits(source_root, relpath)
            live_exec = 0
            if not live_path.is_symlink():
                try:
                    live_exec = live_path.stat().st_mode & 0o111
                except OSError:
                    live_exec = 0
            if source_exec != live_exec:
                classification = "mode_drift"
                strategy = "sync_mode"
            else:
                classification = "unchanged"
                strategy = "noop"
        elif not base_ref or base is None:
            # Issue #666: no usable base for this file. If the source
            # release ref is a different version from the live install,
            # treat as a forward-rolling upgrade and deploy upstream
            # (release-shipped files like VERSION, bridge-upgrade.py,
            # lib/bridge-isolation-v2*.sh must actually land). On a
            # same-version rerun (e.g. re-applying v0.8.3 over v0.8.3
            # without recorded base_ref), keep_live still wins —
            # operator-edited content is preserved.
            if versions_differ:
                classification = "upstream_only"
                strategy = "deploy_upstream"
            else:
                classification = "unknown_base_live_diff"
                strategy = "keep_live"
        elif base == live:
            classification = "upstream_only"
            strategy = "deploy_upstream"
        elif base == upstream:
            classification = "live_only"
            strategy = "keep_live"
        else:
            classification = "merge_required"
            strategy = "manual_merge"

        counts[classification] += 1
        if classification == "unchanged":
            continue
        files.append(
            {
                "path": relpath,
                "classification": classification,
                "strategy": strategy,
                "base_ref": base_ref,
                "base_exists": base is not None,
                "live_exists": live is not None,
                "text": is_text_bytes(upstream) and is_text_bytes(live) and (base is None or is_text_bytes(base)),
                "hashes": {
                    "upstream": sha256_bytes(upstream),
                    "live": sha256_bytes(live),
                    "base": sha256_bytes(base),
                },
            }
        )

    return {
        "mode": "upgrade-analyze",
        "source_root": str(source_root),
        "target_root": str(target_root),
        "base_ref": base_ref,
        "counts": counts,
        "files": files,
    }


def merge_text_versions(base: bytes, live: bytes, upstream: bytes) -> tuple[str, bytes]:
    with tempfile.TemporaryDirectory(prefix="bridge-upgrade-merge-") as tmpdir:
        tmp_root = Path(tmpdir)
        live_path = tmp_root / "live"
        base_path = tmp_root / "base"
        upstream_path = tmp_root / "upstream"
        live_path.write_bytes(live)
        base_path.write_bytes(base)
        upstream_path.write_bytes(upstream)
        proc = subprocess.run(
            ["git", "merge-file", "-p", "--diff3", str(live_path), str(base_path), str(upstream_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode == 0:
            return ("clean", proc.stdout)
        if proc.returncode > 0 and proc.stdout:
            return ("conflict", proc.stdout)
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip() or "git merge-file failed")


def apply_live(
    source_root: Path,
    target_root: Path,
    base_ref: str,
    dry_run: bool,
    strict_merge: bool,
    run_id: str = "",
) -> dict[str, Any]:
    analysis = analyze_live(source_root, target_root, base_ref)
    actions: list[dict[str, Any]] = []
    counts = {
        "files_copied": 0,
        "files_merged_clean": 0,
        "files_merged_conflict": 0,
        "files_preserved_live": 0,
        "files_skipped_noop": analysis["counts"].get("unchanged", 0),
        "files_mode_synced": 0,
    }
    conflicts: list[str] = []
    conflict_backups: list[str] = []
    # Issue #394: capture per-conflict metadata at write-time so the
    # next upgrade can auto-archive entries whose live target hash has
    # not changed since (operator already adopted/rejected, or hadn't
    # touched). `live_sha256_at_write` is `live`'s sha256 immediately
    # before the conflict file lands; "" when the live file did not
    # exist (treated as "any subsequent presence != at-write").
    conflict_records: list[dict[str, Any]] = []

    for item in analysis["files"]:
        relpath = str(item["path"])
        classification = str(item["classification"])
        live_path = target_root / relpath
        upstream = (source_root / relpath).read_bytes()
        live = live_path.read_bytes() if live_path.exists() else None
        base = git_file_bytes(source_root, base_ref, relpath) if base_ref else None

        if classification == "mode_drift":
            counts["files_mode_synced"] += 1
            actions.append({"path": relpath, "action": "sync_mode"})
            continue

        if classification in {"missing_live", "upstream_only"}:
            counts["files_copied"] += 1
            actions.append(
                {
                    "path": relpath,
                    "action": "deploy_upstream",
                    "bytes": upstream,
                }
            )
            continue

        if classification in {"live_only", "unknown_base_live_diff"}:
            counts["files_preserved_live"] += 1
            actions.append({"path": relpath, "action": "keep_live"})
            continue

        if classification != "merge_required":
            actions.append({"path": relpath, "action": "noop"})
            continue

        if item.get("text") and base is not None and live is not None:
            merge_kind, merged = merge_text_versions(base, live, upstream)
            if merge_kind == "clean":
                counts["files_merged_clean"] += 1
                actions.append(
                    {
                        "path": relpath,
                        "action": "merge_clean",
                        "bytes": merged,
                    }
                )
                continue
            counts["files_merged_conflict"] += 1
            conflicts.append(relpath)
            backup_path = conflict_backup_path(live_path)
            conflict_backups.append(str(backup_path))
            conflict_records.append(
                {
                    "path": str(backup_path),
                    "live_target": str(live_path),
                    "live_target_relpath": relpath,
                    "live_sha256_at_write": sha256_bytes(live),
                }
            )
            actions.append(
                {
                    "path": relpath,
                    "action": "merge_conflict",
                    "bytes": upstream,
                    "conflict_bytes": merged,
                    "conflict_backup_path": str(backup_path),
                }
            )
            continue

        counts["files_merged_conflict"] += 1
        conflicts.append(relpath)
        backup_path = conflict_backup_path(live_path)
        conflict_backups.append(str(backup_path))
        conflict_records.append(
            {
                "path": str(backup_path),
                "live_target": str(live_path),
                "live_target_relpath": relpath,
                "live_sha256_at_write": sha256_bytes(live),
            }
        )
        actions.append(
            {
                "path": relpath,
                "action": "merge_conflict",
                "bytes": upstream,
                "conflict_bytes": live if live is not None else upstream,
                "conflict_backup_path": str(backup_path),
            }
        )

    payload = {
        "mode": "upgrade-apply",
        "source_root": str(source_root),
        "target_root": str(target_root),
        "base_ref": base_ref,
        "dry_run": dry_run,
        "strict_merge": strict_merge,
        "analysis": analysis,
        "counts": counts,
        "conflicts": conflicts,
        "conflict_backups": conflict_backups,
        "actions": [
            {
                "path": action["path"],
                "action": action["action"],
                **(
                    {"conflict_backup_path": action["conflict_backup_path"]}
                    if "conflict_backup_path" in action
                    else {}
                ),
            }
            for action in actions
        ],
        "applied": False,
        "aborted": False,
    }

    if conflicts and strict_merge:
        payload["aborted"] = True
        return payload

    if dry_run:
        return payload

    for action in actions:
        kind = action["action"]
        if kind in {"noop", "keep_live"}:
            continue
        live_path = target_root / action["path"]
        # Authoritatively mirror the git-tracked exec bit. `0o644 | 0`
        # for non-executable tracked files also propagates exec-bit
        # *removals* (100755 → 100644 upstream), which the earlier
        # "only chmod when exec_bits" variant silently ignored.
        target_mode = 0o644 | git_tracked_exec_bits(source_root, action["path"])
        if kind == "sync_mode":
            try:
                os.chmod(live_path, target_mode)
            except FileNotFoundError:
                # Live file was removed between analyze and apply.
                # Treat as a no-op — the next upgrade pass will redeploy.
                pass
            continue
        if kind == "merge_conflict":
            write_bytes(Path(action["conflict_backup_path"]), action["conflict_bytes"])
        write_bytes(live_path, action["bytes"], target_mode)

    payload["applied"] = True

    # Issue #394: emit the structured conflict record for this run so
    # `agb upgrade conflicts list` and the next-run reconcile can find
    # it. Stat each conflict file *after* it has been written so size
    # and mtime are accurate; the at-write live-target hash captured
    # above is the reconcile anchor.
    if conflict_records and not dry_run:
        record_run_id = run_id or _generate_run_id()
        record_dir = target_root / "state" / "upgrade-conflicts"
        record_dir.mkdir(parents=True, exist_ok=True)
        rendered = []
        for entry in conflict_records:
            cp = Path(entry["path"])
            try:
                st = cp.stat()
                size = st.st_size
                mtime_iso = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(
                    timespec="seconds"
                )
            except OSError:
                size = 0
                mtime_iso = ""
            rendered.append(
                {
                    "path": entry["path"],
                    "live_target": entry["live_target"],
                    "live_target_relpath": entry["live_target_relpath"],
                    "size": size,
                    "mtime": mtime_iso,
                    "live_target_sha256_at_write": entry["live_sha256_at_write"],
                }
            )
        save_json(
            record_dir / f"{record_run_id}.json",
            {
                "run_id": record_run_id,
                "timestamp": now_iso(),
                "target_root": str(target_root),
                "conflict_files": rendered,
            },
        )
        payload["run_id"] = record_run_id
        payload["conflict_record_path"] = str(record_dir / f"{record_run_id}.json")

    return payload


def _generate_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]


def file_sha256(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except OSError:
        return ""


def list_conflict_records(target_root: Path) -> list[Path]:
    record_dir = target_root / "state" / "upgrade-conflicts"
    if not record_dir.is_dir():
        return []
    return sorted(p for p in record_dir.glob("*.json") if p.is_file() and not p.name.startswith("auto-archive-"))


def list_conflict_files(target_root: Path) -> list[Path]:
    if not target_root.is_dir():
        return []
    out: list[Path] = []
    for path in target_root.rglob("*.upgrade-conflict"):
        if not path.is_file():
            continue
        rel = path.relative_to(target_root).as_posix()
        if rel.startswith("backups/"):
            continue
        out.append(path)
    return sorted(out, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)


def lookup_conflict_record(target_root: Path, conflict_path: Path) -> dict[str, Any] | None:
    """Return the most recent upgrade-conflicts/<run-id>.json entry that
    references `conflict_path` (matched by absolute path), or None.

    The "most recent" rule is needed because the same live file can
    accumulate multiple conflict-write events across upgrades; we want
    the one whose `live_target_sha256_at_write` matches the *current*
    pre-reconcile state, not an older fragment.
    """
    target = str(conflict_path)
    matches: list[tuple[float, dict[str, Any], dict[str, Any]]] = []
    for record_path in list_conflict_records(target_root):
        try:
            payload = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for entry in payload.get("conflict_files") or []:
            if entry.get("path") == target:
                ts = record_path.stat().st_mtime if record_path.exists() else 0.0
                matches.append((ts, payload, entry))
                break
    if not matches:
        return None
    matches.sort(key=lambda item: item[0], reverse=True)
    _, _payload, entry = matches[0]
    return entry


def archive_conflict_file(target_root: Path, conflict_path: Path) -> Path:
    """Move `conflict_path` under `<target_root>/backups/upgrade-conflict-archive/<YYYY-MM-DD>/<original-relpath>`
    and return the destination path. Caller is responsible for adding
    an audit row.
    """
    rel = conflict_path.relative_to(target_root) if conflict_path.is_absolute() else conflict_path
    archive_root = target_root / "backups" / "upgrade-conflict-archive" / date.today().isoformat()
    dest = archive_root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        # Tie-break by appending a millisecond timestamp; archives must be
        # additive, never destroy a prior archive on a same-day rerun.
        suffix = datetime.now(timezone.utc).strftime("%H%M%S%f")
        dest = dest.with_name(f"{dest.name}.{suffix}")
    shutil.move(str(conflict_path), str(dest))
    return dest


def write_conflict_audit(target_root: Path, action: str, detail: dict[str, Any]) -> None:
    """Append one JSONL row to `<target_root>/logs/upgrade-conflicts.log`
    so list/diff/adopt/discard/archive/reconcile leave an inspectable
    trail. Best-effort; failures are silent (do not break the action).
    """
    log_path = target_root / "logs" / "upgrade-conflicts.log"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "ts": now_iso(),
            "action": action,
            "detail": detail,
        }
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def cmd_analyze_live(args: argparse.Namespace) -> int:
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    payload = analyze_live(source_root, target_root, resolve_base_ref(target_root, args.base_ref or ""))
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_backup_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_root = Path(args.backup_root).expanduser()
    source_root = Path(args.source_root).expanduser() if args.source_root else None
    analysis_payload = load_json_arg(args.analysis_json, args.analysis_json_file)
    migration_payload = load_json_arg(args.migration_json, args.migration_json_file)
    entries = build_backup_entries(target_root, analysis_payload, migration_payload) if (analysis_payload or migration_payload) else []
    payload = {
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "exists": target_root.exists(),
        "created": False,
        "manifest_path": str(backup_root / "manifest.json"),
        "snapshot_mode": "targeted" if entries else "full",
        "entry_count": len(entries),
    }
    if source_root is not None:
        payload["source_head"] = git_head(source_root)
        payload["source_ref"] = git_ref(source_root)
        payload["version"] = read_source_version(source_root)
    if target_root.exists() and not args.dry_run:
        copy_live_backup(target_root, backup_root, entries or None)
        manifest = {
            "created_at": now_iso(),
            "target_root": str(target_root),
            "source_root": str(source_root) if source_root is not None else "",
            "source_head": payload.get("source_head", ""),
            "source_ref": payload.get("source_ref", ""),
            "version": payload.get("version", ""),
            "snapshot_mode": payload["snapshot_mode"],
            "entries": entries,
        }
        save_json(backup_root / "manifest.json", manifest)
        payload["created"] = True
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_backup_extend_live(args: argparse.Namespace) -> int:
    """Record additional files in an existing backup snapshot.

    Rationale: the primary `backup-live` snapshot is built from the tracked-file
    analysis and the migrate-agents preview. Later upgrade stages such as
    `bridge-docs.py apply --all` mutate files outside that targeted set (per-agent
    `MEMORY-SCHEMA.md`, `SKILLS.md`, `CLAUDE.md`, managed-doc symlinks, etc.) and
    their prior contents are not captured, so `rollback-live` cannot restore
    those files. This subcommand takes the changed-paths JSON produced by
    `bridge-docs.py apply --dry-run --json`, copies each still-present target
    path into `backup_root/live/`, and appends a manifest entry so the rollback
    path treats them identically to the primary backup set.
    """
    target_root = Path(args.target_root).expanduser().resolve()
    # Issue #150: keep a parallel unresolved form of target_root for the
    # fallback relative-path check. On macOS `/tmp` resolves to `/private/tmp`,
    # and operator-supplied paths typically use the unresolved form — a
    # resolve-vs-literal string mismatch would otherwise turn the fallback
    # into a no-op and leave parent-symlink-outside children dropped.
    target_root_literal = Path(args.target_root).expanduser().absolute()
    backup_root = Path(args.backup_root).expanduser()
    payload = {
        "mode": "backup-extend-live",
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "dry_run": bool(args.dry_run),
        "added_entries": 0,
        "skipped_existing": 0,
        "skipped_missing": 0,
        "skipped_outside_target": 0,
    }

    raw = (args.paths_json or "").strip()
    if not raw:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    try:
        doc_payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"--paths-json is not valid JSON: {exc}") from exc
    changed_paths = doc_payload.get("changed_paths") or []
    if not isinstance(changed_paths, list):
        raise SystemExit("--paths-json must contain a list under `changed_paths`")

    manifest_path = backup_root / "manifest.json"
    manifest = load_json(manifest_path, {})
    existing_entries = list(manifest.get("entries") or [])
    existing_relpaths = {str(entry.get("path") or "") for entry in existing_entries}

    added_entries: list[dict[str, str]] = []
    backup_live = backup_root / "live"

    for raw_path in changed_paths:
        if not isinstance(raw_path, str) or not raw_path:
            continue
        clean = raw_path
        if clean.startswith("removed:"):
            clean = clean[len("removed:"):]
        # Canonicalize the ancestor dirs but preserve the final component
        # unchanged. If we used `Path.resolve()` on the whole path, a symlink
        # at the tail (e.g. `agents/demo/TOOLS.md -> ../shared/TOOLS.md`)
        # would be followed and the manifest entry would record the target
        # instead of the link path — breaking rollback for exactly the
        # symlink paths bridge-docs.py rewrites. Resolve the parent only.
        raw = Path(clean).expanduser()
        if not raw.is_absolute():
            raw = Path.cwd() / raw
        try:
            parent_resolved = raw.parent.resolve()
        except OSError:
            payload["skipped_missing"] += 1
            continue
        abs_path = parent_resolved / raw.name
        try:
            relpath = abs_path.relative_to(target_root).as_posix()
        except ValueError:
            # Issue #150: the parent `.resolve()` above follows intermediate
            # symlinks. If an operator has retargeted a directory symlink
            # inside `target_root` to an absolute path outside (e.g.
            # `agents/shared -> /opt/external-shared`), the resolved parent
            # lands outside `target_root` and the entry was silently
            # dropped from the manifest — so rollback later cannot restore
            # the child file. Retry using the unresolved path against the
            # unresolved target root: the operator-supplied path is
            # guaranteed to be under `target_root` at the literal level
            # (otherwise it would not have been emitted by bridge-docs.py
            # for this install). Only truly-outside paths — e.g. an
            # absolute path that does not syntactically start with
            # `target_root` under either resolution — fall through to the
            # outside-target bucket now.
            try:
                relpath = raw.relative_to(target_root_literal).as_posix()
            except ValueError:
                payload["skipped_outside_target"] += 1
                continue
        if relpath in existing_relpaths:
            payload["skipped_existing"] += 1
            continue
        existing_relpaths.add(relpath)
        live_path = target_root / relpath
        if live_path.exists() or live_path.is_symlink():
            kind = "dir" if live_path.is_dir() and not live_path.is_symlink() else "file"
            entry = {"path": relpath, "state": "present", "kind": kind}
        else:
            entry = {"path": relpath, "state": "absent", "kind": "file"}
            payload["skipped_missing"] += 1
        added_entries.append(entry)
        if args.dry_run:
            continue
        if entry["state"] != "present":
            continue
        dst = backup_live / relpath
        dst.parent.mkdir(parents=True, exist_ok=True)
        if live_path.is_symlink():
            link_target = os.readlink(live_path)
            if dst.exists() or dst.is_symlink():
                dst.unlink()
            os.symlink(link_target, dst)
        elif live_path.is_dir():
            shutil.copytree(live_path, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(live_path, dst, follow_symlinks=False)

    payload["added_entries"] = len(added_entries)

    if added_entries and not args.dry_run:
        merged = existing_entries + added_entries
        merged.sort(key=lambda item: str(item.get("path") or ""))
        manifest["entries"] = merged
        # If the snapshot was previously "full" (no entries), a targeted extend
        # still leaves the full tree intact; leave snapshot_mode alone.
        save_json(manifest_path, manifest)

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_daily_backup_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_dir = Path(args.backup_dir).expanduser()
    retain_days = max(1, int(args.retain_days))
    today = date.today()
    payload: dict[str, Any] = {
        "mode": "daily-backup-live",
        "target_root": str(target_root),
        "backup_dir": str(backup_dir),
        "archive_path": str(backup_dir / daily_backup_archive_name(today)),
        "retain_days": retain_days,
        "exists": target_root.exists(),
        "created": False,
        "pruned": [],
        "snapshots_pruned": [],
        "outcome": "skipped_no_target_root",
    }
    if not target_root.exists():
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    if args.dry_run:
        payload["outcome"] = "dry_run"
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    result = create_daily_backup_archive(target_root, backup_dir, today)
    payload["outcome"] = result["outcome"]
    payload["archive_path"] = result.get("archive_path", payload["archive_path"])
    payload["snapshots"] = result.get("snapshots", [])
    payload["free_bytes"] = result.get("free_bytes", 0)
    payload["needed_bytes"] = result.get("needed_bytes", 0)
    payload["reaped_tmp"] = result.get("reaped_tmp", [])
    if "archive_bytes" in result:
        payload["archive_bytes"] = result["archive_bytes"]
    if "error_detail" in result:
        payload["error_detail"] = result["error_detail"]
    # Issue #785: surface per-member EACCES skips so operators can see what
    # was excluded from the archive instead of treating a partial-but-created
    # outcome as a silent success.
    if "skipped_isolated_count" in result:
        payload["skipped_isolated_count"] = result["skipped_isolated_count"]
    if "skipped_isolated" in result:
        payload["skipped_isolated"] = result["skipped_isolated"]

    if result["outcome"] == "created":
        payload["created"] = True
        payload["pruned"] = prune_daily_backup_archives(backup_dir, retain_days, today)
        payload["snapshots_pruned"] = prune_sqlite_snapshots(target_root, retain_days, today)

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_verify_tasks_db(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    db_path = target_root / "state/tasks.db"
    payload: dict[str, Any] = {
        "mode": "verify-tasks-db",
        "target": str(db_path),
        "exists": db_path.exists(),
        "ok": False,
    }
    if not db_path.exists():
        payload["error"] = "missing"
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        # Fresh installs don't have tasks.db until the first task is filed.
        # Treat missing as non-fatal (exit 0); operator/agent reads `ok=false`
        # + `error=missing` from the JSON and decides what to do.
        return 0
    try:
        # mode=ro avoids any journal-mode side-effects on the live DB; the
        # Bridge guard policy that flags raw `sqlite3 state/tasks.db` from
        # agents does not apply to this packaged read-only helper.
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            row = conn.execute("PRAGMA quick_check").fetchone()
            check = row[0] if row else ""
            payload["quick_check"] = check
            payload["ok"] = check == "ok"
        finally:
            conn.close()
    except sqlite3.DatabaseError as exc:
        payload["error"] = f"sqlite_error: {exc}"
    except Exception as exc:  # pragma: no cover
        payload["error"] = f"{type(exc).__name__}: {exc}"
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if payload["ok"] else 1


# --- backup residue cleanup -------------------------------------------------
#
# Used by `agb upgrade --apply` (via lib/bridge-cleanup.sh) and exposed as a
# standalone subcommand so operators can run it manually:
#
#   python3 bridge-upgrade.py cleanup-residue --target-root ~/.agent-bridge \
#     --backup-dir ~/.agent-bridge/backups/daily \
#     --upgrade-backups-dir ~/.agent-bridge/backups
#
# Always returns exit 0 with a structured JSON payload. `cleanup_failures`
# is non-empty when any individual step failed; the caller (upgrade flow)
# surfaces that to the operator instead of aborting the upgrade.

def _format_bytes(n: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(max(0, int(n)))
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{n} B"


def _free_bytes(path: Path) -> int:
    try:
        return shutil.disk_usage(path).free
    except (FileNotFoundError, PermissionError):
        return 0


def prune_upgrade_backups(
    upgrade_backups_dir: Path,
    *,
    current_backup_root: Path | None,
    retain_count: int,
    retain_days: int,
    today: date | None = None,
    no_backup_mode: bool = False,
) -> dict[str, Any]:
    """Conservative pruner for `backups/upgrade-*/` directories.

    Both gates apply:
      - keep at least `retain_count` newest entries (by mtime)
      - of the rest, only delete those older than `retain_days`
      - the current upgrade's BACKUP_ROOT (if any) is always preserved
      - in --no-backup mode, do nothing (no signal that operator is OK
        with destruction of older backup snapshots)
    """
    summary: dict[str, Any] = {
        "scanned": 0,
        "preserved": [],
        "pruned": [],
        "skipped_no_backup_mode": no_backup_mode,
    }
    if no_backup_mode:
        return summary
    if not upgrade_backups_dir.exists():
        return summary
    today = today or date.today()
    cutoff_ts = (
        datetime.combine(today, datetime.min.time()).timestamp()
        - max(0, retain_days) * 86400
    )

    candidates: list[tuple[float, Path]] = []
    for child in sorted(upgrade_backups_dir.iterdir()):
        if not child.is_dir():
            continue
        if not child.name.startswith("upgrade-"):
            continue
        try:
            mtime = child.stat().st_mtime
        except FileNotFoundError:
            continue
        candidates.append((mtime, child))
    summary["scanned"] = len(candidates)
    candidates.sort(key=lambda item: item[0], reverse=True)

    keep_paths: set[Path] = set()
    if current_backup_root is not None:
        try:
            current_resolved = current_backup_root.resolve()
        except OSError:
            current_resolved = current_backup_root
        for _, path in candidates:
            try:
                if path.resolve() == current_resolved:
                    keep_paths.add(path)
            except OSError:
                continue

    for _, path in candidates[: max(0, retain_count)]:
        keep_paths.add(path)

    for mtime, path in candidates:
        if path in keep_paths:
            summary["preserved"].append({"path": str(path), "mtime": int(mtime)})
            continue
        if mtime >= cutoff_ts:
            summary["preserved"].append({"path": str(path), "mtime": int(mtime)})
            continue
        try:
            shutil.rmtree(path)
            summary["pruned"].append(str(path))
        except OSError as exc:
            summary.setdefault("errors", []).append(
                {"path": str(path), "error": f"{type(exc).__name__}: {exc}"}
            )
    return summary


def validate_claude_config(path: Path) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "path": str(path),
        "exists": path.exists(),
        "status": "missing",
    }
    if not path.exists():
        return payload
    try:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
        payload["status"] = "ok"
    except json.JSONDecodeError as exc:
        payload["status"] = "corrupted"
        payload["error"] = f"JSONDecodeError: {exc}"
    except OSError as exc:
        payload["status"] = "unreadable"
        payload["error"] = f"{type(exc).__name__}: {exc}"
    if payload["status"] == "corrupted":
        backups_dir = Path.home() / ".claude" / "backups"
        if backups_dir.exists():
            backup_candidates = sorted(
                (p for p in backups_dir.glob("**/.claude.json") if p.is_file()),
                key=lambda p: p.stat().st_mtime if p.exists() else 0,
                reverse=True,
            )
            if backup_candidates:
                payload["recovery_candidate"] = str(backup_candidates[0])
    return payload


def cmd_cleanup_residue(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    # PR #508 r2: default these to the canonical layout under target_root.
    # Without the defaults, `cleanup-residue --target-root <root>` (the
    # exact form in OPERATOR_ACTIONS_PENDING.md and in the upgrader's
    # printed recovery command) would skip stale-tmp / daily-prune /
    # upgrade-* prune entirely — defeating the manual fallback path.
    backup_dir = (
        Path(args.backup_dir).expanduser()
        if args.backup_dir
        else (target_root / "backups" / "daily")
    )
    upgrade_backups_dir = (
        Path(args.upgrade_backups_dir).expanduser()
        if args.upgrade_backups_dir
        else (target_root / "backups")
    )
    current_backup_root = (
        Path(args.current_backup_root).expanduser() if args.current_backup_root else None
    )
    retain_days = max(1, int(args.daily_retain_days))
    upgrade_retain_count = max(0, int(args.upgrade_retain_count))
    upgrade_retain_days = max(0, int(args.upgrade_retain_days))
    today = date.today()

    payload: dict[str, Any] = {
        "mode": "cleanup-residue",
        "target_root": str(target_root),
        "backup_dir": str(backup_dir) if backup_dir else "",
        "upgrade_backups_dir": str(upgrade_backups_dir) if upgrade_backups_dir else "",
        "no_backup_mode": bool(args.no_backup_mode),
        "stale_tmp_removed": [],
        "daily_pruned": [],
        "snapshots_pruned": [],
        "upgrade_backups": {},
        "claude_config": {},
        "free_bytes_before": 0,
        "free_bytes_after": 0,
        "cleanup_failures": [],
    }

    measure_path = backup_dir if (backup_dir and backup_dir.exists()) else target_root
    if measure_path and measure_path.exists():
        payload["free_bytes_before"] = _free_bytes(measure_path)

    # 1. stale tmp reaping (no grace gate when run from upgrade — the
    # upgrade wouldn't proceed if the daemon were mid-write of yesterday's
    # tarball; in fact upgrade stops the daemon before this point). Use
    # the env-tuned grace anyway as defense in depth.
    if backup_dir and backup_dir.exists():
        try:
            payload["stale_tmp_removed"] = reap_stale_daily_backup_tmp(backup_dir)
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "stale_tmp_reap", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 2. daily archive prune at the new retain default.
    if backup_dir and backup_dir.exists():
        try:
            payload["daily_pruned"] = prune_daily_backup_archives(
                backup_dir, retain_days, today
            )
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "daily_prune", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 3. SQL snapshot prune.
    try:
        payload["snapshots_pruned"] = prune_sqlite_snapshots(
            target_root, retain_days, today
        )
    except Exception as exc:
        payload["cleanup_failures"].append(
            {"step": "snapshot_prune", "error": f"{type(exc).__name__}: {exc}"}
        )

    # 4. upgrade-* prune (conservative; preserves current BACKUP_ROOT).
    if upgrade_backups_dir is not None:
        try:
            payload["upgrade_backups"] = prune_upgrade_backups(
                upgrade_backups_dir,
                current_backup_root=current_backup_root,
                retain_count=upgrade_retain_count,
                retain_days=upgrade_retain_days,
                today=today,
                no_backup_mode=bool(args.no_backup_mode),
            )
            errors = payload["upgrade_backups"].get("errors") or []
            for err in errors:
                payload["cleanup_failures"].append(
                    {"step": "upgrade_prune", "error": err.get("error", "unknown"),
                     "path": err.get("path", "")}
                )
        except Exception as exc:
            payload["cleanup_failures"].append(
                {"step": "upgrade_prune", "error": f"{type(exc).__name__}: {exc}"}
            )

    # 5. ~/.claude.json validation (read-only).
    try:
        payload["claude_config"] = validate_claude_config(
            Path(args.claude_config_path).expanduser()
            if args.claude_config_path
            else Path.home() / ".claude.json"
        )
    except Exception as exc:
        payload["cleanup_failures"].append(
            {"step": "claude_config", "error": f"{type(exc).__name__}: {exc}"}
        )

    if measure_path and measure_path.exists():
        payload["free_bytes_after"] = _free_bytes(measure_path)
    payload["free_bytes_before_human"] = _format_bytes(payload["free_bytes_before"])
    payload["free_bytes_after_human"] = _format_bytes(payload["free_bytes_after"])
    payload["bytes_freed"] = max(
        0, payload["free_bytes_after"] - payload["free_bytes_before"]
    )
    payload["bytes_freed_human"] = _format_bytes(payload["bytes_freed"])

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_apply_live(args: argparse.Namespace) -> int:
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    base_ref = resolve_base_ref(target_root, args.base_ref or "")
    payload = apply_live(
        source_root,
        target_root,
        base_ref,
        bool(args.dry_run),
        bool(args.strict_merge),
        run_id=str(getattr(args, "run_id", "") or ""),
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 2 if payload.get("aborted") else 0


def cmd_write_state(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    source_root = Path(args.source_root).expanduser()
    payload = {
        "updated_at": now_iso(),
        "source_root": str(source_root),
        "version": args.version or read_source_version(source_root),
        "source_ref": args.source_ref or git_ref(source_root),
        "source_head": git_head(source_root),
        "channel": args.channel or "",
        "backup_root": str(Path(args.backup_root).expanduser()) if args.backup_root else "",
    }
    analysis_payload = load_json_arg(args.analysis_json, args.analysis_json_file)
    if analysis_payload:
        payload["analysis"] = analysis_payload
    save_json(upgrade_state_path(target_root), payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_rollback_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_root = Path(args.backup_root).expanduser() if args.backup_root else latest_backup_root(target_root)
    if backup_root is None:
        raise SystemExit("no upgrade backup found")
    payload = {
        "mode": "upgrade-rollback",
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "dry_run": bool(args.dry_run),
        "restored": False,
        "removed_entries": 0,
    }
    if not args.dry_run:
        payload["removed_entries"] = restore_live_backup(target_root, backup_root)
        payload["restored"] = True
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def _resolve_conflict_path(target_root: Path, raw: str) -> Path:
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = (target_root / candidate).resolve()
    else:
        candidate = candidate.resolve(strict=False)
    return candidate


def _confirm_or_abort(prompt: str, yes: bool) -> bool:
    if yes:
        return True
    if not sys.stdin.isatty():
        print(
            f"refusing without confirmation: pass --yes to proceed ({prompt})",
            file=sys.stderr,
        )
        return False
    try:
        answer = input(f"{prompt} [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer in {"y", "yes"}


def cmd_conflicts_list(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    files = list_conflict_files(target_root)
    rows: list[dict[str, Any]] = []
    now = datetime.now(timezone.utc)
    for path in files:
        try:
            st = path.stat()
        except OSError:
            continue
        mtime = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc)
        record_entry = lookup_conflict_record(target_root, path)
        live_target = ""
        at_write = ""
        hash_changed: bool | None = None
        if record_entry is not None:
            live_target = str(record_entry.get("live_target") or "")
            at_write = str(record_entry.get("live_target_sha256_at_write") or "")
            if live_target:
                current = file_sha256(Path(live_target)) if Path(live_target).exists() else ""
                if at_write:
                    hash_changed = current != at_write
        rows.append(
            {
                "path": str(path),
                "live_target": live_target,
                "size": st.st_size,
                "mtime": mtime.astimezone().isoformat(timespec="seconds"),
                "age_seconds": int(max(0, (now - mtime).total_seconds())),
                "live_target_sha256_at_write": at_write,
                "live_target_hash_changed_since_write": hash_changed,
            }
        )
    rows.sort(key=lambda row: row["mtime"], reverse=True)
    if args.json:
        print(json.dumps({"conflicts": rows, "count": len(rows)}, ensure_ascii=False, indent=2))
        return 0
    if not rows:
        print("(no pending .upgrade-conflict files)")
        return 0
    print("path\tsize\tmtime\tage\thash-changed")
    for row in rows:
        age = row["age_seconds"]
        if age < 3600:
            age_str = f"{age // 60}m"
        elif age < 86400:
            age_str = f"{age // 3600}h"
        else:
            age_str = f"{age // 86400}d"
        hash_state = (
            "changed"
            if row["live_target_hash_changed_since_write"] is True
            else (
                "unchanged"
                if row["live_target_hash_changed_since_write"] is False
                else "unknown"
            )
        )
        print(f"{row['path']}\t{row['size']}\t{row['mtime']}\t{age_str}\t{hash_state}")
    print(f"total: {len(rows)} conflict file(s)")
    return 0


def cmd_conflicts_diff(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file():
        print(f"not a conflict file: {conflict}", file=sys.stderr)
        return 1
    if not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    live = conflict.with_name(conflict.name[: -len(".upgrade-conflict")])
    if not live.exists():
        print(f"live target missing: {live}", file=sys.stderr)
        return 1
    proc = subprocess.run(
        ["diff", "-u", "--", str(live), str(conflict)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    sys.stdout.buffer.write(proc.stdout)
    if proc.stderr:
        sys.stderr.buffer.write(proc.stderr)
    return 0 if proc.returncode in {0, 1} else proc.returncode


def cmd_conflicts_adopt(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    live = conflict.with_name(conflict.name[: -len(".upgrade-conflict")])
    if not _confirm_or_abort(f"adopt {conflict} → {live}?", bool(args.yes)):
        return 1
    shutil.copyfile(conflict, live)
    conflict.unlink()
    write_conflict_audit(
        target_root,
        "conflict_adopt",
        {"conflict": str(conflict), "live_target": str(live)},
    )
    print(json.dumps({"action": "adopt", "conflict": str(conflict), "live_target": str(live)}))
    return 0


def cmd_conflicts_discard(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    if not _confirm_or_abort(f"discard {conflict} (live unchanged)?", bool(args.yes)):
        return 1
    conflict.unlink()
    write_conflict_audit(
        target_root,
        "conflict_discard",
        {"conflict": str(conflict)},
    )
    print(json.dumps({"action": "discard", "conflict": str(conflict)}))
    return 0


def cmd_conflicts_archive(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser().resolve()
    conflict = _resolve_conflict_path(target_root, args.path)
    if not conflict.is_file() or not conflict.name.endswith(".upgrade-conflict"):
        print(f"not a *.upgrade-conflict path: {conflict}", file=sys.stderr)
        return 1
    if not _confirm_or_abort(f"archive {conflict} (live unchanged)?", bool(args.yes)):
        return 1
    dest = archive_conflict_file(target_root, conflict)
    write_conflict_audit(
        target_root,
        "conflict_archive",
        {"conflict": str(conflict), "archived_to": str(dest), "reason": "manual"},
    )
    print(json.dumps({"action": "archive", "conflict": str(conflict), "archived_to": str(dest)}))
    return 0


def cmd_conflicts_reconcile(args: argparse.Namespace) -> int:
    """Auto-archive conflict files whose live target hash has not changed
    since the conflict was written.

    Operator semantics: an unchanged hash means the operator either
    explicitly kept the live version (their pre-write content survived
    the upgrade) or never touched it AND the conflict has not been
    re-deposited by a fresh merge in the meantime — either way the
    conflict file is no longer informative. A changed hash means the
    operator may be mid-reconcile (adopt-in-progress, partial edit), so
    we leave it alone.

    Only `--auto-archive` actually mutates state. Without the flag this
    is a read-only report (suitable for `agb status` integration).
    """
    target_root = Path(args.target_root).expanduser().resolve()
    files = list_conflict_files(target_root)
    actions: list[dict[str, Any]] = []
    for conflict in files:
        record_entry = lookup_conflict_record(target_root, conflict)
        if record_entry is None:
            actions.append(
                {
                    "conflict": str(conflict),
                    "decision": "skip",
                    "reason": "no structured record found",
                }
            )
            continue
        live_target = Path(str(record_entry.get("live_target") or ""))
        at_write = str(record_entry.get("live_target_sha256_at_write") or "")
        if not at_write:
            actions.append(
                {
                    "conflict": str(conflict),
                    "decision": "skip",
                    "reason": "missing at-write hash",
                }
            )
            continue
        current = file_sha256(live_target) if live_target.exists() else ""
        if current == at_write:
            decision = "auto-archive"
            reason = "live hash unchanged since conflict write"
        else:
            decision = "skip"
            reason = "live hash changed since conflict write"
        action = {
            "conflict": str(conflict),
            "live_target": str(live_target),
            "live_target_sha256_at_write": at_write,
            "live_target_sha256_now": current,
            "decision": decision,
            "reason": reason,
        }
        if decision == "auto-archive" and bool(args.auto_archive):
            try:
                dest = archive_conflict_file(target_root, conflict)
                action["archived_to"] = str(dest)
                write_conflict_audit(
                    target_root,
                    "conflict_auto_archive",
                    {
                        "conflict": str(conflict),
                        "archived_to": str(dest),
                        "live_target": str(live_target),
                        "reason": reason,
                    },
                )
            except OSError as exc:
                action["decision"] = "skip"
                action["reason"] = f"archive failed: {exc}"
        actions.append(action)
    payload = {
        "mode": "upgrade-conflicts-reconcile",
        "target_root": str(target_root),
        "auto_archive": bool(args.auto_archive),
        "actions": actions,
        "archived_count": sum(
            1 for entry in actions if entry.get("decision") == "auto-archive" and "archived_to" in entry
        ),
        "skipped_count": sum(1 for entry in actions if entry.get("decision") == "skip"),
    }
    if bool(args.auto_archive) and payload["archived_count"]:
        receipt_path = (
            target_root
            / "state"
            / "upgrade-conflicts"
            / f"auto-archive-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
        )
        save_json(receipt_path, payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-upgrade.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate = subparsers.add_parser("migrate-agents")
    migrate.add_argument("--source-root", required=True)
    migrate.add_argument("--target-root", required=True)
    migrate.add_argument("--admin-agent", default="")
    migrate.add_argument("--dry-run", action="store_true")
    migrate.set_defaults(handler=cmd_migrate_agents)

    # Issue #4769 (reverts #517): the inject subcommand for the admin
    # pair-programming managed block is removed together with the admin
    # codex pair auto-backfill it served. Operators who explicitly
    # maintain a pair-programming SOP block do so in the admin's
    # CLAUDE.md directly; nothing else in the runtime parses the
    # markers, so no managed refresh is needed.

    backup = subparsers.add_parser("backup-live")
    backup.add_argument("--target-root", required=True)
    backup.add_argument("--backup-root", required=True)
    backup.add_argument("--source-root")
    backup.add_argument("--analysis-json", default="")
    backup.add_argument("--analysis-json-file", default="")
    backup.add_argument("--migration-json", default="")
    backup.add_argument("--migration-json-file", default="")
    backup.add_argument("--dry-run", action="store_true")
    backup.set_defaults(handler=cmd_backup_live)

    extend = subparsers.add_parser(
        "backup-extend-live",
        help=(
            "Extend an existing backup snapshot with files that a later upgrade "
            "stage (e.g. bridge-docs.py apply) is about to mutate. Accepts the "
            "`changed_paths` JSON from `bridge-docs.py apply --dry-run --json`."
        ),
    )
    extend.add_argument("--target-root", required=True)
    extend.add_argument("--backup-root", required=True)
    extend.add_argument(
        "--paths-json",
        default="",
        help="JSON payload matching bridge-docs.py --json output (expects a `changed_paths` key).",
    )
    extend.add_argument("--dry-run", action="store_true")
    extend.set_defaults(handler=cmd_backup_extend_live)

    daily_backup = subparsers.add_parser("daily-backup-live")
    daily_backup.add_argument("--target-root", required=True)
    daily_backup.add_argument("--backup-dir", required=True)
    # Bug #507 (3): default retention dropped from 30 → 7. Long-lived
    # installs were generating 45–60 GB of baseline disk consumption from
    # daily archives alone, which then triggered the disk-full death
    # spiral cascade. Operators who want the old behavior set
    # BRIDGE_DAILY_BACKUP_RETAIN_DAYS=30 (or pass --retain-days 30).
    daily_backup.add_argument("--retain-days", type=int, default=7)
    daily_backup.add_argument("--dry-run", action="store_true")
    daily_backup.set_defaults(handler=cmd_daily_backup_live)

    verify_tasks_db = subparsers.add_parser(
        "verify-tasks-db",
        help=(
            "Run PRAGMA quick_check against state/tasks.db in read-only mode "
            "and print a JSON result. Used by post-upgrade verification."
        ),
    )
    verify_tasks_db.add_argument("--target-root", required=True)
    verify_tasks_db.set_defaults(handler=cmd_verify_tasks_db)

    cleanup_residue = subparsers.add_parser(
        "cleanup-residue",
        help=(
            "Reap stale daily-backup tmp files, prune old archives + SQL "
            "snapshots, prune old upgrade-* backups (conservative), and "
            "validate ~/.claude.json. Used by `agb upgrade --apply` and "
            "available standalone."
        ),
    )
    cleanup_residue.add_argument("--target-root", required=True)
    cleanup_residue.add_argument(
        "--backup-dir", default="",
        help="Daily-backup directory (default: <target-root>/backups/daily)",
    )
    cleanup_residue.add_argument(
        "--upgrade-backups-dir", default="",
        help="Parent dir holding upgrade-* snapshots (default: <target-root>/backups)",
    )
    cleanup_residue.add_argument(
        "--current-backup-root", default="",
        help="Path of the in-progress upgrade backup (always preserved).",
    )
    cleanup_residue.add_argument(
        "--no-backup-mode", action="store_true",
        help="Set when invoked from `agb upgrade --no-backup`; skip upgrade-* prune.",
    )
    cleanup_residue.add_argument(
        "--daily-retain-days", type=int, default=7,
    )
    cleanup_residue.add_argument(
        "--upgrade-retain-count", type=int, default=5,
    )
    cleanup_residue.add_argument(
        "--upgrade-retain-days", type=int, default=14,
    )
    cleanup_residue.add_argument(
        "--claude-config-path", default="",
        help="Override path to .claude.json (default: ~/.claude.json).",
    )
    cleanup_residue.set_defaults(handler=cmd_cleanup_residue)

    apply_live_parser = subparsers.add_parser("apply-live")
    apply_live_parser.add_argument("--source-root", required=True)
    apply_live_parser.add_argument("--target-root", required=True)
    apply_live_parser.add_argument("--base-ref", default="")
    apply_live_parser.add_argument("--dry-run", action="store_true")
    apply_live_parser.add_argument("--strict-merge", action="store_true")
    # Issue #394: caller-supplied run-id stamps the structured record
    # at state/upgrade-conflicts/<run-id>.json. Empty → auto-generated.
    apply_live_parser.add_argument("--run-id", default="")
    apply_live_parser.set_defaults(handler=cmd_apply_live)

    analyze = subparsers.add_parser("analyze-live")
    analyze.add_argument("--source-root", required=True)
    analyze.add_argument("--target-root", required=True)
    analyze.add_argument("--base-ref", default="")
    analyze.set_defaults(handler=cmd_analyze_live)

    write_state = subparsers.add_parser("write-state")
    write_state.add_argument("--source-root", required=True)
    write_state.add_argument("--target-root", required=True)
    write_state.add_argument("--backup-root", default="")
    write_state.add_argument("--analysis-json", default="")
    write_state.add_argument("--analysis-json-file", default="")
    write_state.add_argument("--version", default="")
    write_state.add_argument("--source-ref", default="")
    write_state.add_argument("--channel", default="")
    write_state.set_defaults(handler=cmd_write_state)

    rollback = subparsers.add_parser("rollback-live")
    rollback.add_argument("--target-root", required=True)
    rollback.add_argument("--backup-root", default="")
    rollback.add_argument("--dry-run", action="store_true")
    rollback.set_defaults(handler=cmd_rollback_live)

    # Issue #394: lifecycle subcommands for `*.upgrade-conflict` files.
    # The Bash dispatcher (`bridge-upgrade.sh conflicts ...`) forwards
    # diff/adopt/discard/archive/reconcile here; `list` is also wired
    # in Python so callers (CI, status surface) can stay in one runtime.
    conflicts_list = subparsers.add_parser("conflicts-list")
    conflicts_list.add_argument("--target-root", required=True)
    conflicts_list.add_argument("--json", action="store_true")
    conflicts_list.set_defaults(handler=cmd_conflicts_list)

    conflicts_diff = subparsers.add_parser("conflicts-diff")
    conflicts_diff.add_argument("--target-root", required=True)
    conflicts_diff.add_argument("path")
    conflicts_diff.set_defaults(handler=cmd_conflicts_diff)

    conflicts_adopt = subparsers.add_parser("conflicts-adopt")
    conflicts_adopt.add_argument("--target-root", required=True)
    conflicts_adopt.add_argument("--yes", action="store_true")
    conflicts_adopt.add_argument("path")
    conflicts_adopt.set_defaults(handler=cmd_conflicts_adopt)

    conflicts_discard = subparsers.add_parser("conflicts-discard")
    conflicts_discard.add_argument("--target-root", required=True)
    conflicts_discard.add_argument("--yes", action="store_true")
    conflicts_discard.add_argument("path")
    conflicts_discard.set_defaults(handler=cmd_conflicts_discard)

    conflicts_archive = subparsers.add_parser("conflicts-archive")
    conflicts_archive.add_argument("--target-root", required=True)
    conflicts_archive.add_argument("--yes", action="store_true")
    conflicts_archive.add_argument("path")
    conflicts_archive.set_defaults(handler=cmd_conflicts_archive)

    conflicts_reconcile = subparsers.add_parser("conflicts-reconcile")
    conflicts_reconcile.add_argument("--target-root", required=True)
    conflicts_reconcile.add_argument("--auto-archive", action="store_true")
    conflicts_reconcile.set_defaults(handler=cmd_conflicts_reconcile)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
