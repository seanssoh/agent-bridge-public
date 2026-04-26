# Mattermost Channel

This Claude Code channel plugin connects a self-hosted Mattermost instance to a Claude agent through Agent Bridge.

## Runtime Files

By default the plugin reads:

- `~/.claude/channels/mattermost/.env`
- `~/.claude/channels/mattermost/access.json`

When Agent Bridge starts an agent with `plugin:mattermost@agent-bridge`, it sets `MATTERMOST_STATE_DIR` to the agent-local directory, for example:

```bash
~/.agent-bridge/agents/patch/.mattermost
```

## Environment

```dotenv
MATTERMOST_URL=https://mattermost.example.com
MATTERMOST_BOT_TOKEN=<bot-access-token>
MATTERMOST_OUTGOING_WEBHOOK_TOKEN=<outgoing-webhook-token>
MATTERMOST_WEBHOOK_HOST=0.0.0.0
MATTERMOST_WEBHOOK_PORT=3979
```

### Bot Account Setup

1. In Mattermost System Console, enable bot accounts: **System Console > Integrations > Bot Accounts > Enable Bot Account Creation**.
2. Go to **Integrations > Bot Accounts > Add Bot Account**.
3. Give it a username (e.g. `agent-bridge`) and role.
4. Copy the generated **Bot Access Token** — this is `MATTERMOST_BOT_TOKEN`.

### Outgoing Webhook Setup

1. Go to **Integrations > Outgoing Webhooks > Add Outgoing Webhook**.
2. Set the callback URL to `http://<host>:<port>/hooks/outgoing` (e.g. `http://localhost:3979/hooks/outgoing`).
3. Choose the channel(s) or trigger word(s) to listen on.
4. Copy the generated **Token** — this is `MATTERMOST_OUTGOING_WEBHOOK_TOKEN`.

## Tools

- `reply`: send a message back to a Mattermost channel that has already passed access control.
- `fetch_messages`: read the local rolling message log captured by the plugin.

## Access

`access.json` is allowlist-first:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<mattermost-user-id>"],
  "channels": {
    "<channel-id>": {
      "requireMention": true,
      "allowFrom": []
    }
  },
  "pending": {},
  "routes": {}
}
```

## Current Scope

This is the Phase 1 channel implementation: Outgoing Webhook receive, access gate, Claude channel notification, reply via Bot API, and local message fetch.

If `BRIDGE_PROMPT_GUARD_ENABLED=1` is set in the agent runtime, Mattermost inbound text is scanned before it reaches Claude and outbound `reply` text is sanitized before send.
