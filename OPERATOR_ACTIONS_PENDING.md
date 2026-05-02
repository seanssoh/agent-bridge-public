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

## v0.7.1 — telegram-relay residue auto-cleanup (no operator action required)

- applies_when_upgrading_from: any version `<= 0.7.0`.
- urgency: **none**.

### Background

v0.7.0 removed the telegram-relay source surface but left it to the operator to clean up live runtime residue (`state/channels/telegram/{tokens.list,*.sock,<token-hash>/}`, per-agent `.telegram/relay-token`, channel entries containing `plugin:telegram-relay@*`, and `BRIDGE_TELEGRAM_RELAY_*` env vars). Two prompts under `docs/proposals/` covered the manual procedure.

v0.7.1 automates the cleanup: `agent-bridge upgrade --apply` now runs `bridge-relay-cleanup.py` after the shared-settings rerender step, removes every residue class above idempotently, and emits a single `telegram_relay_residue_cleanup_applied` audit row when it actually changed something. Re-runs are no-ops. Per-agent `.telegram/.env` and `.telegram/access.json` are preserved — the official plugin still reads them.

### Action

**No operator action required for the common path.** The auto step covers every host that runs `agent-bridge upgrade --apply` to v0.7.1+.

If the auto step exited non-zero (rare — usually a filesystem permissions issue), the upgrader emits a `[bridge-upgrade] WARN: telegram-relay residue cleanup helper exited non-zero` line. In that case, run the manual prompt:

- All hosts: `docs/proposals/v0.7.0-install-cleanup-verification-prompt.md`
- Relay-host migration (heavier): `docs/proposals/jjujju-migration-prompt.md`

Both prompts are now fallbacks rather than first-line procedures.

### Skip if

- Always skip — informational; the cleanup activates automatically on the first `agent-bridge upgrade --apply` to v0.7.1+.

---

## v0.7.0 — telegram-relay daemon removed (operator action required on relay hosts)

- applies_when_upgrading_from: any version `0.6.37 .. 0.6.x` that registered the relay daemon.
- urgency: **high** for relay-using hosts (SYRS jjujju and any clones); **none** for hosts that never registered the relay.

### Background

PR3 reverts #475 phases 2/3 (the v0.6.37+ telegram-relay daemon). Outbound Telegram is now the parent agent's responsibility through the official `plugin:telegram@claude-plugins-official`. The cron inbox-only reporting contract from PR1+PR2 makes this clean: cron children write structured inbox tasks; parents forward through their own channel plugin.

The following surface is removed in v0.7.0:

- `agent-bridge telegram-relay <start|stop|status|health>` CLI subcommand (and the underlying `bridge-telegram-relay.sh`).
- `lib/telegram-relay.py` daemon and the `bridge_telegram_relay_supervise` daemon step.
- `plugins/telegram-relay/` plugin tree (the bun MCP adapter).
- `BRIDGE_TELEGRAM_RELAY_ENABLED` env var, `bridge-setup.py telegram --use-relay` / `--no-relay` flags, and the `BRIDGE_TELEGRAM_USE_RELAY` env knob.
- `state/channels/telegram/tokens.list` and `<token-hash>/` daemon state directories — these become orphaned but are not auto-removed; cleanup is part of the manual migration prompt below.
- Per-agent `.telegram/.env` and `.telegram/access.json` files are **preserved** — the official `plugin:telegram@claude-plugins-official` still reads them.

### Action — for hosts that registered the relay

The migration is **manual** per Sean's standing instruction (Q-F 2026-05-02). The verbatim prompt to send to the affected agent on the relay host lives at [`docs/proposals/jjujju-migration-prompt.md`](docs/proposals/jjujju-migration-prompt.md). Send it as-is to the relay-host's admin/agent and wait for confirmation before declaring the host migrated.

### Skip if

- The host never registered the relay (`grep BRIDGE_TELEGRAM_RELAY ~/.agent-bridge/agent-roster.local.sh` returns empty AND no relay process was ever supervised).
- The host doesn't use Telegram at all.

### Verification target

After running the manual migration prompt, the relay-host operator should observe:

- `~/.agent-bridge/state/channels/telegram/tokens.list` is empty or absent.
- `BRIDGE_AGENT_CHANNELS["<telegram-agent>"]` no longer contains `plugin:telegram-relay@agent-bridge`; it contains `plugin:telegram@claude-plugins-official` instead.
- `agent-bridge status --json` no longer surfaces a `telegram-relay` plugin entry for that agent.
- A real Telegram round-trip (cron child → main-session inbox task → parent forwards via official plugin) lands in the operator's chat.

---

## v0.6.x — cron inbox-only reporting contract (PR1+PR2 — no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.40`.
- urgency: **none** (informational).

### Background

PR1 (#499) and PR2 introduce inbox-only reporting for disposable cron children. The cron-runner now writes a structured `[cron-followup]` inbox task to the cron's parent agent (the configured `target_agent` — usually the operator-attached main session) when a run produces a signal worth surfacing; otherwise the run logs and exits silently. Existing crons default to silent-on-no-signal automatically — no per-job migration needed.

Per-job overrides ship via job metadata (Sean Q-B 2026-05-02):

- `metadata.cronReportingPolicy = default | always_main_session | always_silent` — force a particular reporting outcome regardless of what the child decides.
- `metadata.cronUrgency = normal | high | urgent` — set the priority of the resulting inbox task.

Operator visibility:

- `agb cron show <job>` now prints `last_reporting_decision`, `last_delivery_intent`, and `last_inbox_task_id` so the cron → inbox → main-session flow is traceable without grepping `state/cron/runs/`. Same trio is in `--format json` and `--format shell` output (`CRON_JOB_LAST_REPORTING_DECISION`, etc.).
- Parent-agent handling contract lives in [`docs/agent-runtime/common-instructions.md` §"Cron Followup Handling"](docs/agent-runtime/common-instructions.md#cron-followup-handling). The frontmatter parser is `lib/bridge_cron_followup.parse_followup` (Python stdlib only).

### Action

**No operator action required.** Existing crons keep their current behavior; the new contract only activates on the next run. `agb cron list` may show fewer admin-side `[cron-followup]` tasks than before — this is expected and signals the new contract is working. Parent agents now own the absorption / forwarding step.

The PR3 telegram-relay reversal is batched into a separate later release; that one **will** require an operator action on hosts that registered the relay daemon (e.g. jjujju). A self-contained migration prompt for that step lives at `docs/proposals/jjujju-migration-prompt.md` and is not auto-scripted into `agent-bridge upgrade --apply` per Sean Q-F.

### Skip if

- Always skip — informational. The contract activates on the next cron tick after upgrade. No operator action is required, period.

---

## v0.6.39 — shared Claude hooks now propagated on upgrade (no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.38`.
- urgency: **none** (informational).

### Background

Before v0.6.39 the upgrader did not call `bridge_ensure_claude_*_hook` for existing hosts, so a release that added a new hook event (Stop / SessionStart / UserPromptSubmit / PromptGuard / ToolPolicy) shipped the new script in `hooks/` but the existing per-agent `settings.json` never registered it. Only fresh installs picked up new hooks.

`v0.6.39` adds `bridge_upgrade_propagate_claude_hooks` that runs before the rerender step and ensures every Claude agent's shared base settings register the latest hook list. The subsequent rerender propagates the change into per-agent effective settings.

### Action

**No operator action required.** `agent-bridge upgrade --apply` from this release onward registers any newly-added hook automatically. The `shared_settings_rerender` line in upgrade output already reflects the post-rerender state.

### Skip if

- Always skip — informational. Behavior takes effect on the next `upgrade --apply` invocation.

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
