#!/usr/bin/env python3
"""Agent Bridge PreCompact hook — captures a lightweight session dump.

Claude Code fires this event right before `/compact` or an auto-compact
compresses the conversation. The hook writes a capture note so the
short-term memory thread survives the compaction. Failures are swallowed
and the hook always exits 0 — compaction must never be blocked.

Settings.json wiring (installed by bridge-hooks.py ensure-pre-compact-hook):

    {
      "PreCompact": [
        {
          "hooks": [{
            "type": "command",
            "command": "python3 <BRIDGE_HOME>/hooks/pre-compact.py",
            "timeout": 20
          }]
        }
      ]
    }
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Allow `from bridge_hook_common import …` even when this hook is invoked
# from `~/.agent-bridge/hooks/pre-compact.py` (the live-runtime layout
# Claude Code wires through settings.json). bridge_hook_common.py sits
# next to this file in both the source tree and the deployed runtime.
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import (
        compact_recovery_enabled,
        gather_canonical_files,
        write_compact_snapshot,
    )
except ImportError:  # pragma: no cover — keep pre-compact resilient if
    # bridge_hook_common is missing (e.g. hooks/ is partially deployed).
    compact_recovery_enabled = None  # type: ignore[assignment]
    gather_canonical_files = None  # type: ignore[assignment]
    write_compact_snapshot = None  # type: ignore[assignment]


def _bridge_home() -> Path:
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        return Path(env_home)
    # Hook scripts live at <bridge-home>/hooks/. Walk up.
    return Path(__file__).resolve().parent.parent


def _agent_id() -> str:
    return (os.environ.get("BRIDGE_AGENT_ID") or "").strip()


def _agent_home() -> Path | None:
    env_home = os.environ.get("BRIDGE_AGENT_HOME")
    if env_home:
        return Path(env_home)
    agent = _agent_id()
    if not agent:
        return None
    candidate = _bridge_home() / "agents" / agent
    return candidate if candidate.exists() else None


def _stdin_payload() -> dict:
    """Claude Code passes hook metadata as JSON on stdin (trigger, custom instructions, etc)."""
    if sys.stdin.isatty():
        return {}
    raw = sys.stdin.read() or ""
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _capture_canonical_snapshot(agent: str) -> str:
    """Persist a pre-compact snapshot of the canonical agent files.

    Returns the snapshot path as a string for inclusion in the bridge-memory
    capture text (so an operator running `bridge-memory search` can locate
    the sidecar later). Empty string when the feature is disabled or the
    helpers from bridge_hook_common are unavailable.
    """
    if compact_recovery_enabled is None or gather_canonical_files is None or write_compact_snapshot is None:
        return ""
    try:
        if not compact_recovery_enabled():
            return ""
        files = gather_canonical_files(agent)
        if not any(files.values()):
            return ""
        path = write_compact_snapshot(agent, files)
        return str(path) if path is not None else ""
    except Exception:
        # Snapshot failure must never block compaction.
        return ""


def main() -> int:
    try:
        agent = _agent_id()
        home = _agent_home()
        if not agent or home is None:
            return 0
        payload = _stdin_payload()
        trigger = str(payload.get("trigger") or payload.get("reason") or "").strip() or "unknown"
        custom = str(payload.get("custom_instructions") or "").strip()
        snapshot_path = _capture_canonical_snapshot(agent)
        capture_text_parts = [
            f"trigger={trigger}",
            f"agent={agent}",
            f"ts={datetime.now().astimezone().isoformat(timespec='seconds')}",
        ]
        if snapshot_path:
            capture_text_parts.append(f"canonical_snapshot={snapshot_path}")
        if custom:
            # Keep the custom-instructions excerpt short; the full prompt
            # is in the session transcript which Claude Code handles on its
            # own side via compactPrompt.
            capture_text_parts.append(f"custom={custom[:500]}")
        capture_text = " | ".join(capture_text_parts)

        bridge_memory = _bridge_home() / "bridge-memory.py"
        template_root = _bridge_home() / "agents" / "_template"
        if not bridge_memory.exists():
            return 0
        cmd = [
            sys.executable or "python3",
            str(bridge_memory),
            "capture",
            "--agent", agent,
            "--home", str(home),
            "--template-root", str(template_root),
            "--source", "pre-compact-hook",
            "--title", f"pre-compact dump ({trigger})",
            "--text", capture_text,
        ]
        try:
            subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
    except Exception:
        # Never block a compaction on hook failure.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
