#!/usr/bin/env python3
"""Stop hook: invoke daily-note-reconcile.py for the current session jsonl.

Closes Gap 2 of #390 memory pipeline: when a Claude session ends, merge
its jsonl into the agent's daily note via the idempotent reconcile script
shipped in PR-1 (PR #449). Any failure is non-blocking — Stop hooks must
not break the operator's Claude session.

Settings.json wiring (PR-2 registers this in agents/_template/.claude/settings.json):

    {
      "Stop": [
        {
          "hooks": [{
            "type": "command",
            "command": "/usr/bin/python3 ~/.agent-bridge/hooks/session-stop.py",
            "timeout": 35
          }]
        }
      ]
    }

Timeout 35s = reconcile internal 30s + 5s setup overhead.

Env contract (set by bridge-run.sh / bridge-agent.sh / Claude Code):
- BRIDGE_AGENT_ID: required for memory-dir resolution.
- BRIDGE_HOME: required to locate scripts/ + agents/. Defaults to
  ``~/.agent-bridge`` when unset.
- BRIDGE_AGENT_WORKDIR: session cwd (matches the wrap-up.md convention)
  used to derive ``~/.claude/projects/<slug>/`` lookup. Defaults to the
  agent's bridge home when unset.
- BRIDGE_TRANSCRIPTS_HOME (optional): override for isolated UID jsonl
  location. See PR #426 Track C / wrap-up.md handling.
- CLAUDE_PROJECT_DIR (optional): Claude Code's transcript dir hint.

Resolution order for the session jsonl path:
1. Stop event stdin's ``transcript_path`` field — Claude Code passes the
   exact path of the jsonl it just wrote. This is the canonical source
   and avoids re-deriving the slug.
2. ``bridge-memory.py current-session-id`` + composed path under
   ``~/.claude/projects/<slug>/<sessionId>.jsonl`` (matches the wrap-up
   slash command convention exactly).

Exit codes:
- 0: reconcile succeeded OR fast-path no-op (prerequisites missing).
- 0 even on reconcile failure (logged to stderr; non-blocking).

Why exit 0 always: a Stop hook that exits non-zero is treated by Claude
Code as a hook error and surfaces a banner to the operator. Memory
reconcile failure is recoverable on next Stop / cron tick; we don't
want to spam the operator with banners.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def _bridge_home() -> Path | None:
    """Resolve the bridge home, or None when the hook should fast-path no-op.

    Resolution order:
    1. BRIDGE_HOME env — explicit operator opt-in. Returned as-is.
    2. <script>/.. fallback — only when that location actually looks like a
       bridge home (contains both scripts/ and agents/). This preserves the
       hook's resilience when invoked under the standard install layout
       (~/.agent-bridge/hooks/session-stop.py) without requiring the env
       var to be set, while refusing to invoke reconcile from arbitrary
       locations (e.g., a source checkout dir, a test fixture). See codex
       r1 review on PR #450.

    Returning None signals main() to fast-path return 0.
    """
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        return Path(env_home).expanduser()
    fallback = Path(__file__).resolve().parent.parent
    if (fallback / "scripts").is_dir() and (fallback / "agents").is_dir():
        return fallback
    return None


def _agent_workdir(bridge_home: Path, agent_id: str) -> Path:
    """Resolve the session workdir used for the ~/.claude/projects/<slug>/ lookup.

    Mirrors the wrap-up.md convention: BRIDGE_AGENT_WORKDIR overrides;
    otherwise the agent's bridge home is used.
    """
    raw = os.environ.get("BRIDGE_AGENT_WORKDIR")
    if raw:
        return Path(raw).expanduser()
    return bridge_home / "agents" / agent_id


def _stop_event_payload() -> dict:
    """Read the Claude Code Stop event JSON payload from stdin.

    Claude Code passes hook metadata as JSON on stdin; for Stop hooks the
    payload contains ``transcript_path`` (jsonl) plus a few session
    fields. Tolerate empty / non-JSON stdin so manual invocations still
    behave (return {}).
    """
    if sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.read() or ""
    except (OSError, ValueError):
        return {}
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _jsonl_from_event(event: dict) -> Path | None:
    raw = event.get("transcript_path")
    if not isinstance(raw, str) or not raw:
        return None
    return Path(raw).expanduser()


def _resolve_session_jsonl_via_helper(
    agent_id: str,
    bridge_home: Path,
) -> Path | None:
    """Fallback path: ask bridge-memory.py current-session-id for the
    session uuid, then compose ``~/.claude/projects/<slug>/<sessionId>.jsonl``.

    Mirrors the agents/_template/.claude/commands/wrap-up.md convention
    so the resolution stays consistent with the rest of the runtime.

    Returns None on any failure (no jsonl, helper missing, no project
    dir, etc.). Errors are logged to stderr but never raised.
    """
    helper = bridge_home / "bridge-memory.py"
    if not helper.is_file():
        print(
            "[session-stop] bridge-memory.py missing; skipping reconcile",
            file=sys.stderr,
        )
        return None

    workdir = _agent_workdir(bridge_home, agent_id)
    transcripts_home = os.environ.get("BRIDGE_TRANSCRIPTS_HOME")

    cmd = [
        sys.executable or "python3",
        str(helper),
        "current-session-id",
        "--agent", agent_id,
        "--home", str(workdir),
    ]
    if transcripts_home:
        cmd += ["--transcripts-home", transcripts_home]

    try:
        result = subprocess.run(
            cmd, check=True, capture_output=True, text=True, timeout=10,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        print(
            f"[session-stop] no session-id ({type(exc).__name__}); "
            "skipping reconcile",
            file=sys.stderr,
        )
        return None
    session_id = (result.stdout or "").strip()
    if not session_id:
        return None

    # Compose the project-dir slug exactly like
    # bridge-memory.cmd_current_session_id does (str(workdir).replace(sep,
    # '-').replace('.', '-')). The slug is rooted under the resolved
    # transcripts home — either the explicit override or $HOME.
    workdir_resolved = workdir.resolve()
    slug = str(workdir_resolved).replace(os.sep, "-").replace(".", "-")

    if transcripts_home:
        override = Path(transcripts_home).expanduser()
        if override.name == "projects" and override.parent.name == ".claude":
            projects_dir = override
        else:
            projects_dir = override / ".claude" / "projects"
    else:
        # CLAUDE_PROJECT_DIR is the Claude Code session-set hint that
        # points at the parent ``projects`` dir; honour it before the
        # ``$HOME`` default.
        claude_project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
        if claude_project_dir:
            projects_dir = Path(claude_project_dir).expanduser()
        else:
            projects_dir = Path.home() / ".claude" / "projects"

    return projects_dir / slug / f"{session_id}.jsonl"


def resolve_session_jsonl(
    event: dict,
    agent_id: str,
    bridge_home: Path,
) -> Path | None:
    """Resolve the jsonl Claude just wrote for this Stop event.

    Order:
    1. ``transcript_path`` from the Stop event stdin payload (canonical).
    2. ``bridge-memory.py current-session-id`` + composed slug path
       (mirrors wrap-up.md so the fallback matches convention).
    """
    event_path = _jsonl_from_event(event)
    if event_path is not None:
        return event_path
    return _resolve_session_jsonl_via_helper(agent_id, bridge_home)


def main() -> int:
    try:
        agent_id = os.environ.get("BRIDGE_AGENT_ID", "").strip()
        if not agent_id:
            return 0  # fast-path: not in a bridge agent context.

        bridge_home = _bridge_home()
        if bridge_home is None or not bridge_home.is_dir():
            # Fast-path no-op: BRIDGE_HOME unset AND fallback not recognizable
            # as a bridge home (no scripts/ + agents/ siblings). See #390 PR-2
            # codex r1 — this prevents reconcile from being launched in an
            # unexpected location when the hook is invoked outside the
            # standard install layout.
            return 0

        reconcile = bridge_home / "scripts" / "daily-note-reconcile.py"
        if not reconcile.is_file():
            # Older install without PR-1 shipped: skip cleanly.
            print(
                "[session-stop] daily-note-reconcile.py missing; skipping",
                file=sys.stderr,
            )
            return 0

        event = _stop_event_payload()
        jsonl = resolve_session_jsonl(event, agent_id, bridge_home)
        if jsonl is None or not jsonl.is_file():
            print(
                f"[session-stop] no current jsonl for agent={agent_id}; "
                "skipping",
                file=sys.stderr,
            )
            return 0

        cmd = [
            sys.executable or "python3",
            str(reconcile),
            "--agent", agent_id,
            "--jsonl", str(jsonl),
        ]
        try:
            subprocess.run(cmd, check=True, timeout=30)
        except subprocess.CalledProcessError as exc:
            print(
                f"[session-stop] reconcile failed (rc={exc.returncode}); "
                "non-blocking",
                file=sys.stderr,
            )
        except subprocess.TimeoutExpired:
            print(
                "[session-stop] reconcile timed out (30s); non-blocking",
                file=sys.stderr,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            print(
                f"[session-stop] reconcile invoke failed "
                f"({type(exc).__name__}); non-blocking",
                file=sys.stderr,
            )
    except Exception as exc:  # pragma: no cover — defensive belt-and-braces
        # Stop hook MUST exit 0. Swallow any unexpected error after
        # logging a breadcrumb so the operator can still see it.
        print(
            f"[session-stop] unexpected error ({type(exc).__name__}); "
            "non-blocking",
            file=sys.stderr,
        )
    return 0  # always 0 — Stop hook must not break session


if __name__ == "__main__":
    raise SystemExit(main())
