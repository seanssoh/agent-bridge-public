# Troubleshooting — auth and channels

Audience: an operator whose agent is up but whose channel does not work yet, or whose channel worked yesterday and now returns 401 / silent-drops / "credentials missing". Goal: walk the decision tree without grepping source.

If the agent itself is the one asking the question, point it at [plugin-enabled-agent.md](./plugin-enabled-agent.md) instead.

---

## Start here: read `agent show`

```bash
agb agent show <agent>
```

The output has a `channel_diagnostics:` block per required channel:

```text
channel_diagnostics:
  - channel: plugin:teams@agent-bridge
    provider: teams
    plugin: installed=yes enabled=yes status=enabled spec=teams@agent-bridge
    launch_allowlisted: yes
    runtime: state_dir=/path/to/state access=ok credentials=missing ready=no
```

Walk the rows top-to-bottom. The first failing row is your starting point — the rows below it often cascade.

The `next_actions:` section at the bottom of `agent show` synthesizes the diagnostics into concrete commands. Try those first; the rest of this page is for when the hint did not resolve the issue.

---

## Decision tree by symptom

### `plugin: installed=no`

The plugin is missing from this agent's view. Two causes:

- **Shared-mode agent on a fresh install** → run `agb upgrade --check` to confirm the source checkout is current, then `agb agent restart <agent>` to re-resolve plugins.
- **Isolated agent** → the controller-side plugin is not visible to the isolated UID. Run `agb plugins seed --agent <agent>` to publish into the isolated marketplace.

If `installed=no` after a seed, check `agb status` for plugin-marketplace errors and [KNOWN_ISSUES.md](../../KNOWN_ISSUES.md) for current quirks.

### `plugin: installed=yes enabled=no`

The plugin is published but not enabled in this agent's engine config.

- **Claude engine** → `claude plugin enable <spec>` (or whatever the engine prints in its diagnostics). The admin can do this on the agent's behalf: ask `agb admin` "enable the `<spec>` plugin for `<agent>`".
- **Codex engine** → enable in the codex config and restart the agent.

### `launch_allowlisted: no`

The channel is listed in the agent's roster but not in the launch-allow list. Almost always means the roster was edited by hand. Fix:

```bash
agb agent update <agent> --channels-set <comma-separated-canonical-channels>
```

Use the canonical `plugin:<name>@<source>` form. `agb agent show` prints the form your agent expects.

### `credentials_status: missing`

You have not yet seeded credentials for this channel. Run the matching setup wizard:

- Discord → `agb setup discord <agent>`
- Telegram → `agb setup telegram <agent>`
- Teams (Microsoft 365 OAuth) → `agb setup teams <agent>`
- Custom workplace plugin → see the plugin's `onboarding` block in `plugin.json`, or ask `agb admin` to walk it.

Do **not** edit channel state files by hand. The wizard sets file mode, ownership, and group correctly for the isolation mode you are in. A hand-pasted token at the wrong mode will be silently unreadable by the isolated UID and you will chase a credentials-missing loop.

### `credentials_status: controller-blind`

The controller cannot read the channel state from the isolated UID (mode 0660, foreign group). `runtime_ready` will say `indeterminate`. This is normal for iso v2 — it does not mean credentials are missing, only that the controller cannot verify them from its UID.

To verify, ask the agent itself (`agb agent show` from inside the iso UID will show `credentials=ok` if they are seeded) or run `agb doctor --agent <agent>` which uses the privileged probe path.

### `runtime: ready=no` with everything else green

The MCP server for this channel has not come up yet. Common causes:

- Daemon group-membership refresh did not run after channel creation → see the `daemon_group_refresh:` line in the create output and run its recovery command.
- MCP server crashed → `agb status` will surface the orphan. `agb agent restart <agent>` rebuilds.
- Stale state from a previous session → `agb agent restart <agent> --force` (the force flag clears stale state files; use sparingly).

### 401 from a previously-working channel

The token rotated or expired.

- Discord/Telegram bot token → re-run `agb setup <channel> <agent>` to overwrite the seeded token.
- Microsoft 365 OAuth → the refresh token may have been invalidated. Re-run `agb setup teams <agent>` to walk the OAuth flow again.

### Silent drops (no 401, but messages don't arrive)

Usually one of:

- **Daemon down** → `agb status` shows the daemon section red. `bash bridge-daemon.sh restart` (or `systemctl --user restart agent-bridge-daemon.service` on systemd hosts).
- **Wake status frozen** → `agb agent show <agent>` shows `wake_status: …` not `ok`. The wake path is a known sensitive area; see [KNOWN_ISSUES.md](../../KNOWN_ISSUES.md).
- **Channel filter** → check the channel-specific allowlist (Discord channel ID, Telegram chat ID). The wizard collects these at setup; a wrong ID silently drops without error.

---

## When credentials must not leak into tracked files

A recurring foot-gun: an operator tries to "save time" by pasting a token into `agent-roster.sh` (tracked) instead of letting the wizard write to runtime state. The wizard exists for a reason:

- The tracked roster is **machine-agnostic** and gets pushed to the public repo.
- The wizard writes to **`agent-roster.local.sh`** (git-ignored) or to channel state dirs with the right group / mode for your isolation mode.
- Channel state dirs are mode 0660 / 2770 under iso v2; the wizard knows how to chgrp/chmod through the bridge sudo path.

If you are asked for a value, walk the wizard. If a doc tells you to paste a value directly into a tracked file, that is a documentation bug — file an issue.

---

## Escalation: when `agent show` does not explain it

```bash
agb doctor                 # cross-cutting: sudoers, groups, marker files, daemon health
agb status --all-agents    # who is queued / claimed / blocked
bash bridge-daemon.sh status
bash bridge-daemon.sh sync # force a reconciliation pass
```

If still stuck, file an issue with the output of `agb agent show <agent>` + `agb doctor` attached. Include your isolation mode (shared / linux-user) and the platform (macOS / Linux distro). Do not include tokens, channel IDs, or host paths — redact those before filing.

---

## See also

- [README §Discord 연결하기](../../README.md#discord-연결하기) — happy-path setup walk-throughs.
- [docs/channels/](../channels/) — per-channel design notes.
- [KNOWN_ISSUES.md](../../KNOWN_ISSUES.md) — live-session quirks.
- [OPERATIONS.md §Iso v2 agent troubleshooting](../../OPERATIONS.md) — iso v2 grant matrix.
