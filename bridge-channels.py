#!/usr/bin/env python3
"""Manage Claude Code .mcp.json webhook channel entries for Agent Bridge."""

from __future__ import annotations

import argparse
import json
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
    if removed:
        save_json(mcp_path, payload)

    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": "removed" if removed else "absent",
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

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
