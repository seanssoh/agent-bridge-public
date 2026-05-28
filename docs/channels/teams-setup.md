# Microsoft Teams Setup Guide

This guide covers the full first-time bring-up path for the Agent Bridge Teams channel on a real server.

## Scope

Current Teams support is Phase 1:

- inbound webhook receive
- allowlist access control
- Claude channel push into the running session
- `reply`
- `fetch_messages`

The Teams plugin currently ships from the local `agent-bridge` marketplace, so it runs as a development channel.

## Prerequisites

- Claude Code authenticated with a `claude.ai` account
- `bun` installed on the host
- Azure Bot / Entra application with:
  - Application ID
  - Client secret
  - Tenant ID
- A public HTTPS messaging endpoint that forwards to the host
- An Agent Bridge Claude agent, for example `patch`

## Delivery Path

```text
Teams user
  -> Microsoft Teams
  -> Azure Bot Service
  -> https://bot.example.com/api/messages
  -> reverse proxy / load balancer
  -> host listener
  -> bun teams plugin (default: 0.0.0.0:3978)
  -> Claude channel notification
  -> running Agent Bridge session
```

If the public endpoint can reach the backend directly on `3978`, use that.

If the public proxy can only target port `80`, you need a local redirect from `80` to the plugin port, for example:

```bash
sudo iptables -t nat -I PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 3978
```

Persist it with your distro's normal iptables save path if needed.

## Recommended Setup Command

Pass the client secret via the `BRIDGE_TEAMS_APP_PASSWORD` environment variable
(or `--app-password-file <path>`) so it is not exposed in shell history or the
process table.

```bash
export BRIDGE_TEAMS_APP_PASSWORD='<client-secret>'
agb setup teams patch \
  --app-id "<azure-bot-app-id>" \
  --tenant-id "<tenant-id>" \
  --allow-from "<aad-object-id-or-teams-user-id>" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --ingress-port "80" \
  --yes
```

### Secret delivery alternatives

The wizard accepts three argv-safe forms for the bot client secret. Pick the
one that matches your invocation style:

1. **`--app-password-file <path>`** — pass any path the wizard can `open()`:
   a regular file (the safest default, e.g. a `chmod 600` tempfile), or any of
   `/dev/fd/N`, named pipes, character/socket specials when the wizard runs
   without crossing a sudo subshell boundary. Bash process substitution
   `<(printf '%s' "$secret")` works in plain-shell invocations but **breaks
   when the call is wrapped in `sudo`** — the `/dev/fd/63` mapping does not
   survive the subshell (issue #1354). Use a tempfile or `--app-password-stdin`
   for `sudo`-wrapped flows.
2. **`--app-password-stdin`** — the wizard reads the secret once from its own
   stdin and uses it. Portable across sudo, useful in CI:
   ```bash
   printf '%s' "$BRIDGE_TEAMS_APP_PASSWORD" | agb setup teams patch \
     --app-id "<azure-bot-app-id>" \
     --tenant-id "<tenant-id>" \
     --app-password-stdin \
     --allow-from "<aad-object-id>" \
     --messaging-endpoint "https://bot.example.com/api/messages" \
     --webhook-host "0.0.0.0" --webhook-port "3978" --ingress-port "80" \
     --yes
   ```
3. **`BRIDGE_TEAMS_APP_PASSWORD` env var** — the legacy form shown above.
   Same security posture as `--app-password-stdin` (no argv, no shell
   history), but the secret remains in the parent shell's environment.

What this does:

- writes `agents/<agent>/.teams/.env`
- writes `agents/<agent>/.teams/access.json`
- writes `agents/<agent>/.teams/state.json`
- validates the App ID / secret / tenant against Microsoft login
- probes the public messaging endpoint when `--messaging-endpoint` is given
- adds `--dangerously-load-development-channels plugin:teams@agent-bridge` to the agent launch command
- installs and enables the Teams Claude plugin

## Validation Output

`agb setup teams` now prints three separate signals:

- `validation`
- `credential_validation`
- `endpoint_probe`

Interpret them like this:

- `credential_validation: ok`
  Means the bot credentials can successfully mint a token.
- `endpoint_probe: ok`
  Means the public messaging endpoint accepted the probe with a 2xx response.
- `endpoint_probe: backend_reached`
  Means traffic reached the backend. `401`, `404`, `405`, or `500` is acceptable for the probe because the endpoint is alive.
- `endpoint_probe: gateway_upstream_unreachable`
  Means the reverse proxy is reachable but cannot talk to the backend. Check port mapping, listener host, and iptables / proxy config.
- `endpoint_probe: unreachable`
  Means DNS / TLS / public routing is still broken.

## Reverse Proxy Patterns

### AWS ALB -> backend 3978 directly

- ALB listener: `443`
- target group backend port: `3978`
- plugin `.env`:

```dotenv
TEAMS_WEBHOOK_HOST=0.0.0.0
TEAMS_WEBHOOK_PORT=3978
```

### AWS ALB -> backend 80 -> iptables redirect -> 3978

- ALB target group backend port: `80`
- host rule:

```bash
sudo iptables -t nat -I PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 3978
```

- plugin `.env`:

```dotenv
TEAMS_WEBHOOK_HOST=0.0.0.0
TEAMS_WEBHOOK_PORT=3978
```

### nginx

```nginx
location /api/messages {
  proxy_pass http://127.0.0.1:3978/api/messages;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

### cloudflared

Route the public hostname to `http://127.0.0.1:3978`.

## First Restart

After setup, restart the agent so the updated launch command is used:

```bash
agb agent restart patch
```

On first boot, Claude Code may display a development-channel warning for the local Teams marketplace plugin. Agent Bridge auto-accepts this during managed startup.

## Allowlist Notes

The Teams allowlist is not email-based.

Use one of:

- Entra / AAD object ID
- Teams internal user ID
- a specific conversation or channel ID

If you do not know the ID yet, do a short controlled capture window:

1. temporarily widen access
2. let the user send one message
3. record the captured ID
4. return to allowlist mode

## Troubleshooting

- Symptom: `credential_validation` fails
  Fix: check App ID, client secret, tenant ID, and secret expiry.
- Symptom: `endpoint_probe: unreachable`
  Fix: check DNS, TLS, security groups, and whether the public URL points to the correct host.
- Symptom: `endpoint_probe: gateway_upstream_unreachable`
  Fix: the reverse proxy is up but the backend is not reachable. Check `TEAMS_WEBHOOK_HOST`, `TEAMS_WEBHOOK_PORT`, and any `80 -> 3978` redirect.
- Symptom: public proxy shows `502`
  Fix: backend mapping is wrong or the plugin is still listening on loopback only.
- Symptom: plugin starts but Claude receives no `<channel source="teams">`
  Fix: confirm the agent launch includes `--dangerously-load-development-channels plugin:teams@agent-bridge`.
- Symptom: inbound messages are duplicated
  Fix: update to a build that includes the Teams dedupe fix.

## Related Files

- [README.md](../../README.md)
- [plugins/teams/README.md](../../plugins/teams/README.md)
- [plugins/teams/ACCESS.md](../../plugins/teams/ACCESS.md)
