# Known Issues

This file tracks operational caveats that matter when extending the bridge.

## 1. Claude trust prompt on first run

Symptom:

- A fresh Claude session in a new folder may stop at a trust prompt before it accepts normal bridge input

Impact:

- The first interaction may require manual confirmation

Workaround:

- Confirm the trust prompt once in that folder
- Future resume flows can then proceed normally

## 2. Urgent sends still depend on prompt state

Current behavior:

- Claude urgent sends now use literal typing plus submit
- Codex urgent sends still use paste plus submit

Residual risk:

- If the target session is in an unusual TUI state or nonstandard input mode, submit behavior may still vary

Operator guidance:

- Keep urgent messages short
- Prefer queue-based work handoff
- If an urgent send looks stuck, inspect the pane before retrying

## 3. Fresh installs have no static roles

This is intentional.

Impact:

- `bridge-start.sh --list` will show no static roles until a user creates `agent-roster.local.sh`

Operator guidance:

- Use `agent-bridge --codex|--claude --name ...` immediately
- Add local static roles only when they add value

## 4. Runtime state is local and untracked

The following are not committed:

- `state/`
- `logs/`
- `shared/`
- `agent-roster.local.sh`

Impact:

- Another machine will not inherit your live sessions, queue history, or local static roles

Operator guidance:

- Treat these as local runtime state, not deployable source

## 5. Smoke test is synthetic

`scripts/smoke-test.sh` validates:

- shell syntax
- optional shellcheck
- isolated daemon startup
- isolated static role launch
- queue create/claim/done
- list, summary, status, and sync paths

It does not validate:

- real Claude CLI behavior
- real Codex CLI behavior
- model-side resume semantics

Use live smoke sessions for those.

## 6. macOS requires non-system Bash

macOS ships Bash `3.2`, but the bridge uses associative arrays.

Operator guidance:

- Install Homebrew Bash
- Put Homebrew `bin` ahead of `/bin` in your shell `PATH`

## 7. Claude custom channel wake is currently disabled

Current behavior:

- the repo still contains `bridge-channel-server.py`, `bridge-channels.py`, and `lib/bridge-channels.sh`
- the active runtime path does not use them
- Claude wake currently relies on `Stop` hook idle markers plus short idle-only `tmux` sends

Reason:

- `--dangerously-load-development-channels` is not suitable for unattended setup or OSS onboarding because it introduces an interactive trust step

Operator guidance:

- treat the channel helpers as backlog / future capability
- restart Claude sessions after bridge deploys that change idle wake behavior

## 8. `bridge-knowledge search` default auto-switches to hybrid when a v2 index exists

Current behavior:

- with no index present the default path stays legacy regex for backwards compatibility
- once an operator runs `bridge-memory rebuild-index --index-kind bridge-wiki-hybrid-v2`, `bridge-knowledge search` automatically prefers the hybrid engine for that agent
- `--legacy-text` is the explicit opt-out flag that forces the regex path regardless

Reason:

- the hybrid engine is higher quality when the index is available; the auto-switch saves operators from having to remember `--hybrid` on every call

Operator guidance:

- treat "did I build a v2 index?" as the effective toggle
- if result shape changes after an index rebuild, that is expected — rerun with `--legacy-text` to compare

## 9. Teams `/auth/callback` endpoint authenticates by state-token possession alone

Current behavior:

- the Teams plugin exposes `/auth/callback` for the ms365 authorization-code pairing flow
- incoming requests are validated only by the tight state regex (`^[A-Za-z0-9_-]{8,128}$`) and written atomically under `$BRIDGE_HOME/shared/ms365-callbacks/<state>.json`
- there is no separate check that a matching `pair_start` is currently pending

Reason:

- the ms365 plugin generates state as a random UUID with a 15-minute expiry, and `pair_poll` consumes and unlinks the callback file on success or error
- for the hosted/local-only deployment targets this is sufficient in practice, and the atomic file write keeps the endpoint safe against concurrent/partial writes

Operator guidance:

- do not expose the Teams plugin's `/auth/callback` to the public internet without additional ingress-level auth (mTLS, ingress token, IP allowlist)
- if you operate a multi-tenant hosted Teams plugin, layer your own `state` allowlist or HMAC before this handler

## 10. Singleton channel plugins (Telegram / Discord) poll-lock across concurrent agents

Current behavior:

- Telegram and Discord bots enforce one-poller-per-bot-token: only one process at a time may hold the `getUpdates` long-poll (Telegram) or the gateway websocket (Discord). A second connection on the same token gets a `409 Conflict` (Telegram) or a session-kick (Discord).
- Claude Code auto-spawns every `~/.claude/settings.json` `enabledPlugins` entry for every agent session, so absent an override every agent's claude process tries to run its own telegram/discord MCP child. The most recently restarted agent holds the lease; every earlier agent has been silently kicked off.

Fix (applied by default from #244):

- `scripts/apply-channel-policy.sh` writes the shared overlay at `agents/.claude/settings.local.json` so every agent whose `.claude/settings.json` resolves to the shared effective settings gets `telegram@claude-plugins-official` and `discord@claude-plugins-official` explicitly disabled.
- When an admin agent is configured (`BRIDGE_ADMIN_AGENT_ID` in env or roster), the same script writes a per-agent local overlay at `agents/<admin>/.claude/settings.local.json` re-enabling those singleton plugins for the router. Claude Code's settings merge order prefers the project `.claude/settings.local.json` over the project `.claude/settings.json` (the shared-effective symlink), so the admin keeps the channels while every other agent stops contending.
- `bridge-upgrade.sh` re-runs the policy on every upgrade (idempotent).

Operator guidance:

- Run `bash scripts/apply-channel-policy.sh` manually after adding or removing agents if the policy has drifted.
- If you change the admin agent (`BRIDGE_ADMIN_AGENT_ID`), re-run `apply-channel-policy.sh` and then remove `agents/<previous-admin>/.claude/settings.local.json` — the script only writes the new admin's overlay, it does not clean up prior admins.
- If a non-admin agent needs its own DM endpoint, provision a dedicated bot token per agent and add the plugin id to that agent's `.claude/settings.json` explicitly, rather than relying on the shared token.

## 11. Daemon exit observability (historical issue #194 closed by v0.6.x hardening)

Background:

- Issue #194 tracked a v0.4.2 → v0.6.0 upgrade where `launchd` respawned `bridge-daemon` six times in ~24 minutes; the only signal at the time was `mtime` gaps in OPERATIONS log because the daemon left no exit reason in `state/launchagent.log`, `state/daemon.log`, or `logs/audit.jsonl`. The issue body explicitly named "exit observability hook" as a precondition to root-causing the cascade.

Current behavior (from v0.6.x; see commit history of `bridge-daemon.sh`):

- `cmd_run` registers four traps before entering the main loop: `_bridge_daemon_on_signal` for `TERM`/`INT`/`HUP`, `_bridge_daemon_on_err` (under `set -E`) for any `set -e` abort, and `_bridge_daemon_on_exit` for `EXIT`.
- Every loop step writes its name into `BRIDGE_DAEMON_LAST_STEP` (27 distinct values across `load_roster`, `discord_relay`, `bridge_sync`, `queue_gateway`, `nudge_scan`, `plugin_liveness`, `idle_sleep`, etc.).
- On exit the EXIT trap appends a single structured line to `state/launchagent.log` and emits a `daemon daemon_exit` row to `logs/audit.jsonl` carrying `pid`, `exit_code`, `signal`, `last_step`, and `err_location` (file:line of the first ERR-trapped failure). `state/daemon-crash.log` also receives the message on non-zero exit.
- Issue #265's four-part hardening compounds the coverage: per-call `bridge_with_timeout` wrapper around the high-risk subprocess sites including every `tmux send-keys` (PRs #279, #281), periodic `daemon_tick` audit + heartbeat file (PR #274), sibling silence supervisor (PR #293), and OS-level liveness watcher (PR #292). Issues #261/#262 added broken-launch quarantine, #270 closed the stall self-loop, #273 sweeps PPID=1 orphan daemons.
- Result: the three plausible exit scenarios from #194 (`set -e` abort, SIGTERM, supervisor-driven restart cascade) all now leave a complete attribution trail across `launchagent.log` + `audit.jsonl` + `daemon-crash.log`.

Operator guidance:

- After a `launchd`/`systemd` respawn cascade, look first at `logs/audit.jsonl` filtered to `actor=daemon` — every exit pairs `daemon_exit` with the prior `daemon_tick` (showing which loop step was active before the silence), `daemon_subprocess_timeout` (showing which call_site hung), or `daemon_silence_*` (showing supervisor-initiated restarts).
- `state/launchagent.log` keeps the same line in plain text for hosts where the audit log is unreadable.
- The original v0.4.2 → v0.6.0 specific hypotheses in #194 (post-upgrade python helper missing, plugin MCP liveness restart against gone session, librarian cron cascade) refer to code paths that no longer exist in their #194-era form; the chain of fixes above either removed them or made them externally observable. Treat #194 as historical — if a similar respawn cascade reappears on a current install, file a fresh issue with the `daemon_exit` audit excerpt rather than reopening #194.
## 12. Disposable cron child cold-start latency

Current behavior:

- Each native cron fire spawns a fresh `claude -p --no-session-persistence ...` child via `bridge-cron-runner.py`. That child cold-loads the Claude CLI binary, every MCP server wired into the agent's plugin set, and a new session bootstrap.
- On warm hosts this adds several seconds per fire; on memory-pressured hosts (e.g. 8 GB Mac mini) it can push the child past `BRIDGE_CRON_SUBAGENT_TIMEOUT_SECONDS` before user code runs (issue #263).
- Most polling/reminder crons (`event-reminder-30min`, `cs-line-poll-5m`, etc.) never call MCP tools, so the MCP cold-load is pure waste.

Mitigation (applied from #263):

- Per-job opt-in: set `metadata.disableMcp` (or `disable_mcp` / `disposableDisableMcp` / `disposable_disable_mcp`) on a cron job to launch its disposable child with `--strict-mcp-config` and no `--mcp-config`, which loads zero MCP servers. Local benchmark on a warm host: claude `-p` cold start dropped from ~5–10 s real / ~2.9 s user to ~3.2–3.7 s real / ~0.6 s user (~78% CPU saved per fire).
- Ops A/B switch: `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP=1` in the runtime env forces every cron child to skip MCP regardless of per-job config; `=0` forces it on. Unset defers to per-job metadata. Use this to roll the change install-wide before annotating individual jobs.
- Safety override: jobs with `metadata.disposableNeedsChannels=true` (channel-relay flow) keep MCP enabled even when the flag asks otherwise — the relay path still needs channel MCP servers to deliver.

Operator guidance:

- Tag every `*/N`-minute polling cron whose body is "fetch + summarise" with `metadata.disableMcp=true`. Reminder/scheduler families are the highest-leverage targets.
- Leave the flag unset for any cron whose payload calls MCP tools (e.g. plugin-driven research, workspace MCP queries).
- This addresses MCP cold-load only. The CLI binary load and session bootstrap remain per-fire; warm-pool / runtime-substitution work tracked in #263 follow-ups.
## 13. Globally-installed Claude plugins spawn MCP servers in every agent session unless per-agent allowlist is set

Current behavior:

- Every Claude session inherits the user-scoped `~/.claude/plugins/installed_plugins.json` registry, so every plugin's MCP server spawns in every agent. On hosts with 11+ agents and 23+ installed plugins this means ~250 MCP processes and ~1 GB RSS — most of them irrelevant to any given agent's role (see #272).
- Editing `enabledPlugins` directly in `agents/<agent>/.claude/settings.json` does not survive `agb agent restart`: the bridge regenerates that file from the shared effective settings.

Fix (applied by default from #272):

- `scripts/apply-channel-policy.sh` learns a per-agent allowlist key, `BRIDGE_AGENT_PLUGINS["<agent>"]="plugin1 plugin2"` (space- or comma-separated). When set, the script writes `agents/<agent>/.claude/settings.local.json` with `enabledPlugins` set to `false` for every globally-installed plugin not in the allowlist, and `true` for each plugin in the allowlist. The `settings.local.json` overlay survives `agb agent restart` because Claude Code's settings merge prefers it over `settings.json`.
- Plugins declared as channels (`BRIDGE_AGENT_CHANNELS`) are auto-included in the agent's effective allowlist so an oversight in the allowlist does not silently disable a required transport.
- Agents without `BRIDGE_AGENT_PLUGINS` set keep the legacy "all installed plugins enabled" behaviour. Existing rosters do not regress.

Operator guidance:

- Declare an allowlist for each long-lived agent role. Start by listing the plugins the agent actually uses (channel transports, role-specific MCP servers like `syrs-gmail`, etc.) and re-run `bash scripts/apply-channel-policy.sh`.
- Restart the agent to pick up the overlay (`agb agent restart <agent>`).
- The allowlist is enforced at MCP-spawn time via `enabledPlugins=false`, not via `--strict-mcp-config`. A `--strict-mcp-config` track is feasible as a follow-up if `enabledPlugins` is found insufficient on a given Claude Code release; today the overlay is the lowest-risk path because the same machinery already enforces the singleton channel policy.
## 14. Layout v2 retains legacy install-root profile / memory after migration

PR-D's `agent-bridge migrate isolation-v2 commit` does NOT delete profile,
skill, or memory files from `$BRIDGE_HOME/agents/<agent>/` — those are
copied to the v2 workdir with `delete_eligible=0` and the install-root
copies are kept as a frozen snapshot.

Practical effect:

- Edits to `CLAUDE.md`, `MEMORY.md`, `SKILLS.md`, `SOUL.md`, `HEARTBEAT.md`,
  `MEMORY-SCHEMA.md`, `COMMON-INSTRUCTIONS.md`, `CHANGE-POLICY.md`,
  `TOOLS.md`, `SESSION-TYPE.md`, `NEXT-SESSION.md`, `.agents/`, `memory/`,
  `users/`, `references/`, `skills/` after activation must go into the v2
  workdir (`$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`). The install-root
  copy is left in place but goes stale.
- `agent-bridge profile deploy <agent>` writes to the v2 workdir under
  v2 because PR-D ships the matching `bridge_agent_default_profile_home`
  v2 branch (lib/bridge-agents.sh). The two locations therefore can drift
  if an admin hand-edits the install-root copy.

Plan: PR-G will either unify the two locations (single source-of-truth in
the v2 workdir) or mark the install-root copy read-only and point all
admin tooling at the v2 path explicitly.

## 15. `_common.sh` `list_active_claude_agents` retains silent success on malformed JSON

`scripts/_common.sh:71-96` parses `agb agent list --json` with a broad
`try/except: sys.exit(0)` clause, so a malformed JSON payload or a failed
`agb` invocation produces an empty agent list rather than a non-zero exit.

PR-D switched `scripts/wiki-daily-ingest.sh` to a strict inline enumerator
because Lane B silent-zero would have masked v2 memory updates, but it
deliberately did NOT change `_common.sh` to avoid touching every other
caller (`bootstrap-memory-system.sh`, `scripts/wiki-v2-rebuild.sh`,
`scripts/wiki-weekly-summarize.sh`, `scripts/wiki-monthly-summarize.sh`).
Those callers retain the original silent-OK behaviour for now.

A follow-up PR (PR-G review) is expected to flip `_common.sh` to fail-closed
and adjust each caller, replacing the local strict block in
`wiki-daily-ingest.sh` with the shared helper at that point.

## 16. Layout v2 — Claude first-launch login required (PR #641 / v0.8.0)

PR-E (v0.7.x) introduced a transitional ACL-grant surface
(`bridge_linux_grant_claude_credentials_access`) that symlinked the
operator's `~/.claude/.credentials.json` into each isolated agent's
home and granted the per-agent UID an `r--` ACL on the file plus `--x`
traverse on every ancestor up to `controller_home`. PR #641 (v0.8.0,
T2) deletes that helper as part of the v1 ACL hard-cut; the v2 layout
now has no named-user ACL surface at all.

Effect on first launch of a v0.8.0 v2-isolated Linux Claude agent:

- The isolated UID's `$HOME/.claude/` no longer contains a
  `.credentials.json` symlink (or any credentials inherited from the
  operator).
- `agent start` launches `claude` and the binary presents its
  interactive login picker — this is acceptable UX, not a hard fail.
- Operators have two options to seed credentials:
  - run `claude login` once per isolated UID (the planned end-state),
    which writes `$BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude/.credentials.json`
    owned by the per-agent UID; or
  - pre-populate `$BRIDGE_AGENT_ROOT_V2/<agent>/credentials/launch-secrets.env`
    with `CLAUDE_CODE_OAUTH_TOKEN=…` (or another supported Claude env
    credential) before the first launch, in which case the launcher
    consumes the env-var path and skips the picker. The supported helper is
    `agent-bridge auth claude-token add --id <id> --stdin --activate --sync`,
    using a token from `claude setup-token`.

This is the planned end-state described in the PR-E plan — the
credential file lives entirely inside the v2 layout, no path reaches
back into the operator's home, and the `acl` package prerequisite is
dropped for v2 + Claude. The named-user ACL surface that entry 16
previously documented is gone.

Rollback: operators on v0.7.x with the legacy ACL-grant surface can
stay on v0.7.x; v0.8.0 is the cut-over and there is no per-agent
auto-migration of the operator's credential file.

### v0.7 → v0.8 migration ACL leftovers

Pre-v2 installs may carry transitional named-user POSIX ACLs that the
v2 layout does **not** allow (per the §16 hard-cut above — v2 has no
named-user ACL surface at all). The most common leftover is on
`/home/agent-bridge-<agent>/.claude/`, where the v0.7 install left a
`root:agent-bridge-<agent>` ownership + a controller-only `r-x` ACL
that prevents the agent UID from reading its own home.

The planned `agent-bridge migrate isolation v2 --apply` command
(v0.9.0+) detects and strips these leftovers across both
`$BRIDGE_DATA_ROOT/agents/<agent>/...` and
`/home/agent-bridge-<agent>/...`. ACL preservation count: **0**.
The migration is a strip-only pass; no named-user ACL is retained on
either subtree.

If the migration command is unavailable (older install / scripted
environment), manual recovery (run as the controller, with `sudo`
available):

```bash
# ⚠️  Input validation FIRST — never run with empty/invalid agent name.
A="<agent>"
[[ "$A" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "agent name validation failed"; exit 1; }

USER="agent-bridge-$A"
GROUP="ab-agent-$A"
CTRL=$(id -un)

# Sanity check — confirm the user exists and its home matches the
# expected shape. Refuses to run if either is wrong.
getent passwd "$USER" >/dev/null || { echo "no Linux user $USER"; exit 1; }
LINUX_HOME="$(getent passwd "$USER" | cut -d: -f6)"
[[ "$LINUX_HOME" == "/home/$USER" ]] || {
  echo "ERROR: $USER home does not match /home/$USER (got: $LINUX_HOME)"
  exit 1
}

# 1. Re-own the agent's actual Linux home and strip transitional ACLs.
sudo chown -R "$USER:$USER" "$LINUX_HOME"
sudo chmod -R u+rwX,go-rwx "$LINUX_HOME"
sudo setfacl -bR "$LINUX_HOME"

# 2. Realign plugin state files to v3 isolated-UID-owned 0600 contract.
#    (controller accesses via passwordless sudo, not group read).
agent-bridge migrate isolation v3 --apply --agent "$A"

# 3. Create the controller-side .claude/ shadow if missing.
sudo install -d -o "$CTRL" -g "$CTRL" -m 0700 \
  "$BRIDGE_DATA_ROOT/agents/$A/.claude"

# 4. Re-launch and verify.
agent-bridge agent start "$A"
```

The full canonical state table and a deeper drift-recovery reference
live at
[`OPERATIONS.md` § "Isolation v2 canonical state and migration"](./OPERATIONS.md#isolation-v2-canonical-state-and-migration)
and [`docs/agent-runtime/v2-isolation-migration.md`](./docs/agent-runtime/v2-isolation-migration.md).

## 17. Layout v2 requires the engine CLI in a base-readable path (enforcement deferred to runtime)

The v2 group contract has no path INTO the operator's home. If
`which claude` resolves to `~/.local/bin/claude` (or any path under
the operator's chmod-0700 home) on a v2 install, the isolated agent
process cannot resolve the binary — the launcher exec's, the bare
`claude` / `codex` invocation hits a non-readable PATH segment, and
the agent dies with `command not found`.

PR-E's engine-CLI fail-fast (in
`bridge_linux_grant_engine_cli_access`) used to catch this at
`agent-bridge isolate <agent>` time and `bridge_die` with an explicit
"move `claude` to /usr/local/bin" message. PR #641 (v0.8.0, T2)
deleted that helper as part of the v1 ACL hard-cut. The check is now
exclusively runtime — operators see a launcher failure instead of a
prepare-time `bridge_die`, and there is no `bridge_isolation_v2_active`
guard left in `bridge_write_linux_agent_env_file` that warns about the
path either.

Workaround for v2 installs (unchanged): install Claude/Codex
system-wide (`/usr/local/bin`, `/opt/…`, or any path with no
controller-home ancestor). The `npm install -g @anthropic-ai/claude-cli`
flow lands in `/usr/local/lib/node_modules/…` with a
`/usr/local/bin/claude` symlink, which works.

Diagnostic: if `agent start` fails with the launcher reporting
`claude: command not found` (or `codex: command not found`), run
`which claude` as the isolated UID — if the result is under
`/home/<controller>/…` (or any path the per-agent UID cannot read),
the install is in a non-v2-readable location and must be moved.

A future PR may re-introduce the prepare-time fail-fast inline in
`bridge_linux_prepare_agent_isolation`; until then this is a runtime
failure mode.

Legacy v1 mode is gone in v0.8.0 — there is no fallback ACL
traverse-chain that covers the controller-home path.

## 18. Layout v2 swaps the isolated UID's `~/.claude` from 0700 to 2750 group-mode

Before PR-E, the isolated UID's `$user_home/.claude` was created mode
`0700` and the controller (and the memory-daily harvester running as
the controller UID) reached `~/.claude/projects/` via a named-user
default ACL `u:<controller>:r-X` set on that directory. PR-E v2 mode
no-ops `bridge_linux_acl_add` and the default-ACL setfacl, so on v2
the dir would have been left at `0700` with no group access — the
controller could no longer traverse into `projects/`.

Under v2 the isolated `~/.claude` is now `chgrp ab-agent-<agent>` +
`chmod 2750`:

- Owner (the isolated UID): `rwx` — Claude still owns its config tree
  and can write `projects/`, `sessions/`, `settings.json`, etc.
- Group (`ab-agent-<agent>`, which the controller joins via PR-A/B/C
  group plumbing): `r-x` — the harvester can list and read.
- Other: `---`.
- The setgid bit means subdirectories created by Claude later (e.g.
  `projects/<workspace>`) inherit `ab-agent-<agent>` as their group,
  so the harvester walks them without further setup. Combined with
  the v2 umask 007 from `bridge_run_apply_v2_umask_if_needed`, new
  files land at `0660` group-readable.

Legacy mode keeps the prior `0700` + named-user default-ACL contract.

This pairs with the per-agent v2 group prerequisite (every isolated
UID's controller must be in `ab-agent-<agent>` AND `ab-shared`,
ensured by `bridge_linux_prepare_agent_isolation`). On a fresh v2
install the operator needs a re-login (or `newgrp` shell) after the
first `agent-bridge isolate <agent>` so the controller process picks
up the new group memberships; otherwise the harvester scan still
fails until the operator's session refreshes. The same prerequisite
is documented in `OPERATIONS.md`'s v2 install section.

## 19. Daily-backup death-spiral on disk-full hosts (closed by v0.7.2)

Symptom (pre-v0.7.2):

- Overnight, `~/.agent-bridge/backups/daily/` accumulates dozens of
  `agent-bridge-YYYY-MM-DD.tgz.tmp.<pid>` files, each ~1–2 GB. Disk
  fills. `~/.claude.json` is partially written and reported as
  "JSON Parse error: Unable to parse JSON string" by every subsequent
  `claude -p` invocation, breaking wiki / cron jobs even after disk
  space is manually recovered.

Root cause (issue #507):

- Stale tmp files from killed backup attempts were never reaped — the
  cleanup line only removed the *current* PID's tmp.
- No pre-flight free-space check; once the disk crossed ~85% full,
  every subsequent attempt was guaranteed to fail and generate
  another GB-scale orphan.
- `--retain-days` defaulted to 30, so the baseline disk consumption
  was already 45–60 GB on a long-lived install — feeding the spiral.
- `state/tasks.db` (sqlite, binary, ~uncompressible) was bundled raw
  into every daily tarball — multiplying retention with near-zero
  dedup.

Fix (v0.7.2):

- See CHANGELOG `[0.7.2]` and OPERATOR_ACTIONS_PENDING.md
  `v0.7.2 — daily-backup death-spiral root-cause + auto-cleanup`.
  Briefly: glob-delete stale tmp at start of each attempt (lock +
  age-gated), pre-flight free-space check, retain default 30 → 7,
  exclude `worktrees/`/`runtime/{assets,media,extensions}/`/`node_modules`,
  online sqlite snapshot to `state/backup-snapshots/tasks-*.sql.gz`
  instead of raw .db, daemon failure cooldown wiring,
  conservative `backups/upgrade-*/` prune, auto-cleanup migration
  on every `agent-bridge upgrade --apply`.

Recovery (only relevant if you're on a host that hasn't yet upgraded
to v0.7.2 and is currently in the failure mode):

```bash
# 1. Free space immediately
rm -f ~/.agent-bridge/backups/daily/*.tgz.tmp.*

# 2. Restore .claude.json from Claude Code's automatic backups
LATEST=$(ls -1t ~/.claude/backups/*/.claude.json 2>/dev/null | head -1)
[[ -n "$LATEST" ]] && cp "$LATEST" ~/.claude.json && echo "restored: $LATEST"

# 3. Upgrade to v0.7.2 to prevent recurrence
agent-bridge upgrade --apply
```

Operator guidance:

- After upgrading to v0.7.2, the `[upgrade-complete]` task body
  contains an agent-safe verification block confirming backup
  hygiene + daemon state + `~/.claude.json` validity. Run it.

## 20. `daemon.log` frozen on launchd-managed installs (issue #590)

Symptom:

- On macOS hosts where `ai.agent-bridge.daemon` is launchd-managed, the
  plist redirects stdout/stderr to `state/launchagent.log`. Activity
  follows that file; `state/daemon.log` freezes the moment launchd takes
  over and an operator who tails `daemon.log` sees nothing.

Current behavior (post #590):

- `BRIDGE_DAEMON_LOG` defaults to the launchagent log path recorded in
  `state/launchagent.config` when that marker is present, and to
  `state/daemon.log` otherwise. The marker is written by
  `scripts/install-daemon-launchagent.sh --apply` from this version
  forward and captures the actual `--label`/`--plist`/`--log-path` the
  operator chose. Pre-v0.7.X installs need to rerun `--apply` once to
  pick up the new default; operators can also set `BRIDGE_DAEMON_LOG`
  in their environment to override at any time.
- `agb daemon status` prints `log=` always and adds `launchagent_log=`
  only when the operator's `BRIDGE_DAEMON_LOG` resolves to a file
  different from the configured launchagent log, so the status output
  never duplicates itself.
- `bridge-doctor.py` ships a `daemon-log-split` detector that fires when
  the configured log is older than 7 days while `launchagent.log` is
  active, with a `BRIDGE_DAEMON_LOG=...` fix hint in the suggested
  action. The detector reads the launchagent path from
  `state/launchagent.config` when present.

## 21. pending-attention spool can grow unbounded for permanently-stuck agents (#589)

The PreCompact-aware spool re-delivery path (PR #605, refs #589) appends
to `state/agents/<agent>/pending-attention.env` whenever a nudge fires
against a live tmux session that hasn't reached prompt-ready. Existing
deferred-handling marks entries past `BRIDGE_TMUX_INJECT_MAX_DEFER_SECONDS`
as `[deferred]` but does not truncate.

If an agent is permanently stuck (hardware failure, broken Claude binary,
glyph regression preventing prompt detection) AND a cron keeps queuing
tasks against it, the spool file grows without bound. Mitigation: stop
the offending cron, or run `agent-bridge agent stop <agent>` to clear
the spool. Future hardening: a max-line guard on the append helper.

## 22. Layout v2 — rollback hatch via `BRIDGE_DISABLE_ISOLATION=1`

v0.8.0 hard-cuts v1 (named-ACL) isolation: T1 fails fast on legacy
markers, T2 deletes the v1 helpers, T3 wires the migration. If v2
isolation hits an unforeseen issue post-deploy on a specific install,
operators can set `BRIDGE_DISABLE_ISOLATION=1` in the controller
environment and restart the daemon + affected agents to keep work
flowing while debugging.

The hatch disables v2 wraps at runtime — agents run as the controller
UID with no group/setgid contract. The configured `isolation_mode`
stays in the roster, the layout marker is not mutated, and v2 resumes
when the env is unset and the daemon + agents restart. Operations
status surface (`agent-bridge agent show <agent>`, `agent list`)
reports `isolation: disabled-by-env` while the hatch is active.

This is a debugging escape, not a permanent operating mode.
Long-term operation without isolation is unsupported in v0.8.0.
Report the underlying v2 issue upstream. Full operator notes:
[`OPERATIONS.md` "Rollback hatch — `BRIDGE_DISABLE_ISOLATION=1`"](OPERATIONS.md).

## 23. v1→v2 migration leaves the daemon "half-alive" if started from a stale shell (#712)

After a v1→v2 isolation migration, a long-lived shell that predates
the upgrade still carries the kernel-cached pre-upgrade supplementary
group set even though `usermod` has added the operator to
`ab-controller` (and any `ab-agent-*` groups) in passwd. A daemon
spawned from such a shell starts successfully but cannot read
`group=ab-controller mode 0640` state files — `agb status` then
surfaces `bridge-state.sh:997 source "$file": Permission denied`.

`bridge-daemon.sh start` now refuses with a re-login remediation
when the current process is missing v2 groups its passwd entry
includes. Linux-only; installs without `ab-controller` (e.g. macOS,
or a fresh install that hasn't run v2 group setup) pass through
unchanged.

Diagnose:
```
cat /proc/$DAEMON_PID/status | grep ^Groups
id -G
```

Recover (Linux):
```
exec sudo -i -u $USER bash
bash bridge-daemon.sh start
```

Debug-only override: `BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS=1`
(the `Permission denied` errors will return — set only when you
need to inspect a specific failure mode).

## 24. Tool-policy denies `env` / `printenv` env-as-prefix invocations (#799 r3)

The tool-policy pretool gate denies env-dump verbs — `env`,
`printenv`, bare `set`, `compgen -e`, `declare -p` / `declare -x`,
`typeset -p` / `typeset -x`, `export -p`, and any read of
`/proc/<pid>/environ` — as defense-in-depth for stale/manual secret
environment variables. #799's final design no longer delivers Claude
OAuth tokens through `CLAUDE_CODE_OAUTH_TOKEN`; it writes the active
setup token into the selected Claude agent's `.claude/.credentials.json`
file instead. The env-dump deny remains because older deploys or manual
operator exports may still put token material in the process
environment, and literal substring checks only fire when the raw command
names the variable.

Side effect: `env VAR=val cmd` (env-as-prefix) is also denied because
distinguishing it from a bare `env` dump from the raw command string
is unreliable. Use one of the following when you need env-as-prefix
invocations from Bash:

- `/usr/bin/env LANG=C foo` — allowed (the absolute path bypasses
  the bare-word `env` pattern, which uses a `/`-rejecting lookbehind).
- `VAR=val cmd` — allowed (shell-native env-prefix, no `env` verb).
- A wrapper shell script that sets the env and execs the binary —
  allowed (the verb is the wrapper name, not `env`).

`set -e` / `set -o pipefail` / `kubectl set image` / `git remote
set-url` / `setfacl` and other commands that happen to contain `set`,
`env`, or `environment` substrings remain allowed; the patterns are
word-boundary based and require terminator/pipe context after bare
`set`.

## 25. Claude OAuth credential — same-UID FS readability residual (#799 r2-of-Path-A)

The per-agent `.claude/.credentials.json` file is owned by the
isolated agent UID so the Claude CLI can read it. Because the same UID
also runs Bash, Read, and other tool subprocesses, a deliberately
constructed tool call that dynamically enumerates `~/.claude` (e.g.
`python -c 'import pathlib;
print((pathlib.Path.home()/".claude"/".credentials.json").read_text())'`)
can read the credential without matching the hook's literal-substring
deny rules.

Defense-in-depth measures applied in #799 r1-of-Path-A through r2:

- File mode `0o600` owned by the isolated agent UID. No cross-UID
  access from other isolated agents or from the controller's tool UID.
- Atomic chown: the credential / config / settings tempfiles are
  chowned to the isolated UID **before** `os.replace`, so there is no
  transient root-owned window at the final path. See PR #799 r2 codex
  finding 3.
- Symlink hardening: `bridge-auth.sh` rejects a pre-existing
  `.claude` symlink in the agent-owned home and verifies the resolved
  real path stays inside the isolated user home. `bridge-auth.py`
  re-applies the check before any privileged write. See PR #799 r2
  codex finding 2.
- Pretool hook deny list catches literal mentions of `.claude` +
  `.credentials.json`, the registry JSON path, the legacy
  `launch-secrets.env`, the `CLAUDE_CODE_OAUTH_TOKEN` env name, and
  env-dump verbs (`env`, `printenv`, `set`, `compgen -e`,
  `declare/typeset -[xp]`, `export -p`, `/proc/<pid>/environ`). See §24.
- Token rotation limits blast radius — a leaked token is invalidated
  on next rotation via `agent-bridge auth claude-token rotate --sync`.

Residual limit: deliberate exfiltration via dynamic `Path.home()`
enumeration in any interpreter that can read `os.environ`/`%ENV`/`ENV[]`
or open files cannot be caught by literal-substring deny rules without
banning all interpreter use. Path B (the prior env-injection design)
leaked through any interpreter's environment view; the Path A
file-based design contains the leak surface to deliberate
`Path.home()`-relative reads, which is hook-deny-able in the literal
case and rotation-recoverable in the deliberate case.

Optional mitigation: `claude_keychain_free_auth` renders a Claude Code
`apiKeyHelper` that reads the locked OAT registry instead of relying on
Claude Code's macOS login-Keychain fallback. This avoids token env injection
and keeps normal launch-secret files token-free, but it is still a same-UID
oracle: any process running as the agent UID can execute the helper. A
setuid/setgid helper, separate launcher identity, or per-launch ephemeral
delivery would be needed to fully close the same-UID readability gap without
re-introducing env injection.

Operator guidance: this is a defense-in-depth limit, not a fundamental
break. For high-trust deployments where the same-UID readability is
not acceptable (e.g. agents executing arbitrary third-party code under
the tool UID), keep token rotation enabled with a short interval and
treat the per-agent credential as a rotation-controlled secret rather
than a long-lived one.

## 26. Fixed in v0.13.x hotfix wave (2026-05-15)

The following classes of issue are resolved as of v0.13.10. See `CHANGELOG.md` for per-release detail.

### Bash 5.3.9 read_comsub / heredoc_write deadlock chain (footgun #11)

Three variants of the same Bash 5.3.9 wedge blocked `agent-bridge upgrade --apply` on hosts running recent bash. Each variant was discovered only after the previous was fixed:

- **v0.13.7 (PR #890)** — `<<<` here-string variant. Four sites converted to pipe / tempfile reads.
- **v0.13.8 (PR #892)** — parent-`$()`-capture-of-heredoc-stdin variant. New helper `bridge_upgrade_capture_to_var`.
- **v0.13.9 (PR #894)** — producer-side heredoc-write variant. Six leap-path bodies moved to standalone files under `lib/upgrade-helpers/` and invoked with file-as-argv.

Operator impact: post-v0.13.10, v0.7.x → v0.13.x leap completes cleanly on Bash 5.3.9 hosts.

**Outstanding**: 18 python heredoc sites in `bridge-upgrade.sh` (post-apply / alternate-subcommand) deferred to v0.14.x cleanup. Off the apply leap path. See §27 below.

### Markerless-existing-install layout reject (upgrade gate)

v0.7.x installs lack the isolation-v2 marker. Post-v0.8.0 the layout resolver hard-rejected markerless installs, blocking the leap.

- **v0.13.10 Track A (PR #897)** — marker-only fast-path in `bridge_isolation_v2_migrate_apply_for_upgrade`. When invoked under `BRIDGE_UPGRADE_CONTEXT=1` and the roster has no isolated agents in the linux-user sense, the migration writes a wire-compatible v2 marker (mode 0640) without group operations. Works on macOS, Linux, BSD without sudo.

### bridge_agent_workdir shared-mode workdir override (#895, ymprince WSL2)

Pre-v0.13.10: `bridge_agent_workdir` unconditionally returned the v2 anchor regardless of isolation mode, breaking `agb --claude --name <agent>` dynamic spawn UX.

- **v0.13.10 Track C (PR #899)** — branch the v2-anchor override on `bridge_agent_isolation_mode`. linux-user keeps current behavior; shared and default-fallback honor explicit `BRIDGE_AGENT_WORKDIR`. Closes #895.

### v2 scaffold home/ vs workdir/ sibling mismatch (#686)

Originally reported v0.8.5. `bridge_scaffold_agent_home` materialized `home/` but `bridge_agent_workdir` resolved to `workdir/`. Fix landed in PR #685 (v0.8.5). PR #898 (v0.13.10 Track B) added regression smoke. Closes #686.

## 27. Outstanding (carry-over to v0.14.x / stabilization plan)

Tracked but not blocking. See `docs/stabilization-plan-2026-05-15.md` for stage assignments and `docs/audit-2026-05-15.md` for individual file:line evidence.

### 18 deferred python heredoc sites in bridge-upgrade.sh

Per v0.13.10 codex r4 (PR #897), 18 `python3 - <<'PY' …` sites remain:
- Lines 662, 761, 784, 1130, 1243, 1252, 1297, 1308, 1534, 1581, 1798, 2144, 2260, 2266, 2278, 2287, 2313, 2345.

Classification (codex r4 verified):
- **7 sites** alternate-subcommand paths (`--check`, `--analyze`, `--rollback`) — never reached via `--apply`.
- **11 sites** post-apply — install is upgraded before any of these execute.

Cleanup: stabilization plan S10-late + bash-5.3.9 VM verification.

### BRIDGE_LAYOUT=legacy env-leak from old sessions

Long-running shell / tmux sessions started before v0.13.10 may carry stale `BRIDGE_LAYOUT=legacy` env. Resolver hard-dies even when on-disk marker is valid v2.

- **Workaround**: `unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT` or restart parent process.
- **Planned fix**: stabilization plan S2.

### macOS isolation-v2 noise

Stop hooks on macOS emit `[경고] write_agent_state_marker: ensure_matrix_path failed` because the v2 matrix encodes Linux POSIX setgid invariants that don't apply on macOS. Cosmetic; marker write succeeds via fallback.

- **Planned fix**: stabilization plan S2 + S3 (platform-aware discriminator).

### Isolated-agent group setup on macOS

`agent-bridge agent add --isolated` on macOS attempts `dseditgroup` which requires sudo. Without sudo, mid-migration failure leaves install in a broken state.

- **Workaround**: do NOT use `--isolated` on macOS. Use shared-mode.
- **Planned fix**: stabilization plan S6 — explicit error gate.

### Audit findings

See `docs/audit-2026-05-15.md` for the full P0/P1/P2 catalog (31 bug-surface + 17 stability + 20 isolation-v2 top sites + 5 isolation-v2 buried-assumption + 10 refactor + 17 test/doc-drift findings). Each has an owner-stage in the stabilization plan.

## 28. Supplementary group refresh required after first v2 isolated agent

First-time v2 isolated-agent setup on Linux requires the controller's
**supplementary group set** to refresh before the controller can
traverse into the new `ab-agent-<agent>` group's tree. This is a Linux
process-credential behavior — the supplementary group set is
established at login / `setgroups` / `newgrp` and inherited across
fork+exec; a later `usermod -aG` does NOT propagate to already-running
processes, and a plain `exec $SHELL` inside the same shell preserves
the stale set. The symptom looks like a permission bug because the
on-disk group ownership is already correct.

Symptom (observed during #1151 verification on an operator-provided
remote Linux QA host):

- The controller user IS a member of `ab-agent-<agent>` on disk
  (`getent group ab-agent-<agent>` shows it).
- Running controller processes (daemon, operator shell, tmux server,
  hook subprocesses spawned from those parents) still hold the
  pre-add supplementary group set.
- `agent start` / scaffold helpers report `Permission denied` on
  writes into `$BRIDGE_DATA_ROOT/agents/<agent>/` even though the
  filesystem ACL looks correct, and the agent never reaches the
  Claude REPL on first try.

Resolution: log out and log back in (refreshes the full group set in
one go), or `newgrp ab-agent-<agent>` for a single-group refresh in the
current shell, THEN restart the daemon (`agent-bridge daemon restart`,
or `sudo systemctl restart agent-bridge` on a systemd install) so the
daemon inherits the new group set. See
[`OPERATIONS.md` §"Supplementary group refresh after first v2 isolated agent"](./OPERATIONS.md#supplementary-group-refresh-after-first-v2-isolated-agent)
for the full runbook including the systemd / launchd variants.

The defer-guard pattern in PR #1149 / #1151 Track A handles the cases
where the deferral can be applied at code time; this entry covers the
operator-side action that is required regardless of how many code
paths defer correctly, because the group set itself lives in the
kernel process table.

## 29. tmux inject spool MUST stay enabled on iso v2 (#1312 / v0.15.0-beta5-2)

`BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0` is silently destructive on iso v2
installs. With the spool disabled, the daemon's busy-time dispatch path
returns rc=1, and the caller (`bridge_dispatch_notification`) ignores
that rc — the message never enters the queue and is never retried.

This was flagged as **CRITICAL data-loss class** by the patch audit on
2026-05-28 (issue #1312).

Lane ε fix (v0.15.0-beta5-2):

- `lib/bridge-tmux.sh::bridge_tmux_spool_enabled` now refuses to honor
  `=0` on iso v2 installs. The runtime treats the spool as enabled and
  emits a `bridge_warn` (once per process) explaining the refusal.
- `bridge-init.sh` adds an init-time warning so the misconfiguration is
  operator-visible at install/init time, not after the first dropped
  message.
- `lib/bridge-tmux.sh::bridge_tmux_send_and_submit` adds a single
  busy→idle re-check (200ms default) before treating an inject as
  definitely-busy, smoothing out mid-call transitions.
- When the FORCE escape hatch is active and a busy-spool-disabled drop
  still happens, the helper emits a
  `tmux_inject_dropped_spool_disabled` audit row so the dropped message
  has operator-visible evidence.

Escape hatch (last-resort, unsafe):

```bash
export BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1
export BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0
```

The FORCE flag is documented as unsafe — it re-enables the data-loss
class. Only use this for diagnostic runs in an isolated `BRIDGE_HOME`.

Non-iso (legacy) installs are unaffected: `=0` remains a no-op-style
toggle for them since the data-loss vector is iso-v2-specific.

## 30. Closing a daemon attention/outbox-stuck alert with `done` re-mints a fresh task-id (#1425)

The daemon's recurring single-task alerts — the A2A outbox-stuck scan and
the blocked-aging reminder/escalation family — dedupe by **re-binding to an
existing OPEN task with a stable title prefix** (`agb`'s `upsert-open`, which
uses `find_open_task_by_prefix` in `bridge-queue.py`). That prefix lookup
matches **open statuses only** (`queued`, `claimed`, `blocked`). So whichever
way you acknowledge the alert decides whether dedupe holds:

- **`claim`** (or leaving the row open / `blocked`) keeps the row in the
  open-prefix pool, so the next daemon scan **re-binds to the same task-id**
  instead of minting a new one. The alert stops churning while the condition
  persists.
- **`done`** releases the row from the open-prefix pool. If the underlying
  condition is *still live* (e.g. a peer that has been offline since Friday),
  the next scan finds no open row for that prefix and **mints a fresh
  task-id**, re-nudging you. Acknowledging-by-`done` is therefore
  counter-productive for a genuinely-stuck condition — it produces task-id
  churn, not silence.

**Operator guidance:** while the condition is unresolved, `claim` the alert
(or leave it open) so dedupe holds. Use `done` only once the underlying
condition is actually resolved — that is the signal that the alert *should*
disappear and a future occurrence *should* get a new id.

This is documented rather than code-changed on purpose: `find_open_task_by_prefix`
is shared by the blocked-aging upserts, so widening it with a global
"recently-done" window would change close semantics outside the daemon
alerts. A code-side churn suppressor (a daemon-alert-specific `upsert-open`
mode that reuses recently-closed *alerts* without reopening them) would be a
separate, narrowly-scoped follow-up.

## 31. Guard intent-aware credential / shared-alias mention gate descoped from v0.16.4 (#1691)

The planned v0.16.4 relaxation of the intent-aware credential-name and
shared-alias *mention* gate (#1691) was **descoped** after a dual adversarial
review found two distinct real bypasses in the substring-analysis layer. The
gate remains in its current conservatively over-blocking state.

Impact:

- Commands that merely *mention* a protected credential name or shared alias
  in a string argument — without actually reading or writing the protected
  path — may be denied even though they pose no real risk.

Operator guidance:

- Rephrase the command to avoid embedding the protected name in the
  argument string, or use a shell variable to hold the value instead of
  the literal name.
- Will be redone bundled with #1709.

## 32. Protected-path guard misses brace / `$BRIDGE_HOME` spellings (#1709)

The substring-based protected-path gates in `hooks/tool-policy.py` match
against **literal path spellings only**. A command that references a protected
path through a Bash brace expansion (e.g. `${BRIDGE_HOME}/state/...`) or an
unresolved `$BRIDGE_HOME` variable reference is not matched and passes
through unprotected.

Impact:

- Bash commands that use brace or variable spellings for a protected path
  are not caught by the substring gate. This is a **pre-existing** gap; it
  was not introduced by v0.16.4.

Operator guidance:

- The guard is an audit/containment layer, not a sandbox — treat this as
  defense-in-depth rather than a complete enforcement guarantee.
- Tracked upstream as #1709; to be addressed bundled with the #1691 redo.

## 33. Non-Bash admin Read can reach shared secret / private subtrees (#1711)

The v0.16.4 admin peer-home read carve-out (#1692) limits the relaxation to
**Bash** reads only and preserves the deny on shared secret and private
subtrees even for admin. However, the broader guard does not yet enforce the
same least-privilege boundary for non-Bash admin reads (e.g. a direct Read
tool call from an admin session targeting a peer's secret/private subtree).

Impact:

- An admin agent using the Read tool directly (rather than a Bash
  `cat`/`head`/etc.) can still reach peer secret/private material that the
  Bash path now denies. Over-permissive rather than data-loss.

Operator guidance:

- Treat admin sessions with the same operational discipline as before —
  access only what is needed; prefer the queue and bridge CLI over direct
  cross-agent reads.
- Tracked as #1711; a follow-up will align the non-Bash path with the
  #1692 Bash least-privilege model.

## 34. Queue-gateway client waits for the real response instead of false-failing a busy round-trip (#1837 / #1834)

Under the file-transport queue gateway (`socket_listener=off`, the default),
the daemon polls each agent's requests/ dir every ~5s, renames a request to
`<id>.working.json` before processing it, and **always** writes a
`responses/<id>.json` carrying the queue child's real exit code (including the
idempotent `task already done` → 0). Under burst load that response arrives
late, so the CLIENT'S read timed out and `cmd_client` raised
`queue gateway timed out` + exit 1 even though the write had committed.
Autonomous callers treated the committed write as a failure and **retried**,
piling on more request files and compounding the contention into a
self-reinforcing thrash (#1837). #1834 is the same surface: transient 1–6×
per-call timeouts against a live daemon, with no built-in retry.

Key boundary fact: `cmd_client` runs **only** as an isolated-agent UID, whose
env sets `BRIDGE_TASK_DB=/dev/null` + `BRIDGE_GATEWAY_PROXY=1` so the agent
cannot touch the controller task DB directly (the entire reason the gateway
exists; see `lib/bridge-agents.sh` "BRIDGE_TASK_DB is sentineled" / #287 /
#294). So the client has exactly one authoritative outcome signal — the
daemon's response file — and the fix is to **wait long enough to read it**, not
to guess the outcome from a DB it cannot read:

- **Bounded read-side retry (#1834 + #1837 keystone).** Before declaring a read
  timeout the client re-polls a few extra windows with growing backoff. The
  daemon's response carries the real exit code, so once the bounded wait reads
  it the client returns that **real** code (idempotent `already done` → 0
  included) instead of a false exit 1 — the keystone is "read the real response,
  don't give up early," never "assume the write landed." The retry only waits
  for the response; it never re-queues a fresh write (that re-queue is the very
  thrash being fixed), and the request the daemon may still be draining as
  `<id>.working.json` is untouched. Tunable via
  `BRIDGE_QUEUE_GATEWAY_READ_RETRIES` (default 3) and
  `BRIDGE_QUEUE_GATEWAY_READ_BACKOFF_SECONDS` (default 0.5).
- **Honest timeout, never a fabricated success.** When the bounded retry still
  exhausts without a response, the client surfaces the real timeout (nonzero)
  and removes the now-stale `<id>.request.json` so the next CLI call does not
  pile a duplicate request on top. It never returns a success the daemon did
  not actually report — the iso UID has no way to confirm an outcome other than
  the response file.
- **Daemon-down primitive (`gateway_daemon_liveness`).** A tri-state
  `up` / `down` / `unknown`. From an iso UID that cannot read the controller's
  daemon pid file, it returns **`unknown`** (not a false `down`) — status
  presentation must render that as "unknown", never "down" (#1837 symptom 3).
  The pid-file path follows the canonical resolution (`BRIDGE_DAEMON_PID_FILE`
  when set, else `<BRIDGE_STATE_DIR>/daemon.pid`), so relocated/custom-pid-file
  installs are read correctly. Exposed as the
  `bridge-queue-gateway.py daemon-liveness [--format json]` subcommand for A3
  (#1833 status presentation) to consume across the boundary.
- **Status health is anchored on that primitive (#1833, wave v0.16.10 A3).**
  `bridge-daemon.sh status` derives its headline and `health:` verdict from
  `bridge_daemon_liveness` (lib/bridge-state.sh) — shell pid resolver first,
  then the `daemon-liveness` primitive — never from whether a queue-gateway
  call timed out. A transient gateway timeout against a live daemon reports
  `health=ok` (with `daemon_liveness=up`); an unreadable pid file (iso v2
  boundary) reports `health=unknown` + `daemon_liveness=unknown`, never a
  false `health=down`. `down` is reserved for a provably dead/absent daemon
  pid. The Python dashboard (`agb status`, bridge-status.py) likewise treats
  EPERM-on-signal as "process exists", and its resolver is tri-state
  (`daemon_status_tri`): a BLOCKED `daemon.pid` read consults the primitive
  and renders `daemon unknown pid=-` (JSON: additive `daemon.state` key;
  `daemon.running` stays a bool, false for unknown) instead of the historical
  false `stopped pid=-`. Regression smoke:
  `scripts/smoke/1833-status-gateway-timeout-not-down.sh`.

This is the client contract only; the daemon's write path is unchanged.
