# Plugin-enabled agent — first-session checklist

Audience: a Claude or Codex agent that just woke up inside a plugin-enabled runtime (channels via `plugin:<name>@<source>`, MCP tools attached, possibly an isolated linux-user UID). Goal: discover your installed plugins, MCP tools, and the right auth source — without reading source — before doing any user work.

Operators reading this: the runtime template links you here from `SESSION-TYPE.md`. You can also point a wedged agent here when it asks "which auth source should I use" or "why is my MCP tool returning 401?".

---

## Five questions you should be able to answer in the first session

1. **Which plugins are installed and enabled for me?**
2. **Which MCP tools should be callable?**
3. **Which auth source is expected for each?**
4. **What do I do when a tool returns 401?**
5. **Under linux-user isolation, which files should I avoid reading directly?**

If you can answer all five before doing user work, you will not get wedged later.

---

## Q1: Which plugins are installed and enabled?

```bash
agb agent show $(whoami | sed 's/^agent-bridge-//')   # if you are an isolated UID
# OR
agb agent show <your-agent-id>                        # if the operator told you
```

The `channel_diagnostics:` block lists every channel you were created with, each with:

- `plugin: installed=<yes|no> enabled=<yes|no> status=<…> spec=<plugin-name@source>`
- `runtime: state_dir=<path> access=<…> credentials=<…> ready=<yes|no|indeterminate>`

`installed=yes enabled=yes ready=yes` on every required row → you can proceed.

`installed=no` on any row → the controller-side install did not propagate into your isolated tree. Tell the operator:

> "I am missing plugin `<spec>`. Please run `agb plugins seed --agent <my-id>` from the controller."

Do not try to install the plugin yourself from inside an isolated UID — you do not have write access to the controller's marketplace root.

For a list of all skills currently discoverable in your session: `agb skills list --agent <my-id>`. Skills are documented per-plugin in [docs/plugin-authoring-iso-v2.md](../plugin-authoring-iso-v2.md).

---

## Q2: Which MCP tools should be callable?

Each channel plugin exposes an MCP server. Inside your Claude/Codex session, the MCP tools surface alongside built-in tools.

To see what is currently wired:

- **Claude session**: the MCP server list is printed at session start; you can also ask the runtime "list my MCP tools".
- **Codex session**: `codex mcp list` (if your codex install ships it) or read the `mcp_servers` block in your `.codex/config.toml`.

If a channel is listed under `channel_diagnostics` but no MCP tools appear in your session, the `runtime_ready` column will say `no` or `indeterminate`. Follow the credentials path (Q3) before re-checking.

---

## Q3: Which auth source is expected?

The credential source depends on the channel provider:

- **Discord plugin** → bot token stored in the channel's runtime state dir. Seeded by `agb setup discord <agent>`.
- **Telegram plugin** → bot token stored similarly. Seeded by `agb setup telegram <agent>`.
- **Teams plugin** → Microsoft 365 OAuth token (ms365). Seeded by `agb setup teams <agent>` which runs the OAuth flow and stores refresh+access tokens in your runtime state dir.
- **Custom workplace plugins (CRM, devops, etc.)** → varies. Check the plugin's `.claude-plugin/plugin.json` `onboarding` block; the admin agent walks the same onboarding flow when the operator says "set up `<plugin>` for me".

You should not see real tokens in tracked source. If `agb agent show` tells you `credentials_status: missing`, ask the operator to run the matching `agb setup <channel>` command. Do not paste tokens into a chat — collect them through the wizard so they land in the right runtime state dir with the right file mode.

For the operator-facing setup flow, see [troubleshooting-auth-and-channels.md](./troubleshooting-auth-and-channels.md).

---

## Q4: What to do when a tool returns 401

In rough order of how-often-this-helps:

1. **`agb agent show <my-id>`** → does the failing channel show `runtime_ready: yes`? If `no`, the credentials are missing or stale.
2. **Was the token recently rotated?** Ask the operator to re-run `agb setup <channel> <my-id>` to refresh the stored token.
3. **Is the plugin installed but disabled?** `agb agent show` will say `plugin: installed=yes enabled=no`. The operator must enable it: `claude plugin enable <spec>` (or the equivalent in your engine).
4. **Are you in an isolated UID and reading a path you do not own?** Some channel state dirs are mode 0660 owned by your isolated UID's group. If you tried to read it from a different UID (e.g. cross-agent debugging), you will see `EACCES` long before you see 401. Use the bridge CLI verb (`agb agent show`) rather than direct file reads — see Q5.
5. **MCP server crashed.** `agb status` will surface the orphan in the daemon section. `agb agent restart <my-id>` rebuilds the runtime cleanly.

If steps 1-5 do not resolve the 401, file an issue with the output of `agb agent show <my-id>` attached. Do not start guessing at config edits — channel credential plumbing is the highest-risk surface in the codebase.

---

## Q5: Under linux-user isolation, which files should I avoid reading directly?

You are an isolated UID `agent-bridge-<my-id>` if `id -un` returns that name. Stay out of:

- **Other agents' homes** — `~/.agent-bridge/agents/<other-agent>/` is mode 2770 owned by `ab-agent-<other-agent>`; you cannot read it. Use `agb agent show <other-agent>` if you need any of its state.
- **Controller-only state files** — `~/.agent-bridge/state/active-roster.md`, `~/.agent-bridge/state/HEARTBEAT.md`. Use `agb status` / `agb agent list` instead.
- **Another agent's branch in a shared git checkout** — no `git checkout <other-branch>` in the operator's primary checkout. If you need a clean workspace for a helper operation, use a temp clone.
- **`sudo`** — you do not have sudoers by default. If you need a privileged operation, tell the operator; they will run it from the controller UID.

The full design rationale lives in [CLAUDE.md §"Working with isolated agents (iso v2)"](../../CLAUDE.md#working-with-isolated-agents-iso-v2) and [docs/developer-handover.md §"Working with isolated agents (iso v2)"](../developer-handover.md). Read those once at first wake; you do not need to re-read them every session.

---

## Operator follow-ups (for the human running this agent)

If the agent above is asking you for a value, the answer is almost always one of:

- run `agb setup <channel> <agent>` to seed credentials
- run `agb plugins seed --agent <agent>` to publish controller-side plugins into the isolated tree
- restart with `agb agent restart <agent>` after a sudoers or group-membership change

Do not paste tokens into the chat. Walk the wizard.

---

## See also

- [docs/agent-runtime/common-instructions.md](../agent-runtime/common-instructions.md) — runtime contract every agent reads at session start.
- [docs/plugin-authoring-iso-v2.md](../plugin-authoring-iso-v2.md) — plugin author's contract for iso v2.
- [troubleshooting-auth-and-channels.md](./troubleshooting-auth-and-channels.md) — the operator-side counterpart to Q3/Q4.
