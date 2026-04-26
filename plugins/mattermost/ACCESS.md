# Mattermost Access Setup

1. In Mattermost System Console, enable bot accounts and outgoing webhooks.
2. Create a bot account and copy the Bot Access Token.
3. Create an outgoing webhook for the desired channel(s) and copy the token.
4. Identify the Mattermost user IDs of allowed users (System Console > Users, or via API).
5. Run Agent Bridge setup:

```bash
agb setup mattermost patch \
  --url "https://mattermost.example.com" \
  --bot-token "<bot-access-token>" \
  --webhook-token "<outgoing-webhook-token>" \
  --allow-from "<mattermost-user-id>" \
  --yes
```

For team channels, require mentions unless the user explicitly asks for every message to wake the agent:

```bash
agb setup mattermost patch \
  --url "https://mattermost.example.com" \
  --bot-token "<bot-access-token>" \
  --webhook-token "<outgoing-webhook-token>" \
  --channel "<channel-id>" \
  --require-mention \
  --yes
```
