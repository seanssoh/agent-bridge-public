#!/usr/bin/env python3
"""Manage Claude Code and Codex hook settings for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import shlex
from datetime import datetime
from pathlib import Path
from typing import Any


# Claude Code 2.1.123 exposes autoCompactWindow in user settings. Avoid
# setting CLAUDE_CODE_AUTO_COMPACT_WINDOW here because that env var takes
# precedence over settings and would make operator overlays harder to reason
# about.
#
# Token budgets are class-aware (issue #593):
# - static-class agents (long-lived, registered in agent-roster.local.sh)
#   compact at 400_000 tokens — the legacy default that protects 8GB-RAM
#   hosts from the worst-case 1M-context restore.
# - dynamic agents (--prefer new, ad hoc, --codex --name … spawns)
#   compact at 1_000_000 tokens — they're disposable and benefit from
#   the full window.
# Unknown / missing class falls back to 1_000_000 (safer per issue #570:
# the prior launch_cmd `[1m]` substring heuristic from #547 never fired in
# practice — `[1m]` is a model-id suffix the runtime prints, not a CLI
# argument — and 1_000_000 is a no-regret upper bound because models with
# smaller native context will compact earlier on their own).
BRIDGE_AUTOCOMPACT_WINDOW_STATIC = 400_000
BRIDGE_AUTOCOMPACT_WINDOW_DYNAMIC = 1_000_000
BRIDGE_AUTOCOMPACT_WINDOW_DEFAULT = BRIDGE_AUTOCOMPACT_WINDOW_DYNAMIC
# Back-compat alias for any external caller that imported the pre-#593
# constant name; same value as the unknown-class fallback.
BRIDGE_DEFAULT_AUTOCOMPACT_WINDOW = BRIDGE_AUTOCOMPACT_WINDOW_DEFAULT


def resolve_managed_autocompact_window(
    launch_cmd: str | None,
    agent_class: str | None = None,
) -> int:
    # launch_cmd is retained for ABI compatibility with callers that still
    # pass it positionally; the substring heuristic was removed in #570 and
    # the resolver now keys off agent_class instead (issue #593).
    del launch_cmd
    cls = (agent_class or "").strip().lower()
    if cls == "static":
        return BRIDGE_AUTOCOMPACT_WINDOW_STATIC
    if cls == "dynamic":
        return BRIDGE_AUTOCOMPACT_WINDOW_DYNAMIC
    return BRIDGE_AUTOCOMPACT_WINDOW_DEFAULT


def managed_claude_settings_defaults(
    launch_cmd: str | None,
    agent_class: str | None = None,
) -> dict[str, Any]:
    return {
        "autoCompactWindow": resolve_managed_autocompact_window(launch_cmd, agent_class),
    }


def load_json(path: Path) -> Any:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def merge_settings(base: Any, overlay: Any) -> Any:
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged = dict(base)
        for key, value in overlay.items():
            if key in merged:
                merged[key] = merge_settings(merged[key], value)
            else:
                merged[key] = value
        return merged
    return overlay


def shell_path(path: Path) -> str:
    expanded = path.expanduser()
    home = Path.home().expanduser()
    try:
        rel = expanded.relative_to(home)
    except ValueError:
        return str(expanded)
    if str(rel) == ".":
        return "~"
    return f"~/{rel.as_posix()}"


def shell_command(program: str, path_str: str, *extra: str) -> str:
    parts = [shlex.quote(program), path_str]
    parts.extend(shlex.quote(str(item)) for item in extra)
    return " ".join(parts)


def stop_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "mark-idle.sh"
    return shell_command(bash_bin, shell_path(hook_path))


# Issue #541 PR-B: the Claude Stop event must fire three independent hooks —
# mark-idle.sh (idle wake), surface-reply-enforce.py (assistant reply
# guarantee), and session-stop.py (drain + transcript→daily-note reconcile).
# Source agents/_template/.claude/settings.json already lists all three; the
# shared base agents/.claude/settings.json carried only mark-idle.sh, so the
# rerender path propagated the incomplete suite to every live always-on
# Claude agent. Helpers below let the ensure path register the missing pair
# in addition to mark-idle.sh.
def surface_reply_enforce_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "surface-reply-enforce.py"
    return shell_command(python_bin, shell_path(hook_path))


def session_stop_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "session-stop.py"
    return shell_command(python_bin, shell_path(hook_path))


def session_start_hook_command(bridge_home: Path, python_bin: str, fmt: str = "text") -> str:
    hook_path = bridge_home / "hooks" / "session-start.py"
    if fmt != "text":
        return shell_command(python_bin, shell_path(hook_path), "--format", fmt)
    return shell_command(python_bin, shell_path(hook_path))


def prompt_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "clear-idle.sh"
    return shell_command(bash_bin, shell_path(hook_path))


def prompt_timestamp_hook_command(bridge_home: Path, python_bin: str, fmt: str = "text") -> str:
    hook_path = bridge_home / "hooks" / "prompt_timestamp.py"
    if fmt != "text":
        return shell_command(python_bin, shell_path(hook_path), "--format", fmt)
    return shell_command(python_bin, shell_path(hook_path))


def prompt_guard_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "prompt-guard.py"
    return shell_command(python_bin, shell_path(hook_path))


def tool_policy_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "tool-policy.py"
    return shell_command(python_bin, shell_path(hook_path))


def pre_compact_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "pre-compact.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_session_start_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-session-start.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_stop_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "check-inbox.py"
    return shell_command(python_bin, shell_path(hook_path), "--format", "codex")


def codex_task_mode_policy_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-task-mode-policy.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_review_output_shape_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-review-output-shape.py"
    return shell_command(python_bin, shell_path(hook_path))


def resolve_settings_path(args: argparse.Namespace) -> Path:
    settings_file = getattr(args, "settings_file", None)
    if settings_file:
        return Path(settings_file).expanduser()
    return Path(args.workdir).expanduser() / ".claude" / "settings.json"


def ensure_settings_root(path: Path) -> dict[str, Any]:
    payload = load_json(path)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"settings root must be a JSON object: {path}")
    return payload


def hooks_list(settings: dict[str, Any], event_name: str) -> list[dict[str, Any]]:
    hooks_root = settings.get("hooks")
    if not isinstance(hooks_root, dict):
        hooks_root = {}
        settings["hooks"] = hooks_root

    event_value = hooks_root.get(event_name)
    if isinstance(event_value, list):
        return event_value

    event_list: list[dict[str, Any]] = []
    hooks_root[event_name] = event_list
    return event_list


def is_mark_idle_hook(command: str) -> bool:
    return "mark-idle.sh" in str(command)


def is_surface_reply_enforce_hook(command: str) -> bool:
    return "surface-reply-enforce.py" in str(command)


def is_session_stop_hook(command: str) -> bool:
    return "session-stop.py" in str(command)


def is_session_start_hook(command: str) -> bool:
    command = str(command)
    return "session-start.py" in command or "codex-session-start.py" in command


def is_clear_idle_hook(command: str) -> bool:
    return "clear-idle.sh" in str(command)


def is_prompt_timestamp_hook(command: str) -> bool:
    return "prompt_timestamp.py" in str(command)


def is_prompt_guard_hook(command: str) -> bool:
    return "prompt-guard.py" in str(command)


def is_tool_policy_hook(command: str) -> bool:
    return "tool-policy.py" in str(command)


def is_pre_compact_hook(command: str) -> bool:
    return "pre-compact.py" in str(command)


def is_codex_session_start_hook(command: str) -> bool:
    return is_session_start_hook(command)


def is_codex_stop_hook(command: str) -> bool:
    command = str(command)
    return "check-inbox.py" in command or "codex-stop.py" in command


def is_codex_prompt_hook(command: str) -> bool:
    return is_prompt_timestamp_hook(command)


def is_codex_task_mode_policy_hook(command: str) -> bool:
    return "codex-task-mode-policy.py" in str(command)


def is_codex_review_output_shape_hook(command: str) -> bool:
    return "codex-review-output-shape.py" in str(command)


def find_command_hook(
    event_hooks: list[dict[str, Any]], predicate: Any
) -> tuple[dict[str, Any], dict[str, Any]] | tuple[None, None]:
    for group in event_hooks:
        if not isinstance(group, dict):
            continue
        hooks = group.get("hooks")
        if not isinstance(hooks, list):
            continue
        for hook in hooks:
            if not isinstance(hook, dict):
                continue
            if hook.get("type") != "command":
                continue
            if predicate(str(hook.get("command") or "")):
                return group, hook
    return None, None


def shell_line(key: str, value: str) -> str:
    return f"{key}={shlex.quote(str(value))}"


def print_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
        for key, value in data.items():
            print(shell_line(key, value))
        return

    print(f"settings_file: {data['HOOK_SETTINGS_FILE']}")
    print(f"status: {data['HOOK_STATUS']}")
    if data.get("HOOK_STOP_HOOK"):
        print(f"stop_hook: {data['HOOK_STOP_HOOK']}")
    if data.get("HOOK_PROMPT_HOOK"):
        print(f"prompt_hook: {data['HOOK_PROMPT_HOOK']}")
    if data.get("HOOK_COMMAND"):
        print(f"command: {data['HOOK_COMMAND']}")
    if data.get("HOOK_ADDITIONAL_CONTEXT"):
        print(f"additional_context: {data['HOOK_ADDITIONAL_CONTEXT']}")


def cmd_status_stop_hook(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    stop_hooks = hooks_list(settings, "Stop")
    _idle_group, idle_hook = find_command_hook(stop_hooks, is_mark_idle_hook)
    _surface_group, surface_hook = find_command_hook(stop_hooks, is_surface_reply_enforce_hook)
    _session_stop_group, session_stop_hook = find_command_hook(stop_hooks, is_session_stop_hook)
    # mark-idle.sh keeps the legacy HOOK_STOP_HOOK / HOOK_COMMAND fields so
    # existing operators / scripts that grep for them stay green. The
    # HOOK_STOP_HOOK_SUITE field (#541 PR-B) reports the aggregate state so
    # the upgrade and smoke paths can detect partial drops of the new pair.
    command = str(idle_hook.get("command") or "") if idle_hook else ""
    suite_present = bool(idle_hook and surface_hook and session_stop_hook)
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if suite_present else "missing",
        "HOOK_STOP_HOOK": "present" if idle_hook else "missing",
        "HOOK_STOP_HOOK_SUITE": "present" if suite_present else "missing",
        "HOOK_STOP_HOOK_MARK_IDLE": "present" if idle_hook else "missing",
        "HOOK_STOP_HOOK_SURFACE_REPLY_ENFORCE": "present" if surface_hook else "missing",
        "HOOK_STOP_HOOK_SESSION_STOP": "present" if session_stop_hook else "missing",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "true" if idle_hook and bool(idle_hook.get("additionalContext")) else "false",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"stop_hook_suite: {'present' if suite_present else 'missing'}")
        print(f"stop_hook_mark_idle: {'present' if idle_hook else 'missing'}")
        print(f"stop_hook_surface_reply_enforce: {'present' if surface_hook else 'missing'}")
        print(f"stop_hook_session_stop: {'present' if session_stop_hook else 'missing'}")
    return 0 if suite_present else 1


def cmd_status_session_start_hook(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    session_hooks = hooks_list(settings, "SessionStart")
    _group, hook = find_command_hook(session_hooks, is_session_start_hook)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "true" if hook and bool(hook.get("additionalContext")) else "false",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"session_start_hook: {'present' if hook else 'missing'}")
    return 0 if hook else 1


def ensure_command_hook(
    settings_path: Path,
    event_name: str,
    desired_command: str,
    matcher: Any,
    *,
    timeout: int = 3,
    additional_context: bool | None = None,
    status_message: str | None = None,
    group_matcher: str | None = None,
) -> bool:
    settings = ensure_settings_root(settings_path)
    event_hooks = hooks_list(settings, event_name)
    changed = False

    group, hook = find_command_hook(event_hooks, matcher)
    if hook is None:
        event_hooks.append(
            {
                **({"matcher": group_matcher} if group_matcher is not None else {}),
                "hooks": [
                    {
                        "type": "command",
                        "command": desired_command,
                        "timeout": timeout,
                        **({"statusMessage": status_message} if status_message is not None else {}),
                        **({"additionalContext": additional_context} if additional_context is not None else {}),
                    }
                ]
            }
        )
        changed = True
    else:
        if hook.get("type") != "command":
            hook["type"] = "command"
            changed = True
        if str(hook.get("command") or "") != desired_command:
            hook["command"] = desired_command
            changed = True
        if int(hook.get("timeout") or 0) != timeout:
            hook["timeout"] = timeout
            changed = True
        if status_message is not None and str(hook.get("statusMessage") or "") != status_message:
            hook["statusMessage"] = status_message
            changed = True
        if additional_context is not None and bool(hook.get("additionalContext")) != bool(additional_context):
            hook["additionalContext"] = additional_context
            changed = True
        if group_matcher is not None and group is not None and str(group.get("matcher") or "") != group_matcher:
            group["matcher"] = group_matcher
            changed = True
        if group is None:
            changed = True

    if changed:
        save_json(settings_path, settings)

    return changed


def cmd_ensure_stop_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    # Resolve the python interpreter once. --bash-bin is the only required
    # CLI flag historically (mark-idle.sh runs under bash), so we keep that
    # contract and discover a python3 via PATH for the new pair. The render
    # path that consumes this file later (bridge_link_claude_settings_to_shared)
    # does the same dance.
    python_bin = getattr(args, "python_bin", None) or shutil.which("python3") or "/usr/bin/python3"
    mark_idle_command = stop_hook_command(bridge_home, args.bash_bin)
    surface_command = surface_reply_enforce_hook_command(bridge_home, python_bin)
    session_stop_command = session_stop_hook_command(bridge_home, python_bin)

    # Issue #541 PR-B: ensure the full Stop hook suite. mark-idle.sh keeps
    # additionalContext=true (idle-wake context); surface-reply-enforce.py
    # and session-stop.py mirror agents/_template/.claude/settings.json
    # (no additionalContext, timeout 5 / 35 respectively).
    changed = ensure_command_hook(
        settings_path,
        "Stop",
        mark_idle_command,
        is_mark_idle_hook,
        timeout=3,
        additional_context=True,
    )
    changed = ensure_command_hook(
        settings_path,
        "Stop",
        surface_command,
        is_surface_reply_enforce_hook,
        timeout=5,
    ) or changed
    changed = ensure_command_hook(
        settings_path,
        "Stop",
        session_stop_command,
        is_session_stop_hook,
        timeout=35,
    ) or changed

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "present",
        "HOOK_STOP_HOOK_SUITE": "present",
        "HOOK_STOP_HOOK_MARK_IDLE": "present",
        "HOOK_STOP_HOOK_SURFACE_REPLY_ENFORCE": "present",
        "HOOK_STOP_HOOK_SESSION_STOP": "present",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": mark_idle_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("stop_hook_suite: present")
        print(f"surface_reply_enforce_command: {surface_command}")
        print(f"session_stop_command: {session_stop_command}")
    return 0


def cmd_ensure_session_start_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    desired_command = session_start_hook_command(bridge_home, args.python_bin, "text")
    changed = ensure_command_hook(
        settings_path,
        "SessionStart",
        desired_command,
        is_session_start_hook,
        timeout=3,
        additional_context=True,
    )

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": desired_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("session_start_hook: present")
    return 0


def cmd_ensure_pre_compact_hook(args: argparse.Namespace) -> int:
    """Register the Track 2 PreCompact event handler in settings.json.

    The hook timeout is set to 20s (the documented ceiling for PreCompact
    so a slow capture can't block compaction), and the hook always exits 0
    on its own (see `hooks/pre-compact.py`). The failure-mode contract is
    therefore: compaction proceeds regardless of capture success.
    """
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    desired_command = pre_compact_hook_command(bridge_home, args.python_bin)
    changed = ensure_command_hook(
        settings_path,
        "PreCompact",
        desired_command,
        is_pre_compact_hook,
        timeout=20,
    )
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_COMMAND": desired_command,
        "HOOK_TIMEOUT": "20",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("pre_compact_hook: present")
    return 0


def cmd_status_pre_compact_hook(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    hooks = hooks_list(settings, "PreCompact")
    _group, hook = find_command_hook(hooks, is_pre_compact_hook)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_COMMAND": command,
        "HOOK_TIMEOUT": str(int(hook.get("timeout") or 0) if hook else 0),
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"pre_compact_hook: {'present' if hook else 'missing'}")
    return 0 if hook else 1


def cmd_status_prompt_hook(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    prompt_hooks = hooks_list(settings, "UserPromptSubmit")
    _clear_group, clear_hook = find_command_hook(prompt_hooks, is_clear_idle_hook)
    _timestamp_group, timestamp_hook = find_command_hook(prompt_hooks, is_prompt_timestamp_hook)
    command = str(clear_hook.get("command") or "") if clear_hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if clear_hook and timestamp_hook else "missing",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present" if clear_hook else "missing",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "true" if timestamp_hook and bool(timestamp_hook.get("additionalContext")) else "false",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"timestamp_hook: {'present' if timestamp_hook else 'missing'}")
        if timestamp_hook:
            print(f"timestamp_command: {str(timestamp_hook.get('command') or '')}")
    return 0 if clear_hook and timestamp_hook else 1


def cmd_ensure_prompt_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    desired_command = prompt_hook_command(bridge_home, args.bash_bin)
    timestamp_command = prompt_timestamp_hook_command(bridge_home, args.python_bin, "text")
    changed = ensure_command_hook(
        settings_path,
        "UserPromptSubmit",
        desired_command,
        is_clear_idle_hook,
        timeout=3,
    )
    changed = ensure_command_hook(
        settings_path,
        "UserPromptSubmit",
        timestamp_command,
        is_prompt_timestamp_hook,
        timeout=3,
        additional_context=True,
    ) or changed

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present",
        "HOOK_COMMAND": desired_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("timestamp_hook: present")
        print(f"timestamp_command: {timestamp_command}")
    return 0


def cmd_status_prompt_guard_hook(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    prompt_hooks = hooks_list(settings, "UserPromptSubmit")
    _group, hook = find_command_hook(prompt_hooks, is_prompt_guard_hook)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present" if hook else "missing",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"prompt_guard_hook: {'present' if hook else 'missing'}")
    return 0 if hook else 1


def cmd_ensure_prompt_guard_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    desired_command = prompt_guard_hook_command(bridge_home, args.python_bin)
    changed = ensure_command_hook(
        settings_path,
        "UserPromptSubmit",
        desired_command,
        is_prompt_guard_hook,
        timeout=3,
        additional_context=True,
    )
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present",
        "HOOK_COMMAND": desired_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("prompt_guard_hook: present")
    return 0


def cmd_status_tool_policy_hooks(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)
    pre_hooks = hooks_list(settings, "PreToolUse")
    post_hooks = hooks_list(settings, "PostToolUse")
    failure_hooks = hooks_list(settings, "PostToolUseFailure")
    _pre_group, pre_hook = find_command_hook(pre_hooks, is_tool_policy_hook)
    _post_group, post_hook = find_command_hook(post_hooks, is_tool_policy_hook)
    _failure_group, failure_hook = find_command_hook(failure_hooks, is_tool_policy_hook)
    command = str(pre_hook.get("command") or "") if pre_hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if pre_hook and post_hook and failure_hook else "missing",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"pre_tool_use_hook: {'present' if pre_hook else 'missing'}")
        print(f"post_tool_use_hook: {'present' if post_hook else 'missing'}")
        print(f"post_tool_failure_hook: {'present' if failure_hook else 'missing'}")
    return 0 if pre_hook and post_hook and failure_hook else 1


def cmd_ensure_tool_policy_hooks(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
    desired_command = tool_policy_hook_command(bridge_home, args.python_bin)
    changed = False
    changed = ensure_command_hook(
        settings_path,
        "PreToolUse",
        desired_command,
        is_tool_policy_hook,
        timeout=3,
        additional_context=True,
    ) or changed
    changed = ensure_command_hook(
        settings_path,
        "PostToolUse",
        desired_command,
        is_tool_policy_hook,
        timeout=3,
        additional_context=True,
    ) or changed
    changed = ensure_command_hook(
        settings_path,
        "PostToolUseFailure",
        desired_command,
        is_tool_policy_hook,
        timeout=3,
        additional_context=True,
    ) or changed
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": desired_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("pre_tool_use_hook: present")
        print("post_tool_use_hook: present")
        print("post_tool_failure_hook: present")
    return 0


def codex_hooks_path(args: argparse.Namespace) -> Path:
    hooks_file = getattr(args, "codex_hooks_file", None)
    if hooks_file:
        return Path(hooks_file).expanduser()
    return Path.home() / ".codex" / "hooks.json"


def print_codex_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
        for key, value in data.items():
            print(shell_line(key, value))
        return

    print(f"hooks_file: {data['CODEX_HOOKS_FILE']}")
    print(f"status: {data['CODEX_HOOK_STATUS']}")
    print(f"session_start_hook: {data['CODEX_SESSION_START_HOOK']}")
    print(f"stop_hook: {data['CODEX_STOP_HOOK']}")
    print(f"prompt_hook: {data.get('CODEX_PROMPT_HOOK', 'missing')}")
    print(f"session_start_command: {data['CODEX_SESSION_START_COMMAND']}")
    print(f"stop_command: {data['CODEX_STOP_COMMAND']}")
    if data.get("CODEX_PROMPT_COMMAND"):
        print(f"prompt_command: {data['CODEX_PROMPT_COMMAND']}")
    print("feature_flag: launch_cli_override")


def cmd_status_codex_hooks(args: argparse.Namespace) -> int:
    hooks_path = codex_hooks_path(args)
    settings = ensure_settings_root(hooks_path)
    session_hooks = hooks_list(settings, "SessionStart")
    stop_hooks = hooks_list(settings, "Stop")
    prompt_hooks = hooks_list(settings, "UserPromptSubmit")
    pretool_hooks = hooks_list(settings, "PreToolUse")
    _session_group, session_hook = find_command_hook(session_hooks, is_codex_session_start_hook)
    _stop_group, stop_hook = find_command_hook(stop_hooks, is_codex_stop_hook)
    _prompt_group, prompt_hook = find_command_hook(prompt_hooks, is_codex_prompt_hook)
    _task_mode_group, task_mode_hook = find_command_hook(pretool_hooks, is_codex_task_mode_policy_hook)
    _output_shape_group, output_shape_hook = find_command_hook(stop_hooks, is_codex_review_output_shape_hook)
    core_present = bool(session_hook and stop_hook and prompt_hook)
    companion_present = bool(task_mode_hook and output_shape_hook)
    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "present" if core_present else "missing",
        "CODEX_SESSION_START_HOOK": "present" if session_hook else "missing",
        "CODEX_STOP_HOOK": "present" if stop_hook else "missing",
        "CODEX_PROMPT_HOOK": "present" if prompt_hook else "missing",
        "CODEX_TASK_MODE_POLICY_HOOK": "present" if task_mode_hook else "missing",
        "CODEX_REVIEW_OUTPUT_SHAPE_HOOK": "present" if output_shape_hook else "missing",
        "CODEX_COMPANION_HOOKS_STATUS": "present" if companion_present else "missing",
        "CODEX_SESSION_START_COMMAND": str(session_hook.get("command") or "") if session_hook else "",
        "CODEX_STOP_COMMAND": str(stop_hook.get("command") or "") if stop_hook else "",
        "CODEX_PROMPT_COMMAND": str(prompt_hook.get("command") or "") if prompt_hook else "",
        "CODEX_TASK_MODE_POLICY_COMMAND": str(task_mode_hook.get("command") or "") if task_mode_hook else "",
        "CODEX_REVIEW_OUTPUT_SHAPE_COMMAND": str(output_shape_hook.get("command") or "") if output_shape_hook else "",
    }
    print_codex_payload(payload, args.format)
    if args.format != "shell":
        print(f"prompt_hook: {'present' if prompt_hook else 'missing'}")
        if prompt_hook:
            print(f"prompt_command: {str(prompt_hook.get('command') or '')}")
        print(f"task_mode_policy_hook: {'present' if task_mode_hook else 'missing'}")
        if task_mode_hook:
            print(f"task_mode_policy_command: {str(task_mode_hook.get('command') or '')}")
        print(f"review_output_shape_hook: {'present' if output_shape_hook else 'missing'}")
        if output_shape_hook:
            print(f"review_output_shape_command: {str(output_shape_hook.get('command') or '')}")
    return 0 if core_present else 1


def cmd_ensure_codex_hooks(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    hooks_path = codex_hooks_path(args)
    hooks_path.parent.mkdir(parents=True, exist_ok=True)
    session_command = session_start_hook_command(bridge_home, args.python_bin, "codex")
    stop_command = codex_stop_hook_command(bridge_home, args.python_bin)
    prompt_command = prompt_timestamp_hook_command(bridge_home, args.python_bin, "codex")
    changed = False
    changed = ensure_command_hook(
        hooks_path,
        "SessionStart",
        session_command,
        is_codex_session_start_hook,
        timeout=3,
        status_message="Loading Agent Bridge queue context",
        group_matcher="startup|resume",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "Stop",
        stop_command,
        is_codex_stop_hook,
        timeout=3,
        status_message="Checking Agent Bridge inbox",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "UserPromptSubmit",
        prompt_command,
        is_codex_prompt_hook,
        timeout=3,
        status_message="Injecting Agent Bridge timestamp context",
    ) or changed

    # Companion-role hooks (Codex). Both ship audit-only by default; operators
    # promote to blocking via BRIDGE_CODEX_TASK_MODE_POLICY=block /
    # BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE=block in agent-roster.local.sh after
    # observing audit logs. Codex CLIs predating PreToolUse / Stop support
    # the entries cleanly: unknown event keys are ignored without hard-fail.
    task_mode_command = codex_task_mode_policy_hook_command(bridge_home, args.python_bin)
    output_shape_command = codex_review_output_shape_hook_command(bridge_home, args.python_bin)
    changed = ensure_command_hook(
        hooks_path,
        "PreToolUse",
        task_mode_command,
        is_codex_task_mode_policy_hook,
        timeout=3,
        status_message="Checking Codex task-mode policy",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "Stop",
        output_shape_command,
        is_codex_review_output_shape_hook,
        timeout=3,
        status_message="Validating Codex review output shape",
    ) or changed

    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "updated" if changed else "unchanged",
        "CODEX_SESSION_START_HOOK": "present",
        "CODEX_STOP_HOOK": "present",
        "CODEX_PROMPT_HOOK": "present",
        "CODEX_TASK_MODE_POLICY_HOOK": "present",
        "CODEX_REVIEW_OUTPUT_SHAPE_HOOK": "present",
        "CODEX_SESSION_START_COMMAND": session_command,
        "CODEX_STOP_COMMAND": stop_command,
        "CODEX_PROMPT_COMMAND": prompt_command,
        "CODEX_TASK_MODE_POLICY_COMMAND": task_mode_command,
        "CODEX_REVIEW_OUTPUT_SHAPE_COMMAND": output_shape_command,
    }
    print_codex_payload(payload, args.format)
    if args.format != "shell":
        print("prompt_hook: present")
        print(f"prompt_command: {prompt_command}")
        print("task_mode_policy_hook: present")
        print(f"task_mode_policy_command: {task_mode_command}")
        print("review_output_shape_hook: present")
        print(f"review_output_shape_command: {output_shape_command}")
    return 0


def next_backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = path.with_name(f"{path.stem}.agent-bridge.bak-{stamp}{path.suffix}")
    index = 1
    while candidate.exists():
      candidate = path.with_name(f"{path.stem}.agent-bridge.bak-{stamp}-{index}{path.suffix}")
      index += 1
    return candidate


# User-owned keys that bridge renderers must preserve across rerenders.
# Rationale: the shared and isolated renderers both compose
# `managed defaults < base < overlay` and overwrite the effective settings
# file on every call (`agent restart`, `agent rerender-settings --apply`,
# `bridge-init.sh` install, `agb upgrade propagate`). Without explicit
# preservation, per-agent user state — plugin enable/disable, marketplace
# pins, danger-prompt skip — is silently wiped on the next render even
# though it lives in the same JSON file Claude itself reads.
#
# (Issue #544 PR2 originally introduced this for the isolated renderer to
# survive the `settings.json` → `settings.effective.json` symlink
# transition. Issue #613 generalized it to the shared renderer after
# operators hit the same silent-clobber on every `--apply`.)
PRESERVED_USER_KEYS = (
    "enabledPlugins",
    "extraKnownMarketplaces",
    "skipDangerousModePermissionPrompt",
)


def _load_preserved_user_keys(effective_path: Path) -> dict[str, Any]:
    """Read the user-owned subset of an existing effective settings file.

    Returns an empty dict if the file is missing, unreadable, malformed,
    or not a JSON object. Callers merge the result *last* so user keys
    win over base/overlay/managed defaults.
    """
    if not effective_path.exists():
        return {}
    try:
        existing = load_json(effective_path)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(existing, dict):
        return {}
    return {k: existing[k] for k in PRESERVED_USER_KEYS if k in existing}


def cmd_render_shared_settings(args: argparse.Namespace) -> int:
    base_path = Path(args.base_settings_file).expanduser()
    overlay_path = Path(args.overlay_settings_file).expanduser()
    effective_path = Path(args.effective_settings_file).expanduser()

    base_payload = ensure_settings_root(base_path)
    overlay_payload = load_json(overlay_path)
    if overlay_payload in (None, ""):
        overlay_payload = {}
    if not isinstance(overlay_payload, dict):
        raise SystemExit(f"shared settings overlay must be a JSON object: {overlay_path}")

    launch_cmd = (getattr(args, "launch_cmd", "") or "") or None
    agent_class = (getattr(args, "agent_class", "") or "") or None
    managed_defaults = managed_claude_settings_defaults(launch_cmd, agent_class)
    # Compose: managed defaults < base < overlay < preserved user keys.
    # Preserved keys merge last so per-agent edits to the effective file
    # (e.g. operator-disabled plugins) survive every rerender. See
    # `PRESERVED_USER_KEYS` rationale above.
    preserved = _load_preserved_user_keys(effective_path)
    merged = merge_settings(managed_defaults, base_payload)
    merged = merge_settings(merged, overlay_payload)
    if preserved:
        merged = merge_settings(merged, preserved)
    save_json(effective_path, merged)

    payload = {
        "base_settings_file": str(base_path),
        "overlay_settings_file": str(overlay_path),
        "effective_settings_file": str(effective_path),
        "overlay_present": "true" if overlay_path.exists() else "false",
        "preserved_keys": ",".join(sorted(preserved.keys())),
    }
    if args.format == "shell":
        for key, value in payload.items():
            print(shell_line(key.upper(), value))
        return 0

    print(f"base_settings_file: {payload['base_settings_file']}")
    print(f"overlay_settings_file: {payload['overlay_settings_file']}")
    print(f"effective_settings_file: {payload['effective_settings_file']}")
    print(f"overlay_present: {payload['overlay_present']}")
    print(f"preserved_keys: [{payload['preserved_keys']}]")
    return 0


# Issue #544 PR2 — render bridge-managed Claude hook entries into a
# controller-owned `<isolated-home>/.claude/settings.effective.json` and
# atomically symlink `<isolated-home>/.claude/settings.json` to it. Chosen
# over a cross-UID symlink to the controller's effective file: a symlink
# would let the isolated UID silently rewrite the file (and clobber hook
# enforcement) on any operator action that touches `~/.claude/settings.json`
# from inside the session. Per-home rendering keeps the hook contract
# inside controller/root ownership while still letting the isolated UID
# read it. Hooks themselves run as the isolated UID — that is intended.
#
# Pre-existing isolated-UID user keys (see `PRESERVED_USER_KEYS`) are
# extracted from any prior regular `settings.json` at that path and merged
# into the rendered effective file so first-run user state survives the
# transition to symlink-managed.
def cmd_render_isolated_home_settings(args: argparse.Namespace) -> int:
    isolated_home = Path(args.isolated_home).expanduser()
    base_path = Path(args.base_settings_file).expanduser()
    overlay_path = Path(args.overlay_settings_file).expanduser()
    launch_cmd = (getattr(args, "launch_cmd", "") or "") or None
    agent_class = (getattr(args, "agent_class", "") or "") or None

    target_dir = isolated_home / ".claude"
    target_dir.mkdir(parents=True, exist_ok=True)
    effective_path = target_dir / "settings.effective.json"
    settings_link = target_dir / "settings.json"

    # 1. Preserve user keys. Source-of-truth selection:
    #   - If `settings.json` is a regular (non-symlink) file, read from
    #     it directly — that is the operator's first-run state pre-
    #     transition, and we must capture the keys before we replace
    #     the file with a symlink to the effective render.
    #   - If `settings.json` is a symlink (i.e. a prior render already
    #     ran), read the preserved keys back out of the existing
    #     `settings.effective.json`. Without this, the second render
    #     would silently drop the keys we preserved on the first pass,
    #     breaking idempotency and erasing the operator's user state
    #     on every subsequent rerender (e.g. agent restart).
    preserved: dict[str, Any] = {}
    if settings_link.exists() and not settings_link.is_symlink():
        preserved = _load_preserved_user_keys(settings_link)
    elif settings_link.is_symlink():
        preserved = _load_preserved_user_keys(effective_path)

    # 2. Compose: managed defaults < base < overlay < preserved user keys.
    base_payload = ensure_settings_root(base_path)
    # `load_json` raises on empty file; treat zero-byte as `{}` so the
    # renderer matches the operator-touch idiom (an empty overlay file
    # is a valid "no overrides" signal).
    if overlay_path.exists() and overlay_path.stat().st_size == 0:
        overlay_payload: Any = {}
    else:
        overlay_payload = load_json(overlay_path)
    if overlay_payload in (None, ""):
        overlay_payload = {}
    if not isinstance(overlay_payload, dict):
        raise SystemExit(f"isolated overlay must be a JSON object: {overlay_path}")

    managed_defaults = managed_claude_settings_defaults(launch_cmd, agent_class)
    merged = merge_settings(managed_defaults, base_payload)
    merged = merge_settings(merged, overlay_payload)
    if preserved:
        merged = merge_settings(merged, preserved)

    # 3. Atomic write of the effective file (mode 0644 so the isolated UID
    # can read it; ownership stays with whoever invoked us — controller
    # under the normal start path, root under sudo-backed reapply).
    effective_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = effective_path.with_suffix(effective_path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(merged, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, effective_path)

    # 4. Atomic symlink: settings.json -> settings.effective.json. Replace
    # any prior regular file (we already preserved its user keys above) or
    # stale symlink. Use a relative target so the link survives if the
    # isolated home moves under it.
    if settings_link.is_symlink() or settings_link.exists():
        settings_link.unlink()
    settings_link.symlink_to("settings.effective.json")

    payload = {
        "isolated_home": str(isolated_home),
        "effective_settings_file": str(effective_path),
        "settings_file": str(settings_link),
        "preserved_keys": ",".join(sorted(preserved.keys())),
    }
    if args.format == "shell":
        for key, value in payload.items():
            print(shell_line(key.upper(), value))
        return 0

    print(f"isolated_home: {payload['isolated_home']}")
    print(f"effective_settings_file: {payload['effective_settings_file']}")
    print(f"settings_file: {payload['settings_file']} -> settings.effective.json")
    print(f"preserved_keys: [{payload['preserved_keys']}]")
    return 0


def cmd_link_shared_settings(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    shared_path = Path(args.shared_settings_file).expanduser()
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    shared_path.parent.mkdir(parents=True, exist_ok=True)

    backup_path = ""
    status = "unchanged"

    if settings_path.is_symlink():
        current_target = os.path.realpath(settings_path)
        desired_target = os.path.realpath(shared_path)
        if current_target == desired_target:
            status = "unchanged"
        else:
            settings_path.unlink()
            status = "updated"
    elif settings_path.exists():
        backup = next_backup_path(settings_path)
        shutil.copy2(settings_path, backup)
        settings_path.unlink()
        backup_path = str(backup)
        status = "updated"
    else:
        status = "updated"

    if not settings_path.exists():
        rel_target = os.path.relpath(shared_path, start=settings_path.parent)
        settings_path.symlink_to(rel_target)

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": status,
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": str(shared_path),
        "HOOK_ADDITIONAL_CONTEXT": "",
    }
    print_payload(payload, args.format)
    if backup_path and args.format != "shell":
        print(f"backup_file: {backup_path}")
        print(f"symlink_target: {os.readlink(settings_path)}")
    elif args.format == "shell":
        print(shell_line("HOOK_BACKUP_FILE", backup_path))
        print(shell_line("HOOK_SYMLINK_TARGET", os.readlink(settings_path)))
    return 0


def claude_user_settings_path(args: argparse.Namespace) -> Path:
    user_file = getattr(args, "claude_user_file", None)
    if user_file:
        return Path(user_file).expanduser()
    return Path.home() / ".claude.json"


def cmd_ensure_project_trust(args: argparse.Namespace) -> int:
    user_file = claude_user_settings_path(args)
    workdir = str(Path(args.workdir).expanduser())
    payload = load_json(user_file)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"claude user settings root must be a JSON object: {user_file}")

    projects = payload.get("projects")
    if not isinstance(projects, dict):
        projects = {}
        payload["projects"] = projects

    project = projects.get(workdir)
    if not isinstance(project, dict):
        project = {}
        projects[workdir] = project

    changed = False
    if project.get("hasTrustDialogAccepted") is not True:
        project["hasTrustDialogAccepted"] = True
        changed = True
    if not isinstance(project.get("allowedTools"), list):
        project["allowedTools"] = []
        changed = True
    if not isinstance(project.get("mcpContextUris"), list):
        project["mcpContextUris"] = []
        changed = True
    if not isinstance(project.get("mcpServers"), dict):
        project["mcpServers"] = {}
        changed = True
    if not isinstance(project.get("enabledMcpjsonServers"), list):
        project["enabledMcpjsonServers"] = []
        changed = True
    if not isinstance(project.get("disabledMcpjsonServers"), list):
        project["disabledMcpjsonServers"] = []
        changed = True

    if changed:
        save_json(user_file, payload)

    status = "updated" if changed else "unchanged"
    if args.format == "shell":
        print(shell_line("HOOK_SETTINGS_FILE", str(user_file)))
        print(shell_line("HOOK_STATUS", status))
        print(shell_line("HOOK_PROJECT", workdir))
        print(shell_line("HOOK_TRUST_ACCEPTED", "true"))
    else:
        print(f"settings_file: {user_file}")
        print(f"status: {status}")
        print(f"project: {workdir}")
        print("trust_accepted: true")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-hooks.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    ensure_parser = subparsers.add_parser("ensure-stop-hook")
    ensure_parser.add_argument("--workdir")
    ensure_parser.add_argument("--settings-file")
    ensure_parser.add_argument("--bridge-home", required=True)
    ensure_parser.add_argument("--bash-bin", required=True)
    # --python-bin is optional for backward compatibility (existing callers
    # in lib/bridge-hooks.sh only pass --bash-bin); when omitted the helper
    # falls back to PATH-discovered python3. Required for the surface-reply
    # and session-stop entries added by issue #541 PR-B.
    ensure_parser.add_argument("--python-bin")
    ensure_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_parser.set_defaults(handler=cmd_ensure_stop_hook)

    status_parser = subparsers.add_parser("status-stop-hook")
    status_parser.add_argument("--workdir")
    status_parser.add_argument("--settings-file")
    status_parser.add_argument("--bridge-home", required=True)
    status_parser.add_argument("--bash-bin", required=True)
    status_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_parser.set_defaults(handler=cmd_status_stop_hook)

    ensure_session_parser = subparsers.add_parser("ensure-session-start-hook")
    ensure_session_parser.add_argument("--workdir")
    ensure_session_parser.add_argument("--settings-file")
    ensure_session_parser.add_argument("--bridge-home", required=True)
    ensure_session_parser.add_argument("--python-bin", required=True)
    ensure_session_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_session_parser.set_defaults(handler=cmd_ensure_session_start_hook)

    status_session_parser = subparsers.add_parser("status-session-start-hook")
    status_session_parser.add_argument("--workdir")
    status_session_parser.add_argument("--settings-file")
    status_session_parser.add_argument("--bridge-home", required=True)
    status_session_parser.add_argument("--python-bin", required=True)
    status_session_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_session_parser.set_defaults(handler=cmd_status_session_start_hook)

    ensure_pre_compact_parser = subparsers.add_parser("ensure-pre-compact-hook")
    ensure_pre_compact_parser.add_argument("--workdir")
    ensure_pre_compact_parser.add_argument("--settings-file")
    ensure_pre_compact_parser.add_argument("--bridge-home", required=True)
    ensure_pre_compact_parser.add_argument("--python-bin", required=True)
    ensure_pre_compact_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_pre_compact_parser.set_defaults(handler=cmd_ensure_pre_compact_hook)

    status_pre_compact_parser = subparsers.add_parser("status-pre-compact-hook")
    status_pre_compact_parser.add_argument("--workdir")
    status_pre_compact_parser.add_argument("--settings-file")
    status_pre_compact_parser.add_argument("--bridge-home", required=True)
    status_pre_compact_parser.add_argument("--python-bin", required=True)
    status_pre_compact_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_pre_compact_parser.set_defaults(handler=cmd_status_pre_compact_hook)

    ensure_prompt_parser = subparsers.add_parser("ensure-prompt-hook")
    ensure_prompt_parser.add_argument("--workdir")
    ensure_prompt_parser.add_argument("--settings-file")
    ensure_prompt_parser.add_argument("--bridge-home", required=True)
    ensure_prompt_parser.add_argument("--bash-bin", required=True)
    ensure_prompt_parser.add_argument("--python-bin", required=True)
    ensure_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_prompt_parser.set_defaults(handler=cmd_ensure_prompt_hook)

    status_prompt_parser = subparsers.add_parser("status-prompt-hook")
    status_prompt_parser.add_argument("--workdir")
    status_prompt_parser.add_argument("--settings-file")
    status_prompt_parser.add_argument("--bridge-home", required=True)
    status_prompt_parser.add_argument("--bash-bin", required=True)
    status_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_prompt_parser.set_defaults(handler=cmd_status_prompt_hook)

    ensure_prompt_guard_parser = subparsers.add_parser("ensure-prompt-guard-hook")
    ensure_prompt_guard_parser.add_argument("--workdir")
    ensure_prompt_guard_parser.add_argument("--settings-file")
    ensure_prompt_guard_parser.add_argument("--bridge-home", required=True)
    ensure_prompt_guard_parser.add_argument("--python-bin", required=True)
    ensure_prompt_guard_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_prompt_guard_parser.set_defaults(handler=cmd_ensure_prompt_guard_hook)

    status_prompt_guard_parser = subparsers.add_parser("status-prompt-guard-hook")
    status_prompt_guard_parser.add_argument("--workdir")
    status_prompt_guard_parser.add_argument("--settings-file")
    status_prompt_guard_parser.add_argument("--bridge-home", required=True)
    status_prompt_guard_parser.add_argument("--python-bin", required=True)
    status_prompt_guard_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_prompt_guard_parser.set_defaults(handler=cmd_status_prompt_guard_hook)

    ensure_tool_policy_parser = subparsers.add_parser("ensure-tool-policy-hooks")
    ensure_tool_policy_parser.add_argument("--workdir")
    ensure_tool_policy_parser.add_argument("--settings-file")
    ensure_tool_policy_parser.add_argument("--bridge-home", required=True)
    ensure_tool_policy_parser.add_argument("--python-bin", required=True)
    ensure_tool_policy_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_tool_policy_parser.set_defaults(handler=cmd_ensure_tool_policy_hooks)

    status_tool_policy_parser = subparsers.add_parser("status-tool-policy-hooks")
    status_tool_policy_parser.add_argument("--workdir")
    status_tool_policy_parser.add_argument("--settings-file")
    status_tool_policy_parser.add_argument("--bridge-home", required=True)
    status_tool_policy_parser.add_argument("--python-bin", required=True)
    status_tool_policy_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_tool_policy_parser.set_defaults(handler=cmd_status_tool_policy_hooks)

    ensure_codex_parser = subparsers.add_parser("ensure-codex-hooks")
    ensure_codex_parser.add_argument("--codex-hooks-file")
    ensure_codex_parser.add_argument("--bridge-home", required=True)
    ensure_codex_parser.add_argument("--python-bin", required=True)
    ensure_codex_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_codex_parser.set_defaults(handler=cmd_ensure_codex_hooks)

    status_codex_parser = subparsers.add_parser("status-codex-hooks")
    status_codex_parser.add_argument("--codex-hooks-file")
    status_codex_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_codex_parser.set_defaults(handler=cmd_status_codex_hooks)

    link_shared_parser = subparsers.add_parser("link-shared-settings")
    link_shared_parser.add_argument("--workdir", required=True)
    link_shared_parser.add_argument("--shared-settings-file", required=True)
    link_shared_parser.add_argument("--format", choices=("text", "shell"), default="text")
    link_shared_parser.set_defaults(handler=cmd_link_shared_settings)

    render_shared_parser = subparsers.add_parser("render-shared-settings")
    render_shared_parser.add_argument("--base-settings-file", required=True)
    render_shared_parser.add_argument("--overlay-settings-file", required=True)
    render_shared_parser.add_argument("--effective-settings-file", required=True)
    render_shared_parser.add_argument(
        "--launch-cmd",
        default="",
        help="Accepted for backwards compatibility; no longer consulted (issue #570 — managed autoCompactWindow default keys off --agent-class instead).",
    )
    render_shared_parser.add_argument(
        "--agent-class",
        default="",
        help="static|dynamic — drives the autoCompactWindow default (issue #593: static=400_000, dynamic=1_000_000, unknown=1_000_000).",
    )
    render_shared_parser.add_argument("--format", choices=("text", "shell"), default="text")
    render_shared_parser.set_defaults(handler=cmd_render_shared_settings)

    # Issue #544 PR2 — render the bridge-managed hook entries into a
    # controller-owned settings.effective.json placed under the isolated
    # UID's HOME, then symlink that home's settings.json to it. See
    # cmd_render_isolated_home_settings for the integrity-boundary
    # rationale (per-home rendered, not cross-UID symlink to controller).
    render_isolated_parser = subparsers.add_parser("render-isolated-home-settings")
    render_isolated_parser.add_argument("--isolated-home", required=True)
    render_isolated_parser.add_argument("--base-settings-file", required=True)
    render_isolated_parser.add_argument("--overlay-settings-file", required=True)
    render_isolated_parser.add_argument(
        "--launch-cmd",
        default="",
        help="Accepted for backwards compatibility; no longer consulted (issue #570 — managed autoCompactWindow default keys off --agent-class instead).",
    )
    render_isolated_parser.add_argument(
        "--agent-class",
        default="",
        help="static|dynamic — drives the autoCompactWindow default (issue #593: static=400_000, dynamic=1_000_000, unknown=1_000_000).",
    )
    render_isolated_parser.add_argument("--format", choices=("text", "shell"), default="text")
    render_isolated_parser.set_defaults(handler=cmd_render_isolated_home_settings)

    trust_parser = subparsers.add_parser("ensure-project-trust")
    trust_parser.add_argument("--workdir", required=True)
    trust_parser.add_argument("--claude-user-file")
    trust_parser.add_argument("--format", choices=("text", "shell"), default="text")
    trust_parser.set_defaults(handler=cmd_ensure_project_trust)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
