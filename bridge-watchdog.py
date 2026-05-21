#!/usr/bin/env python3
"""bridge-watchdog.py — scan bridge-owned agent homes for drift and onboarding gaps."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"
# Claude-runtime profile files. Codex agents don't read these — see #905.
CLAUDE_REQUIRED_FILES = ("CLAUDE.md", "SOUL.md", "MEMORY-SCHEMA.md", "MEMORY.md", "SESSION-TYPE.md")
# Backward-compat alias: legacy callers / tests reference REQUIRED_FILES.
REQUIRED_FILES = CLAUDE_REQUIRED_FILES


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
    # Provenance from the registry payload. `engine` defaults to "claude"
    # when the registry lookup is unavailable so legacy listing-only mode
    # continues to assert the Claude-profile set (no regression for
    # pre-#905 installs). `agent_source` defaults to "" (unknown) so the
    # #907 fresh-provision suppression only activates when the registry
    # explicitly tags the agent as dynamic.
    engine: str = "claude"
    agent_source: str = ""


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


# Directory basenames under $BRIDGE_AGENT_HOME_ROOT that are bridge-managed
# infrastructure rather than per-agent homes; the watchdog skips them.
# Mirrors bridge-doctor.py:ORPHAN_SKIP_NAMES — keep the two lists in lockstep.
WATCHDOG_SKIP_NAMES = frozenset({"_template", "shared"})


# Registry-provenance map shared between the loader and the scan loop.
# Keys are agent ids (basename of `agents/<name>`); values are dicts with
# the subset of registry fields the watchdog needs:
#   - "engine":       "claude" | "codex" | ""
#   - "agent_source": "static" | "dynamic" | ""
# A dedicated type alias keeps the signatures readable without dragging
# the whole registry schema into the watchdog.
RegistryMeta = dict[str, dict[str, str]]


def list_agent_dirs(
    root: Path,
    selected: list[str],
    registry_ids: set[str] | None = None,
) -> tuple[list[Path], list[str]]:
    """Enumerate per-agent home directories to scan.

    Returns (scan_paths, orphan_names).

    When ``registry_ids`` is provided (registry-anchored mode, default), only
    directories whose basename appears in the registry are scanned. Directories
    on disk that are not in the registry are returned in ``orphan_names`` so
    the caller can surface them under a separate ``orphan_directories`` alert
    bucket — they no longer drive ``profile_drift`` warns (refs queue #4796).

    When ``registry_ids`` is ``None``, every directory is scanned (legacy
    behavior, used only when the caller passes ``--no-registry-anchored``).

    When ``selected`` is non-empty, both filters defer to the explicit
    selection so ``agent-bridge watchdog scan <agent>`` keeps working even
    if the registry lookup failed.
    """
    if not root.exists():
        return [], []
    paths: list[Path] = []
    orphans: list[str] = []
    selected_set = set(selected)
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in WATCHDOG_SKIP_NAMES:
            continue
        if selected:
            if path.name in selected_set:
                paths.append(path)
            continue
        if registry_ids is not None and path.name not in registry_ids:
            orphans.append(path.name)
            continue
        paths.append(path)
    return paths, orphans


def load_registry_agent_ids(
    args: argparse.Namespace,
    bridge_home: Path,
) -> tuple[set[str] | None, RegistryMeta]:
    """Return ``(ids, meta)`` from ``agent registry --json``.

    ``ids`` is the set of registered agent ids used to anchor the directory
    enumeration. ``meta`` is a per-id provenance map (``engine`` +
    ``agent_source``) consumed by the scan loop to apply the engine-aware
    profile check (#905) and the dynamic-agent fresh-state suppression (#907).

    Returns ``(None, {})`` when registry-anchoring is disabled or the lookup
    fails; the caller falls back to the legacy listing-only mode in that case
    so the watchdog never goes silent because of a broken registry endpoint.
    The empty meta map then makes every agent default to ``engine=claude``
    (preserving pre-#905 behavior) and ``agent_source=""`` (so #907's
    dynamic-only suppression is never accidentally triggered for unknown
    provenance).

    Tests inject ``--agent-registry-json <file>`` to skip the subprocess; the
    file shape mirrors ``bridge-doctor.py`` (JSON array of objects with an
    ``id`` field, optionally ``engine`` + ``agent_source``) so the same
    fixtures work for both detectors.
    """
    if args.agent_registry_json:
        path = Path(args.agent_registry_json).expanduser()
        if not path.is_file():
            print(
                f"[bridge-watchdog] --agent-registry-json file not found: {path}",
                file=sys.stderr,
            )
            return None, {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(
                f"[bridge-watchdog] --agent-registry-json unreadable ({exc}); "
                "falling back to listing-only enumeration",
                file=sys.stderr,
            )
            return None, {}
        return _registry_ids_from_payload(data)

    binary = args.agent_bridge or os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip()
    if not binary:
        sibling = Path(__file__).resolve().parent / "agent-bridge"
        if sibling.is_file():
            binary = str(sibling)
        else:
            located = shutil.which("agent-bridge")
            if not located:
                print(
                    "[bridge-watchdog] agent-bridge binary not found; "
                    "falling back to listing-only enumeration",
                    file=sys.stderr,
                )
                return None, {}
            binary = located
    env = os.environ.copy()
    env["BRIDGE_HOME"] = str(bridge_home)
    try:
        proc = subprocess.run(
            [binary, "agent", "registry", "--json"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        stderr = getattr(exc, "stderr", "") or ""
        print(
            f"[bridge-watchdog] agent registry --json failed ({type(exc).__name__}: "
            f"{stderr.strip() or exc}); falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        print(
            f"[bridge-watchdog] agent registry --json returned invalid JSON ({exc}); "
            "falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    return _registry_ids_from_payload(data)


def _registry_ids_from_payload(
    data: object,
) -> tuple[set[str] | None, RegistryMeta]:
    if not isinstance(data, list):
        print(
            "[bridge-watchdog] agent registry payload is not a JSON array; "
            "falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    ids: set[str] = set()
    meta: RegistryMeta = {}
    for row in data:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or "").strip()
        if not agent_id:
            continue
        ids.add(agent_id)
        # Surface engine + agent_source so the scan loop can apply the
        # engine-aware profile check (#905) and the dynamic-agent
        # fresh-state suppression (#907). Missing fields → empty string;
        # the scan loop maps empty engine → "claude" (legacy behavior)
        # and empty source → no #907 suppression (conservative).
        meta[agent_id] = {
            "engine": str(row.get("engine") or "").strip(),
            "agent_source": str(row.get("agent_source") or "").strip(),
        }
    return ids, meta


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


# Engines with no Claude-runtime profile contract at the agent home root
# — none of these CLIs read CLAUDE.md / SOUL.md / SESSION-TYPE.md, so the
# watchdog must not assert profile drift on them. This is an explicit
# allowlist, NOT "anything that isn't claude": a genuinely unknown engine
# string stays under the conservative Claude-default contract so a new
# engine surfaces as drift (prompting a watchdog update) instead of
# silently skipping the check. Add a new exempt engine here.
NON_CONTRACT_ENGINES = frozenset({"codex", "antigravity"})


def has_home_profile_contract(engine: str, agent_source: str) -> bool:
    """Whether the watchdog should hold this agent to the Claude-style
    home-profile contract: the ``CLAUDE_REQUIRED_FILES`` set, the managed
    ``CLAUDE.md`` block, and the ``SESSION-TYPE.md`` onboarding state.

    Issues #905 / #907 each special-cased one slice of this — codex was
    exempted from required files, the managed block, and onboarding;
    dynamic agents were exempted from the managed block. A third engine
    (``antigravity``, v0.14.5) then fell through to the Claude default and
    surfaced as a false ``status=error`` on every scan, because none of
    those three call sites knew about it. This predicate is the single
    gate so a known exempt engine is exempt by construction.

    The contract holds for:

      - Claude agents, static or unknown-source.
      - Any *unknown* engine string, static or unknown-source — the
        conservative legacy default (#905). An unknown engine is held to
        the contract so it surfaces as drift; the fix is to add it to
        ``NON_CONTRACT_ENGINES`` once the watchdog is taught about it.

    The contract is waived for:

      - ``agent_source == "dynamic"`` — a full exemption regardless of
        engine. Dynamic agents are ad-hoc spawns
        (``agent-bridge --<engine> --name``) that never run
        ``bridge_scaffold_agent_home``, so legitimately have no profile
        files, no managed block, and no SESSION-TYPE.md. The watchdog has
        no finer "scaffolded vs ad-hoc" signal than ``agent_source``.
      - The known non-Claude engines in ``NON_CONTRACT_ENGINES``.
    """
    if agent_source == "dynamic":
        return False
    return engine not in NON_CONTRACT_ENGINES


def required_profile_files(engine: str, agent_source: str = "") -> tuple[str, ...]:
    """Required profile-file set for an agent.

    Returns ``CLAUDE_REQUIRED_FILES`` only for agents under the
    home-profile contract (see :func:`has_home_profile_contract`); every
    other agent returns an empty tuple so the missing-files check is a
    no-op. ``agent_source`` defaults to ``""`` so a legacy positional
    ``required_profile_files(engine)`` call keeps the conservative
    Claude-default behavior for an unknown source.
    """
    if has_home_profile_contract(engine, agent_source):
        return CLAUDE_REQUIRED_FILES
    return ()


def classify_status(
    missing_files: list[str],
    broken_links: list[str],
    onboarding_state: str,
    missing_block: bool,
    session_type: str = "",
    agent_source: str = "",
    engine: str = "claude",
) -> str:
    # All three drift signals — missing required files, managed-block,
    # onboarding staleness — are gated on the home-profile contract (see
    # has_home_profile_contract). Known non-Claude engines have no
    # SESSION-TYPE.md / managed-CLAUDE.md / required-file contract (#905,
    # originally codex only — now also antigravity), and dynamic agents
    # are ad-hoc spawns that legitimately land with
    # `missing_managed_claude_block=yes` and `onboarding_state=pending`
    # until their first run; flagging any of these is admin alert-fatigue
    # for a condition admin cannot resolve (#907, #303/#304/#343
    # anti-pattern). missing_files is gated here too so classify_status is
    # internally consistent and does not depend on the caller having
    # pre-emptied `required` via required_profile_files.
    contract = has_home_profile_contract(engine, agent_source)
    if missing_files and contract:
        return "error"
    onboarding_stale = (
        contract
        and onboarding_state in {"pending", "missing"}
        and session_type not in NON_ONBOARDING_SESSION_TYPES
    )
    effective_missing_block = missing_block if contract else False
    if broken_links or effective_missing_block or onboarding_stale:
        return "warn"
    return "ok"


def scan_agent(
    agent_dir: Path,
    engine: str = "claude",
    agent_source: str = "",
) -> AgentWatch:
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
        required = required_profile_files(engine, agent_source)
        missing_files = [name for name in required if not (agent_dir / name).exists()]
        # The `missing_managed_claude_block` FIELD records actual file
        # state, so it is gated on engine alone, NOT the contract: any
        # engine that could own a CLAUDE.md (Claude + unknown engines —
        # same conservative set as the contract) gets a truthful field;
        # the known non-Claude engines in NON_CONTRACT_ENGINES definitively
        # don't own one. A dynamic Claude agent still gets an accurate
        # field — #907 keeps the field truthful and suppresses only the
        # classification *signal*, which classify_status gates through
        # has_home_profile_contract.
        if engine not in NON_CONTRACT_ENGINES:
            claude_text = read_text(agent_dir / "CLAUDE.md") if (agent_dir / "CLAUDE.md").exists() else ""
            missing_block = MANAGED_START not in claude_text or MANAGED_END not in claude_text
        else:
            missing_block = False
        session_type, onboarding_state = parse_session_type(agent_dir)
        heartbeat_present, heartbeat_age = heartbeat_age_seconds(agent_dir)
        broken_links = collect_broken_links(agent_dir)
        status = classify_status(
            missing_files,
            broken_links,
            onboarding_state,
            missing_block,
            session_type,
            agent_source,
            engine,
        )
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
            engine=engine or "claude",
            agent_source=agent_source,
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
            engine=engine or "claude",
            agent_source=agent_source,
        )


def render_markdown(
    records: list[AgentWatch],
    bridge_home: Path,
    orphan_directories: list[str] | None = None,
) -> str:
    now_iso = datetime.now().astimezone().isoformat()
    problems = [item for item in records if item.status != "ok"]
    orphan_directories = orphan_directories or []
    lines = [
        "# Watchdog Report",
        "",
        f"- generated_at: {now_iso}",
        f"- bridge_home: {bridge_home}",
        f"- agents: {len(records)}",
        f"- problems: {len(problems)}",
        f"- orphan_directories: {len(orphan_directories)}",
        "",
    ]
    if orphan_directories:
        # Refs queue #4796: orphan dirs (smoke leaks, manual mkdir) used to
        # surface as profile_drift warns when the watchdog enumerated
        # `agents/` directly. Surface them under a separate bucket so
        # operators can triage with `agent-bridge doctor --detectors
        # orphan-agent-dir` instead of treating them as live-agent drift.
        lines.append("## orphan_directories")
        lines.extend(f"- {name}" for name in orphan_directories)
        lines.append("")
    if not records:
        lines.append("- no agents scanned")
        return "\n".join(lines) + "\n"
    for item in records:
        lines.append(f"## {item.agent}")
        lines.append(f"- status: {item.status}")
        lines.append(f"- engine: {item.engine}")
        if item.agent_source:
            lines.append(f"- agent_source: {item.agent_source}")
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
    # Refs queue #4796: registry-anchored enumeration is the default. Orphan
    # directories under $BRIDGE_AGENT_HOME_ROOT no longer drive profile_drift
    # warns; they surface in the separate `orphan_directories` bucket. Pass
    # --no-registry-anchored to restore the legacy listing-only behavior
    # (every dir is scanned as if it were a registered agent).
    parser.add_argument(
        "--registry-anchored",
        dest="registry_anchored",
        action="store_true",
        default=True,
        help="enumerate agents from `agent registry --json` (default)",
    )
    parser.add_argument(
        "--no-registry-anchored",
        dest="registry_anchored",
        action="store_false",
        help="legacy listing-only enumeration (scan every dir under agents/)",
    )
    parser.add_argument(
        "--agent-bridge",
        default=None,
        help="path to the agent-bridge binary used for the registry query",
    )
    parser.add_argument(
        "--agent-registry-json",
        default=None,
        help="path to a JSON file with the registry payload (test injection)",
    )
    args = parser.parse_args()

    bridge_home = Path(args.bridge_home).expanduser()
    agent_root = Path(args.agent_home_root).expanduser() if args.agent_home_root else bridge_home / "agents"
    registry_ids: set[str] | None = None
    registry_meta: RegistryMeta = {}
    if args.registry_anchored:
        # Explicit agent args bypass the registry id filter (so the
        # operator can still scope-scan a single agent even when the
        # registry endpoint is broken), but we still consult the registry
        # for engine + agent_source metadata so #905 / #907 fixes apply
        # to scoped scans too.
        registry_ids, registry_meta = load_registry_agent_ids(args, bridge_home)
        if args.agents:
            # Disable the id filter; keep the meta map.
            registry_ids = None
    scan_paths, orphan_directories = list_agent_dirs(agent_root, args.agents, registry_ids)
    records = [
        scan_agent(
            path,
            engine=(registry_meta.get(path.name, {}).get("engine") or "claude"),
            agent_source=registry_meta.get(path.name, {}).get("agent_source", ""),
        )
        for path in scan_paths
    ]
    payload = {
        "generated_at": datetime.now().astimezone().isoformat(),
        "bridge_home": str(bridge_home),
        "agent_home_root": str(agent_root),
        "agent_count": len(records),
        "problem_count": sum(1 for item in records if item.status != "ok"),
        "orphan_directory_count": len(orphan_directories),
        "orphan_directories": orphan_directories,
        "agents": [asdict(item) for item in records],
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_markdown(records, bridge_home, orphan_directories), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
