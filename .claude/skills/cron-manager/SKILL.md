---
name: cron-manager
description: Create, inspect, update, and delete Agent Bridge native cron jobs with `agb cron`.
---

Use this skill when an agent identifies recurring work that should be scheduled through Agent Bridge instead of being remembered manually.

## Rules

- Prefer bridge-native cron jobs via `agb cron create|list|update|delete`.
- Keep payloads short and operator-facing. Put the actual recurring instruction in the payload.
- Use the owning bridge agent id in `--agent`.
- Do not create a cron when a one-off queue task or existing cron is sufficient.
- Update or delete stale jobs instead of creating duplicates.

## Commands

```bash
agb cron list --agent <agent>
agb cron create --agent <agent> --schedule "0 9 * * *" --title "Daily check" --payload "..."
agb cron update <job-id> --schedule "0 10 * * *"
agb cron delete <job-id>
```

## Inspection & Recovery

- `agb cron inventory --agent <agent>` — full catalogue across all states, not just enabled jobs (`--enabled yes|no|all`, `--mode recurring|one-shot|all`).
- `agb cron show <job-name-or-id>` — full detail for a single job (schedule, payload, tz, last/next run).
- `agb cron errors report --agent <agent>` — failed-run history. **Agents commonly guess `cron history` / `cron logs` / `cron status` — those do not exist; use `cron errors report` instead.**
- `agb cron sync` — manually re-sync the schedule. Rare; the daemon normally does this.
- `agb cron enqueue <job-name-or-id> --target <agent>` — fire a job ad-hoc into the target agent's inbox without waiting for its schedule.

## Guidance

- Default timezone is the local system timezone unless `--tz` is set.
- If the recurring work only matters after explicit human approval, do not schedule it automatically.
- If the job routinely produces "no change" results, the disposable cron worker should return `needs_human_followup=false`.

## Pinning the cron child model (issue #1880)

The disposable cron child does **not** inherit the model an interactive `/model` writes into the agent-home `.claude/settings.json`. Pin a stable model so a scheduled cron does not silently follow (and 404 with) whatever the interactive session is using.

```bash
agb cron create --agent <agent> --schedule "0 9 * * *" --title "Daily check" --payload "..." \
  --model <model-id> [--effort <effort>]
agb cron update <job-id> --model <model-id>     # set
agb cron update <job-id> --model ""             # clear -> fall back to cron-default/roster
agb cron create --agent <agent> ... --cron-default-model <model-id>   # default for jobs with no per-job model
```

Resolution precedence (highest first): per-job `--model` -> `--cron-default-model` (jobs-file `cronDefaults`) -> roster `BRIDGE_AGENT_MODEL` -> `BRIDGE_CRON_DEFAULT_MODEL` env. `--effort` applies to **codex** targets only (raw `claude -p` has no effort flag). `agb cron show <job>` reports the **effective** resolved `model:` / `effort:` rows with their `(source: per-job|cron-default|fallback|unset)`, plus the raw `per_job_model:` / `per_job_effort:` override. `show` resolves the in-process legs (per-job → cron-default → `BRIDGE_CRON_DEFAULT_MODEL`); the roster leg resolves at **dispatch** (bash), so an effective `unset` may still pick up a roster/env value when the job actually fires. The cron child NEVER reads the interactive `.claude/settings.json` for its model.

If **no** stable source resolves (per-job, `cronDefaults`, roster, and `BRIDGE_CRON_DEFAULT_MODEL` all unset), the handling is **conditional** on the interactive `.claude/settings.json`: if it **has** a `model` (the genuine #1880 coupling), the **Claude** cron child **fails closed** — the run is marked failed with an actionable error naming the fix (`--cron-default-model <model>` or roster `BRIDGE_AGENT_MODEL[<agent>]`); the settings value is read only to decide, never passed. If settings.json has **no** model (or is missing/unreadable), there is no coupling, so the child **proceeds on the account default** with no `--model` (config injection intact), exactly as before #1880.

## CLI Help

`agb` is a compact dispatcher for `agent-bridge`. Use `agb --help` and `agb cron --help` for the full surface. `agb help` (without dashes) is **not** a recognised command; nor are `agb list` / `agb status` (use `agent-bridge ...` for those — `agb` is queue/dispatch only).
