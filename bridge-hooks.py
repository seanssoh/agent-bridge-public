#!/usr/bin/env python3
"""Manage Claude Code and Codex hook settings for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

# Canonical isolation-aware pathlib helpers. Issue #1175: previously
# duplicated in both bridge-setup.py and bridge-hooks.py; consolidated
# to a single source of truth so a single fix lands in both files.
_BRIDGE_HOOKS_LIB_DIR = Path(__file__).resolve().parent / "lib"
if _BRIDGE_HOOKS_LIB_DIR.is_dir() and str(_BRIDGE_HOOKS_LIB_DIR) not in sys.path:  # noqa: raw-pathlib-controller-only — import-time controller-side lib dir probe
    sys.path.insert(0, str(_BRIDGE_HOOKS_LIB_DIR))

from bridge_iso_paths import (  # noqa: E402
    isolated_workdir_owner as _isolated_workdir_owner,
    resolve_isolated_owner_for_path as _resolve_isolated_owner_for_path,
    sudo_run_as as _sudo_run_as,
    safe_path_check as _safe_path_check,
    safe_read_env as _safe_read_env,
    safe_load_json as _safe_load_json,
)


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


def agent_bridge_development_plugin_settings(launch_cmd: str | None) -> dict[str, Any]:
    if not launch_cmd:
        return {}
    try:
        tokens = shlex.split(launch_cmd)
    except ValueError:
        tokens = launch_cmd.split()

    plugin_specs: list[str] = []
    seen: set[str] = set()
    index = 0
    while index < len(tokens):
        token = tokens[index]
        value = ""
        if token == "--dangerously-load-development-channels" and index + 1 < len(tokens):
            value = tokens[index + 1]
            index += 2
        elif token.startswith("--dangerously-load-development-channels="):
            value = token.split("=", 1)[1]
            index += 1
        else:
            index += 1
            continue
        if not value.startswith("plugin:") or not value.endswith("@agent-bridge"):
            continue
        spec = value[len("plugin:") :]
        if spec in seen:
            continue
        seen.add(spec)
        plugin_specs.append(spec)

    if not plugin_specs:
        return {}

    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if not bridge_home:
        bridge_home = str(Path(__file__).resolve().parent)
    return {
        "enabledPlugins": {spec: True for spec in plugin_specs},
        "extraKnownMarketplaces": {
            "agent-bridge": {
                "source": {
                    "source": "directory",
                    "path": bridge_home,
                }
            }
        },
    }


def managed_claude_settings_defaults(
    launch_cmd: str | None,
    agent_class: str | None = None,
) -> dict[str, Any]:
    # `promptSuggestionEnabled: False` disables Claude Code's inline
    # composer ghost text (the dimmed "Try asking …" suggestion that
    # appears in the input box after a turn completes). On bridge-managed
    # agents the daemon's pending-input detector
    # (`bridge_tmux_session_inject_busy` → `bridge_tmux_line_has_sgr_dim`,
    # `lib/bridge-tmux.sh:1322`) reads that ghost text as real typed
    # input and defers the first send of every queued task until the
    # nudge fallback fires (~30s–1min latency). PR #566 added an SGR-2
    # detector to filter the dim form, but newer Claude Code builds
    # render the suggestion with other ANSI shapes (24-bit gray,
    # 256-color faint, `\x1b[90m`) the narrow detector misses (#630).
    # Disabling the feature at the settings layer is the stable fix —
    # bridge-managed agents are operated through the queue, not by a
    # human typing in the composer, so the suggestion has no value here.
    # Operators who attach interactively and want it back can set
    # `promptSuggestionEnabled: true` in the per-agent overlay
    # (`settings.local.json`) — overlay wins over managed defaults.
    defaults = {
        "autoCompactWindow": resolve_managed_autocompact_window(launch_cmd, agent_class),
        "promptSuggestionEnabled": False,
    }
    # Issue #1073: bridge-managed Claude agents launch with
    # `--dangerously-skip-permissions`. On a fresh per-agent `CLAUDE_CONFIG_DIR`
    # the CLI displays a one-shot "Bypass Permissions mode" warning picker that
    # blocks the tmux session, which `bridge-run.sh`'s foreground-detect kills
    # and relaunches → infinite restart loop. `skipDangerousModePermissionPrompt`
    # = True in settings.json is Claude's documented opt-out. Setting it as a
    # managed default (rather than relying on operator-run `auth claude-token
    # sync`) ensures the prompt is suppressed on the very first launch of a
    # fresh channel agent — admin agents reusing the controller's already-
    # onboarded `~/.claude` never hit this, so it was only caught when the
    # first per-agent-config Claude agent (a Teams channel agent) was created.
    # Operator overlay (`settings.local.json`) still wins via the
    # `managed < base < overlay < preserved` merge order.
    if launch_cmd and "--dangerously-skip-permissions" in launch_cmd:
        defaults["skipDangerousModePermissionPrompt"] = True
    plugin_settings = agent_bridge_development_plugin_settings(launch_cmd)
    if plugin_settings:
        defaults = merge_settings(defaults, plugin_settings)
    return defaults


def load_json(path: Path) -> Any:
    # Controller-side JSON reader. Callers that may operate on isolated
    # paths must route through `_safe_load_json` (canonical helper in
    # `lib/bridge_iso_paths.py`) instead of this primitive — that
    # wrapper sudo-cats the body when the controller-direct read
    # raises PermissionError. This function intentionally remains a
    # thin pathlib wrapper for controller-only call sites
    # (`ensure_settings_root` against the operator's own
    # `<bridge_home>/.../settings.base.json`, etc.).
    if not path.exists():  # noqa: raw-pathlib-controller-only — primitive used by both controller-only and iso-routed callers; iso callers wrap with _safe_load_json
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — controller-owned hook scaffold; iso-routed callers stage via _ensure_dir_with_sudo upstream
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
    return str(path.expanduser())


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
    # Recognize both the active rendered spelling (`session-start.py
    # [--format codex]`) and the legacy `codex-session-start.py` wrapper
    # spelling so re-rendering an existing install rewrites the command
    # in place rather than appending a duplicate hook. The wrapper file
    # itself was removed in #1068 (HOOKS-SSOT); only the predicate match
    # remains as a migration courtesy.
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
    # Recognize both the active rendered spelling (`check-inbox.py
    # --format codex`) and the legacy `codex-stop.py` wrapper spelling
    # so re-rendering an existing install rewrites the command in place
    # rather than appending a duplicate hook. The wrapper file itself
    # was removed in #1068 (HOOKS-SSOT); only the predicate match
    # remains as a migration courtesy.
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
    hooks_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — codex hooks live under ~/.codex (controller-owned), not under isolated agent tree
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


def next_backup_path(path: Path, os_user: str | None = None) -> Path:
    # Backup-name collision loop. The candidate sits next to the
    # original (same parent dir, same owner), so when `os_user` is
    # provided we route the existence probe through `_safe_path_check`
    # — the same proactive-sudo + fail-closed wrapper the caller used
    # to confirm the original — instead of a raw `candidate.exists()`
    # that can raise PermissionError on a blind isolated directory
    # before the caller's sudo-backed copy2/rm fallback can fire
    # (#1175 r2 / PR #1176 codex review). When `os_user` is None the
    # wrapper falls through to the direct pathlib check with the
    # ancestor-walker recovery, so controller-only callers stay
    # well-behaved.
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = path.with_name(f"{path.stem}.agent-bridge.bak-{stamp}{path.suffix}")
    index = 1
    while _safe_path_check("exists", candidate, os_user):
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


def _bridge_home_from_base_settings(base_path: Path) -> Path | None:
    expanded = base_path.expanduser()
    try:
        if (
            expanded.name == "settings.json"
            and expanded.parent.name == ".claude"
            and expanded.parent.parent.name == "agents"
        ):
            return expanded.parent.parent.parent
    except IndexError:
        return None
    return None


def _normalize_bridge_hook_paths(settings: dict[str, Any], bridge_home: Path | None) -> None:
    if bridge_home is None:
        return
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    old_prefix = "~/.agent-bridge/hooks/"
    new_prefix = f"{bridge_home}/hooks/"
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            entries = group.get("hooks")
            if not isinstance(entries, list):
                continue
            for hook in entries:
                if not isinstance(hook, dict):
                    continue
                command = hook.get("command")
                if isinstance(command, str) and old_prefix in command:
                    hook["command"] = command.replace(old_prefix, new_prefix)


def _load_preserved_user_keys(effective_path: Path) -> dict[str, Any]:
    """Read the user-owned subset of an existing effective settings file.

    Returns an empty dict if the file is missing, unreadable, malformed,
    or not a JSON object. Callers merge the result *last* so user keys
    win over base/overlay/managed defaults.

    #1175: existence probe uses the canonical safe wrapper so the
    rerender that fires from `agent restart` against an isolated
    home's `.claude/settings.effective.json` does not raise
    PermissionError before the renderer can decide whether there is
    a preserved-key payload to merge — the controller may be unable
    to stat that path on a v2 isolated UID where the per-agent
    supplementary group is not in the controller's grouplist (#1170
    family). The owner is resolved via the walker so a leaf that
    doesn't yet exist still picks up the isolated lineage.
    """
    owner = _resolve_isolated_owner_for_path(effective_path)
    if not _safe_path_check("exists", effective_path, owner):
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
    _normalize_bridge_hook_paths(merged, _bridge_home_from_base_settings(base_path))
    save_json(effective_path, merged)

    # #1175: report-only `overlay_present` probe routes through the
    # canonical safe wrapper so the renderer does not raise a
    # traceback for an isolated overlay file the controller cannot
    # stat directly. The walker resolves the owner from the path's
    # ancestor lineage; on shared (non-isolated) installs the owner
    # is None and the wrapper degrades to a direct `path.exists()`.
    _overlay_owner_report = _resolve_isolated_owner_for_path(overlay_path)
    payload = {
        "base_settings_file": str(base_path),
        "overlay_settings_file": str(overlay_path),
        "effective_settings_file": str(effective_path),
        "overlay_present": "true" if _safe_path_check("exists", overlay_path, _overlay_owner_report) else "false",
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
    target_dir.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — render flow runs sudo-backed externally when the isolated home denies controller writes
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
    # #1175: existence/symlink probes route through the canonical
    # safe wrapper so a rerender against an isolated home (where the
    # controller may not have +x traversal on `.claude/`) does not
    # raise PermissionError before the renderer can pick a source-
    # of-truth branch. The owner is resolved per-path via the walker
    # so a leaf that doesn't yet exist still picks up the isolated
    # lineage. On shared (non-isolated) installs the owner is None
    # and the wrapper degrades to direct pathlib semantics.
    _settings_link_owner = _resolve_isolated_owner_for_path(settings_link)
    preserved: dict[str, Any] = {}
    if _safe_path_check("exists", settings_link, _settings_link_owner) and not _safe_path_check("is_symlink", settings_link, _settings_link_owner):
        preserved = _load_preserved_user_keys(settings_link)
    elif _safe_path_check("is_symlink", settings_link, _settings_link_owner):
        preserved = _load_preserved_user_keys(effective_path)

    # 2. Compose: managed defaults < base < overlay < preserved user keys.
    base_payload = ensure_settings_root(base_path)
    # `load_json` raises on empty file; treat zero-byte as `{}` so the
    # renderer matches the operator-touch idiom (an empty overlay file
    # is a valid "no overrides" signal).
    # #1175: existence probe through the safe wrapper. The subsequent
    # `.stat()` call is only reached when the safe wrapper confirmed
    # the path exists, so on isolated trees the stat is preceded by a
    # successful sudo `test -e`; the controller is already known to
    # have +x traversal on the parent at that point (otherwise the
    # safe probe would have routed through sudo and returned True
    # without ever stat-ing the inode directly). Still, wrap in a
    # PermissionError-guarded try/except so a late-revoked group does
    # not crash the renderer — fall through to load_json which then
    # raises a structured FileNotFoundError or JSONDecodeError the
    # caller can recover from.
    _overlay_owner_isolated = _resolve_isolated_owner_for_path(overlay_path)
    if _safe_path_check("exists", overlay_path, _overlay_owner_isolated):
        try:
            _overlay_is_empty = overlay_path.stat().st_size == 0  # noqa: raw-pathlib-controller-only — guarded by safe_path_check above + PermissionError-tolerant try/except
        except (OSError, PermissionError):
            _overlay_is_empty = False
    else:
        _overlay_is_empty = False
    if _overlay_is_empty:
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
    _normalize_bridge_hook_paths(merged, _bridge_home_from_base_settings(base_path))

    # 3. Atomic write of the effective file (mode 0644 so the isolated UID
    # can read it; ownership stays with whoever invoked us — controller
    # under the normal start path, root under sudo-backed reapply).
    effective_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — already-staged by target_dir.mkdir above; sudo-backed reapply caller has write access
    tmp = effective_path.with_suffix(effective_path.suffix + ".tmp")
    # E2E test on Ubuntu 24.04 VM (2026-05-16) caught a race: under
    # concurrent bootstrap (bridge-bootstrap.sh) + patch first-start +
    # watchdog firing, the parent dir occasionally gets recreated by
    # a sibling process between mkdir and os.replace, and the tmp
    # file disappears with the dir. Retry once with a fresh write
    # cycle before propagating; if it still fails after the retry,
    # treat as a soft warning and continue (the effective_path may
    # have been written by another writer in the meantime, or the
    # next agent-start tick will re-render).
    def _atomic_write_effective() -> None:
        with tmp.open("w", encoding="utf-8") as handle:
            json.dump(merged, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, effective_path)

    try:
        _atomic_write_effective()
    except FileNotFoundError:
        # Race window — parent dir got nuked between mkdir and replace,
        # or tmp got removed by a sibling cleanup. Retry once.
        effective_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — retry of the upstream mkdir; same sudo-backed-reapply contract
        try:
            _atomic_write_effective()
        except FileNotFoundError as exc:
            sys.stderr.write(
                "[bridge-hooks] effective-settings atomic write raced "
                f"twice; continuing — next agent-start tick will re-render. "
                f"detail={exc}\n"
            )

    # 4. Atomic symlink: settings.json -> settings.effective.json. Replace
    # any prior regular file (we already preserved its user keys above) or
    # stale symlink. Use a relative target so the link survives if the
    # isolated home moves under it.
    # #1175: probes route through the canonical safe wrapper (reuses
    # the owner resolved upstream at step 1). The `.unlink()` /
    # `.symlink_to()` calls themselves still need direct write access
    # on the isolated home — if controller lacks it the call raises
    # PermissionError, which is the correct surface (the renderer
    # cannot proceed without write access; the safe-probe was only
    # there to avoid raising on the read probe).
    if _safe_path_check("is_symlink", settings_link, _settings_link_owner) or _safe_path_check("exists", settings_link, _settings_link_owner):
        settings_link.unlink()  # noqa: raw-pathlib-controller-only — gated by safe_path_check above; symlink/unlink need direct write access by design (sudo-backed reapply caller has it)
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


# #1175: `_isolated_workdir_owner` + `_sudo_run_as` moved to
# `lib/bridge_iso_paths.py` (consolidated with the near-identical
# bridge-setup.py duplicates). The private names remain available
# via the top-of-file `from bridge_iso_paths import ... as _...`.


def _ensure_dir_with_sudo(path: Path, os_user: str | None) -> None:
    # #1120 sub-A: function name promised sudo escalation but the body
    # only reached sudo AFTER a controller-direct `path.mkdir(...)`
    # raised PermissionError. On v2 isolation the parent dir
    # (`<v2-root>/<agent>/` is `root:ab-agent-<slug> 2750`) blocks
    # controller writes, so the direct mkdir always raised and the
    # caller printed a Python traceback before the sudo fallback even
    # got a chance to silence it on its own line.
    #
    # Contract:
    #   - If `os_user` is None, attempt a best-effort recovery via
    #     `_isolated_workdir_owner(path)`. Callers that don't already
    #     know the isolation owner (e.g. callers that derive the path
    #     from a configuration field without consulting the workdir
    #     stat) can pass None and still get sudo-first routing on
    #     isolated trees. Returns None on non-Linux hosts and on
    #     controller-owned paths, in which case the function preserves
    #     the original controller-direct `mkdir` shape — byte-for-byte
    #     unchanged for shared-mode agents.
    #   - If `os_user` resolves to a name that is NOT the current
    #     process user, route through `sudo -n -u <os_user> mkdir -p
    #     <path>` FIRST. The isolated UID owns
    #     `<v2-root>/<agent>/workdir/` (mode 2770) so creating
    #     `<workdir>/.claude/` under it succeeds without controller
    #     intervention. On success, return cleanly (no PermissionError
    #     raised at all → no traceback).
    #   - If sudo escalation is unavailable (`_sudo_run_as` rc 127,
    #     non-Linux dev host) or fails (typically because an ancestor
    #     dir denies group write — e.g. `<v2-root>/<agent>/` mode 2750
    #     where the iso UID is in the group but cannot write, the
    #     #1145 shape), fall back to a controller-direct
    #     `path.mkdir(parents=True, exist_ok=True)`. On v2 isolation
    #     that controller-direct mkdir will itself fail with
    #     PermissionError — re-raise so the caller sees a real error
    #     rather than silent partial state. The caller is responsible
    #     for try/except OSError to surface a structured warning
    #     (#1145, #1119 / PR #1124 pattern).
    if os_user is None:
        os_user = _isolated_workdir_owner(path)
    current_user = ""
    try:
        import pwd
        current_user = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, ImportError):
        current_user = ""
    if os_user is not None and os_user != current_user:
        rc = _sudo_run_as(os_user, "mkdir", "-p", str(path))
        if rc == 0:
            return
        # Fall through to controller-direct attempt. This succeeds when
        # the path is actually controller-owned (mis-detection of iso
        # ownership via a group-only signature on a controller-owned
        # tree, etc.). When it fails with PermissionError we let it
        # propagate — better surface a real error than fail silently.
    path.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — sudo-first branch above already tried iso escalation; this is the documented controller-direct fallback


# #1175: `_safe_path_check` moved to `lib/bridge_iso_paths.py`
# (consolidated canonical implementation lifted from bridge-setup.py's
# r2 form — proactive sudo + sudo-stderr discrimination + 5s timeout,
# plus the bridge-hooks side's traceback-quiet fail-closed-on-blind-
# pathlib semantics). Pre-#1175 the hooks-side helper was the
# reactive shape — #1173 was the open ticket to bring it up to the
# canonical form. The shared module's `safe_path_check` is the
# canonical form, imported as `_safe_path_check` at the top of this
# file for back-compat with the historical private-name call sites.


def _safe_realpath(path: Path, os_user: str | None) -> str:
    """PermissionError-safe `os.path.realpath` for isolated workdirs.

    Companion to `_safe_path_check`. `os.path.realpath` resolves symlinks
    by stat-ing each component; on an isolated workdir the controller
    can hit PermissionError mid-resolution. Fall back to
    `sudo -n -u <agent-user> readlink -f`. Returns the original path
    string when the sudo fallback also fails (best-effort — the caller
    compares two realpaths for equality, so falling back to the raw
    string just forces the "not equal" branch and re-creates the link).
    """
    try:
        return os.path.realpath(path)
    except PermissionError:
        if os_user is None:
            raise
        result = subprocess.run(
            ["sudo", "-n", "-u", os_user, "readlink", "-f", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() or str(path)


def cmd_link_shared_settings(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    shared_path = Path(args.shared_settings_file).expanduser()
    # v0.8.8 #714 item 3 / #694: when the agent workdir is owned by a
    # linux-user-isolated account, controller-side `mkdir` / `unlink` /
    # `symlink_to` / `shutil.copy2` raise PermissionError because the
    # workdir is mode 0750 owned by `agent-bridge-<name>:<group>`. The
    # rerender / start path that drives this command runs as the
    # controller, so we sniff the workdir owner and escalate via
    # `sudo -n -u <agent-user>` for the file-system mutations only.
    # On non-isolated agents `os_user` is None and every fallback is a
    # no-op — the direct ops succeed first try, byte-for-byte
    # unchanged.
    #
    # #1145: even with uid-first owner detection (PR #1142) AND sudo-
    # first escalation in `_ensure_dir_with_sudo` (PR #1133), the
    # `sudo -u agent-bridge-<slug> mkdir -p` step can still fail when
    # the per-agent root `<v2-root>/<agent>/` is `root:ab-agent-<slug>
    # mode 2750` — the isolated UID is in the group but `2750` denies
    # group write, so creating `workdir/.claude/` under it requires
    # root (or a pre-scaffolded `workdir/` with mode 2770 owned by the
    # iso UID). When `link-shared-settings` runs before the
    # scaffold-as-root step that materializes `workdir/`, BOTH the
    # sudo-as-iso mkdir AND the controller-direct fallback raise
    # PermissionError. Pre-#1145 that bubbled up as a stacked
    # traceback and the wrapping `agent create` flow lost the rest of
    # its work. Apply the proven #1119 / PR #1124 watchdog pattern:
    # wrap the per-agent file-system ops in `try/except OSError`,
    # emit a structured single-line warning (no traceback), surface
    # `HOOK_STATUS=permission_denied` in the payload, and return 0 so
    # the create flow continues. The downstream `bridge_linux_prepare_
    # agent_isolation` step (which DOES run with root) re-materializes
    # the link, so the failure is recoverable.
    workdir = Path(args.workdir).expanduser()
    try:
        os_user = _isolated_workdir_owner(workdir)
        _ensure_dir_with_sudo(settings_path.parent, os_user)
        _ensure_dir_with_sudo(shared_path.parent, None)

        backup_path = ""
        status = "unchanged"

        if _safe_path_check("is_symlink", settings_path, os_user):
            current_target = _safe_realpath(settings_path, os_user)
            # `shared_path` is controller-owned (lives under shared/ in the
            # bridge runtime, never inside an isolated workdir). Pass
            # os_user=None to keep the realpath straightforward and avoid
            # an unnecessary sudo escalation surface.
            desired_target = _safe_realpath(shared_path, None)
            if current_target == desired_target:
                status = "unchanged"
            else:
                try:
                    settings_path.unlink()  # noqa: raw-pathlib-controller-only — guarded by try/except PermissionError with sudo rm fallback below
                except PermissionError:
                    if os_user is None:
                        raise
                    rc = _sudo_run_as(os_user, "rm", "-f", str(settings_path))
                    if rc != 0:
                        raise
                status = "updated"
        elif _safe_path_check("exists", settings_path, os_user):
            backup = next_backup_path(settings_path, os_user)
            try:
                shutil.copy2(settings_path, backup)  # noqa: raw-pathlib-controller-only — guarded by try/except PermissionError with sudo cp -p fallback below
            except PermissionError:
                if os_user is None:
                    raise
                rc = _sudo_run_as(os_user, "cp", "-p", str(settings_path), str(backup))
                if rc != 0:
                    raise
            try:
                settings_path.unlink()  # noqa: raw-pathlib-controller-only — guarded by try/except PermissionError with sudo rm fallback below
            except PermissionError:
                if os_user is None:
                    raise
                rc = _sudo_run_as(os_user, "rm", "-f", str(settings_path))
                if rc != 0:
                    raise
            backup_path = str(backup)
            status = "updated"
        else:
            status = "updated"

        if not _safe_path_check("exists", settings_path, os_user):
            rel_target = os.path.relpath(shared_path, start=settings_path.parent)
            try:
                settings_path.symlink_to(rel_target)
            except PermissionError:
                if os_user is None:
                    raise
                rc = _sudo_run_as(os_user, "ln", "-s", rel_target, str(settings_path))
                if rc != 0:
                    raise
    except OSError as exc:
        # #1145: surface a structured single-line warning so the operator
        # sees WHY the link failed (which UID, which path, what errno
        # name) without a Python traceback that obscures the rest of the
        # `agent create` envelope. Matches the watchdog #1119/PR #1124
        # `scan_error` shape: stable `error_kind` token + the failing
        # path. The downstream isolation-prepare step is privileged and
        # will re-link the settings under root; returning 0 with the
        # structured payload keeps the wrapping create flow intact.
        if isinstance(exc, PermissionError):
            error_kind = "permission_denied"
        elif isinstance(exc, FileNotFoundError):
            error_kind = "not_found"
        else:
            error_kind = "os_error"
        error_path = getattr(exc, "filename", None) or str(settings_path)
        print(
            f"[bridge-hooks] link-shared-settings: "
            f"{type(exc).__name__} ({exc.strerror or exc}); "
            f"path={error_path}; iso_user={os_user or '-'}",
            file=sys.stderr,
        )
        failure_payload = {
            "HOOK_SETTINGS_FILE": str(settings_path),
            "HOOK_STATUS": error_kind,
            "HOOK_STOP_HOOK": "",
            "HOOK_PROMPT_HOOK": "",
            "HOOK_COMMAND": str(shared_path),
            "HOOK_ADDITIONAL_CONTEXT": f"error_path={error_path}",
        }
        print_payload(failure_payload, args.format)
        if args.format == "shell":
            print(shell_line("HOOK_BACKUP_FILE", ""))
            print(shell_line("HOOK_SYMLINK_TARGET", ""))
            print(shell_line("HOOK_ERROR_KIND", error_kind))
            print(shell_line("HOOK_ERROR_PATH", str(error_path)))
        return 0

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


# Issue #730 — agent profile shared-doc/skill symlinks created on pre-v0.8
# layouts resolve to non-existent paths after the v0.8 home/workdir split.
# `cmd_relink_agent_profile_paths` iterates a closed set of expected link
# sites and replaces each broken symlink with one pointing at the correct
# relative target. Real files (non-symlinks) are skipped to avoid clobbering
# operator content. See bridge-watchdog.collect_broken_links — that scan
# surfaces the drift; this command remediates it. The relink contract is
# intentionally narrow:
#   * workdir/<DOC>.md → ../../../shared/<DOC>.md
#       (3 levels up from <bridge_home>/agents/<agent>/workdir/ → <bridge_home>;
#        canonical shared/ tree lives under BRIDGE_HOME).
#   * home/.claude/skills/<skill> → ../../../../../.claude/skills/<skill>
#       (5 levels up from <bridge_home>/agents/<agent>/home/.claude/skills/ →
#        <bridge_home>; bridge-managed skills mirror lives at
#        BRIDGE_HOME/.claude/skills/<skill>, not $HOME/.claude/skills/.)
# Anything else is left untouched. Profile-link layout owners (docs, skills)
# control this list; new link sites must be added here explicitly.
PROFILE_SHARED_DOC_NAMES = (
    "COMMON-INSTRUCTIONS.md",
    "CHANGE-POLICY.md",
    "TOOLS.md",
)


def _relink_one(
    link: Path,
    desired_rel_target: str,
    os_user: str | None,
) -> tuple[str, str]:
    """Resolve a single profile link and repair if broken.

    Returns ``(state, detail)`` where ``state`` is one of:
      * ``"already_ok"`` — link present, resolves to an existing path with the
        desired relative target (or any target that exists; we trust the
        operator's prior placement when it works).
      * ``"repaired"`` — link was missing, broken, or pointed at the wrong
        relative target; replaced with ``desired_rel_target`` via ``ln -sfn``.
      * ``"skipped"`` — a real (non-symlink) file/dir sits at ``link``; we
        do not clobber it. Caller should warn.
      * ``"failed"`` — relink attempt errored even after sudo fallback.

    ``detail`` carries a short human-readable note (existing target,
    expected target, exception class) for the JSON payload.
    """
    # Use lexists so a broken symlink registers as present.
    if os.path.lexists(link):
        is_symlink = os.path.islink(link)
        if not is_symlink:
            return ("skipped", "non-symlink path occupies link site")
        existing = os.readlink(link)
        # If the link resolves (target exists), leave it alone — the
        # operator may have a different but functioning relative target.
        # We only repair when the link is broken or already points at a
        # non-resolvable place.
        if os.path.exists(link) and existing == desired_rel_target:
            return ("already_ok", f"target={existing}")
        if os.path.exists(link) and existing != desired_rel_target:
            # Resolves, but not via the canonical relative form. Leave it —
            # less risky than rewriting a working link. Surface the drift
            # so an operator can decide.
            return ("already_ok", f"target={existing} (non-canonical, resolves)")
    # Replace (or create) the symlink atomically. `ln -sfn` is the
    # idempotent shell idiom — no readlink-then-unlink-then-symlink race.
    try:
        # Direct controller-side `ln -sfn`. Falls back to sudo on
        # PermissionError for isolated workdirs (#714 / #694 shape).
        rc = subprocess.run(
            ["ln", "-sfn", desired_rel_target, str(link)],
            check=False,
        ).returncode
        if rc != 0 and os_user is not None:
            rc = _sudo_run_as(os_user, "ln", "-sfn", desired_rel_target, str(link))
        if rc != 0:
            return ("failed", f"ln -sfn rc={rc}")
    except OSError as exc:
        return ("failed", f"{type(exc).__name__}: {exc}")
    return ("repaired", f"target={desired_rel_target}")


def _relink_agent_profile_paths(agent_home: Path, home_dir: Path) -> dict[str, list[str]]:
    """Resolve every expected profile link under ``agent_home``.

    ``agent_home`` is ``<bridge_home>/agents/<agent>``; ``home_dir`` is
    the operator's ``$HOME`` (passed in so tests can redirect via env
    without touching ``Path.home()``). Note: the bridge-managed skills
    mirror that the relink targets point at lives under ``BRIDGE_HOME``,
    not ``$HOME`` — see the skill-loop comment below.
    """
    result: dict[str, list[str]] = {
        "repaired": [],
        "already_ok": [],
        "skipped": [],
        "failed": [],
    }

    workdir = agent_home / "workdir"
    home_root = agent_home / "home"

    # Per-link-class isolation owner detection. workdir/ and home/ are both
    # owned by agent-bridge-<name> under v2 layout; check each independently
    # because shared-mode agents have neither subdir owned by an isolated
    # user (helper returns None).
    # #1175: resolve owners up-front via the walker (returns None on
    # non-isolated paths). All subsequent `exists` / `is_dir` probes
    # route through the canonical safe wrapper so a re-run scan
    # against a v2 isolated tree the controller cannot stat directly
    # does not raise PermissionError before the loop reaches its
    # per-entry skip branch — the source of the PostToolUseFailure
    # traceback flood (Gap 7).
    workdir_user = _resolve_isolated_owner_for_path(workdir)
    home_user = _resolve_isolated_owner_for_path(home_root)
    skills_dir = home_root / ".claude" / "skills"
    skills_dir_user = _resolve_isolated_owner_for_path(skills_dir)

    # Shared-doc links: workdir/<DOC>.md → ../../../shared/<DOC>.md.
    # 3 levels up from <bridge_home>/agents/<agent>/workdir/ lands at
    # <bridge_home>; the canonical shared/ tree lives directly under it.
    if _safe_path_check("exists", workdir, workdir_user):
        for name in PROFILE_SHARED_DOC_NAMES:
            link = workdir / name
            desired = f"../../../shared/{name}"
            state, detail = _relink_one(link, desired, workdir_user)
            result[state].append(f"workdir/{name}: {detail}")

    # Skill links: home/.claude/skills/<skill> → ../../../../../.claude/skills/<skill>.
    # 5 levels up from <bridge_home>/agents/<agent>/home/.claude/skills/ resolves to:
    #   $BRIDGE_HOME/.claude/skills/<skill>
    # (NOT $HOME/.claude/skills/<skill> — the on-disk skill mirror lives inside
    # the bridge home, not the operator's home directory.)
    # We relink every entry that already exists in the agent's skills dir
    # (operator's source of truth for which skills the agent should see).
    # Missing-source skills (operator removed the
    # $BRIDGE_HOME/.claude/skills/<skill> dir) still get the corrected link
    # target — if the operator restores the skill later the link will resolve.
    #
    # #1175: `skills_dir.is_dir()` was a HIGH site — under v2 isolation
    # the controller's `is_dir` raises PermissionError on an isolated
    # skills/ tree, contributing to the PostToolUseFailure traceback
    # flood. Route the existence probe through the safe wrapper; the
    # `iterdir()` and per-entry `is_dir()` still need direct read
    # access (best-effort — fall through to surface "skipped" on
    # PermissionError instead of crashing).
    if _safe_path_check("exists", skills_dir, skills_dir_user):
        try:
            _skills_dir_is_dir = skills_dir.is_dir()  # noqa: raw-pathlib-controller-only — guarded by safe_path_check above; iterdir() below also needs direct read
        except (OSError, PermissionError):
            _skills_dir_is_dir = False
        if _skills_dir_is_dir:
            try:
                _skills_entries = sorted(skills_dir.iterdir())
            except (OSError, PermissionError):
                _skills_entries = []
            for entry in _skills_entries:
                link = skills_dir / entry.name
                # Only consider symlink entries — anything else (directory or
                # regular file) we surface as skipped without clobbering.
                if not os.path.islink(link):
                    try:
                        _entry_is_dir = entry.is_dir()  # noqa: raw-pathlib-controller-only — iterdir() result; PermissionError-tolerant try/except above
                    except (OSError, PermissionError):
                        _entry_is_dir = False
                    if _entry_is_dir:
                        result["skipped"].append(
                            f"home/.claude/skills/{entry.name}: real directory occupies link site"
                        )
                    else:
                        # Regular file (or other non-dir/non-symlink) at a
                        # skill slot — surface so the operator sees it instead
                        # of silently skipping. Do not clobber.
                        result["skipped"].append(
                            f"home/.claude/skills/{entry.name}: non-symlink/non-dir file occupies link site"
                        )
                    continue
                desired = f"../../../../../.claude/skills/{entry.name}"
                state, detail = _relink_one(link, desired, home_user)
                result[state].append(f"home/.claude/skills/{entry.name}: {detail}")
        else:
            result["skipped"].append("home/.claude/skills: not a directory")

    return result


def _is_hud_status_line(cmd: str) -> bool:
    """Return True if *cmd* looks like a claude-hud statusLine command."""
    return "claude-hud" in cmd or "src/index.ts" in cmd or "index.js" in cmd


def _hud_tap_present(cmd: str) -> bool:
    return "hud-usage-tap" in cmd


def _patch_hud_command(cmd: str, tap_path: str) -> str:
    """Insert `python3 <tap_path> |` before the final bun/node exec call.

    Handles both `exec "…bun…"` and `exec "…node…"` patterns.  If no
    exec-runtime pattern is found, prepend the tap unconditionally so the
    tap is still active (minor format change is better than silent no-op).
    """
    import re

    tap_prefix = f"python3 {shlex.quote(tap_path)} | "
    pattern = re.compile(r'(exec\s+"[^"]*(?:bun|node)[^"]*")')
    if pattern.search(cmd):
        return pattern.sub(rf"{tap_prefix}\1", cmd, count=1)
    # Fallback: prepend at start of last semicolon-separated clause.
    parts = cmd.rsplit(";", 1)
    if len(parts) == 2:
        return parts[0] + "; " + tap_prefix + parts[1].lstrip()
    return tap_prefix + cmd


def cmd_ensure_hud_usage_tap(args: argparse.Namespace) -> int:
    """Patch a HUD statusLine command to pipe through hud-usage-tap.py.

    Reads the current statusLine.command from settings.json.  If it is a
    HUD command but does not yet include the tap, rewrites it in-place to
    prepend `python3 <bridge_home>/scripts/hud-usage-tap.py |` before the
    bun/node exec call.  Idempotent: re-running after patching is a no-op.
    """
    bridge_home = Path(args.bridge_home).expanduser()
    tap_path = str(bridge_home / "scripts" / "hud-usage-tap.py")
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)

    sl = settings.get("statusLine")
    if not isinstance(sl, dict):
        payload = {
            "HOOK_SETTINGS_FILE": str(settings_path),
            "HOOK_STATUS": "no-hud",
            "HOOK_STOP_HOOK": "",
            "HOOK_PROMPT_HOOK": "",
            "HOOK_COMMAND": "",
        }
        print_payload(payload, args.format)
        if args.format != "shell":
            print("hud_usage_tap: no-hud (statusLine not present or not a dict)")
        return 1

    cmd = sl.get("command", "")
    if not isinstance(cmd, str) or not _is_hud_status_line(cmd):
        payload = {
            "HOOK_SETTINGS_FILE": str(settings_path),
            "HOOK_STATUS": "no-hud",
            "HOOK_STOP_HOOK": "",
            "HOOK_PROMPT_HOOK": "",
            "HOOK_COMMAND": cmd,
        }
        print_payload(payload, args.format)
        if args.format != "shell":
            print("hud_usage_tap: no-hud (statusLine.command is not a HUD command)")
        return 1

    if _hud_tap_present(cmd):
        payload = {
            "HOOK_SETTINGS_FILE": str(settings_path),
            "HOOK_STATUS": "present",
            "HOOK_STOP_HOOK": "",
            "HOOK_PROMPT_HOOK": "",
            "HOOK_COMMAND": cmd,
        }
        print_payload(payload, args.format)
        if args.format != "shell":
            print("hud_usage_tap: present")
        return 0

    patched = _patch_hud_command(cmd, tap_path)
    settings["statusLine"]["command"] = patched
    save_json(settings_path, settings)

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": patched,
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("hud_usage_tap: updated")
    return 0


def cmd_status_hud_usage_tap(args: argparse.Namespace) -> int:
    settings_path = resolve_settings_path(args)
    settings = ensure_settings_root(settings_path)

    sl = settings.get("statusLine")
    cmd = (sl or {}).get("command", "") if isinstance(sl, dict) else ""
    if not cmd or not _is_hud_status_line(cmd):
        status = "no-hud"
        rc = 1
    elif _hud_tap_present(cmd):
        status = "present"
        rc = 0
    else:
        status = "missing"
        rc = 1

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": status,
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": cmd,
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print(f"hud_usage_tap: {status}")
    return rc


def _resolve_agent_home_root(args: argparse.Namespace) -> Path:
    """Return the directory under which `<agent>/` agent homes live."""
    if getattr(args, "agent_home_root", None):
        return Path(args.agent_home_root).expanduser()
    bridge_home = (
        getattr(args, "bridge_home", None)
        or os.environ.get("BRIDGE_HOME")
        or str(Path.home() / ".agent-bridge")
    )
    return Path(bridge_home).expanduser() / "agents"


def cmd_relink_agent_profile_paths(args: argparse.Namespace) -> int:
    agent_home_root = _resolve_agent_home_root(args)
    home_dir = Path(os.environ.get("HOME") or str(Path.home())).expanduser()

    # #1175: `agent_home_root` lives under `$BRIDGE_HOME/agents/` which is
    # controller-owned on shared-mode installs but may carry isolated
    # children under v2 (`<v2-root>/<agent>/` = `root:ab-agent-<a>` mode
    # 2750). The `is_dir` probe must not raise on a sub-tree the
    # controller cannot stat — route through the canonical safe wrapper.
    _root_owner = _resolve_isolated_owner_for_path(agent_home_root)

    selected: list[str] = []
    if getattr(args, "all_agents", False):
        if _safe_path_check("exists", agent_home_root, _root_owner):
            try:
                _is_root_dir = agent_home_root.is_dir()  # noqa: raw-pathlib-controller-only — guarded by safe_path_check above
            except (OSError, PermissionError):
                _is_root_dir = False
            if _is_root_dir:
                try:
                    _agent_entries = sorted(agent_home_root.iterdir())
                except (OSError, PermissionError):
                    _agent_entries = []
                for entry in _agent_entries:
                    try:
                        _entry_is_dir = entry.is_dir()  # noqa: raw-pathlib-controller-only — iterdir() result; PermissionError-tolerant try/except above
                    except (OSError, PermissionError):
                        _entry_is_dir = False
                    if not _entry_is_dir:
                        continue
                    if entry.name.startswith(".") or entry.name in {"_template", "shared"}:
                        continue
                    selected.append(entry.name)
    elif getattr(args, "agent", None):
        selected = [args.agent]
    else:
        print(
            "[bridge-hooks] relink-profile-paths requires --agent <name> or --all-agents",
            file=sys.stderr,
        )
        return 2

    agents_payload: list[dict[str, Any]] = []
    overall_failed = 0
    for agent in selected:
        agent_home = agent_home_root / agent
        # #1175: per-agent existence/is_dir probe through the safe
        # wrapper so a v2 isolated agent home that the controller
        # cannot stat directly does not raise a traceback before the
        # "agent home not found" skip can fire.
        _agent_home_owner = _resolve_isolated_owner_for_path(agent_home)
        if not _safe_path_check("exists", agent_home, _agent_home_owner):
            agents_payload.append(
                {
                    "agent": agent,
                    "repaired": [],
                    "already_ok": [],
                    "skipped": [f"agent home not found: {agent_home}"],
                    "failed": [],
                }
            )
            continue
        report = _relink_agent_profile_paths(agent_home, home_dir)
        overall_failed += len(report["failed"])
        agents_payload.append({"agent": agent, **report})

    if getattr(args, "json", False):
        print(json.dumps({"agents": agents_payload}, ensure_ascii=False, indent=2))
    else:
        for entry in agents_payload:
            agent = entry["agent"]
            print(
                f"agent={agent} "
                f"repaired={len(entry['repaired'])} "
                f"already_ok={len(entry['already_ok'])} "
                f"skipped={len(entry['skipped'])} "
                f"failed={len(entry['failed'])}"
            )
            for line in entry["repaired"]:
                print(f"  repaired: {line}")
            for line in entry["skipped"]:
                print(f"  skipped: {line}")
            for line in entry["failed"]:
                print(f"  failed: {line}")
    # Non-zero exit only when relink itself errored (not when paths were
    # skipped or already ok). The upgrader treats this as informational.
    return 1 if overall_failed else 0


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

    # Issue #730 — repair v0.8 layout shared-doc/skill profile symlinks.
    relink_profile_parser = subparsers.add_parser("relink-profile-paths")
    relink_target = relink_profile_parser.add_mutually_exclusive_group(required=True)
    relink_target.add_argument("--agent", help="Single agent name under <bridge-home>/agents/")
    relink_target.add_argument(
        "--all-agents",
        action="store_true",
        help="Iterate every agent directory under <bridge-home>/agents/",
    )
    relink_profile_parser.add_argument(
        "--bridge-home",
        help="Override BRIDGE_HOME; defaults to env BRIDGE_HOME or ~/.agent-bridge.",
    )
    relink_profile_parser.add_argument(
        "--agent-home-root",
        help="Override the agents root directly (defaults to <bridge-home>/agents).",
    )
    relink_profile_parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON payload instead of the human-readable summary.",
    )
    relink_profile_parser.set_defaults(handler=cmd_relink_agent_profile_paths)

    hud_tap_ensure_parser = subparsers.add_parser(
        "ensure-hud-usage-tap",
        help="Patch a HUD statusLine command to pipe through hud-usage-tap.py.",
    )
    hud_tap_ensure_parser.add_argument("--workdir")
    hud_tap_ensure_parser.add_argument("--settings-file")
    hud_tap_ensure_parser.add_argument("--bridge-home", required=True)
    hud_tap_ensure_parser.add_argument("--python-bin", required=True)
    hud_tap_ensure_parser.add_argument(
        "--format", choices=("text", "shell"), default="text"
    )
    hud_tap_ensure_parser.set_defaults(handler=cmd_ensure_hud_usage_tap)

    hud_tap_status_parser = subparsers.add_parser(
        "status-hud-usage-tap",
        help="Report whether the HUD statusLine command includes hud-usage-tap.py.",
    )
    hud_tap_status_parser.add_argument("--workdir")
    hud_tap_status_parser.add_argument("--settings-file")
    hud_tap_status_parser.add_argument("--bridge-home", required=True)
    hud_tap_status_parser.add_argument(
        "--format", choices=("text", "shell"), default="text"
    )
    hud_tap_status_parser.set_defaults(handler=cmd_status_hud_usage_tap)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
