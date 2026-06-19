#!/usr/bin/env python3
"""Manage Claude Code .mcp.json webhook channel entries for Agent Bridge."""

from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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
    tmp.replace(path)


def ensure_mcp_root(path: Path) -> dict[str, Any]:
    payload = load_json(path)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"mcp root must be a JSON object: {path}")
    return payload


def mcp_servers(payload: dict[str, Any]) -> dict[str, Any]:
    value = payload.get("mcpServers")
    if isinstance(value, dict):
      return value
    value = {}
    payload["mcpServers"] = value
    return value


def webhook_entry(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "transport": "stdio",
        "command": args.python_bin,
        "args": [args.server_script],
        "env": {
            "BRIDGE_WEBHOOK_PORT": str(args.port),
            "BRIDGE_WEBHOOK_AGENT": args.agent,
            "BRIDGE_HOME": args.bridge_home,
            "BRIDGE_STATE_DIR": args.bridge_state_dir,
            "PYTHONUNBUFFERED": "1",
        },
    }


def print_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
        for key, value in data.items():
            print(f"{key}={json.dumps(str(value))}")
        return

    print(f"mcp_file: {data['MCP_FILE']}")
    print(f"status: {data['MCP_STATUS']}")
    print(f"server_name: {data['MCP_SERVER_NAME']}")
    print(f"webhook_port: {data['MCP_WEBHOOK_PORT']}")
    print(f"command: {data['MCP_COMMAND']}")


def cmd_status_webhook_server(args: argparse.Namespace) -> int:
    mcp_path = Path(args.workdir).expanduser() / ".mcp.json"
    payload = ensure_mcp_root(mcp_path)
    entry = mcp_servers(payload).get(args.server_name)
    desired = webhook_entry(args)
    command = f"{desired['command']} {desired['args'][0]}"
    present = entry == desired
    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": "present" if present else "missing",
            "MCP_SERVER_NAME": args.server_name,
            "MCP_WEBHOOK_PORT": str(args.port),
            "MCP_COMMAND": command,
        },
        args.format,
    )
    return 0 if present else 1


def cmd_ensure_webhook_server(args: argparse.Namespace) -> int:
    mcp_path = Path(args.workdir).expanduser() / ".mcp.json"
    payload = ensure_mcp_root(mcp_path)
    servers = mcp_servers(payload)
    desired = webhook_entry(args)
    changed = servers.get(args.server_name) != desired
    servers[args.server_name] = desired
    if changed:
        save_json(mcp_path, payload)

    command = f"{desired['command']} {desired['args'][0]}"
    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": "updated" if changed else "unchanged",
            "MCP_SERVER_NAME": args.server_name,
            "MCP_WEBHOOK_PORT": str(args.port),
            "MCP_COMMAND": command,
        },
        args.format,
    )
    return 0


def cmd_remove_webhook_server(args: argparse.Namespace) -> int:
    mcp_path = Path(args.workdir).expanduser() / ".mcp.json"
    payload = ensure_mcp_root(mcp_path)
    servers = mcp_servers(payload)
    removed = servers.pop(args.server_name, None) is not None
    status = "removed" if removed else "absent"
    if removed:
        # beta5 QA finding #1: on `agent create --isolate` this legacy-
        # webhook cleanup step runs against a workdir owned by the
        # isolated UID, so `save_json` (mkdir / tmp-write / replace)
        # raises PermissionError. The step is non-essential — the agent
        # is created fine either way — but an uncaught exception dumped
        # a full Python traceback into the create output (the caller in
        # bridge-start.sh / bridge-setup.sh captures stderr and echoes
        # it). Catch the PermissionError / OSError quietly: emit a
        # one-line note in MCP_STATUS, no traceback, and keep rc=0 so the
        # create outcome is unchanged. A genuine cleanup is then the
        # operator's manual follow-up (the callers already warn about a
        # residual `.mcp.json` entry).
        try:
            save_json(mcp_path, payload)
        except (PermissionError, OSError) as exc:
            status = "remove-skipped (not writable)"
            print(
                f"bridge-channels: webhook cleanup skipped — {mcp_path} "
                f"not writable ({exc.__class__.__name__})",
                file=sys.stderr,
            )

    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": status,
            "MCP_SERVER_NAME": args.server_name,
            "MCP_WEBHOOK_PORT": str(args.port),
            "MCP_COMMAND": "",
        },
        args.format,
    )
    return 0


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--bridge-home", required=True)
    parser.add_argument("--bridge-state-dir", required=True)
    parser.add_argument("--python-bin", required=True)
    parser.add_argument("--server-script", required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--format", choices=("text", "shell"), default="text")


# ---------------------------------------------------------------------------
# PreCompact channel auto-notify routing primitive (issue #597 Track A).
#
# Activity index file: $BRIDGE_STATE_DIR/channels/<plugin>/<agent>.json
# Schema:
# {
#   "schema_version": 1,
#   "agent": "<agent-id>",
#   "plugin": "<plugin-id>",     # e.g. "discord", "telegram", "teams", "mattermost"
#   "updated_ts": <epoch>,
#   "channels": {
#     "<platform-channel-id>": {
#       "channel_id": "<platform id>",
#       "reply_kind": "thread|conversation|root",
#       "last_seen_id": "...",
#       "last_seen_ts": <epoch>,
#       "last_user_inbound_ts": <epoch>,
#       "last_user_inbound_ts_ms": <int milliseconds>,
#       "last_user_inbound_message_id": "...",
#       "last_user_inbound_user_id": "...",
#       "last_user_inbound_recorded_ns": <int nanoseconds>,
#       "thread_id": "..." (optional)
#     },
#     ...
#   }
# }
#
# Track A defines the consumer side only. Writers (Discord/Telegram relays
# and the Teams/Mattermost TS plugins) populate this index in later tracks.
# Until those land, the route lookup correctly returns "no route" (exit 1)
# whenever an activity index file is missing or empty.
# ---------------------------------------------------------------------------


_ROUTE_DEFAULT_RECENCY_SECONDS = 1800


def _coerce_recency_seconds(raw: str | int | None) -> int:
    """Coerce a recency value to a positive int, falling back to the default.

    Empty strings, non-numeric strings, zero, and negative values all collapse
    to the 1800-second default per the spec — callers should never need to
    pre-validate this argument.
    """
    if raw is None:
        return _ROUTE_DEFAULT_RECENCY_SECONDS
    if isinstance(raw, int):
        return raw if raw >= 1 else _ROUTE_DEFAULT_RECENCY_SECONDS
    text = str(raw).strip()
    if not text:
        return _ROUTE_DEFAULT_RECENCY_SECONDS
    try:
        value = int(text)
    except ValueError:
        try:
            value = int(float(text))
        except ValueError:
            return _ROUTE_DEFAULT_RECENCY_SECONDS
    return value if value >= 1 else _ROUTE_DEFAULT_RECENCY_SECONDS


def _normalize_channel_token(token: str) -> tuple[str, str] | None:
    """Strip `plugin:` prefix and `@marketplace` suffix from a roster token.

    Returns ``(plugin, channel_key)`` where ``plugin`` is the plugin id
    (e.g. ``discord``) and ``channel_key`` is the marketplace-stripped tail
    used as a sanity check against the roster's declared plugin id.

    Returns ``None`` for empty or malformed tokens (silently skipped).
    """
    if not token:
        return None
    raw = token.strip()
    if not raw:
        return None
    if raw.startswith("plugin:"):
        raw = raw[len("plugin:"):]
    if not raw:
        return None
    # Drop @marketplace suffix if present.
    plugin = raw.split("@", 1)[0].strip()
    if not plugin:
        return None
    return plugin, raw


def _split_channels_csv(csv: str) -> list[tuple[str, str]]:
    """Parse a roster channels CSV into a list of (plugin, raw) pairs."""
    if not csv:
        return []
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    # Tokens may be space- or comma-separated, mirroring bridge_normalize_channels_csv.
    for chunk in csv.replace(",", " ").split():
        normalized = _normalize_channel_token(chunk)
        if normalized is None:
            continue
        plugin = normalized[0]
        if plugin in seen:
            continue
        seen.add(plugin)
        out.append(normalized)
    return out


def _load_activity_index(state_dir: Path, plugin: str, agent: str) -> dict[str, Any] | None:
    """Read the per-plugin per-agent activity index file.

    Returns ``None`` for missing files or malformed JSON. Never raises.
    """
    path = state_dir / "channels" / plugin / f"{agent}.json"
    if not path.exists():
        return None
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _candidate_inbound_ms(entry: dict[str, Any]) -> int | None:
    """Compute the candidate's last_user_inbound timestamp in milliseconds.

    Both ``last_user_inbound_ts`` (epoch seconds) and the optional
    ``last_user_inbound_ts_ms`` (epoch milliseconds) must agree on
    "this entry has a recorded user inbound." If ``last_user_inbound_ts``
    is missing or non-positive the candidate is filtered out — feeders
    that can only emit `_ms` should also emit `_ts = _ms // 1000` so the
    schema invariant holds (codex review of #601 r1 caught this gap).

    When both are present, prefer `_ms` for resolution; fall back to
    `_ts * 1000` when `_ms` is absent or invalid.
    """
    ts_raw = entry.get("last_user_inbound_ts")
    if not (isinstance(ts_raw, (int, float)) and ts_raw > 0):
        return None
    ms_raw = entry.get("last_user_inbound_ts_ms")
    if isinstance(ms_raw, (int, float)) and ms_raw > 0:
        return int(ms_raw)
    return int(ts_raw * 1000)


def _candidate_recorded_ns(entry: dict[str, Any]) -> int:
    """Return ``last_user_inbound_recorded_ns`` as an int (0 when absent)."""
    raw = entry.get("last_user_inbound_recorded_ns")
    if isinstance(raw, (int, float)) and raw >= 0:
        return int(raw)
    return 0


def _collect_route_candidates(
    state_dir: Path,
    agent: str,
    channels: list[tuple[str, str]],
    cutoff_ms: int,
) -> list[dict[str, Any]]:
    """Walk the activity index for each declared plugin and gather candidates.

    Each candidate dict carries the fields needed for argmax + tie-break and
    for shaping the final shell/JSON output.
    """
    candidates: list[dict[str, Any]] = []
    for plugin, _raw in channels:
        index = _load_activity_index(state_dir, plugin, agent)
        if index is None:
            continue
        ch_map = index.get("channels")
        if not isinstance(ch_map, dict):
            continue
        for channel_key, entry in ch_map.items():
            if not isinstance(entry, dict):
                continue
            inbound_ms = _candidate_inbound_ms(entry)
            if inbound_ms is None or inbound_ms < cutoff_ms:
                continue
            message_id = entry.get("last_user_inbound_message_id")
            if not isinstance(message_id, str) or not message_id:
                continue
            channel_id = entry.get("channel_id")
            if not isinstance(channel_id, str) or not channel_id:
                # Fall back to the map key so writers that key by channel id
                # still produce a usable route.
                if isinstance(channel_key, str) and channel_key:
                    channel_id = channel_key
                else:
                    continue
            inbound_ts = entry.get("last_user_inbound_ts")
            if isinstance(inbound_ts, (int, float)) and inbound_ts > 0:
                inbound_ts_int = int(inbound_ts)
            else:
                inbound_ts_int = inbound_ms // 1000
            thread_id = entry.get("thread_id") if isinstance(entry.get("thread_id"), str) else ""
            candidates.append(
                {
                    "plugin": plugin,
                    "channel_id": channel_id,
                    "reply_to_message_id": message_id,
                    "last_user_inbound_ts": inbound_ts_int,
                    "last_user_inbound_ts_ms": inbound_ms,
                    "last_user_inbound_recorded_ns": _candidate_recorded_ns(entry),
                    "thread_id": thread_id or "",
                }
            )
    return candidates


_TIE_WINDOW_MS = 1000


def _select_route(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Pick the most-recent inbound channel with a deterministic 1-second tie window.

    The spec contract is "tie-break when two candidates differ by less
    than one second" — sorting on exact ts_ms first would let a candidate
    1 ms newer beat a same-second peer that has a higher recorded_ns
    (codex review of #601 r1 caught this).

    Algorithm:
    1. Find the maximum ts_ms (call it ``leader_ms``).
    2. Group all candidates with ``ts_ms >= leader_ms - 1000`` (the tie
       window). Anything older than the window is excluded — it lost on
       inbound time, not on tie-break.
    3. Within the tie window, sort by ``recorded_ns`` desc, then lexical
       ``plugin``, ``channel_id``, ``reply_to_message_id``.
    4. Return the first.
    """
    if not candidates:
        return None
    leader_ms = max(int(c["last_user_inbound_ts_ms"]) for c in candidates)
    floor_ms = leader_ms - _TIE_WINDOW_MS
    tie_window = [c for c in candidates if int(c["last_user_inbound_ts_ms"]) >= floor_ms]
    return min(
        tie_window,
        key=lambda c: (
            -int(c["last_user_inbound_recorded_ns"]),
            c["plugin"],
            c["channel_id"],
            c["reply_to_message_id"],
        ),
    )


def _print_route(route: dict[str, Any], fmt: str) -> None:
    """Emit the selected route in shell or JSON format."""
    payload = {
        "CHANNEL_ROUTE_PLUGIN": route["plugin"],
        "CHANNEL_ROUTE_CHANNEL_ID": route["channel_id"],
        "CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID": route["reply_to_message_id"],
        "CHANNEL_ROUTE_LAST_USER_INBOUND_TS": str(route["last_user_inbound_ts"]),
    }
    if route.get("thread_id"):
        payload["CHANNEL_ROUTE_THREAD_ID"] = route["thread_id"]
    if fmt == "json":
        print(json.dumps(payload, ensure_ascii=False))
        return
    for key, value in payload.items():
        print(f"{key}={json.dumps(str(value))}")


def cmd_route_precompact_target(args: argparse.Namespace) -> int:
    """Resolve the best PreCompact reply target for ``--agent``.

    On success: prints shell/json key=value assignments and exits 0.
    On no route: exits 1 with no stdout (silent skip path for the daemon).
    """
    recency_seconds = _coerce_recency_seconds(args.recency_seconds)
    try:
        now_ts_int = int(args.now_ts) if args.now_ts not in (None, "") else 0
    except (TypeError, ValueError):
        now_ts_int = 0
    if now_ts_int <= 0:
        import time as _time
        now_ts_int = int(_time.time())
    cutoff_ms = (now_ts_int - recency_seconds) * 1000

    channels = _split_channels_csv(args.channels_csv or "")
    if not channels:
        return 1

    state_dir = Path(args.bridge_state_dir).expanduser()
    candidates = _collect_route_candidates(state_dir, args.agent, channels, cutoff_ms)
    route = _select_route(candidates)
    if route is None:
        return 1
    _print_route(route, args.format)
    return 0


# ---------------------------------------------------------------------------
# PreCompact send-managed-message + templates + EMA stats (issue #597 Track B).
#
# This block adds:
#   1. Localized notice / followup template rendering with override envs.
#   2. EMA-backed stats file at $BRIDGE_STATE_DIR/precompact-stats.json with
#      fcntl.flock + atomic replace; mirrors bridge-memory.py's pattern.
#   3. Per-plugin send adapters for Discord and Telegram (operator-side
#      credentials/access state). Teams + Mattermost return a structured
#      `track-c-pending` error so the daemon's audit row records the gap
#      until Track C ships the TS-side CLI mode.
#
# Track D (the relay activity-index writers) and Track C (TS plugin server
# changes) are intentionally out of scope here.
# ---------------------------------------------------------------------------


_PRECOMPACT_STATS_SCHEMA_VERSION = 1
_EMA_ALPHA_DEFAULT = 0.30
_EMA_ALPHA_MIN = 0.01
_EMA_ALPHA_MAX = 1.00
_EXPECTED_SECONDS_FALLBACK = 45
_EXPECTED_SECONDS_MIN = 5
_EXPECTED_SECONDS_MAX = 900
_PLUGINS_TRACK_C_PENDING = ("mattermost",)
_HTTP_TIMEOUT_SECONDS = 10.0


_DEFAULT_TEMPLATES = {
    "notice": {
        "en": "Heads up: {agent} is compacting its context now. I should be back in about {expected_seconds}s.",
        "ko": "{agent} 컨텍스트 압축이 시작됐습니다. 약 {expected_seconds}초 뒤에 다시 응답할 수 있습니다.",
    },
    "followup": {
        "en": "{agent} is back online after compaction. Thanks for waiting.",
        "ko": "{agent} 컨텍스트 압축이 끝났습니다. 이제 다시 응답할 수 있습니다.",
    },
}

_TEMPLATE_ENV_KEYS = {
    "notice": {
        "en": "BRIDGE_PRECOMPACT_NOTIFY_TEMPLATE_EN",
        "ko": "BRIDGE_PRECOMPACT_NOTIFY_TEMPLATE_KO",
    },
    "followup": {
        "en": "BRIDGE_PRECOMPACT_FOLLOWUP_TEMPLATE_EN",
        "ko": "BRIDGE_PRECOMPACT_FOLLOWUP_TEMPLATE_KO",
    },
}


def _normalize_lang(raw: str | None) -> str:
    """Normalize a language hint to one of the supported codes ("en"|"ko")."""
    if not raw:
        return "en"
    code = str(raw).strip().lower()
    if code in ("en", "ko"):
        return code
    return "en"


def _resolve_template(kind: str, lang: str) -> str:
    """Pick the active template for `kind` ∈ {notice, followup} and `lang`.

    Resolution: env override (BRIDGE_PRECOMPACT_*_TEMPLATE_EN/KO) → default.
    The override env is ignored when empty/whitespace.
    """
    env_key = _TEMPLATE_ENV_KEYS.get(kind, {}).get(lang)
    if env_key:
        override = os.environ.get(env_key, "")
        if override and override.strip():
            return override
    return _DEFAULT_TEMPLATES.get(kind, {}).get(lang) or _DEFAULT_TEMPLATES["notice"]["en"]


def _format_template(template: str, fields: dict[str, Any]) -> str:
    """Substitute `{name}` placeholders with `fields`; missing keys render empty.

    Using a custom dict-of-strings rather than `str.format(**fields)` so a
    template that references a field we did not compute does not raise KeyError
    — that would surface as a send failure instead of a degraded but
    deliverable message.
    """
    class _SafeDict(dict):
        def __missing__(self, key: str) -> str:  # type: ignore[override]
            return ""

    try:
        return template.format_map(_SafeDict(fields))
    except (IndexError, ValueError):
        # Malformed template: fall back to the raw template so the operator
        # at least gets a delivered notice that points at their own typo.
        return template


def _coerce_alpha(raw: str | float | int | None) -> float:
    """Clamp the EMA alpha from env to [0.01, 1.00]; default 0.30."""
    if raw is None or raw == "":
        return _EMA_ALPHA_DEFAULT
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return _EMA_ALPHA_DEFAULT
    if math.isnan(value) or math.isinf(value):
        return _EMA_ALPHA_DEFAULT
    return max(_EMA_ALPHA_MIN, min(_EMA_ALPHA_MAX, value))


def _ema_update(prior: float | None, sample: float, alpha: float) -> float:
    """Exponential moving average — first sample seeds the EMA at the sample."""
    if prior is None or prior <= 0:
        return float(sample)
    return float(alpha) * float(sample) + (1.0 - float(alpha)) * float(prior)


def _stats_path(state_dir: Path) -> Path:
    return state_dir / "precompact-stats.json"


def _stats_lock_path(state_dir: Path) -> Path:
    return state_dir / "precompact-stats.json.lock"


def _load_stats(state_dir: Path) -> dict[str, Any]:
    """Read precompact-stats.json or return a freshly seeded skeleton.

    Caller MUST hold the sibling .lock flock. On parse failure, the corrupt
    file is renamed aside and a fresh skeleton is returned so the writer
    starts from a clean slate (mirrors the spec's risk-mitigation guidance).
    """
    path = _stats_path(state_dir)
    if not path.exists():
        return _empty_stats()
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        try:
            corrupt = path.with_suffix(path.suffix + f".corrupt-{int(time.time())}")
            path.replace(corrupt)
        except OSError:
            pass
        return _empty_stats()
    if not isinstance(payload, dict):
        return _empty_stats()
    if "schema_version" not in payload:
        payload["schema_version"] = _PRECOMPACT_STATS_SCHEMA_VERSION
    if not isinstance(payload.get("agents"), dict):
        payload["agents"] = {}
    if not isinstance(payload.get("global"), dict):
        payload["global"] = _empty_global_stats()
    return payload


def _empty_global_stats() -> dict[str, Any]:
    return {
        "count": 0,
        "ema_seconds": 0.0,
        "last_duration_seconds": 0,
        "last_started_ts": 0,
        "last_completed_ts": 0,
    }


def _empty_agent_stats() -> dict[str, Any]:
    return {
        "count": 0,
        "auto_count": 0,
        "manual_count": 0,
        "ema_seconds": 0.0,
        "auto_ema_seconds": 0.0,
        "manual_ema_seconds": 0.0,
        "last_duration_seconds": 0,
        "last_trigger": "",
        "last_started_ts": 0,
        "last_completed_ts": 0,
    }


def _empty_stats() -> dict[str, Any]:
    return {
        "schema_version": _PRECOMPACT_STATS_SCHEMA_VERSION,
        "host": socket.gethostname(),
        "updated_ts": 0,
        "alpha": _EMA_ALPHA_DEFAULT,
        "global": _empty_global_stats(),
        "agents": {},
    }


def _save_stats(state_dir: Path, payload: dict[str, Any]) -> None:
    """Atomic temp-then-replace write of precompact-stats.json.

    Caller MUST hold the sibling .lock flock.
    """
    path = _stats_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    try:
        json.dump(payload, tmp, ensure_ascii=False, indent=2)
        tmp.write("\n")
        tmp.flush()
        try:
            os.fsync(tmp.fileno())
        except OSError:
            pass
    finally:
        tmp.close()
    os.replace(tmp.name, path)


def _expected_seconds(stats: dict[str, Any], agent: str) -> int:
    """Resolve `expected_seconds` for the notice template.

    Order: agent.auto_ema_seconds → agent.ema_seconds → global.ema_seconds →
    BRIDGE_PRECOMPACT_NOTIFY_DEFAULT_EXPECTED_SECONDS env → 45. Result is
    rounded up to a whole second and clamped to [5, 900] for display.
    """
    agent_stats = stats.get("agents", {}).get(agent, {}) if isinstance(stats, dict) else {}
    candidate = 0.0
    for key in ("auto_ema_seconds", "ema_seconds"):
        val = agent_stats.get(key) if isinstance(agent_stats, dict) else None
        if isinstance(val, (int, float)) and val > 0:
            candidate = float(val)
            break
    if candidate <= 0:
        global_stats = stats.get("global", {}) if isinstance(stats, dict) else {}
        gval = global_stats.get("ema_seconds") if isinstance(global_stats, dict) else None
        if isinstance(gval, (int, float)) and gval > 0:
            candidate = float(gval)
    if candidate <= 0:
        env_default = os.environ.get("BRIDGE_PRECOMPACT_NOTIFY_DEFAULT_EXPECTED_SECONDS", "")
        try:
            ev = float(env_default) if env_default else 0.0
        except (TypeError, ValueError):
            ev = 0.0
        if ev > 0:
            candidate = ev
    if candidate <= 0:
        candidate = float(_EXPECTED_SECONDS_FALLBACK)
    rounded = int(math.ceil(candidate))
    return max(_EXPECTED_SECONDS_MIN, min(_EXPECTED_SECONDS_MAX, rounded))


def _read_stats_for_render(state_dir: Path) -> dict[str, Any]:
    """Read stats under a shared flock. Returns an empty skeleton on any IO error."""
    path = _stats_path(state_dir)
    if not path.exists():
        return _empty_stats()
    lock_path = _stats_lock_path(state_dir)
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return _empty_stats()
    try:
        with lock_path.open("a") as lock_handle:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_SH)
            except OSError:
                pass
            try:
                return _load_stats(state_dir)
            finally:
                try:
                    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
    except OSError:
        return _empty_stats()


def _record_completion_stats(
    state_dir: Path,
    agent: str,
    trigger: str,
    started_ts: int,
    completed_ts: int,
    alpha: float,
) -> dict[str, Any]:
    """Append a started/completed pair to precompact-stats.json under flock.

    Returns the post-update stats payload (including the agent and global
    ema_seconds the daemon can echo into the audit row).
    """
    duration = max(0, int(completed_ts) - int(started_ts))
    lock_path = _stats_lock_path(state_dir)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        except OSError:
            # Without flock we still proceed; concurrent writers are rare and
            # we'd rather miss a sample than block the daemon loop.
            pass
        try:
            payload = _load_stats(state_dir)
            payload["alpha"] = float(alpha)
            payload["host"] = socket.gethostname()
            payload["updated_ts"] = int(time.time())

            agents = payload.setdefault("agents", {})
            agent_stats = agents.get(agent)
            if not isinstance(agent_stats, dict):
                agent_stats = _empty_agent_stats()
                agents[agent] = agent_stats

            agent_stats["count"] = int(agent_stats.get("count", 0)) + 1
            trigger_norm = (trigger or "").strip().lower()
            if trigger_norm == "auto":
                agent_stats["auto_count"] = int(agent_stats.get("auto_count", 0)) + 1
                agent_stats["auto_ema_seconds"] = _ema_update(
                    agent_stats.get("auto_ema_seconds"), duration, alpha
                )
            elif trigger_norm == "manual":
                agent_stats["manual_count"] = int(agent_stats.get("manual_count", 0)) + 1
                agent_stats["manual_ema_seconds"] = _ema_update(
                    agent_stats.get("manual_ema_seconds"), duration, alpha
                )
            agent_stats["ema_seconds"] = _ema_update(
                agent_stats.get("ema_seconds"), duration, alpha
            )
            agent_stats["last_duration_seconds"] = duration
            agent_stats["last_trigger"] = trigger_norm
            agent_stats["last_started_ts"] = int(started_ts)
            agent_stats["last_completed_ts"] = int(completed_ts)

            global_stats = payload.setdefault("global", _empty_global_stats())
            global_stats["count"] = int(global_stats.get("count", 0)) + 1
            global_stats["ema_seconds"] = _ema_update(
                global_stats.get("ema_seconds"), duration, alpha
            )
            global_stats["last_duration_seconds"] = duration
            global_stats["last_started_ts"] = int(started_ts)
            global_stats["last_completed_ts"] = int(completed_ts)

            _save_stats(state_dir, payload)
            return payload
        finally:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def _format_started_time(ts: int | str | None) -> str:
    """Best-effort ISO-second formatter for template fields."""
    try:
        epoch = int(ts) if ts not in (None, "") else 0
    except (TypeError, ValueError):
        return ""
    if epoch <= 0:
        return ""
    try:
        return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="seconds")
    except (OverflowError, OSError, ValueError):
        return ""


def _render_managed_message(
    kind: str,
    lang: str,
    agent: str,
    expected_seconds: int,
    duration_seconds: int,
    started_ts: int,
    completed_ts: int,
    plugin: str,
    channel_id: str,
    trigger: str,
) -> str:
    """Render the notice or followup body for the requested language."""
    lang_norm = _normalize_lang(lang)
    template = _resolve_template(kind, lang_norm)
    fields = {
        "agent": agent,
        "expected_seconds": expected_seconds,
        "expected_minutes": max(1, math.ceil(expected_seconds / 60)),
        "duration_seconds": duration_seconds,
        "duration_minutes": max(1, math.ceil(duration_seconds / 60)) if duration_seconds else 0,
        "started_time": _format_started_time(started_ts),
        "completed_time": _format_started_time(completed_ts),
        "channel": channel_id,
        "host": socket.gethostname(),
        "trigger": trigger or "",
    }
    return _format_template(template, fields)


# ---------------------------------------------------------------------------
# Per-plugin send adapters.
#
# These are operator-side senders that read per-agent plugin state under
# <BRIDGE_HOME>/agents/<agent>/.<plugin>/. They are intentionally minimal —
# they only do what the daemon's PreCompact notice needs (post a short message
# in reply to a known channel/message id) and do not attempt to mirror the
# full plugin surface.
#
# Each adapter returns a tuple `(message_id, thread_id)` on success and
# raises a SendAdapterError on failure. Discord + Telegram are implemented
# in Track B; Teams + Mattermost return a structured `track-c-pending`
# error so the daemon's audit row records the gap until Track C lands.
# ---------------------------------------------------------------------------


class SendAdapterError(Exception):
    """Structured failure wrapper for managed-message adapter calls."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _agent_plugin_dir(bridge_home: Path, agent: str, plugin: str) -> Path:
    """Naive `<bridge_home>/agents/<agent>/.<plugin>` default.

    This only matches a plain shared-mode layout where the agent's workdir IS
    `<bridge_home>/agents/<agent>`. For iso-v2 agents, agents with an explicit
    BRIDGE_AGENT_WORKDIR, or a BRIDGE_DATA_ROOT-relocated install the canonical
    per-agent plugin state dir is `<workdir>/.<plugin>` — resolved in bash by
    `bridge_agent_<plugin>_state_dir` and threaded in via `--plugin-state-dir`
    (#2005). Callers must prefer that bash SSOT value and treat this only as a
    last-resort fallback (and log when they fall back).
    """
    return bridge_home / "agents" / agent / f".{plugin}"


def _resolve_plugin_state_dir(
    bridge_home: Path, agent: str, plugin: str, plugin_state_dir: str
) -> Path:
    """Return the canonical per-agent plugin state dir for an HTTP adapter.

    Prefers the bash-resolved `--plugin-state-dir` value (the
    `bridge_agent_<plugin>_state_dir` SSOT, which honors the iso-v2 /
    BRIDGE_AGENT_WORKDIR-map / BRIDGE_DATA_ROOT workdir precedence). Falls back
    to the naive `_agent_plugin_dir` only when the arg is empty, and logs the
    fallback so an iso/custom-workdir mismatch is visible rather than silently
    reading credentials from the wrong directory (#2005).
    """
    resolved = (plugin_state_dir or "").strip()
    if resolved:
        return Path(resolved).expanduser()
    fallback = _agent_plugin_dir(bridge_home, agent, plugin)
    print(
        f"send-managed-message warning: {plugin} adapter received no "
        f"--plugin-state-dir; falling back to {fallback} (canonical value is "
        f"the bash-resolved bridge_agent_{plugin}_state_dir)",
        file=sys.stderr,
    )
    return fallback


def _read_dotenv(path: Path) -> dict[str, str]:
    """Parse a `KEY=value` style .env file. Tolerates missing/unreadable files."""
    out: dict[str, str] = {}
    if not path.exists():
        return out
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return out
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if (value.startswith("\"") and value.endswith("\"")) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        if key:
            out[key] = value
    return out


def _http_post_json(url: str, payload: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    """POST a JSON body and decode the JSON response.

    Raises SendAdapterError on transport failure or non-2xx response. The
    raw response body is included in the error message (truncated) so the
    daemon's audit row can surface the platform-side reason.
    """
    body = json.dumps(payload).encode("utf-8")
    base_headers = {"Content-Type": "application/json", "Accept": "application/json"}
    base_headers.update(headers)
    request = urllib.request.Request(url, data=body, headers=base_headers, method="POST")
    try:
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(request, timeout=_HTTP_TIMEOUT_SECONDS, context=ctx) as response:
            raw = response.read()
            if response.status < 200 or response.status >= 300:
                raise SendAdapterError(
                    "http_error",
                    f"HTTP {response.status}: {raw[:200]!r}",
                )
            try:
                return json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError):
                return {}
    except urllib.error.HTTPError as exc:
        try:
            raw = exc.read()[:200]
        except Exception:
            raw = b""
        raise SendAdapterError("http_error", f"HTTP {exc.code}: {raw!r}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SendAdapterError("network_error", str(exc)) from exc


def _adapter_discord(
    bridge_home: Path,
    agent: str,
    channel_id: str,
    reply_to_message_id: str,
    body: str,
    plugin_state_dir: str = "",
) -> tuple[str, str]:
    """Discord adapter — POST /channels/{id}/messages with message_reference.

    Reads the bot token from the per-agent .discord/.env (DISCORD_BOT_TOKEN
    or BRIDGE_DISCORD_BOT_TOKEN); the access.json sidecar can override the
    token, mirroring how bridge-setup.py persists Discord credentials.

    `plugin_state_dir` is the canonical `.discord` dir resolved in bash by
    `bridge_agent_discord_state_dir` (the `<workdir>/.discord` SSOT that
    bridge-setup.py also writes to). We read from that, not a Python-derived
    path — see `_resolve_plugin_state_dir` (#2005).
    """
    plugin_dir = _resolve_plugin_state_dir(bridge_home, agent, "discord", plugin_state_dir)
    env = _read_dotenv(plugin_dir / ".env")
    token = (
        env.get("DISCORD_BOT_TOKEN")
        or env.get("BRIDGE_DISCORD_BOT_TOKEN")
        or env.get("DISCORD_TOKEN")
    )
    access_path = plugin_dir / "access.json"
    if access_path.exists():
        try:
            access = json.loads(access_path.read_text(encoding="utf-8"))
            if isinstance(access, dict):
                token = access.get("bot_token") or access.get("token") or token
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            pass
    if not token:
        raise SendAdapterError("missing_credentials", "discord bot token not configured")

    payload: dict[str, Any] = {"content": body[:2000]}
    if reply_to_message_id:
        payload["message_reference"] = {
            "channel_id": channel_id,
            "message_id": reply_to_message_id,
            # fail_if_not_exists=False: if the original was deleted, still
            # post in the channel rather than rejecting the send.
            "fail_if_not_exists": False,
        }
        # Suppress the "@<user>" ping inherited from the reply chain.
        payload["allowed_mentions"] = {"replied_user": False, "parse": []}

    url = f"https://discord.com/api/v10/channels/{urllib.parse.quote(channel_id)}/messages"
    response = _http_post_json(
        url,
        payload,
        {"Authorization": f"Bot {token}", "User-Agent": "agent-bridge/0 (+precompact-notify)"},
    )
    message_id = str(response.get("id") or "")
    thread_id = ""
    if not message_id:
        raise SendAdapterError("malformed_response", "discord response missing message id")
    return message_id, thread_id


def _adapter_telegram(
    bridge_home: Path,
    agent: str,
    channel_id: str,
    reply_to_message_id: str,
    body: str,
    plugin_state_dir: str = "",
) -> tuple[str, str]:
    """Telegram adapter — POST /bot{token}/sendMessage with reply_parameters.

    Reads the bot token from the per-agent .telegram/.env; access.json may
    override. Uses the modern `reply_parameters` envelope when a reply id is
    provided so quote-replies survive forum topics and supergroup retargets.

    `plugin_state_dir` is the canonical `.telegram` dir resolved in bash by
    `bridge_agent_telegram_state_dir` (the `<workdir>/.telegram` SSOT that
    bridge-setup.py also writes to). We read from that, not a Python-derived
    path — see `_resolve_plugin_state_dir` (#2005).
    """
    plugin_dir = _resolve_plugin_state_dir(bridge_home, agent, "telegram", plugin_state_dir)
    env = _read_dotenv(plugin_dir / ".env")
    token = (
        env.get("TELEGRAM_BOT_TOKEN")
        or env.get("BRIDGE_TELEGRAM_BOT_TOKEN")
        or env.get("TELEGRAM_TOKEN")
    )
    access_path = plugin_dir / "access.json"
    if access_path.exists():
        try:
            access = json.loads(access_path.read_text(encoding="utf-8"))
            if isinstance(access, dict):
                token = access.get("bot_token") or access.get("token") or token
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            pass
    if not token:
        raise SendAdapterError("missing_credentials", "telegram bot token not configured")

    # Telegram caps message bodies around 4096 chars; truncate well below.
    payload: dict[str, Any] = {"chat_id": channel_id, "text": body[:4000]}
    if reply_to_message_id:
        try:
            mid = int(reply_to_message_id)
            payload["reply_parameters"] = {
                "message_id": mid,
                "allow_sending_without_reply": True,
            }
        except (TypeError, ValueError):
            # If the message id is non-numeric (shouldn't happen for Telegram),
            # send without a reply anchor rather than failing the whole send.
            pass

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    response = _http_post_json(url, payload, {})
    if not response.get("ok"):
        raise SendAdapterError(
            "platform_error",
            f"telegram error: {response.get('description') or response}",
        )
    result = response.get("result") if isinstance(response.get("result"), dict) else {}
    message_id = str(result.get("message_id") or "")
    thread_id = str(result.get("message_thread_id") or "")
    if not message_id:
        raise SendAdapterError("malformed_response", "telegram response missing message_id")
    return message_id, thread_id


_BUN_CANDIDATES = (
    "~/.bun/bin/bun",
    "/usr/local/bin/bun",
    "/opt/homebrew/bin/bun",
)
# Teams send-managed shells out to a bun process that does a single proactive
# Bot Framework send. Give it more headroom than the HTTP adapters (which talk
# straight to an API) since bun start-up + continueConversation can be slower.
_TEAMS_SEND_TIMEOUT_SECONDS = 30.0


def _resolve_bun() -> str | None:
    """Locate the bun runtime: PATH first, then the usual install prefixes."""
    found = shutil.which("bun")
    if found:
        return found
    for candidate in _BUN_CANDIDATES:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def _adapter_teams(
    bridge_home: Path,
    agent: str,
    channel_id: str,
    reply_to_message_id: str,
    body: str,
    plugin_state_dir: str = "",
) -> tuple[str, str]:
    """Teams adapter — shell out to `bun plugins/teams/server.ts send-managed`.

    Unlike discord/telegram, Teams has no simple bot-token HTTP send: the
    proactive DM goes through the stored Bot Framework ConversationReference,
    which only the bundled bun plugin can replay (`continueConversation`). So
    this adapter spawns the plugin CLI rather than POSTing.

    `plugin_state_dir` is the canonical `.teams` state dir resolved in bash by
    `bridge_agent_teams_state_dir` (which honors the full iso-v2 /
    BRIDGE_AGENT_WORKDIR-map / BRIDGE_DATA_ROOT workdir precedence). We do NOT
    re-derive it in Python — the bash value is the single source of truth and
    is exported to the plugin as TEAMS_STATE_DIR so it reads the same
    conversations.json the inbound listener seeded. The shared resolver below
    falls back to `<bridge_home>/agents/<agent>/.teams` (a last-resort default
    matching only a plain shared-mode layout) and logs the fallback so an
    iso/custom-workdir mismatch is visible rather than silently wrong.
    """
    server_ts = bridge_home / "plugins" / "teams" / "server.ts"
    if not server_ts.is_file():
        raise SendAdapterError(
            "missing_plugin", f"teams plugin server.ts not found: {server_ts}"
        )

    bun = _resolve_bun()
    if not bun:
        raise SendAdapterError(
            "missing_bun",
            "bun runtime not found on PATH or common install prefixes; "
            "teams managed-send requires bun",
        )

    resolved_state_dir = str(
        _resolve_plugin_state_dir(bridge_home, agent, "teams", plugin_state_dir)
    )

    argv = [
        bun,
        str(server_ts),
        "send-managed",
        "--agent",
        agent,
        "--channel-id",
        channel_id,
        "--body",
        body,
    ]
    if reply_to_message_id:
        argv += ["--reply-to-message-id", reply_to_message_id]

    env = os.environ.copy()
    env["BRIDGE_AGENT_ID"] = agent
    env["TEAMS_STATE_DIR"] = resolved_state_dir

    try:
        proc = subprocess.run(
            argv,
            env=env,
            capture_output=True,
            text=True,
            timeout=_TEAMS_SEND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise SendAdapterError(
            "network_error", f"teams send-managed timed out: {exc}"
        ) from exc
    except OSError as exc:
        raise SendAdapterError(
            "spawn_error", f"teams send-managed could not spawn bun: {exc}"
        ) from exc

    rc = proc.returncode
    stderr_tail = (proc.stderr or "").strip()[-400:]
    if rc == 2:
        raise SendAdapterError(
            "missing_args", f"teams send-managed missing args: {stderr_tail}"
        )
    if rc == 3:
        raise SendAdapterError(
            "ref_not_found",
            "teams send-managed has no stored conversation reference for "
            f"channel_id={channel_id} (the operator never messaged this bot, "
            f"so there is no proactive-DM target yet): {stderr_tail}",
        )
    if rc != 0:
        raise SendAdapterError(
            "send_failed", f"teams send-managed failed (rc={rc}): {stderr_tail}"
        )

    try:
        response = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise SendAdapterError(
            "malformed_response",
            f"teams send-managed returned non-JSON stdout: {exc}",
        ) from exc
    if not isinstance(response, dict):
        raise SendAdapterError(
            "malformed_response", "teams send-managed stdout is not a JSON object"
        )

    message_id = str(response.get("message_id") or "")
    thread_id = str(response.get("thread_id") or "")
    if not message_id:
        raise SendAdapterError(
            "malformed_response", "teams send-managed response missing message_id"
        )
    return message_id, thread_id


def _dispatch_send(
    plugin: str,
    bridge_home: Path,
    agent: str,
    channel_id: str,
    reply_to_message_id: str,
    body: str,
    plugin_state_dir: str = "",
) -> tuple[str, str]:
    """Route the send call to the correct adapter, raising SendAdapterError.

    `plugin_state_dir` is the bash-resolved `bridge_agent_<plugin>_state_dir`
    SSOT (`<workdir>/.<plugin>`), threaded in for every HTTP/CLI adapter so
    Python never re-derives the workdir (#2005). Each adapter falls back to the
    naive `<bridge_home>/agents/<agent>/.<plugin>` only when it is empty.
    """
    if plugin == "discord":
        return _adapter_discord(
            bridge_home, agent, channel_id, reply_to_message_id, body, plugin_state_dir
        )
    if plugin == "telegram":
        return _adapter_telegram(
            bridge_home, agent, channel_id, reply_to_message_id, body, plugin_state_dir
        )
    if plugin == "teams":
        return _adapter_teams(
            bridge_home, agent, channel_id, reply_to_message_id, body, plugin_state_dir
        )
    if plugin in _PLUGINS_TRACK_C_PENDING:
        # Teams / Mattermost true managed-send needs the TS plugin server's
        # CLI extension (Track C). Returning a structured error here lets the
        # daemon's audit row name the gap precisely without the operator
        # having to grep the code to find out why nothing went out.
        raise SendAdapterError(
            "track_c_pending",
            f"managed-message send for plugin={plugin} requires Track C TS plugin extension",
        )
    raise SendAdapterError("unsupported_plugin", f"unsupported plugin: {plugin}")


def _emit_send_payload(payload: dict[str, str], fmt: str) -> None:
    """Print the result either as `KEY="value"` shell pairs or single-line JSON."""
    if fmt == "json":
        print(json.dumps(payload, ensure_ascii=False))
        return
    for key, value in payload.items():
        print(f"{key}={json.dumps(str(value))}")


def cmd_send_managed_message(args: argparse.Namespace) -> int:
    """Send a managed PreCompact notice or followup via the resolved plugin.

    Honors `--dry-run` for CI/smoke; in dry-run mode the adapter is bypassed
    entirely and a deterministic synthetic message id is emitted so the
    daemon's pending-state writer can still close the loop.
    """
    bridge_home = Path(args.bridge_home).expanduser()
    state_dir = Path(args.bridge_state_dir).expanduser()
    plugin = (args.plugin or "").strip().lower()
    agent = (args.agent or "").strip()
    channel_id = (args.channel_id or "").strip()
    body = args.body or ""
    kind = (args.kind or "notice").strip().lower()
    if kind not in ("notice", "followup"):
        kind = "notice"
    reply_to = (args.reply_to_message_id or "").strip()
    correlation_id = (args.correlation_id or "").strip()
    plugin_state_dir = (getattr(args, "plugin_state_dir", "") or "").strip()

    if not plugin or not agent or not channel_id or not body:
        return 2

    if args.dry_run:
        synthetic_id = f"dryrun-{int(time.time() * 1000)}"
        _emit_send_payload(
            {
                "CHANNEL_SEND_STATUS": "ok",
                "CHANNEL_SEND_PLUGIN": plugin,
                "CHANNEL_SEND_CHANNEL_ID": channel_id,
                "CHANNEL_SEND_REPLY_TO_MESSAGE_ID": reply_to,
                "CHANNEL_SEND_MESSAGE_ID": synthetic_id,
                "CHANNEL_SEND_THREAD_ID": "",
                "CHANNEL_SEND_DRY_RUN": "1",
                "CHANNEL_SEND_KIND": kind,
                "CHANNEL_SEND_CORRELATION_ID": correlation_id,
            },
            args.format,
        )
        return 0

    # Daemon log channel — the daemon redirects stdout to a captured pipe and
    # parses CHANNEL_SEND_* assignments, so structured error context belongs
    # on stderr where bridge-daemon.sh forwards it to the audit row reason.
    try:
        message_id, thread_id = _dispatch_send(
            plugin, bridge_home, agent, channel_id, reply_to, body, plugin_state_dir
        )
    except SendAdapterError as exc:
        print(f"send-managed-message error: {exc.code}: {exc.message}", file=sys.stderr)
        return 1

    # Stats access here is read-only — record_completion_stats happens in the
    # follow-up dispatch when the daemon pairs the started/completed markers.
    _ = state_dir

    _emit_send_payload(
        {
            "CHANNEL_SEND_STATUS": "ok",
            "CHANNEL_SEND_PLUGIN": plugin,
            "CHANNEL_SEND_CHANNEL_ID": channel_id,
            "CHANNEL_SEND_REPLY_TO_MESSAGE_ID": reply_to,
            "CHANNEL_SEND_MESSAGE_ID": message_id,
            "CHANNEL_SEND_THREAD_ID": thread_id,
            "CHANNEL_SEND_DRY_RUN": "0",
            "CHANNEL_SEND_KIND": kind,
            "CHANNEL_SEND_CORRELATION_ID": correlation_id,
        },
        args.format,
    )
    return 0


def cmd_render_precompact_message(args: argparse.Namespace) -> int:
    """Stand-alone renderer used by the daemon to produce notice/followup body.

    Accepts most of the per-event context as flags so the daemon can call
    it once per send without round-tripping through stats again. When
    `--read-stats` is set, the renderer pulls `expected_seconds` from
    precompact-stats.json (under shared flock); otherwise it uses the
    explicit `--expected-seconds` value.
    """
    state_dir = Path(args.bridge_state_dir).expanduser()
    expected_seconds = 0
    try:
        if args.expected_seconds not in (None, ""):
            expected_seconds = int(args.expected_seconds)
    except (TypeError, ValueError):
        expected_seconds = 0
    if expected_seconds <= 0 and args.read_stats:
        stats = _read_stats_for_render(state_dir)
        expected_seconds = _expected_seconds(stats, args.agent)
    if expected_seconds <= 0:
        expected_seconds = _EXPECTED_SECONDS_FALLBACK

    duration_seconds = 0
    try:
        if args.duration_seconds not in (None, ""):
            duration_seconds = max(0, int(args.duration_seconds))
    except (TypeError, ValueError):
        duration_seconds = 0

    started_ts = 0
    try:
        started_ts = int(args.started_ts) if args.started_ts not in (None, "") else 0
    except (TypeError, ValueError):
        started_ts = 0
    completed_ts = 0
    try:
        completed_ts = int(args.completed_ts) if args.completed_ts not in (None, "") else 0
    except (TypeError, ValueError):
        completed_ts = 0

    body = _render_managed_message(
        kind=args.kind,
        lang=args.lang,
        agent=args.agent,
        expected_seconds=expected_seconds,
        duration_seconds=duration_seconds,
        started_ts=started_ts,
        completed_ts=completed_ts,
        plugin=args.plugin,
        channel_id=args.channel_id,
        trigger=args.trigger,
    )

    if args.format == "json":
        print(json.dumps({
            "BODY": body,
            "EXPECTED_SECONDS": expected_seconds,
            "DURATION_SECONDS": duration_seconds,
            "LANG": _normalize_lang(args.lang),
            "KIND": args.kind,
        }, ensure_ascii=False))
        return 0
    # Shell format: BODY uses base64 to keep newlines/quotes intact when the
    # daemon eval's the output. Daemon decodes via `base64 -d`.
    import base64
    encoded = base64.b64encode(body.encode("utf-8")).decode("ascii")
    print(f"PRECOMPACT_BODY_B64={json.dumps(encoded)}")
    print(f"PRECOMPACT_EXPECTED_SECONDS={json.dumps(str(expected_seconds))}")
    print(f"PRECOMPACT_DURATION_SECONDS={json.dumps(str(duration_seconds))}")
    print(f"PRECOMPACT_LANG={json.dumps(_normalize_lang(args.lang))}")
    print(f"PRECOMPACT_KIND={json.dumps(args.kind)}")
    return 0


def cmd_record_precompact_completion(args: argparse.Namespace) -> int:
    """Record a started/completed pair into precompact-stats.json.

    Called by the daemon after pairing markers. Emits the post-update
    `expected_seconds` so the daemon can include it in the followup audit
    row without re-reading the stats file.
    """
    state_dir = Path(args.bridge_state_dir).expanduser()
    try:
        started_ts = int(args.started_ts)
        completed_ts = int(args.completed_ts)
    except (TypeError, ValueError):
        return 2
    if completed_ts < started_ts:
        completed_ts = started_ts
    alpha = _coerce_alpha(args.alpha if args.alpha not in (None, "") else os.environ.get("BRIDGE_PRECOMPACT_EMA_ALPHA"))
    payload = _record_completion_stats(
        state_dir=state_dir,
        agent=args.agent,
        trigger=args.trigger or "",
        started_ts=started_ts,
        completed_ts=completed_ts,
        alpha=alpha,
    )
    expected = _expected_seconds(payload, args.agent)
    duration = max(0, completed_ts - started_ts)
    if args.format == "json":
        print(json.dumps({
            "DURATION_SECONDS": duration,
            "EXPECTED_SECONDS": expected,
            "ALPHA": alpha,
        }, ensure_ascii=False))
        return 0
    print(f"PRECOMPACT_STATS_DURATION_SECONDS={json.dumps(str(duration))}")
    print(f"PRECOMPACT_STATS_EXPECTED_SECONDS={json.dumps(str(expected))}")
    print(f"PRECOMPACT_STATS_ALPHA={json.dumps(str(alpha))}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-channels.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    ensure_parser = subparsers.add_parser("ensure-webhook-server")
    add_common_args(ensure_parser)
    ensure_parser.set_defaults(handler=cmd_ensure_webhook_server)

    status_parser = subparsers.add_parser("status-webhook-server")
    add_common_args(status_parser)
    status_parser.set_defaults(handler=cmd_status_webhook_server)

    remove_parser = subparsers.add_parser("remove-webhook-server")
    add_common_args(remove_parser)
    remove_parser.set_defaults(handler=cmd_remove_webhook_server)

    route_parser = subparsers.add_parser("route-precompact-target")
    route_parser.add_argument("--agent", required=True)
    route_parser.add_argument("--channels-csv", required=True)
    route_parser.add_argument("--bridge-state-dir", required=True)
    route_parser.add_argument("--recency-seconds", default="1800")
    route_parser.add_argument("--now-ts", default="")
    route_parser.add_argument("--format", choices=("shell", "json"), default="shell")
    route_parser.set_defaults(handler=cmd_route_precompact_target)

    # Issue #597 Track B: managed-message send + render + completion-stats subcommands.
    send_parser = subparsers.add_parser("send-managed-message")
    send_parser.add_argument("--plugin", required=True)
    send_parser.add_argument("--agent", required=True)
    send_parser.add_argument("--channel-id", required=True)
    send_parser.add_argument("--reply-to-message-id", default="")
    send_parser.add_argument("--body", required=True)
    send_parser.add_argument("--kind", default="notice", choices=("notice", "followup"))
    send_parser.add_argument("--bridge-home", required=True)
    send_parser.add_argument("--bridge-state-dir", required=True)
    # Canonical `<workdir>/.<plugin>` state dir resolved in bash by
    # bridge_agent_<plugin>_state_dir (honors iso-v2 / BRIDGE_AGENT_WORKDIR-map /
    # BRIDGE_DATA_ROOT precedence). Every managed-send adapter reads its
    # credentials/state from here instead of re-deriving the workdir in Python
    # (#2005 generalizes #1996's teams-only thread to discord/telegram/teams).
    # `--teams-state-dir` is kept as a back-compat alias for the (unshipped)
    # #1996 flag name. Both map to the same dest.
    send_parser.add_argument(
        "--plugin-state-dir", "--teams-state-dir", dest="plugin_state_dir", default=""
    )
    send_parser.add_argument("--correlation-id", default="")
    send_parser.add_argument("--format", choices=("shell", "json"), default="shell")
    send_parser.add_argument("--dry-run", action="store_true")
    send_parser.set_defaults(handler=cmd_send_managed_message)

    render_parser = subparsers.add_parser("render-precompact-message")
    render_parser.add_argument("--agent", required=True)
    render_parser.add_argument("--kind", required=True, choices=("notice", "followup"))
    render_parser.add_argument("--lang", default="en")
    render_parser.add_argument("--plugin", default="")
    render_parser.add_argument("--channel-id", default="")
    render_parser.add_argument("--trigger", default="")
    render_parser.add_argument("--expected-seconds", default="")
    render_parser.add_argument("--duration-seconds", default="")
    render_parser.add_argument("--started-ts", default="")
    render_parser.add_argument("--completed-ts", default="")
    render_parser.add_argument("--bridge-state-dir", required=True)
    render_parser.add_argument("--read-stats", action="store_true")
    render_parser.add_argument("--format", choices=("shell", "json"), default="shell")
    render_parser.set_defaults(handler=cmd_render_precompact_message)

    record_parser = subparsers.add_parser("record-precompact-completion")
    record_parser.add_argument("--agent", required=True)
    record_parser.add_argument("--trigger", default="auto")
    record_parser.add_argument("--started-ts", required=True)
    record_parser.add_argument("--completed-ts", required=True)
    record_parser.add_argument("--alpha", default="")
    record_parser.add_argument("--bridge-state-dir", required=True)
    record_parser.add_argument("--format", choices=("shell", "json"), default="shell")
    record_parser.set_defaults(handler=cmd_record_precompact_completion)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
