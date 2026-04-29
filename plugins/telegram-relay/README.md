# Telegram Relay Channel

`plugin:telegram-relay@agent-bridge` is the opt-in Telegram channel client for
the Agent Bridge polling relay daemon.

The official Telegram plugin owns a Telegram `getUpdates` polling stream inside
each Claude session. Running a second session with the same token can replace
or terminate the first poller. This plugin removes that single-consumer race:
Claude sessions connect to the Agent Bridge relay over a Unix socket while the
daemon owns the Telegram polling stream.

## Runtime Files

By default the plugin reads:

```text
~/.claude/channels/telegram/.env
~/.claude/channels/telegram/access.json
```

When Agent Bridge starts an agent, it sets `TELEGRAM_STATE_DIR` to the
agent-local directory, for example:

```text
~/.agent-bridge/agents/patch/.telegram
```

The `.env` file must contain:

```dotenv
TELEGRAM_BOT_TOKEN=<telegram-bot-token>
```

The relay daemon itself expects a raw token file, not dotenv syntax. Setup
writes a protected `relay-token` file next to `.env`, registers that path in
`~/.agent-bridge/state/channels/telegram/tokens.list`, and enables daemon
supervision. The token value is never placed on argv.

## Opt-In Steps

1. Configure the Telegram state and opt into relay supervision:

   ```bash
   agent-bridge setup telegram patch \
     --token "<telegram-bot-token>" \
     --allow-from "<telegram-user-id>" \
     --default-chat "<telegram-chat-id>" \
     --use-relay \
     --yes
   ```

2. Restart or sync the bridge daemon. Setup already writes `.env`,
   `access.json`, `.telegram/relay-token`, `tokens.list`, the
   `plugin:telegram-relay@agent-bridge` channel registration, and
   `BRIDGE_TELEGRAM_RELAY_ENABLED=1`.

   ```bash
   bash bridge-daemon.sh sync
   agent-bridge status --json
   ```

## Tools

The plugin registers the Telegram channel tool names expected by Claude
sessions:

- `reply`: supported. Sends text through daemon `send_message`. Accepts
  `chat_id`, `text`, and optional `reply_to`.
- `react`: registered for tool-surface compatibility; not supported until the
  relay daemon grows a reaction RPC.
- `download_attachment`: registered for tool-surface compatibility; not
  supported until the relay daemon grows a file-download RPC.
- `edit_message`: registered for tool-surface compatibility; not supported
  until the relay daemon grows an edit-message RPC.

Incoming Telegram messages arrive as Claude channel notifications and can also
be dispatched through `agent-bridge urgent` when `TELEGRAM_RELAY_DISPATCH` is
`urgent` or `both`.

## Environment

```dotenv
TELEGRAM_STATE_DIR=/path/to/.telegram
BRIDGE_HOME=~/.agent-bridge
BRIDGE_STATE_DIR=~/.agent-bridge/state
BRIDGE_TELEGRAM_RELAY_ENABLED=1
BRIDGE_TELEGRAM_RELAY_AUTOSPAWN=1
TELEGRAM_RELAY_REGISTER_TOKEN=1
TELEGRAM_RELAY_DISPATCH=mcp
TELEGRAM_RELAY_AGENT=<agent-name>
TELEGRAM_RELAY_BOT_USERNAME=<bot-username>
```

`TELEGRAM_RELAY_DISPATCH` values:

- `mcp`: send Claude channel notifications only. This is the default.
- `urgent`: call `agent-bridge urgent <agent> <message>`.
- `both`: do both.

## Current Scope

This is Phase 2 for issue #475: plugin client adapter, operator docs, and smoke
coverage. Phase 3 will automate `bridge-setup.py telegram` lifecycle wiring and
status liveness display.
