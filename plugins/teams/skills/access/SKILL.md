---
name: teams-access
description: Configure Microsoft Teams allowlists for the Agent Bridge Teams channel.
---

Use this skill when a Teams-connected Claude agent needs to explain or adjust Teams channel access.

The runtime state lives under `TEAMS_STATE_DIR`, usually `<agent-workdir>/.teams`.

Important files:

- `.env`: contains `TEAMS_APP_ID`, `TEAMS_APP_PASSWORD`, and `TEAMS_TENANT_ID`.
- `access.json`: contains user allowlists and conversation policies.

Prefer the deterministic Agent Bridge setup command instead of hand-editing
credentials. Pass the client secret via the `BRIDGE_TEAMS_APP_PASSWORD`
environment variable (or `--app-password-file <path>`) so it is not exposed in
shell history or the process table:

```bash
BRIDGE_TEAMS_APP_PASSWORD=<secret> agb setup teams <agent> --app-id <app-id> --tenant-id <tenant-id> --allow-from <aad-object-id> --yes
```

For team channels, require mentions unless the user explicitly asks for every message in the channel to wake the agent:

```bash
agb setup teams <agent> --conversation <conversation-id> --require-mention --yes
```
