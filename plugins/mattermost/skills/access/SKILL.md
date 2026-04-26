---
name: mattermost-access
description: Configure Mattermost allowlists for the Agent Bridge Mattermost channel.
---

Use this skill when a Mattermost-connected Claude agent needs to explain or adjust Mattermost channel access.

The runtime state lives under `MATTERMOST_STATE_DIR`, usually `<agent-workdir>/.mattermost`.

Important files:

- `.env`: contains `MATTERMOST_URL`, `MATTERMOST_BOT_TOKEN`, and `MATTERMOST_OUTGOING_WEBHOOK_TOKEN`.
- `access.json`: contains user allowlists and channel policies.

Prefer the deterministic Agent Bridge setup command instead of hand-editing credentials:

```bash
agb setup mattermost <agent> --url <mattermost-url> --bot-token <token> --webhook-token <token> --allow-from <user-id> --yes
```

For team channels, require mentions unless the user explicitly asks for every message in the channel to wake the agent:

```bash
agb setup mattermost <agent> --channel <channel-id> --require-mention --yes
```
