# Mattermost Access Setup

1. In Mattermost System Console, **enable bot accounts**
   (`Integrations → Bot Accounts → Enable`).
2. Create one bot per agent and copy each bot's **Access Token**.
3. **Invite each bot to the channel(s) you want it to monitor**.
   The plugin uses Mattermost's WebSocket gateway, so channel coverage
   is a function of bot membership — no per-channel webhook
   registration is required.
4. Identify the Mattermost user IDs of allowed users
   (System Console → Users, or via API).
5. Run Agent Bridge setup:

```bash
agb setup mattermost <agent> \
  --url "https://mattermost.example.com" \
  --bot-token "<bot-access-token>" \
  --allow-from "<mattermost-user-id>" \
  --yes
```

For shared channels, require @-mentions so only messages addressed
to this bot wake the agent (the plugin's per-route mention gate also
enforces this regardless of `requireMention`):

```bash
agb setup mattermost <agent> \
  --url "https://mattermost.example.com" \
  --bot-token "<bot-access-token>" \
  --channel "<channel-id>" \
  --require-mention \
  --yes
```

`bridge-setup.py mattermost` writes three files:

- `<mattermost-dir>/.env` — `MATTERMOST_URL`, `MATTERMOST_BOT_TOKEN`,
  `BRIDGE_AGENT_ID`
- `<mattermost-dir>/access.json` — DM/channel allowlists
- `<agent-workdir>/.mcp.json` — `mattermost-mcp-server` upserted
  (existing MCP servers preserved). Override the binary path with
  `--mcp-binary /abs/path/mattermost-mcp-server` if it's not on
  `PATH`.
