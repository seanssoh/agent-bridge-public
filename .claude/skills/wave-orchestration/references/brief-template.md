# Brief template — fully worked, section by section

A fixer brief is a contract. Vague briefs produce r2 review rounds. Concrete briefs land r1. The template below is field-tested — every section earned its place by the consequence of leaving it out at least once.

## Brief skeleton

```markdown
# Issue #<N> Track <X> — <one-line title>

## Repo / branch / scope

Repo: `<absolute path to operator's primary checkout>` (`main` HEAD `<short-sha>`).
You will run inside an **isolated git worktree** — use **relative paths only**
from your worktree root. Do **not** write to absolute paths inside the
operator's primary checkout.

Branch: `<branch-name>`

PR target: `<owner>/<repo>` `main`. Run `gh auth switch --user <upstream-user>`
before `gh pr create`. Use `--no-maintainer-edit` (cross-fork).

## Read first (do not skip)

- `gh issue view <N> --json body --jq .body` — full issue body
- `<repo>/lib/foo.sh:<line-range>` — the function you'll modify; read its
  current shape before touching
- `<repo>/scripts/smoke-test.sh:<line-range>` — existing test fixture you'll
  extend; understand what conventions it uses
- (any other files the fixer must read to make sound edits)

## What to change

### Step 1 — <descriptive name>

In `<file>`, change `<function or section>` so that:

1. <concrete change, ideally with a code sketch>
2. <another concrete change>

Code sketch (adjust whatever is robust):

\`\`\`bash
my_function() {
  local arg1="$1"
  ...
}
\`\`\`

### Step 2 — <next change>

(continue per change)

## Out of scope (do **not** do)

- Do **not** edit `<file-X>` — that's separate scope
- Do **not** add a new CLI subcommand — Track Y territory
- Do **not** modify `bridge-lib.sh::<function>` — surface change risk
- No VERSION bump, no CHANGELOG entry. Release contract = `release/vX.Y.Z`
  branch only.

## Verification

```
# 1. Lint
bash -n <file1> <file2>
shellcheck <file1> <file2>

# 2. Helper test (or unit-style fixture)
/opt/homebrew/bin/bash -c '
  unset BRIDGE_HOME
  cd .
  source ./bridge-lib.sh
  res="$(my_function /tmp/does-not-exist)"
  [[ -z "$res" ]] || { echo FAIL; exit 1; }
  echo OK
'

# 3. Render check (if rendering)
/opt/homebrew/bin/bash -c '
  cd .
  source ./bridge-lib.sh
  my_render_function | grep -F "<expected substring>"
'

# 4. Regression guard (if touching shared file)
grep -F "<existing important content>" <file>
```

All N checks must pass.

## CI

CI smoke is failing on `main` for `<reason — pre-existing, not yours to fix>`.
Note in PR body. Not blocking.

## PR opening

Single commit. Subject: `<type>: <short-description> (#<N> Track <X>)`.

PR body:
1. `## Summary` — 2-3 lines on intent
2. `## What changed` — file-by-file
3. `## Verification` — output of the verification matrix
4. CI status note (pre-existing failure mode, if any)
5. `## Scope discipline` — confirm release contract preserved
6. End with `Addresses Track <X> of #<N>. Track <Y/Z> stays open.`

**Do NOT** write `closes #<N>` anywhere. Use `(#<N> Track <X>)` as the
non-keyword reference.

## CRITICAL — close-keyword footgun

GitHub parses `closes #<N> Track <X>` as `closes #<N>` and ignores the
qualifier. Same for `closes #<N>-A`. **Never** use those forms. Use
`(#<N> Track <X>)` exactly.

This is footgun #2 in `references/footguns.md`. It has cost real recovery
sessions in this repo (#283 and #303 both got auto-closed by accident).

## Stop point

Stop at PR open. Do **not** auto-merge. Return PR URL + JSON schema.

## Reminders

1. Worktree-relative paths only.
2. `gh auth switch --user <upstream-user>` before `gh pr create`.
3. `--no-maintainer-edit` on `gh pr create` (cross-fork).
4. No code changes outside the listed files. No VERSION bump. No CHANGELOG.
5. Single commit, <N> file(s).

## Output

Return the JSON schema from `agents/_template/CLAUDE.md` line ~54:

```json
{
  "files_changed": ["<list>"],
  "checks_run": ["<list>"],
  "acceptance_met": [true, true, ...],
  "blockers": [],
  "user_review_needed": false,
  "user_message": ""
}
```

Plus the PR URL.
```

## Why each section earned its place

### Repo / branch / scope (section 1)

**Without**: fixer picks the wrong base ref or branch name.

**With**: explicit path, ref, branch, target. Fixer can't get this wrong.

The "isolated worktree" + "relative paths only" callout in this section is **footgun #1** prevention. It must repeat in section 10 (Reminders) too — fixers skim, repetition catches.

### Read first (section 2)

**Without**: fixer makes edits based on the issue body's narrative, which may reference files that don't exist or have moved.

**With**: explicit list of files the fixer must read before editing. Forces the fixer to ground in the actual code state.

Use line ranges where you can — fixer doesn't need to read the whole file, just the relevant function.

### What to change (section 3)

**Without**: fixer interprets the spec, may interpret it differently from you.

**With**: per-step, per-file recipe. Code sketches where the spec is ambiguous. The fixer's job becomes "translate this spec to working code", not "design from the issue body".

Be concrete. "Add a check for missing dir" is vague. "Add `if [[ -z "$path" || ! -d "$path" ]]; then printf '%s' "$path"; return 0; fi` at the top of `bridge_project_root_for_path`" is concrete.

### Out of scope (section 4)

**Without**: fixer over-scopes. Adds bonus features. Touches files you didn't intend. Reviewer rejects on "scope creep".

**With**: explicit deny-list. The fixer reads it and stops at the boundary.

This is the single highest-leverage section. Skip it at your peril.

### Verification (section 5)

**Without**: fixer ships, you find issues post-merge.

**With**: explicit bash commands. Fixer runs each before declaring done; reports the output in the PR body.

Use **executable** verification — `bash -n`, `shellcheck`, `grep -F`, helper unit tests. Don't write "verify the function works" — write the exact command.

### CI (section 6)

**Without**: fixer wastes time chasing pre-existing CI failures it can't fix.

**With**: tells the fixer "this fail is pre-existing; not yours; document and move on".

CI on the Agent Bridge repo has been failing on every recent main commit since 2026-04-21. Every wave brief calls this out. Saves the fixer ~15 minutes per dispatch.

### PR opening (section 7)

**Without**: PR body is sloppy. Reviewer has to ask for clarification.

**With**: structured body the reviewer can grep.

The body sections (Summary / What changed / Verification / CI / Scope) are the convention. Reviewer agents and human reviewers both recognize this shape.

### CRITICAL — close-keyword footgun (section 8)

**Without**: fixer types `closes #283 Track B` and the issue auto-closes when the PR merges.

**With**: explicit warning + alternative.

This is **footgun #2**. It has cost real recovery sessions. Always include in section 8.

### Stop point (section 9)

**Without**: fixer auto-merges the PR. Now you can't review. Operator finds out post-fact.

**With**: explicit "stop at PR open, do not merge".

The orchestrator merges. The fixer opens the PR and stops. Hard line.

### Reminders (section 10)

**Without**: footguns repeat (worktree paths, gh auth, VERSION).

**With**: terse repetition of the most-tripped footguns at the end of the brief.

Fixers skim. Repetition at the bottom is your last line of defense.

### Output (section 11)

**Without**: fixer returns prose. You can't tell programmatically what was checked, what was blocked, what needs operator review.

**With**: structured JSON schema. Orchestrator can parse `acceptance_met` and `blockers` to decide next action.

The schema lives in `agents/_template/CLAUDE.md` line 54. Standard across waves.

## Length sanity check

A working brief is **150-300 lines markdown**. Less = sketchy spec, fixer guesses; more = brief is doing the fixer's job and you should just write the code yourself.

If your brief is approaching 400 lines, the work is too big for one wave. Split it.
