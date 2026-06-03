#!/usr/bin/env python3
"""Codex PermissionRequest hook — bounded, redacted, audit-only by default.

Codex CLI 0.135.0+ fires `PermissionRequest` when a tool call needs the
operator's approval (e.g. a write outside the sandbox, a network egress).
This hook records the request and — only when explicitly enabled — surfaces
it to the operator via a single `[PERMISSION] <agent> needs approval for
<tool>` queue task (the same surface the Claude `permission_escalation.py`
hook + `patch-permission-approval` skill use).

SECURITY CONTRACT (this hook is the only Codex hook that handles a
permission decision surface, so it is deliberately conservative):

1. REDACTION. The hook NEVER persists raw file paths, full command argv,
   tool-input bodies, env, or secrets. The audit row and any queued task
   carry only: the tool name, the requesting agent id, and a redacted
   SHA-256 context hash derived from the tool input (a forensic anchor that
   reveals nothing about the content). No reason string, no path, no
   command text is written.

2. DEDUPE / THROTTLE. At most ONE queue task per `(agent, tool)` within a
   throttle window (default 600s; override with
   ``BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS``). Repeated requests
   inside the window update the throttle marker but never spam new tasks.
   The throttle state lives in the agent's state dir
   (`state/agents/<agent>/codex-permission-throttle.json`).

3. NO ALLOW/DENY SIDE EFFECT BY DEFAULT. The hook exits 0 and emits NO
   `permissionDecision`. It NEVER auto-allows or auto-denies. Only when
   ``BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on`` is set does it create the
   `[PERMISSION]` queue task (still surfacing to the operator, never
   deciding). There is no env that makes this hook decide allow/deny — the
   operator decides via the queue task / approval skill.

4. FAIL-OPEN. Any hook error → exit 0, never block the Codex session.

Environment:
- ``BRIDGE_AGENT_ID`` — required; without it the hook no-ops.
- ``BRIDGE_CODEX_PERMISSION_AUTO_QUEUE`` — ``on`` to enqueue a
  `[PERMISSION]` task to the admin agent (default: audit-only, no task).
- ``BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS`` — throttle window for
  the per-(agent,tool) queue task (default: 600).
- ``BRIDGE_ADMIN_AGENT_ID`` — the admin agent the `[PERMISSION]` task is
  routed to. When unset and auto-queue is on, the hook audits a skip.

Output: Codex `hookSpecificOutput` envelope with an empty
``additionalContext`` and NO ``permissionDecision``. Always exits 0.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from bridge_hook_common import (
        bridge_state_dir,
        queue_cli,
        under_isolated_uid,
        write_audit,
    )
except ImportError:  # pragma: no cover — keep the hook resilient if hooks/
    # is partially deployed.
    bridge_state_dir = None  # type: ignore[assignment]
    queue_cli = None  # type: ignore[assignment]
    under_isolated_uid = None  # type: ignore[assignment]
    write_audit = None  # type: ignore[assignment]

_DEFAULT_THROTTLE_SECONDS = 600
# Recursion guard env: queue task creation drives `agb task create`, which
# itself fires hooks. Never re-enter.
_RECURSION_ENV = "BRIDGE_HOOK_CODEX_PERMISSION_ACTIVE"

# A legitimate tool name is a single canonical identifier: alnum plus a closed
# set of separators (`_`, `.`, `:`, `-`). It must NEVER carry a path, argv, or
# arbitrary free text. The sanitizer below extracts the leading canonical token
# and discards everything else, so a hostile payload like
# `Write /Users/op/keys.txt sk-...` cannot smuggle a path/secret through the
# tool-NAME field into the audit row or the [PERMISSION] queue task (codex
# Phase-4 BLOCKING — the tool_name leak class, sibling to the tool_input
# redaction already in place).
_TOOL_NAME_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:-]+")
_TOOL_NAME_MAX_LEN = 64
_REDACTED_TOOL_NAME = "redacted-tool"


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _auto_queue_enabled() -> bool:
    raw = (os.environ.get("BRIDGE_CODEX_PERMISSION_AUTO_QUEUE") or "").strip().lower()
    return raw == "on"


def _throttle_window_seconds() -> int:
    raw = (os.environ.get("BRIDGE_CODEX_PERMISSION_QUEUE_THROTTLE_SECONDS") or "").strip()
    if not raw:
        return _DEFAULT_THROTTLE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_THROTTLE_SECONDS
    return value if value > 0 else _DEFAULT_THROTTLE_SECONDS


def _raw_tool_name(event: dict[str, Any]) -> str:
    """Return the caller-supplied tool name VERBATIM (untrusted).

    Used ONLY to derive a one-way SHA-256 correlation anchor. The raw value
    must never be persisted directly — every persistence path uses the
    sanitized ``_tool_name`` instead.
    """
    for key in ("tool_name", "toolName", "tool"):
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _sanitize_tool_name(raw: str) -> str:
    """Reduce an untrusted tool-name string to a SAFE canonical token.

    Extracts the leading ``[A-Za-z0-9_.:-]+`` token (the legitimate tool
    identifier shape) and discards everything after it — so a hostile
    ``Write /Users/op/keys.txt sk-…`` collapses to ``Write`` and no path /
    argv / secret survives. The token is length-capped. A value with no
    canonical leading token (e.g. starts with a path separator) yields
    ``redacted-tool``; an empty/missing name yields ``unknown``.

    This is the SINGLE source of the tool name for ALL persistence paths
    (audit ``detail.tool``, the ``[PERMISSION]`` task title/body, and the
    throttle/context keys), mirroring the redaction discipline already
    applied to ``tool_input``.
    """
    raw = (raw or "").strip()
    if not raw:
        return "unknown"
    match = _TOOL_NAME_TOKEN_RE.match(raw)
    if match is None:
        # No canonical token at the start → the whole value is hostile
        # free-text (e.g. a leading "/path" or quoted blob). Persist nothing
        # from it; the SHA-256 anchor on the raw value preserves correlation.
        return _REDACTED_TOOL_NAME
    token = match.group(0)[:_TOOL_NAME_MAX_LEN]
    return token or _REDACTED_TOOL_NAME


def _tool_name(event: dict[str, Any]) -> str:
    """SAFE canonical tool name — the only tool-name value any persistence
    path may use. See :func:`_sanitize_tool_name`."""
    return _sanitize_tool_name(_raw_tool_name(event))


def _tool_name_sha256(raw: str) -> str:
    """One-way correlation anchor for the RAW (untrusted) tool name."""
    return hashlib.sha256((raw or "").encode("utf-8", errors="replace")).hexdigest()


def _normalize_tool_for_key(tool: str) -> str:
    """Stable, filesystem-safe key fragment for the throttle marker.

    Collapses anything outside [A-Za-z0-9._-] to '_' so a hostile tool name
    can never escape the per-agent throttle file or smuggle a path
    separator. Empty / all-stripped names normalize to 'unknown'.
    """
    safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in tool)
    safe = safe.strip("._-")
    return safe or "unknown"


def _context_hash(event: dict[str, Any]) -> str:
    """SHA-256 anchor over the (redacted) tool-input payload.

    This is the ONLY thing derived from the tool input that we persist. It
    is a one-way hash, so it leaks neither paths, argv, nor secrets, while
    still letting an operator confirm two audit rows refer to the same
    underlying request. We hash a canonicalized JSON of the tool-input dict
    (sorted keys) plus the tool name.
    """
    tool_input = event.get("tool_input") or event.get("toolInput") or event.get("input") or {}
    try:
        canonical = json.dumps(tool_input, ensure_ascii=True, sort_keys=True, default=str)
    except (TypeError, ValueError):
        canonical = str(tool_input)
    # Hash over the RAW tool name (one-way; no leak) so two identical
    # underlying requests — including identical hostile payloads — produce the
    # same anchor for operator correlation.
    payload = f"{_raw_tool_name(event)}\x00{canonical}"
    return hashlib.sha256(payload.encode("utf-8", errors="replace")).hexdigest()


def _throttle_path(agent: str) -> Path | None:
    if bridge_state_dir is None:
        return None
    return bridge_state_dir() / "agents" / agent / "codex-permission-throttle.json"


def _load_throttle(agent: str) -> dict[str, Any]:
    path = _throttle_path(agent)
    if path is None or not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_throttle(agent: str, state: dict[str, Any]) -> bool:
    path = _throttle_path(agent)
    if path is None:
        return False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=True) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)
        return True
    except (PermissionError, OSError):
        # codex review gap 1: keep ALL PermissionRequest audit rows free of
        # raw paths. The fail-open audit target is the agent id (never the
        # throttle file path), and the detail records only that the
        # controller-owned throttle write was skipped under iso — no path.
        if under_isolated_uid is not None and under_isolated_uid() and write_audit is not None:
            try:
                write_audit(
                    "hook_permission_fail_open.codex_permission_request.throttle",
                    agent,
                    {"operation": "save_throttle"},
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
        return False


def _within_throttle(agent: str, tool_key: str, now: int, window: int) -> bool:
    """True iff a queue task for (agent, tool_key) fired within the window."""
    state = _load_throttle(agent)
    entries = state.get("tools")
    if not isinstance(entries, dict):
        return False
    last = entries.get(tool_key)
    if not isinstance(last, (int, float)):
        return False
    return (now - int(last)) < window


def _record_throttle(agent: str, tool_key: str, now: int) -> None:
    state = _load_throttle(agent)
    entries = state.get("tools")
    if not isinstance(entries, dict):
        entries = {}
    entries[tool_key] = now
    state["tools"] = entries
    _save_throttle(agent, state)


def _admin_agent_id() -> str:
    return (os.environ.get("BRIDGE_ADMIN_AGENT_ID") or "").strip()


def _create_permission_task(agent: str, admin: str, tool: str, context_hash: str) -> bool:
    """Create the `[PERMISSION]` queue task. Body carries NO raw input.

    The body intentionally contains only the tool name, the requesting
    agent, the redacted context hash, and operator instructions — never a
    path, argv, or reason text that could echo a secret.
    """
    if queue_cli is None:
        return False
    title = f"[PERMISSION] {agent} needs approval for {tool}"
    body = "\n".join(
        [
            f"agent={agent}",
            f"tool={tool}",
            f"context_sha256={context_hash}",
            "surface=codex_permission_request (audit-only hook, no auto-decision)",
            "",
            "Codex requested permission for the tool above. The hook does NOT",
            "auto-allow or auto-deny — you decide. Approve / deny in the Codex",
            "session directly (the request is blocking there); this task is the",
            "operator-visible record. Raw paths / argv are intentionally NOT",
            "included — inspect the live Codex prompt for the specifics.",
        ]
    )
    # codex review gap 2: the recursion guard MUST reach the queue-create
    # child. `queue_cli()` calls subprocess.run() with no `env=` override, so
    # the child inherits THIS process's os.environ. Set the guard in
    # os.environ before the call (so the child sees it and short-circuits if
    # creating the task re-fires this hook) and restore it afterward so we do
    # not permanently poison the hook process env.
    prior = os.environ.get(_RECURSION_ENV)
    os.environ[_RECURSION_ENV] = "1"
    try:
        proc = queue_cli(
            [
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
        )
    except Exception:  # noqa: BLE001 — enqueue failure must not block
        return False
    finally:
        if prior is None:
            os.environ.pop(_RECURSION_ENV, None)
        else:
            os.environ[_RECURSION_ENV] = prior
    return getattr(proc, "returncode", 1) == 0


def _emit_envelope() -> None:
    # AUDIT-ONLY: no permissionDecision is ever emitted. The operator (or
    # the live Codex prompt) decides. We emit a well-formed envelope so
    # Codex's parser is satisfied without us influencing the decision.
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "additionalContext": "",
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def main() -> int:
    # Recursion guard: queue-task creation drives agb, which re-fires hooks.
    if (os.environ.get(_RECURSION_ENV) or "").strip() == "1":
        _emit_envelope()
        return 0
    try:
        event = _read_event()
        agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
        if not agent:
            _emit_envelope()
            return 0

        # `tool` is the SANITIZED canonical token — the ONLY tool-name value
        # that reaches any persistence path (audit detail.tool, the
        # [PERMISSION] task title/body, the throttle/context keys). The raw
        # (untrusted) name is read only to derive a one-way correlation hash
        # and to detect whether sanitization actually dropped anything.
        raw_tool = _raw_tool_name(event)
        tool = _sanitize_tool_name(raw_tool)
        tool_name_redacted = raw_tool != tool
        tool_sha256 = _tool_name_sha256(raw_tool) if tool_name_redacted else ""
        tool_key = _normalize_tool_for_key(tool)
        context_hash = _context_hash(event)
        now = int(time.time())
        window = _throttle_window_seconds()
        auto_queue = _auto_queue_enabled()
        admin = _admin_agent_id()

        # Decide whether to surface a queue task. Default: never (audit-only).
        # Even with auto-queue on, respect the per-(agent,tool) throttle and
        # require an admin recipient.
        throttled = _within_throttle(agent, tool_key, now, window)
        task_created = False
        skip_reason = ""
        if not auto_queue:
            skip_reason = "audit_only_default"
        elif not admin:
            skip_reason = "no_admin_agent"
        elif throttled:
            skip_reason = "throttled"
        else:
            task_created = _create_permission_task(agent, admin, tool, context_hash)
            if task_created:
                _record_throttle(agent, tool_key, now)
            else:
                skip_reason = "task_create_failed"

        if write_audit is not None:
            try:
                write_audit(
                    "codex_permission_request",
                    agent,
                    {
                        # SANITIZED canonical tool token ONLY — never the raw
                        # caller-supplied tool-name string.
                        "tool": tool,
                        # Whether the raw tool name carried more than the
                        # canonical token (a path/argv/secret smuggle attempt).
                        "tool_name_redacted": tool_name_redacted,
                        # One-way anchor for the RAW tool name; emitted ONLY when
                        # sanitization dropped something, so an operator can
                        # correlate without the raw value ever being persisted.
                        "tool_sha256": tool_sha256,
                        # Redacted forensic anchor ONLY. No path / argv / reason.
                        "context_sha256": context_hash,
                        "auto_queue": auto_queue,
                        "throttle_window_seconds": window,
                        "throttled": throttled,
                        "task_created": task_created,
                        "skip_reason": skip_reason,
                        "decision_emitted": False,
                    },
                )
            except Exception:  # noqa: BLE001 — best-effort audit
                pass
    except Exception:  # noqa: BLE001 — fail-open: never block the Codex session
        pass
    _emit_envelope()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
