# Repository Guidelines

## Project Structure & Module Organization
The repository is a Bash-based bridge for managing Claude and Codex agents through `tmux`. Core entry points live at the root: `agent-bridge`, thin wrapper `agb`, `bridge-start.sh`, `bridge-run.sh`, `bridge-send.sh`, `bridge-action.sh`, `bridge-task.sh`, `bridge-sync.sh`, and `bridge-daemon.sh`. `bridge-lib.sh` is now a thin loader; shared shell implementation lives under `lib/`. Queue state lives in `bridge-queue.py` with SQLite data under `state/tasks.db`. Treat `shared/` as handoff notes for humans or agents, and treat `state/` plus `logs/` as generated runtime artifacts, not hand-edited source.

## Build, Test, and Development Commands
There is no build step; scripts run directly with Bash.

- `bash bridge-start.sh --list`: show registered agents and session metadata.
- `bash bridge-start.sh tester --dry-run`: verify roster lookup and launch command without starting `tmux`.
- `bash bridge-daemon.sh status|sync|start|stop`: inspect or manage roster sync, queue heartbeats, and idle nudges.
- `./agent-bridge status` or `./agent-bridge status --watch`: show the bridge dashboard with queue totals, agent load, and open tasks.
- `bash bridge-task.sh create --to tester --title "retest" --body-file shared/report.md`: enqueue work instead of interrupting another agent.
- `./agent-bridge inbox tester`, `./agent-bridge claim 12 --agent tester`, `./agent-bridge done 12 --agent tester`: inspect and advance queued work.
- `bash bridge-send.sh --urgent tester "prod issue" --wait 5`: send a direct interrupt only when the queue cannot wait.
- `./agent-bridge --codex --name smoke --workdir /path --no-attach`: create an ad hoc dynamic agent.
- `./agent-bridge --codex --name worker-a --prefer new`: create an isolated git worktree worker when a shared repo already has dormant static roles.
- `./agent-bridge worktree list`: inspect managed worktree workers and their repo paths.
- `./scripts/install-shell-integration.sh --shell zsh --apply`: install zsh integration so `agent-bridge`, `agb`, and bridge aliases work without `./`.
- `./scripts/smoke-test.sh`: run an isolated end-to-end bridge smoke test without touching live bridge state.
- `shellcheck *.sh agent-bridge agb`: lint the shell entry points before submitting changes.

## Coding Style & Naming Conventions
Use Bash with `#!/usr/bin/env bash` and `set -euo pipefail` unless a loop intentionally handles non-zero exit codes, as in `bridge-run.sh`. Indent with two spaces inside functions and `case` arms. Keep reusable helpers under `lib/` and prefix them `bridge_`. Use uppercase names for exported configuration such as `BRIDGE_*`, and lowercase names for local variables. Follow the existing naming pattern: `bridge-<verb>.sh` for primary commands.

## Testing Guidelines
This snapshot does not include a full unit test suite, so rely on linting plus manual smoke checks. At minimum, run `shellcheck`, `./scripts/smoke-test.sh`, one `--dry-run` path for the script you changed, and one daemon pass via `bash bridge-daemon.sh sync`. Test heartbeat-sensitive changes in an isolated `BRIDGE_HOME` with temporary tmux sessions so live agents are not interrupted.

## Commit & Pull Request Guidelines
This working copy does not include `.git`, so there is no local history to infer conventions from. Use short imperative commit subjects such as `bridge: add task queue heartbeat`. Keep pull requests narrow, list the scripts touched, include the exact manual verification commands you ran, and call out any changes to queue semantics, roster behavior, `tmux` session handling, or generated `state/` file formats.

## Multi-Agent Collaboration (Claude ↔ Codex)

Agent Bridge is routinely operated by multiple agents at once — typically a planner/author (`agb-dev-claude`) and one or more reviewers (`agb-dev-codex-1`, `agb-dev-codex-2`, etc.). These rules keep those agents from stepping on each other's branches and worktrees. **They are mandatory from the new-session mark — older sessions that were already running may have ignored them, and the PR review history reflects that.**

### 1. Worktree isolation is the default for every Codex agent

Codex agents MUST work inside their own git worktree, not the operator's primary checkout. The reason is operational, not stylistic: when two agents share a worktree, `git checkout`, `git commit --amend`, and even idle `fetch`/`pull` from one will silently move `HEAD` out from under the other (observed on 2026-04-24 during the v0.6.9 release cut, where a Codex agent's merge-helper amended a commit on top of another agent's uncommitted work).

- Spawn with `agent-bridge --codex --name <id> --prefer new` (use `--claude` for Claude agents). The top-level `agent-bridge` CLI creates a dedicated worktree under `${BRIDGE_WORKTREE_ROOT:-~/.agent-bridge/worktrees}/<project-basename>-<sha8>/<agent>` automatically (the `-<sha8>` suffix is a sha1-prefix of the project root, so two different repos with the same basename don't collide). `bridge-run.sh` itself does not accept `--prefer`; always go through `agent-bridge` for the first launch.
- Inspect the registry with `agent-bridge worktree list`.
- There is no `agent-bridge worktree remove` subcommand today. The paths are content-addressed (`$BRIDGE_WORKTREE_ROOT/<project-basename>-<sha8>/<agent>` for the tree, `$BRIDGE_WORKTREE_META_DIR/<agent>--<sha12>.env` for the registry entry, where `<sha12>` is sha1("project_root|agent")[:12]). Do not reconstruct those names by hand — read them, don't guess them:
  ```bash
  # 1) From `agent-bridge worktree list`, note the exact `root=` path for
  #    the agent you're retiring.
  agent-bridge worktree list
  # 2) git-native remove using that exact path.
  git -C <project-root> worktree remove "<root-path-from-list>"
  # 3) Drop ONLY the matching registry entry. The same agent name can
  #    have --<sha12> entries for different project roots, so scope the
  #    removal by sourcing each env file and comparing WORKTREE_ROOT
  #    directly. A grep would miss matches because the writer stores
  #    the path via `printf '%q'` (shell-quoted), while `worktree list`
  #    prints the raw path — paths containing spaces or regex
  #    metacharacters never match the quoted form.
  target="<root-path-from-list>"
  for env in "$BRIDGE_WORKTREE_META_DIR"/<agent>--*.env; do
    [[ -f "$env" ]] || continue
    WORKTREE_ROOT=""
    # shellcheck source=/dev/null
    source "$env"
    [[ "$WORKTREE_ROOT" == "$target" ]] && rm -f "$env"
  done
  ```
  Never `rm -f "$BRIDGE_WORKTREE_META_DIR"/<agent>--*.env` blindly — that deletes every project's entry for the same agent name. And never `rm -rf` the worktree path without `git worktree remove` first — that leaves git's bookkeeping in a stale state and breaks future `--prefer new` spawns for the same name.
- Never run `git checkout <branch>` or `git commit --amend` inside the operator's primary checkout from a Codex agent's session. Those operations belong in the agent's own worktree or in a short-lived temp clone.

### 2. Pair-review workflow

Claude authors the change; Codex reviews; Claude merges only after Codex signs off.

1. Author agent creates a feature branch off `main`, commits, pushes, and opens a PR.
2. Author agent drops a review brief under `/tmp/agb-<pr-number>-codex-review.md` — background, focus checklist, expected outputs (`implement-ok` / `needs-more: …`).
3. Author agent enqueues a review task with `bridge-task.sh create --from <author> --to <reviewer> --title "[PR #<N> review] …" --body-file /tmp/agb-<pr-number>-codex-review.md`.
4. Reviewer agent verifies the diff, writes its finding into the bridge-task completion note, and returns via `agb done`.
5. Author agent applies feedback; each round bumps the title (`[PR #N re-review]`, `[PR #N re-review r3]`, …) and gets its own brief file. Every round is a fresh `bridge-task create`, not an edit of the prior task.
6. Merge only after the reviewer's final note starts with `implement-ok`. Reviewer agents may squash-merge themselves if the operator has granted that permission; otherwise the author agent performs the merge.

### 3. Release mechanics

A release PR updates only `VERSION` and `CHANGELOG.md`. Keep it in a branch named `release/vX.Y.Z`. Codex reviews the CHANGELOG entries and verifies the version-bump convention before `git tag -a vX.Y.Z <merge-sha>` and `git push origin vX.Y.Z`. Do not tag on a non-merge commit or on the feature branch.

### 3a. Release lines & LTS policy

Agent Bridge runs an **LTS line + mainline**, not a single moving tag. Full policy: [`docs/release-lines.md`](./docs/release-lines.md). What a Codex reviewer needs to hold (operator-decided 2026-06-08):

- **Current LTS: v0.16.2.** An LTS is a blessed stable tag (release title `(LTS)` + README marker) for conservative/production installs.
- **One line until features diverge** — the v0.16.x hardening sequence (v0.16.3, …) rides `main` and *is* the LTS line; do not fork a maintenance branch until the first new *feature* lands. Fork trigger: branch `release/0.16-lts` from the latest `v0.16.x` tag and bump `main` to `v0.17.0-beta`. New features → beta first, never onto the LTS line.
- **Support window**: an LTS is supported until the next LTS is declared.
- **Backport criteria** (LTS branch only): security · data loss · upgrade/rollback breakage · fleet-host-down regression. Not features/cosmetic/perf-only/refactors. Fix on `main` first, cherry-pick back only if it qualifies. When reviewing a backport PR, confirm it meets these criteria.
- **Versioning**: LTS = patch bumps; mainline features = minor. **Channel enforcement**: `--channel stable` currently resolves to the highest global tag, so an `lts` version-line-pin channel (landing in v0.16.3, on the v0.16.x line) is what keeps LTS installs from auto-jumping when a higher minor ships. The upgrader is high-risk — review channel-resolver changes adversarially and confirm the default channel behavior is unchanged.

### 4. Forbidden operations under shared worktree

Even when a Codex agent is attached to a shared worktree for legacy reasons, the following are forbidden on the operator's primary checkout:

- `git checkout`, `git reset`, `git clean`, or `git worktree prune` affecting `main`.
- `git commit --amend` against a commit you did not author in that same session.
- `git push --force` or `--force-with-lease` against another agent's branch.

Violations have blocked real operator work at least once (see the v0.6.9 release cut note above) and must be treated as P1 process breakage, not a style issue.
