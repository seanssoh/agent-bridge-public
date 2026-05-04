# Agent Runtime — memory-daily harvester

> Per-agent detection-only reconciler for the canonical daily note
> (`<agent-home>/memory/YYYY-MM-DD.md`). **Not** the primary writer — the daily
> note itself is written by session `/wrap-up` (see
> [`auto-memory-isolation.md`](auto-memory-isolation.md)). The harvester only
> observes: if the previous operating day had activity but the note is missing
> or semantic-empty, it queues a `[memory-daily-backfill]` task for the agent
> to reconstruct from transcript + captures + git.

## 1. Purpose

The harvester is a **reconcile-kicker** that runs once per agent per day and
decides one of:

- Canonical note exists and is non-empty → no action.
- Canonical note missing but legacy `<home>/users/default/memory/<date>.md`
  exists and is non-empty → no action, note the legacy path.
- Canonical note missing with strong/medium activity evidence → queue a
  backfill task for the agent.
- Weak-only evidence (git commits, PreCompact captures) → no action.
- Gate disabled → skip and write a minimal manifest.
- Sudo wrap failed on linux-isolated installs → skip and aggregate.

No LLM is invoked. The harvester is pure detection.

## 2. Cron registration

`bootstrap-memory-system.sh` registers one cron per active **static** Claude
agent (see [§12 — Static-only contract](#12-static-only-contract)):

- Title: `memory-daily-<agent>`
- Schedule: `0 3 * * *` (Asia/Seoul)
- Payload:

  ```
  bash "$BRIDGE_HOME/scripts/memory-daily-harvest.sh" --agent <agent>

  # This harvester reconciles the agent's most recent jsonl session
  # transcript (resolved via session_id under ~/.claude/projects/) into the
  # agent's daily note at memory/daily/<YYYY-MM-DD>.md by invoking
  # scripts/daily-note-reconcile.py before the harvest pass. The harvester
  # then writes the authoritative RESULT_SCHEMA JSON to
  # $CRON_REQUEST_DIR/authoritative-memory-daily.json. The runner reads that
  # file directly. Your structured_output is a secondary relay.
  # Do NOT re-interpret status / summary / actions_taken — the harvester is authoritative.
  ```

This body is the canonical source; `bridge-cron.py`
`MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE` and the embedded literal in
`bootstrap-memory-system.sh:step_memory_daily_cron_one` mirror it. The
`jsonl` / `session_id` / `daily-note-reconcile` keywords are load-bearing:
`agb cron migrate-payloads --jsonl-aware` (issue #541 PR-A) uses them as
the predicate for whether an existing payload needs rewriting.

The inline `Do NOT re-interpret` pragma is load-bearing. The cron runner
forwards payload text to a Claude subagent as the prompt body; without the
override the subagent could paraphrase `actions_taken`, which would defeat the
daemon refresh-gating contract in §7.

Gate-off agents (`BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0`) skip
registration. A re-run of `bootstrap-memory-system.sh --apply` after disabling
the gate deletes the stale cron.

## 3. Harvest runtime chain

```
native cron scheduler
  └─> bridge-cron-runner.py
        ├─ exports CRON_REQUEST_DIR=<per-run workdir>
        └─ spawns claude -p … (prompt = cron payload text)
              └─ Claude subagent uses Bash tool to run the stub:
                   scripts/memory-daily-harvest.sh --agent <agent>
                     └─ parses `agent show --json` for workdir + profile.home
                        + isolation.mode + isolation.os_user (each via its own
                        python3 parse — whitespace-safe)
                     └─ linux-user isolation + user mismatch:
                          · resolve target_home = $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>
                          · test -r $target_home/.claude/projects
                              readable → exec python
                                         --transcripts-home=<target_home>
                                         (controller UID; queue DB + manifest
                                          + sidecar stay in controller
                                          context; ONLY transcripts scan
                                          reads the target's directory via
                                          the controller r-X ACL added by
                                          bridge_linux_prepare_agent_isolation)
                              unreadable → exec python --skipped-permission
                                           --os-user … (admin aggregate
                                           surfaces the missing ACL /
                                           missing target home)
                     └─ exec bridge-memory.py harvest-daily \
                          --agent … --home … --workdir … \
                          --sidecar-out "$CRON_REQUEST_DIR/authoritative-memory-daily.json"
                            └─ writes manifest atomically
                            └─ writes sidecar atomically (RESULT_SCHEMA-compliant)
                            └─ emits same JSON on stdout for LLM relay
        ├─ sidecar is preferred source (parse_claude_output is fallback)
        ├─ exception path: re-attempt sidecar before returning error
        └─ writes result.json with `child_result_source` audit field
bridge-daemon.sh
  └─ reads CRON_RESULT_FILE on cron worker completion
  └─ if actions_taken contains "queue-backfill" → queue session refresh
     else → audit `session_refresh_skipped`
```

## 4. Manifest schema v1

Path: `state/memory-daily/<agent>/<date>.json`.

```json
{
  "schema": "memory-daily-manifest-v1",
  "agent": "<agent>",
  "date": "YYYY-MM-DD",
  "timezone": "Asia/Seoul",
  "state": "checked|queued|resolved|skipped-permission|disabled|escalated",
  "first_detected_at": "2026-04-23T03:00:12+09:00",
  "last_checked_at":   "2026-04-24T03:00:04+09:00",
  "resolved_at":       null,
  "attempts": 1,
  "aggregate_notified_at": null,
  "run_id": "<cron run id>",
  "daily_note": {
    "path": "<agent-home>/memory/YYYY-MM-DD.md",
    "status": "present|semantic-empty|missing",
    "size_bytes": 1234,
    "has_meta_marker": true,
    "meta_schema_version": 1,
    "session_count": 3,
    "writer_mix": {"session": 2, "cron": 1},
    "has_tag_line": false,
    "semantic_nonempty": true
  },
  "legacy_paths_checked": [
    {"path": "<agent-home>/users/default/memory/YYYY-MM-DD.md",
     "present": true, "non_empty": true}
  ],
  "legacy_note_present": true,
  "activity": {
    "strong": {"transcript_sessions": [...]},
    "medium": {
      "queue_task_ids": [329, 331],
      "ingested_captures_non_precompact": ["<home>/raw/captures/ingested/….json"]
    },
    "weak": {
      "precompact_captures": ["<home>/raw/captures/ingested/….json"],
      "git_commits": ["abc1234", "def5678"]
    }
  },
  "decision": {
    "source_confidence": "strong|medium|weak|none",
    "action": "ok|queue-backfill|no-op|skip",
    "reason_code": null
  },
  "task": {
    "current_task_id": 333,
    "current_task_status": "queued",
    "last_task_id": null,
    "last_task_closed_at": null,
    "requeue_after": null
  }
}
```

Notes:

- `daily_note` field set reflects v0.7 §2 alignment with the actual
  `bridge-memory.py` daily-note format (meta marker + session count +
  writer_mix dict).
- `writer_mix` is a `{session: int, cron: int}` count map.
- `legacy_note_present` exists for the transitional period; canonical path
  unification landed in issue #220 (canonical = `<home>/memory/<date>.md`
  for every user). The probe is gated by `BRIDGE_MEMORY_LEGACY_PROBE`
  (default `1`); set it to `0` once `bridge-memory.py migrate-canonical
  --apply` has been run on every install. The probe is scheduled for
  removal in v0.7.
- Atomic write: `<file>.tmp.<pid>` → `os.replace` (see `_atomic_write_json`).

## 5. State machine

```
entry
├─ gate off                                              → state=disabled, action=skip
├─ sudo wrap failed (linux-user isolation)               → state=skipped-permission, action=skip
│                                                          (merges (agent,date) into admin-aggregate-skip)
├─ canonical note present + non-empty                    → state=checked, action=ok
├─ canonical missing/empty + legacy present + non-empty  → state=checked, action=no-op
├─ canonical missing/empty + strong OR medium activity   → state=queued, action=queue-backfill
├─ canonical missing/empty + weak-only activity          → state=checked, action=no-op
└─ canonical missing/empty + no activity                 → state=checked, action=no-op

resolution (next run carries over previous manifest)
├─ prev.state=queued + current canonical non-empty       → state=resolved
├─ prev.state=queued + prev task open                    → DEDUPE
├─ prev.state=queued + task closed < 24h + note missing  → cooldown, DEDUPE
├─ prev.state=queued + task closed ≥ 24h + note missing  → re-queue, attempts+=1
└─ attempts > 3                                          → state=escalated
```

## 6. Aggregate state

- `state/memory-daily/admin-aggregate-skip.json` — permission-skip aggregate.
- `state/memory-daily/admin-aggregate-escalated.json` — attempts>3 aggregate.

Both use `_merge_aggregate_state(path, merger)` with `fcntl.flock` for exclusive
access (see `bridge-memory.py:2371`). Schema:

```json
{
  "schema": "memory-daily-admin-aggregate-v1",
  "last_notified_at": "2026-04-23T03:00:12+09:00",
  "open_task_id": 456,
  "window_start": "2026-04-22T03:00:00+09:00",
  "by_day": {
    "2026-04-22": {
      "agents": ["patch", "librarian"],
      "first_seen_at": "…",
      "last_seen_at": "…"
    }
  }
}
```

A newly appearing `(agent, date)` pair triggers create-or-update of the admin
aggregate task (`[memory-daily-skip-admin]` or `[memory-daily-escalated]`).
Inside a 24h window with no new pair, `last_notified_at` is carried forward
without re-touching the task.

## 7. Daemon gating contract

`bridge-daemon.sh` cron_worker_complete handler only queues a session refresh
when the harvester backfilled the queue. The check is:

```bash
if [[ "${CRON_FAMILY:-}" == "memory-daily" && "${CRON_RUN_STATE:-}" == "success" ]]; then
  if bridge_agent_memory_daily_refresh_enabled "$TASK_ASSIGNED_TO"; then
    if bridge_cron_actions_taken_contains "${CRON_RESULT_FILE:-}" "queue-backfill"; then
      bridge_agent_note_memory_daily_refresh "$TASK_ASSIGNED_TO" "$run_id" "${CRON_SLOT:-}"
      bridge_audit_log daemon session_refresh_queued …
    else
      bridge_audit_log daemon session_refresh_skipped … --detail reason=no_queue_backfill_action
    fi
  fi
fi
```

The helper `bridge_cron_actions_taken_contains` (in `lib/bridge-cron.sh`) reads
`result.json`, parses `actions_taken`, and returns exit 0 iff the action is
present.

`process_memory_daily_refresh_requests` clears any stuck pending refresh for a
disabled agent **before** the gate skip, emitting a
`session_refresh_pending_cleared` audit with `reason=gate_off`.

Source-of-truth ordering inside the cron runner (v0.9 §2):

1. `run_claude` completes.
2. For `memory-daily` family, if
   `<request_file>/authoritative-memory-daily.json` exists, load + validate it
   and use that as `child_result` (`child_result_source=authoritative-sidecar`).
3. Otherwise fall back to `parse_claude_output(stdout)`
   (`child_result_source=child-fallback` for the memory-daily family, `child`
   for others).
4. Exception path: `parse_claude_output` failure retries the sidecar once more
   (`child_result_source=authoritative-sidecar-after-parse-error`).
5. `final_state` is recalculated after sidecar recovery so a valid sidecar
   rescues a parse error.

`result.json` carries `child_result_source` and, when applicable, a
`sidecar_error_note` for audit.

## 8. Opt-out

Per-agent:

```bash
# agent-roster.local.sh
BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0
```

The bash gate helper at `lib/bridge-agents.sh::bridge_agent_memory_daily_refresh_enabled`
enforces this at daemon dispatch time. Re-running
`bootstrap-memory-system.sh --apply` after disabling the gate deletes the
stale cron for that agent.

For the Python harvester's fallback probe (invoked outside a sourced roster),
set `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>=0` in the environment.

## 9. Audit fields

`result.json` written by `bridge-cron-runner.py`:

- `child_result_source` ∈ `{authoritative-sidecar,
  authoritative-sidecar-after-parse-error, child-fallback, child}`.
- `sidecar_error_note` — present only when sidecar load/validate failed and
  fallback to child stdout was taken.

Daemon audit events:

- `session_refresh_queued` — harvester produced `queue-backfill`.
- `session_refresh_skipped` — family=memory-daily with no backfill action.
  Detail `reason=no_queue_backfill_action`.
- `session_refresh_pending_cleared` — gate-off cleanup of a stale pending
  refresh. Detail `reason=gate_off`.

## 10. Linux-user isolation (#219)

The harvester stays in **controller UID** so its queue-DB reads
(`task_events`), dedupe lookups (`_task_status`), and backfill writes
(`bridge-task.sh create`) continue to work against the controller-owned
tasks.db. Cross-UID access is limited to a single strict read lens: the
controller is granted r-X on the isolated user's `~/.claude/projects/` so
`_scan_transcripts` can see the target's transcript store without any sudo
re-exec.

### Dispatch paths

When `agent show --json` reports `isolation.mode=linux-user` and
`isolation.os_user != $(id -un)`, the stub resolves
`target_home=$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>` and probes
read access to `$target_home/.claude/projects`:

- **readable** — exec the harvester with `--transcripts-home=<target_home>`
  in controller context. `_scan_transcripts` reads the target's store via
  the r-X ACL. Queue/manifest/aggregate operations are unchanged.

- **unreadable** (ACL not applied, `.claude/projects` not yet created, or
  any other `access(2)` failure) — exec the harvester with
  `--skipped-permission --os-user <os_user>`. Python writes
  `state=skipped-permission`, merges `(agent, date)` into
  `admin-aggregate-skip.json`, and exits 0. Per v0.5 §10.1 this is a
  structured skip; the admin aggregate task surfaces the gap.

The stub does **not** invoke `sudo`. All UID switching happens via filesystem
ACLs set at isolation prep time.

### ACL contract

`bridge_linux_prepare_agent_isolation()` (`lib/bridge-agents.sh`) creates and
grants the following during isolation prep (static or `--reapply`):

| Path | Grant | Rationale |
|---|---|---|
| `state/memory-daily/` | `u:<os_user>:r-x` | Traverse only — peer `<agent>/` dirs stay out of reach. |
| `state/memory-daily/<agent>/` | `u:<os_user>:rwX` + default | Per-agent manifest writes (if a future pipeline re-introduces isolated writes). |
| `state/memory-daily/shared/aggregate/` | `u:<os_user>:rwX` + default | Multi-agent `fcntl.flock`-guarded aggregate files. |
| `state/cron/runs/<run_id>/` | `u:<os_user>:rwX` + default | Granted per-dispatch in `bridge_cron_run_dir_grant_isolation`. |
| `<user_home>/.claude/projects/` | `u:<controller>:r-X` + default | Read lens so the controller-UID harvester can scan the target's transcripts without sudo re-exec. |

Legacy `state/memory-daily/admin-aggregate-{skip,escalated}.json` files are
migrated into `shared/aggregate/` in **controller context** — either by
`bridge_linux_prepare_agent_isolation` (sudo-root `mv`) or by
`bootstrap-memory-system.sh --apply` (controller-user `mv`). The harvester
never migrates during its hot path.

### Sudoers note

`bridge_migration_sudoers_entry` still installs `NOPASSWD: SETENV: tmux, bash`
for the isolated `os_user`. The harvester does not consume this entry in the
v1.3 design, but tmux/bash launch paths (`bridge-start.sh`) still rely on it.
`bridge_linux_can_sudo_to` probes `sudo -n -u <os_user> -- bash -c 'exit 0'`
so the probe matches the installed entry.

### Re-applying ACLs to an already-isolated agent

```bash
agent-bridge isolate <agent> --reapply
# --dry-run prints the plan without executing
```

`--reapply` skips `useradd` / ownership migration / sudoers steps and only
re-runs `bridge_linux_prepare_agent_isolation`, which is idempotent. Required
to pick up ACL-contract changes on existing installs (this PR).

### Dispatch ordering under isolation

`bridge-cron.sh::dispatch_cron_run` writes run_dir artifacts **before**
creating the queue task (issue #219) so a daemon worker cannot claim a
task ahead of the request / status / manifest files. The request and
manifest are seeded with `dispatch_task_id=0` / `task_id=0` placeholders
and atomically rewritten to the real queue id once it's known. The
`already_enqueued` short-circuit only takes effect for positive task
ids, so a run stranded by a prior failed create is re-dispatched on the
next pass (stale artifacts are cleared first).

`bridge_cron_run_dir_grant_isolation` is called best-effort between the
artifact writes and the queue-create step. Under v1.3 the memory-daily
harvester runs as the controller UID, so the grant is not load-bearing
for memory-daily dispatch — failure is ignored (`|| true`) and the queue
task is still created. The helper remains useful for future cron
families that do spawn isolated subprocesses, but memory-daily does not
depend on the isolated os_user owning `state/cron/runs/<run_id>/`.

### Testing flexibility

`bridge-memory.py harvest-daily --transcripts-home <path>` overrides the
base for `~/.claude/projects` scanning; used by smoke tests and manual
invocation.

## 11. Known limits

- Canonical path unification (`users/default/memory` → `<home>/memory`) is
  resolved by issue #220. Use `bridge-memory.py migrate-canonical --home
  <home> [--user <id>] [--apply]` to fold any leftover legacy notes;
  default is dry-run, `--apply` performs an atomic move and writes
  `<home>/memory/_migration_log.json`. The harvester still probes the
  legacy path read-only to suppress false-positive backfills during the
  one-release transition window; set `BRIDGE_MEMORY_LEGACY_PROBE=0` to
  disable the probe once migration has run on every install. Probe
  removal target: v0.7.
- The primary daily-note writer is session `/wrap-up`, tracked in
  [`auto-memory-isolation.md`](auto-memory-isolation.md). This harvester does
  not write notes — only queues backfill tasks.
- Cron rebalancing via `agb cron rebalance-memory-daily` is a separate
  operational surface and not invoked by bootstrap.

## 12. Static-only contract

Per [issue #376](https://github.com/SYRS-AI/agent-bridge-public/issues/376),
the `memory-daily-<agent>` cron + `memory-daily-harvest.sh` harvester pipeline
is intentionally scoped to **static** agents only.

### Why

Static agents are managed-from-outside: operators interact via
Discord/Telegram/Teams, agents run unattended, and the daily note at
`<agent-home>/memory/<date>.md` is the operational record.

Dynamic agents are managed-from-inside: the operator is at the agent's TUI,
the conversation IS the operational record, and the transcript is already on
disk at `~/.claude/projects/<slug>/<sessionId>.jsonl`. There is no separate
daily note the bridge needs to harvest — the operator already saw everything.

### Enforcement points (defense in depth)

The contract is enforced at three layers so a single forgotten filter at any
one layer cannot reintroduce the daily exit-2 / `[cron-followup]` storm that
issue #376 documents:

| Layer | Source | Behavior |
|---|---|---|
| Registration filter (Track A, v0.6.18) | `scripts/_common.sh::list_active_static_claude_agents` | Filters `agent list --json` on `engine=="claude" && active && source=="static"`. `bootstrap-memory-system.sh` builds `STATIC_AGENT_SET` from this helper. |
| Apply-time migration (Track B) | `bootstrap-memory-system.sh::step_memory_daily_cron_one` | When `agent ∉ STATIC_AGENT_SET`, the function detects an existing dynamic-agent cron and removes it via the existing 3-mode pattern (`check` records `drift-migration-pending`; `dry-run` records `would-remove`; `apply` calls `agb cron delete <id>` and records `migrated-removed`). When no cron exists for the dynamic agent, it records `skip-dynamic-agent`. |
| Harvester refusal (Track C, v0.6.18) | `scripts/memory-daily-harvest.sh` | Re-checks `agent show --json | .source` and exits `0` (success / no-op) — *not* `2` — when source is dynamic. Exit 0 keeps the cron's run-state at success so the daemon does not generate a `[cron-followup]` task. |

Track A prevents new dynamic-agent crons from being registered. Track B
removes any pre-v0.6.18 dynamic-agent crons on the next
`bootstrap-memory-system.sh apply` and reports them under `check` / `dry-run`.
Track C is the last-resort guard that catches manually-created crons or
future helpers that forget to filter.

### Future helpers

If you add a new per-agent pipeline that depends on `<agent-home>/` existing
on disk, filter on `source == "static"`. The dynamic-agent case is easy to
forget because the broader `list_active_claude_agents` helper still emits
both classes — that helper is preserved for status reporting and watchdog
scans that genuinely apply to both. For static-only registration, use
`list_active_static_claude_agents`.

The strict source-class block lives in `bootstrap-memory-system.sh` and
`scripts/wiki-daily-ingest.sh` per `KNOWN_ISSUES` entry 15 — do not lift
it into a new `_common.sh` helper without re-reviewing that contract.

### Operator-side cleanup of pre-fix installs

Operators with installs bootstrapped before v0.6.18 already have
`memory-daily-<agent>` crons registered for dynamic agents. After v0.6.18,
the harvester silently no-ops via Track C, so the dead crons are harmless —
but they remain dead weight on the cron board until removed. To clean them
up automatically:

```bash
bash bootstrap-memory-system.sh --apply
```

The Track B branch in `step_memory_daily_cron_one` detects the existing
dynamic-agent crons and removes them with a `migrated-removed` audit row.
Re-runs are no-ops (the lookup returns nothing on the second pass).
