# Architecture

This repository is a local orchestration layer for Claude Code and Codex sessions running inside `tmux`.

## Read This First

If you are resuming development, read in this order:

1. [`README.md`](./README.md)
2. [`ARCHITECTURE.md`](./ARCHITECTURE.md)
3. [`docs/developer-handover.md`](./docs/developer-handover.md)
4. [`OPERATIONS.md`](./OPERATIONS.md)
5. [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md)
6. [`AGENTS.md`](./AGENTS.md)

## Core Model

There are two kinds of agents:

- Static roles: defined in `agent-roster.sh` or `agent-roster.local.sh`
- Dynamic agents: created with `agent-bridge --codex|--claude --name ...`

Static roles are optional. Fresh installs ship with an empty static roster.

Tracked long-lived agent profiles live under `agents/`. That tree is the portable source of truth for prompt text and future per-agent memory or skill directories; machine-local launch wiring still lives in the roster.

## Main Entry Points

- [`agent-bridge`](./agent-bridge): operator-facing CLI for status, task queue, urgent sends, worktree listing, and dynamic agent launch
- [`agb`](./agb): shorthand wrapper that delegates to `agent-bridge`
- [`bridge-start.sh`](./bridge-start.sh): start a static role inside `tmux`
- [`bridge-run.sh`](./bridge-run.sh): loop or one-shot launcher inside the tmux session
- [`bridge-task.sh`](./bridge-task.sh): shell wrapper around the SQLite queue
- [`bridge-profile.sh`](./bridge-profile.sh): tracked agent profile status, diff, and deploy
- [`bridge-cron.sh`](./bridge-cron.sh): legacy cron inventory, error reports, queue adapters, and stale one-shot cleanup wrapper
- [`bridge-send.sh`](./bridge-send.sh): urgent-only direct message path
- [`bridge-action.sh`](./bridge-action.sh): send predefined actions like `/resume`
- [`bridge-daemon.sh`](./bridge-daemon.sh): background sync and heartbeat loop
- [`bridge-sync.sh`](./bridge-sync.sh): reconcile active tmux sessions into live bridge state
- [`bridge-status.sh`](./bridge-status.sh): compact TUI-style dashboard
- [`bridge-lib.sh`](./bridge-lib.sh): thin loader that sources the shell modules under [`lib/`](./lib)
- [`bridge-queue.py`](./bridge-queue.py): persistent queue and daemon-side bookkeeping
- [`bridge-cron.py`](./bridge-cron.py): legacy cron inventory parsing, recurring error reports, metadata export, and cleanup pruning
- [`bridge-handoff-daemon.sh`](./bridge-handoff-daemon.sh): A2A cross-bridge handoff lifecycle (receiver daemon start/stop/status + delivery-runner tick)
- [`bridge-handoffd.py`](./bridge-handoffd.py): A2A receiver daemon — tailnet-bound HTTP listener that HMAC-verifies + enqueues remote handoffs
- [`bridge-a2a.py`](./bridge-a2a.py): A2A CLI (`send` / `outbox` / `inbox-dedupe` / `peers` / `deliver`) reached through `agent-bridge a2a ...`

## Shell Module Layout

Shared Bash implementation is split under [`lib/`](./lib):

**Core modules**

- `bridge-core.sh`: generic helpers, hashing, queue wrapper, and path utilities
- `bridge-agents.sh`: roster accessors, active-agent queries, worktree preparation, session kill helpers, `bridge_agent_workdir` resolver (post-#895 honors isolation_mode), `bridge_agent_isolation_mode` lookup
- `bridge-tmux.sh`: tmux session I/O and submit helpers
- `bridge-skills.sh`: project-local skill generation and migration of older managed skill directories
- `bridge-state.sh`: roster loading, dynamic/static agent persistence, session-id detection, and daemon snapshots
- `bridge-cron.sh`: legacy cron path helpers, family-aware default slots, target resolution, and enqueue manifests
- `bridge-hooks.sh`: Claude / Codex hook ensure + status, shared-settings symlink, `bridge_claude_settings_mode` source-aware classifier
- `bridge-channels.sh`: channel discovery, per-channel webhook port allocation, dynamic + static channel state writes
- `bridge-cleanup.sh`: cleanup payload renderer (v0.13.6 PR #886 — heredoc-free fixture path)

**Isolation-v2 stack** (added v0.8.0+, expanded through v0.13.x)

- `bridge-marker-bootstrap.sh`: layout marker validator + reader; runs before `bridge-layout-resolver.sh` so the resolver sees a parsed marker (or env fallback)
- `bridge-layout-resolver.sh`: decides BRIDGE_LAYOUT (v2 only as of v0.8.0); fail-fast on `legacy` env; markerless-existing-install detection; fresh-install bypass handshake
- `bridge-isolation-v2.sh`: matrix-driven path enforcement (groups, modes, setgid); platform-aware (POSIX setgid on Linux; Darwin no-op stubs in many ensure paths)
- `bridge-isolation-v2-migrate.sh`: layout migration entry; v0.13.10 added the marker-only fast-path for markerless-existing-install + no-isolated-roster (Track A PR #897)
- `bridge-isolation-v2-reapply.sh`: standalone reapply / verify CLI for matrix rows; Linux-only platform-gated at entry
- `bridge-isolation-runtime.sh`: per-launch runtime helpers (secret-env exec wrapper with umask 0007)
- `bridge-isolation-v3-channel-dotenv.sh`: channel `.env` secret-store ACL helpers (POSIX named-user ACL on Linux; macOS no-op)
- `bridge-isolation-helpers.sh`: shared primitives reused across the v2/v3 stack (write-as-agent, sudo-handoff predicates)
- `bridge-migration.sh`: per-agent migration entry for the `migrate-agents` subcommand; Linux-only via `bridge_migration_require_linux`
- `bridge-host-profile.sh`: per-host capability snapshot (uname, sudo availability, group tooling) consulted by isolation gates

**Upgrade helpers** (added v0.13.9, expanded through v0.13.10)

`lib/upgrade-helpers/` holds standalone scripts invoked by `bridge-upgrade.sh` with file-as-argv (no heredoc-stdin → no footgun #11 Bash 5.3.9 deadlock). Each file replaces a former `<<EOF`/`<<'PY'` heredoc body that wedged the leap path:

- `channel-guard-report.sh` (bash heredoc → standalone)
- `channel-guard-json.py` (python heredoc → standalone)
- `agent-restart-json.py` (python heredoc → standalone)
- `recorded-source-root.py` (inline python heredoc → standalone)
- `isolation-v2-migrate.sh` (inline bash heredoc → standalone)
- `emit-failure-json.py` (python heredoc → standalone, EXIT-trap path)

**Wave orchestration**

- `bridge-wave.sh`: wave-orchestration runtime support (used by skill `wave-orchestration`)

**A2A cross-bridge handoff** (added v0.15.0-class, issue #1032)

- `bridge-a2a.sh`: receiver-daemon + delivery-runner lifecycle helpers sourced by `bridge-handoff-daemon.sh` (pid-file tracking, fail-closed preflight, outbox-drain tick)
- `bridge_a2a_common.py` (repo root, not under `lib/`): shared A2A module — wire protocol, HMAC signing scheme, data-only JSON config loader, durable `outbox.db` / `inbox.db` SQLite schemas. Imported by both `bridge-a2a.py` and `bridge-handoffd.py`. See [`docs/a2a-cross-bridge.md`](./docs/a2a-cross-bridge.md).

## State Layout

Runtime state lives under `state/` and is intentionally untracked:

- `state/tasks.db`: SQLite queue plus agent heartbeat state
- `state/active-roster.tsv` and `state/active-roster.md`: current live roster snapshot
- `state/agents/`: dynamic agent metadata
- `state/history/`: persisted resume metadata for static and dynamic agents
- `state/worktrees/`: metadata for managed isolated workers
- `state/profiles/`: deploy manifests for tracked agent profiles
- `state/daemon.pid` and `state/daemon.log`: daemon process tracking
- `state/handoff/`: A2A cross-bridge handoff working dir — `outbox.db` (sender), `inbox.db` (receiver dedupe), `incoming/` + `outgoing/` staged bodies (mode 0600), `handoffd.pid`

Human or agent handoff text belongs in `shared/`. Operator logs belong in `logs/`.

## Agent Lifecycle

### Dynamic

`agent-bridge --codex --name dev` or `agent-bridge --claude --name tester`:

1. Resolve workdir from the current directory unless `--workdir` is given
2. Optionally install a project-local bridge skill
3. Persist dynamic metadata under `state/agents/`
4. Start a tmux session
5. Detect and persist the native Claude or Codex session id when possible

### Static

`bridge-start.sh <agent>`:

1. Read the tracked roster and optional local override roster
2. Resolve tmux session name, workdir, launch command, loop mode, and actions
3. Persist state and start the tmux session

## Queue-First Collaboration

Normal inter-agent work should flow through the queue, not direct chat.

Queue operations:

- `create`
- `inbox`
- `show`
- `claim`
- `done`
- `handoff`
- `summary`

The queue backend stores:

- tasks
- task events
- agent_state snapshots used by the daemon

This makes the system durable across tmux restarts and daemon restarts.

## Heartbeats And Nudges

The daemon does not call an LLM on every loop. It polls local state only:

- tmux session presence
- tmux activity timestamps
- task assignments and leases
- last-seen timestamps for agents

When an idle active agent has queued work and its cooldown window has passed, the daemon sends a short nudge into the tmux session.

## Direct Messages

`bridge-send.sh` is restricted to urgent paths. This is intentional.

- Queue for normal work
- Urgent direct messages for interrupts only

Claude uses a literal typing path for submit reliability. Codex continues to use bracketed paste plus submit.

## Worktree Isolation

If multiple writers need to act on the same git repo, `agent-bridge --prefer new` creates a managed git worktree under:

`~/.agent-bridge/worktrees/<repo-slug>/<agent>`

Metadata for those worktrees is stored in `state/worktrees/`.

## Cron Reporting Contract

Disposable cron children do not own a user-facing channel and never write to one directly. The cron reports through the **inbox-only contract**: the runner emits a structured task to the cron's parent agent (`target_agent`, usually the operator-attached main session), which then decides whether to absorb it silently or forward it through its own channel plugin.

```
                     ┌──────────────────────────────────────────────┐
                     │          parent agent (main session)         │
                     │                                              │
   external channels │   ↑ Telegram (in/out via official plugin)   │
   ◀────────────────►│   ↑ Discord  (in/out via official plugin)   │
                     │   ↑ Mattermost (in/out via plugin)          │
                     │                                              │
                     │   ── reads inbox tasks (from cron) ──        │
                     │   ── routes to channel based on frontmatter ─│
                     └──────────────────────────────────────────────┘
                                          ▲
                                          │ agent-bridge inbox task
                                          │ (one per non-silent run)
                                          │ frontmatter: delivery_intent, forward_target, …
                                          │
                     ┌──────────────────────────────────────────────┐
                     │   cron child (claude -p / codex exec)        │
                     │   - no channel plugins                       │
                     │   - --strict-mcp-config unconditionally      │
                     │   - if no signal → log + exit (silent)       │
                     │   - if signal → write inbox task + exit      │
                     └──────────────────────────────────────────────┘
                                          ▲
                                          │ cron schedule fires
                                          │ bridge-cron-runner.py
```

### Result schema (PR1)

`bridge-cron-runner.RESULT_SCHEMA` requires every cron child to declare:

- `delivery_intent`: `silent | main_session_only | forward_to_user`. Required.
- `summary_short`: required when `delivery_intent != silent`, ≤200 chars.
- `forward_target`: required when `delivery_intent = forward_to_user`. Object `{channel, target_ref, format}` where `channel ∈ {telegram, discord, mattermost, …}`, `target_ref` is a logical name (not a chat id), `format ∈ {markdown, text}`.

Per-job overrides live on `metadata`:

- `cronReportingPolicy = default | always_main_session | always_silent` — force a particular reporting outcome regardless of what the child decided. The runner demotes any non-success `final_state` to `reporting_decision = invalid` so failures are never silently swallowed (Codex r2 fix on PR #499).
- `cronUrgency = normal | high | urgent` — priority hint for the resulting inbox task.

### Inbox task contract (PR1 + PR2)

When `delivery_intent != silent`, the runner writes a `[cron-followup]` queue task to `target_agent` with a strict JSON-frontmatter body:

```
---
{
  "schema_version": 1,
  "kind": "cron-followup",
  "delivery_intent": "...",
  "run_id": "...",
  "job_id": "...",
  "job_name": "...",
  "family": "...",
  "target_agent": "<parent>",
  "reporting_policy": "default | always_main_session | always_silent",
  "forward_target": { "channel": "...", "target_ref": "...", "format": "..." },
  "summary_short": "<≤200 chars>",
  "legacy_structured_relay": true
}
---

# [cron-followup] <job-name>
... markdown body ...
```

Parent agents parse this body via `lib/bridge_cron_followup.parse_followup` (Python stdlib only — PyYAML deliberately not used so the consumer matches the runner's stdlib-only constraint). On parse failure the consumer falls back to legacy prose handling — see [`docs/agent-runtime/common-instructions.md` §"Cron Followup Handling"](docs/agent-runtime/common-instructions.md#cron-followup-handling) for the full algorithm.

### Dedupe semantics

Two task title formats encode the dedupe rule:

- `[cron-followup] <job> [main_session_only]` — refresh-by-job. The runner calls `bridge-queue.py find-open --mode refresh-by-job`; if a prior open task exists for the same job, the runner updates the body in place so the parent always sees the *current* state of this monitor (not a backlog of identical absorptions).
- `[cron-followup] <job> (run=<run_id>)` — per-run. Every distinct human-facing alert lands as a fresh task. The runner *never* overwrites an unread `forward_to_user` task.

### Audit trail

The runner writes the reporting trio to both `result.json` and `status.json` under each `state/cron/runs/<run_id>/`:

- `reporting_decision`: `silent | reported | invalid`
- `delivery_intent`: same as the child's chosen / policy-overridden intent
- `inbox_task_id`: queue task id, or `null` for silent runs

`bridge-cron.py:run_native_finalize` mirrors the trio onto the job state (`lastReportingDecision`, `lastDeliveryIntent`, `lastInboxTaskId`) so `agb cron show` and `agb cron list --json` expose the cron → inbox → main flow without grepping run dirs.

The daemon's followup gate (`bridge-daemon.sh` `case "$CRON_REPORTING_DECISION"`) reads the trio via `bridge_cron_load_run_shell`:

- `silent` / `reported` → daemon clears `CRON_NEEDS_HUMAN_FOLLOWUP` (runner already handled or intentionally silent).
- `invalid` / empty → daemon's existing failure-followup path runs (so a malformed result or missing field is never lost).

## Hooks / Tool Policy

`hooks/tool-policy.py` is the per-tool-call gate that enforces per-agent
isolation, audited mutation of protected paths, and prompt-guard
sanitization. Together with `hooks/bridge_hook_common.py` it is the
containment/audit layer (not a sandbox — see CLAUDE.md "High-Risk
Areas" item 5).

### Agent class

Each agent has a class (`user` by default; `system` opt-in via roster).

- `user` — per-agent isolation; cross-agent reads denied.
- `system` — read-only access to other agents' `memory/{projects,
  decisions,shared}/` subtrees and to `shared/*` (excluding
  `shared/private/` and `shared/secrets/`). `Bash`, `Edit`, and `Write`
  outside the agent's own home stay denied even for `system`. Every
  cross-agent read emits a `system_cross_agent_read` row to
  `audit.jsonl` so the operator retains a full ledger.

Class is declared in the roster (`BRIDGE_AGENT_CLASS["<agent>"]="system"`
in `agent-roster.local.sh`) — runtime cannot change it. Unknown class
values hard-fail at roster load. The shipped public roster declares
no system-class agents; operators add `BRIDGE_AGENT_CLASS["…"]="system"`
to their librarian / patch agents locally. The bash side exposes the
value via `bridge_agent_class`; the calling agent's class is exported
to hook subprocesses as the `BRIDGE_AGENT_CLASS_FOR_HOOK` scalar
(distinct name to avoid colliding with the bash associative array).

## Configuration Surface

Important environment variables:

- `BRIDGE_HOME`
- `BRIDGE_ROSTER_FILE`
- `BRIDGE_ROSTER_LOCAL_FILE`
- `BRIDGE_STATE_DIR`
- `BRIDGE_TASK_DB`
- `BRIDGE_DAEMON_INTERVAL`
- `BRIDGE_HEALTH_WARN_SECONDS`
- `BRIDGE_HEALTH_CRITICAL_SECONDS`
- `BRIDGE_WORKTREE_ROOT`
- `BRIDGE_LEGACY_HOME`
- `BRIDGE_SOURCE_CRON_JOBS_FILE`
- `BRIDGE_CRON_STATE_DIR`

Use them for isolated testing and for machine-specific installs.

## Development Notes

- The tracked roster should stay generic
- Private machine paths belong in `agent-roster.local.sh`
- Runtime directories are not source files
- Cross-platform behavior assumes Bash 4+, tmux, Python 3, and git
- Multi-tenant per-UID isolation is Linux-only; macOS runs shared mode
  plus hook-layer hardening only (see
  [`docs/platform-support.md`](./docs/platform-support.md))
- Linux-user isolation uses POSIX group + setgid exclusively (v2). v0.8.0
  hard-cut the legacy named-user-ACL mode (v1): `bridge_resolve_layout()`
  fails fast on `BRIDGE_LAYOUT=v1`/`legacy` and the v1 ACL helper surface
  (`bridge_linux_grant_*`, `bridge_linux_acl_*`,
  `bridge_linux_repair_*`) is fully removed in T2 (PR #641). Runtime
  contract: per-agent group `ab-agent-<name>`, isolated home at
  chmod 2750/2770 setgid, agent launches under `umask 007`, controller
  UID joined to every per-agent group via `usermod -aG` (Linux) or
  `dseditgroup` (Darwin). The `acl` package is no longer required and
  no named-user ACL surface remains for Claude credentials — operators
  seed credentials with `claude login` per isolated UID or pre-populate
  `$BRIDGE_AGENT_ROOT_V2/<agent>/home/credentials/launch-secrets.env`.
  See `OPERATIONS.md` "Layout v2 migration" for the upgrade-integrated
  migration tool (PR #640) and "Rollback hatch — `BRIDGE_DISABLE_ISOLATION=1`"
  for the runtime escape (PR #648). `KNOWN_ISSUES.md` §16/§17 cover
  the Claude first-launch login flow and the base-readable engine CLI
  prerequisite. The v2 isolation runtime lives in
  `lib/bridge-isolation-v2.sh` + `lib/bridge-isolation-runtime.sh`.
