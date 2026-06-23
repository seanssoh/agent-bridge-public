# Agent Runtime — Memory Schema

> Canonical SSOT for how every Agent Bridge runtime stores short-term, long-term, and team-shared memory. The bridge renders this body into `<bridge_home>/shared/MEMORY-SCHEMA.md`, and each agent home installs `MEMORY-SCHEMA.md` as a symlink that resolves to that shared file (depth-correct on both v1 `agents/<a>/` and v2 `data/agents/<a>/home/` layouts; issue #1813/#1814). The old per-agent `MEMORY-SCHEMA.md` template-fork copies are deprecated and retired — one body, two locations, lockstep by construction, exactly like `common-instructions.md`.
>
> Related canonical docs: [`common-instructions.md`](common-instructions.md), [`wiki-graph-rules.md`](wiki-graph-rules.md), [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md), [`research-capture-protocol.md`](research-capture-protocol.md).

## 1. Three-layer model

Every agent has three memory layers. They must not blur into each other.

| Layer | Where | Who writes | Who reads | Lifetime |
|---|---|---|---|---|
| **Raw (short-term)** | `agent/memory/<daily>.md` + `memory/raw/*.md` + Track 2 capture artifacts | the agent itself | the agent itself; cascading summarizer | rolling 7–30 days |
| **Wiki (long-term)** | `shared/wiki/agents/<agent>/` namespace + `shared/wiki/{entities,concepts,decisions,systems}/` canonical | the agent (namespaced) + admin (canonical) | any agent; humans via Obsidian | durable |
| **Schema (this file + canonical docs)** | `docs/agent-runtime/*.md` | admin | every agent | semver |

The **raw** layer is the ground truth of "what happened". The **wiki** layer is the curated distillation. The **schema** layer is how the first two are supposed to be organized.

Rule: *raw* never automatically overwrites *wiki*. *wiki* never retroactively rewrites *raw*. Promotion from raw → wiki goes through `agent-bridge knowledge promote` with LLM review.

## 2. Raw layer — agent short-term memory

Directory layout per agent home:

```
agents/<agent>/
├── MEMORY.md                     # index only — latest summary + pointers
├── memory/
│   ├── YYYY-MM-DD.md             # daily note (one file per operating day)
│   ├── raw/                      # raw captures (bridge-memory capture output)
│   ├── weekly/YYYY-Www.md        # weekly cascade (Track 3)
│   ├── monthly/YYYY-MM.md        # monthly cascade (Track 3)
│   ├── lessons.md                # moved from old compound/lessons.md
│   ├── research/                 # research-capture-protocol.md scope
│   └── decisions/                # agent-local decisions (team-wide → wiki)
├── state/
│   └── session_handoff.md        # bridge daemon writes; agent does not edit
└── users/<user-id>/
    ├── USER.md                   # per-user profile (root USER.md symlink폐지)
    └── MEMORY.md                 # per-user memory
```

Deprecated and removed in PR 1/2:

- Root `USER.md` global symlink — deleted. Use `users/<user-id>/USER.md`.
- Root `SYRS-USER.md` symlink — replaced by `shared/wiki/people/<slug>.md` canonical pages.
- `compound/lessons.md` — moved to `memory/lessons.md`.
- `recent-context.md` — retired; daemon state goes to `state/`, human summary to the daily note.

### Daily note

- One file per day. Append-only during the day. Sections: `## Morning handoff`, `## Work log`, `## Decisions`, `## Followup`.
- **Canonical path is `<agent-home>/memory/<date>.md` for every user**, including `default` (issue #220). The legacy split where the `default` user wrote to `<home>/memory/` and other users wrote to `<home>/users/<user>/memory/` is retired; the actual writer (`bridge-memory.py daily-append`) takes no user argument and always lands in the shared root. Pre-220 installs that have leftover notes under `<home>/users/default/memory/` should run `bridge-memory.py migrate-canonical --home <home> --apply` once. The `users/<user>/memory/` directory remains a multi-tenant escape hatch for hand-staged notes (still indexed by `rebuild-index`), but is not the bridge writer's target.
- Do **not** anchor cross-agent knowledge here — put team-wide facts into `memory/research/` or promote to wiki.
- Cross-refs at the bottom follow the wiki graph rules: `## Related (auto-wiki)` with entities/concepts/decisions/people only. No tree edges (`[[<agent>-weekly]]`, `[[agents#<self>]]`). See [`wiki-graph-rules.md`](wiki-graph-rules.md).

### Research captures

Research-producing agents (syrs-derm, syrs-trend, syrs-creative, newsbot, syrs-buzz, syrs-production) follow the stricter schema in [`research-capture-protocol.md`](research-capture-protocol.md). One research unit = one file with YAML frontmatter. No append-per-section into category files.

### MEMORY.md (index)

- < 5 KB. Contains only: pointer list, "Latest Check" summary, cross-links to the current week's daily notes.
- Full history lives in `memory/YYYY-MM-DD.md` archive — never embed archive content back into `MEMORY.md`.

## 3. Short-term continuity — session hooks (Track 2)

Session compaction and restart are the two places where short-term memory is most likely to vanish. Three hooks preserve it.

### 3.1 `PreCompact` hook

- File: `hooks/pre-compact.py`.
- Trigger: Claude Code `PreCompact` event (new in Track 2).
- Behaviour: read `trigger` + `custom_instructions` + current task id, write `bridge-memory capture --kind session-dump` so the next session can recover.
- Timeout: 20s. **Exit code 0 is mandatory** — a non-zero exit blocks the compaction, which is worse than losing a session tail.
- If capture fails, log to `state/doc-migration/...` and still return 0.

### 3.2 `SessionStart` matcher (3 modes)

- File: `hooks/session-start.py`.
- Matchers: `startup` (cold boot), `resume` (transcript replay), `compact` (post-compaction).
- Each matcher calls `bridge-memory search --scope raw` with appropriate filters. `compact` mode specifically pulls the last `session-dump` capture.
- If the matcher finds `NEXT-SESSION.md`, surface it first regardless of mode.

### 3.3 `compactPrompt`

- Location: `_template/.claude/settings.json`.
- Length: ≤ 300 chars (Claude Code requirement). Current canonical is 280 chars and preserves: task id, last decision, open blocker, pending tool-calls.
- Do not add role-specific instructions to `compactPrompt` — role shape lives in `SOUL.md`.

## 4. Long-term memory — cascading summary + shared wiki (Track 3)

The cascade compacts noise into layered summaries while keeping provenance.

| Cadence | Source | Destination | Source retention |
|---|---|---|---|
| daily | raw captures + daily note (last 24h) | `memory/daily/YYYY-MM-DD.md` | keep raw 7 days |
| weekly | 7 daily notes | `memory/weekly/YYYY-Www.md` | keep daily 30 days |
| monthly | 4–5 weekly notes | `memory/monthly/YYYY-MM.md` | keep weekly 180 days |
| promoted | any cadence | `shared/wiki/` (team) or agent-local curated page | follows source window |

CLI surface:

```sh
agent-bridge memory summarize daily [--agent <id>] [--date YYYY-MM-DD]
agent-bridge memory summarize weekly [--agent <id>] [--week YYYY-Www]
agent-bridge memory summarize monthly [--agent <id>] [--month YYYY-MM]
agent-bridge memory reconcile [--agent <id>]
agent-bridge knowledge promote --agent <id> [--llm-review]
```

Cron example (land alongside Track 3 PR):

```sh
agent-bridge cron create --name memory-summarize-daily --agent <self>   --at "10 3 * * *"   --command "agent-bridge memory summarize daily --agent <self>"
agent-bridge cron create --name memory-summarize-weekly --agent <self>   --at "20 3 * * 1"   --command "agent-bridge memory summarize weekly --agent <self>"
agent-bridge cron create --name memory-summarize-monthly --agent <self>   --at "30 3 1 * *" --command "agent-bridge memory summarize monthly --agent <self>"
```

Key rule: **the cascade never deletes source ahead of its retention window. It compacts summaries, not raw truth.** An agent must still be able to replay the original capture if a durable fact is challenged.

## 5. Wiki layer — team-shared brain

### 5.1 Namespace

```
shared/wiki/
├── agents/<agent>/
│   ├── daily/<agent>-YYYY-MM-DD.md        # read-only copy of agent daily (no body rewrite)
│   ├── weekly-summary.md
│   ├── monthly-summary.md
│   ├── entities/<slug>.md
│   ├── concepts/<slug>.md
│   ├── decisions/YYYY-MM-DD-<slug>.md
│   └── systems/<slug>.md
├── entities/<slug>.md                      # team-canonical (admin-curated)
├── concepts/<slug>.md
├── decisions/<slug>.md
├── systems/<slug>.md
├── people/<slug>.md                        # one person per file (myo.md, sean.md, ...)
├── projects/syrs/                          # legacy syrs-meta namespace
└── .obsidian/                              # Obsidian vault config (humans only)
```

Each agent writes under its own `agents/<agent>/` namespace — no race with other agents. Cross-agent canonical entities get merged into `shared/wiki/entities|concepts|decisions|systems/` by admin. See [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md).

### 5.2 Graph edges

Strict rules in [`wiki-graph-rules.md`](wiki-graph-rules.md). Quick summary:

- **Keep** cross-references: `daily ↔ entities/concepts/decisions/systems`, `entities ↔ concepts`, `decisions ↔ entities`, `daily ↔ people/<person>`.
- **Forbid** tree edges: `daily ↔ weekly-summary`, `weekly ↔ monthly`, `daily ↔ agents#<self>`, index → rollup autolinks, and per-namespace tree rollups.
- Daily notes copied into wiki: **body unchanged**. Only append `## Related (auto-wiki)` at the bottom.

### 5.3 Memory mode (roster switch)

`BRIDGE_AGENT_MEMORY_MODE["<agent>"]` controls whether the agent participates in wiki promotion.

- `shared` (default): agent reads/writes `shared/wiki/`, participates in cascade promotion.
- `isolated`: agent only uses its own `memory/` tree. Cascade summarize still runs; `knowledge promote` is skipped.

Override precedence: `state/agents/<agent>/agent-env.sh` > roster associative array > default `shared`. Resolver is `bridge_agent_memory_mode()` in `lib/bridge-agents.sh`.

Mode transitions:

- `shared → isolated`: agent stops writing to `shared/wiki/`. Existing entries it owns remain, but read-only from its perspective.
- `isolated → shared`: CLI dry-runs which local curated pages would be promotable. No automatic mass promotion — each file is promoted explicitly.

CLI: `agent-bridge memory mode set <agent> shared|isolated` (land with Track 3 PR).

## 6. LLM-wiki hybrid search

- Index kind `bridge-wiki-hybrid-v2` (Gemini embeddings + FTS5) is **additive** to the existing `bridge-wiki-fts-v1` and `legacy-hybrid` kinds. Existing indexes keep working.
- `bridge-knowledge promote --llm-review` uses Gemini to suggest canonical merges. Fallback: legacy text match if Gemini unavailable.
- `memory-manager.py` routes a search through whichever kinds are enabled on the agent.

## 7. User preference promotion (feedback → overhead)

Three scopes, in order of implementation effort and blast radius:

### 7.1 User-specific preferences → shared user profile (Issue #162 Phase 1, landed v0.5.x)

The default path for "this user wants the agent(s) working with them to behave this way." Write with:

```
agent-bridge memory promote --agent <agent> --kind user-profile \
    --user <uid> --summary "<one-line rule>"
```

The entry lands in `shared/users/<uid>/USER.md` under the `## Stable Preferences` section. Every agent whose `users/<uid>/` is linked to the canonical picks it up at next session start via the existing `CLAUDE.md` read-order step (`users/<user-id>/USER.md`). No new file, no new pointer chain — reuses the surface the agent already reads early in boot.

The promoted `## Stable Preferences` section is intentionally distinct from the hand-edited `- Stable preferences:` bullet in the Identity/Working Notes skeleton, so promoted rules do not clobber the operator's manual edits.

### 7.2 Agent-role-specific operating rules → ACTIVE-PREFERENCES.md (Phase 2, spec'd, not yet landed)

When a rule applies only to one agent's role (not to every agent working with the user), it belongs in `agents/<agent>/ACTIVE-PREFERENCES.md`. Pointer added to the agent's `CLAUDE.md` read-order list; file is silently skipped when absent. See [`user-preference-injection.md`](user-preference-injection.md) for the full spec.

### 7.3 Team-wide operating rules → `docs/agent-runtime/active-preferences.md` (Phase 3, admin-gated)

For rules every agent in the team must follow (comms protocols, escalation patterns). Admin-only write gate; other agents propose via a queue task to admin. See [`user-preference-injection.md`](user-preference-injection.md).

## 8. Legacy migration

All agents today have at least some of the following that must be cleaned up on migration (see [`migration-guide.md`](migration-guide.md)):

- Drifting per-agent `MEMORY-SCHEMA.md` → replace with symlink to this file.
- `compound/lessons.md` → rename to `memory/lessons.md`.
- Root `USER.md` (+ `SYRS-USER.md`) symlinks → delete. Migrate to `users/<user-id>/USER.md` + `shared/wiki/people/<slug>.md`.
- `recent-context.md` → delete. Daemon state moves to `state/`, human summary goes into the current daily note.
- `memory/projects/<big-file>.md` research aggregations → split via `agb knowledge split-legacy --llm` into `memory/research/<type>/<slug>.md`. Original becomes a link-only index.

## 9. Changelog

- 2026-04-19: initial ratified version. Merges the old drift-prone per-agent `MEMORY-SCHEMA.md` copies. Introduces 3-layer model (raw / wiki / schema), Track 2 hook surface (PreCompact + SessionStart 3-matcher + compactPrompt), Track 3 cascade (daily/weekly/monthly + reconcile), wiki namespace + memory mode. Cross-references `wiki-graph-rules.md`, `wiki-entity-lifecycle.md`, `research-capture-protocol.md`, `user-preference-injection.md`, `migration-guide.md`.
