# Mattermost Channel

This plugin receives messages from a self-hosted Mattermost instance via Outgoing Webhooks and routes them to Agent Bridge agents. Agents respond using the [mattermost-mcp-server](https://github.com/mattermost/mattermost-plugin-agents) `create_post` tool.

## Architecture

```
Mattermost user → Outgoing Webhook
  → Plugin server (bridge mode, single port)
  → Bot mention routing (@sales-bot → sales_mun agent)
  → agb urgent <agent> (task queue)
  → Claude agent claims task
  → mattermost-mcp-server create_post → Mattermost
```

The plugin server runs as a standalone process (not inside Claude Code). Message reception and response use separate paths:

- **Inbound**: Outgoing Webhook → plugin server → `agb urgent`
- **Outbound**: Agent uses `mattermost-mcp-server` MCP tools (`create_post`, `read_channel`, etc.)

## Setup

### 1. Mattermost Bot Accounts

Create a bot account per agent in Mattermost System Console:

1. **System Console > Integrations > Bot Accounts > Enable Bot Account Creation**
2. **Integrations > Bot Accounts > Add Bot Account** for each agent
3. Copy each bot's **Access Token**

### 2. Outgoing Webhooks

Create one webhook per channel, all pointing to the same plugin server:

1. **Integrations > Outgoing Webhooks > Add Outgoing Webhook**
2. Callback URL: `http://<host>:3979/hooks/outgoing`
3. Select the channel to monitor
4. Repeat for each channel

For localhost development, enable internal connections:
**System Console > Environment > Developer > Allow untrusted internal connections**: `127.0.0.1 localhost`

### 3. MCP Server for Agents

Build and configure the official Mattermost MCP server:

```bash
git clone https://github.com/mattermost/mattermost-plugin-agents
cd mattermost-plugin-agents && make mcp-server
```

Add `.mcp.json` to each agent's workdir:

```json
{
  "mcpServers": {
    "mattermost": {
      "command": "/path/to/mattermost-mcp-server",
      "env": {
        "MM_SERVER_URL": "http://localhost:8065",
        "MM_ACCESS_TOKEN": "<bot-access-token>"
      }
    }
  }
}
```

### 4. Plugin Server (Bridge Mode)

Create a bot routes file (`bot-routes.json`):

```json
[
  {"username": "sales-bot", "token": "<token>", "agent": "sales_mun", "system_prompt": "You are a sales assistant."},
  {"username": "research-bot", "token": "<token>", "agent": "formulation_research", "system_prompt": "You are a formulation researcher."}
]
```

Start the plugin server:

```bash
MATTERMOST_BRIDGE_MODE=1 \
MATTERMOST_STANDALONE=1 \
MATTERMOST_BOT_ROUTES=bot-routes.json \
MATTERMOST_STATE_DIR=~/.agent-bridge/agents/<agent>/.mattermost \
MATTERMOST_OUTGOING_WEBHOOK_TOKEN= \
BRIDGE_HOME=~/.agent-bridge \
bun plugins/mattermost/server.ts
```

### 5. Agent Roster

Agents do not need channel plugin flags. Standard launch command is sufficient since MCP tools come from `.mcp.json`:

```bash
BRIDGE_AGENT_LAUNCH_CMD["sales_mun"]='claude --dangerously-skip-permissions'
```

## Runtime Files

Per-agent state directory (`~/.agent-bridge/agents/<agent>/.mattermost/`):

- `.env`: `MATTERMOST_URL`, `MATTERMOST_BOT_TOKEN`, `MATTERMOST_OUTGOING_WEBHOOK_TOKEN`
- `access.json`: user allowlists and channel policies
- `messages.jsonl`: local rolling message log

## Access

`access.json` is allowlist-first:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<mattermost-user-id>"],
  "channels": {
    "<channel-id>": {
      "requireMention": false,
      "allowFrom": []
    }
  }
}
```

## Environment Variables

| Variable | Description |
|---|---|
| `MATTERMOST_BRIDGE_MODE` | `1` to route messages via `agb urgent` |
| `MATTERMOST_STANDALONE` | `1` to enable standalone fallback (Claude API/CLI) |
| `MATTERMOST_BOT_ROUTES` | Path to bot routes JSON for multi-bot routing |
| `MATTERMOST_STATE_DIR` | Agent-local state directory |
| `MATTERMOST_WEBHOOK_PORT` | HTTP server port (default: 3979) |
| `MATTERMOST_OUTGOING_WEBHOOK_TOKEN` | Leave empty to skip token validation |
| `BRIDGE_HOME` | Agent Bridge home (default: `~/.agent-bridge`) |

## Standalone Fallback

When `MATTERMOST_STANDALONE=1` and bridge-send fails, the plugin falls back to generating a response directly via Claude API (`ANTHROPIC_API_KEY`) or Claude CLI (`claude --print`).

## Prompt Guard

If `BRIDGE_PROMPT_GUARD_ENABLED=1` is set, inbound text is scanned and outbound reply text is sanitized before send.
