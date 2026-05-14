# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Agent Bridge is a thin local orchestration layer that wires Claude Code and Codex sessions together over `tmux` + SQLite queue + a Bash daemon. It does not implement its own agent runtime — Claude/Codex are the agents. Design priorities, in order, are **queue-first**, **daemon-safe**, and **runtime-preserving**.

## Read These Before Editing

These four files hold the context that is not derivable from the code:

1. [`ARCHITECTURE.md`](./ARCHITECTURE.md) — entry points, shell module layout, queue/state boundaries.
2. [`docs/developer-handover.md`](./docs/developer-handover.md) — concrete "where/how to edit" walkthrough and the biggest foot-guns.
3. [`OPERATIONS.md`](./OPERATIONS.md) — live-install behavior and upgrade contract.
4. [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md) — live-session quirks (trust prompt, urgent-send edge cases, channel wake status).

[`AGENTS.md`](./AGENTS.md) is the repo-guidelines doc — treat it as authoritative for style.

## Source Checkout vs Live Runtime (critical)

Never confuse these two trees:

- **Source checkout** (where you usually are): this git repo. Canonical location is `~/.agent-bridge-source`, but `~/Projects/agent-bridge-public` is also supported via `AGENT_BRIDGE_SOURCE_DIR` / `agent-bridge upgrade --source ...`.
- **Live runtime**: `~/.agent-bridge`. Contains `state/`, `logs/`, `shared/`, `agents/<name>/` runtime homes, `agent-roster.local.sh`, the queue DB, and daemon state. Do **not** commit anything derived from live runtime into the source tree, and do **not** hand-copy source files over live runtime — use `agb upgrade` (see OPERATIONS.md).

Generated / runtime artifacts that should never be edited as source: `state/`, `logs/`, `shared/` (live), `agents/<name>` runtime homes.

## Queue-First Is a Contract

Normal inter-agent work goes through `bridge-task.sh` / the SQLite queue. `bridge-send.sh` and `bridge-action.sh` are for *urgent interrupts only*. Any change that touches queue semantics, roster loading, session resume, worktree handling, cron behavior, or the upgrader is high-risk and must include manual verification notes in the PR.

Tracked source must stay machine-agnostic. Machine-specific roster overrides, channel IDs, tokens, and private team data belong in `agent-roster.local.sh` (git-ignored), never in tracked files.

## Layout at a Glance

- Root `bridge-*.sh` and `bridge-*.py`: primary CLI entry points. New logic should generally go into a `lib/bridge-*.sh` helper rather than growing root scripts.
- [`lib/`](./lib): shared Bash implementation (`bridge-core.sh`, `bridge-agents.sh`, `bridge-tmux.sh`, `bridge-state.sh`, `bridge-cron.sh`, `bridge-skills.sh`, `bridge-hooks.sh`).
- Python is used for structured work: queue backend (`bridge-queue.py`), cron inventory (`bridge-cron.py`), docs/audit/intake/dashboard helpers.
- [`agents/`](./agents): tracked portable agent profile templates (not runtime homes).
- [`scripts/`](./scripts): install + smoke + deploy helpers.

## Common Commands

There is no build step.

**Validation before a PR (required):**

```bash
bash -n *.sh agent-bridge agb lib/*.sh scripts/*.sh
shellcheck *.sh agent-bridge agb lib/*.sh scripts/*.sh agent-roster.local.example.sh
./scripts/smoke-test.sh
```

`scripts/smoke-test.sh` runs isolated daemon/queue/static-role checks without touching live bridge state. It does **not** exercise real Claude/Codex CLI behavior — changes to tmux submit paths, hooks, prompt state, or urgent-send logic require a live manual check in an isolated `BRIDGE_HOME`.

**Inspecting bridge state during development:**

```bash
./agent-bridge status              # dashboard
./agent-bridge list                # agent inventory
bash bridge-daemon.sh status       # daemon
bash bridge-daemon.sh sync         # force a reconciliation pass
bash bridge-start.sh --list        # static roles
bash bridge-start.sh <role> --dry-run
```

**Queue smoke flow:**

```bash
bash bridge-task.sh create --to tester --title "t" --body "b"
./agent-bridge inbox tester
./agent-bridge claim <id> --agent tester
./agent-bridge done  <id> --agent tester --note "ok"
```

**Dynamic agent / worktree:**

```bash
./agent-bridge --codex --name smoke --workdir /tmp/demo --no-attach
./agent-bridge --codex --name worker-a --prefer new    # isolated git worktree
./agent-bridge worktree list
```

**Release preflight (when touching shipped surface):**

```bash
bash ./scripts/oss-preflight.sh
```

## Environment Variables Worth Knowing

- `BRIDGE_HOME` — override live runtime root; essential for isolated tests.
- `AGENT_BRIDGE_SOURCE_DIR` — tell the upgrader where the source checkout is when it's not at `~/.agent-bridge-source`.
- `BRIDGE_ROSTER_FILE`, `BRIDGE_ROSTER_LOCAL_FILE`, `BRIDGE_STATE_DIR`, `BRIDGE_TASK_DB`, `BRIDGE_WORKTREE_ROOT`, `BRIDGE_CRON_STATE_DIR`.

## High-Risk Areas (edit with care)

1. **Queue / daemon / status** — strongly coupled; touching one usually needs re-checking the other two.
2. **`lib/bridge-tmux.sh`** — Claude and Codex have different submit semantics; urgent sends are sensitive to prompt state (trust, blocker, copy-mode).
3. **Upgrade path (`bridge-upgrade.sh`, `bridge-upgrade.py`, `scripts/deploy-live-install.sh`)** — must preserve `state/`, `logs/`, `shared/`, local roster, and live agent homes. The upgrader must also tolerate non-standard source-checkout paths.
4. **Worktree isolation (`state/worktrees/`, `~/.agent-bridge/worktrees/<repo>/<agent>`)** — getting this wrong can corrupt a shared repo or run an agent against the wrong branch.
5. **Hooks / tool policy / prompt guard (`hooks/`, `bridge-hooks.py`, `bridge-guard.py`)** — containment/audit layer, not a sandbox. Changes here affect every Claude session's settings.

## Platform Notes

- Requires Bash 4+ (associative arrays). macOS ships Bash 3.2 — install Homebrew Bash and put it ahead of `/bin` in `PATH`.
- Requires `tmux`, `python3`, `git`.
- If shell integration was installed from a source checkout, moving the checkout requires rerunning `scripts/install-shell-integration.sh --apply` so the rc-managed block re-points.

## Editing Principles

- Prefer small, targeted changes over refactors. `AGENTS.md` style applies.
- Prefer adding a `lib/bridge-*.sh` helper over growing root scripts.
- If you change documented behavior, update the corresponding doc (`README.md`, `ARCHITECTURE.md`, `OPERATIONS.md`, `KNOWN_ISSUES.md`, or `docs/developer-handover.md`) in the same change.
- Do not put private team names, channel tokens, or machine paths into tracked files — this repo is a public snapshot.

## Multi-Issue Work — Evaluate Wave Orchestration First

Before processing 2+ open issues / PRs / tracks (or any work with back-references to multiple GitHub items), evaluate whether the `wave-orchestration` skill applies. The full decision matrix and dispatch contract live in [`docs/agent-runtime/common-instructions.md`](./docs/agent-runtime/common-instructions.md) under *Multi-Item Work — Wave Orchestration 평가*. Headlines:

- 2+ disjoint issues, Track A/B/C splits, or large changes that benefit from per-track PRs → invoke the skill, write per-track briefs, dispatch fixers in parallel via `Agent` with `isolation: "worktree"` + `run_in_background: true`.
- Single small bug / typo / <50 LOC / interactive review → direct edit, do not invoke the skill.
- Same-file/same-function conflicts → serialize, never dispatch overlapping fixers in parallel.
- The directive applies to admin, static, dynamic, and cron sessions. Dynamic agents on ad-hoc work should re-evaluate when hidden back-references appear in the task body.

## Working With Codex Reviewers

This repo is normally operated by Claude + one or more Codex agents running side by side. The full collaboration contract lives in [`AGENTS.md` §"Multi-Agent Collaboration"](./AGENTS.md). The pieces you need to remember as a Claude author:

1. **Never touch another agent's branch in the shared worktree.** Do not run `git checkout <other-branch>`, `git commit --amend`, `git reset`, or `git worktree prune` in the operator's primary checkout. If you need a clean workspace for a helper operation (e.g. verifying a Codex-authored PR), do it in a temp clone. Codex sessions themselves are expected to run inside their own `--prefer new` worktree; assume they do, and do not hand them paths inside your own.
2. **Pair-review every non-trivial PR.** Default reviewer is `agb-dev-codex-2`. Workflow:
   - Write a review brief to `/tmp/agb-<pr-number>-codex-review.md`: background, focus checklist, expected output shape (`implement-ok` / `needs-more: …`).
   - Queue it: `bash bridge-task.sh create --from agb-dev-claude --to agb-dev-codex-2 --title "[PR #<N> review] <subject>" --body-file /tmp/agb-<pr-number>-codex-review.md`.
   - Wait for the `[task-complete]` notification, `agb claim`, read the completion note.
   - If `needs-more: …`, fix and enqueue the next round with a bumped title (`[PR #<N> re-review]`, then `r3`, etc.) and its own brief file. Each round is a fresh `bridge-task create`, not an edit of the prior task.
   - Merge only after the final reviewer note opens with `implement-ok`. Codex may squash-merge itself when the operator has granted that permission; otherwise you perform the merge.
3. **Release PRs change only `VERSION` + `CHANGELOG.md`.** Keep them on a `release/vX.Y.Z` branch. Same pair-review contract. `git tag -a vX.Y.Z` goes on the merge commit, never on the feature branch.
4. **Branch naming.** `fix/<slug>` for bug fixes, `feat/<slug>` for new capability, `release/vX.Y.Z` for version bumps, `docs/<slug>` for doc-only changes. Keep one PR per branch; rebase to `main` rather than piggy-backing on another open PR (that was the source of the #235 "stacked on #232" confusion on 2026-04-24).
5. **When a review round loops more than 3 times** without an `implement-ok`, stop and reconsider scope before continuing — that's usually a signal the PR is touching too much surface or the spec is ambiguous; a `codex-spec` round on the originating issue is often cheaper than another code round.

Codex cannot observe your local worktree, so reproducibility is on you: include the exact path, env, and command in the review brief and the PR description — not just the symptom. Assume Codex will rerun your verification from scratch.
