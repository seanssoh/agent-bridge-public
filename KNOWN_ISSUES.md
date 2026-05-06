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
  - pre-populate `$BRIDGE_AGENT_ROOT_V2/<agent>/home/credentials/launch-secrets.env`
    with `ANTHROPIC_API_KEY=…` before the first launch, in which case
    the launcher consumes the env-var path and skips the picker.

This is the planned end-state described in the PR-E plan — the
credential file lives entirely inside the v2 layout, no path reaches
back into the operator's home, and the `acl` package prerequisite is
dropped for v2 + Claude. The named-user ACL surface that entry 16
previously documented is gone.

Rollback: operators on v0.7.x with the legacy ACL-grant surface can
stay on v0.7.x; v0.8.0 is the cut-over and there is no per-agent
auto-migration of the operator's credential file.

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
