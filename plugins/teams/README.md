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

- `reply`: send a message back to a Teams conversation that has already passed access control. Accepts `chat_id` (required), `text` (optional if `attachments` is non-empty), and `attachments` (optional array; personal chats only — see §Outbound Attachments).
- `fetch_messages`: read the local rolling message log captured by the plugin.
- `send_message`: proactively initiate a 1:1 message to an allowlisted Teams user without requiring an inbound message first. Accepts `to` (required — AAD object ID or Teams user ID matching an entry in `access.json` allowFrom) and `text` (required). Uses the Bot Framework `createConversation` / `sendActivity` pattern when no stored conversation reference exists; reuses the stored reference if the user has messaged the bot before. Requires the bot app to be installed in the target user's Teams personal scope.

  Example:
  ```jsonc
  { "to": "<aad-object-id-or-teams-user-id>", "text": "Setup complete — bridge is online." }
  ```

  Return shape:
  ```jsonc
  { "ok": true, "conversation_id": "...", "message_id": "..." }
  // or on error:
  { "ok": false, "conversation_id": "", "message_id": "", "error": "bot_not_installed_or_auth_failed: ..." }
  ```

  Common errors:
  - `send_message: target "..." is not in the access.json allowFrom list` — add the user's id via `agb setup teams <agent> --allow-from <id> --yes`.
  - `bot_not_installed_or_auth_failed` — ensure the bot app is installed in the user's Teams personal scope (Apps -> search for the bot), or have a tenant admin push it via Graph `installedApps`. Also verify `TEAMS_APP_ID` / `TEAMS_APP_PASSWORD` / `TEAMS_TENANT_ID` match the Azure Bot registration.
  - `user_not_found` — confirm the `to` value is the correct AAD object ID or Teams user ID for this tenant.

  For multi-region tenants where the Teams service URL differs from the default (`smba.trafficmanager.net/amer`), set `TEAMS_SERVICE_URL` in `.env`. The plugin derives the URL automatically from any stored conversation reference once the user has messaged the bot at least once.

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
BRIDGE_TEAMS_APP_PASSWORD=... agb setup teams <agent> --app-id ... --tenant-id ... --allow-from ... --messaging-endpoint https://bot.example.com/api/messages --webhook-host 0.0.0.0
```

## Inbound Attachments

When a Teams user attaches a file or image, the plugin downloads each attachment to:

```
<TEAMS_STATE_DIR>/attachments/<message_id>/<filename>
```

(directory mode 0700, file mode 0600). Attachment metadata is exposed in two shapes:

- **Direct Claude channel notification** (`notifications/claude/channel`) — meta is kept **flat and string-only**: scalar `attachment_count` and `attachment_names` fields. It does **not** carry a nested `attachments` array. The flat shape is what keeps the direct channel notification reliable (see #1022).
- **Bridge queue / audit / replay body** — retains the rich nested `attachments` array, each entry with `name`, `content_type`, `download_status` (`ok` / `skipped_non_file` / `failed`), and — on success — `local_path` and `size_bytes`.

Cards (`application/vnd.microsoft.card.*` and `application/vnd.microsoft.teams.card.*`) are recorded with `skipped_non_file` so the agent still sees the metadata.

Downloaded content types:

- `application/vnd.microsoft.teams.file.download.info` — Teams native file picker (downloadUrl from `content.downloadUrl`)
- `image/*` — picture attachments
- `application/*` (other than card types above) — PDFs, DOCX, ZIP, octet-stream, etc.
- `audio/*`, `video/*`, `text/*` — media and plain text

Cards stay skipped on purpose; the agent should not auto-fetch adaptive / hero / signin card payloads.

Override the location and size cap via:

```dotenv
TEAMS_ATTACHMENTS_DIR=<absolute path>     # must be absolute and writable; otherwise default is used
TEAMS_ATTACHMENT_MAX_BYTES=52428800       # default: 50 MB; clamped to 1 GB; non-numeric falls back to default
```

Filenames and message ids are sanitized (strict allowlist) before they're joined into the on-disk path; downloads stream to disk with an in-flight byte counter so a server lying about `Content-Length` cannot bypass the cap.

## Outbound Attachments

The `reply` MCP tool accepts an optional `attachments` array so the agent can send general files (PDF/DOCX/ZIP/images/etc.) back to a Teams user. Phase 1 supports **personal chats only** — group chats and channels return a structured error `attachments_not_supported_in_groupchat` (SharePoint-backed group delivery is Phase 2).

```jsonc
{
  "chat_id": "...",
  "text": "Here's the report you asked for",
  "attachments": [
    { "path": "/abs/path/to/report.pdf", "name": "report.pdf" }
  ]
}
```

Delivery uses the Teams file consent card flow:

1. The plugin sends one `application/vnd.microsoft.teams.card.file.consent` activity per file, with the agent's text on the first card. The pending consent is persisted to `<TEAMS_STATE_DIR>/outbound-consents.json` (mode 0600) keyed by a server-generated token so a plugin restart between send and user-accept can still complete the upload.
2. When the user clicks **Accept**, Teams posts a `fileConsent/invoke` activity to `/api/messages`. The plugin PUTs the file bytes to the upload URL and replies with a `fileInfo` card pointing at the uploaded blob. **Decline** drops the pending record and posts a short text reply.
3. Pending consents older than 24 hours are swept on plugin start.

Per-file validation:

- `path` must be absolute and live under `TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT` (defaults to `<TEAMS_STATE_DIR>/outbound`). The supplied path is `realpath`-resolved (following parent-directory symlinks) and the resolved path must remain inside the realpath of the allow root, so a symlink chain inside the root cannot escape to arbitrary host files.
- Must be a regular file. Symbolic links are rejected outright at the supplied path (an `lstat` check runs before `realpath`); the agent must pass the real on-disk location, not a link to it. Directories and special files are also rejected.
- Per-file size cap via `TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES` (default 50 MB; clamped to 1 GB).
- Display name (defaults to `basename(path)`) runs through the same sanitizer as inbound — strict allowlist.
- Content type is inferred from the filename extension. Card types (`application/vnd.microsoft.card.*` and `application/vnd.microsoft.teams.card.*`) are rejected; the agent cannot inject adaptive cards through the attach path.

Per-message cap: 10 attachments.

Override the allowlist root and size cap via:

```dotenv
TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT=<absolute path>   # default: <TEAMS_STATE_DIR>/outbound
TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES=52428800            # default: 50 MB; clamped to 1 GB
```

## Inbound delivery

Delivered via direct MCP push to the live Claude session — no configuration required. A delivery failure surfaces as a non-2xx so Teams retries; the local message log is appended only after delivery succeeds, so retries cannot duplicate already delivered messages.

## Current Scope

This is the Phase 1 channel implementation: webhook receive, access gate, Claude channel notification, reply, local message fetch, and a lightweight `/auth/callback` endpoint used by the `ms365` plugin authorization-code pairing flow. Multi-tenant user-to-agent routing is intentionally left to the Agent Bridge relay layer so one Teams bot can map many users to many timeout agents without mixing conversation state.

If `BRIDGE_PROMPT_GUARD_ENABLED=1` is set in the agent runtime, Teams inbound text is scanned before it reaches Claude and outbound `reply` text is sanitized before send.
