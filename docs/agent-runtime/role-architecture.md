# Agent Runtime — Role Architecture

> Canonical SSOT for the role boundary between Claude (main agent) and Codex (companion agent), and the hook-set design implications that flow from that boundary. This file exists because the hook inventory grew asymmetrically between the two engines without an explicit contract; future hook decisions should reference this matrix instead of mirroring engine-by-engine.
>
> See also: [`common-instructions.md`](common-instructions.md) (general runtime), [`admin-protocol.md`](admin-protocol.md) (admin role).

## Roles

### Claude — main agent

- The primary user-facing surface. Receives messages from external channels (Discord, Telegram, Teams, future Slack/Email) directly via plugin MCPs.
- Owns long-running coordination, channel-aware decisions, and any work that requires conversational context about the human.
- Hook suite is rich because Claude is the *channel-facing* runtime: it needs prompt-injection guards for untrusted external messages, surface-reply enforcement so replies land back on the channel that originated the request, session-handoff so channel context survives restarts, and permission escalation gating because operators interact with Claude directly.

### Codex — companion agent

- The reviewer / second-opinion runtime. Does not receive external channel messages directly; all input arrives as durable tasks queued by Claude (or by another Codex peer for chained review).
- Canonical example: `patch-dev` reviewing `patch`'s plan briefs and code-review briefs in the standard pair-programming flow (`AGENTS.md §"Multi-Agent Collaboration"`).
- Hook suite is *minimal by design*, not by oversight. Codex does not need channel-facing hooks because it has no channel-facing surface; it does need *companion-role* hooks for the things that go wrong specifically in review/companion work — task-mode discipline, review output shape, task brief sanity.

### Implications

- **Do not mirror Claude hooks into Codex wholesale.** The asymmetry is the point. Mirroring forces channel-facing concepts (reply tools, prompt injection guards over conversational input, compaction notes for live channel sessions) into a runtime where they are unobservable or false-positive-prone.
- **Design Codex hooks from Codex's failure modes**, not from a checklist of Claude hooks that lack a Codex twin.

## Hook classification matrix

Each Claude hook below has a classification that determines whether a Codex twin is needed and, if so, in what form. Classification rules:

- **shared** — the hook addresses a concern that exists on both runtimes. Either reuse the same implementation, or write an engine-specific implementation that satisfies the same contract.
- **shared-with-adapter** — the policy concern is shared, but the implementation needs a Codex-specific schema/event adapter before it can run on Codex.
- **channel-facing** — the hook addresses a Claude-only concern (external channel input or output). Codex does not need a twin.
- **engine-specific** — the hook addresses a runtime-specific concern (compaction model, session continuity model). Codex companion continuity is queue-based; no equivalent needed unless a concrete bug surfaces.
- **deferred** — the policy concern exists on both runtimes but the design is not yet settled (e.g. permission model). Defer until a separate design pass.

| Claude hook | Classification | Codex disposition |
|---|---|---|
| `session_start.py` (SessionStart) | **shared** | Wired via `session-start.py --format codex` (rendered by `session_start_hook_command(..., "codex")` in `bridge-hooks.py`). The legacy `codex-session-start.py` wrapper was removed in #1068 (HOOKS-SSOT); the renderer's predicate still matches the old spelling so re-rendering an existing install rewrites the command in place. |
| `mark-idle.sh` + `check_inbox.py` (Stop) | **shared** | Codex Stop wired via `check-inbox.py --format codex` (rendered by `codex_stop_hook_command()`). The legacy `codex-stop.py` wrapper was removed in #1068 (HOOKS-SSOT); the renderer's predicate still matches the old spelling so re-rendering an existing install rewrites the command in place. |
| `prompt_timestamp.py` (UserPromptSubmit) | **shared** | Already shared between engines. |
| `prompt-guard.py` (UserPromptSubmit) | **channel-facing** | Codex does not receive untrusted prompt-shaped input from external channels. Companion-role *task body* validation is a separate concern handled by the queue-time validator (preferred) or `codex-task-body-validate.py` hook fallback. Do not mirror `prompt-guard` directly. |
| `tool-policy.py` (PreToolUse) | **shared-with-adapter** | Codex executes the same dangerous local tools (Bash, file writes, network calls). Policy concern is shared. Implementation needs a Codex `PreToolUse` event adapter and a schema pass before it runs blocking; ship in dry-run/audit-only first. |
| `surface-reply-enforce.py` (Stop) | **channel-facing** | Reply tools (Discord/Telegram/Teams) are Claude-only. Codex has no equivalent surface. No twin. |
| `permission_escalation.py` (PermissionDenied) | **deferred** | Policy concern is shared, but Claude fires on `PermissionDenied` while Codex CLI exposes `PermissionRequest`; the bridge launch path also bypasses approvals on Codex today. Defer Codex twin until a separate permission-model design pass settles the contract. |
| `pre-compact.py` (PreCompact) | **engine-specific** | Codex compaction model differs from Claude's; the daemon-observer pattern in [#597] does not apply. Companion continuity is queue-based. No twin until a concrete Codex compaction continuity bug surfaces. |
| `session-handoff.py` (Stop) | **engine-specific** | Channel context handoff is a Claude/main-agent concern. Codex restart continuity is queue/task-based. No twin. |

## Companion-role hook set (Codex)

The hooks below address Codex-specific failure modes. Implementation order is risk-graded: low-risk / dry-run experiments land first; blocking-mode versions land only after the role doc names them as experiments and smoke coverage exists.

### Priority 1 — `codex-task-mode-policy.py` (PreToolUse)

**Failure mode it addresses.** A Codex task tagged `[plan]` or `[review]` is supposed to be read-only — write your conclusions, do not edit source. Manual discipline drifts: reviewers occasionally start editing files in the primary checkout when the task title clearly said "plan" or "review."

**Behavior.** Reads the currently claimed task (deterministic lookup: `status='claimed' AND claimed_by=<agent>`; ambiguity or absence → fail-open with audit). If that task title carries a plan/review prefix, denies any tool use that writes to the primary checkout. Structured tool fields cover `Edit`/`Write`/`NotebookEdit`/`MultiEdit`. **Bash classification (issue #639 redesign — Option C)** is now default-deny in block mode:

1. **Closed read-only allow-list.** Routine review commands (`git status|diff|show|log|grep|ls-files|rev-parse|blame|...`, `ls`, `cat`, `head`, `tail`, `wc`, `stat`, `file`, `du`, `rg`, `grep`, `find` without `-exec`/`-delete`, `python -c <code>` whose AST contains no `open`/`write_text`/`os.remove`/etc., plus `echo`/`printf`/`true`/`false`/`test`) are allow-listed and need no grant. New entries are policy changes — they require comments explaining read-only-ness, plus block-allow and block-deny smoke coverage.
2. **Common-shape write detector.** A small, named verb set (`rm`, `cp`, `mv`, `install`, `touch`, `sed -i`, `chmod`, `chown`, `dd`, `mkdir`, `rmdir`, `tee`, `patch`, `git` mutating subcommands, output redirections like `>file`, `1>file`, `>>file`, `&>file`) is parsed into structured `(head, target_paths)` for grant matching. PR #636 r1-r5 fixes (fd redirection, git long-flag mutating subcommands, `patch -i`/`install -t` target rules, attached `-tDEST`/`-oFILE`, combined-cluster `-rt`) are preserved.
3. **Default-deny in block mode.** Anything that is neither allow-listed nor a recognized write shape (`cargo build`, `npm install`, `awk` scripts, `bash -c "$DYNAMIC"`, command substitution, heredocs feeding interpreters, etc.) is `UNKNOWN_SHELL`. In block mode this denies; in audit mode it logs and allows. This is what closes the multi-command, substitution, exotic-interpreter, and heredoc gaps that PR #636 r1-r5 deferred.

**Carve-outs and grants.**
- `/tmp/` scratch writes are always allowed (structured tool target or every Bash write target under `/tmp/`).
- Legacy `implement-permission: <path>` grant in the task body remains supported (path-prefix containment).
- Proposed `[grants]` block in the task body:
  - `write: <path>` — equivalent to `implement-permission`.
  - `write: <known-write-command...>` — shape grant, matches when runtime command's head equals the grant's head AND every resolved write target is contained in the grant's resolved target. Example: `write: rm /Users/somewhere/build` lets `rm /Users/somewhere/build/x` through but not `cp ... /Users/somewhere/build/x`.
  - `shell: <exact command>` — exact-command escape hatch for unknown shell, exotic interpreters, heredoc bodies, and substitutions. Whitespace-normalized equality.
- Path/write grants accept `~`, `$WORKDIR`, `$PWD`, and `$TMPDIR` env expansion. Unknown variables make the grant invalid (audit warning, not a literal match).
- Free-text phrases like "implement in `<path>`" still do **not** grant write permission.

**Stage.** Land in audit-only mode first; flip to blocking after smoke proves no false-positives over a week of normal pair-programming traffic. Block-mode promotion is a separate operator decision (see "Operator: how to promote to blocking mode" below) — the issue #639 redesign **enables** safe block-mode promotion but does not change the default.

### Priority 2 — `codex-review-output-shape.py` (Stop)

**Failure mode it addresses.** Pair-programming protocol requires review responses to start with `plan-ok`, `implement-ok`, or `needs-more: <reason>`. Reviewers occasionally forget the prefix; the requesting agent then has to scan free-form text to figure out the verdict.

**Behavior.** A Stop hook (final answer is visible at stop time, unlike PreToolUse). Inspects the tail of the response. If the claimed task was a `[plan]` or `[review]` and the response does not start with one of the three approved prefixes:
- **Dry-run / audit mode** (initial deploy): emit a warning record. Do not block.
- **Blocking mode** (after smoke proves no false-positives): return `decision: block` with a structured correction prompt asking Codex to restate the result with one of `plan-ok`, `implement-ok`, or `needs-more`. This matches existing Codex Stop hook semantics.

**Why Stop, not PreToolUse.** PreToolUse only sees individual tool calls, not the final answer surface. A reply enforcement at PreToolUse would either fire too early (before the reviewer composed the verdict) or be wired to the wrong tool surface. Stop is the natural enforcement point.

### Companion piece — task-body validator (queue-time, not a hook)

The companion-role set ships **two hooks plus one queue-time validator**, not three hooks. The validator lives in the shell-layer task-create surface so it can see the recipient's roster engine/class, which the Python queue layer cannot do without that metadata.

**Failure mode it addresses.** A weak task brief (missing focus checklist, missing expected output shape) forces the reviewer to guess what the requester wants. The reviewer can return `needs-more`, but the round trip wastes a turn.

**Behavior.** `agent-bridge task create --to <codex-agent>` validates the task body **before** it's enqueued. Implementation:
- Shell-layer gate in `bridge-task.sh cmd_create`, after `bridge_require_agent` and engine lookup, applied only when recipient engine is `codex` AND title prefix is `[plan]`/`[review]`/`[review r2]` etc.
- Pure reusable helper `bridge-queue.py validate-companion-body` parses the body and returns OK/missing-list (no roster awareness in the Python layer; engine/class is decided by the shell caller).
- Body must contain a focus checklist (`## Focus checklist`, `## focus list`, or `## Focus`) AND specify expected output shape (mention of `plan-ok` / `implement-ok` / `needs-more` or a custom shape line).
- Rejects weak briefs with a structured error pointing at missing sections.

**Bypass.** `--skip-companion-validate` (shell flag, not Python). For non-`[plan]`/`[review]` task titles or non-codex recipients, the validator is not invoked at all.

**Why shell-layer, not Python-layer or hook.** `bridge-queue.py create` does not know roster metadata — it only sees agent names. The shell layer already loads the roster (`ensure_roster_loaded`) and knows engine/class. `UserPromptSubmit` would only see the surface prompt, not the durable task body, and cannot inspect it for queue-driven Codex sessions.

### Out of scope for this round

- `PermissionRequest`-based escalation. Defer until permission model design settles.
- Channel reply enforcement on Codex. Codex has no channel reply surface.
- Compaction notes on Codex. Codex compaction model differs.
- Mirroring `surface-reply-enforce.py` for Codex.

## Operator: how to promote to blocking mode

Codex companion hooks ship in **audit-only mode** by default. To promote to blocking once you have observed the audit log and confirmed no false-positives:

1. Read recent companion-hook entries in `logs/agents/<codex-agent>/audit.jsonl` for at least one week of normal pair-programming traffic. Filter on actions starting with `codex_task_mode_policy.` and `codex_review_output_shape.`.
2. Confirm zero unintended denials. If you see a false-positive, fix the hook before promoting.
3. In `agent-roster.local.sh`, set the per-install controls:
   ```bash
   export BRIDGE_CODEX_TASK_MODE_POLICY=block
   export BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE=block
   ```
   Both env vars are propagated through `bridge_export_env_prefix`, so they survive tmux/sudo/isolation launch paths. Default (unset) = `audit`.
4. Restart codex agents (`agent-bridge agent restart <codex-agent>`).

Reverting: unset the env vars (or set them to `audit`) and restart.

**Codex CLI minimum version.** This companion-hook set requires Codex CLI ≥ `0.128.0` (PreToolUse event support). Older Codex CLIs are fail-soft: hook events that the CLI does not understand are ignored, the bridge does not hard-fail. `python3 bridge-hooks.py status-codex-hooks` reports presence/absence so operators can tell.

## Wrapper staleness check (Claude side)

Several Claude hook wrappers were written in early April and have not been updated since. They are minimal (10–30 lines) and call the underlying implementation, but no smoke test verifies that the wrapper signature still matches the implementation:

- `session-start.py` → `session_start.main()` (also handles Codex via `--format codex`)
- `check-inbox.py` → `check_inbox.main()` (also handles Codex via `--format codex`)
- `mark-idle.sh` → `bridge_agent_mark_idle_now` + queue summary
- `clear-idle.sh` → `bridge_agent_clear_idle_marker`

The legacy `codex-session-start.py` and `codex-stop.py` standalone wrappers were removed in #1068 (HOOKS-SSOT). The renderer installs the direct shared modules with `--format codex`; predicate-side recognition of the old wrapper spelling remains as a migration courtesy so re-render rewrites the legacy command in place.

**Smoke coverage** for these is tracked separately (Stage 3 of the hook audit). It must verify that each wrapper's `main()` invocation succeeds with the current implementation signature, and that the codex hooks file (`~/.codex/hooks.json` template) lists the expected entries.

## When to revise this file

Revise when any of the following change:

- A new external channel surface lands on Codex (e.g. Codex CLI gains direct Slack receive). At that point the "channel-facing" classification needs a Codex column.
- The pair-programming protocol changes shape (e.g. introduces a third response prefix beyond `plan-ok` / `implement-ok` / `needs-more`).
- Codex CLI's hook surface gains or loses a hook event the matrix references.
- **Claude hook inventory or event wiring changes** (this file is a Claude-hook classification matrix, not only a Codex-hook-surface matrix; a moved Claude hook or a renamed event invalidates the rows above).
- A new companion-role failure mode is observed in production. Default trigger: at least two distinct codex agents AND lasts more than a session. **High-severity exception**: a single destructive or security-relevant companion-role failure is enough to revise immediately, regardless of distinct-agent count.

Do not add a Codex hook just because Claude has one. Add a Codex hook because a companion-role failure was observed and named.

## References

- [`common-instructions.md`](common-instructions.md) — general agent runtime
- `AGENTS.md §"Multi-Agent Collaboration"` — pair-programming protocol
- `bridge-hooks.py` — `is_codex_*_hook` predicates and `ensure_codex_hooks` wiring
- `hooks/` — current implementation directory
- Originating mining: `shared/upstream-candidates/2026-05-06-hook-inventory-audit-codex-claude.md` (held-for-design-discussion until this file lands)
