#!/usr/bin/env python3
"""Permission-denied escalation hook.

Fires on Claude Code's PermissionDenied event (--permission-mode auto).
Enqueues an urgent task to the admin agent describing the denied tool call,
marks the requesting agent's current claimed task as blocked, and emits an
audit entry. The agent's Claude session continues; it returns to its queue
loop rather than retrying synchronously.

v1 scope: detect + enqueue + block. Admin-side approval handler and daemon
timeout fanout are follow-ups.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent

# Import bridge_hook_common from hooks/ directly; ROOT may have only ``--x``
# ACL for isolated UIDs (see bridge_hook_common.load_guard_module docstring).
_HOOKS_DIR = Path(__file__).resolve().parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from bridge_hook_common import (  # noqa: E402
    bridge_home_dir,
    bridge_script_dir,
    current_agent,
    current_agent_workdir,
    load_guard_module,
    truncate_text,
    write_audit,
)

_guard = load_guard_module(ROOT, required_attrs=("sanitize_text",))
if _guard is None:
    sys.exit(0)

sanitize_text = _guard.sanitize_text


RECURSION_ENV = "BRIDGE_HOOK_PERMISSION_ESCALATION_ACTIVE"
DRY_RUN_ENV = "BRIDGE_PERMISSION_ESCALATION_DRY_RUN"


def admin_agent_id() -> str:
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


def agent_bridge_cli() -> Path:
    return bridge_home_dir() / "agent-bridge"


def tool_input_summary(tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
    if tool_name == "Bash":
        return {
            "command": truncate_text(str(tool_input.get("command") or ""), 240),
            "description": truncate_text(str(tool_input.get("description") or ""), 120),
        }
    for key in ("file_path", "path", "pattern", "url", "subagent_type", "description"):
        value = tool_input.get(key)
        if value:
            return {key: truncate_text(str(value), 240)}
    try:
        payload = json.dumps(tool_input, ensure_ascii=False, sort_keys=True)
    except TypeError:
        payload = str(tool_input)
    return {"summary": truncate_text(payload, 240)}


def redacted_summary_text(agent: str, tool_name: str, tool_input: dict[str, Any]) -> str:
    summary = tool_input_summary(tool_name, tool_input)
    raw = json.dumps(summary, ensure_ascii=False)
    scrubbed = sanitize_text(raw, surface="permission_escalation", agent=agent)
    return scrubbed.sanitized_text


def find_origin_task(agent: str) -> dict[str, Any] | None:
    script = bridge_script_dir() / "bridge-queue.py"
    cwd = current_agent_workdir()
    cwd_arg = str(cwd) if cwd.exists() else None
    try:
        proc = subprocess.run(
            [sys.executable, str(script), "find-open", "--agent", agent, "--format", "json"],
            capture_output=True,
            text=True,
            check=False,
            cwd=cwd_arg,
        )
    except (OSError, FileNotFoundError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    if str(payload.get("status") or "") != "claimed":
        return None
    return payload


def build_task_body(
    agent: str,
    tool_name: str,
    tool_use_id: str,
    redacted_args: str,
    reason: str,
    origin_task_id: int | None,
) -> str:
    lines = [
        f"agent={agent}",
        f"tool={tool_name}",
        f"tool_use_id={tool_use_id}",
        f"args={redacted_args}",
        f"task_id={origin_task_id if origin_task_id is not None else 'none'}",
        f"reason={truncate_text(reason, 400)}",
        "",
        "Approve once: update origin task status=queued (agent retries on re-claim).",
        "Approve always: merge the matching permission rule into the agent's",
        f"  {agent}/.claude/settings.local.json and unblock the origin task.",
        "Deny: mark origin task done with a 'denied: find alternative' note.",
    ]
    return "\n".join(lines)


def create_admin_task(
    admin: str,
    agent: str,
    tool_name: str,
    body: str,
    dry_run: bool,
) -> tuple[bool, str]:
    title = f"[PERMISSION] {agent} needs approval for {tool_name}"
    cmd = [
        str(agent_bridge_cli()),
        "task",
        "create",
        "--to",
        admin,
        "--from",
        agent,
        "--priority",
        "urgent",
        "--title",
        title,
        "--body",
        body,
    ]
    env = os.environ.copy()
    env[RECURSION_ENV] = "1"
    if dry_run:
        return True, f"DRY_RUN:{' '.join(cmd)}"
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
    except (OSError, FileNotFoundError) as exc:
        return False, f"subprocess_error: {exc}"
    return proc.returncode == 0, (proc.stdout or proc.stderr).strip()


def block_origin_task(
    origin_task_id: int,
    agent: str,
    tool_name: str,
    redacted_args: str,
    dry_run: bool,
) -> tuple[bool, str]:
    note = (
        f"permission_needed:{tool_name} — "
        f"retry {redacted_args} after approval"
    )
    cmd = [
        str(agent_bridge_cli()),
        "task",
        "update",
        str(origin_task_id),
        "--status",
        "blocked",
        "--note",
        note,
    ]
    env = os.environ.copy()
    env[RECURSION_ENV] = "1"
    if dry_run:
        return True, f"DRY_RUN:{' '.join(cmd)}"
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
    except (OSError, FileNotFoundError) as exc:
        return False, f"subprocess_error: {exc}"
    return proc.returncode == 0, (proc.stdout or proc.stderr).strip()


def handle_permission_denied(payload: dict[str, Any], agent: str) -> int:
    tool_name = str(payload.get("tool_name") or "unknown")
    tool_use_id = str(payload.get("tool_use_id") or "")
    reason = str(payload.get("reason") or "")
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    admin = admin_agent_id()
    dry_run = os.environ.get(DRY_RUN_ENV, "").strip() not in {"", "0", "false", "no", "off"}
    redacted_args = redacted_summary_text(agent, tool_name, tool_input)

    if not admin:
        write_audit(
            "permission_escalation_skipped",
            agent,
            {
                "agent": agent,
                "tool_name": tool_name,
                "tool_use_id": tool_use_id,
                "session_id": str(payload.get("session_id") or ""),
                "reason": truncate_text(reason, 400),
                "redacted_args": redacted_args,
                "skipped": "no_admin_agent",
                "dry_run": dry_run,
            },
        )
        return 0

    origin = find_origin_task(agent)
    origin_task_id = int(origin["id"]) if origin else None

    detail: dict[str, Any] = {
        "agent": agent,
        "tool_name": tool_name,
        "tool_use_id": tool_use_id,
        "session_id": str(payload.get("session_id") or ""),
        "reason": truncate_text(reason, 400),
        "redacted_args": redacted_args,
        "admin_agent": admin,
        "origin_task_id": origin_task_id,
        "dry_run": dry_run,
    }

    if origin_task_id is None:
        write_audit("permission_escalation_no_origin_task", agent, detail)

    body = build_task_body(
        agent=agent,
        tool_name=tool_name,
        tool_use_id=tool_use_id,
        redacted_args=redacted_args,
        reason=reason,
        origin_task_id=origin_task_id,
    )

    ok_create, info_create = create_admin_task(admin, agent, tool_name, body, dry_run)
    detail["task_create_ok"] = ok_create
    detail["task_create_info"] = truncate_text(info_create, 240)

    if origin_task_id is not None:
        ok_block, info_block = block_origin_task(
            origin_task_id, agent, tool_name, redacted_args, dry_run
        )
        detail["task_block_ok"] = ok_block
        detail["task_block_info"] = truncate_text(info_block, 240)

    write_audit("permission_escalation_requested", agent, detail)
    return 0


def main() -> int:
    if os.environ.get(RECURSION_ENV, "").strip() == "1":
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    event = str(payload.get("hook_event_name") or "")
    if event != "PermissionDenied":
        return 0

    agent = current_agent()
    if not agent:
        return 0

    return handle_permission_denied(payload, agent)


if __name__ == "__main__":
    raise SystemExit(main())
