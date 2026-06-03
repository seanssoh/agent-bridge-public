#!/usr/bin/env python3
"""Codex PreCompact hook — canonical snapshot + NEXT-SESSION handoff note.

Codex CLI 0.135.0+ fires `PreCompact` right before it compresses the
conversation (`trigger: manual|auto`). This hook captures a best-effort
snapshot of the agent's canonical identity files (SOUL.md / MEMORY.md /
etc.) so the post-compact `SessionStart` recovery path
(`compact_recovery_context`) can re-inject them even if the live files are
touched mid-compact, and emits an audit row recording the event. When a
NEXT-SESSION.md handoff is present in the agent's workdir/home, its path is
recorded in the audit row so the operator can correlate the handoff with
the compaction.

AUDIT-ONLY by default. This hook NEVER blocks compaction and NEVER emits a
decision — it always exits 0. The only side effect is a best-effort
canonical snapshot sidecar (gated by ``BRIDGE_COMPACT_RECOVERY``, the same
env that gates the Claude `pre-compact.py` snapshot) plus an audit row.

Environment:
- ``BRIDGE_AGENT_ID`` — required; without it the hook no-ops.
- ``BRIDGE_COMPACT_RECOVERY`` — set to ``0``/``false``/``off`` to disable
  the canonical snapshot sidecar (default: enabled). No effect on the
  audit row.

Output: Codex `hookSpecificOutput` envelope with an empty
``additionalContext`` (PreCompact has no context to inject; the recovery
context is injected at the next SessionStart). Failures are swallowed and
the hook ALWAYS exits 0 — compaction must never be blocked.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

# bridge_hook_common sits next to this file in both the source tree and the
# deployed runtime (~/.agent-bridge/hooks/). Make the import robust to the
# live-runtime layout Codex wires through ~/.codex/hooks.json.
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import (
        agent_default_home,
        agent_workdir,
        compact_recovery_enabled,
        first_existing_path,
        gather_canonical_files,
        write_audit,
        write_compact_snapshot,
    )
except ImportError:  # pragma: no cover — keep the hook resilient if hooks/
    # is partially deployed; PreCompact must never break compaction.
    agent_default_home = None  # type: ignore[assignment]
    agent_workdir = None  # type: ignore[assignment]
    compact_recovery_enabled = None  # type: ignore[assignment]
    first_existing_path = None  # type: ignore[assignment]
    gather_canonical_files = None  # type: ignore[assignment]
    write_audit = None  # type: ignore[assignment]
    write_compact_snapshot = None  # type: ignore[assignment]


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _normalize_trigger(event: dict[str, Any]) -> str:
    raw = str(event.get("trigger") or event.get("reason") or "").strip().lower()
    if raw in {"manual", "auto"}:
        return raw
    return raw or "unknown"


def _next_session_path(agent: str) -> Path | None:
    if agent_workdir is None or agent_default_home is None or first_existing_path is None:
        return None
    try:
        workdir = agent_workdir(agent)
        default_home = agent_default_home(agent)
        return first_existing_path(
            [workdir / "NEXT-SESSION.md", default_home / "NEXT-SESSION.md"]
        )
    except Exception:  # noqa: BLE001 — handoff lookup must never block compaction
        return None


def _capture_snapshot(agent: str) -> str:
    """Persist the canonical-file snapshot; return the path or empty string."""
    if (
        compact_recovery_enabled is None
        or gather_canonical_files is None
        or write_compact_snapshot is None
    ):
        return ""
    try:
        if not compact_recovery_enabled():
            return ""
        files = gather_canonical_files(agent)
        if not any(files.values()):
            return ""
        path = write_compact_snapshot(agent, files)
        return str(path) if path is not None else ""
    except Exception:  # noqa: BLE001 — snapshot failure must not block compaction
        return ""


def _emit_envelope() -> None:
    # Codex hook output contract: PreCompact carries no additionalContext
    # (the recovery context is injected at the next SessionStart). Emit a
    # well-formed empty envelope so Codex's deny_unknown_fields parser is
    # satisfied.
    json.dump(
        {"hookSpecificOutput": {"hookEventName": "PreCompact", "additionalContext": ""}},
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def main() -> int:
    try:
        event = _read_event()
        agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
        if not agent:
            _emit_envelope()
            return 0

        trigger = _normalize_trigger(event)
        snapshot_path = _capture_snapshot(agent)
        next_session = _next_session_path(agent)

        if write_audit is not None:
            try:
                write_audit(
                    "codex_pre_compact.snapshot",
                    agent,
                    {
                        "trigger": trigger,
                        "snapshot_path": snapshot_path,
                        "next_session_present": next_session is not None,
                        # Record only the basename + parent dir name, never the
                        # full path beyond the agent tree, to keep the audit row
                        # stable across hosts.
                        "next_session": next_session.name if next_session is not None else "",
                    },
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
    except Exception:  # noqa: BLE001 — never block a compaction on hook failure
        pass
    _emit_envelope()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
