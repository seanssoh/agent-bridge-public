#!/usr/bin/env python3
"""Send short Agent Bridge notifications over Discord, Discord webhooks, or Telegram."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from bridge_guard_common import prompt_guard_enabled, sanitize_text

HOOKS_DIR = Path(__file__).resolve().parent / "hooks"
if str(HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(HOOKS_DIR))

from bridge_hook_common import write_audit


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_text_file(path: str | None) -> str:
    if not path:
        return ""
    return Path(path).read_text(encoding="utf-8").strip()


def load_account_config(config_path: Path, kind: str, account: str) -> dict[str, Any]:
    payload = load_json(config_path)
    channels = payload.get("channels") or {}
    channel_cfg = channels.get(kind) or {}
    accounts = channel_cfg.get("accounts") or {}
    account_cfg = accounts.get(account)
    if not isinstance(account_cfg, dict):
        raise SystemExit(f"{kind} account not found: {account}")
    return account_cfg


def load_account_token(account_cfg: dict[str, Any]) -> str:
    token = str(account_cfg.get("token") or "").strip()
    if token:
        return token
    token_file = str(account_cfg.get("tokenFile") or "").strip()
    if token_file:
        token = load_text_file(token_file)
        if token:
            return token
    raise SystemExit("channel account token is missing")


def load_account_api_base(account_cfg: dict[str, Any], default: str) -> str:
    for key in ("apiBaseUrl", "api_base_url", "api_base"):
        value = str(account_cfg.get(key) or "").strip()
        if value:
            return value.rstrip("/")
    return default.rstrip("/")


def normalize_target(kind: str, target: str) -> str:
    value = str(target).strip()
    if kind == "telegram" and value.startswith("agent:"):
        return value.rsplit(":", 1)[-1]
    return value


def build_message(title: str, message: str, task_id: str, priority: str) -> str:
    title = title.strip()
    message = message.strip()
    task_id = str(task_id or "").strip()
    priority = str(priority or "").strip()

    header = "[Agent Bridge]"
    if priority and priority != "normal":
        header += f" {priority}"
    if task_id:
        header += f" task #{task_id}"
    if title:
        header += f": {title}"

    parts = [header]
    if message:
        parts.append(message)
    return "\n".join(parts)


def send_discord(token: str, channel_id: str, text: str, api_base_url: str) -> None:
    payload = json.dumps({"content": text}).encode("utf-8")
    req = Request(
        f"{api_base_url.rstrip('/')}/channels/{channel_id}/messages",
        data=payload,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def send_discord_webhook(webhook_url: str, text: str, username: str) -> None:
    payload: dict[str, Any] = {"content": text}
    if username:
        payload["username"] = username
    req = Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def send_telegram(token: str, chat_id: str, text: str, api_base_url: str) -> None:
    payload = urlencode(
        {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": "true",
        }
    ).encode("utf-8")
    req = Request(
        f"{api_base_url.rstrip('/')}/bot{token}/sendMessage",
        data=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def send_mattermost(token: str, channel_id: str, text: str, api_base_url: str) -> None:
    payload = json.dumps({"channel_id": channel_id, "message": text}).encode("utf-8")
    req = Request(
        f"{api_base_url.rstrip('/')}/api/v4/posts",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def cmd_send(args: argparse.Namespace) -> int:
    kind = str(args.kind).strip()
    target = normalize_target(kind, args.target)
    account = str(args.account or "default").strip()
    text = build_message(args.title or "", args.message or "", args.task_id or "", args.priority or "normal")

    if prompt_guard_enabled():
        sanitized = sanitize_text(text, surface="output", agent=str(args.agent or "").strip())
        if sanitized.blocked:
            write_audit(
                "prompt_guard_canary_triggered" if sanitized.canary_triggered else "prompt_guard_blocked",
                str(args.agent or "bridge"),
                {
                    "surface": "output",
                    "kind": kind,
                    "target": target,
                    "canary_tokens": sanitized.canary_tokens,
                },
            )
            text = "[Agent Bridge] outbound message blocked by prompt guard."
        elif sanitized.was_modified:
            write_audit(
                "prompt_guard_sanitized",
                str(args.agent or "bridge"),
                {
                    "surface": "output",
                    "kind": kind,
                    "target": target,
                    "redacted_types": sanitized.redacted_types,
                    "redaction_count": sanitized.redaction_count,
                },
            )
            text = sanitized.sanitized_text

    payload = {
        "agent": args.agent,
        "kind": kind,
        "target": target,
        "account": account,
        "text": text,
    }

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if not args.runtime_config:
        raise SystemExit("--runtime-config is required")
    try:
        if kind == "discord":
            account_cfg = load_account_config(Path(args.runtime_config), kind, account)
            token = load_account_token(account_cfg)
            api_base_url = load_account_api_base(account_cfg, "https://discord.com/api/v10")
            send_discord(token, target, text, api_base_url)
        elif kind == "discord-webhook":
            send_discord_webhook(target, text, args.agent or "Agent Bridge")
        elif kind == "telegram":
            account_cfg = load_account_config(Path(args.runtime_config), kind, account)
            token = load_account_token(account_cfg)
            api_base_url = load_account_api_base(account_cfg, "https://api.telegram.org")
            send_telegram(token, target, text, api_base_url)
        elif kind == "mattermost":
            account_cfg = load_account_config(Path(args.runtime_config), kind, account)
            token = load_account_token(account_cfg)
            api_base_url = load_account_api_base(account_cfg, "http://localhost:8065")
            send_mattermost(token, target, text, api_base_url)
        else:
            raise SystemExit(f"unsupported notify kind: {kind}")
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"{kind} notify failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SystemExit(f"{kind} notify failed: {exc.reason}") from exc

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-notify.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    send_parser = subparsers.add_parser("send")
    send_parser.add_argument("--agent")
    send_parser.add_argument("--kind", required=True, choices=("discord", "discord-webhook", "telegram", "mattermost"))
    send_parser.add_argument("--target", required=True)
    send_parser.add_argument("--account", default="default")
    send_parser.add_argument("--runtime-config")
    send_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    send_parser.add_argument("--title")
    send_parser.add_argument("--message")
    send_parser.add_argument("--task-id")
    send_parser.add_argument("--priority", default="normal")
    send_parser.add_argument("--dry-run", action="store_true")
    send_parser.set_defaults(handler=cmd_send)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
