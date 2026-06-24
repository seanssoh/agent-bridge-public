# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Audience**: a code contributor (you, when editing source). This file is the **repo contributor contract** — source-vs-runtime boundaries, queue semantics, high-risk surfaces, validation/release rules.

**If you are an operator / first-time installer / agent at first wake**: this is the wrong file. Read [docs/onboarding/](./docs/onboarding/) instead — persona-based runbooks for first-install, creating a static agent, plugin-enabled-agent first-session checklist, and channel/auth troubleshooting. Then come back here if you also need to edit source.

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
- [`lib/`](./lib): shared Bash implementation. Core modules: `bridge-core.sh`, `bridge-agents.sh`, `bridge-tmux.sh`, `bridge-state.sh`, `bridge-cron.sh`, `bridge-skills.sh`, `bridge-hooks.sh`, `bridge-channels.sh`, `bridge-cleanup.sh`. Isolation-v2 stack (v0.8.0+): `bridge-marker-bootstrap.sh`, `bridge-layout-resolver.sh`, `bridge-isolation-v2.sh`, `bridge-isolation-v2-migrate.sh`, `bridge-isolation-v2-reapply.sh`, `bridge-isolation-runtime.sh`, `bridge-isolation-v3-channel-dotenv.sh`, `bridge-isolation-helpers.sh`, `bridge-migration.sh`, `bridge-host-profile.sh`. See `ARCHITECTURE.md` §"Shell Module Layout" for the full annotated list.
- [`lib/upgrade-helpers/`](./lib/upgrade-helpers) (v0.13.9+): standalone scripts invoked by `bridge-upgrade.sh` with file-as-argv to bypass the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). Six files: `channel-guard-report.sh`, `channel-guard-json.py`, `agent-restart-json.py`, `recorded-source-root.py`, `isolation-v2-migrate.sh`, `emit-failure-json.py`. **Anti-pattern**: do NOT add new `<<EOF` / `<<'PY'` heredoc-stdin to subprocess in `bridge-upgrade.sh` — extract to a standalone helper instead. See `KNOWN_ISSUES.md` §26.
- Python is used for structured work: queue backend (`bridge-queue.py`), cron inventory (`bridge-cron.py`), docs/audit/intake/dashboard helpers.
- A2A cross-bridge handoff (v0.14.5-beta4+): `bridge-handoff-daemon.sh` + `lib/bridge-a2a.sh` (receiver/runner lifecycle), `bridge-handoffd.py` (tailnet-bound receiver daemon), `bridge-a2a.py` (`agb a2a` CLI), `bridge_a2a_common.py` (wire protocol + HMAC + data-only config loader + outbox/inbox SQLite schemas). See `docs/a2a-cross-bridge.md`.
- [`agents/`](./agents): tracked portable agent profile templates (not runtime homes).
- [`scripts/`](./scripts): install + smoke + deploy helpers.

## Recent critical patches (v0.13.7-v0.13.10, 2026-05-15)

A 4-cycle hotfix wave + bundled v2-isolation cleanup landed on 2026-05-15. Read these if touching upgrade / isolation / scaffold code:

- **v0.13.7-v0.13.9**: three variants of the same Bash 5.3.9 `read_comsub`/`heredoc_write` deadlock (footgun #11). Each release unblocked the next leap step; v0.13.9 closed the chain by extracting heredoc bodies to `lib/upgrade-helpers/`.
- **v0.13.10**: 3-track bundle — Track A (PR #897) markerless-existing-install marker-only migrate; Track B (PR #898) v2 scaffold regression smoke; Track C (PR #899) `bridge_agent_workdir` isolation-mode branch (#895 ymprince WSL2 OSS user).

Current stabilization roadmap: `docs/stabilization-plan-2026-05-15.md` (mandatory read for any post-v0.13.10 session). Audit ground truth: `docs/audit-2026-05-15.md`.

**Version policy** (operator directive 2026-05-15): stabilization PRs do NOT bump VERSION/CHANGELOG. The next release PR is operator-cued and batches accumulated user-visible items. See plan §"Version policy".

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

## Releases require explicit operator permission

**Never cut a version release (VERSION bump + CHANGELOG entry + release/vX.Y.Z PR + tag) without the operator's explicit go**, even if you have broad autonomy on the work that would go into it. "Handle items 1-N autonomously" or "you decide" or similar standing autonomy does NOT include the release ship itself. Operator's standing directive (2026-05-17): batch fixes accumulate freely; the operator cues the release.

Acceptable: prep VERSION + CHANGELOG drafts, run codex-rescue review on a release branch, leave the PR open for operator to merge. NOT acceptable: squash-merge the release PR or push the `vX.Y.Z` tag without an explicit "go release" or equivalent from the operator.

**A release is not done at the tag — sync the docs index in the same session** (operator directive 2026-05-31). After the `vX.Y.Z` tag lands, update `README.md`'s top block to the new version: the `**Current version**` line, the one-line **Headline** (name the release's marquee feature + notable fixes), and the `Recommended upgrade target` + leap-path. Then confirm any new feature's usage docs are current (`OPERATIONS.md`, `docs/developer-handover.md`, `docs/<feature>-design.md`). This is a **separate `docs/vX.Y.Z-...` PR** — the release PR itself stays VERSION + CHANGELOG only (see "Working With Codex Reviewers" point 3). Why it matters: installing agents and patch read the README headline + feature docs — *not* the CHANGELOG — to discover and correctly use new capabilities, so a stale README ships new features invisible (v0.15.1's `agb setup template-sync` had 0 README refs right after the cut until PR #1435).

## Release Lines & LTS Policy

Agent Bridge runs an **LTS line + mainline**, not a single moving tag. Full policy: [`docs/release-lines.md`](./docs/release-lines.md). Headlines (operator-decided 2026-06-08 with the v0.16.2 LTS cut):

- **Every v0.16.x release is an LTS release.** The current LTS-line head is **v0.16.4** (2026-06-09); v0.16.2 was the first declared LTS (2026-06-08) — both designations stand; a new patch supersedes the prior as line head without revoking its LTS status. An LTS is a blessed stable tag (release title `(LTS)` + README marker) that conservative/production installs pin to.
- **One line until features diverge.** Until the first new *feature* lands there is a single line (`main`); the v0.16.x **hardening** sequence (v0.16.3, …) rides `main` and *is* the LTS line. Do **not** fork a maintenance branch prematurely.
- **Fork trigger** = the first real new feature: branch `release/0.16-lts` from the latest `v0.16.x` tag, bump `main` to `v0.17.0-beta`. New features → **beta first** (existing rule), never onto the LTS line.
- **Support window**: an LTS gets fixes **until the next LTS is declared**.
- **Backport criteria** (LTS branch only): security · data loss · upgrade/rollback breakage · fleet-host-down regression. **Not** features/cosmetic/perf-only/refactors. Fix on `main` first, cherry-pick back only if it qualifies.
- **Versioning**: LTS = patch bumps (v0.16.3 …); mainline features = minor (v0.17.0 …). Bump size is the operator's call (small-bumps preference); a capability-add in a patch is allowed when operator-directed.
- **Channel enforcement (gap being closed in v0.16.3)**: `--channel stable` (default) resolves to the *highest global* tag today, so shipping v0.17.0 would auto-pull every default install off the LTS. v0.16.3 adds an **`lts` channel** (version-line pin → latest `v0.16.x`); it must ship on the v0.16.x line so LTS installs can pin. Prod installs track `lts`.
- **Ownership**: one dev orchestrator + the codex pair own *both* lines; the fleet are consumers. A dedicated LTS agent is only warranted post-fork when feature + backport work compete — and then via a **worktree**, not a separate clone/folder.
- **Branch hygiene — `release/X.Y-lts` is protected; force-pushes are CI-gated.** Treat the LTS branch like `main`: a `--force`/`--force-with-lease` push whose resulting HEAD has **not** passed CI is prohibited. Prefer branch protection (required green CI check + force-push block/gate); floor until then = hold the push, confirm the HEAD is green, *then* push (LTS-cut preflight checklist item). An un-verified force-push leaves the branch HEAD broken even when the tagged release is fine — it ships invisibly to the *next* patch cut. This class has recurred 3× (bad cherry-pick merge; wholesale ci-select copy referencing absent smokes; force-pushed lint-baseline regressions). See [`docs/release-lines.md`](./docs/release-lines.md) §"Branch hygiene".

## Environment Variables Worth Knowing

- `BRIDGE_HOME` — override live runtime root; essential for isolated tests.
- `AGENT_BRIDGE_SOURCE_DIR` — tell the upgrader where the source checkout is when it's not at `~/.agent-bridge-source`.
- `BRIDGE_ROSTER_FILE`, `BRIDGE_ROSTER_LOCAL_FILE`, `BRIDGE_STATE_DIR`, `BRIDGE_TASK_DB`, `BRIDGE_WORKTREE_ROOT`, `BRIDGE_CRON_STATE_DIR`.
- A2A: `BRIDGE_A2A_CONFIG` (override `handoff.local.json` path), `BRIDGE_A2A_TAILSCALE_CLI` (explicit `tailscale` binary path), `BRIDGE_A2A_OUTBOX_DB` / `BRIDGE_A2A_INBOX_DB`, `BRIDGE_A2A_ALLOW_TEST_BIND` (loopback test bind — never in production).

## High-Risk Areas (edit with care)

1. **Queue / daemon / status** — strongly coupled; touching one usually needs re-checking the other two.
2. **`lib/bridge-tmux.sh`** — Claude and Codex have different submit semantics; urgent sends are sensitive to prompt state (trust, blocker, copy-mode).
3. **Upgrade path (`bridge-upgrade.sh`, `bridge-upgrade.py`, `scripts/deploy-live-install.sh`)** — must preserve `state/`, `logs/`, `shared/`, local roster, and live agent homes. The upgrader must also tolerate non-standard source-checkout paths.
4. **Worktree isolation (`state/worktrees/`, `~/.agent-bridge/worktrees/<repo>/<agent>`)** — getting this wrong can corrupt a shared repo or run an agent against the wrong branch.
5. **Hooks / tool policy / prompt guard (`hooks/`, `bridge-hooks.py`, `bridge-guard.py`)** — containment/audit layer, not a sandbox. Changes here affect every Claude session's settings.
6. **A2A receiver (`bridge-handoffd.py`, `bridge_a2a_common.py`)** — the only component that handles untrusted *remote* traffic. The fail-closed tailnet bind, HMAC verification, `remote_addr` check, allowlist, and dedupe are security-critical; never weaken the bind proof or expose `--skip-companion-validate` to remote peers.

## Working with isolated agents (iso v2)

On Linux hosts that have linux-user isolation enabled (the v0.8.0+ iso v2 stack), every agent runs as a dedicated OS user `agent-bridge-<a>` with a primary group `ab-agent-<a>`. The controller (your normal shell) is intentionally NOT a member of those groups — that boundary is what keeps one agent's credentials/runtime out of another agent's reach. The cost is a handful of "permission denied" surprises if you treat iso agents the same as shared-mode agents. Keep these rules in mind when working in or against an iso v2 agent:

- **Read-restricted paths from inside an iso UID.** An iso agent cannot read the controller's `~/.agent-bridge/state/active-roster.md`, `HEARTBEAT.md`, other agents' home directories, or files under another iso UID's runtime. Anything CLAUDE.md guides "go look at active-roster.md" must be reachable through a bridge CLI verb (e.g. `agb agent list`, `agb status`) — not direct fs read.
- **Permission dance on shared files.** Cross-class state files (per-agent metadata, shared marketplaces) use a controller-published pattern: controller writes as root with `chgrp -h ab-agent-<a>`, mode 2770 dirs / 0660 files. Use `bridge_iso_run` / `agent-bridge iso-run` for every controller→iso boundary read/write; do NOT direct-touch iso-owned paths from controller code (`KNOWN_ISSUES.md` §"iso v2 boundary").
- **Body files cross the same boundary.** A body file written by an iso UID at mode 0660 owned by `agent-bridge-<a>` is not readable by the controller UID unless it has `ab-agent-<a>` group membership. `bridge-task.sh create --body-file <path>` and `agb a2a send --body-file <path>` automatically fall back to `sudo -n -u <owner> cat <path>` when the direct read raises `PermissionError` (Issue #1280). If that fallback also fails, the operator workaround is `sudo chmod 0644 <path>` before the send.
- **Recommended flow for iso agents.** Use the queue (`agb task create`) for inter-agent work; use `agb a2a` for cross-bridge handoffs. Avoid direct `git checkout` into another agent's branch, avoid editing files in another agent's home, and avoid relying on `sudo` from inside an iso UID (no sudoers entry by default).
- **Known restrictions, summarized.**
  - No direct read of controller HOME state files (active-roster.md, HEARTBEAT.md).
  - No direct write into another agent's home / workdir.
  - No `git checkout <other-branch>` in the operator's primary checkout.
  - No `sudo` from inside an iso UID without explicit operator sudoers grant.

### Agent's own POV: what blocks where + workaround

The rules above are written from the controller's perspective. If you are the iso v2 agent itself (running under `agent-bridge-<a>` on a Linux host with v2 isolation active), here is the same boundary expressed as the paper-cuts you will actually hit on a fresh session, with the supported workaround for each. The compressed five-row form lives in `agb agent show <a>` output as the `iso_boundary_quickref:` section; this table is the long form with concrete commands and error strings. Common paper-cuts catalogued: body_file direct read, controller HOME files, shared/wiki reads, plugins-cache mcp.json edits, cross-iso sudo, and cross-branch git checkout in the operator's primary checkout. Test ground truth: `v0.15.0-beta5-2` `test_clean` fresh-install observation (Issue #1357).

| Attempt | What you'll see | Workaround |
|---|---|---|
| `cat <bridge_home>/state/queue/bodies/<id>.md` (path printed by `agb show <id>`) | `Permission denied` (body owned by `<controller-user>:ab-shared`, you are group member but not owner; controller-side queue paths also restrict at the directory boundary) | The body is already inlined in `agb show <id>` output — read it from there. The `body_file:` row is for the controller's own scripting, not for you. |
| `cat <bridge_home>/state/active-roster.md` | `Permission denied` | `agb agent list`, `agb status` |
| `cat <bridge_home>/state/HEARTBEAT.md` | `Permission denied` | `agb status` (same surface, daemon-rendered) |
| `cat <bridge_home>/shared/wiki/...` | `OK` (`ab-shared` group readable) | Direct read is fine; no CLI verb required |
| Edit `<bridge_home>/plugins-cache/<marketplace>/<plugin>/.mcp.json` | `EACCES` (mode 0640 `<controller-user>:ab-shared`, you are group member but not owner) | Ask the operator to run controller-side `agb plugins seed` (or the marketplace-specific seed) and then restart you. Most plugins ship as stdio proxies that look up tokens at call time, so direct `.mcp.json` edits are rarely the right answer anyway. |
| Plugin call returns `401` / `Authentication required` on first use | (no traceback, just the API error) | The plugin's own onboarding skill is the source of truth (e.g. `cosmax-crm:onboarding` for CRM, `plugin:teams:configure` for Teams). If unclear, surface the 401 to the operator via the queue — do not hand-fabricate auth state. |
| `sudo -u <other-iso> ...` from inside your UID | `sudo: a password is required` / `not in sudoers` | Not supported — delegate to the controller via the queue (`agb task create --to <controller-admin>`). No iso UID is in `sudoers` by default. |
| `git checkout <other-branch>` in the operator's primary checkout | Branch state collision, file ownership mismatch, possible WIP loss in the operator's working tree | Use a worktree under your own `<agent_home>/.claude/worktrees/...` or delegate to the controller. Never `git checkout` in `/Users/<op>/Projects/<repo>` or equivalent — that is the operator's working copy. |
| Read another iso agent's home (`<bridge_home>/agents/<other>/...` or its dispatched workdir) | `Permission denied` | Cross-agent work goes through the queue (`agb task create --to <other>`); no read-through is supported. |

If you see one of these on a fresh boot and you are tempted to "work around" it locally (e.g. by `sudo`-escalating or by reading a different copy you guessed at), stop — the workaround column is the only contract we hold across upgrades. The controller-side fixes (seeding caches, granting groups, plumbing new shared paths) live in `OPERATIONS.md` §"Iso v2 agent troubleshooting"; surface the symptom to the operator if the listed workaround does not apply to your specific case.

For the full design rationale see [`docs/developer-handover.md`](./docs/developer-handover.md) §"Working with isolated agents (iso v2)" and [`OPERATIONS.md`](./OPERATIONS.md) §"Iso v2 agent troubleshooting".

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
2. **Pair-review every non-trivial PR.** Default reviewer is the admin's codex pair, `<admin>-dev` (e.g. `patch-dev` on a `patch`-admin install — auto-provisioned at install time on a server host, see `bridge-init.sh`). Workflow:
   - Write a review brief to `/tmp/agb-<pr-number>-codex-review.md`: background, focus checklist, expected output shape (`implement-ok` / `needs-more: …`).
   - Queue it: `bash bridge-task.sh create --from <admin> --to <admin>-dev --title "[PR #<N> review] <subject>" --body-file /tmp/agb-<pr-number>-codex-review.md`.
   - Wait for the `[task-complete]` notification, `agb claim`, read the completion note.
   - If `needs-more: …`, fix and enqueue the next round with a bumped title (`[PR #<N> re-review]`, then `r3`, etc.) and its own brief file. Each round is a fresh `bridge-task create`, not an edit of the prior task.
   - Merge only after the final reviewer note opens with `implement-ok`. Codex may squash-merge itself when the operator has granted that permission; otherwise you perform the merge.
3. **Release PRs change only `VERSION` + `CHANGELOG.md`.** Keep them on a `release/vX.Y.Z` branch. Same pair-review contract. `git tag -a vX.Y.Z` goes on the merge commit, never on the feature branch.
4. **Branch naming.** `fix/<slug>` for bug fixes, `feat/<slug>` for new capability, `release/vX.Y.Z` for version bumps, `docs/<slug>` for doc-only changes. Keep one PR per branch; rebase to `main` rather than piggy-backing on another open PR (that was the source of the #235 "stacked on #232" confusion on 2026-04-24).
5. **When a review round loops more than 3 times** without an `implement-ok`, stop and reconsider scope before continuing — that's usually a signal the PR is touching too much surface or the spec is ambiguous; a `codex-spec` round on the originating issue is often cheaper than another code round.

Codex cannot observe your local worktree, so reproducibility is on you: include the exact path, env, and command in the review brief and the PR description — not just the symptom. Assume Codex will rerun your verification from scratch.
