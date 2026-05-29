# Create a static agent — what to do after `agent create`

Audience: an admin (or admin-operator) who just ran `agb agent create <name> ...` and is now looking at the create-output asking "what now?". Goal: ship the next required command without reading source.

If you have not yet run `agent create`, start at [first-install.md](./first-install.md).

---

## Read `next_steps:` from the create output

`agb agent create` ends its text output with a `next_steps:` section. The list is **persona-aware** — it depends on what you asked for at create time:

- terminal-only static agent (no channels) → `agent start --dry-run`, attach, memory/onboarding checklist
- Discord agent → `agb setup discord <agent>`, then `agb agent show <agent>`
- Telegram agent → `agb setup telegram <agent>`, then `agb agent show <agent>`
- Teams agent → `agb setup teams <agent>`, then `agb agent show <agent>`
- plugin-enabled isolated agent → `agb plugins seed`, `agb skills list --agent <agent>`, then `agb agent show <agent>`
- linux-user isolated agent → CLI-mediated access reminders (do not direct-read files under another agent's home; use `agb agent show` / `agb agent list`)

Run those in order. They are not generic — they reflect the channels you wired, the isolation mode you chose, and the engine you picked.

If you want to see them again without re-creating, run `agb agent show <agent>` — the `next_actions:` section there continues from the same data plus a live diagnostics check.

---

## Common create patterns

### Terminal-only static agent

```bash
agb agent create writer --engine claude
agb agent start writer --dry-run     # verify the launch line resolves
agb attach writer                    # talk to it
```

After attach, walk the onboarding skill: ask the agent to read its `SOUL.md` / `CLAUDE.md` / `SESSION-TYPE.md` and confirm it has the tools it expects.

### Channel-wired static agent (Discord example)

```bash
agb agent create writer --engine claude --channels plugin:discord@claude-plugins-official --discord-channel <YOUR_CHANNEL_ID>
agb setup discord writer             # the admin asks for token + channel access
agb agent show writer                # check channel_diagnostics + next_actions
agb agent start writer --dry-run
```

The `<YOUR_CHANNEL_ID>` value comes from your Discord client (Developer Mode → right-click channel → Copy Channel ID). The token is collected by `agb setup discord`. Do not put either in tracked files.

### Plugin-enabled isolated agent (Linux only)

```bash
agb agent create coder --engine claude --isolate --channels plugin:teams@agent-bridge,plugin:cosmax-crm@agent-bridge
agb plugins seed --agent coder       # publish controller-side plugins into coder's isolated marketplace
agb agent show coder                 # verify plugin_installed=yes, plugin_enabled=yes, runtime_ready=yes
agb agent start coder --dry-run
```

The `--isolate` flag scaffolds an isolated linux-user (`agent-bridge-coder`) with its own group, marketplace root, and runtime. Plugins must be seeded into the isolated tree explicitly — the controller-side install is not visible to the isolated UID. See [plugin-enabled-agent.md](./plugin-enabled-agent.md) for the first-session checklist the agent itself should follow.

---

## When the create succeeded but `next_steps:` looks empty

Two known shapes:

1. **You ran with `--json` and ignored the `policy` / `next_steps` fields.** The JSON envelope carries the same `next_steps` array — pipe it through `jq` if you are scripting.
2. **You created a managed-role variant (admin, admin-codex pair) where the next step is owned by bootstrap.** The create output still emits `create: ok`; the next user action is `agb admin` (for the admin) or nothing (the pair is auto-spawned on first admin nudge). See [docs/agent-runtime/admin-agent-convention.md](../agent-runtime/admin-agent-convention.md).

---

## When the create output says `daemon_group_refresh: …`

On linux-user isolation, the daemon needs the new per-agent supplementary group to send urgent/queue traffic to the new agent. The create-side refresh attempts it automatically and prints one of:

- `ok` / `ok-systemd-sudo-self` — refresh succeeded; nothing to do.
- `manual-required-...` — you need to run the printed recovery command before the new agent can be addressed by urgent-send / channel-readiness probes.
- `failed-...` — refresh attempted but failed; the create still succeeded, but you must restart the daemon manually.

The create output prints the exact recovery command. Run it verbatim — do not paraphrase, do not skip.

---

## Common follow-ups

- **The agent does not appear in `agb status`.** → `agb agent list` (registered?) → `agb daemon sync` (reconcile pass) → `agb agent show <name>` (look at `actions:` and `session_health:`).
- **Channel says credentials missing.** → [troubleshooting-auth-and-channels.md](./troubleshooting-auth-and-channels.md).
- **Plugin says installed=no after seed.** → [plugin-enabled-agent.md](./plugin-enabled-agent.md) §"First-session checklist".

---

## See also

- [README §에이전트 종류](../../README.md#에이전트-종류) — taxonomy of static / dynamic / admin / admin-pair.
- [docs/agent-runtime/admin-agent-convention.md](../agent-runtime/admin-agent-convention.md) — convention for the admin agent that creates other agents on your behalf.
- [OPERATIONS.md](../../OPERATIONS.md) — iso v2 grant matrix and channel state contract.
