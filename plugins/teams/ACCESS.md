# Teams Access Setup

1. In Azure, create or open an Azure Bot resource.
2. Copy the bot Application ID.
3. Create a client secret and copy the value as the App Password.
4. Copy the Tenant ID.
5. Add the bot to Teams and send it one message from the intended user.
6. Use the Teams AAD object ID or Teams user ID as `--allow-from`.
7. Run Agent Bridge setup. Pass the client secret via the
   `BRIDGE_TEAMS_APP_PASSWORD` environment variable (or `--app-password-file
   <path>`) so it is not exposed in shell history or the process table:

```bash
export BRIDGE_TEAMS_APP_PASSWORD='<client-secret>'
agb setup teams patch \
  --app-id "<app-id>" \
  --tenant-id "<tenant-id>" \
  --allow-from "<aad-object-id-or-user-id>" \
  --yes
```

For team channels, also add a conversation/channel id:

```bash
export BRIDGE_TEAMS_APP_PASSWORD='<client-secret>'
agb setup teams patch \
  --app-id "<app-id>" \
  --tenant-id "<tenant-id>" \
  --conversation "<teams-conversation-or-channel-id>" \
  --require-mention \
  --yes
```

For full production bring-up, including messaging endpoint probing, `TEAMS_WEBHOOK_HOST`, reverse proxy examples, and iptables guidance, see [docs/channels/teams-setup.md](../../docs/channels/teams-setup.md).
