# Discord Setup Guide

This guide covers the full first-time bring-up path for the Agent Bridge Discord channel on a real server.

## Scope

Current Discord support covers:

- gateway (WebSocket) inbound receive — no public HTTP endpoint to expose
- pairing + allowlist access control
- Claude channel push into the running session
- `reply` (with native reply-references and file attachments)
- `react`
- `edit_message`
- `fetch_messages`
- `download_attachment`
- guild-channel mention-triggering (opt-in per channel ID)
- per-agent thread-as-session (opt-in via `DISCORD_THREAD_AUTO_SESSION_CHANNEL_ID`)

The Discord plugin ships from the local `agent-bridge` marketplace
(`plugins/discord/`), exactly like the Teams plugin, so it is a
bridge-vendored channel rather than a Claude-official one. It is derived from
Anthropic's Apache-2.0 `discord` plugin; see
[plugins/discord/LICENSE](../../plugins/discord/LICENSE).

## Prerequisites

- Claude Code authenticated with a `claude.ai` account
- `bun` installed on the host (the MCP server runs on Bun)
- A Discord application with a bot user:
  - bot token (Developer Portal → Bot → Reset Token)
  - **Message Content Intent** enabled (Privileged Gateway Intents) — without
    it the bot receives messages with empty content
- The bot invited to at least one server you share with it (Discord will not
  let you DM a bot unless you share a guild)
- An Agent Bridge Claude agent, for example `patch`

Recommended OAuth2 bot permissions when inviting (URL Generator → `bot`
scope): View Channels, Send Messages, Send Messages in Threads, Read Message
History, Attach Files, Add Reactions. DM-only use technically needs none, but
enabling them now saves a return trip when you want guild channels later.

## Delivery Path

```text
Discord user
  -> Discord
  -> Discord Gateway (outbound WebSocket from the host)
  -> bun discord plugin (MCP server, gateway client)
  -> Claude channel notification
  -> running Agent Bridge session
```

Unlike Teams, Discord uses an **outbound** gateway connection. There is no
inbound HTTPS endpoint to publish and no reverse proxy or port redirect to
configure — the bot dials out to Discord, so the host only needs outbound
network access.

## Recommended Setup Command

Pass the bot token via the `--token` flag (or write it to the channel `.env`
out of band). The `--channel` value is the default Discord channel/snowflake
the agent should treat as its primary conversation.

```bash
agb setup discord patch \
  --token "<discord-bot-token>" \
  --channel "<discord-channel-id>" \
  --yes
```

What this does:

- writes `agents/<agent>/.discord/.env`
- writes `agents/<agent>/.discord/access.json`
- writes `agents/<agent>/.discord/state.json`
- provisions the bundled plugin's `node_modules` via `bun install`
- adds the Discord channel to the agent launch command
  (`plugin:discord@agent-bridge`)
- installs and enables the Discord Claude plugin

> The bot token is a credential — the wizard writes it to a `chmod 600`
> `.env`. To run multiple bots on one host (different tokens, separate
> allowlists), point `DISCORD_STATE_DIR` at a different directory per
> instance.

## Validation Output

`agb setup discord` reports a `validation` signal for the write step. Because
Discord connects outbound over the gateway rather than receiving inbound HTTP,
there is no public-endpoint probe equivalent to the Teams `endpoint_probe` —
liveness is confirmed at first connect when the agent restarts and the bot
appears online.

Interpret the signals like this:

- `validation: ok`
  Means the channel state files were written and the launch command updated.
- bot shows **online** in Discord after restart
  Means the gateway connection succeeded and the token is valid.
- bot stays **offline** after restart
  Means the token is wrong/expired, Message Content Intent is off, or the host
  has no outbound network access to the Discord gateway.

## First Restart

After setup, restart the agent so the updated launch command is used:

```bash
agb agent restart patch
```

On first boot, Claude Code loads the Discord plugin from the local
`agent-bridge` marketplace (`plugin:discord@agent-bridge`). Agent Bridge
handles the managed startup so the channel attaches without manual plugin
menu steps.

## Pairing and Allowlist

The Discord allowlist is **snowflake**-based, not email-based. Enable
Developer Mode (User Settings → Advanced) and right-click → Copy ID to read a
user, channel, or guild snowflake.

Default policy is `pairing`, which is a temporary ID-capture mode — not a
long-term state. Bring-up flow:

1. With the agent running, DM the bot. It replies with a pairing code.
2. Approve it in the session with `/discord:access pair <code>` (the code
   captures the sender's snowflake).
3. Once everyone who should reach the bot is in the allowlist, lock it down
   with `/discord:access policy allowlist` so strangers no longer get pairing
   replies.

If you already have snowflakes, you can add them directly with
`/discord:access allow <id>` and skip pairing entirely. Guild channels are
opt-in per channel ID; in a guild channel the bot triggers only on mention.

See [plugins/discord/ACCESS.md](../../plugins/discord/ACCESS.md) for DM
policies, guild channels, mention detection, delivery config, the skill
commands, and the `access.json` schema.

## Thread-as-Session (Opt-In)

The Agent Bridge Discord build adds an optional per-agent thread-as-session
feature. When enabled, every thread created under a designated parent channel
auto-spawns a persistent isolated Claude sub-session owned by the
channel-owning agent.

To enable, set the parent channel's snowflake in the agent's Discord `.env`:

```dotenv
DISCORD_THREAD_AUTO_SESSION_CHANNEL_ID=<parent-channel-snowflake>
```

Notes:

- Disabled by default — leave the variable unset to keep the channel as a
  plain reply/fetch channel.
- The setting is **per agent** (scoped to that agent's `.discord/.env`), even
  though the plugin code is shared across agents.
- The bundled dispatcher (`plugins/discord/thread-session/`) derives the
  owning agent from `BRIDGE_AGENT_ID`, so it works for any Discord agent with
  no per-agent path configuration.
- Restart the agent after changing the variable — the server reads it at boot.

## Troubleshooting

- Symptom: bot stays offline after restart
  Fix: check the token (Developer Portal → Bot → Reset Token), confirm
  Message Content Intent is enabled, and confirm the host has outbound network
  access to the Discord gateway.
- Symptom: bot is online but receives messages with empty content
  Fix: enable **Message Content Intent** in the Developer Portal and restart.
- Symptom: bot cannot be DM'd
  Fix: invite the bot to a server you share with it — Discord blocks DMs to a
  bot you share no guild with.
- Symptom: plugin starts but Claude receives no `<channel source="discord">`
  Fix: confirm the agent launch includes `plugin:discord@agent-bridge` and
  that the sender's snowflake is allowed (or pairing is still open).
- Symptom: a guild channel message does not reach the assistant
  Fix: guild channels are opt-in per channel ID and trigger on mention only —
  add the channel and mention the bot.
- Symptom: thread auto-session does not spawn
  Fix: confirm `DISCORD_THREAD_AUTO_SESSION_CHANNEL_ID` is set to the **parent**
  channel snowflake and that the agent was restarted after the change.

## Related Files

- [README.md](../../README.md)
- [plugins/discord/README.md](../../plugins/discord/README.md)
- [plugins/discord/ACCESS.md](../../plugins/discord/ACCESS.md)
