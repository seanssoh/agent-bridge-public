#!/usr/bin/env python3
"""Lightweight Discord -> Agent Bridge wake relay for on-demand agents."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


# Discord snowflakes encode milliseconds since 2015-01-01T00:00:00Z in the
# upper 42 bits. Used as the canonical inbound timestamp for activity
# index entries — derived directly from the message id, no separate API
# call required.
_DISCORD_EPOCH_MS = 1420070400000


def _snowflake_to_ms(snowflake: str | int | None) -> int:
    """Decode a Discord snowflake into epoch milliseconds.

    Returns 0 if the value cannot be parsed.
    """
    if snowflake is None:
        return 0
    try:
        as_int = int(str(snowflake))
    except (TypeError, ValueError):
        return 0
    if as_int <= 0:
        return 0
    return (as_int >> 22) + _DISCORD_EPOCH_MS


def _record_user_inbound_activity(
    state_dir: Path | None,
    agent: str,
    channel_id: str,
    message: dict[str, Any],
    now_ts: int,
    *,
    reply_kind: str = "message",
    thread_id: str | None = None,
) -> None:
    """Write a normalized inbound entry into the precompact activity index.

    Schema is the one produced/consumed by issue #597 Track A:
    `$BRIDGE_STATE_DIR/channels/discord/<agent>.json`.

    Writes are best-effort; any error is swallowed so a malformed state
    dir or filesystem hiccup never breaks the wake relay.
    """
    if not state_dir or not agent or not channel_id or not isinstance(message, dict):
        return
    message_id = message.get("id")
    if not message_id:
        return
    author = message.get("author") or {}
    if author.get("bot"):
        # Defensive — caller already filters human messages, but never
        # poison the index with a bot-self echo.
        return
    user_id = str(author.get("id") or "")
    inbound_ms = _snowflake_to_ms(message_id)
    if inbound_ms <= 0:
        inbound_ms = int(now_ts) * 1000
    inbound_ts = inbound_ms // 1000
    try:
        recorded_ns = time.time_ns()
    except AttributeError:  # pragma: no cover — Python <3.7
        recorded_ns = int(time.time() * 1_000_000_000)

    target = state_dir / "channels" / "discord" / f"{agent}.json"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        lock_path = target.with_name(target.name + ".lock")
        with lock_path.open("a") as lock_handle:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
                payload: dict[str, Any] = {}
                if target.exists():
                    try:
                        with target.open("r", encoding="utf-8") as handle:
                            existing = json.load(handle)
                        if isinstance(existing, dict):
                            payload = existing
                    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
                        payload = {}
                payload["schema_version"] = 1
                payload["agent"] = agent
                payload["plugin"] = "discord"
                payload["updated_ts"] = int(now_ts)
                channels_map = payload.get("channels")
                if not isinstance(channels_map, dict):
                    channels_map = {}
                entry = channels_map.get(channel_id)
                if not isinstance(entry, dict):
                    entry = {}
                entry["channel_id"] = channel_id
                entry["reply_kind"] = reply_kind
                entry["last_seen_id"] = str(message_id)
                entry["last_seen_ts"] = int(now_ts)
                entry["last_user_inbound_ts"] = int(inbound_ts)
                entry["last_user_inbound_ts_ms"] = int(inbound_ms)
                entry["last_user_inbound_message_id"] = str(message_id)
                if user_id:
                    entry["last_user_inbound_user_id"] = user_id
                entry["last_user_inbound_recorded_ns"] = int(recorded_ns)
                if thread_id:
                    entry["thread_id"] = str(thread_id)
                channels_map[channel_id] = entry
                payload["channels"] = channels_map

                tmp = tempfile.NamedTemporaryFile(
                    mode="w",
                    encoding="utf-8",
                    dir=str(target.parent),
                    prefix=f".{target.name}.",
                    suffix=".tmp",
                    delete=False,
                )
                try:
                    json.dump(payload, tmp, ensure_ascii=False, indent=2)
                    tmp.write("\n")
                    tmp.flush()
                    os.fsync(tmp.fileno())
                finally:
                    tmp.close()
                os.chmod(tmp.name, 0o600)
                os.replace(tmp.name, target)
            finally:
                try:
                    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
    except OSError:
        # Activity index is advisory — never break the relay on write
        # failures.
        return


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def load_token(runtime_config: Path, relay_account: str) -> str:
    token = load_optional_token(runtime_config, relay_account)
    if not token:
        raise SystemExit(f"discord relay token not found for account '{relay_account}'")
    return token


def load_optional_token(runtime_config: Path, relay_account: str) -> str:
    payload = load_json(runtime_config, {})
    token = (
        (((payload.get("channels") or {}).get("discord") or {}).get("accounts") or {})
        .get(relay_account, {})
        .get("token")
    )
    return str(token or "")


def read_snapshot(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("agent\tchannel_id\t"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                print(f"[discord-relay] malformed snapshot row fields={len(parts)} raw={line!r}", file=sys.stderr)
                continue
            if len(parts) == 4:
                agent, channel_id, active, idle_timeout = parts
                session = ""
            else:
                agent, channel_id, active, idle_timeout = parts[:4]
                session = "\t".join(parts[4:])
            try:
                idle_timeout_value = int(idle_timeout)
            except ValueError:
                print(f"[discord-relay] malformed idle_timeout raw={line!r}", file=sys.stderr)
                continue
            if not agent or not channel_id:
                print(f"[discord-relay] malformed snapshot row missing agent/channel raw={line!r}", file=sys.stderr)
                continue
            rows.append(
                {
                    "agent": agent,
                    "channel_id": channel_id,
                    "active": active == "1",
                    "idle_timeout": idle_timeout_value,
                    "session": session,
                }
            )
    return rows


def snowflake_int(value: str | int | None) -> int:
    if value is None:
        return 0
    return int(str(value))


def open_dm_channel(token: str, recipient_id: str) -> str | None:
    """POST /users/@me/channels to open/get a DM channel with a user."""
    payload = json.dumps({"recipient_id": recipient_id}).encode("utf-8")
    req = Request(
        "https://discord.com/api/v10/users/@me/channels",
        data=payload,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-relay/0.1",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
            return str(data.get("id") or "")
    except (HTTPError, URLError):
        return None


def load_dm_allowlist(agent_home_root: str, agent: str) -> list[str]:
    """Read allowFrom user IDs from agent's .discord/access.json."""
    access_path = Path(agent_home_root) / agent / ".discord" / "access.json"
    if not access_path.exists():
        return []
    try:
        data = json.loads(access_path.read_text(encoding="utf-8"))
        return [str(uid) for uid in (data.get("allowFrom") or []) if uid]
    except Exception:
        return []


def load_registered_agents(bridge_home: Path) -> set[str] | None:
    cmd = [str(bridge_home / "agent-bridge"), "agent", "list", "--json"]
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as err:
        print(f"[discord-relay] failed to load registered agents: {err}", file=sys.stderr)
        return None

    try:
        payload = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as err:
        print(f"[discord-relay] failed to decode registered agents: {err}", file=sys.stderr)
        return None

    agents = {str(item.get("agent")) for item in payload if item.get("agent")}
    return agents or None


def note_relay_issue(state: dict[str, Any], now_ts: int, reason: str, detail: str = "") -> None:
    state["last_suppressed_ts"] = now_ts
    state["last_suppressed_reason"] = reason
    state["last_error_ts"] = now_ts
    if detail:
        state["last_error"] = detail[:500]


def fetch_channel_messages(token: str, channel_id: str, limit: int) -> list[dict[str, Any]]:
    query = urlencode({"limit": str(limit)})
    url = f"https://discord.com/api/v10/channels/{channel_id}/messages?{query}"
    req = Request(
        url,
        headers={
            "Authorization": f"Bot {token}",
            "User-Agent": "agent-bridge-discord-relay/0.1",
        },
        method="GET",
    )

    for attempt in range(2):
        try:
            with urlopen(req, timeout=15) as response:
                payload = response.read().decode("utf-8")
                data = json.loads(payload)
                if isinstance(data, list):
                    return data
                return []
        except HTTPError as err:
            if err.code == 429 and attempt == 0:
                try:
                    retry_payload = json.loads(err.read().decode("utf-8"))
                    retry_after = float(retry_payload.get("retry_after", 1.0))
                except Exception:
                    retry_after = 1.0
                time.sleep(min(max(retry_after, 0.5), 5.0))
                continue
            raise
        except URLError:
            if attempt == 0:
                time.sleep(1.0)
                continue
            raise

    return []


def display_name(message: dict[str, Any]) -> str:
    author = message.get("author") or {}
    member = message.get("member") or {}
    return (
        member.get("nick")
        or author.get("global_name")
        or author.get("username")
        or author.get("id")
        or "unknown"
    )


def message_preview(message: dict[str, Any], limit: int = 180) -> str:
    content = " ".join((message.get("content") or "").split())
    attachments = message.get("attachments") or []
    if not content and attachments:
        names = [attachment.get("filename") for attachment in attachments if attachment.get("filename")]
        content = f"[attachments] {', '.join(names[:3])}"
    if not content:
        content = "[no text]"
    if len(content) > limit:
        return content[: limit - 3] + "..."
    return content


def enqueue_task(bridge_home: Path, agent: str, channel_id: str, messages: list[dict[str, Any]]) -> str:
    latest = messages[-1]
    latest_author = display_name(latest)
    latest_preview = message_preview(latest)
    title = f"[Discord] wake {agent} for channel {channel_id}"
    body = (
        f"Discord relay detected {len(messages)} new human message(s) in channel {channel_id} "
        f"while {agent} was offline.\n\n"
        f"Latest author: {latest_author}\n"
        f"Latest message id: {latest.get('id')}\n"
        f"Preview: {latest_preview}\n\n"
        f"Wake the session, reconnect Discord, and read the backlog directly in Discord. "
        f"This task is a wake signal, not a full message transport."
    )
    cmd = [
        str(bridge_home / "agent-bridge"),
        "task",
        "create",
        "--to",
        agent,
        "--from",
        "discord-relay",
        "--priority",
        "high",
        "--title",
        title,
        "--body",
        body,
    ]
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def tmux_session_active(session: str) -> bool:
    if not session:
        return False
    result = subprocess.run(
        ["tmux", "has-session", "-t", f"={session}"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def has_open_wake_task(bridge_home: Path, agent: str) -> bool:
    db_path = bridge_home / "state" / "tasks.db"
    if not db_path.exists():
        return False

    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            """
            SELECT 1
            FROM tasks
            WHERE assigned_to = ?
              AND created_by = 'discord-relay'
              AND status IN ('queued', 'claimed', 'blocked')
            LIMIT 1
            """,
            (agent,),
        ).fetchone()
    return row is not None


def cmd_sync(args: argparse.Namespace) -> int:
    snapshot = read_snapshot(Path(args.agent_snapshot))
    if not snapshot:
        return 0

    if not args.runtime_config:
        raise SystemExit("--runtime-config is required")
    bridge_home = Path(args.bridge_home)
    token = load_optional_token(Path(args.runtime_config), args.relay_account)
    state_path = Path(args.state_file)
    state = load_json(state_path, {"channels": {}})
    channels = state.setdefault("channels", {})
    dm_channels = state.setdefault("dm_channels", {})
    now_ts = int(time.time())
    # Activity index lives under $BRIDGE_STATE_DIR/channels/discord/. The
    # relay's --state-file is rooted in the same state dir; deriving from
    # its parent keeps the writer in sync with whatever isolated runtime
    # the operator points the relay at.
    activity_state_dir = state_path.parent
    registered_agents = load_registered_agents(bridge_home)

    try:
        if token:
            for row in snapshot:
                channel_id = row["channel_id"]
                channel_state = channels.setdefault(channel_id, {"agent": row["agent"]})
                channel_state["agent"] = row["agent"]

                try:
                    messages = fetch_channel_messages(token, channel_id, args.poll_limit)
                except HTTPError as err:
                    print(
                        f"[discord-relay] channel={channel_id} agent={row['agent']} http_error={err.code}",
                        file=sys.stderr,
                    )
                    continue
                except URLError as err:
                    print(
                        f"[discord-relay] channel={channel_id} agent={row['agent']} url_error={err.reason}",
                        file=sys.stderr,
                    )
                    continue

                if not messages:
                    continue

                messages.sort(key=lambda item: snowflake_int(item.get("id")))
                latest_id = str(messages[-1].get("id"))
                last_seen_id = channel_state.get("last_seen_id")

                if not last_seen_id:
                    channel_state["last_seen_id"] = latest_id
                    channel_state["seeded_at"] = now_ts
                    continue

                new_messages = [item for item in messages if snowflake_int(item.get("id")) > snowflake_int(last_seen_id)]
                if not new_messages:
                    continue

                channel_state["last_seen_id"] = latest_id
                channel_state["last_seen_ts"] = now_ts

                human_messages = [item for item in new_messages if not ((item.get("author") or {}).get("bot"))]

                # Mirror the most recent USER inbound into the precompact
                # activity index so the daemon's notify routing primitive
                # (issue #597 Track A) can find a reply target. Done before
                # the registered/live/cooldown skips so a recently-active
                # human inbound is still routable when the agent comes back
                # online.
                if human_messages:
                    _record_user_inbound_activity(
                        activity_state_dir,
                        row["agent"],
                        channel_id,
                        human_messages[-1],
                        now_ts,
                    )

                if registered_agents is not None and row["agent"] not in registered_agents:
                    note_relay_issue(channel_state, now_ts, "unknown_agent", row["agent"])
                    continue

                live_active = row["active"] or tmux_session_active(str(row.get("session") or ""))
                if live_active:
                    continue

                if not human_messages:
                    continue

                if has_open_wake_task(bridge_home, row["agent"]):
                    note_relay_issue(channel_state, now_ts, "open_wake_task")
                    continue

                last_enqueue_ts = int(channel_state.get("last_enqueue_ts") or 0)
                if args.cooldown_seconds > 0 and now_ts - last_enqueue_ts < args.cooldown_seconds:
                    note_relay_issue(channel_state, now_ts, "cooldown")
                    continue

                try:
                    output = enqueue_task(bridge_home, row["agent"], channel_id, human_messages)
                except (OSError, subprocess.CalledProcessError) as err:
                    detail = (getattr(err, "stderr", "") or getattr(err, "stdout", "") or str(err)).strip()
                    note_relay_issue(channel_state, now_ts, "enqueue_failed", detail)
                    print(
                        f"[discord-relay] channel={channel_id} agent={row['agent']} enqueue_failed "
                        f"detail={detail[:240]}",
                        file=sys.stderr,
                    )
                    continue

                channel_state["last_enqueue_ts"] = now_ts
                channel_state["last_enqueue_message_id"] = str(human_messages[-1].get("id"))
                channel_state["last_enqueue_preview"] = message_preview(human_messages[-1])
                print(
                    f"[discord-relay] enqueued agent={row['agent']} channel={channel_id} "
                    f"messages={len(human_messages)} :: {output}"
                )

        agent_home_root = bridge_home / "agents"

        if registered_agents is not None:
            stale_dm_keys = [key for key, value in dm_channels.items() if str((value or {}).get("agent") or "") not in registered_agents]
            for key in stale_dm_keys:
                dm_channels.pop(key, None)

        # Scan registered agents with .discord dirs — not just snapshot (which only has active agents)
        all_dm_agents: list[str] = []
        if agent_home_root.is_dir():
            for agent_dir in sorted(agent_home_root.iterdir()):
                if not agent_dir.is_dir() or agent_dir.name.startswith("."):
                    continue
                if registered_agents is not None and agent_dir.name not in registered_agents:
                    continue
                if (agent_dir / ".discord" / ".env").exists():
                    all_dm_agents.append(agent_dir.name)

        session_by_agent = {row["agent"]: row.get("session", "") for row in snapshot}

        for agent in all_dm_agents:
            allow_ids = load_dm_allowlist(str(agent_home_root), agent)
            if not allow_ids:
                continue

            agent_env_path = agent_home_root / agent / ".discord" / ".env"
            if not agent_env_path.exists():
                continue
            try:
                agent_token = agent_env_path.read_text(encoding="utf-8").split("=", 1)[1].strip()
            except Exception:
                continue

            for user_id in allow_ids:
                dm_key = f"dm:{agent}:{user_id}"
                dm_state = dm_channels.setdefault(dm_key, {"agent": agent, "user_id": user_id})

                if not dm_state.get("channel_id"):
                    ch_id = open_dm_channel(agent_token, user_id)
                    if not ch_id:
                        continue
                    dm_state["channel_id"] = ch_id

                channel_id = dm_state["channel_id"]
                try:
                    messages = fetch_channel_messages(agent_token, channel_id, args.poll_limit)
                except (HTTPError, URLError):
                    continue

                if not messages:
                    continue

                messages.sort(key=lambda item: snowflake_int(item.get("id")))
                latest_id = str(messages[-1].get("id"))
                last_seen_id = dm_state.get("last_seen_id")

                if not last_seen_id:
                    dm_state["last_seen_id"] = latest_id
                    dm_state["seeded_at"] = now_ts
                    new_messages = messages
                else:
                    new_messages = [item for item in messages if snowflake_int(item.get("id")) > snowflake_int(last_seen_id)]
                if not new_messages:
                    continue

                dm_state["last_seen_id"] = latest_id
                dm_state["last_seen_ts"] = now_ts

                human_messages = [item for item in new_messages if not ((item.get("author") or {}).get("bot"))]

                # Same activity-index mirror as the channel path above —
                # DM channels reuse the same $BRIDGE_STATE_DIR/channels
                # /discord/<agent>.json file, keyed by the platform DM
                # channel id.
                if human_messages:
                    _record_user_inbound_activity(
                        activity_state_dir,
                        agent,
                        channel_id,
                        human_messages[-1],
                        now_ts,
                    )

                session_name = session_by_agent.get(agent, agent)
                if tmux_session_active(session_name):
                    continue

                if not human_messages:
                    continue

                if has_open_wake_task(bridge_home, agent):
                    note_relay_issue(dm_state, now_ts, "open_wake_task")
                    continue

                try:
                    output = enqueue_task(bridge_home, agent, channel_id, human_messages)
                except (OSError, subprocess.CalledProcessError) as err:
                    detail = (getattr(err, "stderr", "") or getattr(err, "stdout", "") or str(err)).strip()
                    note_relay_issue(dm_state, now_ts, "enqueue_failed", detail)
                    print(
                        f"[discord-relay] dm_channel={channel_id} agent={agent} enqueue_failed "
                        f"detail={detail[:240]}",
                        file=sys.stderr,
                    )
                    continue

                dm_state["last_enqueue_ts"] = now_ts
                dm_state["last_enqueue_message_id"] = str(human_messages[-1].get("id"))
                dm_state["last_enqueue_preview"] = message_preview(human_messages[-1])
                print(
                    f"[discord-relay] DM enqueued agent={agent} user={user_id} "
                    f"messages={len(human_messages)} :: {output}"
                )
    finally:
        save_json(state_path, state)

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Discord wake relay for Agent Bridge on-demand agents")
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("--agent-snapshot", required=True)
    sync_parser.add_argument("--bridge-home", required=True)
    sync_parser.add_argument("--state-file", required=True)
    sync_parser.add_argument("--runtime-config")
    sync_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    sync_parser.add_argument("--relay-account", default="default")
    sync_parser.add_argument("--poll-limit", type=int, default=5)
    sync_parser.add_argument("--cooldown-seconds", type=int, default=60)
    sync_parser.set_defaults(handler=cmd_sync)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
