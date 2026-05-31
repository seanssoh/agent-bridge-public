# Wave Orchestration Plugin Design

## 1. Goals & Non-Goals

Recommended approach: implement wave orchestration as a bridge-native CLI and runtime plugin that standardizes the existing "brief -> isolated worker -> Codex plan/review -> PR -> main-agent merge decision" pattern. The plugin should reuse Agent Bridge primitives that already exist: dynamic agents started through `agent-bridge --codex|--claude --name ... --prefer new`, managed worktrees under `BRIDGE_WORKTREE_ROOT`, durable task delivery through `bridge-task.sh`, review requests through `bridge-review.sh`, audit rows through `bridge_audit_log`, and the existing status dashboard. The old Claude-only skill should become source material for this plugin, not the runtime contract.

The primary goal is repeatable, parallel delivery of 2-4 independent issue tracks without sharing a checkout or hiding results in a single agent's transcript. Non-goals for the first implementation: automatic merge, replacing the task queue, replacing `gh`, inventing a second worktree registry, or depending on Claude Code's `Agent` tool. The plugin should work when the main agent is Claude or Codex because the surface is `agent-bridge wave ...`, not a Claude-only subagent call.

Trade-offs: a bridge-native CLI has more implementation cost than copying the existing skill into every agent, but it gives durable state, cross-engine support, and observability. Keeping the skill as the contract is faster, but preserves the current Claude-specific dispatch model and the `.claude/worktrees` path that conflicts with the repo's managed-worktree rules.

**Operator decision (2026-04-26)**: **CLI-only first release**. Daemon integration deferred to a follow-up phase once the CLI surface stabilizes. CLI ships faster and can still write durable state files; daemon work (dashboard freshness, stale detection, automatic cleanup) is a Phase 2.

## 2. User-facing CLI surface

Recommended approach: add a top-level `agent-bridge wave` command routed to a new implementation module. The minimum surface should be:

```text
agent-bridge wave dispatch <issue-or-brief> [--repo <owner/repo>] [--tracks A,B,C] [--main-agent <agent>] [--worker-engine claude|codex] [--reviewer <agent>|--review-policy] [--dry-run] [--json]
agent-bridge wave list [--all] [--json]
agent-bridge wave show <wave-id> [--json]
agent-bridge wave watch <wave-id>
agent-bridge wave complete <wave-id> --member <member-id> --pr <url> --report-file <path>
agent-bridge wave cleanup <wave-id|--stale> [--dry-run] [--force]
agent-bridge wave templates
agent-bridge wave close-issue <issue> [--wave <wave-id>]   # see §12
```

`dispatch` should create a wave id, write one durable brief per member under `shared/waves/<wave-id>/<member-id>/brief.md`, start or reuse one worker per independent track, and create a queue task assigned to each worker. Do not use direct urgent sends for normal dispatch. Worker agent ids should be deterministic enough to inspect and unique enough to avoid collisions, for example `wave-276-A-4f3a`, with the full metadata stored in `state/waves/<wave-id>.json`. If the operator supplies a prewritten brief instead of a GitHub issue, the plugin should treat it as the source of truth and skip issue parsing.

The plugin should decide "one worker or many" by explicit `--tracks` list only. Without `--tracks`, dispatch creates a single worker covering the whole brief. The plugin does **not** parse issue body for track headings (per §2 operator decision). When multiple tracks are listed, `dispatch --dry-run` should show expected file surfaces per track and a proposed parallelization plan. The default wave size should be 2-4 members. Tracks with overlapping same-function write surfaces should be serialized by creating later members in `pending` state rather than dispatching them immediately.

Trade-offs: a rich CLI with list/show/watch adds implementation work, but it prevents wave state from living only in transcripts. Inferring tracks from issue text saves time but can be wrong; explicit `--tracks` plus `--dry-run` keeps the operator in control when scope is ambiguous.

**Operator decision (2026-04-26)**: **explicit `--tracks` only**. Auto-parse declined to avoid misreading issue prose as implementation scope. Operators must list the tracks they want dispatched. Issue body is shown in `--dry-run` for reference but not parsed for track names.

## 3. Worktree lifecycle

Recommended approach: use the existing Agent Bridge managed worktree layout, not the legacy Claude skill layout. New workers should be started with `agent-bridge --<engine> --name <worker-id> --workdir <repo-path> --prefer new --no-attach`, which creates worktrees under `~/.agent-bridge/worktrees/<repo-slug>-<sha8>/<agent>` and metadata under `state/worktrees/`. This aligns with `ARCHITECTURE.md`, `OPERATIONS.md`, and the repository rule that Codex agents must not write in the operator's primary checkout.

The lifecycle should be: create worktree at dispatch; preserve it through PR review; remove it only after the main agent merges or explicitly closes the member as abandoned. Successful members should delete the remote branch and remove the local worktree with `git worktree remove` after merge. Failed or blocked members should be preserved with a TTL marker so the operator can inspect the checkout, logs, and branch. Each member id, branch, worktree root, source repo, PR URL, task id, and cleanup state should be recorded in `state/waves/<wave-id>.json`.

Collision avoidance should come from unique member ids plus pre-dispatch file-surface checks. A single issue with Tracks A/B/C produces separate worker ids and branches. If two members would touch the same function or generated artifact, the plugin should mark the later member `waiting_for=<member-id>` and dispatch it after the earlier PR merges or is abandoned.

Trade-offs: removing worktrees immediately after PR open saves disk space but destroys the easiest debugging surface. Preserving until merge costs disk, but matches the pair-review loop and supports r2 fixes without reconstructing state.

**Operator decision (2026-04-26)**: **7-day TTL** for failed or abandoned worktrees. Successful merge still cleans immediately. 7 days supports asynchronous operator review and postmortems; cron-based cleanup runs daily and removes expired markers.

## 4. Codex CLI integration

Recommended approach: add a small adapter surface, conceptually `bridge-codex.sh`, with `doctor`, `plan`, and `review` subcommands. The wave plugin should call the adapter rather than shelling directly to `codex` everywhere. `doctor` verifies `BRIDGE_CODEX_BIN` or `command -v codex`, `codex --version`, login/readiness if detectable, PATH including `/opt/homebrew/bin` on macOS, and whether the current sandbox can run the noninteractive command shape. `plan` reads the member brief and writes `shared/waves/<wave-id>/<member-id>/codex-plan.md`. `review` reads the PR diff or local diff and writes `codex-review.md` with a literal first line of `review-ok` or `needs-more: ...`.

The adapter must handle the known Codex/Claude submission differences by avoiding tmux TUI injection for planning and review whenever possible. Existing bridge startup launches Codex with `-c features.hooks=true --dangerously-bypass-approvals-and-sandbox --no-alt-screen`, while urgent sends use paste-plus-submit for Codex and type-plus-submit for Claude. Wave plan/review should prefer a direct noninteractive Codex process and only fall back to a queued Codex reviewer agent when the CLI cannot run directly.

Workers should run Codex twice: before editing for a constrained plan, and after editing for a review of the diff. The plan is advisory, not a separate approval gate unless the adapter returns `plan-needs-more` or fails. The review is a quality gate: `needs-more` sends the worker back to edit before PR open unless the operator has configured draft-PR-on-review-failure.

Trade-offs: a wrapper adds another script, but it centralizes PATH, sandbox, timeout, and output-shape handling. Calling `codex` directly from worker prompts is simpler but will repeat the current "Codex not installed" false negatives and make review outputs hard to parse.

**Operator decision (2026-04-26)**: **draft PR on Codex review failure**. Worker still opens a PR but in draft mode with a `[blocked: codex-review needs-more]` label or marker visible to the main agent. Operators get a concrete review surface earlier and can decide whether to address `needs-more` findings or convert to ready-for-review.

## 5. PR automation

Recommended approach: each worker opens its own PR after local verification and Codex review pass. The PR body should be generated from a plugin template using the brief, plan, review, verification output, and changed-file list. Required sections: Summary, What changed, Verification, Codex plan/review, Scope discipline, Wave metadata, and Remaining tracks. The worker should stop at PR open and report the URL; it must never merge.

The plugin should lint commit messages, PR titles, and PR bodies for GitHub close keywords before allowing push or PR creation. For tracked issues with remaining tracks, safe references are `(#276 Track A)` or `Addresses Track A of #276`; unsafe forms include `closes #276 Track A` and `closes #276-A`. The close-keyword guard should be mechanical because this is a documented recurring failure in the source skill. The plugin **never** writes close keywords automatically; closing is gated through `agent-bridge wave close-issue` (see §12).

PR creation should use `gh` and run preflight checks: `gh auth status`, correct active account if configured, branch pushed, target base branch, and `--no-maintainer-edit` for cross-fork workflows. If `gh` is unavailable or auth fails, the worker should still commit and return a blocked report containing branch, worktree path, and exact commands for the main agent to finish.

Trade-offs: worker-authored PR bodies keep the work self-contained, but the main agent may want to rewrite summaries for consistency. A generated template can support both by making the worker body complete but easy for the main agent to edit before merge.

**Operator decision (2026-04-26)**: **normal PRs by default** (not draft). Codex review already gates quality before PR creation; draft mode adds an extra state transition without commensurate value. Exception: when Codex review returns `needs-more` (per §4 decision), the PR opens in draft. Operator may always force draft via `--pr-mode draft`.

## 6. Main agent feedback loop

Recommended approach: completion is queue-first. When a member opens a PR or blocks, it creates a task to the main agent with a body containing wave id, member id, issue/track, PR URL, branch, worktree root, Codex plan path, Codex review path, verification commands and outputs, changed files, blockers, and recommended next action. The worker also marks its own original task done with a short note pointing to the completion task. This follows the runtime rule that substantive findings must be delivered in a new task to the requester, not buried in a done note.

The main agent owns the merge decision. It reviews the PR, requests pair review when policy requires it, posts `needs-more` findings back as a new r2 task, or merges with a structured `implement-ok` merge note. Every r2/r3 cycle should be a fresh task and a fresh brief file under the same wave member directory. After three review rounds without `implement-ok`, the plugin should mark the member `stalled` and ask the main agent to split scope or escalate.

If the requested main agent is not bridge-registered, the plugin should not silently use done notes as the result channel. It should either fail dispatch before starting workers or route completion tasks to the configured admin/coordinator with the requested recipient clearly named.

Trade-offs: queue completion adds one more task per PR, but it makes results durable across tmux restarts and visible in `agent-bridge status`. Direct messages are faster in the moment but are the wrong default for long-running wave work.

**Operator decision (2026-04-26)**: **infer `--main-agent` from `BRIDGE_AGENT_ID` / current tmux context**. Operators can override with explicit `--main-agent <agent>`. Inference is the ergonomic default; the explicit flag is required when the operator dispatches from a shell that is not bridge-managed (no `BRIDGE_AGENT_ID` set) or wants results to land on a different coordinator.

## 7. Plugin interface (base + options)

Recommended approach: define a base plugin contract that any agent can use from a terminal:

```text
Input: issue number or brief file, repo root, main agent, optional tracks.
Output: wave id, member ids, queue task ids, state file, and later PR result tasks.
State: state/waves/<wave-id>.json plus shared/waves/<wave-id>/ artifacts.
Events: audit rows for dispatch, member start, plan, review, PR open, completion, failure, cleanup.
```

The base interface should be engine-neutral. A Claude main agent, Codex main agent, or human operator can all run the same `agent-bridge wave` commands. Engine-specific behavior belongs in options: `--worker-engine`, `--planner codex|none`, `--reviewer codex-cli|bridge-review:<agent>|none`, `--pr-mode normal|draft|commit-only`, `--cleanup success|ttl|manual`, and `--max-parallel`. A `wave-policy.json` file under `BRIDGE_HOME` or repo-local `.agent-bridge/wave-policy.json` can provide defaults for reviewer, worker engine, PR mode, TTL, and bypasses.

Agent-specific options should be allowed but narrow. A Codex worker can use self-plan plus a separate Codex reviewer agent, while a Claude worker can call the Codex CLI for plan/review. A docs-only member can bypass Codex review only if policy allows it and the bypass reason is recorded in state and audit. The default for non-trivial code should remain pair-review or Codex review rather than size-based direct review.

**Default worker engine**: **Claude**. Workers default to Claude calling Codex CLI for plan/review. This preserves the current issue-fixer prompt shape and reuses the bridge's existing Claude integration. Codex workers (`--worker-engine codex`) remain opt-in for cross-engine experiments and policy-driven defaults.

Trade-offs: policy files make behavior reproducible but introduce another config layer. CLI flags are transparent for one-off waves but become repetitive and error-prone for a team operating the same workflow daily.

**Operator decision (2026-04-26)**: **both global and repo-local policy**, with repo-local taking precedence. Search order: `<repo>/.agent-bridge/wave-policy.json` -> `$BRIDGE_HOME/wave-policy.json` -> built-in defaults. Repo-local must avoid private agent names (lint check at load time); private overrides belong in `agent-roster.local.sh` or env vars.

## 8. Migration plan

Recommended approach: migrate the existing `~/.claude/skills/wave-orchestration` assets into tracked Agent Bridge plugin assets, then replace the old skill with a thin managed pointer that tells Claude users to run `agent-bridge wave`. The first release ships a deprecation shim that **`agent-bridge upgrade` installs automatically** when the legacy skill directory is present (operator decision below).

Suggested asset mapping:

| Existing skill asset | Plugin destination | Runtime use |
|---|---|---|
| `SKILL.md` | `plugins/wave-orchestration/docs/operator-guide.md` plus generated bridge skill summary | Keep orchestration spine, but replace Claude `Agent` dispatch with `agent-bridge wave dispatch`. |
| `references/brief-template.md` | `plugins/wave-orchestration/templates/brief-template.md` | Source for `wave dispatch --template` and generated member briefs. |
| `references/footguns.md` | `plugins/wave-orchestration/docs/footguns.md` and linter rules | Turn close-keyword, worktree-path, VERSION/CHANGELOG, PATH, and review-skip warnings into checks. |
| `references/recipes.md` | `plugins/wave-orchestration/docs/recipes.md` | Back `agent-bridge wave templates` and examples. |
| `references/wave-examples.md` | `plugins/wave-orchestration/docs/examples.md` | Keep as human examples, not always injected into agent context. |
| `agents/issue-fixer.md` | `plugins/wave-orchestration/agents/issue-fixer.md` or `agents/_template.wave-worker/` | Convert into portable worker instructions used by generated briefs and worker startup tasks. |

Backward compatibility should be explicit. The deprecation shim replaces `~/.claude/skills/wave-orchestration/SKILL.md` with a one-screen pointer to `agent-bridge wave` and stashes the original under `~/.claude/skills/wave-orchestration.legacy/` so operators can roll back if needed. Project-local generated skills for Codex and Claude mention the new wave command in their bridge reference once the CLI exists.

Trade-offs: preserving the old skill as a shim avoids breaking active Claude sessions, but two sources of truth can drift. Replacing it aggressively reduces drift but surprises users who rely on global Claude skills outside Agent Bridge.

**Operator decision (2026-04-26)**: **automatic migration**. `agent-bridge upgrade` (when the new release is installed) detects the legacy skill directory and:
1. Stashes the original under `~/.claude/skills/wave-orchestration.legacy/<timestamp>/`.
2. Replaces `SKILL.md` with the deprecation shim.
3. Logs the action to `logs/audit.jsonl` with `kind=skill_migration`, `from=...`, `to=...`.
4. Prints a one-line operator notice on the next `agent-bridge status` invocation.

The migration is idempotent (re-running upgrade doesn't re-stash). Operators can disable via `BRIDGE_SKIP_SKILL_MIGRATION=1` for hosts where the global Claude state must not be touched.

## 9. Dependencies & fallbacks

Recommended approach: declare hard and soft dependencies up front.

Hard dependencies for dispatch: Bash 4+, Python 3, `tmux`, `git`, a git repo root, Agent Bridge queue DB, and a registered main agent (or `--main-agent` explicit override). If any of these are missing, `wave dispatch` should fail before creating workers. Managed worktree isolation should be required by default; `--shared-workdir` can exist as an explicit emergency override but should be audited and rejected for parallel writes.

Soft dependencies: `codex`, `gh`, `shellcheck`, Homebrew Bash on macOS, network access to GitHub, and a configured review policy. If `codex` is missing, the member should fall back to a bridge review task assigned to a configured Codex reviewer agent (see operator decision below). If `gh` is missing or unauthenticated, the worker should stop at commit and report exact push/PR commands. If `shellcheck` is missing, shell workers should report the missing check and still run `bash -n`; policy can decide whether that blocks.

Known platform fallbacks should match repo guidance. macOS is a shared-UID developer target, so isolation is worktree-level plus hook/prompt guard. Linux production deployments can combine worktrees with `linux-user` isolation, but queue handoff must still go through the gateway path rather than direct SQLite access from isolated UIDs.

Trade-offs: failing early on missing hard dependencies avoids half-created waves. Allowing fallbacks for Codex and GitHub keeps workers useful in offline or auth-limited sessions, but the resulting member state must be visibly `blocked` or `commit-only`, not "complete".

**Operator decision (2026-04-26)**: **fallback to bridge review task** when Codex CLI is unavailable. Hard fail rejected because PATH/auth/sandbox incidents are too common to block all waves. The fallback path:
1. Detect Codex unavailable via `bridge-codex.sh doctor` exit code.
2. Create a queue task to a configured Codex reviewer agent (`wave-policy.json::codex_reviewer_fallback`) with the diff and a `[wave-codex-review-fallback]` title.
3. Worker waits up to `wave-policy.json::codex_review_timeout_minutes` (default 30) for the reviewer's `done` note before proceeding with the PR open.
4. Member state shows `codex-review: fallback-pending` until the reviewer responds, then `fallback-ok` or `fallback-needs-more`.

If both Codex CLI and the fallback reviewer are unavailable, the member is `blocked` rather than auto-completed.

## 10. Observability

Recommended approach: make wave state inspectable from both files and CLI. `agent-bridge wave list` should show active wave id, issue, main agent, member counts by state, open PRs, blockers, and age. `wave show` should print each member's worker, task id, worktree, branch, PR, Codex plan/review status, verification status, and cleanup status. `wave watch` can refresh the same view, similar to `agent-bridge status --watch`.

Audit rows should be emitted for at least: `wave_dispatched`, `wave_member_queued`, `wave_member_started`, `wave_codex_plan_ok`, `wave_codex_plan_failed`, `wave_codex_review_ok`, `wave_codex_review_needs_more`, `wave_pr_opened`, `wave_member_complete`, `wave_member_failed`, `wave_complete`, `wave_close_blocked`, `wave_close_invoked`, and `wave_cleanup`. Details should include `wave_id`, `member_id`, `task_id`, `worker`, `main_agent`, `repo`, `branch`, and `pr_url` where applicable. Avoid putting full prompt bodies or secrets in audit rows; those belong in `shared/waves/...` files with normal local filesystem permissions.

The main `agent-bridge status` dashboard should eventually add a compact wave line, for example `waves active=2 blocked=1 prs=3`, with details left to `wave list`. The daemon does not need to run model calls for wave observability; it can read state files, queue summaries, and audit rows just like existing status surfaces do.

**Operator decision (2026-04-26)**: **both JSON state file AND human-readable README**. Each wave writes:
- `state/waves/<wave-id>.json` — machine-readable, full schema, single source of truth.
- `shared/waves/<wave-id>/README.md` — auto-generated summary (members, status, PRs, blockers) refreshed on each state transition. Operators and other agents can `cat` it without JSON tooling.

The README is regenerated from the JSON on every state change; it is never the SSOT. If the JSON and README disagree, the JSON wins and the README is rewritten on the next transition.

Trade-offs: state files plus audit rows duplicate some information, but they serve different users: state files support resumable orchestration, while audit logs support timeline reconstruction. Adding too much to the main dashboard risks clutter, so wave-specific detail should stay in `wave show`.

## 11. Issue close discipline

`agent-bridge wave close-issue <issue> [--wave <wave-id>]` is the **only** path that closes a tracked issue. Workers and the wave plugin itself never write close keywords (`closes`, `fixes`, `resolves`) into PR titles, bodies, or commit messages. The lint check (§5) rejects any PR opened by the plugin that contains a close keyword in its title, body, or commit subject.

`wave close-issue` is invoked by the main agent (not the operator directly) once all members are merged. Logic:

1. Resolve `<issue>` and discover all wave members tagged with that issue (`state/waves/*.json` index).
2. **Validation step (automatic)**:
   - Every wave member tagged with `issue=<N>` must have `state=complete` and a merged PR (`gh pr view <pr> --json state` returns `MERGED`).
   - The wave's recorded `--tracks` list (captured at dispatch time and stored in `state/waves/<wave-id>.json`) must be fully covered: every track listed at dispatch has at least one merged member with a matching `track` tag. (Issue body is **not** parsed for track names — same as §2 dispatch contract. Coverage is checked against the operator's explicit `--tracks` list, not against issue prose.)
   - No outstanding `wave_codex_review_needs_more` audit rows in the last 24 hours for any wave member targeting this issue.
3. **On validation pass**: `gh issue close <N>` with a structured body summarizing the merged PRs, audit row `wave_close_invoked`.
4. **On validation fail**: do **not** close. Emit audit row `wave_close_blocked` with the failed reasons. Escalate to the main agent's own surface (TUI or notify-target — never admin's queue, per #345 contract). Body: "Issue #N close blocked: <reason>. Open tracks: <list>. Run `agent-bridge wave close-issue <N>` again after addressing."

Manual operator override: `--force` is reserved for the human operator only — the main agent **never** passes `--force`. When the operator (Sean) personally invokes `agent-bridge wave close-issue <N> --force`, validation is skipped and the audit row records `wave_close_invoked detail=force=operator-override`. Used only when validation logic itself is wrong (e.g., a track was implemented out-of-band as a single PR not tagged as a wave member). The agent-side automatic path always validates.

**Operator decision (2026-04-26)**: **main agent invokes `wave close-issue` automatically once all wave members merge**. The agent-driven path always runs validation — `--force` is reserved for human-operator invocation only and is never passed by the agent. On validation failure, the plugin escalates to the main agent's own operator-attached surface (TUI for dynamic main, notify-target for static main) and does not close the issue. The main agent's role here is consistent with #304/#345: admin/coordinator queue is not the escalation target; the originating surface is.

## 12. Open questions resolved

All eleven open questions from the original design draft have been resolved by the operator on 2026-04-26. Quick reference:

| # | Question | Decision |
|---|----------|----------|
| 1 | Release shape | CLI-only first; daemon integration is Phase 2 (§1) |
| 2 | Track inference | Explicit `--tracks` only; no auto-parse (§2) |
| 3 | Worker default engine | Claude calling Codex CLI (§7) |
| 4 | Codex unavailable behavior | Fallback to bridge review task (§9) |
| 5 | PR mode | Normal PR by default; draft when Codex review `needs-more` (§4); operator may always force via `--pr-mode draft` (§5) |
| 6 | Worktree cleanup TTL | 7 days for failed/blocked; immediate on merge success (§3) |
| 7 | `--main-agent` requirement | Inferred from `BRIDGE_AGENT_ID`; explicit flag overrides (§6) |
| 8 | Policy location | Both global and repo-local; repo-local precedence (§7) |
| 9 | Skill migration | Automatic via `agent-bridge upgrade` (§8) |
| 10 | Wave state visibility | JSON + README mirror (§10) |
| 11 | Issue close discipline | Agent-driven `wave close-issue` always validates; `--force` is operator-only override (§11); on validation fail, escalate to main agent's surface |

These decisions inform the Phase 1 implementation scope: CLI surface (§2), worktree integration (§3), Codex adapter (§4), PR automation with close-keyword guard (§5), main-agent feedback loop (§6), policy file loading (§7), skill migration on upgrade (§8), Codex fallback path (§9), JSON+README state (§10), and `wave close-issue` validation flow (§11).

Phase 2 will add daemon-side dashboard integration, stale wave detection, and automatic cleanup beyond the TTL-based local sweep.
