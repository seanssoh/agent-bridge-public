---
name: wave-orchestration
description: End-to-end wave workflow for shipping multi-PR change sets through an integration branch with codex pair-review at every gate. Five phases — plan + codex plan-agreement → dispatch parallel fixers (each fixer runs its own codex self-review inside its worktree) → orchestrator-led PR-by-PR pair-review onto an integration branch (NOT main) → integration branch full review + QA → operator-cued release with tag and changelog. Use whenever the user has 2+ open issues/PRs to process in parallel, mentions "wave", "Track A/B/C/D", "parallel fixer", "ship these issues", "integration branch", "wave plan", "release wave", asks to dispatch issue-fix agents, wants codex pair-review on a complex PR, describes a backlog they want batched into focused PRs, or any multi-PR change set that should not be squash-merged straight to main without an integration burn-in. **Parallelism + pair-review are the defaults, not the exceptions** — independent fixers dispatch in one message with multiple Agent tool calls and run_in_background, and every non-trivial agreement gate uses the 5-round convergence protocol (3-round soft-agreement nudge → 5-round operator escalation). Captures the field-tested orchestration pattern that has landed 15+ PRs per session on Agent Bridge with zero regressions, plus the operator's 2026-05-19 workflow refinement: integration-branch lifecycle, dependency-graph merge order, QA gate, and explicit release-cue.
---

# Wave orchestration — plan → fixer → integration → QA → release

## When to use this skill

Use when:
- **2+ independent issues** open and the user wants them processed in parallel
- An issue is split into **Tracks A/B/C/D** and each track is potentially its own PR
- A change set is **large enough to need an integration branch** rather than landing directly on `main`
- A PR is **>300 LOC + specialized domain** (Linux ACL, daemon scheduler, security primitives, etc.) and needs codex pair-review
- A PR sits on a **third-party fork** (different `gh` user) and you need to push fix commits to that branch from your own session
- The user says "process the backlog", "ship these issues", "dispatch fixers", "wave 1/2/3", "Track A of #N", "needs-more on PR #N", "release wave", or "integration branch"

Do NOT use when:
- A single small one-off bug fix → just edit and PR directly
- Architectural design discussion that needs the human → brainstorm first, do not dispatch
- Refactor with >5 file moves and ambiguous scope → write a plan first, get user signoff, *then* maybe dispatch
- The work fits comfortably in 50 LOC and the user is online to review interactively

## Five-phase shape

```
Phase 1 — Plan + codex plan-agreement
  └─ orchestrator writes plan; pair-reviewer agrees via 5-round convergence

Phase 2 — Integration branch + parallel fixer dispatch
  └─ orchestrator forks main → integration branch
  └─ fixers worktree off integration branch, run in parallel

Phase 3 — Per-fixer self-review (codex subagent inside worktree)
  └─ each fixer runs internal codex review until agreement, then opens PR

Phase 4 — Orchestrator-led PR merge onto integration branch
  └─ PRs merged in dependency-graph order (least dependent first)
  └─ pair-review at every merge; orchestrator cleans up worktrees post-merge

Phase 5 — Integration review + QA + operator-cued release
  └─ pair-reviewer does full-branch review
  └─ QA gate (failures → re-dispatch fixer, not cherry-revert)
  └─ operator-explicit-go → merge to main, bump VERSION/CHANGELOG, tag, GitHub release
```

The five phases are sequential at the wave level. **Within Phase 2-4 the fixers and per-PR reviews run in parallel** — that's where the wall-clock win comes from.

---

## Phase 1 — Plan + codex plan-agreement

Write a plan document at `/tmp/<wave-id>-plan.md` that describes:

- **Scope** — issues / tracks in this wave (cite `#N` + track letter)
- **Integration branch name** — `feat/wave-<id>-integration` for feature waves, `release/v<X.Y.Z>-integration` for release waves
- **Per-fixer track plan** — one section per fixer with its scope, files-to-touch, expected PR base (the integration branch, not main), and dependency relationship to other fixers in the same wave
- **Dependency graph** — explicit ordering for Phase 4 merge (least-dependent fixer first)
- **Out-of-scope** — anything explicitly *not* in this wave so the codex reviewer doesn't push for it
- **Verification + QA approach** — what `/qa` (or equivalent) actually exercises, and what counts as "pass"

Then queue the plan to the project's **long-lived pair-reviewer codex** for a plan-level review (NOT a code review). The reviewer for plan-level work is the same long-lived codex pair the project's `AGENTS.md` / `CLAUDE.md` designates for code review (e.g., `agb-dev-codex` on Agent Bridge — verify via `bash bridge-start.sh --list` because some installs lack the `-2` suffix the docs sometimes assume).

Plan brief shape:

```bash
bash bridge-task.sh create --from <orchestrator-agent> --to <pair-reviewer-agent> \
  --title "[Wave <id> plan review] <one-line scope>" --body-file /tmp/<wave-id>-plan.md
```

Apply the **convergence protocol** (see "Convergence protocol" section below) until plan agreement is reached. **Do not start Phase 2 without it** — Phase 2 dispatches parallel fixers, and a plan disagreement caught at Phase 1 is 10× cheaper than the same disagreement caught after 4 PRs are open.

---

## Phase 2 — Integration branch + parallel fixer dispatch

### Create the integration branch (orchestrator only)

```bash
git checkout main
git pull --ff-only origin main
git checkout -b <integration-branch-name>   # from the plan
git push -u origin <integration-branch-name>
```

The integration branch is owned by the orchestrator (this main session). Fixers never create or modify the branch itself — they branch off it for their fixer branches and PR back to it.

### Write briefs (one per fixer)

Briefs go to `/tmp/<wave-id>-<fixer-slug>-fixer.md` and follow `references/brief-template.md`. **Required additions for this skill's workflow** (on top of the existing template):

- **PR base** — explicit `--base <integration-branch-name>`, **not** `main`. Spell this out in the brief's "PR opening" section.
- **Internal codex review contract** — the fixer must run codex review on its own diff *before* opening the PR, and apply the convergence protocol. Brief says: "Open the PR only when your internal codex review returns `implement-ok`. If you hit the round cap, return the disagreement summary instead of opening the PR — orchestrator decides escalation."
- **Worktree path discipline** — relative paths only from worktree root. Footgun #1 callout.
- **No VERSION/CHANGELOG bump** — those are batched in Phase 5 by the orchestrator.

### Dispatch idiom (ONE message, multiple Agent calls)

```javascript
// All in a SINGLE assistant turn — sending across multiple turns serializes them.
Agent({ description: "Wave N — fixer A", subagent_type: "issue-fixer",
        prompt: <points at /tmp/wave-N-A-fixer.md>,
        isolation: "worktree", run_in_background: true })
Agent({ description: "Wave N — fixer B", subagent_type: "issue-fixer",
        prompt: <points at /tmp/wave-N-B-fixer.md>,
        isolation: "worktree", run_in_background: true })
Agent({ description: "Wave N — fixer C", subagent_type: "issue-fixer",
        prompt: <points at /tmp/wave-N-C-fixer.md>,
        isolation: "worktree", run_in_background: true })
```

If `issue-fixer` is not installed on this host, the fallback is `subagent_type: "general-purpose"` with a brief that does more lifting — see "Bundled agent" at the bottom.

### Conflict avoidance before dispatch

| Two fixers touch... | Parallel? |
|---|---|
| Wholly disjoint files | yes |
| Different functions in the same file | yes (merge order may need rebase) |
| Same function | **no — serialize** |
| Docs + code in same area | yes |
| 3+ fixers all touching `lib/bridge-core.sh` | partial — fan out 2 max, third rebases |

Sweet spot: **2-4 fixers per wave.** Larger waves hit your own context-budget pressure when reviews start landing.

---

## Phase 3 — Per-fixer self-review (inside the worktree)

This is the key change vs the old skill: fixers run their **own** codex review inside the worktree before opening the PR. The orchestrator's pair-review in Phase 4 then has less to do, and r2-round bounce-back is dramatically reduced.

The fixer brief instructs the fixer to:

1. Apply the edit, run the verification matrix from the brief.
2. Stage the diff.
3. Spawn `codex:codex-rescue` subagent with a code-review brief that includes the staged diff + acceptance criteria.
4. Apply the **convergence protocol** inside the worktree (same 5-round cap, same 3-round soft-agreement nudge, same operator-escalation cliff). If the operator-escalation cliff hits, the fixer **does not open the PR** — it returns the disagreement summary to the orchestrator and the orchestrator decides whether to escalate to the user.
5. On agreement (`implement-ok`), commit, push, open PR with `--base <integration-branch-name>`, return the PR number to the orchestrator.

The fixer's internal codex is a **fresh ephemeral subagent** scoped to that fixer's diff only. It is distinct from the long-lived pair-reviewer used in Phases 1, 4, 5.

When a fixer's internal codex review must wait for the subagent to actually complete, the brief MUST include the line "Wait for completion in your final assistant message. Do not return a thread id and exit." — see footgun #8 in `references/footguns.md`. Every other dispatch hits this.

---

## Phase 3.5 — Monitor dispatched fixers (wedge detection + recovery)

**Operator directive (2026-06-03): never leave a long-running fixer unattended. Check on it; don't waste time letting a dead one go stale.** Background fixers fail silently — the single most common failure is a fixer **wedging on its internal `codex:codex-rescue` review** (it blocks waiting on the subagent for 1-2+ hours — the fixer-internal-codex-wedge pattern, confirmed repeatedly). A wedged fixer produces no PR and no notification; if you don't check, you burn hours.

### Monitor cadence
After dispatching background fixers, set a wall-clock expectation per fixer (a normal scoped fix opens a PR within ~20-30 min incl. the internal review; a deep/security fix longer). If a fixer hasn't reported a PR by its budget, **check it** — do NOT wait indefinitely. Cheap, context-safe signals (NEVER tail the JSONL transcript — it overflows your context):

- `gh pr list` — did it open a PR?
- `git ls-remote origin 'refs/heads/<fixer-branch>'` — did it push a branch?
- `git -C .claude/worktrees/agent-<id> log --oneline -3` — any commits in its worktree?
- `stat -f '%Sm (%z bytes)' <output-file>` — output-file **mtime** + size (activity proxy).

### Wedge signal
Output-file mtime stale (no change for ~15+ min) **AND** no commits **AND** no PR/branch = wedged (almost always parked on the internal codex-rescue call). A tiny output file (~100-200 bytes) that hasn't grown confirms it barely started.

### Recovery — and the non-negotiable review rule
1. **Re-engage** (preferred when work exists): `SendMessage` to the fixer's `agentId` telling it to finalize + push (and, if the internal review is the blocker on a small/clear diff, to skip it and let the orchestrator's Phase-4 pair-review be the gate). Re-engaging preserves its worktree + context.
2. **Kill + take over** (when it barely started / the change is trivial, < ~50 LOC): `TaskStop` the agent, then do the edit yourself in a **dedicated temp worktree** (`git worktree add -b <branch> /tmp/<slug> origin/main`) — never in the operator's primary checkout.
3. **CRITICAL — taking over does NOT skip review (operator directive 2026-06-03).** When a fixer wedges on its *internal* codex review and you finish the work yourself, the PR has now had **zero** codex review. You MUST still queue the **`agb-dev-codex` Phase-4 pair-review** (Phase 4 below) and merge ONLY on `implement-ok`. The wedged internal review was the fixer's self-check; the Phase-4 pair-review is the real merge gate and is mandatory for EVERY PR — a taken-over PR is not an exception. Never push-and-merge a wedge-recovery PR on your own say-so.

**Field evidence**: in one wave, 3/3 dispatched fixers wedged at the internal codex-rescue step — each had finished its edits + verification matrix, then stalled at "now invoke the codex rescue subagent". The edits sat intact in the worktree the whole time; only the commit/push/PR stage never ran. Take-over recovered all of them with zero lost work. Note the wedge is specifically the *fixer-internal* codex-rescue handoff (Phase 3), not the long-lived `agb-dev-codex` queue review (Phases 1/4/5).

---

## Phase 4 — Orchestrator PR-by-PR merge onto integration branch

When fixer PRs start landing (notifications via background dispatch), the orchestrator processes them **one at a time in dependency-graph order** (least-dependent first — the plan's dependency graph is authoritative).

For each PR:

1. **Pair-review** with the long-lived codex pair (same one used for the plan). This is on top of the fixer's internal review — internal review checks the diff in isolation, this review checks fit with the integration branch + cross-fixer surface.
2. Apply the **convergence protocol** as usual.
3. On `implement-ok`, **squash-merge to the integration branch (NOT main)**:
   ```bash
   gh pr merge <N> --squash --body "$(cat <<'EOF'
   implement-ok

   <reviewer-context: codex pair-review round N>

   Verified:
   - <acceptance criterion 1>
   - ...
   - Single commit, <N> file(s)
   - Merged to <integration-branch>, not main

   Approved.
   EOF
   )"
   ```
4. **Clean up the fixer's worktree and remote branch** immediately after merge:
   ```bash
   git -C <repo> worktree remove -f -f <repo>/.claude/worktrees/agent-<hash>
   gh api -X DELETE /repos/<owner>/<repo>/git/refs/heads/<fixer-branch>
   ```
   The orchestrator is the **sole accountable owner** for cleanup. Worktrees that survive past their PR merge accumulate as stale state (`.claude/worktrees/` regularly hits 60+ entries on a busy install). Sweep at the end of every wave: `find <repo>/.claude/worktrees -maxdepth 1 -type d` and reconcile against open PRs.
5. **Rebase the integration branch on `origin/main`** periodically if the wave runs long. Stale integration branches that haven't pulled main in days are a merge-conflict trap when Phase 5 fires.

If the convergence protocol hits the operator-escalation cliff on a PR review, do not silently keep waiting — escalate to the user with the disagreement summary so they can decide direction.

---

## Phase 5 — Integration review + QA + operator-cued release

When all wave PRs have merged to the integration branch:

### 5a. Full-branch codex review

Queue a final review brief to the long-lived pair-reviewer scoped to the integration branch as a whole:

```bash
bash bridge-task.sh create --from <orchestrator-agent> --to <pair-reviewer-agent> \
  --title "[Wave <id> integration review] <branch>" \
  --body-file /tmp/<wave-id>-integration-review.md
```

Brief should include: full `git log main..<integration-branch>`, cumulative diff stat, surface that wasn't reviewed per-PR (e.g., docs cross-file consistency, naming convergence across multiple PRs), and any cross-PR regression that would only show up against the integration HEAD.

Apply convergence protocol.

### 5b. QA gate

Check whether `/qa` (or the project's equivalent) is invocable standalone in this environment:

- **If yes**: run it against the integration branch. `/qa` from the `gstack` framework can be invoked directly if the host has it installed.
- **If no**: write a project-local QA runner derived from `/qa`'s contract (navigate the live build, exercise critical user flows, check for regressions in adjacent features). Land that runner in the project under `scripts/qa/` or similar so future waves can reuse it.

QA pass = ship. QA fail = re-dispatch the fixer responsible for the failing surface and re-merge after their fix lands.

**Why re-dispatch, not cherry-revert** (operator directive 2026-05-19): cherry-revert leaves the user-facing bug shipped + the wave goal unmet. Re-dispatch the same fixer if its worktree is still alive (`.claude/worktrees/agent-<hash>` exists); otherwise spawn a fresh fixer with a brief that includes the QA failure repro. Re-merge through the same Phase 4 PR gate. Cherry-revert is the last-resort fallback only when the bug cannot be fixed in the wave's wall-clock budget.

### 5c. Operator-cued release

Releases require **explicit operator go** every time. Standing autonomy on the wave does NOT extend to the release ship itself (durable rule, see your memory). Report the wave summary to the user:

- Integration branch HEAD, PRs landed, QA result
- Proposed version bump (semver: major / minor / patch / `-beta` / `-rc` — recommend based on change shape; user decides)
- Proposed tag name + whether to mark as GitHub Pre-release

Wait for the user's explicit go. On `go release`:

1. Open a release PR `release/v<X.Y.Z>` that merges the integration branch into `main` and bumps `VERSION` + `CHANGELOG.md` in the same commit.
2. Pair-review the release PR (same as Phase 4 — even release PRs need pair-review per the project's `AGENTS.md`).
3. Squash-merge release PR.
4. Tag on the merge commit: `git tag -a v<X.Y.Z> -m "<release title>"` then `git push origin v<X.Y.Z>`.
5. GitHub release: `gh release create v<X.Y.Z> --title "v<X.Y.Z>" --notes "<CHANGELOG section>"` — add `--prerelease` for `-beta` / `-rc` tags.
6. Delete the integration branch: `gh api -X DELETE /repos/<owner>/<repo>/git/refs/heads/<integration-branch>` (after confirming all commits are on main).
7. Update memory if this wave shifted a pattern.

---

## Convergence protocol (applies to every agreement gate)

Used at: Phase 1 (plan), Phase 3 (fixer-internal), Phase 4 (per-PR), Phase 5a (integration), Phase 5b (release PR).

| Round | Action |
|---|---|
| 1 | Submit work → reviewer returns `implement-ok` or `needs-more: <list>` |
| 2 | If `needs-more`: fix all items → re-submit |
| 3 | If still `needs-more`: fix what you agree with, then **explicitly negotiate** with the reviewer for any remaining disagreement: "If the remaining items are not a major issue, let's land this and re-check in the next code review round." Submit the negotiation note as part of the r3 reply. |
| 4 | Reviewer reads the negotiation note and either: (a) agrees with the soft-landing → `implement-ok`, or (b) BLOCKING with reasoning. If (b), fix what's now possible and re-submit. |
| 5 | If still no `implement-ok`: **escalate to the user** with the disagreement summary. Do NOT proceed without the user's call. |

**Why the 3-round nudge exists**: long convergence loops without a soft-landing valve are how PRs slip from a 90-minute cycle into a 4-hour cycle and end up reverted out of frustration. After round 3, both sides usually have a clear picture of what's blocking — give the reviewer the chance to soft-land non-major items and re-check in a later code review, instead of grinding through pedantic re-rounds.

**The 5-round cliff is real**: do not raise it case-by-case. If you find yourself at round 5 with no agreement, the work is misscoped or the spec is ambiguous. Operator decides which direction to take next.

**Autonomy default**: between rounds 1-4 the orchestrator runs autonomously (no user questions). User is only pulled in at round 5 cliff, or if the reviewer surfaces something genuinely ambiguous that needs a product call (not a technical call).

---

## Codex role split — long-lived pair vs ephemeral fixer-internal

Two distinct codex agents play different roles in a wave. **Never conflate them.**

| Role | Identity | Scope | Used in |
|---|---|---|---|
| **Long-lived pair-reviewer** | The project's designated pair-reviewer (e.g., `agb-dev-codex` on Agent Bridge). Verify name with `bash bridge-start.sh --list`. | Stable context across the entire wave + multiple waves. Reviews plans, per-PR diffs against integration branch, full-branch reviews, release PRs. | Phases 1, 4, 5a, 5b release PR |
| **Ephemeral fixer-internal codex** | Fresh `codex:codex-rescue` subagent spawned inside each fixer's worktree. New instance per fixer. | Scoped to that fixer's diff only. No memory of other fixers in the wave. | Phase 3 |

The split matters because:
- Long-lived pair sees the **whole wave context** — catches cross-PR regression, surface drift, naming inconsistency.
- Ephemeral fixer-internal sees the **diff in isolation** — catches local bugs, missing tests, semantic issues in that fixer's scope.
- If both flag the same PR, the long-lived pair's note carries more weight on cross-cutting concerns; the fixer-internal's note carries more weight on local correctness.

A `codex:codex-rescue` subagent dispatch MUST include "Wait for completion in your final assistant message. Do not return a thread id and exit." or it returns an empty thread id. Every other dispatch hits this. (Footgun #8.)

---

## Integration branch lifecycle (orchestrator responsibilities)

The orchestrator is the **sole owner** of the integration branch. Concrete obligations:

1. **Create** at Phase 2 start, from latest `origin/main`.
2. **Push** immediately so fixer worktrees can branch off the same remote ref.
3. **Rebase on `origin/main`** periodically during long waves (rule of thumb: if main has moved >10 commits since the integration branch's last rebase, rebase before the next PR merge — otherwise the PR's rebase will be ambiguous).
4. **Merge fixer PRs in dependency-graph order** (Phase 4).
5. **Sweep stale worktrees + remote branches** after each Phase 4 merge.
6. **Final merge to main** at Phase 5c via release PR (NOT direct push or fast-forward — release PRs are pair-reviewed too).
7. **Delete the integration branch** after release tag is pushed and all commits are confirmed on main.

If the wave is canceled (operator stops the wave or QA fails irrecoverably), the integration branch is closed without merging to main. Delete it explicitly so it doesn't accumulate as stale state.

---

## Fixer worktree lifecycle (orchestrator-owned)

The fixer creates the worktree (via `isolation: "worktree"` in the Agent dispatch). The **orchestrator** is responsible for cleaning it up:

| Event | Cleanup action |
|---|---|
| Fixer PR merges (Phase 4) | Remove worktree + delete remote fixer branch |
| QA fails + same fixer re-dispatched (Phase 5b) | Keep worktree alive; re-issue work to existing fixer if possible |
| Wave canceled | Sweep all wave worktrees + remote branches |
| End of wave (cleanup sweep) | `find <repo>/.claude/worktrees -maxdepth 1 -type d -mtime +7` → reconcile against open PRs; any worktree with no matching open PR is stale |

If worktrees accumulate (the `.claude/worktrees/` directory regularly hits 60+ entries on a busy install), the issue is almost always orchestrator failing this cleanup step at Phase 4 merge time. Don't defer it — run it immediately after each squash-merge while you have the worktree path in mind.

---

## Dispatch idiom recap

Same-message dispatch for parallelism:

```javascript
// Single assistant turn:
Agent({ description: "Wave N — A", subagent_type: "issue-fixer", prompt: ..., isolation: "worktree", run_in_background: true })
Agent({ description: "Wave N — B", subagent_type: "issue-fixer", prompt: ..., isolation: "worktree", run_in_background: true })
Agent({ description: "Wave N — C", subagent_type: "issue-fixer", prompt: ..., isolation: "worktree", run_in_background: true })
```

Critical flags:
- `isolation: "worktree"` — without this, the fixer mutates the operator's primary checkout (footgun #1).
- `run_in_background: true` — main session continues while fixers work; notifications arrive on completion.
- `prompt` is a 30-50 line overview pointing at `/tmp/<wave>-<fixer-slug>-fixer.md`; the brief lives in the file, not the prompt.

---

## Footgun catalog

8 footguns from the original skill — all still apply. **Read `references/footguns.md` before dispatching; have it open while reviewing PRs.**

1. Worktree path leakage (absolute paths in brief)
2. GitHub close-keyword regex (`closes #283 Track B` → closes #283)
3. `gh auth` account mismatch (cross-fork PR fails on wrong account)
4. VERSION/CHANGELOG bleeding into feature PRs (Phase 5 owns the bump; fixers must NOT touch VERSION/CHANGELOG)
5. macOS Bash 3.2 vs Bash 4+
6. Committed source vs heredoc-generated content
7. Cross-fork PR push from fork account (not new branch)
8. codex-rescue async-default (missing wait-for-completion line)

**New footguns specific to this workflow** (also written up in `references/footguns.md`; numbered to avoid collision with existing #9 parallelization and #10 pair-review-skip):
11. PR opened with `--base main` instead of the integration branch — fixer brief must spell out `--base <integration-branch>` and the orchestrator must verify on each PR via `gh pr view <N> --json baseRefName`.
12. Stale integration branch (main moved 20+ commits since last rebase) → merge conflicts at Phase 5 release PR. Orchestrator rebases periodically during long waves.
13. Worktree accumulation (orchestrator forgot Phase 4 cleanup) → disk + `git worktree list` clutter. Sweep at end of every wave with `find <repo>/.claude/worktrees -maxdepth 1 -type d`.

---

## Verification before completion (every PR)

Don't claim "done" without:

- `bash -n` on every touched `.sh` file
- `shellcheck` on every touched `.sh` file (warnings OK; errors not OK)
- `python3 -c "import ast; ast.parse(open('<file>').read())"` on every touched `.py` file
- Live test of any new helper function via fresh bash + source `./bridge-lib.sh` (note the `./`)
- `git diff --cached --stat` before commit — confirm only the intended files are staged
- `gh pr diff <N>` after PR open — confirm fixer didn't touch unintended files (worktree path footgun)
- `gh pr view <N> --json baseRefName` — confirm base is the integration branch, not `main` (new footgun #9)

---

## Reference files

- `references/brief-template.md` — fully worked brief template (use for fixer briefs; extend with PR-base + internal-codex-review sections)
- `references/footguns.md` — 8 original footguns + 3 new ones (#9-#11 from this workflow)
- `references/recipes.md` — cross-fork push, codex setup verification, worktree cleanup, releasing PR conventions
- `references/wave-examples.md` — worked waves from the Agent Bridge repo

Read these on demand; the SKILL.md above is the orchestration spine and stays under ~500 lines on purpose.

## Bundled agent

- `agents/issue-fixer.md` — project-agnostic single-issue fixer. **Not auto-installed.** Copy to `~/.claude/agents/issue-fixer.md` (one-time setup) to make `subagent_type: "issue-fixer"` available:
  ```bash
  mkdir -p ~/.claude/agents
  cp ~/.claude/skills/wave-orchestration/agents/issue-fixer.md ~/.claude/agents/issue-fixer.md
  ```

  Or fall back to `general-purpose` with a more detailed brief that explicitly references the worktree-relative-paths rule, single-commit convention, no-VERSION/CHANGELOG rule, PR-base-must-be-integration-branch rule, and the JSON return schema the brief specifies.

Project-specific fixers (Agent Bridge's `upstream-issue-fixer`, etc.) take precedence over the bundled default when available — they have hardcoded project conventions and need less from the brief.
