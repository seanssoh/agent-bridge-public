---
name: telegram-relay-access
description: Configure allowlists for the Agent Bridge Telegram relay channel plugin.
---

Use this skill when a Telegram-relay-connected Claude agent needs to explain
or adjust Telegram channel access.

The runtime state lives under `TELEGRAM_STATE_DIR`, usually
`<agent-workdir>/.telegram`.

Important files:

- `.env`: contains `TELEGRAM_BOT_TOKEN`.
- `relay-token`: plugin-created raw token file for the daemon, mode `0600`.
- `access.json`: contains `allowFrom`, `groups`, `dmPolicy`, and optional
  delivery settings.

Prefer the deterministic Agent Bridge setup command instead of hand-editing
credentials:

```bash
agent-bridge setup telegram <agent> --token <bot-token> --allow-from <telegram-user-id> --default-chat <chat-id> --yes
```

For groups, require mentions unless the user explicitly asks for every message
in the group to wake the agent:

```json
{
  "groups": {
    "-1001234567890": {
      "requireMention": true,
      "allowFrom": []
    }
  }
}
```

The relay plugin keeps using the same `.telegram/access.json` shape as the
current Telegram setup path; switching from `plugin:telegram@claude-plugins-official`
to `plugin:telegram-relay@agent-bridge` does not require rewriting access
policy files.
