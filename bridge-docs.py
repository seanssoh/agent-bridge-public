#!/usr/bin/env python3
"""bridge-docs.py — audit and normalize bridge-owned agent home docs."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"
# Issue #1816 / #2062: the BEGIN marker is a STABLE LITERAL — the version stamp
# does NOT ride the marker line. It lives on a separate in-block metadata line
# (`_managed_version_line()`, an HTML comment so it is invisible in rendered
# markdown) right after the BEGIN marker. Keeping the marker literal means every
# consumer (the watchdog drift probe, the upgrader splice, the migrate/preserve
# helpers, and any future reader) matches it with a plain substring test — there
# is no stamp-suffix blast radius to chase across the repo. `MANAGED_START_RE`
# is retained ONLY as a defensive tolerance for any transitional block that an
# interim build may have stamped on the marker: `MANAGED_START_PREFIX` is the
# bytes up to (but excluding) the trailing ` -->`, and the regex matches a
# stamped-or-unstamped BEGIN alike so a strip/audit still recognizes such a
# block. Renders never emit the stamped form.
MANAGED_START_PREFIX = MANAGED_START[: -len(" -->")]
MANAGED_START_RE = re.escape(MANAGED_START_PREFIX) + r"(?: v=[^\n>]*)? -->"
# In-block version stamp (#1816 audit goal, #2062 placement). Emitted on its own
# line immediately after the literal BEGIN marker. HTML-comment form so it is
# inert in any markdown renderer and never shows up as block content. A future
# audit reads the version mechanically via `MANAGED_VERSION_RE` instead of the
# operator md5-ing N blocks by hand; the marker itself stays a stable literal.
MANAGED_VERSION_PREFIX = "<!-- agent-bridge-managed-version:"


def _managed_version_line(version: str) -> str:
    return f"{MANAGED_VERSION_PREFIX} {version} -->"


# Capture the version value from the in-block metadata line (group 1). Tolerant
# of surrounding whitespace; returns None when the line is absent (e.g. a legacy
# pre-#1816 block or a transitional marker-stamped block).
MANAGED_VERSION_RE = re.compile(
    re.escape(MANAGED_VERSION_PREFIX) + r"\s*([^\n>]*?)\s*-->"
)


def parse_managed_block_version(text: str) -> str | None:
    """Return the in-block managed version stamp, or None if not present.

    Reads the in-block version line emitted just after the BEGIN marker. Kept
    here so the watchdog/audit can extract the stamp mechanically without
    re-deriving the line format. Back-compat: a transitional block that stamped
    the version onto the BEGIN marker (` v=<version>` suffix) is also recognized
    so audit reporting does not regress for such a block.

    The search is SCOPED to the managed-block span (BEGIN marker → END marker) so
    a stray `<!-- agent-bridge-managed-version: ... -->` comment in an agent's
    own custom CLAUDE.md content outside the block can never be mis-read as the
    managed stamp.
    """
    # Scope to the managed block. The BEGIN marker is matched stamp-tolerantly so
    # the transitional `v=`-on-marker block is still located; the version may then
    # be on the marker (no in-block line) — handled by the legacy fallback below.
    block_match = re.search(
        rf"{MANAGED_START_RE}.*?{re.escape(MANAGED_END)}", text, flags=re.S
    )
    scope = block_match.group(0) if block_match else ""
    match = MANAGED_VERSION_RE.search(scope)
    if match:
        return match.group(1).strip() or None
    # Transitional fallback: version stamped on the BEGIN marker itself.
    legacy = re.search(
        re.escape(MANAGED_START_PREFIX) + r" v=([^\n>]*?) -->", scope
    )
    if legacy:
        return legacy.group(1).strip() or None
    return None


HOME_DIR = str(Path.home())
HOME_DIR_RE = re.escape(HOME_DIR)
REPO_ROOT = Path(__file__).resolve().parent


def _read_repo_version() -> str:
    """Read the engine VERSION (first line) for the managed-block stamp.

    Mirror of `bridge-upgrade.py::read_source_version` — kept independent so
    this module has no import dependency on the upgrader. Returns a benign
    `0.0.0-dev` sentinel when the file is missing so a partial checkout still
    renders a (clearly non-release) stamp rather than crashing.
    """
    try:
        version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").splitlines()[0].strip()
    except (FileNotFoundError, IndexError, OSError):
        return "0.0.0-dev"
    return version or "0.0.0-dev"

REMOVABLE_DOCS = ("AGENTS.md", "IDENTITY.md", "BOOTSTRAP.md")
AGENT_SHARED_LINKS = (
    "COMMON-INSTRUCTIONS.md",
    "CHANGE-POLICY.md",
    "TOOLS.md",
    "ADMIN-PROTOCOL.md",
    # Issue #1814: MEMORY-SCHEMA.md joins the canon-symlink family. Its body
    # is now propagated from `docs/agent-runtime/memory-schema.md` into
    # `<bridge_home>/shared/MEMORY-SCHEMA.md` (see render_shared_memory_schema_md)
    # and the home file is a symlink that resolves to that single body — the
    # exact wiring the canon doc's own header already promises and the
    # migration guide table records. This retires the per-home byte-copy fork
    # (the old `sync_memory_schema_from_template` template-sync) and, with the
    # symlink in place, the legacy template-sync's symlink-clobber path can no
    # longer fire (it now sees a symlink and refuses — see the is_symlink guard).
    "MEMORY-SCHEMA.md",
)
DEPRECATED_SHARED_FILES = (
    "ROSTER.md",
    "SYRS-CONTEXT.md",
    "SYRS-RULES.md",
    "SYRS-USER.md",
)
# The shared-doc filenames the engine itself ever symlinks into an agent home:
# the current canon links plus the deprecated ones cleanup garbage-collects.
# Broken-link cleanup (#1813) is scoped to THIS namespace — a broken link whose
# resolved name is outside it (e.g. an operator-authored `OPERATOR-NOTE.md` that
# happens to point into `shared/`) is foreign and must be left untouched.
MANAGED_SHARED_DOC_NAMES = frozenset(AGENT_SHARED_LINKS) | frozenset(DEPRECATED_SHARED_FILES)
# Identity/doc files the migration may rewrite in place (legacy ~/.openclaw
# path normalization). Issue #1781: `MEMORY.md` is AGENT-WRITTEN state, not a
# managed doc — the doc-migration must not rewrite it (even an in-place legacy
# path rewrite mutates live agent memory). It is intentionally absent here; the
# `memory/` tree and `users/<id>/MEMORY.md` are likewise never doc-rewritten.
# Issue #1815: `CHECKLIST.md` is a dead entry from a retired generation of the
# doc set — nothing in the current product creates or references it, so the
# per-apply rewrite attempt was always a no-op. `HEARTBEAT.md` is a
# daemon-written runtime artifact that lives in the agent *workdir*
# (`<workdir>/HEARTBEAT.md`, written by `write_agent_heartbeat` on each daemon
# tick), NOT an identity-home doc — any in-place doc rewrite the engine made to
# it would be overwritten on the very next tick, and in agent homes the file
# does not exist at all. The doc engine has no business rewriting either, so
# both are dropped; only `SOUL.md` is a real home doc the migration may rewrite.
AGENT_RUNTIME_REWRITE_FILES = ("SOUL.md",)
SHARED_CLAUDE_SKILL_NAMES = (
    "agent-bridge-runtime",
    "agent-bridge-operating-manual",
    "cron-manager",
    "memory-wiki",
)
LEGACY_PATTERNS = (
    "openclaw message send",
    "sessions_send",
    "sessions_spawn",
    "sessions_history",
    "openclaw cron add",
    "~/agent-bridge/state/tasks.db",
    f"{HOME_DIR}/agent-bridge/state/tasks.db",
    "~/.openclaw/",
    f"{HOME_DIR}/.openclaw/",
)


@dataclass
class AgentAudit:
    agent: str
    removable_docs: list[str]
    broken_links: list[str]
    local_skills: list[str]
    reference_files: list[str]
    claude_legacy_hits: list[str]


@dataclass
class SkillEntry:
    name: str
    description: str
    category: str
    kind: str
    type: str
    path: str
    doc_path: str
    entry: str
    mcp_plugin: str
    target_agents: list[str]
    source_dir: Path

    def to_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "description": self.description,
            "category": self.category,
            "kind": self.kind,
            "type": self.type,
            "path": self.path,
            "doc_path": self.doc_path,
            "entry": self.entry,
            "mcp_plugin": self.mcp_plugin,
            "target_agents": list(self.target_agents),
        }


def parse_frontmatter_scalar(raw: str) -> object:
    value = raw.strip().strip("\"'")
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [item.strip().strip("\"'") for item in inner.split(",") if item.strip()]
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    return value


def parse_frontmatter(text: str) -> dict[str, object]:
    if not text.startswith("---\n"):
        return {}
    marker = "\n---\n"
    end_index = text.find(marker, 4)
    if end_index == -1:
        return {}
    block = text[4:end_index]
    lines = block.splitlines()
    data: dict[str, object] = {}
    index = 0
    while index < len(lines):
        raw = lines[index]
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in raw:
            index += 1
            continue
        key, value = raw.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not value:
            items: list[str] = []
            index += 1
            while index < len(lines):
                nested = lines[index].strip()
                if not nested.startswith("- "):
                    break
                items.append(nested[2:].strip().strip("\"'"))
                index += 1
            data[key] = items
            continue
        data[key] = parse_frontmatter_scalar(value)
        index += 1
    return data


def strip_frontmatter(text: str) -> str:
    if not text.startswith("---\n"):
        return text
    marker = "\n---\n"
    end_index = text.find(marker, 4)
    if end_index == -1:
        return text
    return text[end_index + len(marker) :]


def first_body_paragraph(text: str) -> str:
    body = strip_frontmatter(text)
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("- ") or line.startswith("```"):
            continue
        return line
    return ""


def normalize_string_list(value: object) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        items = [item.strip() for item in value.replace(",", " ").split()]
        return [item for item in items if item]
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return [str(value).strip()]


def load_roster_skill_map() -> dict[str, list[str]]:
    raw = os.environ.get("BRIDGE_AGENT_SKILLS_JSON", "").strip()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    result: dict[str, list[str]] = {}
    if not isinstance(payload, dict):
        return result
    for agent, skills in payload.items():
        normalized = normalize_string_list(skills)
        if normalized:
            result[str(agent)] = sorted(set(normalized))
    return result


def invert_roster_skill_map(roster_map: dict[str, list[str]]) -> dict[str, list[str]]:
    inverted: dict[str, list[str]] = {}
    for agent, skills in roster_map.items():
        for skill in skills:
            inverted.setdefault(skill, []).append(agent)
    for skill, agents in list(inverted.items()):
        inverted[skill] = sorted(set(agents))
    return inverted


def skill_runtime_root(bridge_home: Path) -> tuple[Path, str]:
    runtime_root = bridge_home / "runtime" / "skills"
    if runtime_root.exists():
        return runtime_root, "~/.agent-bridge/runtime/skills"
    return REPO_ROOT / "runtime-templates" / "skills", "~/.agent-bridge/runtime/skills"


def shared_skill_root(bridge_home: Path) -> tuple[Path, str]:
    live_root = bridge_home / ".claude" / "skills"
    if live_root.exists():
        return live_root, "~/.agent-bridge/.claude/skills"
    return REPO_ROOT / ".claude" / "skills", "~/.agent-bridge/.claude/skills"


def discover_skill_entry(
    skill_dir: Path,
    *,
    kind: str,
    category: str,
    canonical_prefix: str,
    mapped_agents: list[str],
) -> SkillEntry:
    skill_file = skill_dir / "SKILL.md"
    text = read_text(skill_file) if skill_file.exists() else ""
    meta = parse_frontmatter(text) if text else {}
    name = str(meta.get("name") or skill_dir.name)
    description = str(meta.get("description") or first_body_paragraph(text) or f"{name} skill")
    declared_agents = normalize_string_list(meta.get("target_agents"))
    target_agents = sorted(set(mapped_agents + declared_agents))
    entry = str(meta.get("entry") or "")
    if not entry:
        script_paths = sorted(
            str(path.relative_to(skill_dir))
            for path in skill_dir.rglob("*")
            if path.is_file() and path.name != "SKILL.md"
        )
        entry = script_paths[0] if script_paths else "SKILL.md"
    doc_path = f"{canonical_prefix}/{skill_dir.name}/SKILL.md" if skill_file.exists() else ""
    return SkillEntry(
        name=name,
        description=description,
        category=str(meta.get("category") or category),
        kind=kind,
        type=str(meta.get("type") or ("claude-shared" if kind == "shared" else "shell-script")),
        path=f"{canonical_prefix}/{skill_dir.name}",
        doc_path=doc_path,
        entry=entry,
        mcp_plugin=str(meta.get("mcp_plugin") or ""),
        target_agents=target_agents,
        source_dir=skill_dir,
    )


def build_skill_registry(bridge_home: Path) -> dict[str, SkillEntry]:
    roster_map = load_roster_skill_map()
    mapped_agents = invert_roster_skill_map(roster_map)
    registry: dict[str, SkillEntry] = {}

    shared_root, shared_prefix = shared_skill_root(bridge_home)
    if shared_root.exists():
        for skill_dir in sorted(path for path in shared_root.iterdir() if path.is_dir()):
            if not (skill_dir / "SKILL.md").exists():
                continue
            entry = discover_skill_entry(
                skill_dir,
                kind="shared",
                category="bridge-core",
                canonical_prefix=shared_prefix,
                mapped_agents=mapped_agents.get(skill_dir.name, []),
            )
            registry[entry.name] = entry

    runtime_root, runtime_prefix = skill_runtime_root(bridge_home)
    if runtime_root.exists():
        for skill_dir in sorted(path for path in runtime_root.iterdir() if path.is_dir()):
            entry = discover_skill_entry(
                skill_dir,
                kind="runtime",
                category="runtime",
                canonical_prefix=runtime_prefix,
                mapped_agents=mapped_agents.get(skill_dir.name, []),
            )
            registry[entry.name] = entry

    return dict(sorted(registry.items()))


def write_skill_registry(bridge_home: Path, registry: dict[str, SkillEntry], dry_run: bool) -> tuple[Path, bool]:
    payload = {
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "skills": {name: entry.to_dict() for name, entry in registry.items()},
    }
    path = bridge_home / "state" / "skill-registry.json"
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    old = read_text(path) if path.exists() else None
    if old != text:
        write_text(path, text, dry_run)
        return path, True
    return path, False


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def pretty_path(path: Path) -> str:
    return str(path).replace(str(Path.home()), "~")


def write_text(path: Path, content: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def copy_path(src: Path, dst: Path, dry_run: bool) -> None:
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        if dst.exists() and not dst.is_dir():
            if dst.is_symlink() or dst.is_file():
                dst.unlink()
            else:
                shutil.rmtree(dst)
        shutil.copytree(src, dst, dirs_exist_ok=True)
        return
    shutil.copy2(src, dst)


def ensure_symlink(link_path: Path, target: str, dry_run: bool) -> bool:
    """Ensure `link_path` is a symlink pointing at `target`.

    Returns True when the link was (or would be, in dry-run) changed.
    Callers rely on this so they can record the mutation in
    `changed_paths` for the upgrade rollback manifest.
    """
    current = link_path.is_symlink() and os.readlink(link_path) == target
    if current:
        return False
    if dry_run:
        return True
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.exists() or link_path.is_symlink():
        if link_path.is_dir() and not link_path.is_symlink():
            shutil.rmtree(link_path)
        else:
            link_path.unlink()
    link_path.symlink_to(target)
    return True


def backup_file(src: Path, backup_root: Path, dry_run: bool) -> None:
    if not src.exists() and not src.is_symlink():
        return
    if dry_run:
        return
    backup_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, backup_root / src.name, follow_symlinks=False)


def list_agent_dirs(
    target_root: Path,
    selected: list[str],
    all_agents: bool,
    home_subdir: str = "",
) -> list[Path]:
    # Issue #1820: ``home_subdir`` (e.g. "home") descends one level into each
    # agent entry so the docs engine grooms the v2 per-agent home
    # ``<target_root>/<agent>/home`` instead of the flat v1 layout
    # ``<target_root>/<agent>``. Selection (name match / _template / shared
    # filtering) still keys off the agent-named parent; only the returned
    # *home* path carries the subdir. Empty subdir preserves the legacy v1
    # behavior byte-for-byte. The subdir is required to exist — a v2 agent
    # entry that has no ``home`` child (mid-scaffold) is skipped rather than
    # grooming the wrong tree.
    candidates = []
    for path in sorted(target_root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        if home_subdir:
            home_path = path / home_subdir
            if not home_path.is_dir():  # noqa: raw-pathlib-controller-only
                continue
            candidates.append(home_path)
        else:
            candidates.append(path)
    if all_agents or not selected:
        return candidates
    selected_set = set(selected)
    # When descending into a subdir the agent name is the parent dir name.
    return [
        path
        for path in candidates
        if (path.parent.name if home_subdir else path.name) in selected_set
    ]


def collect_relative_files(base: Path, child: str) -> list[str]:
    path = base / child
    if not path.exists():
        return []
    if path.is_file():
        return [child]
    results = []
    for item in sorted(path.rglob("*")):
        if item.is_file():
            results.append(str(item.relative_to(base)))
    return results


def collect_broken_links(agent_dir: Path) -> list[str]:
    broken = []
    for path in agent_dir.rglob("*"):
        if path.is_symlink() and not path.exists():
            broken.append(f"{path.relative_to(agent_dir)} -> {os.readlink(path)}")
    return broken


def audit_agent(agent_dir: Path) -> AgentAudit:
    removable_docs = [name for name in REMOVABLE_DOCS if (agent_dir / name).exists()]
    local_skills = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    claude_path = agent_dir / "CLAUDE.md"
    claude_hits: list[str] = []
    if claude_path.exists():
        # MANAGED_START_RE matches the stamped (` v=<version>`) and unstamped
        # BEGIN marker alike (#1816), so the managed block is fully stripped
        # before legacy-pattern detection regardless of stamp presence.
        claude_text = re.sub(
            rf"{MANAGED_START_RE}.*?{re.escape(MANAGED_END)}\n*",
            "",
            read_text(claude_path),
            flags=re.S,
        )
        for pattern in LEGACY_PATTERNS:
            if pattern in claude_text:
                claude_hits.append(pattern)
    return AgentAudit(
        agent=agent_dir.name,
        removable_docs=removable_docs,
        broken_links=collect_broken_links(agent_dir),
        local_skills=local_skills,
        reference_files=reference_files,
        claude_legacy_hits=claude_hits,
    )


def render_shared_tools_md(bridge_home: Path) -> str:
    home = pretty_path(bridge_home)
    mode = skills_doc_mode()
    if mode == "legacy-catalog":
        skill_guide_line = f"- 스킬 가이드: `{home}/shared/SKILLS.md`"
    elif mode == "plugin-routing":
        skill_guide_line = (
            f"- 스킬 라우팅 인덱스: `{home}/shared/skill-routing.md` "
            f"(상세 query는 `{home}/agent-bridge skills list [--agent NAME] [--json]`)"
        )
    else:  # disabled
        skill_guide_line = (
            f"- 스킬 디스커버리: Claude Code의 공식 Skill 도구를 사용한다. "
            f"per-agent installed plugin은 `{home}/agent-bridge skills list`로 조회한다."
        )
    return f"""# TOOLS.md — Agent Bridge Shared Runtime

<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->

## Canonical Queue Commands
- Dashboard: `{home}/agent-bridge status`
- Inbox 확인: `{home}/agb inbox <agent>`
- 태스크 상세: `{home}/agb show <task-id>`
- claim / done: `{home}/agb claim <task-id> --agent <agent>` / `{home}/agb done <task-id> --agent <agent>`
- durable A2A: `{home}/agent-bridge task create --to <agent> --title "..." --body-file {home}/shared/report.md`
- cross-bridge A2A (send to an agent on another machine / find its node / rooms): `{home}/agent-bridge a2a ...` — task-oriented quickref in `docs/a2a-quickref.md`
- urgent interrupt: `{home}/agent-bridge urgent <agent> "..."`
- handoff: `{home}/agent-bridge handoff <task-id> --to <agent> --note "..."`

## Human-Facing Output
- Discord/Telegram 보고는 연결된 Claude 세션 안에서 자연스럽게 응답한다.
- 레거시 direct-send CLI를 직접 호출하지 않는다.
- 브리지 알림이 필요하면 queue 또는 bridge notify path를 사용한다.

## External Channel Timestamp Handling
Discord/Telegram MCP가 `fetch_messages`·channel webhook으로 반환하는 timestamp(`ts`, `<channel ... ts="...">`)는 모두 **ISO 8601 UTC** 포맷이다 (`Z` suffix, 예: `2026-05-03T22:29:18.928Z`).
- 사용자에게 시간을 인용·비교·보고할 때 반드시 **로컬 timezone(KST = UTC+9)** 으로 변환한 뒤 표기한다.
- UTC 시간이 15:00 이후이면 KST 날짜는 다음 날로 넘어간다(날짜 boundary 주의).
- prompt hook의 `now: ... KST`와 MCP `ts (UTC)`는 다른 timezone이라 그대로 빼면 안 된다.
- 변환 검산: `KST = UTC + 09:00` (서머타임 없음, 항상 일정).
- **오류 사례 (2026-05-04 syrs-sns):** Discord MCP가 `ts="2026-05-03T22:29:18.928Z"`를 반환했는데 에이전트가 "22:29에 보내신 메시지"로 그대로 인용함 → 실제로는 `2026-05-04 07:29 KST`였고 날짜·시각 모두 어긋남. UTC→KST 변환을 빠뜨리면 +9h + 날짜 경계 flip이 동시에 일어난다.

## Cron
- inventory/list/create/update/delete: `{home}/agent-bridge cron ...`
- 옛 cron helper 예시는 더 이상 기준이 아니다.

## Credential & Token Rotation
Claude OAT 풀(여러 setup-token을 등록하고 하나만 active로 두는 다중 토큰 레지스트리)과 codex fleet-sync는 `{home}/agent-bridge auth` (= `bridge-auth.sh`)로 다룬다. 주간 한도/429 쿼터/토큰 로테이션 신호가 보이면 이 verb들을 먼저 본다.

- pool 상태 확인: `{home}/agent-bridge auth claude-token list` (토큰 id·fingerprint만 노출, 토큰값은 안 나옴)
- active 전환: `{home}/agent-bridge auth claude-token activate <id> --sync`
- 자동 로테이션: `{home}/agent-bridge auth claude-token auto-rotate enable|disable|status [--threshold 99]` (기본 threshold 99%)
- 수동 로테이션: `{home}/agent-bridge auth claude-token rotate --reason <text> --sync`
- 쿼터 처리: 한도 친 토큰은 `{home}/agent-bridge auth claude-token mark-quota <id> [--reset-at <iso>]`로 빼두고, reset 이후 `recover-due`가 재검증해 복구한다
- 헬스 체크: `{home}/agent-bridge auth claude-token check <id> --disable-on-quota --enable-on-ok`
- codex fleet-sync: `{home}/agent-bridge auth codex-cred register|source|sync|verify`

caveats:
- **계정 경계.** 로테이션이 *주간* 한도를 실제로 넘기려면 토큰이 **서로 다른 계정** 소속이어야 한다(쿼터는 account-level). 같은 계정의 토큰만 풀에 있으면 로테이션해도 같은 한도에 막힌다.
- **토큰=시크릿.** 등록은 `--stdin` / `--token-file` (또는 운영자 터미널 전용 echo-off `receive`)로만 넣는다. 절대 argv·env·채팅·큐 본문에 토큰값을 인라인하지 않는다.
- 운영 런북(주간 한도/쿼터 소진 시 대응)은 `OPERATIONS.md`의 "Claude setup-token registry and rotation", 전체 설계는 `docs/design/fleet-credential-design.md`를 본다.

## Ops Recipes (intent → command)
에이전트가 운영 점검 명령을 반복적으로 잘못 추측해서 blocked 된 사례가 있다(issue #163). 이름을 처음부터 찾는 대신 아래 의도→명령 매핑을 먼저 본다.

| intent | command |
| --- | --- |
| 상태/헬스 확인 | `{home}/agent-bridge status` |
| 실시간 프로세스 점검 | `{home}/agent-bridge watchdog scan` |
| cron 실패/에러 리포트 | `{home}/agent-bridge cron errors report` |
| cron job 목록 | `{home}/agent-bridge cron list` |
| queue 요약 (누가 뭘 들고 있나) | `{home}/agent-bridge summary` |
| 에이전트 인벤토리 | `{home}/agent-bridge list` |
| 감사 로그 실시간 추적 | `{home}/agent-bridge audit follow` |
| 메모리 위키 정합성 점검 | `{home}/agent-bridge memory lint --agent <agent>` |
| 다른 에이전트로 작업 넘기기 | `{home}/agent-bridge task create --to <agent> ...` |
| 긴급 인터럽트 | `{home}/agent-bridge urgent <agent> "..."` |
| 토큰 풀/로테이션 확인 | `{home}/agent-bridge auth claude-token list` / `auto-rotate status` |

CLI가 모르는 이름을 추측하면 `혹시 이 명령이었나요?` 힌트가 함께 뜬다. 자주 빗맞는 케이스(`health`, `diag`, `cron stats`, `cron list --failed`, `ps`, `agents`, `task stats`)는 `lib/bridge-core.sh`의 `bridge_suggest_subcommand` curated alias 테이블에 이미 들어 있다.

## Queue State
- live queue는 `{home}/state/tasks.db`에 있다.
- 하지만 직접 sqlite를 두드리는 대신 `agb inbox/show/claim/done/summary`를 사용한다.
- repo checkout의 `~/agent-bridge/state/tasks.db`는 live state의 기준이 아니다.

## Subagents
- bridge-managed disposable child가 필요하면 현재 engine의 disposable runner를 사용한다.
- 옛 child-session 예시는 더 이상 기준이 아니다.

## Shared References
- 공통 규칙: `{home}/shared/COMMON-INSTRUCTIONS.md`
- upstream/downstream 분류: `{home}/shared/CHANGE-POLICY.md`
- 팀 지식 인덱스: `{home}/shared/wiki/index.md`
- 사용자/운영자 프로필: `{home}/shared/wiki/people.md`
- 에이전트 역할/구성: `{home}/shared/wiki/agents.md`
- 팀 운영 규칙: `{home}/shared/wiki/operating-rules.md`
- 데이터 소스/도구: `{home}/shared/wiki/data-sources.md`, `{home}/shared/wiki/tools.md`
{skill_guide_line}
"""


LOCAL_OVERRIDE_BEGIN = (
    "<!-- BEGIN LOCAL OVERRIDE — machine-local, not regenerated by agent-bridge -->"
)
LOCAL_OVERRIDE_END = "<!-- END LOCAL OVERRIDE -->"


def append_local_override(base: str, local_path: Path) -> str:
    """Append an operator-owned machine-local override to a generated doc.

    `agb upgrade` regenerates the shared docs wholesale, so a host otherwise
    has no upgrade-safe place for durable local rules. A sibling
    `<name>.local.md` file is never generated or overwritten by the bridge;
    when present, its body is appended here under explicit markers.

    A missing, empty, or unreadable override file degrades to a no-op — the
    return value is byte-identical to ``base`` — so a doc render never aborts
    an upgrade on account of a local file.
    """
    try:
        if not local_path.is_file():
            return base
        extra = local_path.read_text(encoding="utf-8", errors="ignore").strip()
    except OSError:
        return base
    if not extra:
        return base
    return (
        f"{base.rstrip()}\n\n"
        f"{LOCAL_OVERRIDE_BEGIN}\n\n"
        "## 로컬 설치 전용 지침 (machine-local)\n\n"
        "- 아래 규칙은 이 설치에만 적용되며 `COMMON-INSTRUCTIONS.local.md`에서 온다.\n"
        "- upstream에서 오지 않으며 `agb upgrade`가 덮어쓰지 않는다.\n\n"
        f"{extra}\n\n"
        f"{LOCAL_OVERRIDE_END}\n"
    )


def _canon_fallback(name: str, source_rel: str) -> str:
    """A clearly-degraded body emitted when a canon source doc is missing.

    Mirrors `ADMIN_PROTOCOL_FALLBACK` for the other propagated docs (#1814):
    the shared copy never silently becomes an *alternate* SSOT body — when the
    source is absent the file says so loudly and points at the recovery action,
    instead of carrying a hand-maintained summary that diverges from canon.
    """
    return (
        f"# {name} — Agent Bridge Shared Rules\n\n"
        f"<!-- Managed by agent-bridge. Source: {source_rel} missing at render time. -->\n\n"
        f"Source document `{source_rel}` was not present in this install at\n"
        f"render time. Re-run `agent-bridge upgrade` from a complete source\n"
        f"checkout to repopulate this file. See repository docs for the\n"
        f"canonical body.\n"
    )


def _render_canon_doc(source_rel: str, fallback: str) -> str:
    """Propagate a `docs/agent-runtime/<doc>.md` canon body into shared/.

    The single proven propagation primitive behind ADMIN-PROTOCOL (#1814):
    read the source-of-truth body from REPO_ROOT, prepend the managed-source
    header so the shared copy is self-describing, and return it verbatim. One
    body, two locations, lockstep by construction — no second hand-maintained
    summary that silently drops most of the contract. Returns `fallback` when
    the source doc is missing.
    """
    source = REPO_ROOT / source_rel
    if not source.exists():
        return fallback
    body = read_text(source)
    header = (
        "<!-- Managed by agent-bridge. "
        f"Source: {source_rel}. "
        "Edits to this file will be overwritten on the next "
        "`agent-bridge upgrade`. -->\n\n"
    )
    return header + body


def render_shared_common_instructions_md(bridge_home: Path) -> str:
    """Propagate docs/agent-runtime/common-instructions.md into shared/.

    Issue #1814: this used to emit a hand-maintained ~2 KB f-string summary
    whose own first bullet claimed SSOT status — a *second*, diverging body
    that silently dropped most of the 27.8 KB ratified contract (task-processing
    detail, escalation rules, changelog'd directives). It is now propagated from
    the canon doc the exact way ADMIN-PROTOCOL already is, so the shared copy and
    the canon doc can never drift. The machine-local `*.local.md` override
    appendix is preserved.
    """
    base = _render_canon_doc(
        "docs/agent-runtime/common-instructions.md",
        _canon_fallback("COMMON-INSTRUCTIONS.md", "docs/agent-runtime/common-instructions.md"),
    )
    return append_local_override(
        base, bridge_home / "shared" / "COMMON-INSTRUCTIONS.local.md"
    )


def render_shared_memory_schema_md(bridge_home: Path) -> str:
    """Propagate docs/agent-runtime/memory-schema.md into shared/.

    Issue #1814: MEMORY-SCHEMA had a canon body (`docs/agent-runtime/
    memory-schema.md`, 13.8 KB) AND a diverged template fork
    (`agents/_template/MEMORY-SCHEMA.md`, 8.2 KB) that `sync_memory_schema_from_
    template` force-copied byte-for-byte into every home — with no statement of
    which body was authoritative. The canon doc's own header already declares it
    the SSOT and says each home installs the file as a symlink to it; this
    renderer makes that true by propagating the canon body into
    `<bridge_home>/shared/MEMORY-SCHEMA.md` (then `ensure_agent_shared_links`
    wires the home symlink). Same proven pattern as ADMIN-PROTOCOL and
    COMMON-INSTRUCTIONS — one body, lockstep by construction.

    `bridge_home` is accepted for dispatch-table signature parity even though
    the content derives from REPO_ROOT alone.
    """
    del bridge_home  # signature parity with other renderers
    return _render_canon_doc(
        "docs/agent-runtime/memory-schema.md",
        _canon_fallback("MEMORY-SCHEMA.md", "docs/agent-runtime/memory-schema.md"),
    )


def render_shared_change_policy_md(bridge_home: Path) -> str:
    home = pretty_path(bridge_home)
    return f"""# CHANGE-POLICY.md — Upstream vs Downstream Classification

<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->

## Default Routing
- **upstream candidate**: public core 기능, 공통 템플릿, 공통 훅, 공통 CLI/daemon 동작, 새 사용자도 겪는 제품 문제
- **downstream/local**: 한 설치에만 있는 roster, agent home, 사용자 데이터, credential, runtime state, 도메인 커스텀
- **mixed**: 로컬에서 발견했지만 다른 설치도 겪을 수 있는 코어 버그. 이 경우 로컬을 안전하게 막은 뒤 upstream 후보로 올린다.

## Treat As Upstream Candidate
- repo-tracked core paths:
  - `{home}/agent-bridge`, `{home}/agb`
  - `bridge-*.sh`, `bridge-*.py`
  - `lib/`, `hooks/`, `agents/_template/`, `runtime-templates/`
  - repo에 추적되는 `plugins/`, `scripts/`, `completions/`
  - 제품 계약을 설명하는 `README.md`, `ARCHITECTURE.md`, generated contract docs
- 증상이 특정 사용자 데이터가 아니라 제품 설계/기본 동작에서 재현되는 경우
- 로컬에서 만든 기능이 범용성이 높고 새 팀에도 그대로 가치가 있는 경우

## Treat As Downstream / Local
- local-only runtime paths:
  - `{home}/agent-roster.local.sh`
  - `{home}/agents/<agent>/...`
  - `{home}/shared/wiki/`, `{home}/shared/raw/`, `{home}/shared/users/`
  - `{home}/runtime/credentials/`, `secrets/`, `data/`, `assets/`, `extensions/`
  - `{home}/state/`, `{home}/logs/`, `backups/`
- 한 사용자/한 팀의 도메인 스킬, private plugin config, 채널 토큰, 채널 권한, business facts
- 레거시 환경 호환성이나 live 운영 정리처럼 public 코어가 아닌 유지보수 항목

## Reporting Checklist
- 변경 전/후 경로 또는 파일
- 변경 이유와 원인
- 영향 범위: local only / likely generic / unknown
- 긴급 로컬 완화가 필요한지 여부
- upstream 후보라면 재현 조건과 일반화 이유

## Filing Rule
- upstream GitHub issue는 관리자 에이전트가 담당한다.
- 사람 승인 없이 바로 GitHub issue를 등록하지 않는다.
- 초안은 `agent-bridge upstream draft ...`로 만들고, 승인 후 `agent-bridge upstream propose ... --yes`를 사용한다.

## Practical Rule Of Thumb
- 망설여지면 먼저 local 보호 조치를 하고 관리자에게 보고한다.
- 관리자도 애매하면 local fix와 upstream candidate를 둘 다 남기고, public 코어에 바로 직접 반영하지 않는다.
"""


ADMIN_PROTOCOL_FALLBACK = """# ADMIN-PROTOCOL.md — Agent Bridge Admin Protocol

<!-- Managed by agent-bridge. Source: docs/agent-runtime/admin-protocol.md missing at render time. -->

Source document `docs/agent-runtime/admin-protocol.md` was not present in this
install at render time. Re-run `agent-bridge upgrade` from a complete source
checkout to repopulate this file. See repository docs for the canonical admin
protocol body.
"""


def render_shared_admin_protocol_md(bridge_home: Path) -> str:
    """Propagate docs/agent-runtime/admin-protocol.md into the shared dir.

    Rationale: the agent CLAUDE.md managed block points admin sessions at
    `ADMIN-PROTOCOL.md` (see `_admin_block_lines`), but until this renderer
    existed the file was never written to `<bridge_home>/shared/` and the
    matching symlink was therefore missing from every admin agent home
    (`COMMON-INSTRUCTIONS.md`, `CHANGE-POLICY.md`, `TOOLS.md` had the wiring
    via `AGENT_SHARED_LINKS`, `ADMIN-PROTOCOL.md` did not). Reading the
    source-of-truth body keeps the shared copy in lockstep with the doc the
    repo already maintains, rather than duplicating 30KB of protocol text
    inline here.

    `bridge_home` is accepted for parity with the other shared renderers
    (dispatch table calls every renderer with the same signature) even
    though this renderer derives content from REPO_ROOT alone.
    """
    del bridge_home  # signature parity with other renderers
    # Routes through the shared `_render_canon_doc` primitive (#1814) so the
    # propagation behaviour is single-sourced across ADMIN-PROTOCOL,
    # COMMON-INSTRUCTIONS, and MEMORY-SCHEMA. ADMIN_PROTOCOL_FALLBACK is kept
    # as the bespoke fallback body.
    return _render_canon_doc("docs/agent-runtime/admin-protocol.md", ADMIN_PROTOCOL_FALLBACK)


SKILLS_DOC_MODES = ("legacy-catalog", "plugin-routing", "disabled")


def skills_doc_mode() -> str:
    """Return the BRIDGE_SKILLS_DOC_MODE setting.

    - `legacy-catalog` (default): emit the historical SKILLS.md monolithic
      catalog. Backwards-compatible; no behaviour change for installs that
      have not opted in.
    - `plugin-routing`: emit a much smaller shared/skill-routing.md that
      lists installed plugins per agent. Stops emitting SKILLS.md.
    - `disabled`: emit neither. Operator has migrated all skill discovery
      to Claude Code's official Skill tool / installed_plugins.json and
      does not want any bridge-managed catalog file.
    """
    raw = os.environ.get("BRIDGE_SKILLS_DOC_MODE", "").strip().lower()
    if raw in SKILLS_DOC_MODES:
        return raw
    return "legacy-catalog"


def load_agent_workdirs() -> dict[str, str]:
    """Roster-driven agent → workdir mapping.

    Caller (lib/bridge-skills.sh during `bridge-docs.py apply`) injects this
    via BRIDGE_AGENT_WORKDIR_JSON. Empty dict when unset — render functions
    handle that gracefully.
    """
    raw = os.environ.get("BRIDGE_AGENT_WORKDIR_JSON", "").strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v) for k, v in data.items() if isinstance(v, str) and v}


def installed_plugins_path() -> Path:
    """Claude Code's authoritative installed-plugin record.

    Honours CLAUDE_HOME for tests; defaults to ~/.claude/plugins/installed_plugins.json
    on a normal install.
    """
    explicit = os.environ.get("CLAUDE_PLUGINS_FILE", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".claude" / "plugins" / "installed_plugins.json"


def load_installed_plugins() -> dict[str, list[dict]]:
    """Read installed_plugins.json. Best-effort; returns {} on any failure."""
    path = installed_plugins_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        return {}
    out: dict[str, list[dict]] = {}
    for key, entries in plugins.items():
        if isinstance(entries, list):
            out[str(key)] = [e for e in entries if isinstance(e, dict)]
    return out


def build_plugin_routing(
    installed: dict[str, list[dict]],
    workdirs: dict[str, str],
) -> tuple[set[str], dict[str, set[str]]]:
    """Split installed plugins into (user-scope, agent-scope mapping).

    user-scope plugins apply to every agent on this host; surface them as
    a single shared row rather than repeating each plugin name in every
    agent column.

    project/local-scope plugins map to a specific projectPath; we attribute
    them to the agent whose workdir resolves to that path. Plugins whose
    projectPath does not match any agent in the roster are dropped from
    the cross-agent index — the plugin is still installed, just not on a
    workspace this bridge install knows about.
    """
    user_plugins: set[str] = set()
    routing: dict[str, set[str]] = {agent: set() for agent in workdirs}

    resolved_workdirs: dict[str, str] = {}
    for agent, workdir in workdirs.items():
        try:
            resolved_workdirs[agent] = str(Path(workdir).resolve())
        except OSError:
            resolved_workdirs[agent] = workdir

    for full_key, entries in installed.items():
        plugin_name = full_key.split("@", 1)[0]
        for entry in entries:
            scope = str(entry.get("scope") or "")
            if scope == "user":
                user_plugins.add(plugin_name)
                continue
            if scope not in {"project", "local"}:
                continue
            project_path = str(entry.get("projectPath") or "").strip()
            if not project_path:
                continue
            try:
                resolved_project = str(Path(project_path).resolve())
            except OSError:
                resolved_project = project_path
            for agent, workdir in resolved_workdirs.items():
                if resolved_project == workdir:
                    routing[agent].add(plugin_name)
                    break
    return user_plugins, routing


def _agent_block_tools_skills_line() -> str:
    """Mode-aware bullet text for the 'TOOLS.md / SKILLS.md' runtime
    canon line in render_agent_bridge_block(). Codex r1 on PR #513 caught
    that this line keeps pointing at SKILLS.md after sync_shared_docs has
    deleted that file in plugin-routing/disabled mode — leaving every
    agent's CLAUDE.md telling the model to read a file that does not
    exist."""
    mode = skills_doc_mode()
    if mode == "legacy-catalog":
        return "- `TOOLS.md`와 `SKILLS.md`는 현재 bridge-native runtime reference다."
    if mode == "plugin-routing":
        return (
            "- `TOOLS.md`는 현재 bridge-native runtime reference다. "
            "스킬 라우팅은 `shared/skill-routing.md` 또는 `agb skills list`를 본다."
        )
    # disabled
    return (
        "- `TOOLS.md`는 현재 bridge-native runtime reference다. "
        "스킬 디스커버리는 Claude Code의 공식 Skill 도구를 사용하고, "
        "per-agent installed plugin은 `agb skills list`로 조회한다."
    )


def _per_agent_skills_anchor_line() -> str:
    """Mode-aware anchor line in render_agent_skills_md(). Same fix as
    _agent_block_tools_skills_line — the legacy-catalog text told the
    model to read shared/SKILLS.md first, which becomes a broken
    reference in plugin-routing/disabled."""
    mode = skills_doc_mode()
    if mode == "legacy-catalog":
        return "- 공용 bridge 명령은 `TOOLS.md`와 `~/.agent-bridge/shared/SKILLS.md`를 먼저 본다."
    if mode == "plugin-routing":
        return (
            "- 공용 bridge 명령은 `TOOLS.md`를 먼저 본다. "
            "스킬 라우팅은 `~/.agent-bridge/shared/skill-routing.md` 또는 "
            "`agb skills list`를 사용한다."
        )
    # disabled
    return (
        "- 공용 bridge 명령은 `TOOLS.md`를 먼저 본다. "
        "스킬 디스커버리는 Claude Code의 공식 Skill 도구를 사용하고, "
        "per-agent installed plugin은 `agb skills list`로 조회한다."
    )


def render_shared_skill_routing_md(bridge_home: Path) -> str:
    """plugin-routing mode: emit a compact agent → installed-plugins index.

    Reads ~/.claude/plugins/installed_plugins.json (Claude Code's
    authoritative record) and the BRIDGE_AGENT_WORKDIR_JSON roster
    snapshot. Bridge shared skills under ~/.agent-bridge/.claude/skills/
    are intentionally NOT included here — they are exposed via Claude
    Code's Skill tool already, and listing them again would just
    re-create the SKILLS.md token tax.
    """
    workdirs = load_agent_workdirs()
    installed = load_installed_plugins()
    user_plugins, routing = build_plugin_routing(installed, workdirs)

    lines = [
        "# skill-routing.md — Cross-Agent Plugin Index",
        "",
        "<!-- Managed by agent-bridge (BRIDGE_SKILLS_DOC_MODE=plugin-routing). -->",
        "<!-- Use `agb skills list --json` for the structured view. -->",
        "",
        "Routing rule: when you need a capability, look up which agent has the plugin",
        "installed below. Bridge shared skills under `~/.agent-bridge/.claude/skills/`",
        "are exposed via Claude Code's Skill tool and not duplicated here.",
        "",
    ]

    if user_plugins:
        lines.extend(
            [
                "## User-scope plugins (available to every agent on this host)",
                "",
                ", ".join(f"`{name}`" for name in sorted(user_plugins)),
                "",
            ]
        )

    lines.extend(
        [
            "## Per-agent plugins (project / local scope)",
            "",
        ]
    )

    if not workdirs:
        lines.extend(
            [
                "_No agent workdir map available. Set `BRIDGE_AGENT_WORKDIR_JSON`",
                "in the caller env (lib/bridge-skills.sh injects this during",
                "`bridge-docs.py apply`)._",
            ]
        )
    else:
        lines.extend(
            [
                "| Agent | Workdir | Installed plugins |",
                "| --- | --- | --- |",
            ]
        )
        for agent in sorted(routing):
            plugins = sorted(routing[agent])
            cell = ", ".join(f"`{name}`" for name in plugins) if plugins else "—"
            workdir_cell = workdirs.get(agent, "—")
            lines.append(f"| `{agent}` | `{workdir_cell}` | {cell} |")

    return "\n".join(lines).rstrip() + "\n"


def render_shared_skills_md(bridge_home: Path, registry: dict[str, SkillEntry]) -> str:
    home = pretty_path(bridge_home)
    shared_skills = [entry for entry in registry.values() if entry.kind == "shared"]
    runtime_skills = [entry for entry in registry.values() if entry.kind == "runtime"]

    lines = [
        "# SKILLS.md — Agent Bridge Shared Skill Catalog",
        "",
        "<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->",
        "",
        "## Usage Rules",
        "- 먼저 각 에이전트의 `CLAUDE.md`, `SOUL.md`, agent-local `SKILLS.md`를 읽고 현재 역할 문맥을 확인한다.",
        "- 공용 스킬 카탈로그는 이 파일이 SSOT다. agent-local `skills/`는 추가 private extension으로만 본다.",
        "- `references/`는 supporting material이지 실행 명령 목록이 아니다.",
        "- 예전 외부 skill 경로가 남아 있어도 canonical runtime은 bridge-local registry와 `~/.agent-bridge/runtime/skills/`다.",
        "",
        "## Shared Claude Skills",
    ]

    if shared_skills:
        lines.extend(
            [
                "| Skill | Description | Type | Path |",
                "| --- | --- | --- | --- |",
            ]
        )
        for entry in shared_skills:
            lines.append(
                f"| `{entry.name}` | {entry.description} | `{entry.type}` | `{entry.path}` |"
            )
    else:
        lines.append("- none")

    lines.extend(["", "## Runtime Skill Catalog"])
    if runtime_skills:
        lines.extend(
            [
                "| Skill | Description | Mapped Agents | Entry |",
                "| --- | --- | --- | --- |",
            ]
        )
        for entry in runtime_skills:
            mapped = ", ".join(f"`{agent}`" for agent in entry.target_agents) if entry.target_agents else "-"
            entry_hint = f"`{entry.entry}`" if entry.entry else "-"
            lines.append(f"| `{entry.name}` | {entry.description} | {mapped} | {entry_hint} |")
    else:
        lines.append("- no runtime skills discovered")

    lines.extend(
        [
            "",
            "## Discovery Contract",
            f"- Registry snapshot: `{home}/state/skill-registry.json`",
            f"- Shared references: `{home}/shared/references/`",
            "- Per-agent `SKILLS.md` files are derived from the same registry plus local `skills/` files.",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def rewrite_agent_runtime_text(agent_dir: Path, text: str) -> str:
    text = normalize_legacy_paths(text)
    runtime_root = "~/.agent-bridge/runtime"
    replacements = {
        "~/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "$HOME/.openclaw/credentials/": f"{runtime_root}/credentials/",
        f"{HOME_DIR}/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "~/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "$HOME/.openclaw/secrets/": f"{runtime_root}/secrets/",
        f"{HOME_DIR}/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "~/.openclaw/openclaw.json": f"{runtime_root}/bridge-config.json",
        "$HOME/.openclaw/openclaw.json": f"{runtime_root}/bridge-config.json",
        f"{HOME_DIR}/.openclaw/openclaw.json": f"{runtime_root}/bridge-config.json",
        "~/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "$HOME/.openclaw/scripts/": f"{runtime_root}/scripts/",
        f"{HOME_DIR}/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "~/.openclaw/skills/": f"{runtime_root}/skills/",
        "$HOME/.openclaw/skills/": f"{runtime_root}/skills/",
        f"{HOME_DIR}/.openclaw/skills/": f"{runtime_root}/skills/",
        "~/.openclaw/data/": f"{runtime_root}/data/",
        "$HOME/.openclaw/data/": f"{runtime_root}/data/",
        f"{HOME_DIR}/.openclaw/data/": f"{runtime_root}/data/",
        "~/.openclaw/assets/": f"{runtime_root}/assets/",
        "$HOME/.openclaw/assets/": f"{runtime_root}/assets/",
        f"{HOME_DIR}/.openclaw/assets/": f"{runtime_root}/assets/",
        "~/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "$HOME/.openclaw/extensions/": f"{runtime_root}/extensions/",
        f"{HOME_DIR}/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "~/.openclaw/memory/": f"{runtime_root}/memory/",
        "$HOME/.openclaw/memory/": f"{runtime_root}/memory/",
        f"{HOME_DIR}/.openclaw/memory/": f"{runtime_root}/memory/",
        "sessions_send": "agent-bridge task create",
        "sessions_spawn": "bridge disposable child",
        "sessions_history": "bridge task/MEMORY context",
        "openclaw message send": "연결된 Claude 세션 응답",
        "localhost:8787/hooks/patch-trigger": "`agent-bridge urgent <admin-agent>`",
        "Discord #patch 채널 웹훅": "`agent-bridge task create --to <admin-agent>` 또는 `agent-bridge urgent <admin-agent>`",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)

    return text


def normalize_agent_runtime_file(path: Path, agent_dir: Path, dry_run: bool, backup_root: Path) -> bool:
    if not path.exists() or not path.is_file():
        return False
    original = read_text(path)
    rewritten = rewrite_agent_runtime_text(agent_dir, original)
    if rewritten == original:
        return False
    backup_file(path, backup_root, dry_run)
    write_text(path, rewritten, dry_run)
    return True


def sync_shared_docs(bridge_home: Path, source_shared: Path, dry_run: bool, stamp: str, registry: dict[str, SkillEntry]) -> list[str]:
    changed: list[str] = []
    target_shared = bridge_home / "shared"
    target_refs = target_shared / "references"
    if not dry_run:
        target_shared.mkdir(parents=True, exist_ok=True)
    shared_link = bridge_home / "agents" / "shared"
    if ensure_symlink(shared_link, "../shared", dry_run):
        changed.append(str(shared_link))

    deprecated_backup_root = bridge_home / "state" / "doc-migration" / "backups" / stamp / "_shared"
    for name in DEPRECATED_SHARED_FILES:
        path = target_shared / name
        if not path.exists() and not path.is_symlink():
            continue
        backup_file(path, deprecated_backup_root, dry_run)
        if not dry_run:
            path.unlink()
        changed.append(f"removed:{path}")

    # PR #514 deleted agents/_template/SKILLS.md from source (so newly
    # scaffolded agents no longer inherit a stale catalog placeholder),
    # but `agent-bridge upgrade` does not propagate source-side file
    # deletions to the live runtime. Hosts that upgraded before PR #514
    # still carry agents/_template/SKILLS.md, and the scaffolder copies
    # everything under _template/ into a new agent home — so the stale
    # file would re-leak into newly-created agents on those hosts.
    # Clean up explicitly (idempotent — backups land alongside the
    # _shared cleanup above).
    template_skills = bridge_home / "agents" / "_template" / "SKILLS.md"
    if template_skills.exists() or template_skills.is_symlink():
        template_backup_root = (
            bridge_home / "state" / "doc-migration" / "backups" / stamp / "_template"
        )
        backup_file(template_skills, template_backup_root, dry_run)
        if not dry_run:
            template_skills.unlink()
        changed.append(f"removed:{template_skills}")

    source_refs = source_shared / "references"
    if source_refs.exists():
        for ref in sorted(source_refs.rglob("*")):
            if not ref.is_file():
                continue
            dst = target_refs / ref.relative_to(source_refs)
            if not dst.exists() or read_text(dst) != read_text(ref):
                copy_path(ref, dst, dry_run)
                changed.append(str(dst))

    generated_renderers: dict[str, "object"] = {
        "TOOLS.md": render_shared_tools_md,
        "COMMON-INSTRUCTIONS.md": render_shared_common_instructions_md,
        "CHANGE-POLICY.md": render_shared_change_policy_md,
        "ADMIN-PROTOCOL.md": render_shared_admin_protocol_md,
        # Issue #1814: MEMORY-SCHEMA.md is now a propagated canon body in
        # shared/ (symlinked from homes via AGENT_SHARED_LINKS), retiring the
        # per-home template fork.
        "MEMORY-SCHEMA.md": render_shared_memory_schema_md,
    }
    # BRIDGE_SKILLS_DOC_MODE chooses the catalog rendering strategy.
    # Whichever file is *not* selected gets cleaned up so a mode flip
    # doesn't leave stale catalogs lying around.
    mode = skills_doc_mode()
    deprecated_skill_docs: list[str] = []
    if mode == "legacy-catalog":
        generated_renderers["SKILLS.md"] = lambda home: render_shared_skills_md(home, registry)
        deprecated_skill_docs.append("skill-routing.md")
    elif mode == "plugin-routing":
        generated_renderers["skill-routing.md"] = render_shared_skill_routing_md
        deprecated_skill_docs.append("SKILLS.md")
    else:  # disabled
        deprecated_skill_docs.extend(["SKILLS.md", "skill-routing.md"])
    for name in deprecated_skill_docs:
        path = target_shared / name
        if not path.exists() and not path.is_symlink():
            continue
        backup_file(path, deprecated_backup_root, dry_run)
        if not dry_run:
            path.unlink()
        changed.append(f"removed:{path}")
    for name, renderer in generated_renderers.items():
        dst = target_shared / name
        text = renderer(bridge_home)
        old = read_text(dst) if dst.exists() else None
        if old != text:
            write_text(dst, text, dry_run)
            changed.append(str(dst))

    return changed


def normalize_legacy_paths(text: str) -> str:
    replacements = {
        f"{HOME_DIR}/agent-bridge/state/tasks.db": "~/.agent-bridge/state/tasks.db",
        "~/agent-bridge/state/tasks.db": "~/.agent-bridge/state/tasks.db",
        f"{HOME_DIR}/agent-bridge/shared/": "~/.agent-bridge/shared/",
        "~/agent-bridge/shared/": "~/.agent-bridge/shared/",
        f"{HOME_DIR}/.openclaw/shared/": "~/.agent-bridge/shared/",
        "~/.openclaw/shared/": "~/.agent-bridge/shared/",
        "$HOME/.openclaw/shared/": "~/.agent-bridge/shared/",
        f"{HOME_DIR}/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        "~/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        "$HOME/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        f"{HOME_DIR}/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        "~/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        "$HOME/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        f"{HOME_DIR}/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        "~/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        "$HOME/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        f"{HOME_DIR}/.openclaw/agents/": "~/.agent-bridge/agents/",
        "~/.openclaw/agents/": "~/.agent-bridge/agents/",
        "$HOME/.openclaw/agents/": "~/.agent-bridge/agents/",
        f"{HOME_DIR}/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        f"{HOME_DIR}/.openclaw/patch": "~/.agent-bridge/agents/patch",
        "~/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        "~/.openclaw/patch": "~/.agent-bridge/agents/patch",
        "$HOME/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        "$HOME/.openclaw/patch": "~/.agent-bridge/agents/patch",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    text = re.sub(
        rf"(?:~|{HOME_DIR_RE})/\.openclaw/workspace-([A-Za-z0-9._-]+)",
        r"~/.agent-bridge/agents/\1",
        text,
    )
    text = re.sub(
        rf"(?:~|{HOME_DIR_RE})/\.openclaw/workspace\b",
        "~/.agent-bridge/agents/main",
        text,
    )
    return normalize_openclaw_home_variants(text)


def normalize_openclaw_home_variants(text: str) -> str:
    text = re.sub(
        r"\$HOME/\.openclaw/workspace-([A-Za-z0-9._-]+)",
        r"~/.agent-bridge/agents/\1",
        text,
    )
    return re.sub(
        r"\$HOME/\.openclaw/workspace\b",
        "~/.agent-bridge/agents/main",
        text,
    )


def extract_identity_snapshot(identity_path: Path) -> list[str]:
    if not identity_path.exists():
        return []
    lines = []
    for raw in read_text(identity_path).splitlines():
        line = raw.strip()
        if line.startswith("- **"):
            lines.append(line)
    return lines[:5]


SESSION_TYPE_RE = re.compile(r"^\s*-\s*Session Type:\s*(?P<value>[A-Za-z0-9_-]+)", re.MULTILINE)


def read_session_type(agent_dir: Path) -> str:
    """Return the agent's session type (e.g. 'admin', 'static-claude').

    Falls back to 'general' when SESSION-TYPE.md is missing, unreadable, or
    does not contain a `- Session Type: <value>` line. The role filter in
    `render_agent_bridge_block` treats 'admin' as the only special case;
    all other values render the general block. Returned value is
    lowercased so `Admin` / `ADMIN` / `admin` all match the filter.
    """
    session_type_path = agent_dir / "SESSION-TYPE.md"
    try:
        text = session_type_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return "general"
    match = SESSION_TYPE_RE.search(text)
    if not match:
        return "general"
    value = match.group("value").strip().lower()
    return value or "general"


def _admin_block_lines() -> list[str]:
    """Admin-only runtime content for the managed block.

    Included only when `render_agent_bridge_block` is called with
    session_type == 'admin'. Kept deliberately short — detailed admin
    protocols live in `docs/agent-runtime/admin-protocol.md` and the agent's
    own CLAUDE.md (outside the managed markers).
    """
    return [
        "",
        "## Admin Protocol Pointer",
        "- First-run onboarding, self-cleanup, static/dynamic boundary, upgrade protocol, and channel setup execution live in `ADMIN-PROTOCOL.md`.",
        "- Managed admin defaults ride with this block; role-specific customizations live outside the managed markers.",
        "- Never auto-run `upstream propose --yes`. Require explicit human approval in every install.",
    ]


def render_agent_bridge_block(agent_dir: Path, session_type: str | None = None) -> str:
    identity_lines = extract_identity_snapshot(agent_dir / "IDENTITY.md")
    local_skill_files = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    if session_type is None:
        session_type = read_session_type(agent_dir)
    # Normalize explicitly-passed session_type so caller case variants
    # ("Admin", "ADMIN") match the role filter.
    session_type = (session_type or "").strip().lower() or "general"
    # Issue #1816 / #2062: the version stamp makes a stale/foreign block
    # mechanically detectable (audit reads the version instead of the operator
    # md5-ing N blocks by hand). The stamp lives on a SEPARATE in-block metadata
    # line, NOT on the BEGIN marker — the marker stays the stable literal
    # MANAGED_START so the watchdog drift probe and every other consumer keep
    # matching it with a plain substring test (no stamp-suffix blast radius).
    # The version line is an HTML comment (inert in rendered markdown) read back
    # via parse_managed_block_version / MANAGED_VERSION_RE.
    lines = [
        MANAGED_START,
        _managed_version_line(_read_repo_version()),
        "## Agent Bridge Runtime Canon",
        "- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.",
        "- `CLAUDE.md`는 운영 계약서다. 레거시 문서나 오래된 메모와 충돌하면 이 파일이 우선한다.",
        "- `SESSION-TYPE.md`는 이 세션이 어떤 종류의 역할인지와 첫 세션 온보딩 상태를 정의한다.",
        "- `NEXT-SESSION.md`가 있으면 시작 직후 읽고 먼저 처리한 뒤, 검증이 끝나면 파일을 삭제한다.",
        # Issue #1815: HEARTBEAT.md dropped from this bullet — it is a
        # daemon-written status artifact in the agent *workdir*, never an
        # identity-home doc (present in 0 homes). The block must not tell every
        # agent to "read" a file that does not exist where it looks.
        "- `MEMORY.md`와 `memory/`는 작업 메모리다.",
        "- `MEMORY-SCHEMA.md`는 memory wiki를 어떻게 유지할지 정의한다.",
        "- `COMMON-INSTRUCTIONS.md`는 전 에이전트 공통 규칙 SSOT다.",
        "- `CHANGE-POLICY.md`는 기술 변경의 upstream/downstream 분류 계약이다.",
        _agent_block_tools_skills_line(),
        # Issue #162 Phase 2: conditional bullet — only rendered when the
        # agent actually has promoted role-specific preferences. Zero
        # overhead when absent (file-exists gate, same pattern as Phase 1's
        # USER.md cross-agent canonical).
        *(
            ["- `ACTIVE-PREFERENCES.md`: 이 에이전트 역할 전용 운영 규칙이다. 매 세션 시작 시 읽는다."]
            if (agent_dir / "ACTIVE-PREFERENCES.md").exists()
            else []
        ),
        "",
        # Issue #1816: pointer-only block (ratified 2026-04-19,
        # docs/agent-runtime/common-instructions.md §"Managed block 계약").
        # The full Queue & Delivery / Task Processing Protocol / Legacy
        # Guardrails bodies that used to be hardcopied here now live ONLY in the
        # canon doc; this block points at the relevant section. 본문 하드카피 금지.
        "## Runtime Protocol Pointers",
        "- 공통 운영 본문은 `COMMON-INSTRUCTIONS.md`에 있다. queue 전달, task 처리(claim → 처리 → 결과 전달 → done --note, 조용한 done/빈 note done 금지), autonomy, escalation, upstream issue policy, channel setup의 source of truth다.",
        "- queue/A2A/bundle/intake 사용법과 status lifecycle(`queued`/`claimed`/`blocked`), blocked escalation timing은 `COMMON-INSTRUCTIONS.md`의 \"Queue Delivery Contract\"와 \"Task Processing Protocol\"을 따른다.",
        "- legacy guardrails(레거시 tasks.db 경로, shared 문서 위치, cron 경로, 폐지된 `AGENTS.md`/`IDENTITY.md`/`BOOTSTRAP.md`)는 `COMMON-INSTRUCTIONS.md`의 \"Legacy Guardrails\"에 있다.",
        "- admin-only 운영 본문은 `ADMIN-PROTOCOL.md`에 있다. first-run onboarding, self-cleanup, static/dynamic boundary, upgrade protocol은 admin 세션에만 적용된다.",
        "- 운영 매뉴얼 인덱스는 `~/.agent-bridge/.claude/skills/agent-bridge-operating-manual/SKILL.md`에서 찾는다.",
        "- `[Agent Bridge] event=...` 외부 push는 `external-push-handling` skill을 읽고 처리한다. 이 블록에는 7-step 루틴을 하드카피하지 않는다.",
        "- 멀티스텝/장시간 작업은 main 루프에서 inline 처리하지 말고 background subagent로 위임해 사람 응답성을 유지한다. 상세 패턴은 `COMMON-INSTRUCTIONS.md`의 \"Background Subagent Delegation\"을 따른다 (background subagent 기능이 없는 엔진은 해당 없음).",
        "- handoff, memory/wiki, user preference promotion은 `docs/agent-runtime/`의 각 canonical 문서를 따른다.",
    ]
    if session_type == "admin":
        lines.extend(_admin_block_lines())
    if identity_lines:
        lines.extend(["", "## Identity Snapshot", *identity_lines])
    if local_skill_files or reference_files:
        lines.extend(["", "## Local Assets"])
        if local_skill_files:
            lines.append("- local skills:")
            lines.extend([f"  - `{entry}`" for entry in local_skill_files])
        if reference_files:
            lines.append("- local references:")
            lines.extend([f"  - `{entry}`" for entry in reference_files])
    lines.append(MANAGED_END)
    return "\n".join(lines)


COMMON_CLAUDE_REPLACEMENTS = {
    '5. Run the DB preflight steps described in `AGENTS.md` before sending anything; if compaction recovery is pending, wait for verification rather than guessing.': '5. Run the DB preflight steps described in `TOOLS.md` before sending anything; if compaction recovery is pending, wait for verification rather than guessing.',
    '6. Confirm that the workspace files you need (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `ROSTER.md`, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.': '6. Confirm that the workspace files you need (`SOUL.md`, `TOOLS.md`, the shared wiki pages, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.',
    '6. Confirm that the workspace files you need (`SOUL.md`, `TOOLS.md`, `ROSTER.md`, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.': '6. Confirm that the workspace files you need (`SOUL.md`, `TOOLS.md`, the shared wiki pages, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.',
    '- Replace `sessions_send(sessionKey="agent:<id>:main", …)` calls with `agent-bridge task create --to <agent>` for the intended recipient, and `agent-bridge urgent` for interrupts. Add context so the receiving agent knows why the request exists.': '- Durable delegation uses `agent-bridge task create --to <agent>`. True interrupts use `agent-bridge urgent <agent> "..."`. Always include enough context for the receiver to work from the queue alone.',
    '- **Telegram** – respond through Claude Code `--channels plugin:telegram@claude-plugins-official`. The plugin mimics the old `openclaw message send` behavior; you do not run that CLI anymore. If a job needs a Telegram nudge, craft the message inside Claude Code and let the plugin deliver it.': '- **Telegram** – respond through Claude Code `--channels plugin:telegram@claude-plugins-official`. If a job needs a Telegram nudge, craft it in the live session and let the plugin deliver it.',
    '- **Bridge queue** – when another agent asks you to do something, create a durable task rather than replying via `sessions_send`. Always include the full context so the queue consumer does not have to open the old gateway stacks.': '- **Bridge queue** – when another agent asks you to do something, create a durable task with enough context for the receiver to work from the queue alone.',
    '- 기존 `sessions_send` 기반 위임은 `agent-bridge task create --to <agent>`로 번역한다. durable delegation은 Bridge queue가 기본이다.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다. 긴급 인터럽트만 `agent-bridge urgent <agent> "..."`를 쓴다.',
    '- `openclaw message send`는 Claude Code CLI에서 직접 쓰지 않는다. Discord-connected coordinator session이 채널과 DM의 전달 경로다.': '- Discord 보고와 DM escalation은 연결된 coordinator 세션 안에서 직접 처리한다.',
    '- 예전 `sessions_send(timeoutSeconds=0)`의 의미는 "즉시 fan-out 후 나중에 수집"이었다. Bridge에서도 같은 프로젝트의 child task는 가능하면 한 burst로 만든다.': '- fan-out semantics는 유지한다: 같은 프로젝트의 child task는 가능하면 한 burst로 만들고, 결과는 수집 후 한 번만 보고한다.',
    '- Old `sessions_send` mail routing becomes `agent-bridge task create --to <agent>` with a full `[MAIL]`, `[SEND-MAIL]`, or `[REPLY-MAIL]` style payload.': '- 메일 라우팅과 회신 handoff는 `agent-bridge task create --to <agent>`로 보낸다. payload에는 `[MAIL]`, `[SEND-MAIL]`, `[REPLY-MAIL]` 맥락을 그대로 담는다.',
    '- Do not use `openclaw message send` directly. In Claude Code, a Discord-connected `mailbot` session is the channel surface.': '- 사람에게 보이는 Discord 상태 공유는 연결된 `mailbot` 세션 안에서 직접 처리한다.',
    '- Old `sessions_send` reporting becomes `agent-bridge task create --to <coordinator-agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <coordinator-agent>`를 사용한다.',
    '- Old `sessions_send` reports become `agent-bridge task create --to <coordinator-agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <coordinator-agent>`를 사용한다.',
    '- Old `sessions_send` reporting becomes `agent-bridge task create --to <agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` reports become `agent-bridge task create --to <agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` becomes `agent-bridge task create --to <agent>`.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` delegation becomes `agent-bridge task create --to <agent>`.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` handoffs become `agent-bridge task create --to <agent>`.': '- handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` consults become `agent-bridge task create --to <agent>`.': '- consult handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send`/`sessions_spawn` style QA orchestration becomes bridge tasks plus Claude subagent features only when explicitly needed inside Claude Code.': '- QA handoff는 bridge task를 기본으로 하고, 정말 필요할 때만 Claude-native subagent를 사용한다.',
    '- Keep executing scripted workloads (e.g., `morning-briefing.py`, `evening-digest.py`, `memory-daily-*`, `event-reminder-*`, `iran-crisis-monitor`) from `~/.openclaw/scripts/`. Keep track of their logs to track regressions.': '- recurring workflow는 bridge-managed cron family와 disposable-child run을 기준으로 본다. legacy helper가 아직 필요하면 실제 존재 여부를 확인한 뒤 compatibility 경로로만 다룬다.',
    '- Mention the regime of skills you still rely on: `agent-db`, `pinchtab`, `naver-maps`, `naver-search`, `openclaw-config`, `patch`, `agent-factory`. Flag `agent-factory` as gateway infrastructure to revisit later if / when it gets rebuilt.': '- Mention the bridge-local integrations you still rely on. If a dependency still lives outside `~/.agent-bridge/runtime`, call it out explicitly as migration debt instead of presenting it as a default tool.',
}


def replace_section(text: str, heading: str, replacement: str) -> str:
    pattern = rf"{re.escape(heading)}\n.*?(?=\n## |\Z)"
    return re.sub(pattern, replacement.strip() + "\n\n", text, flags=re.S)


def replace_section_range(text: str, start_heading: str, end_heading: str, replacement: str) -> str:
    pattern = rf"{re.escape(start_heading)}\n.*?(?=\n{re.escape(end_heading)}\n)"
    return re.sub(pattern, replacement.strip() + "\n\n", text, flags=re.S)


def rewrite_claude_legacy_text(agent_dir: Path, text: str) -> str:
    for old, new in COMMON_CLAUDE_REPLACEMENTS.items():
        text = text.replace(old, new)

    return text


def normalize_claude(agent_dir: Path, dry_run: bool, backup_root: Path) -> str | None:
    """Rewrite CLAUDE.md's managed block. Returns the change marker, or None.

    Return contract (#1816): None when nothing changed (so no-op apply runs
    deposit no backup); the CLAUDE.md path string when the block was rewritten;
    a `skipped-unbalanced:<path>` marker when the file's BEGIN/END markers are
    imbalanced. The caller records the returned marker in the apply summary.
    """
    claude_path = agent_dir / "CLAUDE.md"
    if not claude_path.exists():
        return None
    original = read_text(claude_path)

    # Issue #1816 — unbalanced-marker guard. `normalize` strips the old block
    # with the non-greedy `MANAGED_START.*?MANAGED_END` regex; if an END marker
    # was lost (hand edit / merge accident) the strip silently no-ops and a fresh
    # block would be prepended anyway → duplicated, contradictory blocks and
    # everything from the orphaned BEGIN onward treated as custom content
    # forever. Count the markers up front; on imbalance, refuse to rewrite and
    # report the file so the operator can fix it by hand rather than have the
    # engine corrupt it. (Balanced count == valid; 0/0 is a fresh file with no
    # block yet — allowed, the block is prepended below.)
    begin_count = len(re.findall(MANAGED_START_RE, original))
    end_count = original.count(MANAGED_END)
    if begin_count != end_count:
        return f"skipped-unbalanced:{claude_path}"

    normalized = re.sub(
        rf"{MANAGED_START_RE}.*?{re.escape(MANAGED_END)}\n*",
        "",
        original,
        flags=re.S,
    )
    normalized = normalize_legacy_paths(normalized)
    normalized = rewrite_claude_legacy_text(agent_dir, normalized)
    block = render_agent_bridge_block(agent_dir)
    if normalized.startswith("# "):
        first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        normalized = f"{first}\n\n{block}\n\n{rest.lstrip()}"
    else:
        normalized = f"{block}\n\n{normalized}"
    # Issue #1816 — changed-only backups. Render first, compare, and only
    # `backup_file` + write when the content actually changes. The old code
    # backed up on every apply pass (before computing the diff), so every cron-
    # driven no-op apply across an N-agent fleet deposited another timestamped
    # CLAUDE.md snapshot under state/doc-migration/backups/, growing unbounded.
    if normalized != original:
        backup_file(claude_path, backup_root, dry_run)
        write_text(claude_path, normalized, dry_run)
        return str(claude_path)
    return None


def render_agent_skills_md(agent_dir: Path, registry: dict[str, SkillEntry]) -> str:
    agent_name = agent_dir.name
    skill_files = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    shared_skills = [
        entry for entry in registry.values() if entry.kind == "shared" and entry.name in SHARED_CLAUDE_SKILL_NAMES
    ]
    mapped_runtime_skills = [
        entry for entry in registry.values() if entry.kind == "runtime" and agent_name in entry.target_agents
    ]
    lines = [
        f"# SKILLS.md — {agent_name}",
        "",
        "<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->",
        "",
        "## Runtime Skill Rules",
        _per_agent_skills_anchor_line(),
        "- local `skills/`가 있으면 해당 파일을 먼저 읽고 절차를 따른다.",
        "- 예전 외부 skill 경로는 compatibility note로만 본다. bridge-local 대체가 있으면 그쪽이 우선이다.",
        "",
        "## Shared Claude Skills",
    ]
    if shared_skills:
        for entry in shared_skills:
            lines.append(f"- `{entry.name}` — {entry.description}")
    else:
        lines.append("- shared Claude skills are not available")
    lines.extend(
        [
            "",
            "## Mapped Runtime Skills",
        ]
    )
    if mapped_runtime_skills:
        for entry in mapped_runtime_skills:
            entry_hint = f" (entry: `{entry.entry}`)" if entry.entry else ""
            lines.append(f"- `{entry.name}` — {entry.description}{entry_hint}")
    else:
        lines.append("- no runtime skills are mapped to this agent")
    lines.extend(
        [
            "",
            "## Local Inventory",
        ]
    )
    if skill_files:
        lines.extend([f"- `{entry}`" for entry in skill_files])
    else:
        lines.append("- local `skills/` 없음")
    if reference_files:
        lines.extend(["", "## References", *[f"- `{entry}`" for entry in reference_files]])
    return "\n".join(lines) + "\n"


def _shared_link_target(agent_dir: Path, shared_dir: Path, name: str) -> str:
    """Relative symlink target from `agent_dir` to `<shared_dir>/<name>`.

    Issue #1813: the old code hard-coded `../shared/<name>`, which only
    resolves at v1 depth (`agents/<agent>/` is one level below
    `<bridge_home>/shared/`). At v2 home depth
    (`data/agents/<agent>/home/`) the shared dir is three levels up, so
    the same string resolved to a non-existent `data/agents/<agent>/shared/`
    and the canon links never reached the home v2 sessions actually read.
    `os.path.relpath` computes the correct relative path at either depth.
    """
    return os.path.relpath(shared_dir / name, agent_dir)


def _resolves_to_shared_doc(path: Path, shared_dir: Path) -> str | None:
    """Return the shared-doc `<name>` a symlink resolves to, else None.

    Resolution-based intent check (#1813): follows the link's target
    (`os.path.realpath`, which resolves a broken link's intent lexically) and
    reports the `<name>` when it lands directly inside `<shared_dir>` on a `.md`
    file — regardless of whether the link was written absolute or relative, by
    the engine or by an operator. Callers gate on the returned name:
    `ensure_agent_shared_links` accepts a link only when the name matches the
    canon doc it is wiring; cleanup only deletes when the name is in the
    bridge-managed namespace, so a foreign operator link is never touched.
    """
    try:
        resolved = Path(os.path.realpath(path))
        shared_resolved = Path(os.path.realpath(shared_dir))
    except OSError:
        return None
    if resolved.parent != shared_resolved or resolved.suffix != ".md":
        return None
    return resolved.name


def ensure_agent_shared_links(
    agent_dir: Path, bridge_home: Path, dry_run: bool, backup_root: Path
) -> list[str]:
    changed: list[str] = []
    shared_dir = bridge_home / "shared"
    for name in AGENT_SHARED_LINKS:
        path = agent_dir / name
        target = _shared_link_target(agent_dir, shared_dir, name)
        # Accept an existing link as correct when it *resolves* to the
        # canonical shared file, regardless of representation (absolute or
        # relative, engine- or operator-seeded). This stops the next apply
        # from clobbering a correct absolute link back into a broken form.
        current_ok = path.is_symlink() and _resolves_to_shared_doc(path, shared_dir) == name
        if current_ok:
            continue
        if path.exists() or path.is_symlink():
            backup_file(path, backup_root, dry_run)
        ensure_symlink(path, target, dry_run)
        changed.append(str(path))
    return changed


def cleanup_broken_shared_doc_links(
    agent_dir: Path, bridge_home: Path, dry_run: bool, backup_root: Path
) -> list[str]:
    changed: list[str] = []
    shared_dir = bridge_home / "shared"
    for path in sorted(agent_dir.iterdir()):
        if not path.is_symlink() or path.name in AGENT_SHARED_LINKS:
            continue
        # A live link is not broken — leave it. Only consider broken links.
        if path.exists():
            continue
        # Resolution-based scoping (#1813): only remove a broken link whose
        # resolved intent is a doc the engine itself manages. The old name-based
        # `target.startswith("../shared/")` test deleted any broken `../shared/
        # *.md` link — including the exact artifact the engine mis-created at v2
        # depth — but it also could not tell a foreign operator link apart.
        # Resolving the broken target against `<shared_dir>` AND requiring the
        # resolved name to be in MANAGED_SHARED_DOC_NAMES keeps cleanup limited
        # to the engine's own namespace: an operator link such as
        # `OPERATOR-NOTE.md -> ../shared/OPERATOR-NOTE.md` resolves into shared
        # but is NOT a managed name, so it is preserved.
        resolved_name = _resolves_to_shared_doc(path, shared_dir)
        if resolved_name is None or resolved_name not in MANAGED_SHARED_DOC_NAMES:
            continue
        backup_file(path, backup_root, dry_run)
        if not dry_run:
            path.unlink()
        changed.append(f"removed:{path}")
    return changed


def sync_memory_schema_from_template(
    agent_dir: Path,
    bridge_home: Path,
    dry_run: bool,
    backup_root: Path,
) -> list[str]:
    """Legacy template-sync for MEMORY-SCHEMA.md, now symlink-clobber-guarded.

    Issue #1814 (DATA-LOSS): MEMORY-SCHEMA.md is now propagated from the canon
    doc (`docs/agent-runtime/memory-schema.md`) into `<bridge_home>/shared/` and
    symlinked into each home by `ensure_agent_shared_links` — which runs *before*
    this function in `sync_agent_docs`. So on a converged install the home file
    is a symlink that resolves to the shared canon body, and this legacy
    template-sync becomes a no-op (it refuses to touch a symlink; see below).

    The hard requirement this function now enforces is the **symlink-clobber
    guard**. `Path.write_bytes` follows symlinks. The canon doc's own header and
    the migration guide both describe a `MEMORY-SCHEMA.md -> docs/agent-runtime/
    memory-schema.md` (or `-> ../shared/MEMORY-SCHEMA.md`) symlink wiring. On any
    install wired that way, the previous `target.write_bytes(template_bytes)`
    would have followed the link and overwritten the *canonical* doc with the
    smaller template fork — fleet-wide, in a single `apply` pass. We now refuse
    to write through a symlink and leave the link (and its canon target)
    untouched. This guard is correct and worth holding even if the symlink
    wiring above is ever reverted.
    """
    changed: list[str] = []
    target = agent_dir / "MEMORY-SCHEMA.md"
    # DATA-LOSS GUARD (#1814): never write through a symlink. A symlinked
    # MEMORY-SCHEMA.md is the canon wiring (post-fix the expected state); writing
    # the template bytes through it would clobber whatever the link resolves to —
    # potentially the shared canon body or the canon doc itself. Leave it alone;
    # the canon body is already kept current by render_shared_memory_schema_md.
    if target.is_symlink():
        return changed
    template = bridge_home / "agents" / "_template" / "MEMORY-SCHEMA.md"
    if not template.exists() or not target.exists():
        return changed
    try:
        template_bytes = template.read_bytes()
    except OSError:
        return changed
    try:
        target_bytes = target.read_bytes()
    except OSError:
        return changed
    if template_bytes == target_bytes:
        return changed
    backup_file(target, backup_root, dry_run)
    if not dry_run:
        # Belt-and-suspenders: even past the is_symlink() gate above, write the
        # bytes via an explicit truncate-and-write on a freshly *unlinked* path
        # so a TOCTOU symlink swap between the check and the write cannot be
        # followed. (A plain `write_bytes` would re-follow a symlink planted in
        # the window.) Remove any existing plain file first, then create anew.
        if target.exists() or target.is_symlink():
            if target.is_symlink():
                # Re-check inside the write branch: a link appeared after the
                # guard — refuse rather than clobber its target.
                return changed
            target.unlink()
        target.write_bytes(template_bytes)
    changed.append(str(target))
    return changed


def sync_agent_docs(agent_dir: Path, bridge_home: Path, dry_run: bool, stamp: str, registry: dict[str, SkillEntry]) -> list[str]:
    changed: list[str] = []
    backup_root = bridge_home / "state" / "doc-migration" / "backups" / stamp / agent_dir.name

    changed.extend(cleanup_broken_shared_doc_links(agent_dir, bridge_home, dry_run, backup_root))
    changed.extend(ensure_agent_shared_links(agent_dir, bridge_home, dry_run, backup_root))
    changed.extend(sync_memory_schema_from_template(agent_dir, bridge_home, dry_run, backup_root))

    claude_change = normalize_claude(agent_dir, dry_run, backup_root)
    if claude_change is not None:
        # `claude_change` is either the rewritten CLAUDE.md path or a
        # `skipped-unbalanced:<path>` marker (#1816 unbalanced-marker guard);
        # both belong in the apply summary so the operator sees what happened.
        changed.append(claude_change)

    # Per-agent SKILLS.md is only emitted in legacy-catalog mode. In
    # plugin-routing/disabled, the per-agent file is removed (with backup)
    # so the boot ritual no longer points at a stale doc that contradicts
    # shared/skill-routing.md or `agb skills list`.
    skills_path = agent_dir / "SKILLS.md"
    if skills_doc_mode() == "legacy-catalog":
        skills_text = render_agent_skills_md(agent_dir, registry)
        old_skills = read_text(skills_path) if skills_path.exists() else None
        if old_skills != skills_text:
            if skills_path.exists():
                backup_file(skills_path, backup_root, dry_run)
            write_text(skills_path, skills_text, dry_run)
            changed.append(str(skills_path))
    else:
        if skills_path.exists() or skills_path.is_symlink():
            backup_file(skills_path, backup_root, dry_run)
            if dry_run:
                changed.append(f"removed:{skills_path}")
            else:
                # Codex r1 on PR #514: don't swallow unlink errors and
                # then claim the file was removed — the upgrade output
                # would lie. Let OSError propagate; the surrounding
                # apply path already treats unlink failures during
                # cleanup as fatal (matches DEPRECATED_SHARED_FILES
                # handling earlier in sync_shared_docs).
                skills_path.unlink()
                changed.append(f"removed:{skills_path}")

    for name in AGENT_RUNTIME_REWRITE_FILES:
        path = agent_dir / name
        if normalize_agent_runtime_file(path, agent_dir, dry_run, backup_root):
            changed.append(str(path))

    skills_root = agent_dir / "skills"
    if skills_root.exists():
        for path in sorted(skills_root.rglob("*.md")):
            if normalize_agent_runtime_file(path, agent_dir, dry_run, backup_root):
                changed.append(str(path))

    for name in REMOVABLE_DOCS:
        path = agent_dir / name
        if path.exists():
            backup_file(path, backup_root, dry_run)
            if not dry_run:
                path.unlink()
            changed.append(f"removed:{path}")

    return changed


def render_audit(audits: list[AgentAudit], bridge_home: Path, source_shared: Path) -> str:
    registry = build_skill_registry(bridge_home)
    shared_count = sum(1 for entry in registry.values() if entry.kind == "shared")
    runtime_count = sum(1 for entry in registry.values() if entry.kind == "runtime")
    mapped_count = sum(1 for entry in registry.values() if entry.kind == "runtime" and entry.target_agents)
    lines = [
        "# Agent Doc Audit",
        "",
        f"- bridge_home: `{pretty_path(bridge_home)}`",
        f"- source_shared: `{pretty_path(source_shared)}`",
        "",
        "## Summary",
        f"- agents: {len(audits)}",
        f"- removable legacy docs: {sum(len(audit.removable_docs) for audit in audits)}",
        f"- broken links: {sum(len(audit.broken_links) for audit in audits)}",
        f"- CLAUDE legacy hits: {sum(len(audit.claude_legacy_hits) for audit in audits)}",
        f"- shared skills discovered: {shared_count}",
        f"- runtime skills discovered: {runtime_count}",
        f"- runtime skills with explicit agent mapping: {mapped_count}",
        "",
    ]
    for audit in audits:
        lines.append(f"## {audit.agent}")
        if audit.removable_docs:
            lines.append(f"- removable: {', '.join(audit.removable_docs)}")
        if audit.broken_links:
            lines.append("- broken links:")
            lines.extend([f"  - {item}" for item in audit.broken_links])
        if audit.claude_legacy_hits:
            lines.append(f"- CLAUDE legacy hits: {', '.join(audit.claude_legacy_hits)}")
        if audit.local_skills:
            lines.append(f"- local skills: {', '.join(audit.local_skills)}")
        if audit.reference_files:
            lines.append(f"- references: {', '.join(audit.reference_files)}")
        if not any((audit.removable_docs, audit.broken_links, audit.claude_legacy_hits, audit.local_skills, audit.reference_files)):
            lines.append("- clean")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def parse_args() -> argparse.Namespace:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("audit", "apply"))
    parser.add_argument("agents", nargs="*")
    parser.add_argument("--all", action="store_true", dest="all_agents")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON summary (mode, agent_count, changed_paths) to stdout instead of the human report.",
    )
    parser.add_argument("--report", type=Path)
    parser.add_argument("--bridge-home", type=Path, default=bridge_home)
    parser.add_argument(
        "--target-root",
        type=Path,
        default=Path(os.environ.get("BRIDGE_AGENT_HOME_ROOT", str(bridge_home / "agents"))),
    )
    parser.add_argument(
        "--home-subdir",
        default="",
        help=(
            "Issue #1820: descend one level into each agent entry to reach the "
            "v2 per-agent home (e.g. 'home' selects <target-root>/<agent>/home). "
            "Empty (default) keeps the flat v1 layout <target-root>/<agent>."
        ),
    )
    parser.add_argument(
        "--source-shared",
        type=Path,
        default=Path(os.environ.get("BRIDGE_OPENCLAW_HOME", str(Path.home() / ".openclaw"))) / "shared",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    bridge_home = args.bridge_home.expanduser().resolve()
    target_root = args.target_root.expanduser().resolve()
    source_shared = args.source_shared.expanduser().resolve()
    registry = build_skill_registry(bridge_home)
    agent_dirs = list_agent_dirs(
        target_root, args.agents, args.all_agents, args.home_subdir
    )

    if args.command == "audit":
        audits = [audit_agent(agent_dir) for agent_dir in agent_dirs]
        report = render_audit(audits, bridge_home, source_shared)
        sys.stdout.write(report)
        if args.report:
            write_text(args.report, report, False)
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    registry_path, registry_changed = write_skill_registry(bridge_home, registry, args.dry_run)
    changed = [str(registry_path)] if registry_changed else []
    changed.extend(sync_shared_docs(bridge_home, source_shared, args.dry_run, stamp, registry))
    for agent_dir in agent_dirs:
        changed.extend(sync_agent_docs(agent_dir, bridge_home, args.dry_run, stamp, registry))

    audits = [audit_agent(agent_dir) for agent_dir in agent_dirs]
    if args.json:
        payload = {
            "mode": "dry-run" if args.dry_run else "apply",
            "agent_count": len(agent_dirs),
            "changed_paths": changed,
        }
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
        return 0

    report_lines = [
        "# Agent Doc Migration",
        "",
        f"- mode: {'dry-run' if args.dry_run else 'apply'}",
        f"- agents: {len(agent_dirs)}",
        f"- changed_paths: {len(changed)}",
        "",
        "## Changed",
    ]
    if changed:
        report_lines.extend([f"- `{item}`" for item in changed])
    else:
        report_lines.append("- no changes")
    report_lines.extend(["", render_audit(audits, bridge_home, source_shared).rstrip(), ""])
    report = "\n".join(report_lines)
    sys.stdout.write(report)
    if args.report:
        write_text(args.report, report, False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
