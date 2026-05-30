# Live Feature Mining

This document tracks capabilities discovered in the maintainer's long-running
private Agent Bridge runtime that may be worth redesigning for the public
project.

The goal is not to copy private runtime files into the public repository.
The goal is to extract the reusable product pattern, remove team-specific
details, and implement coherent public features.

Related meta issue: https://github.com/seanssoh/agent-bridge-public/issues/9

## Rules

- Do not port private business facts, customer data, credentials, channel IDs,
  people IDs, or vendor-specific secrets.
- Do not preserve historical OpenClaw naming unless it is required for a
  migration path.
- Prefer generic primitives over one-off scripts.
- Public features must work for a new team, not just for the maintainer's live
  environment.
- Files and databases used as indexes must be rebuildable from the canonical
  source of truth.

## Architecture Direction

The private runtime suggests a layered team operating system:

- Markdown team wiki: human-readable team knowledge source of truth.
- External databases: source of truth for structured operational data.
- SQLite/FTS/vector indexes: derived search helpers, never canonical storage.
- Raw captures: event source material that can be promoted into the wiki.
- Admin agent: operator that maintains the wiki, agents, upgrades, health, and
  issue escalation.
- Task queue and channels: collaboration transport, not long-term memory.

The public core should make those layers explicit.

## Candidate Inventory

| Area | Live artifact pattern | Problem solved in live runtime | Public capability candidate | Sensitivity | Size | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Team Knowledge SSOT | Shared context/rules/user/tool markdown files | Every agent needs the same team facts, people list, operating rules, and tool map | `shared/wiki/` with `people.md`, `agents.md`, `operating-rules.md`, `data-sources.md`, `tools.md`, `decisions/`, `projects/`, `playbooks/` | High: redact team facts and IDs | Large | P0 |
| Structured Data Registry | Tool cards for commerce, marketing, finance, calendar, and production data | Agents know which database or API owns which facts instead of guessing | Generic data-source registry plus tool cards and read/write permission metadata | High: no credentials or business data | Medium | P0 |
| Admin Agent OS | Admin notes, next-session handoff, update checklist, healthcheck scripts | The admin agent can resume operations, finish onboarding, and maintain the bridge after restarts | Standard admin playbook, `NEXT-SESSION.md` contract, update checklist, onboarding state machine | Low/Medium | Medium | P0 |
| Restart Handoff | Next-session markdown written before intentional restart | Fresh sessions can proactively continue interrupted onboarding or setup without relying on `--continue` | Generic restart handoff file consumed at session startup | Low | Small | P0 |
| Resilience and Recovery | Session watchdog, recovery markers, network watchdog, crash monitor | Stalled agents and broken relays are detected and escalated without user polling | Daemon-owned health probes, stall markers, escalation thresholds, safe restart semantics | Medium | Large | P0 |
| Context Pressure Management | Context watchdog and compaction helpers | Long-running agents avoid silent degradation and know when to compact or restart | Context pressure monitor and admin guidance for compaction/restart | Low | Medium | P1 |
| Channel Health | Channel bootstrap checks and channel-health reports | Discord/Telegram relays fail visibly and guide recovery | Channel diagnostics command, plugin health check, relay capability status | Medium: redact tokens | Medium | P0 |
| Audit and Safety | Outbound audit, input guard, hook guard, prompt-injection notes | External inputs and outbound messages are safer and traceable | Generic outbound audit log, external-input guardrails, hook safety rails | Medium | Medium | P1 |
| Tool/Credential Policy | Credentials helper and runtime credential folders | Agents can use tools without exposing secrets or inventing credential locations | Secret location policy, credential lookup helper, redacted diagnostics | High | Medium | P1 |
| Automation/Cron Orchestration | Daily briefing, event reminder, cron failure monitor, cron dispatch artifacts | Scheduled work produces auditable outputs and escalates failures | Cron run history, retry/escalation policy, optional wiki promotion | Medium | Medium | P1 |
| Agent Factory | Role templates, checklists, per-agent soul/heartbeat conventions | New agents have consistent identity, lifecycle, memory, skills, and channel setup | Role profile templates and agent creation wizard | Low | Medium | P1 |
| Collaboration Review Loops | Cross-agent/Codex review scripts and handoff patterns | Important plans and code changes get independent review before execution | Optional review gate contracts and queue-first review tasks | Low | Medium | P1 |
| Shared Operator Profile | Shared user profile, channel handles, and addressing rules reused across roles | Every long-lived agent needs the same primary human identity, aliases, handles, and approval scope without rediscovering them | Canonical operator profile contract in the shared team registry, consumed by all roles at startup | High: redact person IDs and handles | Medium | P0 |
| Structured Collaboration Handoff | `a2a-files`, queue handoff notes, and file-backed transfer conventions | Multi-agent work becomes lossy when files, images, and expected outputs are passed only as free text | Queue-first handoff bundle with artifact manifest, required action, and completion contract | Medium | Medium | P0 |
| External Intake Triage | Mail triage notes, raw captures, classification/routing workflows, follow-up drafts | External inputs need consistent filter/extract/route behavior instead of ad hoc per-role prompting | Generic capture inbox, extraction schema, queue routing, and optional human follow-up draft contract | Medium/High | Medium | P0 |
| Memory Curation | Daily memory, promotion logs, memory search skill, wiki index | Agents can retain durable lessons without loading all history | Team wiki + per-agent memory lifecycle with lint/search/promote commands | Medium | Large | P0 |
| Media/Input Capture | Inbound media metadata files and raw capture folders | Channel artifacts can be referenced without dumping raw payloads into prompts | Raw capture store with safe summaries and promotion workflow | Medium/High | Medium | P2 |
| Migration Audit | Migration plans, audit notes, compatibility backlog | Live systems can move from older runtimes without losing state | Migration audit command and compatibility checklist | Medium | Medium | P2 |

## First Product Slice: Team Knowledge SSOT

The most valuable first slice is the team-level source of truth, because many
other features depend on it.

Proposed public layout:

```text
shared/wiki/
  index.md
  people.md
  agents.md
  operating-rules.md
  data-sources.md
  tools.md
  decisions/
  projects/
  playbooks/

shared/raw/
  captures/
  channel-events/
  cron-results/

shared/indexes/
  wiki.sqlite
```

Responsibilities:

- `people.md`: team members, aliases, preferred names, channel handles, decision
  scope, communication preferences.
- `agents.md`: roster-level role descriptions, owners, channels, escalation
  paths, lifecycle expectations.
- `operating-rules.md`: global behavior, security, approval gates, language,
  reporting style, and channel rules.
- `data-sources.md`: which database/API owns which structured data, how to
  query it, and whether it is read-only or write-capable.
- `tools.md`: reusable tools, required credentials, approval requirements, and
  failure modes.
- `decisions/`: durable decisions with date, owner, rationale, and impact.
- `projects/`: active project context that applies across multiple agents.
- `playbooks/`: repeated workflows such as onboarding, incident handling,
  release, upgrade, and channel setup.

Storage policy:

- Markdown wiki is canonical for team knowledge.
- PostgreSQL or external systems remain canonical for structured business data.
- The wiki links to databases and commands; it does not duplicate large tables.
- SQLite/FTS/vector indexes are rebuilt from markdown and raw captures.
- Raw captures are source material, not the curated knowledge base.

## Proposed Follow-Up Issues

1. **Team Knowledge SSOT**
   - Implement `agent-bridge knowledge init|capture|promote|search|lint`.
   - Add `shared/wiki/` templates.
   - Update admin onboarding to create the initial people/agents/rules pages.

2. **Admin OS Restart Handoff**
   - Standardize `NEXT-SESSION.md` semantics.
   - Teach admin startup to read handoff, continue onboarding, then remove or
     archive the handoff when complete.

3. **Data Source and Tool Registry**
   - Add generic tool-card schema.
   - Add redacted credential policy and diagnostics.
   - Add read/write/approval metadata for each tool.

4. **Channel and Session Health**
   - Productize channel plugin checks, tmux loop guidance, restart semantics,
     and relay readiness checks.

5. **Resilience Markers**
   - Productize daemon-owned stall/recovery marker handling.
   - Keep it independent from channel-specific relay mechanics.

6. **Review Gate Workflow**
   - Make cross-agent review an optional queue workflow.
   - Avoid hard-coding any one provider or private agent identity.

7. **Structured Handoff Bundles** (`#23`)
   - Add a first-class handoff bundle contract for queue-first collaboration.
   - Include artifact manifests and explicit return/completion expectations.

8. **External Intake Triage** (`#24`)
   - Define the raw capture -> classify -> extract -> route pipeline.
   - Standardize `needs_human_followup` drafts instead of direct-send shortcuts.

9. **Shared Operator Profiles** (`#25`)
   - Add one canonical operator/human profile surface for all long-lived agents.
   - Keep this as a concrete slice under the broader shared-team knowledge contract (`#22`).

## Review Checklist For Porting A Live Feature

Before turning a live artifact into public code, answer:

- What reusable problem does it solve?
- Is the current live implementation a script, policy, data file, or workflow?
- What team-specific data must be removed?
- What should be canonical storage?
- What can be regenerated?
- Does this belong in core, a template, a skill, or documentation?
- What migration path is needed for existing installs?
- What smoke test proves it works on a clean install?
