#!/usr/bin/env python3
"""bridge-watchdog.py — scan bridge-owned agent homes for drift and onboarding gaps."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"
REQUIRED_FILES = ("CLAUDE.md", "SOUL.md", "MEMORY-SCHEMA.md", "MEMORY.md", "SESSION-TYPE.md")


@dataclass
class AgentWatch:
    agent: str
    session_type: str
    onboarding_state: str
    status: str
    missing_files: list[str]
    broken_links: list[str]
    missing_managed_claude_block: bool
    heartbeat_present: bool
    heartbeat_age_seconds: int | None


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def list_agent_dirs(root: Path, selected: list[str]) -> list[Path]:
    if not root.exists():
        return []
    paths = []
    selected_set = set(selected)
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        if selected and path.name not in selected_set:
            continue
        paths.append(path)
    return paths


def collect_broken_links(agent_dir: Path) -> list[str]:
    broken = []
    for path in agent_dir.rglob("*"):
        if path.is_symlink() and not path.exists():
            broken.append(f"{path.relative_to(agent_dir)} -> {os.readlink(path)}")
    return broken


def parse_session_type(agent_dir: Path) -> tuple[str, str]:
    session_type = "unknown"
    onboarding_state = "missing"
    path = agent_dir / "SESSION-TYPE.md"
    if not path.exists():
        return session_type, onboarding_state
    text = read_text(path)
    session_match = re.search(r"Session Type:\s*([A-Za-z0-9._-]+)", text)
    onboarding_match = re.search(r"Onboarding State:\s*([A-Za-z0-9._-]+)", text)
    if session_match:
        session_type = session_match.group(1).strip()
    if onboarding_match:
        onboarding_state = onboarding_match.group(1).strip()
    return session_type, onboarding_state


def heartbeat_age_seconds(agent_dir: Path) -> tuple[bool, int | None]:
    path = agent_dir / "HEARTBEAT.md"
    if not path.exists():
        return False, None
    age = int(datetime.now(timezone.utc).timestamp() - path.stat().st_mtime)
    return True, max(age, 0)


# Session types that have no interactive first-session onboarding flow by
# design (see #241). `dynamic` agents are auto-provisioned promote-only /
# task-drain workers such as `librarian`; `cron` agents are scheduler-
# launched and never see a human. Leaving SESSION-TYPE.md at
# `Onboarding State: pending` is the steady-state for these classes, so
# flagging them as `warn` creates alert-fatigue on every scan.
NON_ONBOARDING_SESSION_TYPES = frozenset({"dynamic", "cron"})


def classify_status(
    missing_files: list[str],
    broken_links: list[str],
    onboarding_state: str,
    missing_block: bool,
    session_type: str = "",
) -> str:
    if missing_files:
        return "error"
    onboarding_stale = (
        onboarding_state in {"pending", "missing"}
        and session_type not in NON_ONBOARDING_SESSION_TYPES
    )
    if broken_links or missing_block or onboarding_stale:
        return "warn"
    return "ok"


def scan_agent(agent_dir: Path) -> AgentWatch:
    # v0.8.8 #715-B / #694: linux-user-isolated agents own
    # `agents/<name>/CLAUDE.md` as `agent-bridge-<name>:<group> 0640`.
    # When the controller process credentials don't include the new
    # group (typical post-migration / post-relogin window), `.exists()`
    # / `.read_text()` on that path raise `PermissionError` and the
    # outer list-comprehension in `main()` propagates the exception —
    # one isolated agent kills the whole watchdog walk and every other
    # agent's row stays stale. Same shape PR #688 handled in
    # `bridge-status.py::pending_upgrade_conflict_count` and PR #695's
    # follow-up `workdir_display`. Wrap the per-agent scan so the row
    # downgrades to a `warn` placeholder and the outer walk continues
    # for the rest of the roster. Missing-files / heartbeat / broken-
    # links fields default to "empty" because we genuinely don't know
    # — surfacing the `permission denied during scan` note on the
    # `broken_links` channel keeps the existing markdown render
    # unchanged (no new `AgentWatch` fields, per spec).
    try:
        missing_files = [name for name in REQUIRED_FILES if not (agent_dir / name).exists()]
        claude_text = read_text(agent_dir / "CLAUDE.md") if (agent_dir / "CLAUDE.md").exists() else ""
        missing_block = MANAGED_START not in claude_text or MANAGED_END not in claude_text
        session_type, onboarding_state = parse_session_type(agent_dir)
        heartbeat_present, heartbeat_age = heartbeat_age_seconds(agent_dir)
        broken_links = collect_broken_links(agent_dir)
        status = classify_status(missing_files, broken_links, onboarding_state, missing_block, session_type)
        return AgentWatch(
            agent=agent_dir.name,
            session_type=session_type,
            onboarding_state=onboarding_state,
            status=status,
            missing_files=missing_files,
            broken_links=broken_links,
            missing_managed_claude_block=missing_block,
            heartbeat_present=heartbeat_present,
            heartbeat_age_seconds=heartbeat_age,
        )
    except (PermissionError, FileNotFoundError) as exc:
        print(
            f"[bridge-watchdog] skipped {agent_dir.name}: "
            f"{type(exc).__name__} during scan ({exc.strerror or exc}); "
            f"likely isolated agent unreadable to controller",
            file=sys.stderr,
        )
        return AgentWatch(
            agent=agent_dir.name,
            session_type="unknown",
            onboarding_state="unknown",
            status="warn",
            missing_files=[],
            broken_links=[f"permission denied during scan: {type(exc).__name__}"],
            missing_managed_claude_block=False,
            heartbeat_present=False,
            heartbeat_age_seconds=None,
        )


def render_markdown(records: list[AgentWatch], bridge_home: Path) -> str:
    now_iso = datetime.now().astimezone().isoformat()
    problems = [item for item in records if item.status != "ok"]
    lines = [
        "# Watchdog Report",
        "",
        f"- generated_at: {now_iso}",
        f"- bridge_home: {bridge_home}",
        f"- agents: {len(records)}",
        f"- problems: {len(problems)}",
        "",
    ]
    if not records:
        lines.append("- no agents scanned")
        return "\n".join(lines) + "\n"
    for item in records:
        lines.append(f"## {item.agent}")
        lines.append(f"- status: {item.status}")
        lines.append(f"- session_type: {item.session_type}")
        lines.append(f"- onboarding_state: {item.onboarding_state}")
        lines.append(f"- heartbeat_present: {'yes' if item.heartbeat_present else 'no'}")
        if item.heartbeat_age_seconds is not None:
            lines.append(f"- heartbeat_age_seconds: {item.heartbeat_age_seconds}")
        if item.missing_files:
            lines.append(f"- missing_files: {', '.join(item.missing_files)}")
        if item.broken_links:
            lines.append("- broken_links:")
            lines.extend(f"  - {entry}" for entry in item.broken_links)
        if item.missing_managed_claude_block:
            lines.append("- missing_managed_claude_block: yes")
        if item.status == "ok":
            lines.append("- issues: none")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("scan",))
    parser.add_argument("agents", nargs="*")
    parser.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    parser.add_argument("--agent-home-root", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    bridge_home = Path(args.bridge_home).expanduser()
    agent_root = Path(args.agent_home_root).expanduser() if args.agent_home_root else bridge_home / "agents"
    records = [scan_agent(path) for path in list_agent_dirs(agent_root, args.agents)]
    payload = {
        "generated_at": datetime.now().astimezone().isoformat(),
        "bridge_home": str(bridge_home),
        "agent_home_root": str(agent_root),
        "agent_count": len(records),
        "problem_count": sum(1 for item in records if item.status != "ok"),
        "agents": [asdict(item) for item in records],
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_markdown(records, bridge_home), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
