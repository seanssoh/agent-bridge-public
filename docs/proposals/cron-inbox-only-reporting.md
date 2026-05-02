# Plan — cron → main-session inbox-only reporting + telegram-relay 폐기

**Status**: DRAFT, awaiting operator review
**Author**: agb-dev-claude (with Codex design-ok #2819, 2026-05-02)
**Operator brief**: Sean, 2026-05-02 11:20 KST
**Related issues / PRs**: #468 (race cascade), #475 (relay daemon — to be reversed), #496 (this PR family's preceding hotfix)

## Goal

Eliminate three intertwined problems in cron behavior:

1. **Context pollution** — recurring "no problem" reports flooding the main session.
2. **Race condition** — cron child and main session both writing to the same external channel (Telegram, Discord) over a singleton resource.
3. **Visibility gap** — main session can't reason about its own crons because their output never lands in its conversation.

End state:

- **Outbound external channels (Telegram/Discord/etc.) are the main session's sole responsibility.** Main session uses Claude Code's official channel plugins. No daemon, no relay, no cron child ever opens an outbound socket on those channels.
- **Cron behaviour:**
  - `silent`: log to existing `state/cron/runs/<run_id>/` artifacts, exit. Don't create an inbox task.
  - `main_session_only`: queue an inbox task to the parent agent with structured frontmatter; main absorbs the info into context, no user-facing send.
  - `forward_to_user`: queue an inbox task with `forward_target` (channel + logical target ref + format). Main resolves the target against its own routing config and sends through its official plugin.
- **Cron children physically cannot reach external channels.** No channel plugins loaded, no MCP tools available, no `agb urgent/task/handoff` shortcuts for delivery. Enforced by removed flags + result validation, not just prompt guidance.
- **`disposable_needs_channels` and the telegram-relay daemon are deleted.**

## Why now

`v0.6.37`–`v0.6.39` shipped a relay-daemon architecture (#475 phase 2/3) that mutated from "fix the race" to "replace the official Telegram plugin." That direction is wrong; it duplicates Claude Code's first-party transport for a problem that is solved more cleanly by making the cron a producer instead of a sender. This plan reverses that direction and puts cron output behind a structured inbox contract.

## Architecture

```
                     ┌──────────────────────────────────────────────┐
                     │          main session (jjujju, etc.)         │
                     │                                              │
   external channels │   ↑ Telegram (in/out via official plugin)   │
   ◀────────────────►│   ↑ Discord  (in/out via official plugin)   │
                     │   ↑ Mattermost (in/out via plugin)          │
                     │                                              │
                     │   ── reads inbox tasks (from cron) ──        │
                     │   ── routes to channel based on frontmatter ─│
                     └──────────────────────────────────────────────┘
                                          ▲
                                          │ agent-bridge inbox task
                                          │ (one per non-silent run)
                                          │ frontmatter: delivery_intent, forward_target, …
                                          │
                     ┌──────────────────────────────────────────────┐
                     │   cron child (claude -p / codex exec)        │
                     │   - no channel plugins                       │
                     │   - no `agb urgent/task/handoff` for delivery│
                     │   - if no signal → log + exit (silent)       │
                     │   - if signal → write inbox task + exit      │
                     └──────────────────────────────────────────────┘
                                          ▲
                                          │ cron schedule fires
                                          │ bridge-cron-runner.py
```

## Implementation choice (decision)

**Option C — runtime injection + per-job override.** Selected over Option A (creation-time prompt template) and pure Option B (runtime injection only) because:

- **Centralized** — one preamble in `bridge-cron-runner.build_prompt()` covers every existing cron the moment the PR lands. No per-job migration needed.
- **Hard to bypass** — the policy preamble is at the top of every cron prompt; subsequent operator prompt content is positioned as a scoped task within the policy's frame.
- **Per-job opt-out** — `metadata.cron_reporting_policy` (allowed values to be enumerated in PR1) lets specific jobs override default silent-on-no-signal (e.g., heartbeat that needs to confirm liveness every tick).
- **Defense in depth** — runtime injection alone is not enforcement; PR1 also (a) physically removes channel plugins from the cron child and (b) validates the result JSON contains a `delivery_intent` and no legacy direct-send markers.

This matches Codex's correction in #2819 "Runtime prompt injection is necessary but not sufficient. … enforce with disabled channel tools and result validation."

## PR series (Codex-recommended order)

### PR1 — cron reporting contract

Single-file dominant change in `bridge-cron-runner.py` plus minor surface in `lib/bridge-cron.sh`, `bridge-queue.py`, smoke tests.

Scope:

1. **Result schema additions** — extend `RESULT_SCHEMA` (Claude `--json-schema` and Codex `--output-schema`) with:
   - `delivery_intent`: enum `silent | main_session_only | forward_to_user`. Required.
   - `forward_target` (object, required when `delivery_intent = forward_to_user`): `{ channel, target_ref, format }`. Channel is enum `telegram | discord | mattermost | …`. `target_ref` is a logical name (not a chat ID or webhook URL). `format` is `markdown | text`.
   - `summary_short`: required when `delivery_intent != silent`, ≤ 200 chars.
   - Existing `channel_relay` is renamed to a deprecated alias of the structured fields and removed in PR2 cleanup.
2. **Policy preamble in `build_prompt()`** — prepended to every cron prompt:
   - Cron child must NOT call any external channel directly (no telegram/discord MCP tools, no shell-outs for delivery, no `agb urgent/task create/handoff` for delivery).
   - Decide `delivery_intent`. Default `silent`. Pick `main_session_only` only when the parent must know. Pick `forward_to_user` only when the run produced a human-facing alert.
   - For `silent`, set summary fields to empty; the runner will skip the inbox task.
   - For non-silent, set `summary_short` and `body` (markdown).
   - Parent identity is `<target_agent>`; main session = parent.
3. **`disposable_needs_channels` deprecation** — flag is read-only honored (audit-log warn) but no longer adds `--channels` or loads MCP plugins. The cron child runs in `--strict-mcp-config` mode unconditionally.
4. **`allow_channel_delivery` rename → `allow_structured_relay`** — old name kept as alias for one minor version, audit-log warn on use. Updated docs/help text.
5. **Result validation in runner** — on `claude -p` / `codex exec` return:
   - Reject results with no `delivery_intent` (schema-required).
   - Reject results with `delivery_intent = forward_to_user` but no `forward_target` (schema-required).
   - **Direct-send markers (`tg_send`, webhook URLs, raw chat IDs, etc.)**: per Sean 2026-05-02 — **defer hard reject to v2.** v1 only emits a one-line `cron_audit` event when a marker is detected so we can quantify whether LLMs actually try this in practice. If observed → add reject in follow-up PR. v1 keeps the door open without false-positive blocking (e.g., a body that legitimately quotes a webhook URL in summary text).
   - On schema-required reject: write `result.json` with `reporting_decision = invalid`, log to stderr, exit non-zero (cron run is marked failed; daemon picks up via existing health path).
   - **Log volume rule (Sean 2026-05-02)**: cron audit entries are one line per run. Format: `cron_audit job=<name> run=<id> intent=<intent> task=<id|null> markers=<n>`. **Do not dump full LLM output to logs.** If markers > 0, attach offending substring (≤ 80 chars) for diagnosis, no more.
6. **Inbox task creation** — for `delivery_intent != silent`:
   - Use existing `bridge_queue_cli create --to <parent_agent> --from cron --title "[cron-followup] <job_name> (<delivery_intent>)" --body-file <frontmatter+body>` path.
   - Body file is markdown with strict JSON-frontmatter (parsed without PyYAML), schema_version=1.
   - Priority maps from new `metadata.cron_urgency` field (`normal | high | urgent`); default `normal`.
7. **Dedupe semantics fix** (Codex caught this) — replace existing prefix-only dedupe `[cron-followup] <job> (` with:
   - `main_session_only`: refresh-by-job (prior open task with matching `job_id` is updated in place — context is "current state of this monitor").
   - `forward_to_user`: dedupe by `run_id` only — every distinct human-facing alert gets its own task. NEVER overwrite an unread `forward_to_user` task.
   - Implementation: extend `bridge_queue_cli find-open` selector with `--mode refresh-by-job` and `--mode per-run`.
8. **Silent-exit audit** — extend `result.json` and `status.json` with:
   - `reporting_decision`: `silent | reported | invalid`
   - `delivery_intent`: copy of the field
   - `inbox_task_id`: null if silent, otherwise the created queue task id
9. **Smoke test (Codex caught this)** — current smoke only tests synthetic result file, not runner→result→followup end-to-end. Add integration test in `scripts/smoke-test.sh` that:
   - Invokes a fake cron with each of the three `delivery_intent` values
   - Verifies inbox state (silent → no task; main_only → refresh-by-job; forward → per-run)
   - Verifies `result.json`/`status.json` audit fields
   - Verifies dedupe semantics (two consecutive `main_only` runs → 1 open task; two consecutive `forward_to_user` runs → 2 open tasks)
10. **Schema migration**: none required (no new task columns; frontmatter inside `body_text`).

PR1 verification:
- `bash -n` + `shellcheck` for `*.sh` files
- `python3 -m py_compile` for `*.py` files
- New smoke integration test passes
- Existing smoke (queue/static-role/daemon) passes
- Pair-review with Codex per CLAUDE.md

### PR2 — main session handling helpers + parent-side docs

Smaller, doc-and-helper-heavy.

Scope:

1. **Frontmatter parser helper** — Python helper at `lib/bridge_cron_followup.py` exposing `parse_followup(body_text) -> dict | None`. Strict JSON frontmatter, no eval, schema_version check. Used by parent-session helpers, future status views, and potential daemon-level routing diagnostics.
2. **Main-session prompt instructions** — extend the admin/parent agent template's session-start instructions to:
   - Recognize `[cron-followup]` titled tasks
   - Parse frontmatter via the helper
   - For `main_session_only`: read body, update internal model, close task with `decision: absorbed`.
   - For `forward_to_user`: resolve `forward_target.channel` against the agent's routing config (parent agent owns this — telegram/discord plugin enabled in agent settings), deliver, close task with `decision: forwarded ts=<ts>`.
3. **`agb cron status` update** — extend status output to show last-run `reporting_decision`, `delivery_intent`, and (if reported) `inbox_task_id` so operators can trace cron→inbox→main flow without grep.
4. **OPERATOR_ACTIONS_PENDING.md entry** — informational: "v0.6.x cron behavior change; existing crons now silent-on-no-signal automatically. No action required, but `agb cron list` may show fewer follow-up tasks against admin agents — this is expected."
5. **Docs** — update `ARCHITECTURE.md` (new "Cron reporting contract" section), `docs/developer-handover.md` (new "Adding a cron with reporting" walkthrough), `docs/agent-runtime/admin-protocol.md` (parent's responsibilities for cron followups).

PR2 verification:
- Doc lint (markdown links)
- Helper unit test (frontmatter parse edge cases — missing field, schema_version mismatch, unknown intent, malformed JSON)
- Pair-review with Codex

### PR3 — telegram-relay reversal/removal

Big, mostly deletion + setup-default rollback.

Scope:

1. **Setup defaults** — `bridge-setup.sh` / `bridge-setup.py telegram` no longer defaults to `--use-relay`. Default flips back to the official `plugin:telegram@claude-plugins-official` path. `--use-relay`/`--no-relay` flags removed (or kept as no-op with deprecation warning for one minor — TBD, Codex prefers full removal).
2. **Daemon supervision** — remove `bridge_telegram_relay_supervise` from `bridge-daemon.sh`. Stop supervising the relay process.
3. **CLI / plugin / state** — delete `agent-bridge telegram-relay`, `bridge-telegram-relay.sh`, `lib/telegram-relay.py`, `plugins/telegram-relay/`. Drop `BRIDGE_TELEGRAM_RELAY_*` env vars from documented surface (keep recognition for one minor with warning, then remove).
4. **`bridge-status.py`** — drop relay status fields.
5. **Smokes** — delete `scripts/smoke/telegram-relay*`.
6. **Operator migration note** — `OPERATOR_ACTIONS_PENDING.md` entry:
   - Existing relay registrations (e.g., on jjujju host): re-run `agent-bridge setup telegram <agent>` (now defaults to official plugin) to migrate.
   - Stop the relay daemon manually if it was supervised by something other than `bridge-daemon.sh` (e.g., a systemd unit installed by an early v0.6.37 setup).
   - Remove `BRIDGE_TELEGRAM_RELAY_*` env vars from `~/.agent-bridge/agent-roster.local.sh` if present.
7. **CHANGELOG** — explicitly call out that #475's relay daemon (Phase 2/3) is reverted, with rationale referencing this design.

PR3 verification:
- Full smoke (`./scripts/smoke-test.sh`) passes (excluding the pre-existing `TMP_ROOT` failure)
- `oss-preflight.sh` passes
- jjujju host migration walkthrough (operator action) — out-of-band manual verification by Sean before merge
- Pair-review with Codex

### Recommended release shape

- PR1 + PR2 → v0.6.40+ minor or patch series. Behavior change is operator-invisible (no flag flips) so a patch is acceptable.
- PR3 → v0.7.0 minor (the relay reversal is a documented removal of a v0.6.x feature; semver-clean to bump minor).

## Operator decisions (Sean 2026-05-02)

- **Q-A** (forward routing config): reuse existing — `settings.local.json` `enabledPlugins` + `agent-roster.local.sh`. **Confirmed.**
- **Q-B** (reporting policy override values): `default | always_main_session | always_silent` only. No `force_forward_to_user`. **Confirmed.**
- **Q-C** (legacy direct-send marker enforcement): **deferred** — v1 only logs detections (one-line `cron_audit`) so we can measure whether LLMs actually try direct send. Hard reject ships only if it becomes a real problem. Log volume kept tight (one line, ≤ 80 char marker excerpt, no full LLM output dump).
- **Q-D** (agentTurn deprecation): deprecate, treat as text. **Confirmed.**
- **Q-E** (PR3 timing): PR1+PR2 first; PR3 (relay removal) batched separately for a later release once PR1+PR2 stabilize the race. **Confirmed.**
- **Q-F** (jjujju host migration): manual operator action on the jjujju host post-PR3. Sean asked for a self-contained migration prompt that can be sent verbatim to the jjujju agent (not auto-scripted into `agent-bridge upgrade --apply`). See `docs/proposals/jjujju-migration-prompt.md` (delivered alongside this plan).

## Open questions for Sean

(All Q-A through Q-F resolved 2026-05-02 — see Operator decisions section above.)

## Risks

- **Existing crons relying on direct-send instructions in their prompt** — PR1 makes those instructions a no-op (no channel tools). The cron will run, the direct-send will silently not happen. Audit-log warns the operator on the next run. Mitigation: PR1 also rewrites the prompt preamble to explicitly tell the child not to attempt direct send, so the LLM doesn't waste tokens trying.
- **Main session falls behind on inbox** — If the parent agent is stopped (jjujju case), `forward_to_user` tasks pile up unread. They are not dropped, and once the parent reattaches it sees them. Acceptable v1 behavior. Daemon-level fanout on extreme delay is out of scope.
- **PR3 reversal anger** — Anyone who wrote tooling against `BRIDGE_TELEGRAM_RELAY_ENABLED` after v0.6.37 will see breakage. Since the relay was only ever shipped against the SYRS reference install, blast radius is small.
- **Schema validation false-positive** — The legacy-marker reject list might trip on legitimate body content (e.g., a cron summarizing a Slack incident that contains a webhook URL in its description). Mitigation: require markers in *intent* fields (forward_target / summary_short / direct-send fragments at action position), not anywhere in body.

## Verification gates per PR

- All three PRs follow the existing CLAUDE.md pair-review contract (Codex r1 → up to r3 max → squash merge after `implement-ok`).
- PR3 additionally requires operator-side manual verification on the jjujju host (Sean confirms migration works) before merge.
- After all three land, post-deploy verification: a real cron tick on the SYRS reference install runs end-to-end → main session sees inbox task → parent forwards correctly via official plugin → cron child shows `--strict-mcp-config` in audit log.

## What this plan does NOT change

- Stall watchdog logic (covered by v0.6.40 #496).
- Live-session tmux `send-keys` urgent-send paths.
- The agent-bridge inbox/queue mechanics themselves.
- Any other channel plugin (Discord, Mattermost) — those don't have the relay daemon issue.
- Memory-pipeline / always-on-cost concerns (#389, #390).
