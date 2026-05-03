# Operator Actions Pending

Per-release admin checklist that the bridge-upgrade post-task references. Each
section below is a single release. After running `agent-bridge upgrade --apply`
on this host, the admin should:

1. Read every section whose `applies_when_upgrading_from <= installed_version`.
2. Execute the listed actions or close them with a one-line `not applicable
   here because <reason>` note.
3. Skip sections that ship with no operator action (the section's body says
   "no operator action required" — most release bumps fall here).

The latest release's section is always at the top. When opening a new release
PR, prepend a new section; do not edit older sections in place.

---

## v0.7.3 — PreCompact hooks now propagated on upgrade (no operator action required)

- applies_when_upgrading_from: any version `<= 0.7.2`.
- urgency: **none** (informational).

### Background

PR #510 (issue #509 C3+C4) shipped `hooks/pre-compact.py` and `hooks/session_start.py` changes that re-inject canonical agent identity files (SOUL/SESSION-TYPE/COMMON-INSTRUCTIONS/TOOLS/MEMORY) after auto-compaction. The session_start half worked on every existing host immediately (it reads canonical files live).

The pre-compact half — which writes a sidecar `state/agents/<agent>/compact-snapshot.json` as a disaster-recovery fallback — was silently skipped: `bridge_upgrade_propagate_claude_hooks` registered the other five hook events but never `PreCompact`. Hosts that ran `agent-bridge upgrade --apply` without restarting their claude agents had the new code on disk but no `settings.json` wire, so `/compact` did not fire the hook.

`v0.7.3` extends `bridge_upgrade_propagate_claude_hooks` with `bridge_ensure_claude_pre_compact_hook`, mirroring the five existing helpers. Subsequent `upgrade --apply` invocations register the PreCompact handler on every claude agent. Idempotent — already-wired agents remain unchanged.

### Action

**No operator action required.** From this release onward `agent-bridge upgrade --apply` registers the PreCompact handler automatically on every claude agent. The next natural `/compact` writes the sidecar snapshot.

### Skip if

- Always skip — informational. Behavior takes effect on the next `upgrade --apply` invocation.

---

## v0.7.3 — pre-v0.7.3 emergency rollout for static claude agents

- applies_when_upgrading_from: any version `0.7.0 .. 0.7.2`.
- urgency: **medium** for hosts that need PreCompact wired *before* upgrading to v0.7.3 (e.g. a long-soak host where you don't want to run a full upgrade right now, or you upgraded to a `0.7.0..0.7.2` build and need the disaster-recovery snapshot working before the next `/compact`); **none** if you can simply run `agent-bridge upgrade --apply` to v0.7.3+ instead.

### Background

Hosts that ran `agent-bridge upgrade --apply` to v0.7.0, v0.7.1, or v0.7.2 received `hooks/pre-compact.py` on disk but no `settings.json` wire — `bridge_upgrade_propagate_claude_hooks` registered five hook events but missed `PreCompact`. **The simplest fix is to upgrade to v0.7.3+**: the new release adds `bridge_ensure_claude_pre_compact_hook` to the propagation loop, so the next `upgrade --apply` registers PreCompact on every claude agent (static and dynamic — `bridge_agent_workdir` reaches both).

This section exists for hosts that need a **manual interim rollout** before they can upgrade. The rollout helper, `scripts/bulk-register-precompact.sh`, already ships in v0.7.x, so it is reachable on the affected versions.

**Important caveat — static agents only.** `scripts/bulk-register-precompact.sh` enumerates `$BRIDGE_HOME/agents/<name>` and registers PreCompact in each agent's per-home `settings.json`. It does **not** reach dynamic claude agents whose `workdir` lives outside `$BRIDGE_HOME/agents/` (e.g. `~/Projects/agent-bridge-public/.claude/settings.json`). Those agents are covered by the v0.7.3 upgrade auto-wire path, not by this helper. If you need the manual interim coverage to include dynamic agents, see "Manual coverage for dynamic agents" below.

### Action — static agents

```bash
bash "$HOME/.agent-bridge/scripts/bulk-register-precompact.sh" --all
```

`--all` covers every claude-engine agent that has a home under `$BRIDGE_HOME/agents/<name>` (the script filters out `_template` and `shared`). For a phased rollout, use `--canary` (registers `patch` only) and `--phase2` (registers `newsbot, syrs-calendar, syrs-creative`) before `--all`.

### Manual coverage for dynamic agents (optional)

If your install runs claude agents whose workdir is outside `$BRIDGE_HOME/agents/<name>` and you cannot wait for the v0.7.3 upgrade:

```bash
~/.agent-bridge/agent-bridge agent list --json \
  | python3 -c '
import json, sys
for row in json.load(sys.stdin):
    if row.get("engine") != "claude":
        continue
    workdir = row.get("workdir") or ""
    if not workdir or workdir.startswith("'"$HOME"'/.agent-bridge/agents/"):
        continue
    print(f"{row[\"agent\"]} {workdir}")
' \
  | while read -r agent workdir; do
      python3 ~/.agent-bridge/bridge-hooks.py ensure-pre-compact-hook \
        --workdir "$workdir" \
        --bridge-home "$HOME/.agent-bridge" \
        --python-bin "$(command -v python3)" \
        --settings-file "$workdir/.claude/settings.json"
  done
```

This iterates dynamic claude agents (engine=claude, workdir not under `~/.agent-bridge/agents/`) and registers PreCompact directly in each project's `.claude/settings.json`. Idempotent like the bulk helper. Stop and review if any agent's settings.json is shared between hosts (e.g. a checked-in template) — the registration is host-local.

### Verify (covers static + dynamic)

```bash
~/.agent-bridge/agent-bridge agent list --json \
  | python3 - <<'PY'
import json, os, sys
data = json.load(sys.stdin)
for row in data:
    if row.get("engine") != "claude":
        continue
    workdir = row.get("workdir") or ""
    settings = os.path.join(workdir, ".claude", "settings.json")
    label = f"{row['agent']:24s} ({row.get('source','?'):8s})"
    if not os.path.isfile(settings):
        print(f"{label}: NO_SETTINGS_FILE ({settings})")
        continue
    try:
        cfg = json.load(open(settings))
    except Exception as e:
        print(f"{label}: PARSE_ERROR ({e})")
        continue
    has_pc = any(
        "pre-compact.py" in (h.get("command") or "")
        for entry in cfg.get("hooks", {}).get("PreCompact", [])
        for h in entry.get("hooks", [])
    )
    print(f"{label}: {'present' if has_pc else 'MISSING'}")
PY
```

This walks the live roster (so dynamic agents are not silently hidden) and prints `present | MISSING | NO_SETTINGS_FILE | PARSE_ERROR` per claude agent.

### Skip if

- This host has no claude-engine agents.
- You upgraded to `v0.7.3+` and `agent-bridge upgrade --apply` completed successfully — the auto-wire path covers both static and dynamic agents.
- You ran the actions above in a previous session and the verify block already prints `present` for every claude agent.
- You upgraded directly from `<= 0.6.x` to `>= 0.7.3` (the v0.7.3 upgrade itself ran the propagation loop with the new entry — the static-only manual path was never relevant to your install).

---

## v0.7.2 — daily-backup death-spiral root-cause + auto-cleanup (no operator action required)

- applies_when_upgrading_from: any version `<= 0.7.1`.
- urgency: **medium** if the host is currently low on free disk; **none** otherwise.

### Background

Issue [#507](https://github.com/SYRS-AI/agent-bridge-public/issues/507) documented a chain of three bugs in the daily-backup system that, together, fill the host disk with orphaned `*.tgz.tmp.*` files (~1.9 GB each), corrupt `~/.claude.json`, and render every `claude -p` subagent inoperable. The same upgrade also addresses two adjacent problems Sean surfaced in the same diagnosis pass: `state/tasks.db` was being bundled into every daily tarball as a raw, ~uncompressible binary (so 30-day retention multiplied it ~30× with near-zero dedup), and `backups/upgrade-*/` snapshots had no prune logic at all.

v0.7.2 ships:

1. **Root-cause fixes (`bridge-upgrade.py`, `bridge-daemon.sh`, `lib/bridge-state.sh`):**
   - Stale `*.tgz.tmp.*` files reaped at the start of every backup attempt (age-gated by `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS`, default 180s, plus an `flock`-based backup lock).
   - Pre-flight free-space check (`shutil.disk_usage` ≥ 1.5× prior largest archive, floor 100 MiB). On insufficient space, the JSON outcome is `skipped_disk_full` and the daemon records the failure.
   - `--retain-days` default dropped 30 → 7 (CLI + daemon defaults). `BRIDGE_DAILY_BACKUP_RETAIN_DAYS=30` keeps the old behavior.
   - `state/tasks.db` (and its `-wal`/`-shm`/`-journal` siblings) excluded from the tar walk; instead a hot online snapshot is dumped to `state/backup-snapshots/tasks-YYYY-MM-DD.sql.gz` and added back to the tarball as a single explicit member. SQL dumps are ~10–20× smaller than the raw .db, gzip well, and round-trip via `sqlite3 newdb < tasks-YYYY-MM-DD.sql`.
   - Exclude list expanded: `worktrees/`, `runtime/{assets,media,extensions}/`, `.claude/worktrees/`, and any-depth `node_modules` (in addition to the existing `__pycache__` skip and the new `state/backup-snapshots/` walk-time skip). Operators can extend via `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS`.
   - Daemon failure cooldown wired to outcomes. After a failure (`disk_full`, `timeout`, `parse`, `error_*`), the next attempt is suppressed for `BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS` (default 3600s). One `daemon_warn` and one audit row per cooldown window, not per cycle.

2. **Auto-cleanup migration (`lib/bridge-cleanup.sh` + `bridge-upgrade.sh` wire-in):**
   - `agent-bridge upgrade --apply` now runs `bridge-upgrade.py cleanup-residue` after the shared-settings rerender. It reaps stale tmp files, prunes daily archives at the new 7-day default, prunes SQL snapshots, prunes `backups/upgrade-*/` (preserving the current upgrade's `BACKUP_ROOT`, the newest `BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT=5` snapshots, and anything younger than `BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS=14`), and validates `~/.claude.json`. In `--no-backup` mode the upgrade-* prune step is skipped (no signal that the operator is OK with destruction).
   - The `[upgrade-complete]` task body now includes a "Backup residue cleanup" summary block (what cleanup actually did + bytes freed) plus an agent-safe verification block (read-only health checks: `du`, `agent-bridge status`, `daily-backup state.env`, `verify-tasks-db`, `~/.claude.json` JSON parse, snapshot restore self-test on a temp DB).

### Action

**No operator action required for the common path.** The auto step covers every host that runs `agent-bridge upgrade --apply` to v0.7.2+, on every subsequent upgrade.

The `[upgrade-complete]` task body will tell you whether cleanup succeeded. If it ran cleanly with `cleanup_failures=0`, run the verification block to confirm post-state and close the task.

### Manual cleanup (only if the auto step reported failures)

If the upgrade output printed `[bridge-upgrade] WARN: backup residue cleanup completed with N failure(s)`, the upgrader could not reach one of: stale tmp removal, daily prune, SQL-snapshot prune, upgrade-* prune, or `~/.claude.json` validation. Re-run cleanup directly:

```bash
TARGET_ROOT="$HOME/.agent-bridge"   # or your install root

python3 "$TARGET_ROOT/bridge-upgrade.py" cleanup-residue \
  --target-root "$TARGET_ROOT" \
  --backup-dir "$TARGET_ROOT/backups/daily" \
  --upgrade-backups-dir "$TARGET_ROOT/backups"
```

If even that fails (typically because the disk is so full that even renames ENOSPC), free space first, then re-run:

```bash
TARGET_ROOT="$HOME/.agent-bridge"

# 1. Reap orphaned tmp files (cheapest win — usually GBs).
rm -f "$TARGET_ROOT/backups/daily"/*.tgz.tmp.*

# 2. Drop daily archives older than 7 days.
find "$TARGET_ROOT/backups/daily" -maxdepth 1 -type f -name 'agent-bridge-*.tgz' \
  -mtime +7 -print -delete

# 3. Drop upgrade-* snapshots older than 14 days, keeping the 5 newest.
ls -1dt "$TARGET_ROOT/backups"/upgrade-* 2>/dev/null \
  | tail -n +6 \
  | while read -r path; do
      mtime_age_days=$(( ( $(date +%s) - $(stat -f %m "$path" 2>/dev/null \
                       || stat -c %Y "$path") ) / 86400 ))
      if (( mtime_age_days > 14 )); then
        echo "removing $path (age=${mtime_age_days}d)"
        rm -rf "$path"
      fi
    done

# 4. Rerun cleanup-residue to refresh state + revalidate ~/.claude.json.
python3 "$TARGET_ROOT/bridge-upgrade.py" cleanup-residue --target-root "$TARGET_ROOT"
```

If `~/.claude.json` is reported corrupted, restore it from `~/.claude/backups/<latest>/.claude.json`:

```bash
LATEST_BACKUP=$(ls -1t ~/.claude/backups/*/.claude.json 2>/dev/null | head -1)
[[ -n "$LATEST_BACKUP" ]] && cp "$LATEST_BACKUP" ~/.claude.json && echo restored: "$LATEST_BACKUP"
```

### Verification (always run)

The `[upgrade-complete]` task body embeds the same agent-safe verification block; run it from there. Standalone copy:

```bash
TARGET_ROOT="$HOME/.agent-bridge"

du -sh "$TARGET_ROOT/backups/daily" "$TARGET_ROOT/backups"/upgrade-* 2>/dev/null
ls "$TARGET_ROOT/backups/daily"/*.tgz.tmp.* 2>/dev/null \
  && echo "STALE TMP STILL PRESENT" \
  || echo "tmp clean"
agent-bridge status 2>/dev/null | head -20
cat "$TARGET_ROOT/state/daily-backup/state.env" 2>/dev/null || echo "(no state yet)"
python3 "$TARGET_ROOT/bridge-upgrade.py" verify-tasks-db --target-root "$TARGET_ROOT"
python3 -c "import json,os; json.load(open(os.path.expanduser('~/.claude.json'))); print('.claude.json OK')" \
  || echo ".claude.json CORRUPTED — restore from ~/.claude/backups/"

LATEST=$(ls -1t "$TARGET_ROOT/state/backup-snapshots"/tasks-*.sql.gz 2>/dev/null | head -1)
if [[ -n "$LATEST" ]]; then
  TMPDB=$(mktemp -t agb-restore-check.XXXXXX.sqlite)
  gunzip -c "$LATEST" | sqlite3 "$TMPDB" >/dev/null 2>&1 \
    && echo "snapshot restorable: $LATEST" \
    || echo "snapshot BROKEN: $LATEST"
  rm -f "$TMPDB"
fi
```

### Skip if

- Always skip the manual cleanup section if the auto step reported `cleanup_failures=0`.
- Always run the verification block — it's read-only and confirms post-state.

---

## v0.7.1 — telegram-relay residue auto-cleanup (no operator action required)

- applies_when_upgrading_from: any version `<= 0.7.0`.
- urgency: **none**.

### Background

v0.7.0 removed the telegram-relay source surface but left it to the operator to clean up live runtime residue (`state/channels/telegram/{tokens.list,*.sock,<token-hash>/}`, per-agent `.telegram/relay-token`, channel entries containing `plugin:telegram-relay@*`, and `BRIDGE_TELEGRAM_RELAY_*` env vars). Two prompts under `docs/proposals/` covered the manual procedure.

v0.7.1 automates the cleanup: `agent-bridge upgrade --apply` now runs `bridge-relay-cleanup.py` after the shared-settings rerender step, removes every residue class above idempotently, and emits a single `telegram_relay_residue_cleanup_applied` audit row when it actually changed something. Re-runs are no-ops. Per-agent `.telegram/.env` and `.telegram/access.json` are preserved — the official plugin still reads them.

### Action

**No operator action required for the common path.** The auto step covers every host that runs `agent-bridge upgrade --apply` to v0.7.1+.

If the auto step exited non-zero (rare — usually a filesystem permissions issue), the upgrader emits a `[bridge-upgrade] WARN: telegram-relay residue cleanup helper exited non-zero` line. In that case, run the manual prompt:

- All hosts: `docs/proposals/v0.7.0-install-cleanup-verification-prompt.md`
- Relay-host migration (heavier): `docs/proposals/jjujju-migration-prompt.md`

Both prompts are now fallbacks rather than first-line procedures.

### Skip if

- Always skip — informational; the cleanup activates automatically on the first `agent-bridge upgrade --apply` to v0.7.1+.

---

## v0.7.0 — telegram-relay daemon removed (operator action required on relay hosts)

- applies_when_upgrading_from: any version `0.6.37 .. 0.6.x` that registered the relay daemon.
- urgency: **high** for relay-using hosts (SYRS jjujju and any clones); **none** for hosts that never registered the relay.

### Background

PR3 reverts #475 phases 2/3 (the v0.6.37+ telegram-relay daemon). Outbound Telegram is now the parent agent's responsibility through the official `plugin:telegram@claude-plugins-official`. The cron inbox-only reporting contract from PR1+PR2 makes this clean: cron children write structured inbox tasks; parents forward through their own channel plugin.

The following surface is removed in v0.7.0:

- `agent-bridge telegram-relay <start|stop|status|health>` CLI subcommand (and the underlying `bridge-telegram-relay.sh`).
- `lib/telegram-relay.py` daemon and the `bridge_telegram_relay_supervise` daemon step.
- `plugins/telegram-relay/` plugin tree (the bun MCP adapter).
- `BRIDGE_TELEGRAM_RELAY_ENABLED` env var, `bridge-setup.py telegram --use-relay` / `--no-relay` flags, and the `BRIDGE_TELEGRAM_USE_RELAY` env knob.
- `state/channels/telegram/tokens.list` and `<token-hash>/` daemon state directories — these become orphaned but are not auto-removed; cleanup is part of the manual migration prompt below.
- Per-agent `.telegram/.env` and `.telegram/access.json` files are **preserved** — the official `plugin:telegram@claude-plugins-official` still reads them.

### Action — for hosts that registered the relay

The migration is **manual** per Sean's standing instruction (Q-F 2026-05-02). The verbatim prompt to send to the affected agent on the relay host lives at [`docs/proposals/jjujju-migration-prompt.md`](docs/proposals/jjujju-migration-prompt.md). Send it as-is to the relay-host's admin/agent and wait for confirmation before declaring the host migrated.

### Skip if

- The host never registered the relay (`grep BRIDGE_TELEGRAM_RELAY ~/.agent-bridge/agent-roster.local.sh` returns empty AND no relay process was ever supervised).
- The host doesn't use Telegram at all.

### Verification target

After running the manual migration prompt, the relay-host operator should observe:

- `~/.agent-bridge/state/channels/telegram/tokens.list` is empty or absent.
- `BRIDGE_AGENT_CHANNELS["<telegram-agent>"]` no longer contains `plugin:telegram-relay@agent-bridge`; it contains `plugin:telegram@claude-plugins-official` instead.
- `agent-bridge status --json` no longer surfaces a `telegram-relay` plugin entry for that agent.
- A real Telegram round-trip (cron child → main-session inbox task → parent forwards via official plugin) lands in the operator's chat.

---

## v0.6.x — cron inbox-only reporting contract (PR1+PR2 — no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.40`.
- urgency: **none** (informational).

### Background

PR1 (#499) and PR2 introduce inbox-only reporting for disposable cron children. The cron-runner now writes a structured `[cron-followup]` inbox task to the cron's parent agent (the configured `target_agent` — usually the operator-attached main session) when a run produces a signal worth surfacing; otherwise the run logs and exits silently. Existing crons default to silent-on-no-signal automatically — no per-job migration needed.

Per-job overrides ship via job metadata (Sean Q-B 2026-05-02):

- `metadata.cronReportingPolicy = default | always_main_session | always_silent` — force a particular reporting outcome regardless of what the child decides.
- `metadata.cronUrgency = normal | high | urgent` — set the priority of the resulting inbox task.

Operator visibility:

- `agb cron show <job>` now prints `last_reporting_decision`, `last_delivery_intent`, and `last_inbox_task_id` so the cron → inbox → main-session flow is traceable without grepping `state/cron/runs/`. Same trio is in `--format json` and `--format shell` output (`CRON_JOB_LAST_REPORTING_DECISION`, etc.).
- Parent-agent handling contract lives in [`docs/agent-runtime/common-instructions.md` §"Cron Followup Handling"](docs/agent-runtime/common-instructions.md#cron-followup-handling). The frontmatter parser is `lib/bridge_cron_followup.parse_followup` (Python stdlib only).

### Action

**No operator action required.** Existing crons keep their current behavior; the new contract only activates on the next run. `agb cron list` may show fewer admin-side `[cron-followup]` tasks than before — this is expected and signals the new contract is working. Parent agents now own the absorption / forwarding step.

The PR3 telegram-relay reversal is batched into a separate later release; that one **will** require an operator action on hosts that registered the relay daemon (e.g. jjujju). A self-contained migration prompt for that step lives at `docs/proposals/jjujju-migration-prompt.md` and is not auto-scripted into `agent-bridge upgrade --apply` per Sean Q-F.

### Skip if

- Always skip — informational. The contract activates on the next cron tick after upgrade. No operator action is required, period.

---

## v0.6.39 — shared Claude hooks now propagated on upgrade (no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.38`.
- urgency: **none** (informational).

### Background

Before v0.6.39 the upgrader did not call `bridge_ensure_claude_*_hook` for existing hosts, so a release that added a new hook event (Stop / SessionStart / UserPromptSubmit / PromptGuard / ToolPolicy) shipped the new script in `hooks/` but the existing per-agent `settings.json` never registered it. Only fresh installs picked up new hooks.

`v0.6.39` adds `bridge_upgrade_propagate_claude_hooks` that runs before the rerender step and ensures every Claude agent's shared base settings register the latest hook list. The subsequent rerender propagates the change into per-agent effective settings.

### Action

**No operator action required.** `agent-bridge upgrade --apply` from this release onward registers any newly-added hook automatically. The `shared_settings_rerender` line in upgrade output already reflects the post-rerender state.

### Skip if

- Always skip — informational. Behavior takes effect on the next `upgrade --apply` invocation.

---

## v0.6.39 — settings rerender for hosts that upgraded before this fix

- applies_when_upgrading_from: any version `0.6.33 .. 0.6.38`
- urgency: medium.

### Action

Run on the upgraded host to backfill managed Claude settings defaults that may
not have propagated during prior upgrades:

```bash
agent-bridge agent rerender-settings --apply
```

Confirm `autoCompactWindow: 400000` is present in each managed Claude agent's
effective settings.

### Skip if

- This host has no managed Claude agents.
- `agent-bridge agent rerender-settings --dry-run` reports every target as
  `unchanged`.

---

## v0.6.39 — `setup telegram` defaults to relay (no operator action required)

- applies_when_upgrading_from: any version `<= 0.6.38`.
- urgency: **none** (informational).

### Background

`agent-bridge setup telegram <agent>` now defaults to `--use-relay` (the
architectural fix from #475 phase 2/3). The legacy
`plugin:telegram@claude-plugins-official` path is still reachable via
`--no-relay` as a transitional escape hatch.

### Action

**No operator action required.** Existing agents on the legacy plugin path keep
working until the operator explicitly re-runs `setup telegram`. Hosts that
already have the v0.6.37 telegram-relay opt-in section processed are already on
the relay path.

### Skip if

- Always skip — this is informational. The flag flip only affects new
  `setup telegram` invocations; existing registrations are untouched.

---

## v0.6.37 — telegram-relay opt-in

- applies_when_upgrading_from: any version `<= 0.6.36`
- urgency: **high** if this host has any agent currently using
  `plugin:telegram@claude-plugins-official` (mid-session disconnect symptom);
  low otherwise.

### Background

`v0.6.34` already shipped the cron-cascade fix (#474), so
`agent-bridge upgrade --apply` alone stops the 30-min cron-driven Telegram
poller SIGTERM cycle on every host. **No operator action required for that
fix — it activates automatically on upgrade.**

`v0.6.37` adds the architectural fix for the remaining cascade triggers
(operator opening a second attached session, `/mcp` reconnect, sibling plugin
spawn): a single-token-owner relay daemon (`lib/telegram-relay.py`) plus a
plugin client adapter (`plugins/telegram-relay/server.ts`) plus the
`bridge-setup.py telegram --use-relay` lifecycle wiring. Activating it is
**operator opt-in** because it changes the channel registration from
`plugin:telegram@claude-plugins-official` to `plugin:telegram-relay@agent-bridge`.

### Action — for each agent that uses the Telegram channel on this host

1. Set `BRIDGE_TELEGRAM_RELAY_ENABLED=1` permanently in the bridge daemon's
   environment file (typically `~/.agent-bridge/.env`; check
   `lib/bridge-daemon.sh` env loading if unsure).

2. Re-key each Telegram-using agent through the relay-aware setup path:
   ```
   ~/.agent-bridge/agent-bridge setup telegram <agent> \
     --token "<bot-token>" \
     --allow-from "<user-id>" \
     --default-chat "<chat-id>" \
     --use-relay --yes
   ```
   The token / allow-from / default-chat values can be recovered from the
   agent's existing `~/.agent-bridge/agents/<agent>/.telegram/.env` and
   `access.json` before re-running setup.

3. Trigger one bridge-daemon sync:
   ```
   ~/.agent-bridge/agent-bridge daemon sync
   ```

4. Confirm the relay is connected:
   ```
   ~/.agent-bridge/agent-bridge status --json | python3 -c \
     "import json,sys; d=json.load(sys.stdin); \
      [print(a['agent'], [p for p in a.get('plugins', []) if p.get('name')=='telegram-relay']) \
       for a in d.get('agents', [])]"
   ```
   Each Telegram agent's `telegram-relay` plugin should report
   `"status": "connected"`.

### Skip if

- This host has no Telegram-using agents.
- This host runs telegram via a non-bridge plugin (Slack/Mattermost/Discord
  share none of the "one polling consumer per token" constraint and are
  unaffected).
- The operator already opted into the relay before upgrading (the existing
  registration in `tokens.list` survives the upgrade).

### Verification target

- `agent-bridge status --json` shows each Telegram agent's `telegram-relay`
  plugin in `connected` state within 60 s of `daemon sync` returning.
- `BRIDGE_TELEGRAM_RELAY_ENABLED=1` is set in the daemon-loaded environment
  (so it survives daemon restarts).

### References

- Issue #475 — full architectural review.
- Phase 1 (daemon): #481 / v0.6.36.
- Phase 2 (plugin client): #483 / v0.6.37.
- Phase 3 (lifecycle + status): #484 / v0.6.37.
- Short-term cron mitigation already applied automatically: #474 / v0.6.34.
