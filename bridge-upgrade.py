#!/usr/bin/env python3
"""Helpers for smart Agent Bridge upgrade flows."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from stat import S_ISFIFO, S_ISSOCK
import tempfile
from typing import Any

MANAGED_CLAUDE_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_CLAUDE_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"


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


def extract_managed_claude_block(text: str) -> str:
    match = re.search(
        rf"{re.escape(MANAGED_CLAUDE_START)}.*?{re.escape(MANAGED_CLAUDE_END)}",
        text,
        re.S,
    )
    return match.group(0).strip() if match else ""


def refresh_managed_claude_block(original: str, managed_block: str) -> str:
    if not managed_block:
        return original
    block = managed_block.rstrip() + "\n"
    pattern = re.compile(
        rf"{re.escape(MANAGED_CLAUDE_START)}.*?{re.escape(MANAGED_CLAUDE_END)}\n*",
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
    results = [migrate_agent_home(path, template_root, admin_agent, args.dry_run) for path in discover_agent_dirs(agent_root)]
    payload = {
        "agent_count": len(results),
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


def resolve_daily_backup_excluded_roots(target_root: Path, backup_dir: Path) -> list[tuple[str, ...]]:
    excluded: list[tuple[str, ...]] = [("logs",)]
    try:
        relative_backup_dir = backup_dir.resolve().relative_to(target_root.resolve())
    except ValueError:
        return excluded
    if relative_backup_dir.parts:
        excluded.append(relative_backup_dir.parts)
    return excluded


def should_skip_daily_backup_relpath(relpath: Path, excluded_roots: list[tuple[str, ...]]) -> bool:
    parts = relpath.parts
    if not parts:
        return False
    if "__pycache__" in parts:
        return True
    for root_parts in excluded_roots:
        if len(parts) >= len(root_parts) and parts[: len(root_parts)] == root_parts:
            return True
    return False


def iter_daily_backup_members(target_root: Path, backup_dir: Path) -> list[tuple[Path, str]]:
    excluded_roots = resolve_daily_backup_excluded_roots(target_root, backup_dir)
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


def create_daily_backup_archive(target_root: Path, backup_dir: Path, today: date) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    archive_path = backup_dir / daily_backup_archive_name(today)
    tmp_path = backup_dir / f"{archive_path.name}.tmp.{os.getpid()}"
    tmp_path.unlink(missing_ok=True)

    with tarfile.open(tmp_path, "w:gz", format=tarfile.PAX_FORMAT, dereference=False) as archive:
        for src_path, arcname in iter_daily_backup_members(target_root, backup_dir):
            try:
                stat_result = os.lstat(src_path)
            except FileNotFoundError:
                continue
            if S_ISSOCK(stat_result.st_mode) or S_ISFIFO(stat_result.st_mode):
                continue
            archive.add(src_path, arcname=arcname, recursive=False)

    tmp_path.replace(archive_path)
    return archive_path


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
            continue
        if path.name.startswith("agent-bridge-") and ".tmp." in path.name:
            path.unlink(missing_ok=True)
            pruned.append(str(path))
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


def apply_live(source_root: Path, target_root: Path, base_ref: str, dry_run: bool, strict_merge: bool) -> dict[str, Any]:
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
    return payload


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
    payload = {
        "mode": "daily-backup-live",
        "target_root": str(target_root),
        "backup_dir": str(backup_dir),
        "archive_path": str(backup_dir / daily_backup_archive_name(today)),
        "retain_days": retain_days,
        "exists": target_root.exists(),
        "created": False,
        "pruned": [],
    }
    if target_root.exists() and not args.dry_run:
        archive_path = create_daily_backup_archive(target_root, backup_dir, today)
        payload["archive_path"] = str(archive_path)
        payload["created"] = True
        payload["pruned"] = prune_daily_backup_archives(backup_dir, retain_days, today)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_apply_live(args: argparse.Namespace) -> int:
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    base_ref = resolve_base_ref(target_root, args.base_ref or "")
    payload = apply_live(source_root, target_root, base_ref, bool(args.dry_run), bool(args.strict_merge))
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-upgrade.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate = subparsers.add_parser("migrate-agents")
    migrate.add_argument("--source-root", required=True)
    migrate.add_argument("--target-root", required=True)
    migrate.add_argument("--admin-agent", default="")
    migrate.add_argument("--dry-run", action="store_true")
    migrate.set_defaults(handler=cmd_migrate_agents)

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
    daily_backup.add_argument("--retain-days", type=int, default=30)
    daily_backup.add_argument("--dry-run", action="store_true")
    daily_backup.set_defaults(handler=cmd_daily_backup_live)

    apply_live_parser = subparsers.add_parser("apply-live")
    apply_live_parser.add_argument("--source-root", required=True)
    apply_live_parser.add_argument("--target-root", required=True)
    apply_live_parser.add_argument("--base-ref", default="")
    apply_live_parser.add_argument("--dry-run", action="store_true")
    apply_live_parser.add_argument("--strict-merge", action="store_true")
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

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
