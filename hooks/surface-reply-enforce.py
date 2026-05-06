#!/usr/bin/env python3
"""Stop hook: enforce that channel-sourced user turns get a matching mcp reply.

Runs once at Stop. If the latest user turn carries
`<channel source="<surface>" chat_id="<id>" message_id="<id>" ...>` tags,
the assistant turn must invoke `mcp__plugin_<namespace>__reply` with a
matching chat_id, OR the assistant text must include an explicit
`<no-reply-needed source="<surface>" chat_id="<id>" reason="..." />`
marker. Otherwise emit `{"decision": "block", "reason": "..."}` so
Claude Code re-enters the turn and gives the agent a chance to send
the reply.

Issue #415 — textual rule from #342 kept regressing within 24h on the
originating agent. Stop hook is the runtime boundary that doesn't rely
on the LLM remembering the rule.

Issue #20739 (2026-05-05) — production channel tags arrive as
`source="plugin:<plugin_name>:<server_name>"` (e.g. "plugin:discord:discord")
and reply tools are exposed as `mcp__plugin_<plugin>_<server>__reply`
(e.g. `mcp__plugin_discord_discord__reply`). The previous
`SUPPORTED_SURFACES = ("discord", ...)` membership check rejected the
prefixed form, so the hook silent-passed every channel-sourced turn for
roughly 30 days. `_parse_source` now normalizes both shapes.
"""
from __future__ import annotations

import json
import os
import re
import sys


# Surface short-names we enforce. Each maps to the mcp reply tool name.
# Keep this list aligned with the plugins that ship a `*__reply` tool
# (discord/telegram/teams). ms365 plugin uses a different reply shape
# (email-send) and is not enforced here.
SUPPORTED_SURFACES = ("discord", "telegram", "teams")

CHANNEL_TAG_RE = re.compile(
    r'<channel\s+source="([^"]+)"\s+chat_id="([^"]+)"\s+message_id="([^"]+)"',
    re.IGNORECASE,
)
NO_REPLY_MARKER_RE = re.compile(
    r'<no-reply-needed\s+source="([^"]+)"\s+chat_id="([^"]+)"',
    re.IGNORECASE,
)


def _parse_source(raw: str):
    """Parse a channel-tag source string → (surface, mcp_namespace).

    Accepts both the legacy short form and the current MCP plugin form:

    - "discord"                 → ("discord", "discord")
    - "plugin:discord:discord"  → ("discord", "discord_discord")
    - "plugin:telegram:telegram"→ ("telegram", "telegram_telegram")
    - "plugin:foo"   (2 segs)   → ("foo", "foo")
    - any other shape           → None

    `surface` is the membership key for SUPPORTED_SURFACES; `mcp_namespace`
    is the segment that goes into f"mcp__plugin_{namespace}__reply".
    """
    if not raw:
        return None
    s = raw.lower()
    if s.startswith("plugin:"):
        parts = s.split(":")
        if len(parts) == 3:
            return parts[1], f"{parts[1]}_{parts[2]}"
        if len(parts) == 2:
            return parts[1], parts[1]
        return None
    return s, s


def load_event() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _read_transcript(path: str) -> list[dict]:
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            entries: list[dict] = []
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
            return entries
    except OSError:
        return []


def _extract_text(message_content) -> str:
    if isinstance(message_content, str):
        return message_content
    if isinstance(message_content, list):
        text = ""
        for part in message_content:
            if isinstance(part, dict) and part.get("type") == "text":
                text += str(part.get("text") or "")
        return text
    return ""


def _latest_pending_channel_input(entries: list[dict]):
    """Walk entries in reverse and return
    (raw_source, surface, namespace, chat_id, message_id, index) for the
    most recent user turn carrying a supported channel tag. Returns None
    if the latest user turn isn't channel-sourced (matches existing
    contract: enforcement applies only when the most recent user turn is
    channel-bound)."""
    for idx in range(len(entries) - 1, -1, -1):
        entry = entries[idx]
        if entry.get("type") != "user":
            continue
        text = _extract_text((entry.get("message") or {}).get("content"))
        match = CHANNEL_TAG_RE.search(text)
        if match:
            raw_source = match.group(1)
            parsed = _parse_source(raw_source)
            if parsed is not None:
                surface, namespace = parsed
                if surface in SUPPORTED_SURFACES:
                    return (
                        raw_source.lower(),
                        surface,
                        namespace,
                        match.group(2),
                        match.group(3),
                        idx,
                    )
        # No supported channel tag on this user turn -> stop walking; we
        # only enforce when the latest user turn was channel-sourced.
        return None
    return None


def _assistant_replies_for_surface(
    entries: list[dict],
    raw_source: str,
    surface: str,
    namespace: str,
    chat_id: str,
    user_idx: int,
) -> bool:
    """Walk forward from the latest channel-source user turn (anchored at
    `user_idx`); return True when an assistant tool_use of
    mcp__plugin_<namespace>__reply with matching chat_id is found, OR when
    an explicit <no-reply-needed source=.. chat_id=..> marker appears in
    the assistant text.

    Marker matching accepts two `source` forms:
      1. exact `raw_source` (e.g. "plugin:discord:discord") — preferred
      2. legacy short surface ("discord", "telegram", "teams") for
         backward compatibility.

    Anything else in the marker source field is rejected to avoid
    accepting unrelated `plugin:<x>:<y>` variants.
    """
    expected_tool = f"mcp__plugin_{namespace}__reply"
    for entry in entries[user_idx + 1:]:
        if entry.get("type") != "assistant":
            continue
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict):
                continue
            ptype = part.get("type")
            if ptype == "tool_use" and part.get("name") == expected_tool:
                tool_input = part.get("input") or {}
                cand = tool_input.get("chat_id")
                if cand is None:
                    cand = tool_input.get("chatId")
                if str(cand or "") == str(chat_id):
                    return True
            if ptype == "text":
                text = str(part.get("text") or "")
                for nm in NO_REPLY_MARKER_RE.finditer(text):
                    nm_source = nm.group(1).lower()
                    nm_chat = nm.group(2)
                    if nm_chat != chat_id:
                        continue
                    if nm_source == raw_source or nm_source == surface:
                        return True
    return False


def main() -> int:
    event = load_event()
    if not event:
        return 0

    # Re-entry guard: if Stop hook is already active for this turn,
    # don't re-block (mirrors the existing check_inbox.py pattern).
    if event.get("stop_hook_active"):
        return 0

    # TUI-only / admin sessions: no BRIDGE_AGENT_ID -> not enforced.
    agent_id = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent_id:
        return 0

    transcript_path = str(event.get("transcript_path") or "")
    entries = _read_transcript(transcript_path)
    if not entries:
        return 0

    pending = _latest_pending_channel_input(entries)
    if pending is None:
        return 0

    raw_source, surface, namespace, chat_id, message_id, user_idx = pending
    if _assistant_replies_for_surface(
        entries, raw_source, surface, namespace, chat_id, user_idx,
    ):
        return 0

    expected_tool = f"mcp__plugin_{namespace}__reply"
    reason = (
        f"{raw_source} chat_id={chat_id} message_id={message_id} "
        f"입력에 대한 답변이 {expected_tool} 호출로 전송되지 않았습니다. "
        f"답변 본문 작성 후 reply tool 호출 후 다시 종료하세요. "
        f"(답변이 불필요하면 assistant text에 "
        f'<no-reply-needed source="{raw_source}" chat_id="{chat_id}" reason="..." /> 마커 추가)'
    )
    response = {"decision": "block", "reason": reason}
    sys.stdout.write(json.dumps(response, ensure_ascii=False))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
