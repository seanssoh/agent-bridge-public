#!/usr/bin/env python3
"""Codex companion-role Stop hook: enforce review-output prefix on `[plan]`/`[review]` tasks.

Behavior:
- Reads ``BRIDGE_AGENT_ID`` and the deterministic single claimed task
  (``status='claimed' AND claimed_by=<agent>``).
- If that task title carries a companion-role prefix (`[plan]` / `[review]`)
  AND the response's first non-blank line does NOT start with one of
  ``plan-ok`` / ``implement-ok`` / ``needs-more``, the hook decides per
  ``BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE``:
    - ``audit`` (default, unset, or any non-block value): emit audit, allow.
    - ``block``: emit audit, return ``decision=block`` with a structured
      correction prompt that includes the response tail so Codex can restate
      without losing prior work.

The hook ignores ``stop_hook_active`` to avoid blocking a recursion guard
chain. It prefers ``last_assistant_message`` (Codex's documented field for
Stop hooks) and falls back to other common envelope keys; if no response
content is available, the hook fails-open with audit.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any

from bridge_hook_common import bridge_task_db, write_audit


COMPANION_PREFIXES = ("plan", "review")
APPROVED_PREFIXES = ("plan-ok", "implement-ok", "needs-more")
RESPONSE_TAIL_LIMIT = 600


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _mode() -> str:
    raw = (os.environ.get("BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE") or "").strip().lower()
    return "block" if raw == "block" else "audit"


def _title_is_companion(title: str) -> bool:
    s = (title or "").strip().lower()
    if not s.startswith("["):
        return False
    end = s.find("]")
    if end <= 0:
        return False
    inner = s[1:end].strip()
    if not inner:
        return False
    head = inner.split(None, 1)[0]
    return head in COMPANION_PREFIXES


def _claimed_task(agent: str) -> dict[str, Any] | None:
    """Return the deterministic single claimed task or None.

    Fails-open with audit on db_error and ambiguous claim.
    """
    db = bridge_task_db()
    if not db.exists():
        return None
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT id, title
                FROM tasks
                WHERE status = 'claimed' AND claimed_by = ?
                ORDER BY claimed_ts DESC, id DESC
                LIMIT 2
                """,
                (agent,),
            ).fetchall()
    except sqlite3.Error as exc:
        write_audit(
            "codex_review_output_shape.db_error",
            agent,
            {"stage": "claimed_task_lookup", "error": str(exc)[:200]},
        )
        return None
    if not rows:
        return None
    if len(rows) > 1:
        write_audit(
            "codex_review_output_shape.ambiguous_claimed_task",
            agent,
            {
                "claimed_count": len(rows),
                "task_ids": [r["id"] for r in rows],
            },
        )
        return None
    row = rows[0]
    return {"id": row["id"], "title": row["title"] or ""}


def _extract_response(event: dict[str, Any]) -> str:
    """Return the response text from a Codex Stop event, best-effort."""
    for key in (
        "last_assistant_message",
        "lastAssistantMessage",
        "assistant_message",
        "assistantMessage",
        "response_text",
        "response",
        "text",
        "message",
    ):
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value
        if isinstance(value, dict):
            inner = value.get("text") or value.get("content")
            if isinstance(inner, str) and inner.strip():
                return inner
    return ""


def _first_nonblank_line(text: str) -> str:
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return ""


def _starts_with_approved_prefix(line: str) -> bool:
    lowered = line.lower()
    for prefix in APPROVED_PREFIXES:
        if lowered.startswith(prefix):
            return True
    return False


def _block_payload(task_title: str, response_text: str) -> dict[str, Any]:
    tail = response_text[-RESPONSE_TAIL_LIMIT:]
    reason = (
        f"This response does not start with one of `plan-ok`, `implement-ok`, "
        f"or `needs-more`. The current task title (`{task_title.strip()}`) is "
        f"a companion-role review task, so the first non-blank line of the "
        f"reply must carry one of these prefixes (followed by an explanation "
        f"or the changes needed). Please restate your conclusion with the "
        f"prefix on the first line; your prior content is preserved below "
        f"for reference:\n\n---\n{tail}"
    )
    return {"decision": "block", "reason": reason}


def main() -> int:
    event = _read_event()
    agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
    if not agent:
        return 0

    # Codex's recursion guard: if a prior Stop hook in the chain already
    # decided to block (and the engine re-fired Stop to give other hooks a
    # turn), the event payload carries `stop_hook_active=true`. Match the
    # behavior of `check_inbox.py --format codex`: short-circuit with allow,
    # never re-fight the prior decision. Without this gate the output-shape
    # block would shadow the inbox Stop hook's decision and create a loop.
    if event.get("stop_hook_active"):
        return 0

    mode = _mode()

    try:
        task = _claimed_task(agent)
    except Exception:  # noqa: BLE001
        write_audit(
            "codex_review_output_shape.error",
            agent,
            {"mode": mode, "stage": "claimed_task_lookup"},
        )
        return 0
    if task is None or not _title_is_companion(task["title"]):
        return 0

    response_text = _extract_response(event)
    if not response_text:
        write_audit(
            "codex_review_output_shape.no_response",
            agent,
            {"mode": mode, "task_id": task["id"], "task_title": task["title"]},
        )
        return 0  # fail-open

    first = _first_nonblank_line(response_text)
    if _starts_with_approved_prefix(first):
        return 0  # OK shape

    detail = {
        "mode": mode,
        "task_id": task["id"],
        "task_title": task["title"],
        "first_line": first[:200],
        "would_block": True,
    }
    write_audit("codex_review_output_shape.deny", agent, detail)

    if mode == "block":
        sys.stdout.write(json.dumps(_block_payload(task["title"], response_text)))
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
