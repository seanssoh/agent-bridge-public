#!/usr/bin/env python3
"""Codex SubagentStop hook — record a subagent completion (audit-only).

Codex CLI 0.135.0+ fires `SubagentStop` when a spawned subagent thread
finishes. This hook records the completion as an audit row
(`action=subagent_fanout`, `phase=stop`) with a bounded completion summary
so operators can correlate the fan-out (`SubagentStart`) with its outcome.

AUDIT-ONLY. This hook NEVER blocks, NEVER re-runs or retries the subagent,
and NEVER emits a decision — it always exits 0. The only effect is one
audit row.

The audit detail is bounded and redacted: it records the subagent name /
id, a status if Codex provides one, and a length-capped completion summary.
It does NOT persist the subagent's full last message, tool argv, file
paths, or any free-form body that could carry secrets.

Environment:
- ``BRIDGE_AGENT_ID`` — required; without it the hook no-ops.

Output: Codex `hookSpecificOutput` envelope with an empty
``additionalContext``.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import truncate_text, write_audit
except ImportError:  # pragma: no cover — keep the hook resilient if hooks/
    # is partially deployed.
    truncate_text = None  # type: ignore[assignment]
    write_audit = None  # type: ignore[assignment]

_SUMMARY_LIMIT = 240


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _first_str(event: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, dict):
            inner = value.get("text") or value.get("content")
            if isinstance(inner, str) and inner.strip():
                return inner.strip()
    return ""


def _cap(text: str) -> str:
    if truncate_text is not None:
        return truncate_text(text, _SUMMARY_LIMIT)
    cleaned = " ".join(str(text).split())
    return cleaned[:_SUMMARY_LIMIT]


def _emit_envelope() -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "SubagentStop",
                "additionalContext": "",
            }
        },
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

        subagent_name = _first_str(
            event, "subagent_name", "subagentName", "agent", "name"
        )
        subagent_id = _first_str(
            event, "subagent_id", "subagentId", "thread_id", "threadId", "id"
        )
        status = _first_str(event, "status", "result", "outcome")
        # A short completion summary is useful telemetry; cap it hard and
        # take it only from explicit summary fields, never the raw last
        # message body (which can carry secrets / large diffs).
        summary = _first_str(event, "summary", "completion_summary", "description")

        if write_audit is not None:
            try:
                write_audit(
                    "subagent_fanout",
                    agent,
                    {
                        "phase": "stop",
                        "subagent_name": _cap(subagent_name),
                        "subagent_id": _cap(subagent_id),
                        "status": _cap(status),
                        "summary": _cap(summary),
                    },
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
    except Exception:  # noqa: BLE001 — never block on hook failure
        pass
    _emit_envelope()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
