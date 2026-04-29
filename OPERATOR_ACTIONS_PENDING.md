# Operator Actions Pending

Per-release admin checklist that the bridge-upgrade post-task references. Each
section below is a single release. After running `agent-bridge upgrade --apply`
on this host, the admin should:

1. Read every section whose `applies_when_upgrading_from <= installed_version`.
2. Execute the listed actions or close them with a one-line `not applicable
   here because <reason>` note.
3. Skip sections that ship with no operator action (the section's body says
   "no operator action required" — most release bumps fall here).

The latest release's section is always at the top. When opening a new release
PR, prepend a new section; do not edit older sections in place.

---

## v0.6.39 — settings rerender for hosts that upgraded before this fix

- applies_when_upgrading_from: any version `0.6.33 .. 0.6.38`
- urgency: medium.

### Action

Run on the upgraded host to backfill managed Claude settings defaults that may
not have propagated during prior upgrades:

```bash
agent-bridge agent rerender-settings --apply
```

Confirm `autoCompactWindow: 400000` is present in each managed Claude agent's
effective settings.

### Skip if

- This host has no managed Claude agents.
- `agent-bridge agent rerender-settings --dry-run` reports every target as
  `unchanged`.

---

## v0.6.39 — `setup telegram` defaults to relay (no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.38`.
- urgency: **none** (informational).

### Background

`agent-bridge setup telegram <agent>` now defaults to `--use-relay` (the
architectural fix from #475 phase 2/3). The legacy
`plugin:telegram@claude-plugins-official` path is still reachable via
`--no-relay` as a transitional escape hatch.

### Action

**No operator action required.** Existing agents on the legacy plugin path keep
working until the operator explicitly re-runs `setup telegram`. Hosts that
already have the v0.6.37 telegram-relay opt-in section processed are already on
the relay path.

### Skip if

- Always skip — this is informational. The flag flip only affects new
  `setup telegram` invocations; existing registrations are untouched.

---

## v0.6.37 — telegram-relay opt-in

- applies_when_upgrading_from: any version `<= 0.6.36`
- urgency: **high** if this host has any agent currently using
  `plugin:telegram@claude-plugins-official` (mid-session disconnect symptom);
  low otherwise.

### Background

`v0.6.34` already shipped the cron-cascade fix (#474), so
`agent-bridge upgrade --apply` alone stops the 30-min cron-driven Telegram
poller SIGTERM cycle on every host. **No operator action required for that
fix — it activates automatically on upgrade.**

`v0.6.37` adds the architectural fix for the remaining cascade triggers
(operator opening a second attached session, `/mcp` reconnect, sibling plugin
spawn): a single-token-owner relay daemon (`lib/telegram-relay.py`) plus a
plugin client adapter (`plugins/telegram-relay/server.ts`) plus the
`bridge-setup.py telegram --use-relay` lifecycle wiring. Activating it is
**operator opt-in** because it changes the channel registration from
`plugin:telegram@claude-plugins-official` to `plugin:telegram-relay@agent-bridge`.

### Action — for each agent that uses the Telegram channel on this host

1. Set `BRIDGE_TELEGRAM_RELAY_ENABLED=1` permanently in the bridge daemon's
   environment file (typically `~/.agent-bridge/.env`; check
   `lib/bridge-daemon.sh` env loading if unsure).

2. Re-key each Telegram-using agent through the relay-aware setup path:
   ```
   ~/.agent-bridge/agent-bridge setup telegram <agent> \
     --token "<bot-token>" \
     --allow-from "<user-id>" \
     --default-chat "<chat-id>" \
     --use-relay --yes
   ```
   The token / allow-from / default-chat values can be recovered from the
   agent's existing `~/.agent-bridge/agents/<agent>/.telegram/.env` and
   `access.json` before re-running setup.

3. Trigger one bridge-daemon sync:
   ```
   ~/.agent-bridge/agent-bridge daemon sync
   ```

4. Confirm the relay is connected:
   ```
   ~/.agent-bridge/agent-bridge status --json | python3 -c \
     "import json,sys; d=json.load(sys.stdin); \
      [print(a['agent'], [p for p in a.get('plugins', []) if p.get('name')=='telegram-relay']) \
       for a in d.get('agents', [])]"
   ```
   Each Telegram agent's `telegram-relay` plugin should report
   `"status": "connected"`.

### Skip if

- This host has no Telegram-using agents.
- This host runs telegram via a non-bridge plugin (Slack/Mattermost/Discord
  share none of the "one polling consumer per token" constraint and are
  unaffected).
- The operator already opted into the relay before upgrading (the existing
  registration in `tokens.list` survives the upgrade).

### Verification target

- `agent-bridge status --json` shows each Telegram agent's `telegram-relay`
  plugin in `connected` state within 60 s of `daemon sync` returning.
- `BRIDGE_TELEGRAM_RELAY_ENABLED=1` is set in the daemon-loaded environment
  (so it survives daemon restarts).

### References

- Issue #475 — full architectural review.
- Phase 1 (daemon): #481 / v0.6.36.
- Phase 2 (plugin client): #483 / v0.6.37.
- Phase 3 (lifecycle + status): #484 / v0.6.37.
- Short-term cron mitigation already applied automatically: #474 / v0.6.34.
