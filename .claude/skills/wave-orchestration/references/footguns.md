# Footgun catalog

Each footgun below has cost a real session of recovery. Read this file before dispatching a fixer or reviewing a PR — and **always include the relevant footgun warning in the fixer brief** if the fixer might trip it.

## Footgun 1 — Worktree path leakage

**Symptom**: Fixer runs in `<repo>/.claude/worktrees/agent-<hash>/` but mutates files in `<repo>/` (the operator's primary checkout) instead. Operator's working tree gets dirty with someone else's changes. Worst case: fixer commits to operator's branch by accident.

**Root cause**: Brief uses absolute paths like `/Users/<user>/Projects/<repo>/lib/foo.sh`. When fixer reads "edit this file", it edits the absolute path — which is the operator's checkout, not the worktree.

**Fix**: Brief always says "use **relative paths only** from your worktree root" in section 1 and again in section 10 (Reminders). Dispatch prompt repeats it. After fixer reports "done", run `gh pr diff <N>` and confirm only the intended files are touched. If the fixer mutated the operator's tree, run `git -C <repo> stash` immediately and self-revert before doing anything else.

**Real instance**: PR #282 fixer wrote to absolute path, ended up self-reverting. Footgun documented in `feedback_parallel_wave_operator_pattern.md`.

## Footgun 2 — GitHub close-keyword regex

**Symptom**: Issue auto-closes when you only addressed Track A; B/C/D still pending. Operators wake up to find "tracking issue with 4 sub-tracks" silently closed.

**Root cause**: GitHub's close-keyword regex is greedy:
- `closes #283 Track B` → closes #283 (the " Track B" qualifier is ignored)
- `closes #303-A` → closes #303 (the "-A" suffix is ignored)
- `closes #303-A, closes #304-A` → closes #303 only (the comma + "#304-A" has no keyword in front of it, which is the one case GitHub respects)

**Fix**: **Never** put `closes #N` in commit subject or PR title when the issue has subtracks B/C/D pending. Use `(#N Track X)` as a non-keyword reference. Example safe forms:
- `docs: admin role spec — Self-Cleanup of Own Queue (#303-A, #304-A)` ✓
- `cron: extend bridge_suggest_subcommand curated aliases (#283 Track C)` ✓
- `docs: admin role spec — Self-Cleanup (closes #303-A)` ✗ closes #303 by accident

**Recovery**: If an issue gets auto-closed by accident, reopen with a comment explaining the GitHub regex bug + which tracks remain. Add a footgun callout to the next brief so the fixer doesn't repeat.

## Footgun 3 — `gh auth` account mismatch

**Symptom**: `gh pr create` fails with `failed to create pull request: GraphQL: createPullRequest: ... must have push access to the repository`. PR isn't created. Fixer blocks waiting for an owner to grant access.

**Root cause**: Multiple `gh` accounts logged in (e.g., `seanssoh` for fork + `SYRS-AI` for upstream). Active account is the fork; the fork has READ permission on upstream, not write. `gh pr create` from the fork account fails to open a PR against upstream.

**Fix**: Brief must include `gh auth switch --user SYRS-AI` (or whichever account has write) **before** any `gh pr create`. Verify via `gh auth status | head -10` showing the right account as Active.

For cross-fork PRs (PR head is `seanssoh:branch`, base is `SYRS-AI:main`), also pass `--no-maintainer-edit` to `gh pr create`. Without it, fork-to-upstream PRs from accounts that don't have collaborator edit access fail.

## Footgun 4 — VERSION/CHANGELOG bleeding into feature PRs

**Symptom**: Fixer's PR includes a `VERSION` bump and `CHANGELOG.md` entry alongside the actual feature change. Concurrent release PR conflicts on `VERSION`. Release contract violated.

**Root cause**: Fixer sees an existing pattern (every recent commit bumps VERSION!) and assumes it's expected. Or fixer's brief was unclear.

**Fix**: Every brief includes "**No VERSION bump, no CHANGELOG entry. Release contract = `release/vX.Y.Z` branch only.**" After fixer reports done, run `git diff --cached --stat` before commit and `gh pr diff <N>` after — confirm `VERSION` and `CHANGELOG.md` are NOT in the file list.

**Real instance**: #220 fixer bundled a v0.6.16 VERSION bump into a docs PR. Required revert + amend to recover.

## Footgun 5 — macOS Bash 3.2 vs Bash 4+

**Symptom**: Test of a function fails with errors like:
```
/bin/bash: line N: cd: ...: No such file or directory
/bin/bash: line N: conditional binary operator expected
/bin/bash: /bin/bash: 이진 파일을 실행할 수 없음
```

Or a function returns empty output even though the source file clearly has the right code.

**Root cause** (one of three):
1. macOS ships Bash 3.2 at `/bin/bash`; the project requires Bash 4+ (associative arrays, `[[ -v ]]`, etc.). Use `/opt/homebrew/bin/bash` explicitly.
2. `source bridge-lib.sh` (without `./`) lets bash search `$PATH` and pick up the runtime-installed copy at `~/.agent-bridge/bridge-lib.sh` instead of the source-checkout copy. **Always** prefix with `./`.
3. The runtime-installed copy is older than the source checkout — your local edits aren't visible because the test sourced the wrong file.

**Fix**:
```bash
/opt/homebrew/bin/bash -c '
  unset BRIDGE_HOME
  cd <repo-source-root>
  source ./bridge-lib.sh
  my_function arg1 arg2
'
```

Verify before claiming done that the function returns the expected output. If the output looks like it's missing your edit, double-check via `declare -f my_function | head -20` — that prints the in-memory function body so you can confirm the loaded version matches your source.

## Footgun 6 — Committed source vs heredoc-generated content

**Symptom**: Brief says "edit `.claude/skills/agent-bridge/references/bridge-commands.md`". Fixer can't find the file. Or fixer edits a file that turns out to be a runtime-installed symlink, and the change disappears at next regen.

**Root cause**: Some skill content lives in **committed `.md` files** (e.g., `.claude/skills/cron-manager/SKILL.md`). Other skill content is **heredoc strings** inside `lib/bridge-skills.sh::bridge_render_*`. A "docs-only" brief that targets a heredoc file mistakenly assumes a committed source.

**Fix**: Before writing the brief, run `find <repo> -name "<filename>" -not -path "*/worktrees/*"` to find the actual source. If no committed source exists, find the heredoc generator via `grep -rn "<a unique string from the file>" lib/ scripts/`. Brief must point at the actual source — heredoc means a **code edit**, not a docs-only edit.

**Real instance**: #283 Track B fixer for PR #307 correctly identified that `agent-bridge/references/bridge-commands.md` was heredoc-generated and STOPPED at PR open with a clear escalation note. The orchestrator then opened a follow-up PR #308 that touched the heredoc directly.

## Footgun 7 — Cross-fork PR push from fork account

**Symptom**: A PR sits on someone else's fork (e.g., `seanssoh:fix/foo`). The original author can't iterate quickly. You want to push fix commits to that branch.

**Workflow**:

```bash
gh auth switch --user <fork-user>      # MUST be active before push
gh auth status                          # verify

cd <repo>
git remote add <fork-user> https://github.com/<fork-user>/<repo>.git \
  || true
git fetch <fork-user> <branch>
git worktree add /tmp/agb-pr<N>-r2 <fork-user>/<branch>
cd /tmp/agb-pr<N>-r2
git checkout -B <branch>

# ... edit, commit ...

git push <fork-user> HEAD:<branch>     # push to fork; PR auto-updates
```

Cleanup:
```bash
git -C <repo> worktree remove --force /tmp/agb-pr<N>-r2
gh auth switch --user <upstream-user>  # restore default for subsequent PRs
```

**Do NOT**:
- Open a new PR — the fix lives on the existing PR's branch
- Switch back to upstream account mid-run — pushes will go to the wrong remote
- Force-push without explicit operator authorization

## Footgun 8 — codex-rescue async-default

**Symptom**: codex-rescue dispatch returns immediately with an empty thread id. No actual review happens. Reviewer comment never lands.

**Root cause**: codex-rescue is async-default. If the prompt doesn't tell it to wait for completion in its final message, it spins up a background thread, returns the thread id, and exits. The orchestrator gets nothing useful back.

**Fix**: Every codex-rescue dispatch prompt must include this exact line:

```
Wait for completion in your final assistant message. Do not return a thread id and exit.
```

That single line changes the dispatch from async to sync. The reviewer's full review comes back in the agent's final message, where the orchestrator can read it directly.

Also: before dispatching, verify codex is set up:

```bash
codex --version 2>/dev/null && command -v codex   # confirm codex CLI is installed and on PATH
```

If `codex` isn't on the agent's PATH (homebrew installs to `/opt/homebrew/bin` on macOS, `/usr/local/bin` on Linux, neither of which subagent shells always include), the agent reports "Codex CLI is not installed" even when the binary exists. **Re-probing alone is not always enough** — the codex-rescue runtime can still fail to invoke codex from its sandboxed shell. When this happens, re-dispatch with **explicit PATH guidance + absolute-path fallback** in the prompt:

```
**Codex CLI is INSTALLED and READY on this machine.** Verified directly:
$ command -v codex
/opt/homebrew/bin/codex
$ codex --version
codex 1.x.x

If your sandboxed shell reports "Codex CLI is not installed", the issue is the
shell's PATH not picking up the package-manager bin directory. Retry with:

  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" codex --version

Or invoke codex directly via the absolute path the orchestrator captured
above. Do NOT abort with "Codex CLI is not installed" if the orchestrator
(me) confirmed codex is reachable. Proceed with the review.
```

This forceful guidance has worked when the simpler "re-probe via companion script" guidance failed. The codex-rescue agent will still try to invoke codex, but the explicit PATH override + the operator-affirmation lets it persist past the false-negative probe.

## Footgun 10 — Skipping pair-review citing PR size

**Symptom**: Operator catches that you squash-merged PRs without the `codex-rescue` (or project-designated) pair reviewer producing an `implement-ok`. Operator orders a `git revert --no-edit` of the offending squash commits and tells you to re-PR with proper review. Trust dropped, time lost.

**Root cause**: The orchestrator's "direct review for <300 LOC mid-size" instinct conflicts with the project's `AGENTS.md` rule "Pair-review every non-trivial PR. Default reviewer is `agb-dev-codex-2`. Merge only after implement-ok." Earlier versions of this skill encoded the size-based carve-out as the default. **It was wrong.** The project rule overrides; the orchestrator must default to pair-review and only invoke direct review for the explicit allow-list (trivial mechanical reverts, single-line typo fixes, operator-directed exceptions).

**Real instance**: 2026-04-26 — three PRs (#323, #324, #325) merged without codex review citing the size-based carve-out. Operator caught the mismatch, ordered PR #332 (mechanical revert), and the original three branches had to be re-PR'd with proper pair-review.

**Fix**:
1. Pair-review is the default for every non-trivial PR.
2. Direct review is allowed only for: mechanical reverts, single-line typos, operator-directed exceptions (cite the operator instruction in the merge note).
3. When in doubt, dispatch codex-rescue. The 5 minutes of review wall-time is much smaller than the cost of recovering from a "merged without review" revert wave.
4. If the operator says "go faster, skip review", honor it for that batch only — but record it in the session memory so the next session doesn't inherit the relaxation.

If you find yourself thinking "this PR is small enough", that's the rationalization. Read the project's `AGENTS.md` again. If the rule is "every non-trivial PR", you do not have permission to skip on size grounds.

## Footgun 9 — Sequential dispatch when parallel is possible

**Symptom**: Wave takes 4× as long as it should. Operator notices "you're doing one at a time when these are all independent — why?"

**Root cause**: Dispatching one Agent call per turn serializes them by default. Each fixer waits for the previous to complete (or at least for the orchestrator's next turn to fire). Even with `run_in_background: true`, dispatching across multiple turns doesn't actually start the second fixer until the first turn completes.

**The fix is mechanical**: when you have 2-4 independent fixers ready to go, dispatch them **in a single message with multiple Agent tool calls**. The runtime fans them out only when they're in the same response.

```javascript
// CORRECT: same turn, three calls — all three start immediately
Agent({ description: "Wave A", ..., run_in_background: true })
Agent({ description: "Wave B", ..., run_in_background: true })
Agent({ description: "Wave C", ..., run_in_background: true })

// WRONG: three turns — second and third don't start until prior turn finishes
// Turn N: Agent({ description: "Wave A", ..., run_in_background: true })
// Turn N+1: (now dispatching B; A may have already done a lot of work)
// Turn N+2: (now dispatching C)
```

**The default for backlog processing should be "scan → triage → write all briefs → dispatch whole batch"**, not "dispatch one, wait, dispatch next". Operators will explicitly call out the difference if they notice it (Sean did at 11:21 KST 2026-04-26: "왜 하나씩만 하는거야?"). Adopt the parallel-first habit instead of waiting for the call-out.

**Edge cases where serialization is correct**:
- Two fixers touching the same function (not just the same file): rebase risk too high; serialize.
- Round-N+1 of the same PR (need round-N's review back first): inherently sequential.
- A fixer whose result informs the next fixer's brief (rare): wait for the report, then dispatch.

Otherwise: parallel.

## Composite footgun — VERSION + close-keyword + worktree path

If a fixer trips footguns 1, 2, and 4 in the same PR, the PR (a) mutates the operator's primary checkout, (b) auto-closes the parent issue, and (c) bumps VERSION concurrent with an open release PR. Recovery is a manual revert + amend + reopen + comment + roster reset. Don't let this happen — every brief should explicitly call out all three. The cost of a 3-line footgun callout in the brief is much smaller than the cost of recovery.
