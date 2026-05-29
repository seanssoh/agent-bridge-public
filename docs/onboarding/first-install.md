# First install — your first hour

Audience: a person who just finished the installer flow in [README.md](../../README.md) and is now sitting at a prompt with no idea what to do next. Goal: get to "install complete + one useful agent created" without reading source.

If you have not yet installed, go back to [README §시작하기](../../README.md#시작하기) first. This page picks up after `bash bridge-bootstrap.sh ...` has succeeded.

---

## Five-minute summary

```text
agb admin                  # talk to the admin agent — your primary surface
agb status                 # one-glance dashboard of the daemon + agents
agb agent list             # who is registered, who is active
agb doctor                 # surface install / channel / isolation issues
agb agent show <agent>     # per-agent diagnostics + next_actions hints
```

Anything else you wanted to do — create a static agent, connect a Discord channel, restart a wedged session — is something `agb admin` can do for you in plain language. The admin agent is the operator surface; the rest of the CLI is the recovery surface for when the agent is asleep or wedged.

---

## What you actually need to know

### 1. Source checkout vs live runtime

There are two trees on your disk:

- **Source checkout** at `~/.agent-bridge-source` (or `~/Projects/agent-bridge-public` if you set `AGENT_BRIDGE_SOURCE_DIR`). This is the git checkout. Hands off unless you are contributing source. See [CLAUDE.md](../../CLAUDE.md) for the contributor contract.
- **Live runtime** at `~/.agent-bridge`. This is where your daemon, queue, agent homes, channel state, and local roster live. Everything `agb` reads/writes goes here.

When you upgrade, you do **not** copy source files manually. Use `agent-bridge upgrade` — the upgrader preserves `state/`, `logs/`, `shared/`, agent homes, and your local roster. See [OPERATIONS.md](../../OPERATIONS.md) for the upgrade contract.

### 2. `agb admin` is the user surface

After install, `agb admin` opens a tmux session attached to the admin agent (default `patch`). From there, you talk to the agent in natural language:

- "create a static agent named writer that reads my Discord"
- "the queue looks stuck, what's going on"
- "show me what's failing in setup"

The admin can run every CLI verb on your behalf. You should not need to memorize the verbs unless you are recovering from a wedge.

### 3. Diagnostics flow when something is incomplete

When you finish install and feel like something is missing, in this order:

```bash
agb status                 # daemon running? agents idle? queue depth ok?
agb agent list             # do my expected agents appear?
agb agent show <name>      # per-agent: channel ready? credentials present? session healthy?
agb doctor                 # cross-cutting: sudo grants, group memberships, marker files
```

`agb agent show` carries a `next_actions:` section when it detects a missing piece — e.g. credentials not seeded, plugin not enabled, broken-launch marker present. Each entry has a concrete `run:` line and a one-sentence `reason:`. Run those before asking the admin.

### 4. Site-specific values come from the setup wizard

This repo is a public snapshot. Tokens, channel IDs, tenant identifiers, team-private names, host paths — none of these have defaults in tracked docs and you should not infer them. The flow for any site-specific value is:

1. The admin agent asks you for it during `agb setup <channel>` or `agb setup agent`.
2. The value lands in your local runtime config (`agent-roster.local.sh`, `~/.agent-bridge/state/...`, or channel-specific dotenv).
3. The runtime config is git-ignored.

If a doc tells you to paste a token from a public source, that is a documentation bug — file an issue.

---

## After the five-minute summary

Pick the next runbook by what you want to do:

- **Create your first static agent.** → [create-static-agent.md](./create-static-agent.md)
- **Plug a Claude agent into Discord/Telegram/Teams.** → [README §Discord 연결하기](../../README.md#discord-연결하기) then run `agb setup discord <agent>` (or `setup telegram` / `setup teams`).
- **Have a plugin-enabled agent and the runtime feels off.** → [plugin-enabled-agent.md](./plugin-enabled-agent.md)
- **Channel credentials are missing or 401s are happening.** → [troubleshooting-auth-and-channels.md](./troubleshooting-auth-and-channels.md)

---

## Common foot-guns in the first hour

- **macOS Bash 3.2.** Agent Bridge requires Bash 4+. Install Homebrew Bash (`brew install bash`) and prefer it in `PATH` ahead of `/bin`. The installer warns you, but the warning is easy to miss.
- **Shell rc not reloaded.** `bridge-bootstrap.sh` prints a `rc_reload_command` at the end. If you skip it, `agb` may not be on your `PATH`. Open a fresh terminal or run the printed command exactly — do not invent your own reload.
- **Hand-copying source to live runtime.** Do not. Use `agent-bridge upgrade`. See [OPERATIONS.md §Upgrade contract](../../OPERATIONS.md).
- **Editing files under `~/.agent-bridge/` as if they were source.** Live runtime is generated. Edit the source checkout (or, for site-specific overrides, `agent-roster.local.sh` and channel dotenv files).

---

## Further reading (when you need it, not before)

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — the moving parts.
- [docs/agent-runtime/admin-protocol.md](../agent-runtime/admin-protocol.md) — how the admin agent thinks.
- [KNOWN_ISSUES.md](../../KNOWN_ISSUES.md) — quirks you may hit at the prompt.
