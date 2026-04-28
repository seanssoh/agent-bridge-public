# Mattermost Channel

This plugin subscribes to a self-hosted Mattermost instance via the
WebSocket gateway (`/api/v4/websocket`) and routes incoming posts to
Agent Bridge agents. Agents respond using the
[mattermost-mcp-server](https://github.com/mattermost/mattermost-plugin-agents)
`create_post` tool (registered for the agent via `.mcp.json`).

## Architecture

```
Mattermost user posts in channel
  → Mattermost server broadcasts `posted` event over WS
  → Plugin server (one WS connection per bot in BOT_ROUTES,
    or one connection in single-bot mode)
  → Per-route gate: dmPolicy / allowFrom / @mention check
  → recentMessageIds dedupe (per-(post_id, route))
  → bridge-guard prompt scan
  → agb urgent <route.agent> "<post text>"
  → Claude agent claims task
  → Agent calls mattermost-mcp-server `create_post` to reply
```

The plugin runs as a single bun process. Inbound and outbound paths
are decoupled:

- **Inbound**: WebSocket → `handlePosted` → `agb urgent`. Outbound
  TCP only — no inbound port to expose.
- **Outbound**: Agent uses `mattermost-mcp-server` MCP tools
  (`create_post`, `read_channel`, `get_thread`, …). Tokens live in
  `.mcp.json` under `MM_ACCESS_TOKEN`.

The vendored WebSocket monitor + reconnect modules (`lib/`) are
adapted from [openclaw](https://github.com/openclaw/openclaw) under
MIT — see `THIRD_PARTY_LICENSES.md`.

## Setup

### 1. Bot Account(s)

In **System Console → Integrations → Bot Accounts**, enable bot
account creation, then add one bot per agent (e.g. `buildersbot`,
`sales-bot`). Copy each bot's **Access Token**. Invite each bot to
the channels it should monitor.

WebSocket transport requires the bot to be a member of the channel —
no per-channel webhook registration is needed.

### 2. Mattermost MCP Server

Build the official MCP server once on the host that will run agents:

```bash
git clone https://github.com/mattermost/mattermost-plugin-agents
cd mattermost-plugin-agents && make mcp-server
sudo install -m 0755 build/mattermost-mcp-server /usr/local/bin/
```

### 3. Run `bridge-setup.py mattermost`

`bridge-setup.py` writes the state dir, access policy, and `.mcp.json`
in one shot:

```bash
python3 ~/.agent-bridge/bridge-setup.py mattermost \
  --agent builders-bot \
  --mattermost-dir ~/.agent-bridge/agents/builders-bot/.mattermost \
  --url https://builders.cosmax.com \
  --bot-token "<buildersbot-access-token>" \
  --allow-from "<operator-user-id>" \
  --channel "<channel-id>" \
  --require-mention \
  --yes
```

This creates:

- `~/.agent-bridge/agents/builders-bot/.mattermost/.env`
- `~/.agent-bridge/agents/builders-bot/.mattermost/access.json`
- `~/.agent-bridge/agents/builders-bot/.mcp.json` (mattermost MCP
  server upserted; existing servers preserved)

### 4. Multi-bot (optional)

For multiple bots in a single plugin process, point at a routes file
instead:

```bash
cat > ~/.agent-bridge/agents/.mattermost-bot-routes.json <<'EOF'
[
  {"username": "buildersbot",  "token": "...", "agent": "builders-bot",          "system_prompt": "..."},
  {"username": "sales-bot",    "token": "...", "agent": "sales_mun",             "system_prompt": "..."},
  {"username": "research-bot", "token": "...", "agent": "formulation_research",  "system_prompt": "..."}
]
EOF
```

Set `MATTERMOST_BOT_ROUTES=<that path>` in the plugin's environment.
The plugin opens one WS connection per route. Each route is
authenticated independently (first failure is fatal). Mention-based
routing — `@buildersbot hello` wakes only `builders-bot` — is
enforced inside `handlePosted` using Mattermost's server-parsed
`data.mentions` field with a regex fallback for events that omit it.

## Runtime files

Per-agent state directory (`~/.agent-bridge/agents/<agent>/.mattermost/`):

- `.env` — `MATTERMOST_URL`, `MATTERMOST_BOT_TOKEN`, `BRIDGE_AGENT_ID`
- `access.json` — user allowlist and per-channel policies
- `messages.jsonl` — local rolling message log

The `.mcp.json` for the agent's own Claude/Codex session lives one
level up at `~/.agent-bridge/agents/<agent>/.mcp.json`.

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
  }
}
```

`requireMention: true` is recommended for shared channels — the
plugin's per-route mention gate enforces it regardless of policy, so
this acts as a defense-in-depth.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MATTERMOST_URL` | `http://localhost:8065` | Mattermost API base (host root, NOT team-scoped). E.g. `https://builders.cosmax.com` |
| `MATTERMOST_BOT_TOKEN` | — | Single-bot mode: the bot's access token |
| `MATTERMOST_BOT_ROUTES` | — | Multi-bot mode: path to JSON array of `{username, token, agent, system_prompt}` |
| `MATTERMOST_BRIDGE_MODE` | `0` | `1` to route via `agb urgent` (production); `0` to use MCP `notifications/claude/channel` push |
| `MATTERMOST_BRIDGE_AGENT` | — | Single-bot agent name when `BRIDGE_MODE=1` and no `BOT_ROUTES` |
| `MATTERMOST_STATE_DIR` | `~/.claude/channels/mattermost` | Per-agent state directory; `bridge-setup.py` overrides this to `~/.agent-bridge/agents/<agent>/.mattermost` |
| `MATTERMOST_WS_URL` | derived from `MATTERMOST_URL` | Override the WebSocket base (rarely needed) |
| `MATTERMOST_HEALTH_CHECK_MS` | `30000` | Bot account `update_at` poll interval |
| `MATTERMOST_WS_INITIAL_DELAY_MS` | `2000` | First reconnect backoff |
| `MATTERMOST_WS_MAX_DELAY_MS` | `60000` | Max reconnect backoff (also used to derive multi-bot watchdog threshold = 3× this) |
| `MATTERMOST_WS_IDLE_TIMEOUT_MS` | `120000` | If no WS frame arrives within this, terminate the connection so reconnect re-establishes. Catches silent auth-fail. |
| `MATTERMOST_ACCESS_MODE` | (unset) | Set to `static` to load access.json once at boot instead of per-event |
| `BRIDGE_HOME` | `~/.agent-bridge` | Agent Bridge home — `bridgeSend` invokes `${BRIDGE_HOME}/agent-bridge urgent ...` |

## Reconnect & resilience

- **Reconnect**: exponential backoff with jitter
  (`MATTERMOST_WS_INITIAL_DELAY_MS` → `MATTERMOST_WS_MAX_DELAY_MS`).
  Successful connections reset backoff to the initial value.
- **Health check**: every `MATTERMOST_HEALTH_CHECK_MS` (default 30s)
  the plugin polls the bot account's `update_at` timestamp. If it
  changes, the connection is terminated to force a fresh
  authentication challenge — catches the silent-disconnect that
  Mattermost exhibits after a bot disable/enable cycle.
- **Idle timeout**: if no WS frame of any kind arrives within
  `MATTERMOST_WS_IDLE_TIMEOUT_MS` (default 2 minutes) the connection
  is terminated. Mattermost emits periodic frames on idle channels
  (`hello`, `typing`, `status_change`, `channel_viewed`), so prolonged
  silence is a reliable signal of a dead connection — including the
  silent-auth-fail mode where Mattermost accepts the WS handshake but
  rejects `authentication_challenge` without closing the socket.
- **Multi-bot watchdog**: when running >1 route, if every route stays
  disconnected for longer than `3 × MATTERMOST_WS_MAX_DELAY_MS` the
  process exits non-zero so `agb` can restart it.

## Prompt guard

If `BRIDGE_PROMPT_GUARD_ENABLED=1` is set, inbound text is scanned
and outbound reply text is sanitized before send.
