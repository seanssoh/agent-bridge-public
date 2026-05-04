# Microsoft Teams Channel

This Claude Code channel plugin connects a Teams bot to a Claude agent through Agent Bridge.

## Runtime Files

By default the plugin reads:

- `~/.claude/channels/teams/.env`
- `~/.claude/channels/teams/access.json`
- `~/.claude/channels/teams/state.json`

When Agent Bridge starts an agent with `plugin:teams@agent-bridge`, it sets `TEAMS_STATE_DIR` to the agent-local directory, for example:

```bash
~/.agent-bridge/agents/patch/.teams
```

## Environment

```dotenv
TEAMS_APP_ID=<azure-bot-app-id>
TEAMS_APP_PASSWORD=<azure-bot-client-secret>
TEAMS_TENANT_ID=<azure-tenant-id>
TEAMS_WEBHOOK_HOST=0.0.0.0
TEAMS_WEBHOOK_PORT=3978
```

Expose `http://<host>:3978/api/messages` through HTTPS and set it as the Azure Bot Service messaging endpoint.
If you also use the `ms365` plugin, expose `http://<host>:3978/auth/callback` through the same listener and register that exact URL as the Entra redirect URI.

For the full operator guide, including ALB / nginx / iptables paths and setup validation, see [docs/channels/teams-setup.md](../../docs/channels/teams-setup.md).

## Tools

- `reply`: send a message back to a Teams conversation that has already passed access control.
- `fetch_messages`: read the local rolling message log captured by the plugin.

## Access

`access.json` is allowlist-first:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<aad-object-id-or-teams-user-id>"],
  "groups": {
    "<conversation-id-or-channel-id>": {
      "requireMention": true,
      "allowFrom": []
    }
  },
  "pending": {},
  "routes": {}
}
```

Agent Bridge writes this file through:

```bash
agb setup teams <agent> --app-id ... --app-password ... --tenant-id ... --allow-from ... --messaging-endpoint https://bot.example.com/api/messages --webhook-host 0.0.0.0
```

## Inbound Attachments

When a Teams user attaches a file or image, the plugin downloads each attachment to:

```
<TEAMS_STATE_DIR>/attachments/<message_id>/<filename>
```

(directory mode 0700, file mode 0600). The Claude channel notification meta gains an `attachments` array with `name`, `content_type`, `download_status` (`ok` / `skipped_non_file` / `failed`), and — on success — `local_path` and `size_bytes`. Cards and other non-file attachment kinds are recorded with `skipped_non_file` so the agent still sees the metadata.

Override the location and size cap via:

```dotenv
TEAMS_ATTACHMENTS_DIR=<absolute path>     # must be absolute and writable; otherwise default is used
TEAMS_ATTACHMENT_MAX_BYTES=52428800       # default: 50 MB; clamped to 1 GB; non-numeric falls back to default
```

Filenames and message ids are sanitized (strict allowlist) before they're joined into the on-disk path; downloads stream to disk with an in-flight byte counter so a server lying about `Content-Length` cannot bypass the cap.

Outbound attachments (sending files from the bot to Teams) are not yet implemented; track that work separately.

## Delivery Mode

By default, inbound Teams messages are delivered to Claude Code with `notifications/claude/channel`, and the server waits for the MCP stdio write before acknowledging the Teams webhook. If the MCP write fails, the webhook returns an error so Teams can retry.

Legacy `TEAMS_BRIDGE_MODE` / `TEAMS_BRIDGE_AGENT` settings are ignored. Teams inbound delivery must not create Agent Bridge queue tasks; it should enter the active Claude Code session as a channel message. Accepted messages are written to the local log only after Claude Code accepts the channel notification, so Teams webhook retries can still recover from delivery failures without duplicating already delivered messages.

## Current Scope

This is the Phase 1 channel implementation: webhook receive, access gate, Claude channel notification, reply, local message fetch, and a lightweight `/auth/callback` endpoint used by the `ms365` plugin authorization-code pairing flow. Multi-tenant user-to-agent routing is intentionally left to the Agent Bridge relay layer so one Teams bot can map many users to many timeout agents without mixing conversation state.

If `BRIDGE_PROMPT_GUARD_ENABLED=1` is set in the agent runtime, Teams inbound text is scanned before it reaches Claude and outbound `reply` text is sanitized before send.
