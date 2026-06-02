# Worked wave examples — Agent Bridge repo, 2026-04-25 session

Four worked waves from a single session that landed 11 PRs with zero regressions. Each example shows the issue, the brief decision, the dispatch shape, the review path, and the merge note.

## Wave example 1 — combined Track A's docs PR

**Issue context**: #303 + #304 both proposed adding admin role spec sections to `agents/_template/CLAUDE.md`. Both Track A's were docs-only. Bundling them into one PR was cheaper than two separate PRs because they touched the same file in the same area.

**Brief size**: ~150 lines. Docs only. Two new H2 sections inserted between existing sections.

**Dispatch**:

```javascript
Agent({
  description: "Wave 1: #303A + #304A admin role spec docs",
  subagent_type: "upstream-issue-fixer",
  prompt: `... pointing at /tmp/agb-303-304-trackA-fixer.md ...`,
  isolation: "worktree",
  run_in_background: true
})
```

**Review path**: direct (docs-only, ~21 LOC, mid-size). No codex-rescue.

**Merge note** (just the structured part):

```
implement-ok

Direct review by orchestrator (docs-only, 21 LOC, mid-size = direct review per wave pattern).

Verified:
- Section ordering correct: Admin First-Run Onboarding Defaults → Admin Self-Cleanup of Own Queue → Admin Static vs Dynamic Agent Boundary → Channel Setup Protocol
- Both new sections gated on Session Type == admin (matches surrounding admin-specific section convention)
- #303 Track A decision tree (a)-(f) present and ordered correctly; default-to-close rule explicit
- #304 Track A static-vs-dynamic boundary present; nudge-dynamic-agent prohibition explicit
- All five daemon maintenance event types listed: [context-pressure], [stall], [crash-loop], [wake-miss], [blocked-aging]
- No VERSION bump, no code changes — release contract preserved
- Korean throughout, internally consistent within each section

Approved.
```

**Outcome**: PR #306 merged at `4e0bde0`. Both #303 and #304 stayed open with comments noting Track A landed.

**What went wrong**: PR squash subject contained `(closes #303-A, #304-A)`. GitHub auto-closed #303 (greedy regex) — see footgun #2. Recovery: reopen with footgun explanation. **Lesson**: every subsequent brief explicitly forbade `closes #N` text in commit subject.

## Wave example 2 — heredoc-generated content discovery

**Issue context**: #283 Track B "skill content guardrails" — three files to edit. Brief assumed all three were committed source.

**Brief size**: ~220 lines. Three-file scope: `.claude/skills/cron-manager/SKILL.md`, `.claude/skills/agent-bridge/references/bridge-commands.md`, `.claude/skills/agent-bridge/SKILL.md`.

**What the fixer found**: only `.claude/skills/cron-manager/SKILL.md` was committed source. The other two were **heredoc strings** inside `lib/bridge-skills.sh::bridge_render_*`. The brief explicitly forbade `lib/` edits. The fixer correctly **stopped at PR open** with a clear `user_review_needed` flag and a note explaining the situation.

**Recovery**: orchestrator opened a follow-up PR #308 that touched the heredoc directly (mid-size lib/ edit, self-authored).

**Lesson**: footgun #6 documented. Future briefs verify committed-source vs heredoc-generated via `find` + `grep` BEFORE writing the brief.

**Outcomes**: PR #307 merged at `1a2be7c` (single-file expansion); PR #308 merged at `b10ebbe` (heredoc edit). #283 stayed open until Tracks C/D/A landed.

## Wave example 3 — direct mid-size lib/ edit (no fixer)

**Issue context**: #283 Track C — extend `bridge_suggest_subcommand` curated alias table to handle `cron history` / `cron logs` / `help`. Three new `case` arms. Total ~14 LOC across `lib/bridge-core.sh` and `scripts/smoke-test.sh`.

**Decision**: mid-size + clear scope + I had context already → **direct edit, no fixer dispatch**.

**Steps**:

```bash
cd <repo>
git checkout -b fix/283-trackC-cli-suggestions
# ... edit lib/bridge-core.sh + scripts/smoke-test.sh ...
bash -n lib/bridge-core.sh scripts/smoke-test.sh
shellcheck lib/bridge-core.sh scripts/smoke-test.sh
/opt/homebrew/bin/bash -c '
  unset BRIDGE_HOME
  cd .
  source ./bridge-lib.sh
  echo "[1] cron history → [$(bridge_suggest_subcommand "cron history" "")]"
  ...
'
git add lib/bridge-core.sh scripts/smoke-test.sh
git commit -m "cli: extend bridge_suggest_subcommand curated aliases ... (#283 Track C)"
git push -u origin fix/283-trackC-cli-suggestions
gh pr create --base main --head fix/283-trackC-cli-suggestions --title "..." --body "..." --no-maintainer-edit
```

**Review path**: self-review — I authored, I reviewed. Mid-size + I tested live → squash merge.

**Lesson**: not every wave needs a fixer dispatch. When the change is mid-size, well-scoped, and you have context, direct edit is faster.

**Outcome**: PR #309 merged at `0ab5c45`.

## Wave example 4 — codex-rescue review of complex PR

**Issue context**: PR #302 — 583 LOC change, Linux ACL semantics, isolated UID plugin sharing. Specialized domain (ACL ordering, sudo wrap, traverse chain). Authored by `<fork-account>` (operator's fork account) on his other Claude session; opened against upstream `<upstream-account>:main`.

**Decision**: >300 LOC + specialized → **codex-rescue review**, not direct.

**Pre-dispatch checks**:

```bash
# Verify codex setup
node "~/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs" setup --json
# Look for "ready": true

# Fetch the diff to a known path
gh pr diff 302 > /tmp/pr-302.diff
wc -l /tmp/pr-302.diff   # 637

# Write the review brief
$EDITOR /tmp/agb-302-codex-review.md
```

**Dispatch** (with the wait-for-completion line):

```javascript
Agent({
  description: "Codex review of PR #302 ACL plugin sharing",
  subagent_type: "codex:codex-rescue",
  prompt: `Code review PR #302 of <upstream-account>/agent-bridge-public — "isolate: channel-ownership-aware plugin sharing for isolated UIDs".

Codex CLI is installed and ready. If your first probe disagrees, re-check via:
node "~/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs" setup --json
That returns "ready": true on this machine.

Read this brief in full first: /tmp/agb-302-codex-review.md
Diff is at /tmp/pr-302.diff (637 lines).
PR body: gh pr view 302 --json body --jq .body

Output requirement: deliver per the "Output shape (required)" section. Open with implement-ok or needs-more: ... literally. Cite file:line.

Wait for completion in your final assistant message. Do not return a thread id and exit.`,
  run_in_background: true
})
```

**Review return**: `needs-more` with 5 blocking findings + 2 risks + 1 nit, each citing `file:line`. The orchestrator posted the review verbatim as a PR comment.

**Footgun-8 instance**: first dispatch returned "Codex CLI is not installed" because the subagent shell had a stripped PATH. Operator confirmed codex was in fact installed; orchestrator re-dispatched with explicit guidance to re-probe via the companion script. Second dispatch succeeded.

**Outcome**: review posted as PR comment. PR #302 stayed open awaiting r2 fixes from the author side. (Subsequent recipe: cross-fork push from `<fork-account>` account — see `references/recipes.md` "Cross-fork PR push".)

## Cross-cutting observations from these waves

1. **Brief size correlates with PR success rate.** Briefs under 100 lines drop r1 success below 80%. 150-300 lines is the sweet spot.

2. **Footgun callouts in the brief save reviews.** Every recurring footgun added a section to subsequent briefs. The brief grew ~5% per wave, but r2 rounds dropped.

3. **Worktree-relative paths must be repeated.** Once in section 1 (Repo / branch / scope) and once in section 10 (Reminders). Fixers skim — repetition catches.

4. **Direct review for mid-size, codex for big specialized.** The threshold isn't precise; ~300 LOC is the rough cutoff but specialized domain (ACL, sudo, daemon scheduler) drops it to ~200 LOC. When in doubt, dispatch codex-rescue — the cost is small.

5. **Self-authored mid-size waves are legitimate.** Not every change needs a fixer. When you have the context and the scope is clear, direct edit + self-review is faster than dispatch + review.

6. **Pause after a wave for cross-PR verification.** Two PRs touching the same file region can land cleanly individually but introduce subtle conflicts when both land. After a wave: pull main, run smoke locally if material, scan recent commits for unintended interactions.

## Anti-pattern — wave examples that did NOT work

### #239 — 14-bullet bundled PR

Original PR #239 tried to ship 14 distinct improvements in one branch. Three review rounds reached without `implement-ok`. Operator stopped the loop, closed #239, and split into 8 wave-sized PRs (#239 splits 1-5 across waves 3-5 of the session). All 8 split PRs landed r1. Total time was less than the 3-round mega-PR loop would have taken.

**Lesson**: if a PR is touching too much surface, splitting into 2-4-PR waves is almost always the right move. The "bundling saves overhead" instinct is wrong — review overhead scales with surface area, not with PR count.

### Live-install mutation by fixer (#220)

Fixer for #220 ran a `migrate-canonical --apply` against the operator's **live `BRIDGE_HOME`** instead of the test fixture. Mutated real state. Required admin task #1373 to reverse. Code change r2 added a `--i-know-this-is-live` guard.

**Lesson**: footgun #1 (worktree path leakage) extends to runtime side-effects. Briefs that involve live-affecting commands must explicitly forbid mutation of the operator's `BRIDGE_HOME` and require the fixer to use a test prefix instead.
