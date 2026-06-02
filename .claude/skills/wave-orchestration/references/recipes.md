# Recipes — concrete commands for common operations

Copy-paste these. Each has been used in production; substitute the placeholders.

## Recipe — full wave dispatch

```bash
# 1. Read the issue
gh issue view <N> --json title,body --jq '"# \(.title)\n\n\(.body)"'

# 2. Find files via grep, not the issue body
find <repo> -name "<filename>" -not -path "*/worktrees/*"
grep -rn "<unique substring>" <repo>/lib/ <repo>/scripts/

# 3. Write the brief at /tmp/<topic>-fixer.md (use template in references/brief-template.md)

# 4. Dispatch (in a single Agent tool call):
#    - subagent_type: upstream-issue-fixer
#    - isolation: worktree
#    - run_in_background: true
#    - prompt: brief overview pointing at /tmp/<topic>-fixer.md

# 5. While waiting, draft the review brief if you'll need codex-rescue review.
```

## Recipe — codex-rescue setup verification

```bash
# Always run before dispatching codex-rescue.
node "~/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs" setup --json
```

Look for `"ready": true` in the output.

If you see `"available": false` for codex but `which codex` shows a binary, the agent is running with a stripped PATH. Re-dispatch the codex-rescue agent with explicit instructions to re-probe via the companion script before declaring codex unavailable.

If `"loggedIn": false`, ask the operator to run `!codex login`.

## Recipe — codex-rescue dispatch (sync, with wait line)

```javascript
Agent({
  description: "Codex review of PR #<N>",
  subagent_type: "codex:codex-rescue",
  prompt: `Code review PR #<N> of <owner>/<repo>.

Codex CLI is installed and ready. If your first probe disagrees, re-check via:
node "~/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs" setup --json
That should return "ready": true on this machine.

**Read this brief in full first**: /tmp/<topic>-codex-review.md

**Diff** is at /tmp/pr-<N>.diff (<N> lines).
**PR body**: gh pr view <N> --json body --jq .body

**Output requirement**: deliver the review per the "Output shape (required)"
section of the brief. Open with \`implement-ok\` or \`needs-more: ...\` literally.
Cite file:line. Don't paraphrase the PR body.

**Wait for completion in your final assistant message.** Do not return a thread
id and exit. The orchestrator (me) needs the full review verbatim in your final
message.`,
  run_in_background: true
})
```

The "wait for completion" line is **footgun #8 prevention**. Without it, the dispatch returns an empty thread id and the review never lands.

## Recipe — fetching a PR diff before review

```bash
gh pr diff <N> > /tmp/pr-<N>.diff
wc -l /tmp/pr-<N>.diff
head -3 /tmp/pr-<N>.diff
```

Save to `/tmp/pr-<N>.diff` so the codex review brief can reference an absolute path the codex agent can read.

## Recipe — squash merge with structured note

```bash
gh pr merge <N> --squash --body "$(cat <<'EOF'
implement-ok

<reviewer-context: "Direct review by orchestrator" or "Reviewer: codex-rescue + orchestrator verification">.

Verified:
- <acceptance criterion 1>: <how it was verified>
- <acceptance criterion 2>
- ...
- No VERSION bump, no CHANGELOG entry — release contract preserved
- Single commit, <N> file(s)
- PR title uses '(#<issue> Track <X>)' — close-keyword footgun avoided

<issue-stays-open-or-closes context — either "Issue #N stays open for Tracks Y, Z" or "All tracks of #N landed.">

Approved.
EOF
)"
```

After merge, immediate cleanup:

```bash
git -C <repo> checkout main
git -C <repo> pull --ff-only origin main
git -C <repo> worktree remove -f -f <repo>/.claude/worktrees/agent-<hash>
gh api -X DELETE /repos/<owner>/<repo>/git/refs/heads/<branch>
```

`gh pr merge --delete-branch` fails with `fatal: 'main' is already used by worktree at '...'` when local `main` is also a worktree. Skip the `--delete-branch` flag and use `gh api` to delete the remote ref directly.

## Recipe — cross-fork PR push (footgun #7)

You want to push fix commits to a PR that lives on someone else's fork.

```bash
# Switch to the fork account FIRST. Critical.
gh auth switch --user <fork-user>
gh auth status   # confirm <fork-user> is now Active=true

cd <repo>
git remote add <fork-user> https://github.com/<fork-user>/<repo>.git \
  || true   # OK if already exists
git fetch <fork-user> <branch>

# Worktree off the fork's HEAD, not main
git worktree add /tmp/agb-pr<N>-r2 <fork-user>/<branch>
cd /tmp/agb-pr<N>-r2
git checkout -B <branch>

# ... edit, run verification, commit ...

git push <fork-user> HEAD:<branch>   # PR auto-updates
```

Cleanup:

```bash
git -C <repo> worktree remove --force /tmp/agb-pr<N>-r2
gh auth switch --user <upstream-user>   # restore default
```

**Do not** open a new PR. The fix lives on the existing PR's branch.

## Recipe — finding committed source vs heredoc-generated content

When a brief targets a `.md` file under `.claude/skills/`, verify whether it's committed source or runtime-generated:

```bash
# Is the file in git?
git -C <repo> ls-files | grep -F "<filename>"
# (empty output = not committed = it's runtime-generated)

# Find the heredoc generator
grep -rn "<a unique string from the file>" <repo>/lib/ <repo>/bridge-*.py
```

If the source is a heredoc inside `lib/bridge-skills.sh::bridge_render_*`, the brief must permit a `lib/` edit — it's NOT a docs-only change.

This is **footgun #6**. The fixer for #283 Track B (PR #307) correctly stopped at PR open when it discovered the brief's "three files" actually only had one committed source; the orchestrator opened a follow-up PR #308 to handle the heredoc.

## Recipe — reopening a footgun-2 auto-closed issue

If GitHub auto-closed an issue because the squash subject contained `closes #<N> Track <X>`:

```bash
gh issue reopen <N> --comment "Reopening — issue auto-closed by GitHub's close-keyword regex when PR #<M>'s squash subject contained \"closes #<N> Track <X>\". GitHub parsed this as \`closes #<N>\` and ignored the qualifier. Tracks <Y, Z> are still pending; <Track-X> landed via PR #<M>."
```

Then update the next brief's footgun callout so the fixer doesn't repeat. (See `references/footguns.md` footgun 2.)

## Recipe — local smoke run on macOS

The smoke test refuses to run when `BRIDGE_HOME` points at a real install. Unset it explicitly:

```bash
cd <repo>
env -u BRIDGE_HOME -u BRIDGE_STATE_DIR -u BRIDGE_TASK_DB \
    -u BRIDGE_ROSTER_LOCAL_FILE -u BRIDGE_AGENT_HOME_ROOT \
    -u BRIDGE_CRON_STATE_DIR \
    bash scripts/smoke-test.sh 2>&1 | tee /tmp/agb-local-smoke-$$.log
```

Tail `/tmp/agb-local-smoke-$$.log` for the failure mode. Recent local smoke fail (chronic since 2026-04-21) is `expected output to contain: session=created-session-XXXX` at line ~3885 (`bridge-start.sh "$CREATED_AGENT" --dry-run` not emitting the session label). Document in PR body as pre-existing; do not chase.

## Recipe — bash 4 helper test (footgun #5)

```bash
/opt/homebrew/bin/bash -c '
  unset BRIDGE_HOME
  cd <repo-source-root>
  source ./bridge-lib.sh   # NOTE the ./
  my_function arg1 arg2
'
```

Without `./`, bash searches `$PATH` and may pick up the runtime-installed copy at `~/.agent-bridge/bridge-lib.sh` instead of the source checkout. **Always** use `./bridge-lib.sh`.

If the function returns empty/wrong output even though the source clearly has your edit, dump the loaded function body to confirm:

```bash
/opt/homebrew/bin/bash -c '
  unset BRIDGE_HOME
  cd <repo-source-root>
  source ./bridge-lib.sh
  declare -f my_function | head -25
'
```

If the dumped body doesn't have your edit, the wrong file was sourced. Fix PATH or use absolute `./`.

## Recipe — worktree cleanup after wave

After a wave (or end of session), prune stale worktrees:

```bash
# /tmp-style worktrees from older fixer runs
for d in /tmp/agb-*; do
  [ -d "$d" ] && git -C <repo> worktree remove --force "$d" 2>/dev/null
done

# .claude/worktrees lockfiles from completed fixers
git -C <repo> worktree prune

# List remaining; any agent-* with `locked` lock should match an active fixer.
git -C <repo> worktree list
```

If `.claude/worktrees/agent-<hash>` has `locked` reason `claude agent agent-<hash> (pid <PID>)` and the PID is dead, force-remove:

```bash
git -C <repo> worktree remove -f -f <repo>/.claude/worktrees/agent-<hash>
```

## Recipe — release PR (when you actually need to bump VERSION)

Release PRs are special. Branch must be `release/vX.Y.Z`. Touch only `VERSION` and `CHANGELOG.md`. Single commit. Standard pair-review contract.

```bash
git checkout -b release/v<X.Y.Z>
# bump VERSION
echo "<X.Y.Z>" > VERSION
# add CHANGELOG entry
$EDITOR CHANGELOG.md
git add VERSION CHANGELOG.md
git commit -m "release: bump version to <X.Y.Z>"
git push -u origin release/v<X.Y.Z>
gh pr create --base main --head release/v<X.Y.Z> --title "release: bump version to <X.Y.Z>" --body "..."
```

After merge, tag the merge commit:

```bash
git checkout main
git pull --ff-only origin main
git tag -a v<X.Y.Z> -m "Release v<X.Y.Z>"
git push origin v<X.Y.Z>
```

**Do not** tag the feature branch. Tags go on the merge commit on `main`.

## Recipe — pair-review r2 (after `needs-more`)

```bash
# 1. Post the review verbatim as a PR comment
gh pr comment <N> --body "$(cat /tmp/<topic>-codex-review-r1.md)"

# 2. Write r2 brief — list each finding with file:line citation and concrete fix recipe
$EDITOR /tmp/<topic>-r2-fixer.md

# 3. Dispatch a fresh fixer for r2 (not the same one)
#    Brief title bumps to r2: "[PR #<N> r2] <subject>"

# 4. Repeat until implement-ok
```

After 3 rounds without `implement-ok`, **stop** and reconsider scope. Often the PR is too big or the spec is ambiguous; split it.

## Recipe — ending a wave

After all PRs in a wave land:

1. `gh issue list --state open --limit 30` — what's still open?
2. `gh pr list --state open --limit 10` — any unmerged PRs?
3. Comment on each issue summarizing what landed and which tracks remain
4. Close issues whose tracks all landed
5. Worktree cleanup (recipe above)
6. Pause to verify no cross-PR regressions

If the user asked you to continue, evaluate the next wave from the remaining open issues. If the natural pause point has been reached and the user's "끝까지 처리해" instruction is satisfied, summarize and stop.
