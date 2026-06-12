#!/usr/bin/env python3
"""Manage Claude Code and Codex hook settings for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import re
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
    sudo_run_as_capture as _sudo_run_as_capture,
    safe_path_check as _safe_path_check,
    safe_read_env as _safe_read_env,
    safe_load_json as _safe_load_json,
    # Phase 2 lift: pull the canonical realpath + ensure_dir helpers
    # from the shared module. The local `_safe_realpath` and
    # `_ensure_dir_with_sudo` wrappers below now delegate to these
    # canonical names instead of re-implementing the sudo + fallback
    # logic. A future bug fix on either side lands in ONE place
    # (lib/bridge_iso_paths.py) rather than both files at once.
    safe_realpath as _safe_realpath_canonical,
    ensure_dir as _ensure_dir_canonical,
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


# Issue #1453: the launch command may carry the channel plugin set under
# either the internal `--dangerously-load-development-channels` flag or the
# public `--channels` alias the bridge actually threads through to the
# running process (lib/bridge-hooks.sh:156, #570). Both must be parsed
# identically — see `launched_channel_plugin_specs`.
_CHANNEL_PLUGIN_FLAGS = (
    "--dangerously-load-development-channels",
    "--channels",
)


def _channel_item_to_spec(item: str) -> str | None:
    """Map a single channel item to its `<plugin>@<marketplace>` spec, or
    None if the item is not a plugin channel.

    A channel item is the `bridge_qualify_channel_item` form: either
    `plugin:<name>@<marketplace>` (a Claude Code plugin channel, the only
    kind that appears in `enabledPlugins`) or `server:<name>` (a transport,
    NOT a plugin). Returns the spec with the leading `plugin:` stripped
    (matching the `enabledPlugins` key form Claude Code records) for plugin
    items; returns None for `server:` items and anything malformed (empty
    plugin name or marketplace id).
    """
    item = item.strip()
    if not item.startswith("plugin:") or "@" not in item:
        return None
    spec = item[len("plugin:") :]
    plugin_name, _sep, marketplace_id = spec.rpartition("@")
    if not plugin_name or not marketplace_id:
        return None
    return spec


def channel_specs_from_csv(channels_csv: str | None) -> list[str]:
    """Return the ordered, de-duped plugin specs from a normalized channels
    CSV (`plugin:a@m,plugin:b@m,server:x`).

    This is the form `bridge_agent_channels_csv` (lib/bridge-agents.sh:6259)
    emits — the SSOT for an agent's effective channel set, sourced from
    `BRIDGE_AGENT_CHANNELS` (the roster) and threaded into the renderers as
    `--channels-csv` (#1453). The bridge composes the actual `--channels`
    launch flag from this same set at launch time, so for normally-created
    channel agents the stored `--launch-cmd` does NOT carry `--channels` —
    the CSV is the only signal the renderer has.
    """
    if not channels_csv:
        return []
    specs: list[str] = []
    seen: set[str] = set()
    for item in channels_csv.split(","):
        spec = _channel_item_to_spec(item)
        if spec is None or spec in seen:
            continue
        seen.add(spec)
        specs.append(spec)
    return specs


def launched_channel_plugin_specs(launch_cmd: str | None) -> list[str]:
    """Return the ordered, de-duped `<plugin>@<marketplace>` specs carried in
    the launch command's channel flags.

    Parses both the internal `--dangerously-load-development-channels` flag
    and the public `--channels` alias (#1453). A single flag value may itself
    be a CSV of channel items (`plugin:a@m,plugin:b@m,server:x`) — the form
    `bridge_extract_channels_from_command` (lib/bridge-agents.sh:5735)
    parses. `server:` items are dropped. The leading `plugin:` prefix is
    stripped from each returned spec.

    NOTE: for a normally-created channel agent the bridge composes the
    `--channels` flag from `BRIDGE_AGENT_CHANNELS` at launch time and the
    *stored* launch command (what the renderer is fed) does NOT carry it; in
    that case this returns []. The renderer must therefore ALSO consult the
    `--channels-csv` it is given — see `effective_channel_plugin_specs`. This
    function still matters for launch commands that DO carry the flag inline
    (explicit `--channels`/dev-channels args, e.g. some dynamic agents).
    """
    if not launch_cmd:
        return []
    try:
        tokens = shlex.split(launch_cmd)
    except ValueError:
        tokens = launch_cmd.split()

    specs: list[str] = []
    seen: set[str] = set()
    index = 0
    while index < len(tokens):
        token = tokens[index]
        value = ""
        if token in _CHANNEL_PLUGIN_FLAGS and index + 1 < len(tokens):
            value = tokens[index + 1]
            index += 2
        elif "=" in token and token.split("=", 1)[0] in _CHANNEL_PLUGIN_FLAGS:
            value = token.split("=", 1)[1]
            index += 1
        else:
            index += 1
            continue
        for item in value.split(","):
            spec = _channel_item_to_spec(item)
            if spec is None or spec in seen:
                continue
            seen.add(spec)
            specs.append(spec)
    return specs


def effective_channel_plugin_specs(
    launch_cmd: str | None,
    channels_csv: str | None = None,
) -> list[str]:
    """Return the ordered, de-duped union of the agent's effective channel
    plugin specs from BOTH signals the renderer has (#1453):

      - the launch command's inline channel flags
        (`launched_channel_plugin_specs`), and
      - the agent's resolved channels CSV (`channel_specs_from_csv`), sourced
        from `BRIDGE_AGENT_CHANNELS` (the SSOT) and passed as `--channels-csv`.

    The CSV is required because the bridge composes the `--channels` launch
    flag from `BRIDGE_AGENT_CHANNELS` at launch time — the *stored* launch
    command the renderer is fed (`bridge_agent_launch_cmd_raw`) does NOT
    carry it for normally-created channel agents. This union is the single
    source of truth for "which channel plugins is this agent launched with"
    consumed by `managed_claude_settings_defaults` (managed-default enables)
    and the renderers' sticky-false repair.
    """
    specs: list[str] = []
    seen: set[str] = set()
    for spec in (*launched_channel_plugin_specs(launch_cmd), *channel_specs_from_csv(channels_csv)):
        if spec in seen:
            continue
        seen.add(spec)
        specs.append(spec)
    return specs


def agent_bridge_development_plugin_settings(
    launch_cmd: str | None,
    channels_csv: str | None = None,
) -> dict[str, Any]:
    # Issue #1212: previously this filter required every plugin spec to
    # end with `@agent-bridge`, which silently dropped every third-party
    # marketplace plugin (e.g. `plugin:cosmax-crm@cosmax-crm-marketplace`)
    # from `enabledPlugins`. The plugin still loaded via the
    # `--dangerously-load-development-channels` argv (so tools registered)
    # but Claude Code's plugin runtime did not load its `hooks/hooks.json`
    # — SessionStart hooks never fired. For `cosmax-crm` this is
    # silent-fatal because its `.mcp.json` ships with a `Bearer
    # __CRM_TOKEN_PLACEHOLDER__` that the SessionStart hook substitutes
    # at startup; without the hook the placeholder reaches the server
    # and the HTTP MCP handshake fails auth with 0 tools.
    #
    # The new filter accepts any `plugin:<name>@<marketplace>` spec
    # (both sides non-empty, `@` as separator). For each accepted spec
    # we also collect its marketplace id and emit an
    # `extraKnownMarketplaces` entry pointing at the controller-side
    # mirror under `$BRIDGE_HOME/data/shared/plugins-cache/marketplaces/<id>`
    # — seeded by `bridge_plugins_seed_mirror_marketplace_root` (#1201/#1202).
    #
    # Safety guards before emitting a third-party marketplace entry:
    #   - marketplace id is non-empty
    #   - marketplace id matches `[A-Za-z0-9._-]+` (no `/` or other
    #     filesystem separators)
    #   - marketplace id is not `.` or `..` (no parent-traversal)
    #   - resolved mirror dir is a real directory under the marketplaces
    #     root (`is_dir()`).
    # When any guard fails, the marketplace entry is skipped but the
    # plugin stays in `enabledPlugins` (Claude's dev-channels argv still
    # loads the plugin from disk; we just decline to materialize a
    # marketplace identity for it).
    # Issue #1453: resolve the agent's effective channel plugin set through
    # the shared `effective_channel_plugin_specs` helper, which unions the
    # launch command's inline channel flags (`--channels` alias + the
    # internal dev-channels flag) with the agent's resolved channels CSV
    # (`--channels-csv`, sourced from BRIDGE_AGENT_CHANNELS — the SSOT). The
    # CSV is essential: the bridge composes the `--channels` launch flag from
    # BRIDGE_AGENT_CHANNELS at launch time, so the stored launch command the
    # renderer is fed (`bridge_agent_launch_cmd_raw`) does NOT carry it for
    # normally-created channel agents. A single resolver keeps this managed-
    # default path and the renderers' sticky-false repair from ever diverging
    # on which channels count. `spec` here is the `<plugin>@<marketplace>`
    # form (leading `plugin:` already stripped); the marketplace id is the
    # rightmost `@` segment, defensive against a plugin name that itself
    # contains `@`.
    plugin_specs = effective_channel_plugin_specs(launch_cmd, channels_csv)
    if not plugin_specs:
        return {}
    marketplace_ids: list[str] = []
    marketplace_seen: set[str] = set()
    for spec in plugin_specs:
        _plugin_name, _sep, marketplace_id = spec.rpartition("@")
        if marketplace_id and marketplace_id not in marketplace_seen:
            marketplace_seen.add(marketplace_id)
            marketplace_ids.append(marketplace_id)

    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if not bridge_home:
        bridge_home = str(Path(__file__).resolve().parent)

    marketplaces: dict[str, Any] = {
        "agent-bridge": {
            "source": {
                "source": "directory",
                "path": bridge_home,
            }
        }
    }
    # Third-party marketplace mirrors live under
    # `$BRIDGE_HOME/data/shared/plugins-cache/marketplaces/<id>` — the
    # same mirror root `bridge_plugins_seed_mirror_marketplace_root`
    # writes to and `bridge_known_marketplace_info` reads from
    # (lib/bridge-agents.sh:1664). Resolve relative to `bridge_home`
    # but apply safety guards before trusting the id as a path segment.
    marketplaces_root = Path(bridge_home) / "data" / "shared" / "plugins-cache" / "marketplaces"
    safe_id_re = re.compile(r"^[A-Za-z0-9._-]+$")
    for mkt_id in marketplace_ids:
        if mkt_id == "agent-bridge":
            continue
        if not mkt_id or mkt_id in {".", ".."}:
            continue
        if not safe_id_re.match(mkt_id):
            continue
        candidate = marketplaces_root / mkt_id
        try:
            is_dir = candidate.is_dir()  # noqa: raw-pathlib-controller-only — controller-side mirror lookup; iso UID never reaches this code
        except OSError:
            is_dir = False
        if not is_dir:
            # Skip the marketplace entry but keep the plugin enabled —
            # the dev-channels argv still loads the plugin from disk.
            continue
        marketplaces[mkt_id] = {
            "source": {
                "source": "directory",
                "path": str(candidate),
            }
        }
    return {
        "enabledPlugins": {spec: True for spec in plugin_specs},
        "extraKnownMarketplaces": marketplaces,
    }


def managed_claude_settings_defaults(
    launch_cmd: str | None,
    agent_class: str | None = None,
    channels_csv: str | None = None,
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
    plugin_settings = agent_bridge_development_plugin_settings(launch_cmd, channels_csv)
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


def inbox_drain_hook_command(bridge_home: Path, python_bin: str) -> str:
    # #9780: Stop inbox-drain auto-continue. Wired AFTER surface-reply-enforce
    # (so it never shadows the channel-reply block) and BEFORE session-stop.
    hook_path = bridge_home / "hooks" / "inbox-auto-drain.py"
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


# #8945 Track B — expanded Codex hook coverage (PreCompact/PostCompact/
# SubagentStart/SubagentStop/PermissionRequest). All audit-only by default;
# any enforcement is env-gated inside the hook scripts themselves.
def codex_pre_compact_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-pre-compact.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_post_compact_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-post-compact.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_subagent_start_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-subagent-start.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_subagent_stop_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-subagent-stop.py"
    return shell_command(python_bin, shell_path(hook_path))


def codex_permission_request_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-permission-request.py"
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


def is_inbox_drain_hook(command: str) -> bool:
    return "inbox-auto-drain.py" in str(command)


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


# #8945 Track B predicates — match the new Codex hook commands so re-render
# rewrites in place rather than appending duplicates.
def is_codex_pre_compact_hook(command: str) -> bool:
    return "codex-pre-compact.py" in str(command)


def is_codex_post_compact_hook(command: str) -> bool:
    return "codex-post-compact.py" in str(command)


def is_codex_subagent_start_hook(command: str) -> bool:
    return "codex-subagent-start.py" in str(command)


def is_codex_subagent_stop_hook(command: str) -> bool:
    return "codex-subagent-stop.py" in str(command)


def is_codex_permission_request_hook(command: str) -> bool:
    return "codex-permission-request.py" in str(command)


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
    _inbox_drain_group, inbox_drain_hook = find_command_hook(stop_hooks, is_inbox_drain_hook)
    _session_stop_group, session_stop_hook = find_command_hook(stop_hooks, is_session_stop_hook)
    # mark-idle.sh keeps the legacy HOOK_STOP_HOOK / HOOK_COMMAND fields so
    # existing operators / scripts that grep for them stay green. The
    # HOOK_STOP_HOOK_SUITE field (#541 PR-B) reports the aggregate state so
    # the upgrade and smoke paths can detect partial drops of the suite
    # (now including the #9780 inbox-auto-drain step).
    command = str(idle_hook.get("command") or "") if idle_hook else ""
    suite_present = bool(idle_hook and surface_hook and inbox_drain_hook and session_stop_hook)
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if suite_present else "missing",
        "HOOK_STOP_HOOK": "present" if idle_hook else "missing",
        "HOOK_STOP_HOOK_SUITE": "present" if suite_present else "missing",
        "HOOK_STOP_HOOK_MARK_IDLE": "present" if idle_hook else "missing",
        "HOOK_STOP_HOOK_SURFACE_REPLY_ENFORCE": "present" if surface_hook else "missing",
        "HOOK_STOP_HOOK_INBOX_DRAIN": "present" if inbox_drain_hook else "missing",
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
        print(f"stop_hook_inbox_drain: {'present' if inbox_drain_hook else 'missing'}")
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


def reorder_event_hook_before(
    settings_path: Path,
    event_name: str,
    move_matcher: Any,
    before_matcher: Any,
) -> bool:
    """Move the hook group matching ``move_matcher`` to sit immediately before
    the group matching ``before_matcher`` in ``event_name``.

    #9780: ``ensure_command_hook`` appends a freshly-registered hook at the end
    of the event list, which would land the inbox-drain hook AFTER session-stop.
    The Stop chain ordering is load-bearing (inbox-drain must run after
    surface-reply-enforce and before session-stop), so this normalises the
    position on every ensure pass — idempotent when already in place. No-op when
    either group is missing.
    """
    settings = ensure_settings_root(settings_path)
    event_hooks = hooks_list(settings, event_name)

    move_idx = before_idx = None
    for idx, group in enumerate(event_hooks):
        if not isinstance(group, dict):
            continue
        hooks = group.get("hooks")
        if not isinstance(hooks, list):
            continue
        for hook in hooks:
            if not isinstance(hook, dict) or hook.get("type") != "command":
                continue
            command = str(hook.get("command") or "")
            if move_idx is None and move_matcher(command):
                move_idx = idx
            if before_idx is None and before_matcher(command):
                before_idx = idx

    if move_idx is None or before_idx is None:
        return False
    if move_idx + 1 == before_idx:
        return False  # already immediately before — nothing to do.

    group = event_hooks.pop(move_idx)
    # Recompute the anchor index after the pop (it shifts left if it followed
    # the moved group).
    if move_idx < before_idx:
        before_idx -= 1
    event_hooks.insert(before_idx, group)
    save_json(settings_path, settings)
    return True


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
    inbox_drain_command = inbox_drain_hook_command(bridge_home, python_bin)
    session_stop_command = session_stop_hook_command(bridge_home, python_bin)

    # Issue #541 PR-B: ensure the full Stop hook suite. mark-idle.sh keeps
    # additionalContext=true (idle-wake context); surface-reply-enforce.py,
    # inbox-auto-drain.py (#9780) and session-stop.py mirror
    # agents/_template/.claude/settings.json (no additionalContext, timeout
    # 5 / 10 / 35 respectively). Chain order: mark-idle → surface-reply-enforce
    # → inbox-auto-drain → session-stop.
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
        inbox_drain_command,
        is_inbox_drain_hook,
        timeout=10,
    ) or changed
    changed = ensure_command_hook(
        settings_path,
        "Stop",
        session_stop_command,
        is_session_stop_hook,
        timeout=35,
    ) or changed
    # #9780: ensure_command_hook appends a newly-registered hook at the end of
    # the list. Re-seat inbox-auto-drain immediately before session-stop so the
    # drain runs after surface-reply-enforce and before the reconcile/idle hook
    # regardless of registration order on an existing install.
    changed = reorder_event_hook_before(
        settings_path,
        "Stop",
        is_inbox_drain_hook,
        is_session_stop_hook,
    ) or changed

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "present",
        "HOOK_STOP_HOOK_SUITE": "present",
        "HOOK_STOP_HOOK_MARK_IDLE": "present",
        "HOOK_STOP_HOOK_SURFACE_REPLY_ENFORCE": "present",
        "HOOK_STOP_HOOK_INBOX_DRAIN": "present",
        "HOOK_STOP_HOOK_SESSION_STOP": "present",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": mark_idle_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    if args.format != "shell":
        print("stop_hook_suite: present")
        print(f"surface_reply_enforce_command: {surface_command}")
        print(f"inbox_drain_command: {inbox_drain_command}")
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
    # #8945 Track B — expanded event coverage.
    pre_compact_hooks = hooks_list(settings, "PreCompact")
    post_compact_hooks = hooks_list(settings, "PostCompact")
    subagent_start_hooks = hooks_list(settings, "SubagentStart")
    subagent_stop_hooks = hooks_list(settings, "SubagentStop")
    permission_request_hooks = hooks_list(settings, "PermissionRequest")
    _pc_group, pre_compact_hook = find_command_hook(pre_compact_hooks, is_codex_pre_compact_hook)
    _poc_group, post_compact_hook = find_command_hook(post_compact_hooks, is_codex_post_compact_hook)
    _ss_group, subagent_start_hook = find_command_hook(subagent_start_hooks, is_codex_subagent_start_hook)
    _sx_group, subagent_stop_hook = find_command_hook(subagent_stop_hooks, is_codex_subagent_stop_hook)
    _pr_group, permission_request_hook = find_command_hook(
        permission_request_hooks, is_codex_permission_request_hook
    )
    core_present = bool(session_hook and stop_hook and prompt_hook)
    companion_present = bool(task_mode_hook and output_shape_hook)
    expanded_present = bool(
        pre_compact_hook
        and post_compact_hook
        and subagent_start_hook
        and subagent_stop_hook
        and permission_request_hook
    )
    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "present" if core_present else "missing",
        "CODEX_SESSION_START_HOOK": "present" if session_hook else "missing",
        "CODEX_STOP_HOOK": "present" if stop_hook else "missing",
        "CODEX_PROMPT_HOOK": "present" if prompt_hook else "missing",
        "CODEX_TASK_MODE_POLICY_HOOK": "present" if task_mode_hook else "missing",
        "CODEX_REVIEW_OUTPUT_SHAPE_HOOK": "present" if output_shape_hook else "missing",
        "CODEX_COMPANION_HOOKS_STATUS": "present" if companion_present else "missing",
        "CODEX_PRE_COMPACT_HOOK": "present" if pre_compact_hook else "missing",
        "CODEX_POST_COMPACT_HOOK": "present" if post_compact_hook else "missing",
        "CODEX_SUBAGENT_START_HOOK": "present" if subagent_start_hook else "missing",
        "CODEX_SUBAGENT_STOP_HOOK": "present" if subagent_stop_hook else "missing",
        "CODEX_PERMISSION_REQUEST_HOOK": "present" if permission_request_hook else "missing",
        "CODEX_EXPANDED_HOOKS_STATUS": "present" if expanded_present else "missing",
        "CODEX_SESSION_START_COMMAND": str(session_hook.get("command") or "") if session_hook else "",
        "CODEX_STOP_COMMAND": str(stop_hook.get("command") or "") if stop_hook else "",
        "CODEX_PROMPT_COMMAND": str(prompt_hook.get("command") or "") if prompt_hook else "",
        "CODEX_TASK_MODE_POLICY_COMMAND": str(task_mode_hook.get("command") or "") if task_mode_hook else "",
        "CODEX_REVIEW_OUTPUT_SHAPE_COMMAND": str(output_shape_hook.get("command") or "") if output_shape_hook else "",
        "CODEX_PRE_COMPACT_COMMAND": str(pre_compact_hook.get("command") or "") if pre_compact_hook else "",
        "CODEX_POST_COMPACT_COMMAND": str(post_compact_hook.get("command") or "") if post_compact_hook else "",
        "CODEX_SUBAGENT_START_COMMAND": str(subagent_start_hook.get("command") or "") if subagent_start_hook else "",
        "CODEX_SUBAGENT_STOP_COMMAND": str(subagent_stop_hook.get("command") or "") if subagent_stop_hook else "",
        "CODEX_PERMISSION_REQUEST_COMMAND": str(permission_request_hook.get("command") or "") if permission_request_hook else "",
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
        print(f"pre_compact_hook: {'present' if pre_compact_hook else 'missing'}")
        print(f"post_compact_hook: {'present' if post_compact_hook else 'missing'}")
        print(f"subagent_start_hook: {'present' if subagent_start_hook else 'missing'}")
        print(f"subagent_stop_hook: {'present' if subagent_stop_hook else 'missing'}")
        print(f"permission_request_hook: {'present' if permission_request_hook else 'missing'}")
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
    # observing audit logs. Current Codex (verified codex-cli 0.135.0) natively
    # supports the PreToolUse / Stop hook events used here; older CLIs that
    # predated them ignored the unknown event keys without hard-failing, so the
    # entries are safe to write either way.
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

    # #8945 Track B — expanded event coverage. Codex CLI 0.135.0/0.136.0
    # supports 10 hook events; the bridge previously rendered only 5
    # (SessionStart / Stop×2 / UserPromptSubmit / PreToolUse). These five
    # add compaction, subagent fan-out, and permission-request coverage.
    # ALL audit-only by default; enforcement (if any) is env-gated inside
    # each hook script. The PermissionRequest hook is the security-sensitive
    # one — it is bounded, redacted, deduped/throttled, and emits NO
    # allow/deny decision by default (operators opt into the queue-task
    # surface via BRIDGE_CODEX_PERMISSION_AUTO_QUEUE=on). Older Codex CLIs
    # that predate these events ignore the unknown event keys without
    # hard-failing, so the entries are safe to write either way.
    pre_compact_command = codex_pre_compact_hook_command(bridge_home, args.python_bin)
    post_compact_command = codex_post_compact_hook_command(bridge_home, args.python_bin)
    subagent_start_command = codex_subagent_start_hook_command(bridge_home, args.python_bin)
    subagent_stop_command = codex_subagent_stop_hook_command(bridge_home, args.python_bin)
    permission_request_command = codex_permission_request_hook_command(
        bridge_home, args.python_bin
    )
    changed = ensure_command_hook(
        hooks_path,
        "PreCompact",
        pre_compact_command,
        is_codex_pre_compact_hook,
        timeout=20,
        status_message="Snapshotting Agent Bridge canonical context",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "PostCompact",
        post_compact_command,
        is_codex_post_compact_hook,
        timeout=5,
        status_message="Restoring Agent Bridge queue context",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "SubagentStart",
        subagent_start_command,
        is_codex_subagent_start_hook,
        timeout=3,
        status_message="Recording Agent Bridge subagent fan-out",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "SubagentStop",
        subagent_stop_command,
        is_codex_subagent_stop_hook,
        timeout=3,
        status_message="Recording Agent Bridge subagent completion",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "PermissionRequest",
        permission_request_command,
        is_codex_permission_request_hook,
        timeout=5,
        status_message="Recording Agent Bridge permission request",
    ) or changed

    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "updated" if changed else "unchanged",
        "CODEX_SESSION_START_HOOK": "present",
        "CODEX_STOP_HOOK": "present",
        "CODEX_PROMPT_HOOK": "present",
        "CODEX_TASK_MODE_POLICY_HOOK": "present",
        "CODEX_REVIEW_OUTPUT_SHAPE_HOOK": "present",
        "CODEX_PRE_COMPACT_HOOK": "present",
        "CODEX_POST_COMPACT_HOOK": "present",
        "CODEX_SUBAGENT_START_HOOK": "present",
        "CODEX_SUBAGENT_STOP_HOOK": "present",
        "CODEX_PERMISSION_REQUEST_HOOK": "present",
        "CODEX_SESSION_START_COMMAND": session_command,
        "CODEX_STOP_COMMAND": stop_command,
        "CODEX_PROMPT_COMMAND": prompt_command,
        "CODEX_TASK_MODE_POLICY_COMMAND": task_mode_command,
        "CODEX_REVIEW_OUTPUT_SHAPE_COMMAND": output_shape_command,
        "CODEX_PRE_COMPACT_COMMAND": pre_compact_command,
        "CODEX_POST_COMPACT_COMMAND": post_compact_command,
        "CODEX_SUBAGENT_START_COMMAND": subagent_start_command,
        "CODEX_SUBAGENT_STOP_COMMAND": subagent_stop_command,
        "CODEX_PERMISSION_REQUEST_COMMAND": permission_request_command,
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
#
# (Issue #1689 added "statusLine": an operator-configured status line —
# e.g. the claude-hud HUD set up via `/claude-hud:setup` — lives as a
# top-level `statusLine` object in settings.json. Without preservation it
# was dropped on every rerender, so the HUD silently vanished on the next
# `agb upgrade` / restart. The bridge's own `hud_usage_tap` reads and
# patches `settings["statusLine"]["command"]`, so preserving the key also
# keeps that tap's patch alive across rerenders rather than having the next
# render delete what the tap just wrote.)
#
# (Issue #1756 added "model" + the benign session-preference toggles below.
# Selection criterion: a user-set top-level key that is a Claude Code
# session preference with NO bridge-managed default — the bridge renders no
# value for it, so dropping the operator's value on every rerender is pure
# data loss. `model` is the live-confirmed case: an operator who pinned
# `"model"` saw it revert to the CLI default after the next upgrade/restart
# re-render, because the render kept only this allowlist and silently
# dropped everything else. DELIBERATELY EXCLUDED:
#   - promptSuggestionEnabled / autoCompactWindow: the bridge SETS these as
#     managed defaults (composer-nudge fix #630 / per-class window #593), so
#     preserving them would let a stale effective value shadow the managed
#     default. They are managed keys, not free user keys.
#   - autoMemoryEnabled / autoDreamEnabled: shipped with a value in the
#     tracked base (agents/.claude/settings.json), so they already carry a
#     bridge-rendered value — not orphan user keys.
#   - arbitrary/unknown keys (the smokes' `unrelatedSetting` control): NOT
#     preserved. This stays a CURATED ALLOWLIST, not a preserve-everything
#     denylist, so the #1495 invalid-hook-key sanitize contract and the
#     existing "allowlist stays tight" regression teeth both still hold.)
PRESERVED_USER_KEYS = (
    "enabledPlugins",
    "extraKnownMarketplaces",
    "apiKeyHelper",
    "skipDangerousModePermissionPrompt",
    "statusLine",
    "model",
    "alwaysThinkingEnabled",
    "agentPushNotifEnabled",
)

# Queue request #11901 (operator-approved Option 1, 2026-06-10): a SHARED
# (non-isolated) static Claude agent inherits the operator's system-global
# `~/.claude/settings.json` as the bottom-most render layer, so operator
# changes to global settings (e.g. `agentPushNotifEnabled`) propagate to
# shared agents on the next render. iso-v2 agents are UNAFFECTED (separate
# OS user/home — global inheritance is not their contract), and dynamic
# agents already read the real `~/.claude`.
#
# SAFETY FILTER (operator caveat): the operator global is a human's
# machine-local file and may carry sensitive or machine-specific items that
# must NOT flow into a managed agent's effective settings. We DENYLIST the
# known-dangerous keys below, plus any top-level key whose name *looks*
# credential-shaped (substring match — defense in depth against future
# Claude Code keys we have not catalogued). Everything else inherits.
#
# Why a denylist (not an allowlist): the whole point of Option 1 is that a
# *future* benign operator-global key (like `agentPushNotifEnabled`, which
# is not in any bridge default) propagates without a code change. An
# allowlist would silently swallow every new key until someone updates this
# file — exactly the gap we are closing. The denylist names the categories
# that are genuinely unsafe to inherit and lets the long tail through.
#
# Rationale per key:
#   - hooks: machine-absolute hook commands; the bridge OWNS the hook suite
#     (Stop/UserPromptSubmit/PreToolUse/... are ensured into the bridge base
#     and must win). Inheriting the operator's hooks would either be
#     redundant (same paths) or wire commands that do not exist on the
#     agent's box.
#   - statusLine: an absolute-path command (operator's HUD) that would break
#     on the agent; it is also a PRESERVED_USER_KEY (#1689) so a per-agent
#     statusLine still wins. We drop the global one rather than risk an
#     unrunnable command in the effective file.
#   - apiKeyHelper / awsAuthRefresh / awsCredentialExport / otelHeadersHelper:
#     credential-emitting commands (machine/account specific).
#   - forceLoginMethod / forceLoginOrgUUID: account binding.
#   - permissions: the bridge governs tool access via the tool-policy hook +
#     `--dangerously-skip-permissions`; inheriting the operator's machine-wide
#     allow/deny rules could silently broaden or break a managed agent.
#   - env: arbitrary environment injection, frequently machine/credential
#     specific.
OPERATOR_GLOBAL_INHERIT_DENYLIST = frozenset(
    {
        "hooks",
        "statusLine",
        "apiKeyHelper",
        "awsAuthRefresh",
        "awsCredentialExport",
        "otelHeadersHelper",
        "forceLoginMethod",
        "forceLoginOrgUUID",
        "permissions",
        "env",
    }
)

# Substring guard: drop any top-level operator-global key whose name looks
# credential-shaped even if it is not in the explicit denylist above. Match
# is case-insensitive and substring-based so e.g. `myApiKey`, `authToken`,
# `clientSecret`, `oauthRefresh` are all caught.
_OPERATOR_GLOBAL_SENSITIVE_NAME_TOKENS = (
    "apikey",
    "token",
    "secret",
    "credential",
    "password",
    "oauth",
    "auth_refresh",
    "authrefresh",
)


def _filter_operator_global_base(payload: Any) -> tuple[dict[str, Any], list[str]]:
    """Return the inheritable subset of an operator-global settings payload.

    Applies `OPERATOR_GLOBAL_INHERIT_DENYLIST` plus the credential-shaped
    name guard. Returns `(filtered_dict, dropped_key_names)`. A non-dict
    payload yields `({}, [])` so a malformed global degrades cleanly to the
    bridge base via the fail-safe in `cmd_render_shared_settings`.
    """
    if not isinstance(payload, dict):
        return {}, []
    filtered: dict[str, Any] = {}
    dropped: list[str] = []
    for key, value in payload.items():
        lowered = str(key).lower()
        if key in OPERATOR_GLOBAL_INHERIT_DENYLIST or any(
            token in lowered for token in _OPERATOR_GLOBAL_SENSITIVE_NAME_TOKENS
        ):
            dropped.append(str(key))
            continue
        filtered[key] = value
    return filtered, sorted(dropped)


def _warn_filtered_operator_global_keys(dropped: list[str], context: str) -> None:
    """Emit a single stderr `[info]` line for sensitive operator-global keys
    that the safety filter dropped before inheritance (#11901).

    Kept off stdout so the `--json`/`--format shell` render paths stay
    machine-parseable.
    """
    if not dropped:
        return
    sys.stderr.write(
        "[info] bridge-hooks: operator-global settings inherited for this "
        f"shared agent with {len(dropped)} sensitive/machine-specific key(s) "
        f"filtered out ({', '.join(dropped)}) before merge into "
        f"{context} (#11901 safety filter)\n"
    )


def _is_render_output_path(path: Path) -> bool:
    """True when `path` matches a bridge-managed render OUTPUT location.

    A bridge render writes the effective settings file (the `effective` leaf
    under a `.claude` directory) at three target shapes — the shared per-agent
    target, the isolated-home target, and the mirrored launched-config target
    — all of which share that leaf-under-`.claude` shape. #1759: the operator-
    global inherit (#11901) becomes self-referential when the operator's
    `~/.claude` settings link is a bridge-managed symlink to one of these
    outputs. Pattern match (leaf name + parent `.claude`) is the cheap pre-
    filter; the authoritative self-ref test in
    `_operator_global_is_self_reference` is the realpath equality against THE
    effective file being rendered.
    """
    try:
        return path.name == "settings.effective.json" and path.parent.name == ".claude"  # noqa: iso-helper-boundary — pure in-memory PurePath name/parent inspection of a controller-resolved render target; no filesystem read of an isolated artifact
    except (IndexError, ValueError):
        return False


def _operator_global_is_self_reference(
    operator_global_path: Path, effective_path: Path
) -> bool:
    """#1759 loop guard: is the operator-global base THIS agent's own output?

    On a shared-admin layout the operator's `~/.claude/settings.json` can be a
    bridge-managed symlink whose target IS this agent's `settings.effective.
    json` (created by `link-shared-settings`). Inheriting it as the #11901
    bottom-most base then reads the agent's own previous render output as its
    base layer — a self-sustaining loop (benign-key resurrection / decay
    inversion / accidental operator-edit survival; see the issue). The fix is
    to break the loop ONLY for the agent that owns the effective file: every
    OTHER agent reading through the same symlink resolves to a DIFFERENT
    `effective_path`, so this returns False for them and their one-directional
    inherit (live-verified AC1-AC6) is untouched.

    Detection is realpath-based, not a string compare, so both the direct
    symlink (settings link -> effective file) and the nested case (settings
    link -> intermediate -> effective file) collapse to the same fully-
    resolved target before comparison.

    Fail SAFE: when the operator-global path *looks* like a render output (the
    `effective` leaf under a `.claude` directory, per `_is_render_output_path`)
    but its realpath cannot be conclusively resolved and matched — broken link,
    permission boundary, indeterminate ownership — we treat it as a self-
    reference and break the loop. Degrading to the bridge base is always safe
    (it is the pre-#11901 behavior); risking the loop is not.
    """
    def _resolve(path: Path) -> str:
        owner = _resolve_isolated_owner_for_path(path)
        try:
            return _safe_realpath(path, owner)
        except OSError:
            # Mid-path stat blocked with no iso owner to escalate through.
            # Return empty so the caller treats resolution as indeterminate
            # and fails safe (rather than crashing the render).
            return ""

    global_real = _resolve(operator_global_path)
    effective_real = _resolve(effective_path)

    # Authoritative self-reference: the resolved operator-global IS the exact
    # effective file we are about to write.
    if global_real and effective_real and global_real == effective_real:
        return True

    # Case-insensitive filesystems (macOS APFS default): realpath PRESERVES
    # the requested spelling, so a symlink target that differs from the
    # effective path only by casing compares unequal above while naming the
    # SAME file. Use inode-aware equivalence when both sides can be statted;
    # any stat failure falls through to the output-shaped fail-safe below
    # (never weaker than the string compare).
    samefile_indeterminate = False
    if global_real and effective_real:
        try:
            if os.path.samefile(global_real, effective_real):
                return True
        except OSError:
            # samefile raises when EITHER side cannot be statted. The
            # EFFECTIVE side commonly does not exist yet — an agent's FIRST
            # render writes it — and that is the normal one-directional
            # inherit (#11901 AC1), not a suspect global. Equivalence is only
            # truly UNPROVEN when the GLOBAL side itself cannot be statted
            # (e.g. the symlink resolves to a MISSING output-shaped path —
            # the codex r2 repro). Record only that case so the output-shaped
            # classification below fails safe instead of being treated as
            # "fully resolved and different" (codex r2 blocker).
            try:
                os.stat(global_real)
            except OSError:
                samefile_indeterminate = True

    # The operator-global is not (or not provably) this agent's effective
    # file. Decide whether it is another agent's render output (legit inherit)
    # or an indeterminate output-shaped target (fail safe).
    global_shape_path = Path(global_real) if global_real else operator_global_path
    if _is_render_output_path(global_shape_path):
        if samefile_indeterminate:
            # Output-shaped AND same-file equivalence unproven -> we cannot
            # rule out that this is our own output. Fail safe: break the loop
            # and degrade to the bridge base.
            return True
        if global_real and effective_real:
            # Both paths fully resolved, they differ, and the global target
            # is statable (the indeterminate flag above did not fire) -> it
            # is ANOTHER agent's effective file reached one-directionally
            # through the symlink. That is the live-verified correct inherit
            # (#11901 AC1-AC6) — including the first-render case where OUR
            # effective file does not exist yet. Keep it, do not break the
            # loop.
            return False
        # Output-shaped but resolution was indeterminate (a realpath came back
        # empty) -> we cannot prove it is NOT this agent's own output. Fail
        # safe: break the loop and degrade to the bridge base.
        return True

    # Not output-shaped: a genuine operator-authored `~/.claude/settings.json`.
    # Inherit normally.
    return False


# Issue #1495: Claude Code skips the ENTIRE settings.json (every key —
# enabledPlugins, skipDangerousModePermissionPrompt, the lot) when the
# `hooks` record carries an event name the CLI does not recognize
# ("PermissionDenied: Invalid key in record" → plugins/MCP/channel bots
# go offline). The legacy `PermissionDenied` block (commit 83c03c28, #93)
# is no longer a valid CC hook event — CC v2.1.87 rejects it — and the
# render `merge_settings` preserves existing keys, so a once-dirty
# settings.json keeps the broken key across every rerender. The render
# path actively prunes any `hooks.<event>` outside this allowlist so a
# fresh render is clean AND an existing dirty file is repaired on the
# next upgrade/restart.
#
# This set MUST contain EVERY hook event the bridge itself wires (the
# `hooks_list(settings, "<event>")` sites in cmd_ensure_tool_policy_hooks +
# managed_claude_settings_defaults), or the prune would delete a live
# bridge-owned hook (#1499 codex r1: `PostToolUseFailure` was omitted → the
# tool-policy failure hook got pruned on isolated render). The #8945
# Codex-coverage events (`PostCompact` / `PermissionRequest` / `SubagentStart`)
# are bridge-wired and stay IN. The ONLY thing intentionally excluded is the
# legacy `PermissionDenied` (the #93 escalation block, no longer wired by the
# bridge and rejected by CC v2.1.87 as an invalid key) — so the prune strips
# it from stale settings while preserving every bridge-managed event.
VALID_CLAUDE_HOOK_EVENTS = frozenset(
    {
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "UserPromptSubmit",
        "Notification",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
        "PermissionRequest",
        "SessionStart",
        "SessionEnd",
    }
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


def _prune_invalid_hook_keys(settings: dict[str, Any]) -> list[str]:
    """Drop any `hooks.<event>` not in the valid Claude Code event allowlist.

    Issue #1495: Claude Code rejects the WHOLE settings.json (silently
    skipping plugins, MCP, skipDangerousModePermissionPrompt, every key)
    when the `hooks` record carries an unrecognized event name. The
    render `merge_settings` preserves existing keys, so a once-dirty
    settings.json (e.g. the legacy `PermissionDenied` block shipped by
    the tracked base before this fix) survives every rerender. Running
    this prune on the merged payload right before write means a fresh
    render is clean AND an existing dirty file is repaired on the next
    upgrade/restart.

    Returns the sorted list of dropped event names so the caller can emit
    a single `[warn]` to stderr. Stdout stays untouched here — the
    `--json` render/rerender paths must keep stdout pure JSON.
    """
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return []
    dropped = [event for event in hooks if event not in VALID_CLAUDE_HOOK_EVENTS]
    for event in dropped:
        del hooks[event]
    return sorted(dropped)


def _warn_dropped_hook_keys(dropped: list[str], context: str) -> None:
    """Emit a single stderr `[warn]` line for pruned invalid hook keys.

    Kept off stdout so the `--json`/`--format shell` render paths stay
    machine-parseable (#1495).
    """
    if not dropped:
        return
    sys.stderr.write(
        "[warn] bridge-hooks: dropped invalid Claude Code hook "
        f"event(s) {', '.join(dropped)} from {context} — Claude Code "
        "rejects the entire settings file on an unknown hook key "
        "(#1495)\n"
    )


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


def _fold_adopted_user_keys_into_shared(
    regular_file: Path,
    shared_effective: Path,
    launch_cmd: str | None = None,
    channels_csv: str | None = None,
) -> list[str]:
    """Fold a regular per-agent `settings.json`'s preserved user keys into the
    shared effective file before `link-shared-settings` replaces it (#1756 (3)).

    When `cmd_link_shared_settings` converts an operator's regular
    `<workdir>/.claude/settings.json` to a symlink at the shared effective
    file, the regular file's content is otherwise lost from the live surface:
    the shared render reads its preserved keys from the *shared* effective
    file, never from the per-agent regular file it is about to adopt. So an
    operator who pinned e.g. `model` in the per-agent file (the file Claude
    itself wrote into) loses it at adoption time. This folds the regular
    file's `PRESERVED_USER_KEYS` into the shared effective target so the
    adoption is lossless. The fold merges user keys *last* (they win), then
    re-sanitizes invalid hook keys (#1495) so adoption can never reintroduce
    a key Claude Code would reject.

    `enabledPlugins` is one of the preserved keys this fold merges last, so an
    adopted regular file recording `enabledPlugins[<launched-channel>]=false`
    would otherwise re-disable a launched channel plugin in the shared
    effective target — re-opening the exact #1453 sticky-false inbound-drop
    the normal render paths repair AFTER the preserved merge. The fold runs
    OUTSIDE the render path (`cmd_link_shared_settings`), so it must apply the
    same `_repair_sticky_false_channel_enables` pass — with the agent's
    launched channel context (`launch_cmd` + `channels_csv`) — after the merge
    and prune, before save, mirroring the render paths' ordering. A false on a
    NON-launched plugin still survives (operator intent preserved where safe).

    Returns the sorted list of folded key names (empty when there is nothing
    to carry forward). Best-effort: a missing/unreadable shared effective
    file is a no-op (the link still forms; the next render re-preserves from
    the effective file once Claude writes the keys back through the symlink).
    """
    adopted = _load_preserved_user_keys(regular_file)
    if not adopted:
        return []
    shared_owner = _resolve_isolated_owner_for_path(shared_effective)
    if not _safe_path_check("exists", shared_effective, shared_owner):
        return []
    try:
        current = load_json(shared_effective)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(current, dict):
        return []
    folded = [k for k in adopted if current.get(k) != adopted[k]]
    if not folded:
        return []
    merged = merge_settings(current, adopted)
    _prune_invalid_hook_keys(merged)
    # #1756 r2 (codex BLOCKING): the adopted file's preserved `enabledPlugins`
    # can carry a launched-channel `false`; without this repair the fold would
    # re-disable inbound channel delivery and bypass the #1453 sticky-false fix
    # until some later render. Apply the same repair the render paths run after
    # the preserved merge, with the launched channel context threaded in.
    _repair_sticky_false_channel_enables(
        merged, launch_cmd, str(shared_effective), channels_csv
    )
    save_json(shared_effective, merged)
    return sorted(folded)


def _repair_sticky_false_channel_enables(
    merged: dict[str, Any],
    launch_cmd: str | None,
    context: str,
    channels_csv: str | None = None,
) -> list[str]:
    """Force `enabledPlugins[<spec>] = True` for every launched channel plugin
    whose preserved value left it disabled (#1453, fix B).

    `enabledPlugins` is a preserved-user key merged *last*, so once Claude
    Code's own plugin runtime records `<channel>: false` into the effective
    file, every subsequent render re-preserves that `false` and the managed
    `true` from `agent_bridge_development_plugin_settings` can never win.
    A disabled channel plugin means Claude Code does not wire up its inbound
    MCP notification handler, so inbound channel messages are silently
    dropped (outbound, which goes through the `--channels` launch path,
    keeps working — the asymmetric symptom).

    The launched channel set is resolved via `effective_channel_plugin_specs`
    — the union of the launch command's inline channel flags and the agent's
    resolved channels CSV (`channels_csv`, from BRIDGE_AGENT_CHANNELS). The
    CSV is essential: normally-created channel agents store a launch command
    WITHOUT `--channels` (the bridge composes it at launch from the roster),
    so the CSV is the only signal the renderer has for which channels the
    agent actually runs.

    The fix asserts the bridge's authority for plugins that are part of the
    agent's launched channel set: for those specs the managed `true` is
    authoritative and overrides a preserved/recorded `false` (or absence).
    Operator enable/disable is still preserved for every plugin that is NOT
    in the launched channel set, so the legitimate "disable a non-launched
    plugin" case is untouched.

    Mutates `merged` in place. Returns the sorted list of spec names whose
    `false` was corrected so the caller can emit a loud `[warn]` (a stale
    sticky-false is a real misconfiguration that previously failed silently).
    """
    specs = effective_channel_plugin_specs(launch_cmd, channels_csv)
    if not specs:
        return []
    enabled = merged.get("enabledPlugins")
    if not isinstance(enabled, dict):
        enabled = {}
        merged["enabledPlugins"] = enabled
    corrected: list[str] = []
    for spec in specs:
        if enabled.get(spec) is not True:
            if enabled.get(spec) is False:
                corrected.append(spec)
            enabled[spec] = True
    if corrected:
        sys.stderr.write(
            "[warn] bridge-hooks: forced enabledPlugins["
            f"{', '.join(sorted(corrected))}]=true in {context} — the "
            "launched channel plugin(s) were recorded disabled, which "
            "silently drops inbound channel delivery (#1453 sticky-false). "
            "Managed channel enables are authoritative for launched "
            "plugins.\n"
        )
    return sorted(corrected)


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
    # #1453: the agent's resolved channels CSV (from BRIDGE_AGENT_CHANNELS,
    # the SSOT — bridge_agent_channels_csv). Required because the stored
    # launch command does NOT carry the `--channels` flag for
    # normally-created channel agents (the bridge composes it at launch).
    channels_csv = (getattr(args, "channels_csv", "") or "") or None
    managed_defaults = managed_claude_settings_defaults(launch_cmd, agent_class, channels_csv)

    # Queue request #11901 (operator-approved Option 1): for a SHARED static
    # agent, the operator's system-global `~/.claude/settings.json` (resolved
    # in the shell via `bridge_agent_operator_home_dir` and passed here as
    # `--operator-global-settings-file`) is inherited as the BOTTOM-MOST
    # layer, filtered through the safety denylist.
    #
    # Why bottom-most (below managed defaults), not the literal "base"
    # position the design note sketched: the bridge's own hook suite (Stop /
    # tool-policy / SessionStart / ...) and the per-class managed defaults
    # (static `autoCompactWindow=400_000`) MUST win over whatever the
    # operator happens to have globally. Placing the filtered global at the
    # bottom means:
    #   * a global key the bridge does NOT set (e.g. `agentPushNotifEnabled`)
    #     propagates up untouched — the gap #11901 closes, and
    #   * a global key the bridge DOES set (e.g. a global
    #     `autoCompactWindow=1_000_000`) is overridden by the managed/base/
    #     overlay layers above it — so per-class and per-agent intentional
    #     differences are preserved.
    #
    # Fail-safe: if the global is missing, unreadable, or not a JSON object,
    # `operator_global_layer` stays empty and the render degrades to the
    # pre-#11901 `managed < base < overlay < preserved` stack — never an
    # empty or broken effective file.
    operator_global_path_arg = (
        getattr(args, "operator_global_settings_file", "") or ""
    ) or None
    operator_global_layer: dict[str, Any] = {}
    if operator_global_path_arg is not None:
        operator_global_path = Path(operator_global_path_arg).expanduser()
        # #1759 loop guard: on a shared-admin layout the operator's
        # `~/.claude/settings.json` can be a bridge-managed symlink to THIS
        # agent's own `settings.effective.json` (created by
        # `link-shared-settings`). Inheriting it as the #11901 base would make
        # the render read its own previous output as the bottom layer — a
        # self-sustaining loop (benign-key resurrection, decay inversion, and
        # operator hand-edits surviving only by accident of the loop rather
        # than via #1756's preserve contract). Break the loop ONLY for the
        # owning agent by degrading to the bridge base exactly like the
        # missing-global path; every OTHER agent's one-directional read
        # through the same symlink resolves to a different effective file and
        # keeps inheriting (#11901 AC1-AC6 intact).
        if _operator_global_is_self_reference(operator_global_path, effective_path):
            sys.stderr.write(
                "[info] bridge-hooks: operator-global settings file resolves "
                f"to this agent's own render output ({effective_path}); "
                "skipping #11901 inheritance and degrading to the bridge base "
                "to break the self-referential loop (#1759). Operator "
                "hand-edits survive via the preserved-key pass (#1756).\n"
            )
            operator_global_path_arg = None
            operator_global_payload = None
        else:
            try:
                operator_global_payload = load_json(operator_global_path)
            except (OSError, json.JSONDecodeError):
                operator_global_payload = None
        operator_global_layer, _global_dropped = _filter_operator_global_base(
            operator_global_payload
        )
        # Warn whenever the safety filter dropped a sensitive key, regardless
        # of whether any benign key survived (#11901 r2): an all-denied global
        # (e.g. only `apiKeyHelper`/`env`) drops every key, leaving
        # `operator_global_layer` empty — but the keys WERE dropped, so the
        # helper contract (one `[info]` stderr line naming them) must still
        # fire. Gating on `_global_dropped` instead of `operator_global_layer`
        # closes the silent-drop gap; the helper itself early-returns on an
        # empty `dropped`, so this stays a single, non-double `[info]` line.
        if _global_dropped:
            _warn_filtered_operator_global_keys(_global_dropped, str(effective_path))

    # Compose: operator-global(filtered) < managed defaults < base < overlay
    # < preserved user keys. Preserved keys merge last so per-agent edits to
    # the effective file (e.g. operator-disabled plugins) survive every
    # rerender. See `PRESERVED_USER_KEYS` rationale above.
    preserved = _load_preserved_user_keys(effective_path)
    if operator_global_layer:
        merged = merge_settings(operator_global_layer, managed_defaults)
    else:
        merged = dict(managed_defaults)
    merged = merge_settings(merged, base_payload)
    merged = merge_settings(merged, overlay_payload)
    if preserved:
        merged = merge_settings(merged, preserved)
    _normalize_bridge_hook_paths(merged, _bridge_home_from_base_settings(base_path))
    # #1495: strip any non-allowlisted hook event so a once-dirty
    # effective file (e.g. the legacy PermissionDenied block) is repaired
    # on this rerender — merge_settings preserves it otherwise — and a
    # fresh render never ships a key Claude Code would reject.
    _warn_dropped_hook_keys(_prune_invalid_hook_keys(merged), str(effective_path))
    # #1453: the preserved-key merge above lets a stale
    # `enabledPlugins[<channel>]=false` (recorded by Claude Code's plugin
    # runtime) override the managed `true`, silently killing inbound channel
    # delivery. Re-assert the bridge's authority over launched-channel
    # plugins *after* the preserved merge so the sticky-false is repaired on
    # this rerender instead of being carried forward forever.
    _repair_sticky_false_channel_enables(merged, launch_cmd, str(effective_path), channels_csv)
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
    # #1453: agent's resolved channels CSV (BRIDGE_AGENT_CHANNELS SSOT). See
    # the shared renderer for why the stored launch command alone is
    # insufficient.
    channels_csv = (getattr(args, "channels_csv", "") or "") or None

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

    managed_defaults = managed_claude_settings_defaults(launch_cmd, agent_class, channels_csv)
    merged = merge_settings(managed_defaults, base_payload)
    merged = merge_settings(merged, overlay_payload)
    if preserved:
        merged = merge_settings(merged, preserved)
    _normalize_bridge_hook_paths(merged, _bridge_home_from_base_settings(base_path))
    # #1495: strip any non-allowlisted hook event so an isolated home's
    # once-dirty effective file (e.g. the legacy PermissionDenied block)
    # is repaired on this rerender — merge_settings preserves it
    # otherwise — and a fresh render never ships a key Claude Code would
    # reject (which would skip the WHOLE settings file → plugins/MCP off).
    _warn_dropped_hook_keys(_prune_invalid_hook_keys(merged), str(effective_path))
    # #1453: re-assert managed channel-plugin enables over a preserved
    # sticky-false (same trap as the shared renderer above) so an isolated
    # channel agent's inbound delivery is not silently dropped.
    _repair_sticky_false_channel_enables(merged, launch_cmd, str(effective_path), channels_csv)

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
    settings_link.symlink_to("settings.effective.json")  # noqa: raw-pathlib-controller-only — paired with the .unlink() above; needs direct write access on the isolated home, sudo-backed reapply caller has it (see #1178 r2)

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
    """`mkdir -p` with isolation awareness.

    Phase 2: the sudo-first / controller-direct fallback logic moved
    to `bridge_iso_paths.ensure_dir`. This wrapper preserves the
    hooks-side contract where callers can pass `os_user=None` and
    expect a best-effort `_isolated_workdir_owner(path)` recovery
    BEFORE delegation. The canonical helper takes the resolved owner
    as input — pre-Phase 2 the resolution happened inside the local
    helper, which made it impossible to share with bridge-setup.py
    (whose `_isolation_aware_mkdir` does its own
    `_resolve_isolated_owner_for_path` walk upstream).

    Behavior unchanged: on a v2 isolation tree the sudo-first route
    succeeds without raising; on a controller-owned tree the direct
    `mkdir` runs. PermissionError on the controller-direct fallback
    propagates so callers can structure-warn.
    """
    if os_user is None:
        os_user = _isolated_workdir_owner(path)
    _ensure_dir_canonical(path, os_user)


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

    Phase 2: thin delegating wrapper around
    `bridge_iso_paths.safe_realpath`. The canonical implementation
    lives in `lib/bridge_iso_paths.py` so a fix to the sudo-fallback
    shape lands in ONE place. Kept here under the historical private
    name so existing call sites and any local stub harnesses work
    unchanged.
    """
    return _safe_realpath_canonical(path, os_user)


def _safe_readlink(path: Path, os_user: str | None, fallback: str) -> str:
    """PermissionError-safe `os.readlink` for the diagnostic symlink_target line.

    #1672: the final payload prints the raw symlink value for diagnostics.
    On an iso-owned link the controller may lack `+x` on the parent dir and
    `os.readlink` raises PermissionError — which would trade the (now-fixed)
    FileExistsError warning for an UNcaught traceback after the try/except
    OSError block. Mirror the `_safe_realpath` sudo-fallback shape: read the
    raw link value via `sudo -n -u <owner> readlink` (no `-f`, so the printed
    value stays the relative target), and fall back to the caller-supplied
    string (the rel_target we just wrote) when sudo is unavailable. Purely
    diagnostic — no caller parses this value.
    """
    try:
        return os.readlink(path)  # noqa: raw-pathlib-controller-only — guarded by try/except PermissionError with sudo readlink fallback below (diagnostic-only, #1672)
    except PermissionError:
        if os_user is None:
            return fallback
        result = _sudo_run_as_capture(os_user, "readlink", str(path))
        if result.returncode == 0:
            return (result.stdout or "").strip() or fallback
        return fallback


def _resolve_iso_link_realpath(path: Path, os_user: str | None) -> str:
    """Resolve a possibly-iso-owned link's fully-resolved target, iso-FIRST.

    #1672: `_safe_realpath` resolves via `os.path.realpath` and only sudo-
    falls back when that raises PermissionError. But `os.path.realpath`
    NEVER raises on a blocked `lstat` — `os.path.islink` internally swallows
    the OSError and returns False, so `realpath` treats the iso-owned link as
    a plain non-link and returns the UNresolved input path. On the real iso
    boundary the controller cannot `lstat` the link, so `_safe_realpath`
    silently returns the unresolved settings.json path — which never equals
    the intended target, defeating the idempotency check (codex review of
    #1672, blocking finding 1).

    So when `os_user` is known (the link is iso-owned and the controller is
    known to be blind to it), force the `sudo -n -u <owner> readlink -f`
    resolution FIRST — the same escalation pattern as #1170/#1280 iso-owned
    reads — and only fall back to `os.path.realpath` when sudo is unavailable
    (rc 127) or fails, or when there is no iso owner (`os_user is None`, the
    non-isolated / dev-host path where the controller CAN resolve directly).
    """
    if os_user is not None:
        result = _sudo_run_as_capture(os_user, "readlink", "-f", str(path))
        if result.returncode == 0:
            resolved = (result.stdout or "").strip()
            if resolved:
                return resolved
        # sudo unavailable (rc 127) / failed — fall through to the controller-
        # direct resolve. On a true iso boundary this returns the unresolved
        # path (forcing the "not equal" → re-raise branch), which is the
        # fail-closed choice: we never silently swallow a possible conflict.
    return _safe_realpath(path, os_user)


def cmd_link_shared_settings(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    shared_path = Path(args.shared_settings_file).expanduser()
    # #1756 r2: the agent's launched channel context, threaded the same way the
    # render paths receive it (BRIDGE_AGENT_CHANNELS CSV + stored launch
    # command), so the adoption fold can repair a sticky-false launched-channel
    # `enabledPlugins` entry (#1453) instead of re-disabling inbound delivery.
    # Optional/empty for legacy and non-channel callers — then the repair
    # resolves an empty launched set and is a no-op.
    link_launch_cmd = (getattr(args, "launch_cmd", "") or "") or None
    link_channels_csv = (getattr(args, "channels_csv", "") or "") or None
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
            # #1756 (3): fold the regular file's preserved user keys into the
            # shared effective target BEFORE we unlink it, so an operator key
            # (e.g. `model`) written into the per-agent settings.json is not
            # lost the moment we adopt the file into the managed symlink. Done
            # while the regular file still exists; best-effort (no-op when the
            # shared target is missing/unreadable — the link still forms).
            # #1756 r2: thread the agent's launched channel context so the fold
            # repairs a sticky-false launched-channel `enabledPlugins` entry
            # (#1453) instead of re-disabling inbound delivery at adoption time.
            folded = _fold_adopted_user_keys_into_shared(
                settings_path, shared_path, link_launch_cmd, link_channels_csv
            )
            if folded:
                sys.stderr.write(
                    "[info] bridge-hooks: link-shared-settings folded operator "
                    f"key(s) {', '.join(folded)} from {settings_path} into "
                    f"{shared_path} before adoption (#1756 — no loss at "
                    "symlink takeover)\n"
                )
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
            # #1672 idempotence preserved across the #1820 atomic change: the
            # iso false-negative path (where _safe_path_check reports "no link"
            # but a correct symlink really sits on disk) must still resolve to
            # "unchanged" rather than blindly rewriting. Probe the on-disk target
            # FIRST via the iso-aware realpath; if it already points at the
            # desired shared target, short-circuit. (Pre-#1820 this was achieved
            # by letting symlink_to raise FileExistsError and re-checking; the
            # atomic os.replace below never raises FileExistsError, so we must
            # check up front.)
            _existing_target = _resolve_iso_link_realpath(settings_path, os_user)
            _desired_target = _safe_realpath(shared_path, None)
            # Authoritative presence check: os.path.lexists sees a symlink (even
            # broken / cross-boundary) without following it. For an iso-owned
            # path the controller may be lexists-blind, so ALSO treat a resolved
            # target that differs from the path itself (i.e. a real link was
            # followed) as evidence of presence. Note: on an ABSENT path
            # `_resolve_iso_link_realpath` returns the unresolved path itself, so
            # we must compare against settings_path to avoid a false "present".
            _resolved_is_real_link = bool(_existing_target) and (
                _existing_target != _safe_realpath(settings_path, None)
            )
            _on_disk = os.path.lexists(settings_path) or _resolved_is_real_link
            if _existing_target and _existing_target == _desired_target:
                # Already the correct link — idempotent no-op (#1672).
                status = "unchanged"
            elif _on_disk:
                # Something is here but it is NOT our desired target: a
                # wrong-target symlink or a non-symlink collision. Do NOT silently
                # os.replace it — that would clobber an operator file / mask a real
                # conflict. Raise FileExistsError so the structured warning fires
                # (the #1672 REAL-conflict contract, preserved across the #1820
                # atomic-retarget change).
                raise FileExistsError(
                    f"settings.json at {settings_path} is not the managed target"
                )
            else:
                try:
                    # Issue #1820: ATOMIC retarget — create the symlink at a temp
                    # name in the same directory, then os.replace() it over the
                    # final path (rename is atomic on POSIX). This closes the
                    # unlink-then-symlink window where a session could read a
                    # missing/half-written settings.json mid-swap (the verdict
                    # requires the workdir symlink retarget to be atomic).
                    # Controller path only; the iso/sudo fallback below keeps its
                    # `ln -s` form.
                    _tmp_link = settings_path.with_name(
                        f".{settings_path.name}.tmp-{os.getpid()}"
                    )
                    try:
                        _tmp_link.unlink()  # noqa: raw-pathlib-controller-only — clear a stale temp from a crashed prior run; same-dir controller-owned scratch
                    except FileNotFoundError:
                        pass
                    _tmp_link.symlink_to(rel_target)  # noqa: raw-pathlib-controller-only — same-dir temp symlink, atomically renamed over the target below (#1820)
                    os.replace(_tmp_link, settings_path)  # noqa: raw-pathlib-controller-only — atomic rename of the temp symlink onto settings.json (#1820)
                except FileExistsError:
                    # #1672: `_safe_path_check("is_symlink", ...)` false-negatives
                    # on an iso-owned existing symlink (the controller's sudo probe
                    # can't stat it across the boundary), so we conclude "no link"
                    # and re-create — but the link is already there. The atomic
                    # os.replace above does NOT raise FileExistsError (it
                    # overwrites), so this branch is now reached only if the temp
                    # symlink_to itself collides; re-check idempotently against the
                    # EXISTING path's target across the iso boundary via
                    # `_resolve_iso_link_realpath` (forces `sudo -n -u <owner>
                    # readlink -f` when iso-owned). If it already points at the
                    # intended target, no-op (unchanged); a wrong-target or
                    # non-symlink collision is a REAL conflict — re-raise.
                    current_target = _resolve_iso_link_realpath(settings_path, os_user)
                    # `shared_path` is controller-owned (lives under shared/), so a
                    # straight controller-side realpath is correct — no escalation.
                    desired_target = _safe_realpath(shared_path, None)
                    if current_target != desired_target:
                        raise
                    status = "unchanged"
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
    # #1672: read the diagnostic symlink_target iso-safely — on an iso-owned
    # link a bare `os.readlink` can raise PermissionError here (after the
    # try/except OSError above), turning the idempotent-restart path into an
    # uncaught traceback. Fall back to the canonical relative target string.
    _symlink_target_fallback = os.path.relpath(shared_path, start=settings_path.parent)
    if backup_path and args.format != "shell":
        print(f"backup_file: {backup_path}")
        print(f"symlink_target: {_safe_readlink(settings_path, os_user, _symlink_target_fallback)}")
    elif args.format == "shell":
        print(shell_line("HOOK_BACKUP_FILE", backup_path))
        print(shell_line("HOOK_SYMLINK_TARGET", _safe_readlink(settings_path, os_user, _symlink_target_fallback)))
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
    link_shared_parser.add_argument(
        "--launch-cmd",
        default="",
        help="The agent launch command. #1756 r2: parsed for the launched channel plugin set (--channels / --dangerously-load-development-channels) so the adoption fold repairs a sticky-false launched-channel enabledPlugins entry (#1453) instead of re-disabling inbound delivery at symlink takeover. Empty for non-channel/legacy callers => no launched set => repair is a no-op.",
    )
    link_shared_parser.add_argument(
        "--channels-csv",
        default="",
        help="The agent's resolved channels CSV (bridge_agent_channels_csv, from BRIDGE_AGENT_CHANNELS — the SSOT). #1756 r2: needed so the adoption fold knows the launched channel plugin set for normally-created channel agents, whose stored launch command does NOT carry the --channels flag, and repairs a stale enabledPlugins=false for those plugins (#1453).",
    )
    link_shared_parser.add_argument("--format", choices=("text", "shell"), default="text")
    link_shared_parser.set_defaults(handler=cmd_link_shared_settings)

    render_shared_parser = subparsers.add_parser("render-shared-settings")
    render_shared_parser.add_argument("--base-settings-file", required=True)
    render_shared_parser.add_argument("--overlay-settings-file", required=True)
    render_shared_parser.add_argument("--effective-settings-file", required=True)
    render_shared_parser.add_argument(
        "--operator-global-settings-file",
        default="",
        help="Operator's system-global ~/.claude/settings.json (resolved in the shell via bridge_agent_operator_home_dir). For SHARED static agents only, its safety-filtered contents are inherited as the bottom-most render layer so operator-global keys (e.g. agentPushNotifEnabled) propagate while per-class/per-agent managed differences still win (queue #11901). Empty / missing / unreadable / non-object => fail-safe degrade to the bridge base (pre-#11901 behavior).",
    )
    render_shared_parser.add_argument(
        "--launch-cmd",
        default="",
        help="The agent launch command. No longer drives the autoCompactWindow default (issue #570 — that keys off --agent-class), but IS parsed for the launched channel plugin set (--channels / --dangerously-load-development-channels) so managed defaults assert those plugins as enabled and a stale enabledPlugins=false is repaired (#1212, #1453).",
    )
    render_shared_parser.add_argument(
        "--agent-class",
        default="",
        help="static|dynamic — drives the autoCompactWindow default (issue #593: static=400_000, dynamic=1_000_000, unknown=1_000_000).",
    )
    render_shared_parser.add_argument(
        "--channels-csv",
        default="",
        help="The agent's resolved channels CSV (bridge_agent_channels_csv, from BRIDGE_AGENT_CHANNELS — the SSOT). Required so the renderer knows the launched channel plugin set for normally-created channel agents, whose stored launch command does NOT carry the --channels flag (the bridge composes it at launch). Managed defaults assert these plugins enabled and a stale enabledPlugins=false is repaired (#1453).",
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
        help="The agent launch command. No longer drives the autoCompactWindow default (issue #570 — that keys off --agent-class), but IS parsed for the launched channel plugin set (--channels / --dangerously-load-development-channels) so managed defaults assert those plugins as enabled and a stale enabledPlugins=false is repaired (#1212, #1453).",
    )
    render_isolated_parser.add_argument(
        "--agent-class",
        default="",
        help="static|dynamic — drives the autoCompactWindow default (issue #593: static=400_000, dynamic=1_000_000, unknown=1_000_000).",
    )
    render_isolated_parser.add_argument(
        "--channels-csv",
        default="",
        help="The agent's resolved channels CSV (bridge_agent_channels_csv, from BRIDGE_AGENT_CHANNELS — the SSOT). Required so the renderer knows the launched channel plugin set for normally-created channel agents, whose stored launch command does NOT carry the --channels flag (the bridge composes it at launch). Managed defaults assert these plugins enabled and a stale enabledPlugins=false is repaired (#1453).",
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
