# Agent Runtime — Migration Guide

> Canonical runbook for migrating an existing Agent Bridge install (agents created before the overhead redesign) into the new runtime: pointer-only `CLAUDE.md`, `docs/agent-runtime/` SSOT symlinks, `users/<user-id>/` partitioning, wiki namespace, cascade memory, and user-preference promotion. Admin (patch) executes this on each host.
>
> Related: [`common-instructions.md`](common-instructions.md), [`admin-protocol.md`](admin-protocol.md), [`memory-schema.md`](memory-schema.md), [`wiki-graph-rules.md`](wiki-graph-rules.md), [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md), [`user-preference-injection.md`](user-preference-injection.md), [`research-capture-protocol.md`](research-capture-protocol.md).

## Applies when

- Host has existing agent homes created before the overhead redesign (indicator: `CLAUDE.md` contains the full 7 KB common block hardcopy inside `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->`).
- Or host has `shared/ROSTER.md`, `shared/TOOLS.md`, `shared/SYRS-*.md` as full-body legacy SSOT files (not 1-line redirect stubs).
- Or host has any agent with `compound/lessons.md`, `recent-context.md`, root-level `USER.md` symlink, `memory/projects/<big-file>.md` research aggregations.

If `agb migrate overhead --pre-migrate --output /tmp/pre.json` reports all-green against the expected post-state, migration is already done. Skip this guide.

## Principles

1. **No destructive moves without a backup.** Every touched file gets `*.bak-<YYYYMMDD>-overhead-redesign`. Every replaced symlink gets a snapshot under `<bridge-home>/state/doc-migration/backups/<stamp>/<agent>/`.
2. **Migrate read paths first, then write paths.** Set up `docs/agent-runtime/` symlinks before deleting old hardcopy bodies, so an interrupted migration still boots.
3. **Preserve markers.** The `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` markers stay — only the body inside changes from hardcopy to pointer.
4. **Never auto-push upstream, never auto-commit.** This migration writes only to the local filesystem.

## Ordering (5-PR series — land in order)

Track 1 overhead redesign, Track 2 memory hooks, and Track 3 cascade all share a single migration sequence on the host. Source: `shared/upstream-candidates/2026-04-19-agent-md-overhead-redesign.md` §E.

### PR 1 — Template + renderer + scaffold

- Replace `agents/_template/CLAUDE.md` with the 84-line pointer-only template.
- Patch `bridge-docs.py`: add `session_type` parameter to `render_agent_bridge_block` + `normalize_claude` + `ensure_agent_shared_links`. Extend `DEPRECATED_SHARED_FILES` list.
- Patch `bridge-agent.sh` scaffold: if `SESSION-TYPE.md` says `admin`, install `ADMIN-PROTOCOL.md` symlink too.
- Land `docs/agent-runtime/{common-instructions,memory-schema,admin-protocol,migration-guide}.md` as stubs (full body lands in PR 2).

**Safety:** `MANAGED_START..MANAGED_END` regex unchanged. Existing agents that still have the hardcopy body are not touched until PR 3.

### PR 2 — Wiki promotion + legacy stubs + contract

- Promote body to `shared/wiki/{agents,tools,people,operating-rules,projects/syrs/context}.md`.
- Replace `shared/{ROSTER,TOOLS,SYRS-USER,SYRS-RULES,SYRS-CONTEXT}.md` with 1-line redirect stubs (template in `track_docs_legacy_stubs.md`).
- Fill in the full body of `docs/agent-runtime/*.md` (PR 2 of this team's deliverables).
- Expand `docs/shared-team-knowledge-contract.md` with `## Cascading summary`, `## Memory mode`, `## Roadmap expansion` sections (append-only diff).

**Safety:** stubs stay around until PR 5 at least. Symlinks from individual agents still resolve.

### PR 3 — Bulk migration CLI: `agb migrate overhead`

- New file `bridge-migrate.py` with the `overhead` subcommand. Routes from `agb` → `bridge-migrate.py overhead ...`.
- Subcommands: `--pre-migrate` (read-only inventory JSON), `--dry-run` (byte diff preview plus detected legacy inline block names), `--apply --yes` (execute with backup), `--rollback --stamp`.
- Backup convention: state backups under `state/doc-migration/backups-<stamp>/`; if legacy inline managed sections are replaced, also write `CLAUDE.md.bak-<YYYYMMDD>-managed-block` next to the file for operator inspection. Rollback uses the state backup. Apply log: `state/doc-migration/apply-<stamp>.jsonl`.
- Safety interlocks: `--apply` requires `--yes`, needs a prior `--pre-migrate` JSON, refuses to run if `docs/agent-runtime/*.md` are missing, skips admin agents if `admin-protocol.md` is missing, never calls `upstream propose`, never calls `git`.
- Verification thresholds: scaffold template ≤ 120 lines / ≤ 12 KB, per-agent `CLAUDE.md` keeps the managed block pointer-only, no legacy inline managed sections remain, no root `USER.md`, `ADMIN-PROTOCOL.md` symlink present on admin only, zero dangling symlinks at the agent home root.

**Operator runbook:**

```sh
agb migrate overhead --pre-migrate --output /tmp/pre.json
agb migrate overhead --dry-run --all > /tmp/dry.txt          # operator review
agb migrate overhead --apply --all --yes                      # executes migration
agb migrate overhead --pre-migrate --output /tmp/post.json    # diff vs /tmp/pre.json
# Rollback if needed:
agb migrate overhead --rollback --stamp <YYYYMMDD>
```

### PR 4 — Track 2 memory hooks

- `bridge-hooks.py`: register `PreCompact` event.
- `hooks/pre-compact.py`: new handler, dumps session tail via `bridge-memory capture --kind session-dump`. Exit code 0 always.
- `hooks/session-start.py`: add matcher branch for `startup | resume | compact`. Each loads appropriate raw-memory scope.
- `_template/.claude/settings.json`: `compactPrompt` (≤ 300 chars), `PreCompact` hook registration, `timeout: 20`.

### PR 5 — Track 3 long-term memory + LLM-wiki + memory mode

- `bridge-memory.py`: add `summarize weekly`, `summarize monthly`, `reconcile` subcommands.
- `bridge-knowledge.py`: `promote --llm-review` (Gemini review → canonical merge suggestions).
- `memory-manager.py`: new index kind `bridge-wiki-hybrid-v2` (additive; existing kinds untouched).
- `shared/wiki/.obsidian/` with 5 JSON config files for graph view.
- `lib/bridge-core.sh`, `lib/bridge-agents.sh`, `agent-roster.local.sh`: `BRIDGE_AGENT_MEMORY_MODE` associative array + resolver + sample entries.
- `agent-bridge migrate memory --agent <id> --mode shared|isolated` CLI.

## Per-agent migration steps (executed by `agb migrate overhead --apply`)

For each agent home under `<bridge-home>/agents/`:

1. **Inventory snapshot**: `CLAUDE.md` line count, managed-block byte size + SHA, root symlinks list, `USER.md` presence, `users/*/` partitions, research aggregations.
2. **Backup**: write the rollback copy under `<bridge-home>/state/doc-migration/backups-<stamp>/<agent>.CLAUDE.md.bak`. If the managed block contains legacy inline sections, also write `CLAUDE.md.bak-<YYYYMMDD>-managed-block` beside the file for operator inspection; rollback still uses the state backup.
3. **Render new CLAUDE.md**: call `bridge_docs.normalize_claude(agent_dir, session_type=<resolved>)`. The managed block is replaced with the pointer-only body. Custom sections outside the markers are preserved byte-for-byte.
4. **Rewire symlinks**: `bridge_docs.ensure_agent_shared_links(agent_dir, session_type)` installs `COMMON-INSTRUCTIONS.md → ../../docs/agent-runtime/common-instructions.md`, `MEMORY-SCHEMA.md → ../../docs/agent-runtime/memory-schema.md`, `CHANGE-POLICY.md → ../shared/CHANGE-POLICY.md`, `TOOLS.md → ../shared/TOOLS.md`. If admin, also `ADMIN-PROTOCOL.md → ../../docs/agent-runtime/admin-protocol.md`.
5. **Remove deprecated**: delete root `USER.md` (file or symlink) if it was pointing at `shared/SYRS-USER.md`. Delete root `SYRS-USER.md` root-level duplicate. Move `compound/lessons.md` → `memory/lessons.md`. Delete `recent-context.md` if present.
6. **Users partition**: if `users/<user>/` doesn't exist yet and a primary user was extracted from the old `SYRS-USER.md`, create `users/owner/USER.md` from its body. Cross-refs are rewritten to wiki canonical (`shared/wiki/people/<slug>.md`).
7. **Research aggregations**: if `memory/projects/<big-file>.md` is present and > 8 KB with > 3 heading sections, schedule it for `agb knowledge split-legacy --llm` (interactive; not part of `--apply --yes`).
8. **Verification**: re-inventory; assert managed block is pointer-only, no legacy inline managed sections remain, no root `USER.md`, admin has `ADMIN-PROTOCOL.md`, no dangling symlinks. Log to `state/doc-migration/apply-<stamp>.jsonl`.

## Wiki-layer migration (admin)

After PR 3 migration lands, admin runs the wiki rollout:

1. For each agent's `memory/2026-*.md` daily notes, copy into `shared/wiki/agents/<agent>/daily/<agent>-YYYY-MM-DD.md` with **body unchanged + `## Related (auto-wiki)` footer only**. See [`wiki-graph-rules.md`](wiki-graph-rules.md).
2. Extract entities/concepts/decisions/systems into the agent namespace.
3. Write `weekly-summary.md` + `monthly-summary.md` with cross-ref links only (no tree edges).
4. Dedup canonical entities (`shared/wiki/entities/<slug>.md`) following [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md). Obsidian `aliases` frontmatter is standard.
5. Remove meta-index antipattern nodes (`memory-md`, `session-handoff-md`, etc.). Split single-file anchor hubs (`people.md` with heading anchors) into per-entity files.

Cron for ongoing cascade (installed per agent after Track 3 lands):

```sh
agent-bridge cron create --name memory-summarize-daily --agent <self>   --at "10 3 * * *" --command "agent-bridge memory summarize daily --agent <self>"
agent-bridge cron create --name memory-summarize-weekly --agent <self>  --at "20 3 * * 1" --command "agent-bridge memory summarize weekly --agent <self>"
agent-bridge cron create --name memory-summarize-monthly --agent <self> --at "30 3 1 * *" --command "agent-bridge memory summarize monthly --agent <self>"
```

## Fresh install bootstrap (new server)

`agb bootstrap --yes` on a new host must produce the already-migrated layout:

1. Creates `<bridge-home>/docs/agent-runtime/` with all canonical files from the upstream repo (`~/agent-bridge/docs/agent-runtime/*.md`).
2. Creates `<bridge-home>/shared/wiki/` with `index.md` + empty canonical namespaces.
3. Scaffolds `patch` admin home from `_template.admin/CLAUDE.md`.
4. Does **not** create root `USER.md` or `SYRS-USER.md` symlinks.
5. Registers `BRIDGE_AGENT_MEMORY_MODE["patch"]="shared"` in roster.

After bootstrap, run `agb migrate overhead --pre-migrate --output /tmp/post.json` and verify all thresholds pass.

## Rollback

Per-run rollback is safe as long as the `apply-<stamp>.jsonl` and backup tree exist:

```sh
agb migrate overhead --rollback --stamp <YYYYMMDD>
```

Rollback restores:

- `CLAUDE.md` from `CLAUDE.md.bak-<stamp>-overhead-redesign` (current `CLAUDE.md` is preserved as `CLAUDE.md.rollback-<YYYYMMDD-HHMMSS>` first).
- Any symlink snapshotted under `<bridge-home>/state/doc-migration/backups/<stamp>/<agent>/`.
- Removes newly-added symlinks (e.g. `ADMIN-PROTOCOL.md`, `COMMON-INSTRUCTIONS.md`) if they were not present in the snapshot.

**Warning:** if you hand-edited the new `CLAUDE.md` after migration, those edits are lost on rollback (kept only in `CLAUDE.md.rollback-*`).

## Verification checklist (post-migration)

From `track1_verify_checklist.md` (admin runs this after `--apply`):

## Telegram Relay Removal (v0.7.0+)

The v0.6.37+ telegram-relay daemon was removed in v0.7.0. Telegram outbound
flows back through `plugin:telegram@claude-plugins-official`, with cron
children writing structured inbox tasks (PR1+PR2 of the cron inbox-only
reporting series) and parents forwarding through their own channel plugin.

For hosts that previously opted into the relay (e.g. jjujju), see
[`docs/proposals/jjujju-migration-prompt.md`](../proposals/jjujju-migration-prompt.md)
and the v0.7.0 entry in [`OPERATOR_ACTIONS_PENDING.md`](../../OPERATOR_ACTIONS_PENDING.md).
Hosts that never registered the relay require no action.

| Metric | Expected post-state |
|---|---|
| Non-admin `CLAUDE.md` max line count | ≤ 200 |
| Admin `CLAUDE.md` max line count | ≤ 220 |
| Managed block average bytes | ≤ 1 024 |
| Root `USER.md` file/symlink count | 0 |
| Dangling root symlinks | 0 |
| Admin agents with `ADMIN-PROTOCOL.md` symlink | equals admin agent count |
| `COMMON-INSTRUCTIONS.md` target | `../../docs/agent-runtime/common-instructions.md` |
| `MEMORY-SCHEMA.md` target | `../../docs/agent-runtime/memory-schema.md` |
| Wiki tree edges (per [`wiki-graph-rules.md`](wiki-graph-rules.md)) | 0 |
| Entity meta-index nodes (`-md`, `memory`, `session-handoff`) | 0 |
| Duplicate entity files (fuzzy match pre-dedup) | 0 (or tagged canonical-from) |

## Prohibited during migration

- `upstream propose --yes`, `upstream propose` (without `--yes`), or any other automatic upstream publish.
- `git commit`, `git push`, force-anything.
- Deleting custom sections of an agent's `CLAUDE.md` that live **outside** the managed block.
- Flipping memory mode without operator confirmation.
- Deleting agent memory files ahead of retention window.

## Changelog

- 2026-04-19: initial ratified version. Consolidates the 5-PR series from `shared/upstream-candidates/2026-04-19-agent-md-overhead-redesign.md` §E, the `agb migrate overhead` spec from `_workspace/track1_migration_cli.md`, and wiki-layer rollout steps from `2026-04-19-wiki-graph-build-rules.md` and `2026-04-19-wiki-entity-cleanup-dedup.md`. Fresh-install bootstrap path added so new hosts land already-migrated.
