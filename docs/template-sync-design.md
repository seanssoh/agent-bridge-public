# Template-sync — seed new agents from a reference agent (design)

**Status:** codex-signed-off design (implement-ok with amendments, agb-dev-codex 2026-05-31). Canonical spec for the 3-lane implementation wave. This file lands as `docs/template-sync-design.md`.

## Problem

On a fresh bridge install, newly-created non-admin agents come up like a brand-new Claude Code — **Sonnet, low effort, no plugins/skills/MCP** — because each agent's config tree is disjoint from the operator's system `~/.claude` and from the admin agent `patch`, and the scaffold template is bare. The operator wants an opt-in wizard that seeds new (and optionally existing) agents from a reference agent's config, with an exclude step.

## Architectural reality (the crux)

Three disjoint config planes. **model/effort/permission_mode are ROSTER-driven launch flags, never persisted to `settings.json`** (`bridge_build_static_launch_cmd`, lib/bridge-state.sh:53-75). Writing model into settings.json is a no-op — launch flags from argv win.

- **Plane A — Roster** (`agent-roster.local.sh`, git-ignored; accessors lib/bridge-agents.sh:8948-9083): model, effort, permission_mode, skills, plugins, channels. Read at **startup** (no live reload → restart to apply).
- **Plane B — Launch cmd** (derived from A at launch). Empty roster fields → `bridge_agent_uses_legacy_launch_flags` true → legacy shape `claude --dangerously-skip-permissions --name <a>` with **no `--model`** → Claude's own Sonnet default. Otherwise → `claude --model <m> --effort <e> --permission-mode <pm>` with inline defaults model=`claude-opus-4-8`, effort=xhigh, pm=auto (bridge-state.sh:68-70).
- **Plane C — `.claude/settings.json`** + managed render (bridge-hooks.py:209): autoCompact/prompt-flags/hooks only — **NO model/plugins/skills/MCP**. Out of scope for sync.

**Sync target = the ROSTER (explicit per-agent fields), never settings.json or a template file.**

## Decision: hybrid-C, materialized (NOT a live accessor fallback)

`setup template-sync` writes a controller-owned **defaults profile** into `agent-roster.local.sh`. `agent create` consumes that profile and writes the selected dimensions as **explicit per-agent roster fields** into the new role block. Optional backfill writes explicit fields to selected existing agents after a diff/confirm.

**SAFETY INVARIANT (codex catch):** the defaults profile is consumed only at **create/backfill time** to MATERIALIZE explicit fields. The accessors (`bridge_agent_model/effort/permission_mode/channels_csv/plugins_csv/skills_csv`) MUST NOT start returning a global default — that would silently flip every OLD roster with unset fields out of the intentional legacy-launch contract (bridge-state.sh:62-71, bridge-agents.sh:9366-9380). Precedence: **explicit per-agent fields always win > materialized defaults (= explicit after create/backfill) > built-in inline defaults (new-shape launch rows only, last resort)**.

## Sync set (data-only, roster-resident)

| # | Dimension | Action | Guard |
|---|---|---|---|
| 1 | model | write `BRIDGE_AGENT_MODEL[a]` | refresh built-in default opus-4-7→opus-4-8 (adjacent change, dry-run shows it) |
| 2 | effort | write `BRIDGE_AGENT_EFFORT[a]` | partial-inherit footgun: empty effort inherits new-shape xhigh, not "none" — show in summary |
| 3 | permission_mode | write `BRIDGE_AGENT_PERMISSION_MODE[a]` | **`legacy` is NEVER inherited** — omit/refuse the dimension + warn if the reference has it |
| 4 | skills | write `BRIDGE_AGENT_SKILLS[a]` | sync only the EXTRA per-agent skills (5 shared skills already auto-attached); materialize = restart/bootstrap re-run |
| 5 | plugins | write `BRIDGE_AGENT_PLUGINS[a]` | validate against installed catalog; marketplace reachability warn |
| 6 | channels | write `BRIDGE_AGENT_CHANNELS[a]` | **declarations only** (`plugin:teams@mkt`); emit per-channel setup-pending next-action (`agb setup teams <a>`) |
| 7 | MCP | **schema-only**, rides on dims 5/6 | **never copy `.mcp.json` env / secret values** |
| 8 | settings (autoCompact/hooks) | **out of scope** | renderer-owned, derived from agent_class |

## Hard security invariants
1. Never copy MCP/plugin secrets, `.mcp.json` env, API keys/tokens, `.teams`/`.ms365`/`.env`/`access.json`, refresh tokens, app passwords, client secrets — **names/schema only**; operator re-populates via the per-channel `setup` wizards.
2. Never auto-propagate `permission_mode=legacy`.
3. No silent model upgrade — dry-run / before-after diff + operator confirm; existing agents untouched until explicitly backfilled.
4. Reference read = **roster-only**. Do NOT introspect patch's live `$HOME/.claude`, installed-plugin cache, settings, env, or MCP runtime (isolation-blocked anyway). Distinguish "reference value" vs "bridge default" in output. (Future: a redacted `agent show --json` manifest; v1 stays roster-only.)
5. Same system-config mutation boundary as `agent create/update` (operator-tui / operator-trusted-id + admin context where applicable + audit). Not a weaker write path.
6. Template metadata carries NO secrets: `source_agent`, `updated_at`, `included_dimensions`, `excluded_dimensions`, hash of the redacted candidate summary.

## Behavior
- **`agb setup template-sync [--from patch] [--exclude <csv>] [--dry-run] [--yes]`** — opt-out wizard: accept-all default, per-dimension + per-item exclusion; before/after diff to stderr; structured stdout result; v1 Claude-agents only (backfill skips incompatible engines with a reason).
- **`agent create <new>`** — reads the defaults profile, materializes explicit fields (subject to the new agent's own explicit fields winning); `--dry-run` shows the new agent will get explicit model/effort/pm/plugins/skills/channels rows.
- **Backfill** — roster-only, no restart by default; per-agent diff; mark `restart_required=true` for launch/plugin/skill/channel changes; reuse existing runtime materialization paths (bridge-skills.sh:135/455-491, bridge-agents.sh channel derivation 9201-9213); print restart next-step; preserve unrelated managed-role fields.

## Shared contracts (pin to avoid cross-lane drift)

**(I) Defaults-profile format** in `agent-roster.local.sh` — a delimited, controller-owned block, e.g.:
```
# === agb:template-defaults v1 (managed by `setup template-sync`) ===
# meta: source_agent=patch updated_at=<iso> included=model,effort,plugins,skills excluded=channels,permission_mode hash=<sha256-of-redacted-summary>
BRIDGE_TEMPLATE_DEFAULT_MODEL="claude-opus-4-8"
BRIDGE_TEMPLATE_DEFAULT_EFFORT="xhigh"
BRIDGE_TEMPLATE_DEFAULT_PLUGINS="cosmax-crm,playwright"
BRIDGE_TEMPLATE_DEFAULT_SKILLS="..."
# permission_mode intentionally omitted (legacy refused / excluded)
# === end agb:template-defaults ===
```
(Final var names/format are Lane A+B+C's shared contract — Lane A reads it in `agent create`, Lane B writes it from the wizard, Lane C documents it in the example file. Whoever lands first pins it; the others match. Keep it sourceable bash + machine-parseable.)

**(II) Roster materialize interface** — Lane A exposes a callable, audited, multi-field-atomic writer (the canonical verb `agent-bridge agent roster materialize-fields <agent> --model .. --effort .. --permission-mode .. --plugins <csv> --skills <csv> --channels <csv> [--dry-run] [--json]` — the `roster` sub-dispatch lives under the `agent` subcommand of `bridge-agent.sh`; there is no top-level `agent-bridge roster`) that Lane B's wizard invokes to apply. It: writes ONLY roster fields, never settings.json; refuses `legacy`; emits a structured diff + audit; is idempotent (no-change = no-op). Lane B codes against this interface and stubs it in its own unit smoke; end-to-end apply is verified at integration.

## Tests (8 required smokes — orchestrator registers in ci-select via integration commit)
1. Dry-run from a fixture roster writes nothing + deterministic candidate/diff.
2. Apply writes only allowed roster fields, never `.claude/settings.json`.
3. Reference `permission_mode=legacy` not propagated → surfaced as refused/omitted.
4. Secret-shaped fixtures (channel creds, env, plugin state, settings) never appear in stdout/stderr or the roster.
5. `agent create newA --dry-run` after an accepted profile → new agent gets EXPLICIT model/effort/pm/plugins/skills/channels rows (not implicit launch fallback).
6. Existing agents unchanged until an explicit backfill target is selected.
7. Backfill preserves unrelated managed-role fields + reports `restart_required` for runtime-affecting fields.
8. No-reference-config patch → partial candidate with "unset / reference missing" status, not guessed values.

## Implementation gaps to close
- `bridge_write_role_block` (bridge-agent.sh:1089-1158) emits channels but NOT model/effort/plugins/skills → extend it / add the structured multi-field writer (contract II).
- Gate `setup template-sync` with the agent-create mutation boundary (bridge-agent.sh:3273-3289 pattern) + audit. Not a weaker path than the existing one-field setup writers (bridge-setup.sh:253-326).
- v1 Claude-only; backfill skips incompatible engines with explicit reason.
- opus-4-7→opus-4-8: lib/bridge-state.sh:68 + agent-roster.local.example.sh:140-142 (Lane C; surfaced in dry-run, no silent upgrade of existing agents).

## Out of scope
Channel credential migration (existing per-channel wizards), settings.json/hooks (renderer-owned), live patch-process introspection, MCP secret copying, Codex-engine semantics for these dimensions (v1).
