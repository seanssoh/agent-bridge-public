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

## Shell Module Layout

Shared Bash implementation is split under [`lib/`](./lib):

- `bridge-core.sh`: generic helpers, hashing, queue wrapper, and path utilities
- `bridge-agents.sh`: roster accessors, active-agent queries, worktree preparation, and session kill helpers
- `bridge-tmux.sh`: tmux session I/O and submit helpers
- `bridge-skills.sh`: project-local skill generation and migration of older managed skill directories
- `bridge-state.sh`: roster loading, dynamic/static agent persistence, session-id detection, and daemon snapshots
- `bridge-cron.sh`: legacy cron path helpers, family-aware default slots, target resolution, and enqueue manifests

## State Layout

Runtime state lives under `state/` and is intentionally untracked:

- `state/tasks.db`: SQLite queue plus agent heartbeat state
- `state/active-roster.tsv` and `state/active-roster.md`: current live roster snapshot
- `state/agents/`: dynamic agent metadata
- `state/history/`: persisted resume metadata for static and dynamic agents
- `state/worktrees/`: metadata for managed isolated workers
- `state/profiles/`: deploy manifests for tracked agent profiles
- `state/daemon.pid` and `state/daemon.log`: daemon process tracking

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
- Linux-user isolation has two access-control modes governed by
  `bridge_isolation_v2_active`:
  - **legacy**: per-isolated-UID named-user POSIX ACLs (`u:agent-bridge-<name>:r-x`
    + traversal chains). Requires the `acl` package on every agent host.
  - **v2 (PR-A → PR-E)**: per-agent group + setgid (`ab-agent-<name>`,
    chmod 2750/2770) plus `umask 007` on agent launches. v2 retains a
    single named-user ACL surface for Claude credentials
    (`bridge_linux_grant_claude_credentials_access`) because the
    operator's `~/.claude/.credentials.json` lives outside the v2
    layout — see `OPERATIONS.md` "v2 ACL contract (PR-E)" for scope and
    `KNOWN_ISSUES.md` §16/§17 for the transitional exception and the
    base-readable engine CLI prerequisite.
