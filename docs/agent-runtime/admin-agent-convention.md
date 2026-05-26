# Agent Description Convention

> Operator-facing convention for `BRIDGE_AGENT_DESC` — the human-readable
> identity string carried on every agent in the roster. Not a runtime
> protocol; this doc tells operators what to write when they set up a new
> install or add a role. See [`admin-protocol.md`](admin-protocol.md) for
> the runtime admin contract and [`role-architecture.md`](role-architecture.md)
> for the broader role taxonomy.

## Why this matters

Downstream agents (other Agent Bridge installs reachable over A2A,
operator-side cosmax-CRM plugins, queue inspectors) read each agent's
description string from `agent show <name>` / `agent describe <name>` to
decide:

- Who to address for which kind of request.
- Which queue inbox is the right destination for a routed task.
- What kind of work each agent considers "in scope" before opening one.

When an install ships with empty or terse description strings (`"<name>
admin role"`), downstream agents fall back to guessing from agent id alone
— and the autonomy benefits Agent Bridge promises stop compounding. The
v0.15.0-beta1 Lane I work landed a useful default in `bridge-init.sh` and
the example roster so a fresh install is correct by construction; this doc
records the convention operators should follow when they extend a roster.

## Convention: one line, role + ownership

A `BRIDGE_AGENT_DESC` entry SHOULD be a single sentence that names the role
AND what the agent owns. Two examples that follow the shape:

```
Agent Bridge admin/coordinator for this install. Owns onboarding,
roster/queue triage, upgrade/release waves, and operator-facing decisions.
```

```
Codex dev/review pair for patch. Reviews PRs, proposes code changes, and
verifies smoke/runtime checks assigned through Agent Bridge.
```

Both name the role (admin/coordinator, codex pair) AND scope the ownership
(onboarding+triage+upgrades vs PR review+code change+verification). A
downstream agent reading either line can route work without further
clarification.

Anti-patterns to avoid:

- **Empty string.** `BRIDGE_AGENT_DESC["foo"]=""` is the worst case — the
  `agent show` text-mode hint at `[no description set; edit
  BRIDGE_AGENT_DESC["foo"] in agent-roster.local.sh]` is the operator
  callout; if you see that line in your roster, edit the roster.
- **Tautology.** `"foo's role"` or `"the foo agent"` does not say what foo
  does. Downstream agents cannot route off it.
- **Multi-line essays.** The description is queue-renderable (TSV column,
  JSON record value, single-line CLI getter). Anything past ~140 chars
  starts crowding terminal-width queue listings.

## Description ≠ Class

`BRIDGE_AGENT_DESC` is IDENTITY. `BRIDGE_AGENT_CLASS` (see
[`agent-roster.local.example.sh`](../../agent-roster.local.example.sh)
around the `BRIDGE_AGENT_CLASS` docs block, refs issue #539) is
AUTHORIZATION.

- A `librarian` agent's DESCRIPTION names the job: "memory
  ingestion/supervisory role; harvests every agent's memory tree into the
  shared wiki."
- A `librarian` agent's CLASS sets the privilege boundary:
  `BRIDGE_AGENT_CLASS["librarian"]="system"` so it can read other agents'
  memory trees.

The description is what a stranger sees; the class is what the runtime
enforces. Conflating them is the most common roster-setup mistake — an
operator writes `class=system` into the description string and leaves
class unset, then wonders why hooks block the agent's reads. Keep them
distinct in the roster.

## Recommended one-liners per role family

For a stock Agent Bridge install with the recommended `patch` (claude
admin) + `patch-dev` (codex pair) shape:

| Role        | id          | Suggested `BRIDGE_AGENT_DESC` line |
| ----------- | ----------- | ---------------------------------- |
| Admin       | `patch`     | `Agent Bridge admin/coordinator for this install. Owns onboarding, roster/queue triage, upgrade/release waves, and operator-facing decisions.` |
| Codex pair  | `patch-dev` | `Codex dev/review pair for patch. Reviews PRs, proposes code changes, and verifies smoke/runtime checks assigned through Agent Bridge.` |
| Antigravity pair | `patch-agy` | `Antigravity/alternate-engine pair for patch. Handles cross-engine implementation or UI/runtime verification tasks assigned through Agent Bridge.` |
| Librarian (system class) | `librarian` | `Memory ingestion/supervisory role. Harvests every agent's memory tree into the shared wiki (access boundary set via BRIDGE_AGENT_CLASS=system).` |

The schema for these entries lives in
[`agent-roster.local.example.sh`](../../agent-roster.local.example.sh)
near the `BRIDGE_AGENT_DESC[...]` block and the `BRIDGE_AGENT_CLASS` docs
block. Lift the recommended lines verbatim and edit the role-specific
words.

## CLI surface

The description string is exposed through three read-only paths. None of
them write back; the source of truth is the roster file.

- `agent show <name>` — text mode prints `description: <line>` (or the
  unset hint shown above); JSON mode (`agent show <name> --json`) carries
  it as `.description` (raw empty string when unset, so scripts can
  distinguish "operator chose to leave blank" from "we substituted a
  hint").
- `agent list --json` — every record carries the same `.description`
  field.
- `agent describe <name>` — single-purpose getter. Prints the description
  + newline on stdout when set; exits non-zero with no stdout and a
  stderr hint pointing to `BRIDGE_AGENT_DESC["<name>"]` in
  `agent-roster.local.sh` when unset. Use this from scripts that just
  want the string — it has no JSON envelope, no engine/workdir noise.
  `-h`/`--help` print usage and exit 0.

There is no `agent describe set <name> <text>` write path in beta1. To
change a description, edit the roster file directly and reload the agent
(or wait for the daemon's next sync). This keeps the description an
operator-curated value, not a runtime-mutated one.

## When to update the description

- **First-run onboarding.** The fresh install already lands the
  recommended admin sentence via `bridge-init.sh`. Operators only need to
  edit if they want install-specific wording (team name, environment,
  region).
- **Adding a new role.** Whenever an operator adds a `BRIDGE_AGENT_*`
  block to `agent-roster.local.sh`, write a matching description in the
  same block. The example file's recommended lines are a starting point.
- **Role boundary change.** If an agent's ownership shifts (e.g., a
  `librarian` becomes a `librarian + auditor`), update the description
  in the same PR that touches `BRIDGE_AGENT_CLASS` or the runtime hooks.

The description is queue-visible and reviewed by every downstream agent
that asks "who owns this?" — treating it as a casual comment is the most
common source of routing mistakes in multi-install fleets.
