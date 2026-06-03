#!/usr/bin/env python3
"""Codex PostCompact hook — re-inject queue context + refresh heartbeat.

Codex CLI 0.135.0+ fires `PostCompact` right after the conversation has
been compacted. The Claude path handles compact recovery via the
`SessionStart` (matcher=compact) hook, but Codex's SessionStart matcher set
does not always re-fire on an in-place compaction, so this dedicated
PostCompact hook re-injects the agent's canonical identity files and the
queue protocol context into the next turn — the same content
`session_start.py` injects on a `compact` matcher.

It also refreshes the per-agent heartbeat marker
(`state/agents/<agent>/codex-post-compact.json`) so operators / the daemon
can see the agent came back online after a compaction.

AUDIT-ONLY. This hook NEVER blocks and NEVER emits a decision — it always
exits 0. The only effects are (a) re-injected `additionalContext` for the
next turn and (b) a best-effort heartbeat marker + audit row.

Environment:
- ``BRIDGE_AGENT_ID`` — required; without it the hook emits an empty
  envelope and no-ops.
- ``BRIDGE_COMPACT_RECOVERY`` — set to ``0``/``false``/``off`` to skip the
  canonical-file re-injection (default: enabled); the queue protocol line
  is still injected.

Output: Codex `hookSpecificOutput` envelope with `additionalContext`
carrying the restored context. Failures are swallowed and the hook ALWAYS
exits 0.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import (
        bridge_state_dir,
        compact_recovery_context,
        session_start_context,
        under_isolated_uid,
        write_audit,
    )
except ImportError:  # pragma: no cover — keep the hook resilient if hooks/
    # is partially deployed.
    bridge_state_dir = None  # type: ignore[assignment]
    compact_recovery_context = None  # type: ignore[assignment]
    session_start_context = None  # type: ignore[assignment]
    under_isolated_uid = None  # type: ignore[assignment]
    write_audit = None  # type: ignore[assignment]


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _heartbeat_marker(agent: str) -> Path | None:
    if bridge_state_dir is None:
        return None
    return bridge_state_dir() / "agents" / agent / "codex-post-compact.json"


def _refresh_heartbeat(agent: str) -> bool:
    """Best-effort per-agent post-compact heartbeat marker. Returns success."""
    marker = _heartbeat_marker(agent)
    if marker is None:
        return False
    payload = {
        "agent": agent,
        "refreshed_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "event": "post_compact",
    }
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        tmp = marker.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(marker)
        os.chmod(marker, 0o600)
        return True
    except (PermissionError, OSError):
        # Under iso v2 the state tree is controller-owned; fail open and
        # emit telemetry the same way save_timestamp_state does, rather
        # than dumping a traceback that Codex would surface as a hook fail.
        if under_isolated_uid is not None and under_isolated_uid() and write_audit is not None:
            try:
                write_audit(
                    "hook_permission_fail_open.codex_post_compact.heartbeat",
                    str(marker),
                    {"operation": "refresh_heartbeat"},
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
        return False


def _build_context(agent: str) -> str:
    parts: list[str] = []
    if compact_recovery_context is not None:
        try:
            restored = compact_recovery_context(agent)
        except Exception:  # noqa: BLE001
            restored = ""
        if restored:
            parts.append(restored)
    if session_start_context is not None:
        try:
            queue_ctx = session_start_context(agent)
        except Exception:  # noqa: BLE001
            queue_ctx = ""
        if queue_ctx:
            parts.append(queue_ctx)
    return "\n\n".join(parts)


def _emit_envelope(context: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostCompact",
                "additionalContext": context,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def main() -> int:
    context = ""
    try:
        _read_event()  # consume stdin; PostCompact payload is advisory
        agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
        if not agent:
            _emit_envelope("")
            return 0

        heartbeat_ok = _refresh_heartbeat(agent)
        context = _build_context(agent)

        if write_audit is not None:
            try:
                write_audit(
                    "codex_post_compact.recover",
                    agent,
                    {
                        "heartbeat_refreshed": heartbeat_ok,
                        "context_reinjected": bool(context),
                        "context_chars": len(context),
                    },
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
    except Exception:  # noqa: BLE001 — never block on hook failure
        pass
    _emit_envelope(context)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
