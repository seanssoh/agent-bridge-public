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

import hashlib
import json
import os
import re
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


# Codex r2 BLOCKING (r3, 2026-05-29, #1358) — second leak vector. This
# hook fires on PermissionDenied, which is exactly what happens when
# tool-policy.py denies the credential-routine command (e.g. the
# env-roster-mismatch deny path). `redacted_summary_text` previously
# put the raw Bash command through `sanitize_text`, whose `openai_key`
# pattern (`\bsk-[A-Za-z0-9]{20,}\b`) does NOT match the Claude OAuth
# token shape (`sk-ant-o-…`, hyphenated, <20 alnum before the first
# `-`). So the raw token landed in both the `permission_escalation_*`
# audit rows and the `[PERMISSION]` admin-task body. Mirror the
# tool-policy hash-only posture: if the Bash command carries ANY Claude
# credential substring, replace the summary with a SHA-256 anchor so
# the token never reaches the audit log or the queued admin task.
def _command_mentions_claude_credentials(raw: str) -> bool:
    """True iff *raw* carries any of the Claude OAuth credential markers.

    Mirrors ``tool-policy.py:_raw_mentions_claude_credentials`` (kept a
    local copy rather than cross-importing a hyphenated module file).
    Five markers: the OAuth setup-token prefix, the credentials JSON
    path pair, the OAuth token env var name, the launch-secrets env
    basename, and the token-registry JSON basename.
    """
    return (
        "sk-ant-o" in raw
        or (".credentials.json" in raw and ".claude" in raw)
        or "CLAUDE_CODE_OAUTH_TOKEN" in raw
        or "launch-secrets.env" in raw
        or "claude-oauth-tokens.json" in raw
    )


def _credential_command_sha256(text: str) -> str:
    """SHA-256 hex anchor for a credential-bearing command (forensic)."""
    return hashlib.sha256(
        (text or "").encode("utf-8", errors="replace")
    ).hexdigest()


# Codex r2 BLOCKING (r3, 2026-05-29, #1358): `sanitize_text`'s
# `openai_key` pattern misses the `sk-ant-o…` OAuth shape, so a non-Bash
# tool input (Grep `pattern`, Read/Write `file_path`) naming a token
# would still leak it through `redacted_summary_text` into the audit row
# AND the `[PERMISSION]` admin-task body. Redact the token-shaped run as
# a final pass after `sanitize_text`. Mirrors
# ``tool-policy.py:_redact_credential_token_values``.
_CREDENTIAL_TOKEN_VALUE_RE = re.compile(r"sk-ant-o[A-Za-z0-9_-]*")


def _redact_credential_token_values(text: str) -> str:
    """Collapse OAuth token runs in *text* (value-only). Mirrors
    ``tool-policy.py:_redact_credential_token_values``.

    Codex r3 self-review (r4, 2026-05-29, #1358) — class closure. The
    audit rows in this module are now covered by the
    ``bridge_hook_common.write_audit`` choke-point, but the
    ``[PERMISSION]`` admin TASK BODY is a SEPARATE sink the choke-point
    does not touch: ``handle_permission_denied`` reads the raw hook deny
    ``reason`` (which can echo the offending command, including an
    ``sk-ant-o…`` token) and ``build_task_body`` writes it verbatim into
    the queued task body via ``create_admin_task --body``. Redacting the
    ``reason`` at source keeps the token out of BOTH the audit
    ``detail.reason`` AND the queue task body / origin-block note.
    ``redacted_args`` already passes through ``redacted_summary_text``;
    ``reason`` was the one free-text field that did not.
    """
    return _CREDENTIAL_TOKEN_VALUE_RE.sub("sk-ant-o<REDACTED>", text or "")


def redacted_summary_text(agent: str, tool_name: str, tool_input: dict[str, Any]) -> str:
    # Hash-only short-circuit for credential-bearing Bash commands. The
    # generic `sanitize_text` openai_key regex does not catch the
    # `sk-ant-o-…` OAuth token shape, so a credential-routine command
    # denied upstream would otherwise leak the raw token here. Replace
    # the whole summary with the command hash anchor; no command text in
    # any form reaches the audit row or the admin-task body.
    if tool_name == "Bash":
        bash_command = str(tool_input.get("command") or "")
        if _command_mentions_claude_credentials(bash_command):
            return json.dumps(
                {"command_sha256": _credential_command_sha256(bash_command)},
                ensure_ascii=False,
            )
    summary = tool_input_summary(tool_name, tool_input)
    raw = json.dumps(summary, ensure_ascii=False)
    scrubbed = sanitize_text(raw, surface="permission_escalation", agent=agent)
    # Final token-value pass: catch the `sk-ant-o…` OAuth shape that
    # `sanitize_text` does not, on every tool (notably non-Bash Grep /
    # Read inputs whose `pattern` / `file_path` named the token).
    return _CREDENTIAL_TOKEN_VALUE_RE.sub(
        "sk-ant-o<REDACTED>", scrubbed.sanitized_text
    )


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
    # Codex r3 self-review (r4, #1358): redact token-shaped values out of
    # the hook deny reason at source so the token cannot ride into the
    # queued `[PERMISSION]` admin task body (build_task_body), the
    # origin-block note, or the audit `detail.reason`. The deny reason can
    # echo the offending command on some gates; `redacted_args` was
    # already scrubbed but `reason` was the one free-text sink that was not.
    reason = _redact_credential_token_values(str(payload.get("reason") or ""))
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
