# Telegram Relay Access Setup

The relay plugin uses the same agent-local state directory as the current
Telegram setup path:

```text
<agent-workdir>/.telegram/.env
<agent-workdir>/.telegram/access.json
```

Agent Bridge sets `TELEGRAM_STATE_DIR` for Claude sessions that launch with a
Telegram channel. The relay plugin reads credentials from `.env`, computes the
token hash locally, and then talks only to the Agent Bridge relay daemon over
the Unix socket.

## Access Model

`access.json` is allowlist-first:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["412587349"],
  "defaultChatId": "412587349",
  "groups": {
    "-1001654782309": {
      "requireMention": true,
      "allowFrom": []
    }
  },
  "pending": {}
}
```

Fields:

- `dmPolicy`: `allowlist`, `open`, or `disabled`. `allowlist` is recommended.
- `allowFrom`: Telegram numeric user IDs allowed to DM the bot.
- `defaultChatId`: optional stable chat id for setup tests and operator notes.
- `groups`: Telegram group or supergroup chat IDs where the bot is active.
- `groups.<id>.requireMention`: when true, only mentions, configured mention
  patterns, or replies to the bot wake the agent.
- `groups.<id>.allowFrom`: optional sender allowlist inside that group. Empty
  means any sender can trigger the group route, subject to mention policy.

## Setup

```bash
agent-bridge setup telegram patch \
  --token "<telegram-bot-token>" \
  --allow-from "412587349" \
  --default-chat "412587349" \
  --yes
```

To enable the relay plugin for that agent, change the channel registration to:

```text
plugin:telegram-relay@agent-bridge
```

Until Phase 3 automates relay lifecycle wiring, also ensure the daemon is
enabled and the token hash is registered:

```bash
export BRIDGE_TELEGRAM_RELAY_ENABLED=1
python3 lib/telegram-relay.py token-hash --token-file ~/.agent-bridge/agents/patch/.telegram/relay-token
```

The plugin writes `.telegram/relay-token` with mode `0600` from the dotenv
token because the daemon expects a raw token file. It can register that file
automatically when
`TELEGRAM_RELAY_REGISTER_TOKEN=1` is set, which is the default. If the relay is
not already running, set `BRIDGE_TELEGRAM_RELAY_AUTOSPAWN=1` to let the plugin
start it through `agent-bridge telegram-relay start --token-file <path>`.

## Security Notes

- The bot token is never passed on argv. The plugin reads `.env`; the daemon
  reads the plugin-created raw `relay-token` file.
- Outbound `reply` calls go through daemon `send_message`; the plugin does not
  call Telegram HTTP APIs directly.
- Incoming text is gated by `access.json` before it is forwarded to Claude or
  to `agent-bridge urgent`.
- If `BRIDGE_PROMPT_GUARD_ENABLED=1`, inbound text is scanned before dispatch
  and outbound `reply` text is sanitized before send.
