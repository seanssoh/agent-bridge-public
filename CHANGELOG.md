# Changelog

All notable changes to Agent Bridge are documented here. This project adheres
loosely to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and tracks
version bumps via the `VERSION` file.

## [Unreleased]

## [0.7.0] — 2026-05-02

### Highlight — cron inbox-only reporting series ships, telegram-relay daemon removed

`v0.7.0` closes the cron inbox-only reporting series Sean approved 2026-05-02. PR1 (#499) shipped the runner contract — disposable cron children write a structured `[cron-followup]` inbox task to their parent agent (the configured `target_agent`) when a run produces a signal, otherwise log-and-exit silently. PR2 (#500) shipped the parent-side helpers (`lib/bridge_cron_followup.py` frontmatter parser, reporting-trio fields in `agb cron show`, parent-handling docs in `common-instructions.md`/`admin-protocol.md`, ARCHITECTURE.md "Cron reporting contract" section). PR3 (#501) closes the loop by ripping out the v0.6.37+ telegram-relay daemon — outbound Telegram is back to the parent agent's responsibility through `plugin:telegram@claude-plugins-official`.

### Added (PR1 + PR2)

- **Cron reporting contract** (#499 PR1). New `RESULT_SCHEMA` fields `delivery_intent` / `forward_target` / `summary_short`. Default for disposable cron children flips to inbox-only ("never write external channels yourself"). Per-job overrides via job metadata: `metadata.cronReportingPolicy = default | always_main_session | always_silent` and `metadata.cronUrgency = normal | high | urgent`. Audit fields written on every run for traceability without grepping `state/cron/runs/`.
- **Reporting trio in `agb cron show`** (#500 PR2). `last_reporting_decision` / `last_delivery_intent` / `last_inbox_task_id` exposed in human/json/shell output (record keeps `None` for absent so JSON renders `null`/shell `''`; human renderer shows `-`). `lib/bridge_cron_followup.py` is a stdlib-only frontmatter parser the parent uses to absorb forwarded cron output before deciding to forward to channels.
- **Parent-side handling docs** (#500 PR2). New `[cron-followup]` section in `docs/agent-runtime/common-instructions.md` + cross-ref in `admin-protocol.md`. ARCHITECTURE.md gains a "Cron reporting contract" section (diagram + schema + dedupe + audit trail). `docs/developer-handover.md` walkthrough updated with the real `~/.agent-bridge/cron/jobs.json` direct-edit + `agb cron import` paths.

### Removed (PR3)

- **telegram-relay daemon (#475 phases 2/3 reversal, #501)**. The v0.6.37+ telegram-relay daemon, `agent-bridge telegram-relay` CLI, `plugins/telegram-relay/`, `bridge-telegram-relay.sh`, `lib/telegram-relay.py`, `bridge-setup.py telegram --use-relay` / `--no-relay` flags, the `BRIDGE_TELEGRAM_RELAY_ENABLED` / `BRIDGE_TELEGRAM_USE_RELAY` env vars, the `bridge_telegram_relay_supervise` daemon step, and the relay status fields in `agent-bridge status` are removed. Telegram outbound now flows through `plugin:telegram@claude-plugins-official`. Per-agent `.telegram/.env` and `.telegram/access.json` are preserved — the official plugin still reads them. See `OPERATOR_ACTIONS_PENDING.md` for the manual operator migration on relay-using hosts (`docs/proposals/jjujju-migration-prompt.md`); hosts that never registered the relay require no action.
- **Smoke harness drops `telegram-relay*` smokes**: `scripts/smoke/telegram-relay.sh`, `scripts/smoke/telegram-relay-plugin.sh`, and `scripts/smoke/telegram-relay-setup.sh` are deleted along with their `scripts/ci-select-smoke.sh` includes.

### Fixed (bonus, PR3)

- **`scripts/smoke-test.sh:447` `TMP_ROOT`-unbound bug**. Pre-existing issue that persisted through the entire PR1+PR2 review cycle (PR1 r1-r4, PR2 r1-r3). The context-pressure unit block runs before the bottom-of-script `TMP_ROOT` setup, so it now allocates its own `mktemp -d` root and removes it inline after the assertions.

### Operator action

- **Relay-host migration is required.** `OPERATOR_ACTIONS_PENDING.md` v0.7.0 entry has urgency **high** for hosts that registered the v0.6.37+ relay (e.g. SYRS jjujju and any clones), urgency **none** for everyone else. Manual migration only per Sean Q-F 2026-05-02 — verbatim prompt at `docs/proposals/jjujju-migration-prompt.md`. No auto-script in `agent-bridge upgrade --apply`.

## [0.6.40] — 2026-04-30

### Highlight — stall watchdog stops false-positive nudges

`v0.6.40` is a single-fix hotfix on top of v0.6.39 that closes #496: idle admin agents (`patch` on the SYRS reference install) were receiving `[Agent Bridge]: stall detected` nudges every ~30 min indefinitely on benign Claude UI scrollback. Audit-log evidence on the affected host showed 29 spurious fires across 2026-04-29..2026-04-30 with `classification=unknown matched_line_hash=""` and a short-lived `claimed=1` produced by per-10-min cron ticks (librarian-watchdog, wiki-mention-scan, etc.) that briefly held a queue task — no actual stall was present.

- **Stall-watchdog `unknown`-fallback removed** (#497). The elif branch in `process_stall_reports()` that auto-classified an agent as `unknown` whenever (`claimed > 0 && idle >= unknown_idle && excerpt_hash != ""`) overrode the classifier's empty result with a heuristic that did not actually correlate with being stuck. The classifier patterns are deliberately narrow (Issues #161, #264, #329 Track A); an empty result is now honored as a hard "not stalled". Real stalls (`rate_limit`, `auth`, `network`, `interactive_picker`) still fire because the classifier still matches them. Defense-in-depth: `queued` is now numerically normalized and included in the `stall_detected` audit detail so future regressions in this area are diagnosable without a separate inbox snapshot.

No operator-side action is required. The fix lands automatically on `agent-bridge upgrade --apply` as part of the daemon restart.

## [0.6.39] — 2026-04-30

### Highlight — operator upgrade coverage + v0.6.x migration gaps closed

`v0.6.39` closes the v0.6.x migration-gap sweep that surfaced after Sean's dev host upgrade from v0.6.33 → v0.6.38. The host hit two regressions today (patch admin source flipping to `dynamic`, and the `autoCompactWindow:400000` managed default not propagating to existing agents) that revealed a class of bugs: changes that ship code but don't run for already-existing installs on `upgrade --apply`. Six suspected gap surfaces were swept; one (Gap 3, hooks) was a real confirmed-gap and is fixed here. The other five are either already covered (Gap 2, 5), clean by design (Gap 4, 6), or addressed by docs convention rather than code (Gap 4 / Gap 6 edge cases through the new release-PR contract).

The release also ships a single canonical upgrade procedure (`UPGRADING.md`) and a release-PR contract that requires every release to declare operator-side actions, preventing future "shipped but not propagated" gaps from slipping through.

- **Gap 3 fix — shared Claude hooks now propagated on upgrade** (#493). New `bridge_upgrade_propagate_claude_hooks` runs `bridge_ensure_claude_*_hook` (Stop / SessionStart / UserPromptSubmit / PromptGuard / ToolPolicy) once per Claude agent against the shared base settings before the rerender step. From this release onward, `agent-bridge upgrade --apply` activates any newly-added hook automatically; before this PR the new hook script was shipped to `hooks/` but the existing per-agent `settings.json` never registered it. The ensure helpers are idempotent so existing registrations are untouched.
- **`UPGRADING.md` — standard upgrade procedure** (#493). Single canonical guide for every install. Same `agent-bridge upgrade --dry-run` → `--apply` sequence regardless of host shape (canonical-only host vs admin host with source-checkout). Covers prerequisites, pre/post checks (VERSION + daemon health + `[upgrade-complete]` task body + `OPERATOR_ACTIONS_PENDING.md` walk-through), source-checkout admin variant (`AGENT_BRIDGE_SOURCE_DIR` / `--source`), and troubleshooting (stale `AGENT_SESSION_ID` cascade prevention #314/#315, `--apply` failure recovery, rollback, conflict files, daemon not restarting).
- **Release-PR contract — operator-action declaration** (#493). New section in `docs/agent-runtime/admin-protocol.md` lists the 6 change categories that almost always need an `OPERATOR_ACTIONS_PENDING.md` entry (new env-var defaults, channel plugin / default flips, hook events not auto-propagated, cron schedule changes, roster schema additions, settings.json keys not in `BRIDGE_MANAGED_CLAUDE_SETTINGS_DEFAULTS`). Reviewers bounce a release PR back as `review-needs-more` if a relevant change ships without an entry.
- **CLI surface alignment** (#493 codex review-then-fix). `agent-bridge upgrade --apply` is now an explicit alias for the default apply path (matches every UPGRADING.md / OPERATIONS.md / admin-protocol.md example). `agent-bridge daemon <subcommand>` dispatches to `bridge-daemon.sh`.

Three follow-up regression fixes from today's dev-host audit are also bundled:

- **Patch source regression fix** (#488 / #2292). v0.6.38 upgrader misclassified the static admin patch as `source=dynamic` because `bridge_write_role_block` overwrote source unconditionally. New `bridge_agent_has_static_admin_shape` (engine=claude + SESSION-TYPE=admin + canonical workdir + SOUL.md) detects admin shape; new `agent reclassify [--apply]` CLI is dry-run by default and self-heals already-broken installs. `upgrade --apply` runs the fixup automatically; JSON/text output adds `source_reclassify`.
- **Shared Claude settings rerender** (#491 / #2299). v0.6.36's `autoCompactWindow:400000` managed default landed in code but the upgrader never re-rendered effective settings for existing agents. New `agent rerender-settings [--apply]` CLI is dry-run by default and emits `shared_settings_rerendered` audit row + visible failure on render/link error. `upgrade --apply` runs the rerender automatically; JSON/text adds `shared_settings_rerender`.
- **Setup telegram default flip** (#490 / #2293). `agent-bridge setup telegram <agent>` now defaults to `--use-relay` (the architectural fix from v0.6.37 #475 phase 2/3). `--no-relay` is the transitional escape hatch. Mutually-exclusive with `--use-relay`. Fresh setups land on the architecturally-safe relay path automatically; existing legacy registrations are untouched until the operator re-runs setup.
- **Mattermost channel plugin** (#438). External contributor (`@daejeong-cosmax`) ships the Mattermost channel plugin under `plugins/mattermost/`. Inbound transport is Mattermost's WebSocket gateway; outbound replies via `mattermost-mcp-server`. Single-bot and multi-bot routing (one plugin process opens N WebSocket connections, routes by `@username` mention). Codex review-then-fix landed five blockers before merge (Mattermost ID validator was using Discord snowflakes / `MATTERMOST_BOT_ROUTES` silent fallback / multi-bot watchdog could exit 0 / stale bun.lock / missing focused smoke).

`OPERATOR_ACTIONS_PENDING.md` gains three new sections:

- v0.6.39 hook propagation (informational, no action required).
- v0.6.39 settings rerender for hosts that upgraded before #491 (run `agent-bridge agent rerender-settings --apply` to backfill).
- v0.6.39 telegram-relay default flip (informational, no action required for existing legacy installs).

## [0.6.38] — 2026-04-29

### Highlight — `OPERATOR_ACTIONS_PENDING.md` mechanism

`v0.6.38` ships a small but cross-cutting mechanism so that release-specific operator actions (like v0.6.37's telegram-relay opt-in) reach every install's admin automatically on the next `agent-bridge upgrade --apply`. Without this, the only way a host's admin learns about a per-release action is by reading the changelog; for low-attention hosts the action gets missed indefinitely.

- **`OPERATOR_ACTIONS_PENDING.md`** at source root. Section per release, newest at top. Each section names the version range it applies to (`applies_when_upgrading_from`), the concrete action to run, the skip rule, and a verification target. The first entry is v0.6.37's telegram-relay opt-in (re-key each Telegram-using agent through `agent-bridge setup telegram <agent> --use-relay --yes` and ensure `BRIDGE_TELEGRAM_RELAY_ENABLED=1` is set in the bridge daemon's environment).
- **`bridge-upgrade.sh`** post-task body now references the file unconditionally. The existing v0.4.0 wiki bootstrap content is preserved; the new reference is appended, not a replacement. Done-note format extended to include an `operator-actions: <summary>` field.
- **`docs/agent-runtime/admin-protocol.md`** adds a "Post-Upgrade Operator Actions Pending" section that defines the per-section processing rule (`applies_when_upgrading_from` filter, skip rule, done-note summary). admin agents read this on every session start, so the contract is canonical from the next upgrade onward.

After this release, every host that runs `agent-bridge upgrade --apply` receives an `[upgrade-complete]` task whose body points at the checklist; the admin processes each applicable section and reports back in the done note. Future release PRs update `OPERATOR_ACTIONS_PENDING.md` only — the upgrade machinery itself does not need touching again.

## [0.6.37] — 2026-04-29

### Highlight — #475 telegram-relay daemon fully wired (Phase 2 + Phase 3)

`v0.6.37` finishes the #475 telegram-relay arc that v0.6.36 started. Phase 2 ships the plugin client adapter; Phase 3 ships the setup-time lifecycle wiring + status display. After this release an operator can opt-in with a single `agent-bridge setup telegram <agent> --use-relay --yes` and the SIGTERM-and-replace race in `claude-plugins-official/telegram@0.0.6` (the original #468 cascade) is closed at the architectural level for that agent.

All four #475 architectural blockers are now closed:

1. ✅ Cron cascade (v0.6.35 / #474)
2. ✅ Admin dead-code instructions (v0.6.36 / #479 #472 follow-up)
3. ✅ Daemon scaffolding (v0.6.36 / #481 phase 1)
4. ✅ Plugin client adapter + lifecycle wiring (v0.6.37 / #483 phase 2 + #484 phase 3)

### Telegram-relay plugin client adapter (#483 / #475 phase 2)

- New plugin tree under `plugins/telegram-relay/` (15 files, +1740 LOC). `server.ts` (~785 LOC) is a bun entrypoint that mirrors the upstream `plugin:telegram@claude-plugins-official` MCP tool surface but does NOT call `getUpdates`. It connects to the Phase 1 daemon's unix socket and forwards inbound updates to `agb urgent <agent>` and outbound `reply` calls to the daemon's `send_message` RPC.
- MCP tool surface: `reply` is the primary tool with `{chat_id, text, reply_to}` schema. `react`, `download_attachment`, `edit_message` are registered as explicit `unsupportedTool` placeholders so Claude sessions calling upstream tool names get a clean error rather than a missing-method failure.
- Token security: token is read from env (`TELEGRAM_BOT_TOKEN`/`BOT_TOKEN`/`TOKEN`), never accepted on argv, never logged. The plugin passes only `--token-file <path>` to the daemon CLI.
- Auto-bootstrap: `BRIDGE_TELEGRAM_RELAY_AUTOSPAWN=1` lets the plugin spawn the daemon if it isn't already running. `TELEGRAM_RELAY_REGISTER_TOKEN=1` (default) auto-writes the token-hash to `tokens.list`.
- Smoke: `scripts/smoke/telegram-relay-plugin.sh` (+364 LOC) stands up the full chain — fake Telegram HTTP server → Phase 1 daemon → two plugin instances. Asserts both plugins receive the same fake update exactly once each (the core fan-out invariant), `reply` round-trips with `chat_id`/`reply_to_message_id`/`text`, plugin SIGTERM doesn't take the daemon down (`relay remains healthy after plugin SIGTERM`), and daemon-restart triggers plugin auto-reconnect with post-restart updates delivered correctly.

### Telegram-relay setup lifecycle wiring + status display (#484 / #475 phase 3)

- `bridge-setup.py telegram --use-relay` (or env `BRIDGE_TELEGRAM_USE_RELAY=1`) now does the full opt-in in one command: writes `.env` + `access.json` (existing data shape unchanged) PLUS a separate `relay-token` file (mode 600, raw token) PLUS registers the token-hash in `~/.agent-bridge/state/channels/telegram/tokens.list` (mode 600). All file writes go through `save_text` which does atomic temp-file rename + `os.chmod(0o600)` both before and after the rename so tokens never appear at any-readable mode even briefly. State root `~/.agent-bridge/state/channels/telegram/` is `chmod 0o700`.
- Without `--use-relay`, `bridge-setup.py telegram` behavior is byte-for-byte unchanged — existing operators on `plugin:telegram@claude-plugins-official` are not affected. A soft stderr deprecation warning fires when an existing agent is reconfigured WITHOUT `--use-relay` after a grace-period date (`TELEGRAM_RELAY_LEGACY_WARN_AFTER`).
- `agent-bridge status` (`bridge-status.py +311` LOC) now renders per-agent MCP plugin liveness. For `plugin:telegram-relay@agent-bridge`, four states distinguished:
  - `not-supervised` — token-hash not in `tokens.list`.
  - `daemon-down` — relay socket not reachable, OR `health` RPC failed.
  - `polling-stale` — daemon reachable but `last_get_updates_ts` > 60s.
  - `connected` — daemon reachable + recent `getUpdates` + ≥ 1 connected client.
- `agent-bridge status --json` exposes the same liveness as a structured `plugins` field per agent so operators can script against it.
- `plugins/telegram-relay/README.md` "Opt-In Steps" collapsed from 5 manual steps to 2 (`agent-bridge setup telegram <agent> --use-relay --yes` does the rest). `docs/agent-runtime/migration-guide.md` adds a section for migrating existing agents from `plugin:telegram@claude-plugins-official` to `plugin:telegram-relay@agent-bridge`.
- New smoke `scripts/smoke/telegram-relay-setup.sh` (+235 LOC) covers the full setup → sync → status round-trip: setup `--use-relay` → tokens.list mode 600 + token hash + token path → `daemon-down` (before supervisor sync) → `bridge-daemon.sh sync` → `connected` → token removal → `not-supervised`. Three of the four status states are exercised in the smoke; `polling-stale` requires time-boundary mocking and is verified manually.

### Operator opt-in (after this release)

Single command on a managed agent:

```
agent-bridge setup telegram <agent> \
  --token "<bot-token>" \
  --allow-from "<user-id>" \
  --default-chat "<chat-id>" \
  --use-relay --yes
```

Then ensure `BRIDGE_TELEGRAM_RELAY_ENABLED=1` is set in the bridge daemon's environment and the next `bridge-daemon.sh sync` cycle will spawn the relay. `agent-bridge status --json` confirms the plugin reports `connected`.

## [0.6.36] — 2026-04-29

### Highlight — context-size auto-compact + telegram-relay daemon phase 1 + admin instruction cleanup

`v0.6.36` lands the longer-tail follow-ups from the same wave that produced v0.6.35. Three of the four open #475 architectural blockers from the Sean / sales_sean Telegram disconnect investigation are now closed (cron cascade in v0.6.35; root-cause polling daemon scaffolding here; admin-side dead-code instructions cleaned up).

- **Setup-time context-size lowering** (#480, closes #473). Each managed Claude agent's `~/.claude/settings.json` now ships with `autoCompactWindow: 400000` as a bridge-managed default. Operator overlays still win — the merge order is `defaults → base → settings.local.json`. Lifecycle hits all three entry points: `agent-bridge agent create`, `bridge-init.sh` admin bootstrap, and `agent-bridge upgrade --apply`. Roster-managed custom workdirs are now treated as shared-settings mode so they pick up the merge without a separate path. The 400k value matches the Claude Code maintainer's public guidance for `[1m]`-variant agents (`autoCompactWindow < 1M`, "400k is a good compromise"); after this PR, Claude Code's *native* auto-compact handles context pressure long before any pane-text pattern would have woken the deprecated daemon-side detector.
- **Telegram polling relay daemon — Phase 1** (#481, partial close on #475). New `lib/telegram-relay.py` (~785 LOC) is a single-token-owner polling daemon supervised by `bridge-daemon.sh`. Plugin clients become thin RPC clients over a unix socket, eliminating the SIGTERM-and-replace race in the upstream `claude-plugins-official/telegram` plugin at the architectural level. The daemon is **opt-in** via `BRIDGE_TELEGRAM_RELAY_ENABLED=1` (default off) — no live behavior change in this release. Phase 2 (plugin client adapter) and Phase 3 (`bridge-setup.py` wiring + `agent-bridge status` plugin liveness) follow.
- **Admin role instruction cleanup** (#479, #472 follow-up). `docs/agent-runtime/admin-protocol.md` static-agent maintenance bullet rewritten to make explicit that automatic context-pressure handling is delegated to setup-time context-size lowering (#473) and that `agent-bridge agent compact|handoff <agent>` are now strictly operator-initiated primitives. Closes the docs gap left by #477 deprecating the daemon-driven trigger.

### Setup-time context-size lowering (#480 / #473)

- New `BRIDGE_MANAGED_CLAUDE_SETTINGS_DEFAULTS = {"autoCompactWindow": 400000}` constant in `bridge-hooks.py`. Intentionally does NOT set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env var because Claude Code 2.1.123+ has env-var precedence over settings — setting both would silently override operator overlays.
- `bridge-hooks.py::cmd_render_shared_settings` merge layering: `merge_settings(BRIDGE_MANAGED_CLAUDE_SETTINGS_DEFAULTS, base_payload)` → `merge_settings(merged, overlay_payload)`. Operator overlay (`~/.agent-bridge/.claude/settings.local.json`) ALWAYS wins.
- `bridge_claude_settings_mode` (`lib/bridge-hooks.sh:55-79`) extended: previously only home-root-managed workdirs were `shared`; now also recognizes roster-managed custom workdirs (path comparison via realpath) as `shared`. New helper `bridge_hook_paths_equal` does the realpath compare via Python.
- `bridge_ensure_claude_shared_settings_for_managed_workdir` is the single entry point that lifecycle paths now call:
  - `bridge-agent.sh:1313` — `run_create()` after roster reload, before isolation prep, when engine is claude.
  - `bridge-init.sh:441-446` — admin bootstrap when not in dry-run and admin engine is claude.
  - `bridge-upgrade.sh:170-185, 1156-1158` — `bridge_upgrade_propagate_claude_shared_settings` iterates every claude-engine roster agent on `--apply`, never on dry-run.
- New focused smoke (`scripts/smoke/hooks.sh:+125`): bridge defaults only / base wins over defaults / overlay wins over base+defaults / nested env keys preserve / isolated-root overlay preservation / custom managed workdir symlink behavior. 4 assertion helpers added.
- Codex agents are unaffected (engine guard on every callsite); they have no `~/.claude/settings.json` to merge into.

### Telegram polling relay daemon Phase 1 (#481 / #475)

- **`lib/telegram-relay.py` (+785 / 0)**: single-instance-per-token polling daemon. Reads bot token from a file (mode-checked, never on argv, never logged). Long-polls Telegram `getUpdates` in one thread, fans out to clients via JSON-line RPC over `~/.agent-bridge/state/channels/telegram/<token-hash>.sock`. RPC verbs: `register {client_id, channel_filter}`, `recv {since_id, timeout_seconds}`, `send_message`, `unregister`, `health`. Per-(client, update_id) dedupe + late-join buffer replay (TTL default 24h, max 1000 entries). Cursor + buffer state under `<token-hash>/`, both protected by `state.lock` flock; buffer persist is ordered BEFORE cursor advance so a crash mid-batch can't lose ack'd updates. SIGHUP token rotation: if the new token's hash differs, daemon emits `telegram_relay_token_rotated` audit + graceful exit (supervisor respawns under new hash); same hash is in-place token reload.
- **`bridge-daemon.sh +54`**: new supervision section reads token-hash list from `~/.agent-bridge/state/channels/telegram/tokens.list`, ensures one relay per hash, audits `telegram_relay_supervise` on spawn. Default off via `BRIDGE_TELEGRAM_RELAY_ENABLED=1` env knob.
- **`bridge-telegram-relay.sh +54` + `agent-bridge` route**: operator CLI surface `agent-bridge telegram-relay {start|stop|status|health}`. `start --token-file <path> --foreground` for debugging; `status` lists active relays with PID, socket, cursor, client count; `health --token-hash <hash>` calls daemon's `health` RPC and pretty-prints. Token never accepted on the command line.
- **`scripts/smoke/telegram-relay.sh +233`**: end-to-end smoke against a fake Telegram HTTP server. Asserts: two clients both receive the same update once (fan-out), `send_message` POSTs `chat_id`/`reply_to_message_id`/`text` correctly, daemon SIGTERMs cleanly within deadline (`wait_for_pid_exit` helper), cursor persisted across restart, late-joining client replays buffered updates within TTL, SIGHUP token rotation emits `telegram_relay_token_rotated` audit with `old_hash`/`new_hash` and the daemon exits 0 instead of running with mismatched state. Plus a separate fault-injection case (`BRIDGE_TELEGRAM_RELAY_FAULT_BUFFER_WRITE=1`) that proves cursor never advances past unwritten buffer state.
- **Phase 2 / Phase 3 deferred**: plugin client adapter (so `claude-plugins-official/telegram@0.0.6/server.ts` becomes a thin RPC client) and lifecycle wiring (`bridge-setup.py telegram` registers the daemon, `agent-bridge status` shows MCP plugin liveness) ship in follow-up PRs. Until those land, `BRIDGE_TELEGRAM_RELAY_ENABLED=0` and nothing live changes.

### Admin instruction cleanup (#479 / #472 follow-up)

- `docs/agent-runtime/admin-protocol.md:83` (the static-agent maintenance bullet) rewritten to two bullets:
  1. Automatic context-pressure handling is delegated to setup-time Claude Code context-size lowering (#473). The daemon no longer auto-creates `[context-pressure]` tasks (#472).
  2. `agent-bridge agent compact|handoff <agent>` remain valid as **operator-initiated** primitives only. Both reject dynamic agents (defense in depth) and write synthetic queue tasks + audit rows on the static path.
- Single-file doc change; no code or CI surface touched.

## [0.6.35] — 2026-04-29

### Highlight — Telegram disconnect mitigation + admin-compact pipeline removal + agent CLAUDE.md slim

`v0.6.35` ships three independent improvements that landed in the same wave:

- **Telegram MCP plugin mid-session disconnect cascade — short-term mitigation** (#474, closes #468 cron-driven path). Cron disposable children no longer auto-load MCP plugins by default, which prevents the upstream telegram plugin's stale-pid SIGTERM logic from killing the parent agent's live poller every cron tick. Net: 30-min cron-cascade-driven disconnects on `event-reminder-30min` / `librarian-watchdog` / `picker-sweep` etc. stop firing. Cron cold-start cost also drops ~49% (~22K input tokens / run on the SYRS reference install).
- **Admin-compact queue-trigger pipeline deprecated** (#477, closes #472). The daemon-driven `[context-pressure]` → `[admin-compact]` queue chain is removed because Claude Code agents have no in-session primitive to invoke their own compaction; the chain only produced queue noise + orphan `NEXT-SESSION.md` files. Detection + audit telemetry (`context_pressure_detected`, `_suppressed`, `_recovered`) is preserved. Manual operator primitives (`agent-bridge agent compact|handoff <agent>`) stay valid. Replacement direction is setup-time `~/.claude/settings.json` context-size lowering — tracked separately in #473.
- **`_template/CLAUDE.md` managed block slimmed** (#476, closes #471). 206 lines / 27 KB → 97 lines / 9.3 KB (≈ 64% reduction). Verbose admin-only and common-protocol bodies moved to `docs/agent-runtime/{common-instructions,admin-protocol}.md`; the per-agent template carries pointers only. `bridge-migrate.py overhead` extended with legacy inline section detection + file-side `CLAUDE.md.bak-<YYYYMMDD>-managed-block` sidecar backup on apply.

### Cron MCP default flip (#474)

- `bridge-cron-runner.py::disable_mcp_for_request` default flipped from `False` to `True` for non-channel cron disposable children. Channel relays (`disposable_needs_channels=True`) and explicit per-job `metadata.disableMcp=False` continue to load MCP. Existing recurring jobs (`event-reminder-30min`, `librarian-watchdog`, `picker-sweep`) automatically benefit; no manifest changes needed.
- `--strict-mcp-config` is the only flag passed (no separate `--mcp-config <path>`). Live `claude -p` reproduction confirmed `--strict-mcp-config` alone is sufficient and `--bare` is unsuitable for cron because it skips auth.
- Precedence chain remains: channel safety override > `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP` env > per-job `metadata.disableMcp` > **default True (new)**.
- 8-case unit harness in `scripts/smoke-test.sh` covers all paths (safety override, env, per-job opt-out/in, default flip).

### Admin-compact pipeline deprecation (#477)

- `bridge-daemon.sh::process_context_pressure_reports` reduced to detection-only. The 199-line static-target task creation + direct-notify + body-builder block is removed; audit rows (`context_pressure_detected` on severity edge or hash drift, `context_pressure_suppressed` for dynamic agents, `context_pressure_recovered` on empty-severity recovery) and per-agent state-file telemetry are preserved.
- Helpers no longer used (`bridge_context_pressure_title`, `_title_prefix`, `_priority`, `_decode_excerpt`, `bridge_write_context_pressure_report_body`) deleted.
- `bridge-cron-runner.py::notify_admin_pressure_defer` and its caller removed; cron memory-pressure deferral itself (queue lifecycle + `cron_dispatch_deferred` audit) is preserved.
- Smoke harness updated: `scripts/smoke-test.sh` and `tests/admin-static-dynamic-boundary/smoke.sh` drop legacy `[context-pressure]` task-creation assertions; new function-level unit covers all four audit modalities (static warning, hash drift, dynamic suppression, recovery) with `bridge_queue_cli`/`bridge_notify_send` stubs wired to `exit 99` so any accidental regression hard-fails the test.
- Manual primitives (`agent-bridge agent compact|handoff <agent>`) and `NEXT-SESSION.md` SessionStart-hook ingestion untouched. `[admin-handoff]` operator-driven path out of scope.
- `agents/_template/CLAUDE.md` admin instruction telling the admin to call `agent compact` on `[context-pressure]` tasks is intentionally NOT modified in this PR — it follows in a small follow-up after #476's doc-slim merged. The admin-side instruction now lives in `docs/agent-runtime/admin-protocol.md` and the follow-up will drop it there.

### Agent CLAUDE.md slim (#476)

- `agents/_template/CLAUDE.md` managed block (`<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->`) reduced from 206 lines / 27 KB to 97 lines / 9.3 KB. The verbose bodies of "Agent Bridge external push policy" (50 lines + JSON schema), "Autonomy & Anti-Stall" (7 lines), "Upstream Issue Policy" (10 lines), "Admin First-Run Onboarding Defaults" (~20 lines), "Admin Self-Cleanup of Own Queue" (12 lines), "Admin Static vs Dynamic Agent Boundary" (7 lines), "Admin Upgrade Protocol" (7 lines), and "Channel Setup Protocol" (12 lines) are removed. The slim block keeps `Agent Bridge Runtime Canon`, `Runtime Protocol Pointers` (new), `Queue & Delivery`, a 1-line `Task Processing Protocol`, `Change Reporting`, and `Legacy Guardrails`.
- Backfilled into `docs/agent-runtime/common-instructions.md`: `External Push Handling`, `Channel Setup Protocol`, and the previously-missing `Change Reporting` section. Variants of "Admin First-Run Onboarding Defaults" / "Admin Self-Cleanup" / "Admin Static-vs-Dynamic" / "Admin Upgrade" already lived in `docs/agent-runtime/admin-protocol.md`.
- `bridge-docs.py::render_agent_bridge_block` refactored to render pointer-style managed blocks. The role-filter (admin role gets `ADMIN-PROTOCOL.md` symlink + an `Admin Protocol Pointer` block) is preserved.
- `bridge-migrate.py overhead` extended:
  - `dry-run` reports per-agent `legacy_inline_blocks` (the headers from the slimmed list above, when found inside the managed block) alongside the byte-count diff.
  - `apply` writes the rollback backup under `state/doc-migration/backups-<stamp>/<agent>.CLAUDE.md.bak` AND, when legacy inline sections are detected, a file-side sidecar `CLAUDE.md.bak-<YYYYMMDD>-managed-block` next to the agent's `CLAUDE.md` for operator inspection.
  - Rollback uses the state backup; sidecar is operator-only and stays in place.
- Smoke assertion swapped from inline `## Autonomy & Anti-Stall` text to pointer-based `## Runtime Protocol Pointers` + `COMMON-INSTRUCTIONS.md` checks (`scripts/smoke-test.sh`).
- Net effect on a 20-agent install: managed-block bytes drop from ~540 KB to ~190 KB across all agents.

### Other tracked issues

- **#475 — Telegram polling: single-owner relay daemon** (registered, not implemented). Long-term root-cause fix for the #468 cascade. Moves the polling consumer for each Telegram bot token out of the per-session MCP plugin process and into a single supervised daemon owned by Agent Bridge runtime. Plugin process becomes a thin RPC client over a local socket. Closes both #468 (telegram singleton-lock cascade) and #234 (bun-based MCP parent-death) at the architectural level. Tracked for a future sprint; #474 is the short-term mitigation.

## [0.6.34] — 2026-04-28

### Highlight — memory pipeline rewiring (#390 PR-1/2/3)

`v0.6.34` ships 3 of the 4 #390 memory-pipeline rewiring PRs that close the
gaps where always-on agents' daily JSONL conversations weren't reaching wiki/
memory. PR-4 (PreCompact threshold tuning) is operator-policy and stays a
follow-up.

The release also includes `static agent restart recovery hardening` (#447),
`dev plugin cache source-overlay fix`, and the previously-shipped
`v0.6.30 isolated-agent residuals hotfix series` continuation.

### Memory pipeline (#390 PR-1/2/3)

- **`feat(memory-pipeline): daily-note-reconcile.py`** (PR #449, #390 PR-1).
  Ships the dependency for the rest of the rewiring sequence — a thin
  idempotent script that merges a Claude session jsonl into the agent's
  daily note. Per-turn sha1 fingerprints stored inside the existing
  `bridge-daily-meta` JSON envelope under `reconciled_fingerprints`. CLI
  exposes `--agent <id> --jsonl <path> [--date YYYY-MM-DD] [--dry-run]
  [--memory-dir <path>] [--transcripts-home <path>] [--json]`. fcntl.flock
  on a sentinel file spans read/modify/write so concurrent invocations
  (cron + Stop hook) don't lose updates. Path traversal sanitization on
  `--agent` (allowlist `[A-Za-z0-9_-]+`) and `--memory-dir` (must resolve
  within `BRIDGE_HOME`). Manifest recovery from body when the meta-block
  manifest is missing/corrupt — re-fingerprints existing turn blocks
  before treating them as new (prevents duplicate-on-first-run-after-
  manifest-loss).
- **`feat(memory-pipeline): Stop hook → daily-note-reconcile`** (PR #450,
  #390 PR-2). Adds `hooks/session-stop.py` that invokes the reconcile
  script when a Claude session ends. Primary jsonl source is the Stop
  event stdin's `transcript_path` (canonical — Claude Code passes the
  exact jsonl path it just wrote, mirroring `surface-reply-enforce.py`);
  fallback chain via `bridge-memory.py current-session-id` + workdir
  slug derivation, honoring `BRIDGE_TRANSCRIPTS_HOME` and
  `CLAUDE_PROJECT_DIR`. Hook always exits 0 — Stop hooks must not break
  the operator's session. Registered alongside `surface-reply-enforce`
  in `agents/_template/.claude/settings.json`'s `Stop` array, timeout 35.
  `_bridge_home()` returns `Optional[Path]` — when `BRIDGE_HOME` is unset
  AND the script-parent.parent fallback isn't a recognizable bridge
  home (no `scripts/`+`agents/` siblings), the hook fast-paths return 0
  without invoking reconcile from an unexpected location.
- **`feat(memory-pipeline): cron-side jsonl reconcile in harvester`**
  (PR #451, #390 PR-3). Modifies `scripts/memory-daily-harvest.sh` to
  invoke `daily-note-reconcile.py` BEFORE the existing
  `exec bridge-memory.py harvest-daily ...` calls. Single insertion
  point covers all operator cron jobs — no per-job payload migration
  needed. Session-id resolved via `bridge-memory.py current-session-id`
  with `--home <workdir>` (matching `wrap-up.md` convention). Workdir
  is realpath-resolved before slug derivation so symlinked or relative
  workdirs match what the Python helper computes (slug transform:
  `s:/:-:g; s:\.:-:g`). Reconcile failures are best-effort: logged to
  stderr, never block the harvest.

### Static agent restart recovery (#447, PR #448)

- **stale env scrub**: `bridge-lib.sh` scrubs missing-root `/tmp/tmp.*`
  / `/var/tmp/tmp.*` / `/private/tmp/tmp.*` / `$TMPDIR/tmp.*` controller
  `BRIDGE_*` paths before defaults resolve. Composes with v0.6.32's
  PR #442 stale-tmp guard. Opt-in escape hatch:
  `BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1` keeps intentional smoke
  fixtures working.
- **NEXT-SESSION.md archive**: delivered handoffs move to
  `archive/NEXT-SESSION.<stamp>.<digest>.md` instead of being deleted.
  UserPromptSubmit hook reinforces active handoffs while
  `NEXT-SESSION.md` exists, reusing the existing digest marker +
  idempotent handoff queue path.
- **forced session-id refresh**: fresh NEXT-SESSION Claude restart
  excludes the previous session id from `bridge_refresh_agent_session_id`'s
  detection so the persisted state actually rotates.
- **`false` token recovery**: when a static Claude launch command was
  corrupted to start with `false` (a previous-session debugging token
  that survived a restart), the recovery rewrites that exact first
  token to the constant `claude` while preserving env-assignment
  prefixes and channel/plugin args. Uses `shlex.split` + re-quoting so
  shell metacharacters in env values don't bleed into the rebuilt
  command.

### Dev plugin cache (PR #446, internal task #391)

- **dev plugin source dependency link**: `bridge-dev-plugin-cache.py`
  now overlays source code (`server.ts`, `package.json`, etc.) into
  the cache version dir while preserving the cache's installed
  `node_modules` directory. Source `node_modules` symlinks to cache's
  `node_modules` so isolated agents resolve dependencies through the
  cache without bypassing the per-agent ACL boundary. Orphan markers
  from previous syncs are cleaned up. Idempotent on re-run.

### v0.6.34 upgrade / migration notes

#### Auto

- v0.6.33 → v0.6.34 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates all four PR groups.
- Memory pipeline activates immediately on next session-stop (PR-2)
  and next memory-daily cron tick (PR-3). The new
  `daily-note-reconcile.py` (PR-1) is the dependency both paths call.
- Stale-env scrub (PR #448 Fix 1) runs on next bridge command after
  upgrade.

#### Operator-required

- **None for upgrades from v0.6.33**.
- **For installs that observed measured capture-0 in the memory
  pipeline**: PR-1/2/3 close the 3 of 4 gaps documented in #390. Gap 4
  (PreCompact auto-compact threshold default at 83.5% rarely
  triggering) remains a follow-up — operators wanting a lower threshold
  can set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=<lower>` per the operator
  policy guidance (this is a knob, not a code change).
- **For installs with corrupted static-agent launch commands** starting
  with `false`: the recovery (PR #448 Fix 4) activates on next restart.

## [0.6.33] — 2026-04-28

### Teams plugin — inbound attachment capture

`v0.6.33` ships a single feature for the Teams channel plugin:

- **`feat(teams): capture and download inbound attachments`** (PR #443).
  Before this release, the Teams plugin (`plugins/teams/server.ts`)
  dropped `activity.attachments` and forwarded only the text body —
  inbound PDFs, Excel files, and images never reached the agent. v0.6.33
  adds a `StoredAttachment` typing and a `downloadAttachments()` helper
  that downloads file-consent attachments and inline images via
  anonymous GET to a per-message attachment directory.

  - **Path**: `<TEAMS_STATE_DIR>/attachments/<message_id>/<filename>`
    (dir 0700, file 0600).
  - **Cap**: `TEAMS_ATTACHMENT_MAX_BYTES` env (default 50 MB). Both
    pre-flight `Content-Length` check and in-flight byte counter abort
    when the cap is exceeded.
  - **Streaming**: download chunks via the response body reader (Bun
    `Response.body`); large files never fully buffer in memory.
  - **Sanitization**: strict allowlists for both `messageId`
    (`[A-Za-z0-9_:\-]+`) and filename (control chars, `..` segments,
    shell metachars all defanged). Path traversal attempts fail
    closed with `download_status=failed`.
  - **Env validation**: `TEAMS_ATTACHMENTS_DIR` requires absolute path
    + writable; `TEAMS_ATTACHMENT_MAX_BYTES` bounds-checked
    (`>0`, `<= 1 GB` ceiling). Invalid values fall back to defaults
    with a warning instead of crashing.
  - **Metadata persisted**: per-attachment `name`, `content_type`,
    `download_status` (`ok` / `skipped_non_file` / `failed`),
    `local_path`, `size_bytes`, `download_error` — written to both
    the `StoredMessage` log and the `notifications/claude/channel`
    meta passed to the agent.
  - **Cards / non-file attachments**: marked
    `download_status=skipped_non_file` so the agent still observes
    their metadata without a download attempt.

  Outbound attachments and bot-token fallback for download URLs that
  require auth are intentionally NOT in this release — see PR #443
  for the follow-up plan.

### v0.6.33 upgrade / migration notes

#### Auto

- v0.6.32 → v0.6.33 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates the change.
- New env vars (`TEAMS_ATTACHMENTS_DIR`, `TEAMS_ATTACHMENT_MAX_BYTES`)
  are optional; defaults work for all existing Teams installs.

#### Operator-required

- **None for upgrades from v0.6.32**. Teams plugin starts capturing
  inbound attachments on next plugin restart. To customize the cap
  or storage location, set `TEAMS_ATTACHMENT_MAX_BYTES` /
  `TEAMS_ATTACHMENTS_DIR` in the operator's plugin env.

## [0.6.32] — 2026-04-28

### Hotfix — v0.6.30 isolated-agent residuals (5 fixes)

`v0.6.32` bundles 5 distinct fixes for residual isolated-agent failures verified
during the v0.6.30/v0.6.31 hotfix cycles. All five land in PR #439's wake to
close out the v0.6.28-rooted isolation regressions before further feature work:

- **Dev-channel auto-accept under linux-user isolation** (#437, PR #442).
  PR #431 (in v0.6.30) added a foreground-PGID gate but that gate failed
  under linux-user isolation because the launch chain is sudo → bash →
  claude — at picker-show time the foreground PGID could be sudo or
  bash, with claude spawned later as a child. PR #435 added a polling
  foreground detector but the outer retry budget was too short (the
  caller didn't loop long enough for claude to appear under wrappers).
  v0.6.32 adds:
  - `bridge_tmux_process_tree_has_claude` — walks the tmux pane's PID
    descendants (not just foreground PGID) to find `claude`,
    `claude-*`, or `claude.*` anywhere in the tree.
  - `bridge_tmux_wait_for_claude_foreground` — bounded 60s/30-check
    polling helper that returns once claude appears in the descendant
    tree.
  - `bridge_tmux_claude_advance_blocker` — integrates the wait helper
    with `tmux send-keys ... Enter` for the dev-channels picker case.
- **Direct `bridge-queue.py` proxy routing** (#436 residual, PR #442).
  PR #439 (in v0.6.31) fixed the bash-side roster load so
  `bridge_queue_gateway_proxy_agent` could detect proxy mode, but
  direct Python invocations that bypass the bash dispatcher still
  tripped on `BRIDGE_TASK_DB=/dev/null` SQLite open. v0.6.32 adds
  proxy detection at the Python entry point in `bridge-queue.py`:
  when `BRIDGE_GATEWAY_PROXY=1`, the CLI short-circuits to the
  gateway client instead of opening the local DB. Gateway recursion
  is prevented with `BRIDGE_QUEUE_GATEWAY_SERVER=1` set on
  gateway-spawned children. `agb show/claim/done` body reads now
  work end-to-end for isolated agents.
- **Claude credential ACL mask repair** (#441 part 1, PR #442).
  Claude can rewrite `~/.claude/.credentials.json` with mode 0600
  and an ACL mask that makes the isolated UID's named-user read
  grant ineffective, sending the isolated agent back to "Not logged
  in". v0.6.32 adds `bridge_linux_repair_claude_credentials_access`
  which `setfacl -m m::r--` to restore the named-user effective
  rights. The repair runs BEFORE channel-health reads in both
  `bridge-start.sh` and the daemon health-check path. Gated on
  Linux + linux-user isolation effective + Claude agent + `sudo`
  available; skipped cleanly otherwise (no hard-exit on macOS / CI
  without sudo).
- **`--cwd` for Teams/MS365 MCP plugin definitions** (PR #442).
  Dev-channel MCP servers (Teams, MS365) now start from their
  plugin cache root via Bun `--cwd`, so the per-agent isolation
  sharing path resolves correctly.
- **Stale `/tmp/tmp.*` controller env fail-closed** (#441 part 2,
  PR #442). When isolated agent-env.sh generation sees stale
  `/tmp/tmp.*` (or `/var/tmp/tmp.*` / `/private/tmp/tmp.*` /
  `$TMPDIR/tmp.*`) controller `BRIDGE_*` paths from a contaminated
  controller shell, the generator now refuses the write with a
  clear operator-facing error rather than serializing ephemeral
  controller test paths into persistent isolated env files. Guard
  applies only during persistent agent-env writes; transient
  exports are unaffected.

### Superseded PRs closed

PR #434 (integrate isolation hotfixes and quiet bootstrap noise) and PR #435
(retry dev-channel picker foreground readiness) were closed as superseded by
PR #442. Both were authored before v0.6.30 cut and contained partial overlap
with PR #430/#431 plus a more polished version of the same dev-channel race
fix that PR #442 ships.

The "upgrade-bootstrap notification suppression" hunk from PR #434's `623417a`
commit was not picked up; if still useful, can be filed as a fresh small PR
off main.

### v0.6.32 upgrade / migration notes

#### Auto

- v0.6.31 → v0.6.32 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates all five fixes.
- Credential ACL repair runs lazily on next `bridge-start` /
  daemon health pass per agent. No manual repair needed.

#### Operator-required

- **None for upgrades from v0.6.31**. Isolated agents that previously
  hit dev-channel picker timeouts, queue body-read failures, or
  credential "Not logged in" loops start working on next start /
  health cycle.
- **For installs that ran v0.6.28 with stale controller env in their
  agent-env.sh**: the new fail-closed guard will refuse to regenerate
  agent-env.sh until the controller shell is clean. Operator action:
  `unset BRIDGE_*` (or open a fresh terminal) and re-run isolation
  prepare.

## [0.6.31] — 2026-04-28

### Hotfix — isolated agent queue CLI gateway proxy detection

`v0.6.31` is a single-PR hotfix to v0.6.30 covering a v0.6.28-rooted regression
that blocked isolated agents from using their queue CLI:

- **`fix(roster): isolated agent queue CLI gateway proxy detection`**
  (#436, PR #439). On v0.6.28 with linux-user isolation, the queue CLI
  commands (`agb inbox`, `agb show`, `agb claim`, `agb done`) raised a
  Python traceback or surfaced `Permission denied` on a peer agent's
  history `.env` file when run from inside the isolated agent's Claude
  REPL. Two related bugs in `bridge_load_roster`:

  1. **Missing env export**. When `bridge_load_roster` discovered the
     per-agent scoped `agent-env.sh` via the `BRIDGE_AGENT_ID +
     BRIDGE_ACTIVE_AGENT_DIR` fallback (the path designed to keep
     isolated UIDs off the 0600 global `agent-roster.local.sh`), it
     sourced the file but did NOT export `BRIDGE_AGENT_ENV_FILE`.
     The downstream `bridge_queue_gateway_proxy_agent` check at
     `lib/bridge-core.sh:375` requires that env var, saw it empty,
     returned 1, and `bridge_queue_cli` fell through to direct
     `bridge-queue.py` against `BRIDGE_TASK_DB=/dev/null` — SQLite
     open failed and the process exited with a traceback at the
     outer `sys.exit(main())` entry.
  2. **Peer history hydration in scoped roster load**. After sourcing
     the scoped env, the function still called
     `bridge_load_static_histories` and
     `bridge_restore_dynamic_agents_from_history`, which iterate every
     peer agent's history `.env` under `$BRIDGE_HISTORY_DIR`. Isolated
     UIDs cannot read peer files (correct ACL), so `source $file`
     failed loudly with `Permission denied`.

  Fix: after the scoped-env fallback discovery, `export
  BRIDGE_AGENT_ENV_FILE` so downstream gateway-proxy detection works.
  Gate `bridge_load_static_histories` +
  `bridge_restore_dynamic_agents_from_history` on `isolated_env_file`
  being empty — the scoped env already carries self + sanitized peer
  metadata, so peer history hydration is unnecessary and unsafe under
  isolation. `bridge_reconcile_dynamic_agents_from_tmux` is not gated
  (it self-guards on tmux availability).

  `tests/isolation-peer-routing.sh` extended with three cases: scoped
  env fallback exports the env-file path, scoped env active skips
  unreadable peer history (chmod 000 fixture), inverse legacy
  controller path still hydrates peer history (sentinel asserted).

### v0.6.31 upgrade / migration notes

#### Auto

- v0.6.30 → v0.6.31 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates the fix.
- The fix takes effect on the next `bridge_load_roster` invocation
  (i.e., next `agb` / `bridge-cli` call by an isolated agent). No
  per-agent state migration required.

#### Operator-required

- **None for upgrades from v0.6.30**. Isolated agents that previously
  could not use their queue CLI start working immediately.

## [0.6.30] — 2026-04-28

### Hotfix release — security + isolation regression

`v0.6.30` is a fast-follow hotfix to v0.6.29 covering two v0.6.28-rooted issues
that surfaced after the v0.6.29 cut:

- **Security: redact secret env values in launch logs** (#428, PR #430).
  v0.6.28's `bridge-run.sh` logged `MS365_CLIENT_SECRET` and other inline
  `KEY=value` env assignments in plaintext into per-agent logs and the tmux
  pane. v0.6.30 adds a shared launch-command redactor and routes redacted
  copies through every log surface that exposes the launch command:
  `bridge-run.sh --dry-run`, tmux-visible runner logs, safe-mode hints,
  crash reports, broken-launch state, and daemon crash-report bodies. The
  raw command is still used for execution and dev-channel picker parsing,
  so behavior is unchanged from the operator perspective except that
  secret values no longer appear in observable logs.

  Redaction is keyed on variable-name patterns: substring match on
  `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `CREDENTIAL`, `AUTH`, `BEARER`,
  `PRIVATE`, `COOKIE`, `JWT`, plus explicit secret-context `_KEY`
  variants (`API_KEY`, `AUTH_KEY`, `PRIVATE_KEY`, `CLIENT_KEY`,
  `ACCESS_KEY`, `SECRET_KEY`) and a `_PWD` suffix. Bare `_KEY` is NOT a
  redaction trigger so common non-secret names like
  `BRIDGE_LAYOUT_MARKER_KEY` and `CACHE_KEY` remain visible.

  Existing v0.6.28/v0.6.29 logs that may already contain plaintext
  secrets are not retroactively rewritten — operators who care about the
  historical log surface should rotate the affected credentials and
  audit the per-agent log files. New crash-body rendering does sanitize
  stale/raw report inputs created before the patch.

- **Regression: dev-channels picker auto-accept under linux-user
  isolation** (#429, PR #431). v0.6.28's textual picker fix from #410
  recognized "WARNING: Loading development channels" pane text and
  advanced the picker without verifying Claude owned the foreground
  process group. Under linux-user isolation, the sudo / bash launch
  chain could still be foreground when Enter was sent, causing the
  picker to advance into the wrong context. v0.6.30 adds a tmux pane
  foreground-process-group check (`pane_pid` → `ps -o tpgid=` → PGID
  command scan) that recognizes `claude`, `claude-*`, `claude.*`, and
  symlinked-claude before sending Enter. Falls back to tmux
  `pane_current_command` when ps is unavailable.

  Scope is limited to the `allow_devchannels=1` blocker path. Trust /
  summary / login-style prompt advancement is unchanged. Synthetic
  picker fixtures opt out of the foreground gate via
  `BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND=0`. The bounded
  retry loop and timeout (`BRIDGE_TMUX_DEV_CHANNELS_MAX_ADVANCE`) are
  preserved.

### v0.6.30 upgrade / migration notes

#### Auto

- v0.6.29 → v0.6.30 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates both fixes.
- Both fixes are in shared library code (`lib/bridge-core.sh`,
  `lib/bridge-tmux.sh`) and `bridge-run.sh`; no per-agent settings
  migration required.

#### Operator-required

- **None for upgrades from v0.6.29**. The redactor activates on next
  launch; the foreground gate activates on next dev-channel picker
  advancement.
- **For installs that ran v0.6.28 with secret-shaped env**: review
  per-agent log files in `state/logs/agent-<name>/` and consider
  rotating credentials surfaced there. The redactor is purely
  forward-looking for already-emitted log content.

## [0.6.29] — 2026-04-28

### Highlight — isolate-v2 6-PR series complete

`v0.6.29` ships the final piece of the isolate-v2 series (PR-A → PR-B → PR-C →
PR-D → PR-E → **PR-F**, default flip). Fresh `agent-bridge init` now provisions
the v2 layout by default; existing markerless installs stay legacy by an
explicit invariant (not a default fall-through). See PR-F section below for the
opt-out instruction (`BRIDGE_LAYOUT=legacy agent-bridge init`).

The release also bundles a v0.6.28 P1 hotfix (linux-user `agent-bridge isolate`
ACL mask narrowing), wave Phase 1.2 (dispatch-to-worker handoff for
`agent-bridge wave`), three small fixes around upgrade tooling / queue/agent
isolation / memory transcripts-home / plugin marketplace, and a daemon-side
behavior change for dynamic-agent context-pressure noise.

### isolate-v2 PR-F — default flip via explicit layout resolver

(PR #418, four review rounds)

Direction agreed across plan-review rounds r1-r5 (tasks #293/#298/#300/#302/#304):

Direction agreed across plan-review rounds r1-r5 (tasks #293/#298/#300/#302/#304):
the project's default layout for **new installs** is now v2, while existing
markerless installs stay legacy by an explicit invariant (not a default
fall-through). Controller state (`tasks.db`, daemon, cron, profiles, history)
remains under `$BRIDGE_HOME/state` in this PR — a future migration PR will
relocate it.

- **New `lib/bridge-layout-resolver.sh`** introduces a state machine with
  five named sources: `env`, `marker`, `missing-marker(existing)`,
  `fresh-install-candidate`, `invalid-marker(fallback)`. The resolver is
  read-only by contract; it never writes the marker or mutates state.
  `BRIDGE_LAYOUT_SOURCE` exposes the source enum to callers.
- **New `BRIDGE_LAYOUT_MARKER_DIR`** (default `$BRIDGE_HOME/state`) anchors
  marker discovery independent of `BRIDGE_STATE_DIR`. v2 activation never
  rebases the marker directory, so child processes continue to resolve
  `source=marker` even if a future PR relocates controller state to
  `$BRIDGE_DATA_ROOT/state`. Propagated through `bridge_export_env_prefix`
  and `bridge_write_linux_agent_env_file`.
- **`agent-bridge init` / `bridge-init.sh` ordering refactor** — init owns
  roster-load timing so `agent-bridge init --dry-run` is mutation-free on a
  fresh install. New `--data-root <path>` flag for explicit fresh-install
  opt-in. Fresh installs write and re-read the v2 marker before admin role
  creation so admin workdirs land under the v2 layout.
- **Partial env override rejection** — `BRIDGE_LAYOUT=v2` without a valid
  `BRIDGE_DATA_ROOT` is now reported as `ignored_partial_env=BRIDGE_LAYOUT`
  instead of silently being honored. Stale `BRIDGE_DATA_ROOT` is also
  cleared on `BRIDGE_LAYOUT=legacy` to prevent v2-derived roots from
  leaking into child env.
- **`scripts/wiki-daily-ingest.sh` and `scripts/memory-daily-harvest.sh`
  active-contract gating** — v2 paths now also require a populated
  `BRIDGE_DATA_ROOT` (not just `BRIDGE_LAYOUT=v2`). Closes the child env
  corner where textual defaults would push these scripts into v2 logic
  without a real active layout.
- **Tests** — `tests/isolation-v2-pr-f/smoke.sh` covers the resolver state
  machine: fresh-install-candidate not active, markerless existing stays
  legacy, valid marker, partial env rejection, marker discoverability after
  `BRIDGE_STATE_DIR` rebase, explicit env override.

Existing legacy installs upgrading to this version see no behavior change:
the resolver's `missing-marker(existing)` invariant keeps them on the legacy
code path until they explicitly run `agent-bridge migrate isolation-v2 apply`.

**Opting out of v2 on a fresh install.** With the default flip, a fresh
`agent-bridge init` now provisions the v2 layout. To stay on legacy, set
`BRIDGE_LAYOUT=legacy` before running init:

```bash
BRIDGE_LAYOUT=legacy agent-bridge init
```

Existing installs with prior usage evidence (`state/`, `logs/`, `agents/`)
are unaffected and stay legacy automatically — the override only matters for
fresh installs that would otherwise pick up the new v2 default.

### Fixes

- **`fix(isolate): plugin-grant ledger out of runtime state dir`** (#422,
  PR #423). v0.6.28 P1: `agent-bridge isolate <agent>` partially failed on
  Linux with `Permission denied` when writing `agent-env.sh`.
  `bridge_isolated_plugin_grants_write` did `chmod 0750` on the ledger's
  parent dir which (in legacy mode) is also the runtime state dir — the
  chmod reset the POSIX ACL mask to `r-x`, capping the controller's named
  `rwx` entry, so the subsequent `cat > agent-env.sh` failed. Fix: ledger
  now lives at `$BRIDGE_STATE_DIR/isolated-plugin-grants/<agent>.json`,
  isolated from the runtime state dir. Legacy fallback reader + cleanup-
  on-write preserved for upgrade migration. r2 round added fail-loud
  guards before legacy cleanup.
- **`isolate: queue body ACL + agent show normalize + bridge-memory
  transcripts-home`** (#412, PR #426). Three Track fixes for isolated
  agents in B → A → C order. Track B grants the controller named ACL on
  queue task body files so the worker can read its own brief through the
  isolated path. Track A normalizes `agent show` output so the agent's
  isolated home appears in the path columns instead of the controller's
  view. Track C adds `--transcripts-home` override to
  `bridge-memory.py current-session-id` and threads it through the
  `wrap-up` slash command so the worker resolves transcripts under
  `$HOME` (its isolated home) rather than the controller's `~/.claude`.
- **`fix(plugin): declare ms365 in agent-bridge marketplace`** (#425,
  PR #427). v0.6.28: `bridge-run.sh` preflight refused to start an
  isolated agent when its allowlisted `ms365@agent-bridge` plugin
  existed on disk and in `installed_plugins.json` but was not declared
  in `.claude-plugin/marketplace.json`. The plugin source tree shipped
  in the repo and channel/isolation code already referenced it; only
  the marketplace declaration was missing. Fix: declare `ms365` in the
  marketplace, plus a new OSS preflight check that every shipped
  `plugins/*/.claude-plugin/plugin.json` name is declared in the
  marketplace (so this gap can't recur silently), plus an allowlist
  for reserved example email domains in the OSS preflight email
  scanner so existing smoke fixtures don't mask the new check.
- **`upgrade: agb upgrade conflicts list — read-only enumeration`**
  (#394 PR-1 of 4, PR #421). When `agb upgrade --apply` leaves
  `.upgrade-conflict.<sha>` files in the live tree (an operator chose
  manual merge), there was no tooling to enumerate them. New
  `agb upgrade conflicts list` returns the conflict files sorted by
  modification time (newest first) for triage. Read-only — no resolve
  / discard / adopt yet (those land in PR-2/3/4 of the sequence).
- **`daemon: skip context-pressure task creation for dynamic agents`**
  (#419, PR #420). Dynamic agents (e.g., `agb-dev-claude`) own their
  own context-budget — Claude's compaction handles it autonomously,
  not the bridge. The daemon's
  `process_context_pressure_reports` previously emitted a queue task
  every time a dynamic agent crossed the 90% threshold, generating
  cron-follow-up noise on the operator's patch and on the dynamic
  agent's own conversation. The textual rule in the system prompt
  was insufficient on its own — daemon-side skip is the durable
  fix. The skip emits a `daemon context_pressure_suppressed` audit
  row with severity / agent / excerpt-hash so the suppression is
  observable.

### `agent-bridge wave dispatch` Phase 1.2

- **`wave: agent-bridge wave dispatch spawns workers + queue tasks`**
  (#276 Phase 1.2, PR #424). Phase 1.1 (CLI surface + state JSON +
  brief writer) shipped in v0.6.18 (PR #373). Before this PR,
  `agent-bridge wave dispatch` left every member at `pending` because
  there was no actual worker spawn or queue task creation — operators
  bypassed the durable state. This PR closes the dispatch-to-worker
  handoff:

  - For each pending member, spawns a worker via
    `agent-bridge --<engine> --name <member-id> --workdir <repo>
    --prefer new --no-attach`.
  - Reads `WORKTREE_ROOT` / `WORKTREE_BRANCH` from the dispatcher's
    metadata env file.
  - Creates a high-priority queue task per member, body = the
    member's `brief.md`.
  - Atomically transitions state JSON `pending -> running` with
    `worker` / `worktree_root` / `branch` / `task_id` populated.
    Refuses to mark non-pending member running (rc=3 from
    `bridge-wave.py state-mark-running`).
  - All-or-rollback contract: state advances only when both spawn
    and queue-task succeed; partial states get observable audit rows
    (`wave_member_dispatch_partial` / `_rollback`).
  - Emits `wave_member_queued` audit per design §10 with
    `worker` / `task_id` / `worktree_root` / `branch` keys.

  `--dry-run` stays read-only (no worker, no task, no state mutation).
  New `--repo-root <dir>` flag lets the operator point dispatch at a
  specific repo; non-git roots short-circuit with a warning, members
  stay `pending`. Phases 1.3-1.6 (codex plan/review invocation, PR
  open + close-keyword guard, completion task, close-issue
  validation) are deferred to follow-up. Issue #276 stays open
  through Phase 1.6.

### v0.6.29 upgrade / migration notes

#### Auto

- v0.6.28 → v0.6.29 binary upgrade is straightforward — no schema
  changes. `agent-bridge upgrade --apply` propagates all changes.
- The v0.6.28 P1 isolate hotfix (PR #423) takes effect on the first
  `agent-bridge isolate <agent>` run after upgrade. The legacy
  ledger location is auto-cleaned-on-write; no manual migration.

#### Operator-required

- **None for upgrades from v0.6.28**. Existing markerless installs
  stay legacy by the resolver's `missing-marker(existing)` invariant
  (PR-F default flip applies to fresh installs only).
- **Fresh installs**: `agent-bridge init` now provisions v2 by
  default. To stay on legacy: `BRIDGE_LAYOUT=legacy agent-bridge init`.

## [0.6.28] — 2026-04-28

### Runtime enforcement — input-source ↔ output-reply matching

- **`hooks(stop): enforce input-source → mcp reply matching at runtime`**
  (#415, PR #416). Issue #342 closed in v0.6.18 with a textual rule
  only — plugin tool descriptions + `_template/CLAUDE.md` instructed
  agents to send replies through the matching MCP tool. Within 24h the
  same defect resurfaced twice on the reporter's host, including on the
  agent that originally filed #342. Same-day re-occurrence on the
  originating agent is the strongest signal that text-only enforcement
  is insufficient.

  This release adds a Stop-hook runtime layer:

  - **`hooks/surface-reply-enforce.py`** (new). Reads the transcript at
    end-of-turn, finds the latest user turn with
    `<channel source="<surface>" chat_id="..." message_id="..." />`
    tags (where `<surface>` is `discord`, `telegram`, or `teams`),
    and blocks Stop with a structured `{decision: "block", reason: ...}`
    response if the assistant turn did NOT invoke
    `mcp__plugin_<surface>__reply` with a matching `chat_id` AND did
    NOT emit a `<no-reply-needed source="..." chat_id="..." />`
    marker. Reply scanning is anchored at the index of the latest
    pending user turn, so an older reply to the same chat cannot
    silently mask a newer unanswered turn (codex r1 fix).
  - **`agents/_template/.claude/settings.json`** registers the hook in
    a new `Stop` array alongside the existing `PreCompact` array.
    `agent-bridge upgrade --apply` propagates to all channel-paired
    agents automatically.
  - **`tests/surface-reply-enforce/smoke.sh`** (new). 7 acceptance
    cases including the codex-r1 regression: matching reply / missing
    reply→block / no-reply marker / TUI-source / `BRIDGE_AGENT_ID`
    empty / `stop_hook_active` re-entry / older same-chat reply does
    NOT satisfy newer unanswered turn.

  Surfaces NOT enforced: ms365 (different reply shape — email-send,
  not chat reply). The `<no-reply-needed>` marker is the operator-
  visible escape hatch for legitimately silent turns.

### v0.6.28 upgrade / migration notes

#### Auto

- v0.6.27 → v0.6.28 binary upgrade is straightforward — no schema
  changes. The new Stop hook is added to `_template/.claude/settings.json`;
  `agent-bridge upgrade --apply` propagates to all agents on next
  upgrade run.

#### Operator-required

None. After upgrade, channel-paired agents will receive a Stop-hook
block-and-resume cycle the first time they skip an mcp reply for a
channel-source input. The hook's `reason` text guides the agent toward
the correct call. Operators don't need to take action unless they
want to ALLOW a silent turn — in which case the agent emits
`<no-reply-needed source="..." chat_id="..." reason="..." />` in its
text content.

## [0.6.27] — 2026-04-28

### Fixes

- **`hooks(session-start): self-enqueue handoff-pending task`** (#409
  Track A, PR #411). `NEXT-SESSION.md` handoff was advisory only —
  the SessionStart hook injected a stdout context line, which
  empirically got out-prioritized by whatever the operator typed as the
  first user message and was silently skipped. The fix self-enqueues
  an urgent task on the agent's own inbox when a handoff is detected.
  The existing queue contract ("claim highest-priority queued task
  first") then turns the handoff into a hard precondition for any
  other work.

  - Idempotent enqueue keyed on a SHA-1 digest of the handoff content
    (matches the bash side's `bridge_agent_next_session_digest`).
  - Same digest → no-op (find-open + title equality check).
  - Content change → fresh urgent task with new digest; operator can
    `done` the previous one once the new handoff is processed.
  - `queue_cli` unavailable → exits 0 without traceback; the existing
    "Handoff present:" stdout context still emits as a fallback.

  Tracks B (settings.json schema cleanup), C (role contract
  strengthening), D (audit row for unacted handoff) of #409 stay open
  for follow-up.

- **`bridge-run: auto-accept dev-channels picker independent of
  allowlist`** (#410, PR #413). The dev-channels warning picker was
  silently failing to auto-accept on agents whose loaded dev channels
  did not intersect the per-agent
  `BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS` allowlist. Default allowlist
  is `plugin:teams@agent-bridge`, so any agent declaring an MS365-only
  (or other non-teams) dev channel stalled indefinitely on the picker.
  Affected both isolated and non-isolated agents — the issue surfaced
  on a non-isolated static agent because earlier debugging assumed
  the bug was isolation-specific.

  The fix removes the allowlist intersection from
  `bridge_run_should_auto_accept_dev_channels` entirely. Rationale:
  the presence of `--dangerously-load-development-channels` in the
  launch cmd is itself the operator's explicit opt-in; the warning
  picker is a confirmation of the same decision. Engine=claude +
  !safe-mode + dev-channels-extracted guards preserved.

### v0.6.27 upgrade / migration notes

#### Auto

- v0.6.26 → v0.6.27 binary upgrade is straightforward — no schema
  changes. Both fixes activate immediately on the next agent cold
  start (#410) / next session (#409).

#### Operator-required

None.

For operators who relied on the per-agent allowlist as a soft denial
of auto-accept, note that v0.6.27 removes that gate — if you want to
prevent auto-accept of a specific dev channel, drop it from the launch
cmd's `--dangerously-load-development-channels` flags. (No reports of
operators using the allowlist this way.)

## [0.6.26] — 2026-04-27

### isolate-v2 PR-E follow-up — dev-codex r1 review remediation

Follow-up to PR #399 (isolate-v2 PR-E shipped in v0.6.24) addressing
the 3 unresolved findings from dev-codex r1 review (`task #1418`):

- **`bridge_linux_prepare_agent_isolation` v2 quiesce gate** (#405,
  PR #405). Refuses to run if the agent's tmux session is alive — the
  channel/workdir mutations downstream do check-then-mutate on
  isolated-UID-writable parents, and the quiesce closes the swap race
  where another iteration of the agent could land between check and
  mutate. Bypassable via `BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1`
  for sandboxed smoke. v2-only; legacy unchanged. (P1#2)
- **`bridge_linux_grant_claude_credentials_access` cred setfacl
  fail-loud** (#405). Previous `|| true` swallowed setfacl failure on
  ACL-disabled mounts and the symlink-plant step would still succeed
  against an unreadable target. Now `|| bridge_die`. (P1#3)
- **`bridge_linux_share_plugin_catalog` v2 + empty cache → die**
  (#405). When `BRIDGE_LAYOUT=v2` and `$BRIDGE_SHARED_ROOT/plugins-cache`
  is empty, the function refuses to fall back to legacy
  `controller_home/.claude/plugins`. Traverse/ACL helpers no-op in v2,
  so the legacy fallback would plant unreadable symlinks. (P2#4)

### Smoke fixture hardening (PR-E suite)

PR-E smoke gains acceptance cases for each new gate plus determinism
hardening:

- **CT4 alive / dead / bypass** verify the v2 quiesce gate — alive case
  now distinguishes the quiesce-die rc=1 from the bypass-marker rc=42
  via stderr grep, so the bypass path can't masquerade as a quiesce-die
  pass.
- **CR3** verifies cred setfacl fail-loud + no symlink plant.
- **PC2** verifies v2 + empty shared cache → die.
- **EP1** pins the `bridge-run.sh` entrypoint dry-run contract via a
  synthetic fixture roster under `$TMP_ROOT` (was previously skipping
  when no host agent was present).
- **PC2/PC3** workdirs moved from hardcoded `/tmp/wd-*` to
  `$TMP_ROOT/wd-*` so cleanup is automatic via the existing trap and
  parallel-safe.
- **`scripts/smoke-test.sh`** documents the defensive-only nature of
  the new `BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT` export — the PR-E
  suite remains operator-driven (`bash tests/isolation-v2-pr-e/smoke.sh`
  directly).

### v0.6.26 upgrade / migration notes

#### Auto

- v0.6.25 → v0.6.26 binary upgrade is straightforward — no schema or
  state-file shape changes. The new gates activate immediately on the
  next isolation prepare call (which only runs under v2 active).

#### Operator-required

None. All changes are v2-gated; legacy installs are unaffected.

For operators evaluating v2 (per the long-standing instructions in the
v0.6.18-v0.6.24 release notes), the new quiesce gate means any
`agent-bridge isolate <agent>` reapply attempt while the agent's tmux
session is alive will now `bridge_die`. Stop the agent's session first,
or pass `BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1` if you genuinely
need to reapply against a running agent (uncommon — usually only for
sandboxed smoke).

## [0.6.25] — 2026-04-27

### P0 fix — smoke-test live-install wipe defense

- **`P0: smoke-test live-install wipe — 4-layer defense`** (#403, PR #406).
  PR-E's smoke (CT4) wiped a reporter's live install at
  `~/.agent-bridge/` because four independent defense layers all failed
  together. The destructive sequence: `bridge_linux_install_agent_bridge_symlink`
  did `rm -rf "$user_home/.agent-bridge"` with `user_home` flowing
  unvalidated from `os_user`; the smoke passed `"ec2-user"` (controller
  login) as `os_user`; the sudo-stub case-passed `rm` straight through
  to the host shell; and the outer smoke-test safety gate only checked
  `BRIDGE_HOME`, not the inner test's `BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT`.

  Fix lands defense-in-depth at all four layers — any one being correct
  prevents the wipe:

  - **Layer A** (`lib/bridge-agents.sh::bridge_linux_install_agent_bridge_symlink`):
    new guard `bridge_die`s if `realpath(target) == realpath(bridge_home)`
    OR if `os_user` is empty OR equals `id -un` (controller login).
  - **Layer B** (`tests/isolation-v2-pr-e/smoke.sh`): unconditional env
    redirect of `BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT` to
    `$TMP_ROOT/fake-home` so destructive paths land in tempdir even if
    a test passes a literal os_user.
  - **Layer C** (`tests/isolation-v2-pr-e/smoke.sh` sudo-stub): every
    absolute-path arg passed to `rm`/`mv`/`mkdir`/`ln`/`find` must
    resolve under `$TMP_ROOT`. Otherwise return 99 + log-to-stderr.
  - **Layer D** (`scripts/smoke-test.sh`): refuses to run when
    `BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT` is set but not rooted under
    a recognised tempdir.

  Operators upgrading from any prior version are protected immediately:
  the next time anyone runs the smoke, the layers fail loud rather than
  destroy data.

### memory-daily Tracks B+D follow-up

- **`memory-daily: apply-time migration cleanup + static-only docs`**
  (#376 B+D, PR #404). Closes the loop on #376 (Tracks A+C shipped in
  v0.6.18). All 4 tracks of #376 are now complete.

  - **Track B** (`bootstrap-memory-system.sh::step_memory_daily_cron_one`):
    detects existing `memory-daily-<agent>` crons whose agent's `source ==
    "dynamic"` and removes them via the existing 3-mode pattern (`check`
    → `drift-migration-pending` + note_drift; `dry-run` → `would-remove`;
    `apply` → `agb cron delete <id>` + `migrated-removed` audit). Operators
    with installs bootstrapped before v0.6.18 had dynamic-agent crons
    silently no-op'd by Track C; the cron entries themselves are now
    cleaned up on the next `bootstrap-memory-system.sh apply`.
  - **Track D** (`docs/agent-runtime/memory-daily-harvest.md` §12):
    documents the static-only memory-daily contract with a three-layer
    defense table (Track A registration filter → Track B apply-time
    migration → Track C harvester refusal) so future per-agent pipelines
    don't repeat the omission.

### v0.6.25 upgrade / migration notes

#### Auto

- v0.6.24 → v0.6.25 binary upgrade is straightforward — no schema or
  state-file shape changes.
- The smoke-test defense layers (Layer A, C, D) activate immediately
  on the next smoke invocation; existing operator workflows are
  unaffected.

#### Operator-required

- **(Optional, recommended)** Run `bootstrap-memory-system.sh apply`
  once on each install to clean up any pre-v0.6.18 dynamic-agent
  memory-daily crons that are still on the cron board (#376 Track B
  apply-time migration). `bootstrap-memory-system.sh dry-run` previews
  what would be removed.

## [0.6.24] — 2026-04-27

### Highlights — isolate-v2 PR-E: legacy ACL helpers no-op + v2 group-mode replacements

Fifth (and second-to-last) PR in the v2 isolation 6-PR initiative. v2
mode (`BRIDGE_LAYOUT=v2`) now stops using named-user POSIX ACLs
end-to-end and runs entirely on the per-agent group + setgid contract,
with one documented transitional exception (Claude credentials access).

**Default off** — every ACL helper falls through to the legacy path
when `BRIDGE_LAYOUT` is unset or `legacy`. PR-F (default flip) is the
only remaining piece in the series.

#### What's in scope (#399, PR #399)

- **ACL primitive helpers** + **direct setfacl call sites**
  short-circuit under v2: `bridge_linux_acl_add` /
  `_recursive` / `_default_dirs_recursive` / `_remove_recursive`,
  `bridge_linux_grant_traverse_chain` / `_revoke_traverse_chain` /
  `_revoke_plugin_channel_grants`, `bridge_linux_acl_repair_channel_env_files`.
- **Traverse refactor**: new private emitter `_bridge_linux_grant_traverse_paths`
  owns `/`-reject + missing-stop reject + Python resolver + ancestor
  check. Public v2-noop wrapper and `_bridge_linux_grant_traverse_chain_unguarded`
  (used only by the credential exception) consume the same emitter.
- **Group-mode replacements** for ACL-load-bearing v2 artifacts:
  - `agent-env.sh` → `chgrp ab-agent-<name>` + `chmod 0640`
  - per-UID `installed_plugins.json` (manifest writer signature now
    takes an explicit `agent` arg) → `chgrp + chmod 0640`
  - `$user_home/.claude/plugins` + `marketplaces` → `chown
    root:ab-agent-<name>`, `chmod 2750`
  - `$user_home/.claude` itself → `chgrp ab-agent-<name>` + `chmod 2750`
    so `~/.claude/projects` (Claude transcripts, used by the memory
    pipeline) is reachable via the v2 group/setgid path
  - channel symlink target → `chgrp + chmod 2770` idempotent for both
    new + pre-existing targets, with explicit `test -L` TOCTOU guards
- **Engine CLI fail-fast** under v2: controller-home paths rejected
  for both `cli_path` and `readlink -f` target. Optional execute probe
  via `bridge_linux_can_sudo_to`-gated `sudo -n -u <os_user> test -x`
  — no nested-sudo pitfalls.
- **`BRIDGE_SHARED_GROUP` membership** is now ensured in
  `bridge_linux_prepare_agent_isolation` for both the isolated UID
  (die on failure) and the controller (warn unless shared plugin
  cache becomes unreadable, in which case escalate to die).
- **`bridge_linux_require_setfacl`** is now gated to legacy mode and
  to v2-with-Claude (covers the credential exception). v2 + non-Claude
  drops the `acl` package prerequisite entirely.
- **`bridge-run.sh` umask wiring**: `bridge_run_apply_v2_umask_if_needed`
  helper sets `umask 007` after `bridge_require_agent` (both startup
  + roster-reload paths) so the agent process tree creates files at
  0660/group inheritance under setgid dirs. The umask is the missing
  piece that lets the controller (group member) read agent-created
  channel state files without ACLs. Helper is defined inline in
  `bridge-run.sh` above the first call site; UM3 smoke drives the
  real entrypoint with `BRIDGE_RUN_UMASK_PROBE_FILE` to assert the
  post-launch umask is `007`.

#### C1 transitional exception — Claude credentials

The single documented ACL retention is `bridge_linux_grant_claude_credentials_access`,
which preserves `r--` access on `~/.claude/.credentials.json` plus the
unguarded traverse chain on its parent ancestors. Other paths under
`~/.claude` are NOT granted; the controller-side `~/.claude` directory
itself is no longer touched by C1. KNOWN_ISSUES.md entry #16
documents the re-auth ACL refresh requirement.

### v0.6.24 upgrade / migration notes

#### Auto

- v0.6.23 → v0.6.24 binary upgrade is straightforward — no schema or
  state-file shape changes. Legacy installs see no behavior change.

#### Operator-required (v2 opt-in only — skip if staying on legacy)

If you want to evaluate v2 isolation:

1. Set `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=/srv/agent-bridge` (or
   any preferred path).
2. Out-of-band shell, run `agent-bridge migrate isolation-v2 dry-run`
   to preview, then `apply` (PR-D, shipped in v0.6.21).
3. Ensure operator account is a member of `BRIDGE_SHARED_GROUP`
   (`ab-shared` by default) — KNOWN_ISSUES.md entries #16 + #18
   document the controller re-login prerequisite.
4. Restart agents so the new v2 group memberships take effect.

The legacy ACL-based path keeps working in parallel until PR-F (default
flip) ships in the next release. Operators should NOT enable v2 on
production yet — wait for PR-F + the migration tool from PR-D to be
exercised on a non-production install first.

## [0.6.23] — 2026-04-27

### Hotfix — macOS cron memory_pressure false positive root cause

Pairs with v0.6.22 (#393 / PR #396): v0.6.22 stopped the cron-followup
spam loop, this release stops the false positive at source.

- **`cron: probe macOS kernel pressure level instead of swap_pct`**
  (#397, PR #400). `bridge-cron-runner.py`'s memory probe was treating
  `swap_pct >= 80` as `memory_pressure` on darwin, but macOS uses swap
  as a normal tier of the memory hierarchy — a laptop sitting at 90%+
  swap can be perfectly healthy because the kernel pages out idle
  memory while keeping RAM available for active workloads. Activity
  Monitor's pressure level stays "Normal" (yellow at most) under these
  conditions. Result on the reporter's host: 15+ memory_pressure
  deferrals in 30 minutes across 5+ cron families while the OS itself
  reported only "Normal" pressure.

  The darwin probe now uses `sysctl kern.memorystatus_vm_pressure_level`
  (Apple's calibrated tier — `1`=Normal, `2`=Warn, `4`=Critical), the
  same metric Apple uses for jetsam decisions and Activity Monitor's
  "Memory Pressure" graph. Defaults to deferring only when level >=
  Warn (>= 2). Env-overridable via
  `BRIDGE_CRON_DARWIN_PRESSURE_LEVEL` (accepts 2 or 4).

  Legacy `swap_pct` probe stays available as an explicit fallback via
  `BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct`, AND fires
  automatically when the sysctl is unreadable (older macOS / sandboxed
  test envs) so the host always has *some* pressure signal rather
  than zero. The legacy `BRIDGE_CRON_SWAP_PCT_LIMIT` env override
  continues to apply when the fallback fires.

  Linux probe (`/proc/meminfo` MemAvailable) is unchanged — the fix
  is gated on darwin only.

### v0.6.23 upgrade / migration notes

#### Auto

- v0.6.22 → v0.6.23 binary upgrade is straightforward — no schema or
  state-file shape changes. The new darwin probe activates on the next
  cron tick.

#### Operator-required

None. Hotfix activates automatically. macOS operators should observe
cron families resume normal flow as long as the OS is reporting
"Normal" or "Warn"-but-below-threshold pressure level. To verify:
`sysctl -n kern.memorystatus_vm_pressure_level` should print `1` or
`2` on a healthy system.

## [0.6.22] — 2026-04-27

### Hotfix — cron-followup self-feeding loop on memory-pressured hosts

- **`stall: skip cron-followup for memory_pressure deferrals`** (#393, PR #396).
  The pre-flight memory guard from #263 Track B (shipped in v0.6.x) defers
  cron dispatch when host swap > 80%, but the daemon was still emitting
  high-priority `[cron-followup]` tasks per deferred slot — creating a
  self-feeding loop on memory-pressured hosts: each followup wakes the
  parent agent, consumes tokens that materialize as more memory in the
  claude process, and increases swap → more deferrals → more followups.
  Observed pattern on a memory-pressured macOS host: 6 `memory_pressure`
  deferrals in 1 hour, each fanning a high-priority task to `patch`.

  Two-part fix:
  - `lib/bridge-cron.sh::bridge_cron_load_run_shell` now exports
    `CRON_DEFERRED_REASON` from `status.json` so the daemon can branch
    on the deferral reason. Empty string for non-deferred runs.
  - `bridge-daemon.sh::process_stall_reports` resets
    `CRON_NEEDS_HUMAN_FOLLOWUP` and `is_failure_followup` after the
    failure-path set when `CRON_RUN_STATE == deferred && CRON_DEFERRED_REASON
    == memory_pressure`. The existing burst-counter + creation block
    silently skips. An audit row records `reason=memory_pressure_deferral`
    and a `daemon_info` line surfaces the skip with the cron family for
    triage.

  Real `failed`/`timeout`/`crash` runs still emit a high-priority
  cron-followup as today. The transient-failure burst gate from
  #230-B and the success+needs_human_followup path from #385 are both
  preserved unchanged.

### v0.6.22 upgrade / migration notes

#### Auto

- v0.6.21 → v0.6.22 binary upgrade is straightforward — no schema or
  state-file shape changes. The cron-followup memory_pressure skip
  activates on the next daemon cycle.

#### Operator-required

None. Hotfix activates automatically. Operators on memory-pressured
hosts should observe the next deferred slot no longer fanning out a
followup task to the parent agent.

## [0.6.21] — 2026-04-27

### Highlights — isolate-v2 PR-D + cron-followup signal correctness

#### isolate-v2 PR-D: migration tool + docs

Operator-driven migration from the legacy ACL-based isolation layout to
v2's per-agent private root + group/setgid + secret-env split (PR-A/B/C
shipped in v0.6.18 + v0.6.19). Default off — every migrate subcommand
fails-fast on `BRIDGE_LAYOUT` unset/legacy.

- **`agent-bridge migrate isolation-v2`** (#388) ships 5 subcommands:
  - `dry-run` — read-only, works on legacy with a `currently legacy —
    would migrate X agents` hint.
  - `apply` — fails-fast on `BRIDGE_LAYOUT != v2`. Self-stop guard
    refuses if `BRIDGE_AGENT_ID` is in the active snapshot (must run
    from out-of-band controller shell). Empty active snapshot → rc=0
    with `[migrate] no active claude agents to migrate; nothing to do.`
  - `rollback` — same fail-fast + self-stop semantics as apply.
  - `commit` — only deletes manifest rows with `verify_status=ok &&
    delete_eligible=1`. Profile / skills / memory files
    (`delete_eligible=0`) are kept in the install root as a frozen
    snapshot through PR-G.
  - `status` — lock-free, read-only summary; rejects extra positional
    args.

- **`bridge_agent_default_profile_home` v2-aware** (#388). Closes a
  contract gap PR-A/B/C left open: returns the v2 workdir under
  `BRIDGE_LAYOUT=v2`, matching every read site (`profile deploy`, etc.).
  Legacy fallback to `bridge_agent_default_home` preserved for
  `BRIDGE_LAYOUT` unset.

- **`scripts/wiki-daily-ingest.sh` Lane B v2-gating** (#388). Lane B's
  strict `agent list --json` enumeration is now gated on `BRIDGE_LAYOUT=v2`;
  legacy installs fall through to the original `find $AGENTS_ROOT/*/memory/...`
  enumeration. Default-off invariant preserved. Inline strict block is
  scoped to `wiki-daily-ingest.sh`; `_common.sh::list_active_claude_agents`
  silent-success-on-malformed-JSON behavior is preserved for non-PR-D
  callers (KNOWN_ISSUES entry 15).

- **Tests**: `tests/isolation-v2-pr-d/smoke.sh` 14/14 (rootless
  acceptance for dry-run / apply / rollback / commit / status round-
  trips); `tests/wiki-daily-ingest/smoke.sh` 7/7 (was 5/5; new Lane B
  legacy fallback + v2 strict cases).

#### cron-followup signal correctness

- **`stall: success-followup bypasses cron burst-gate`** (#385, PR #391).
  `bridge-daemon.sh::process_stall_reports`'s burst-gate (introduced by
  #230-B to suppress transient API failure noise) was also suppressing
  legitimate `success+needs_human_followup=true` signals on the first
  run of every slot — cron families like `morning-briefing` have a
  daily channel-relay handoff task that the subagent legitimately marks
  `needs_human_followup=true` on success, but the gate fired
  `below_threshold` and the followup task was never created. The fix
  introduces an `is_failure_followup` flag set only when the cron's run
  state is non-success (transient API failure path); the burst counter
  + threshold gate apply only to `is_failure_followup=1`. Success-
  followups always create the task. The transient failure protection
  from #230-B is preserved.

### v0.6.21 upgrade / migration notes

#### Auto

- v0.6.20 → v0.6.21 binary upgrade is straightforward — no schema or
  state-file shape changes. The cron-followup gate fix activates on
  the next daemon cycle.
- The migration tool itself (`agent-bridge migrate isolation-v2`) is
  default-off — operators must explicitly opt in to v2 via
  `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=<path>` before any of the
  mutating subcommands will run.

#### Operator-required (v2 opt-in only — skip if staying on legacy)

If you want to migrate a non-production install from legacy to v2:

1. Set `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=/srv/agent-bridge` (or any
   preferred path) in your shell environment.
2. Out-of-band shell (NOT inside an agent's tmux session — the
   self-stop guard refuses): `agent-bridge migrate isolation-v2 dry-run`
   to preview the migration.
3. `agent-bridge migrate isolation-v2 apply` to perform the migration.
4. After verification: `agent-bridge migrate isolation-v2 status` to
   confirm. `commit` to delete eligible legacy paths once you're happy.

The legacy ACL-based path keeps working in parallel until PR-E (legacy
ACL helper removal) and PR-F (default flip) ship in upcoming releases.
Operators should NOT enable v2 on production yet — full series review
recommended before flipping the default.

## [0.6.20] — 2026-04-27

Operator-experience hotfix release. Two issues filed against v0.6.19 that
materially impact how operators interact with the runtime — neither is a
production isolation bug, but both block routine workflows.

### Operator-visible fixes

- **`tool-policy.py` allows read-intent on protected paths** (#383, PR #386).
  v0.6.19's `[upgrade-complete]` bootstrap task instructs admin to inspect
  `agent-roster.local.sh` for workarounds — but the post-#341 hook denied all
  access (Read tool, `cat`/`grep`/`head`/`tail`, even `agent-bridge config get`)
  and pointed users at `config set` as a substitute. `set` is the write path
  that should stay gated. PR-#386 distinguishes read-intent (Read / Glob /
  Grep / NotebookRead tools, ~32 read-only Bash commands, `agent-bridge config
  get` / `list-protected`) from write-intent (Edit / Write / NotebookEdit,
  output redirection, `sed -i`, `awk -i inplace`, `agent-bridge config set`).
  Read-intent bypasses the protected-path block-all branch for ALL agents.
  Write-intent stays gated by the existing #341 admin + operator-wrapper
  contract. The queue DB stays unconditionally blocked (the `agb` queue
  commands are the structured-read surface). Smoke matrix updated.

- **`agent-bridge upgrade` aborts on dirty source for tag / release/\* targets**
  (#380, PR #384). The upgrader was silently using the source-checkout's
  current working tree as the merge source — when a maintainer had
  uncommitted edits or was on a feature branch, those changes got folded
  into the upgrade and produced surprise conflicts on core files even though
  the released tag itself was clean. PR-#384 adds a pre-flight: when
  `target_ref` matches `^v[0-9]` or `release/*`, runs `git status --porcelain`
  in the source checkout and aborts with a structured message (exit 64) if
  non-empty. The message offers three resolution paths: (1) stash, (2) point
  `AGENT_BRIDGE_SOURCE_DIR` at a clean checkout, (3) explicit
  `--allow-dirty-source` opt-in for maintainers testing release candidates.
  Pre-flight runs for both `--dry-run` and `--apply` so the abort surfaces
  before any merge attempt.

### v0.6.20 upgrade / migration notes

#### Auto

- v0.6.19 → v0.6.20 binary upgrade is straightforward — no schema or
  state-file shape changes. Both fixes activate immediately on the next
  daemon cycle / next `agent-bridge upgrade` invocation.

#### Operator-required

None. Both fixes are runtime-behavior changes that take effect automatically.

## [0.6.19] — 2026-04-27

### Highlights — isolate-v2 PR-C: per-agent private root + secret-env split

The substantive isolation contract change. Replaces named-ACL grants
with POSIX group + setgid + per-agent private root. **Default off**
(`BRIDGE_LAYOUT` unset → all helpers fall back to legacy). Opt-in
via `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=<path>`.

- **Per-agent private root layout** (#381). Operator-decided contract:
  - `$BRIDGE_AGENT_ROOT_V2/<agent>/` mode 2750 owner=root group=ab-agent-<agent>
  - `home/`, `workdir/`, `runtime/`, `logs/`, `requests/`, `responses/` mode 2770 owner=isolated group=ab-agent-<agent>
  - `credentials/` mode 2750 owner=controller group=ab-agent-<agent>
  - `credentials/launch-secrets.env` mode 0640 owner=controller group=ab-agent-<agent>

  Member of `ab-agent-<agent>` group gets traverse + read; non-member
  UID has no group → cannot traverse → cross-agent secret leak blocked.
  Isolated UID can `cat` `launch-secrets.env` but cannot rm/mv/replace
  (parent + dir mode 2750 deny group write).

- **Secret-env split** (#381). `bridge_isolation_v2_load_secret_env` reads
  `launch-secrets.env` and exports its `KEY=value` pairs strictly (no
  `eval`). New file-mode check (codex r1 B-3) rejects modes broader than
  0640 (group-write or world-read). New
  `bridge_isolation_v2_exec_with_secret_env` helper wraps the child
  exec in a subshell so the parent restart-loop cannot retain secrets
  across rotations. Out-of-band `mktemp` marker pattern signals loader
  failure separately from the child's own exit code.

- **`bridge_agent_workdir` v2 precedence** (#381). When v2 active,
  per-agent root takes precedence over `BRIDGE_AGENT_WORKDIR` roster
  override. Rationale: per-agent private contract requires the workdir
  to live inside the per-agent root; an explicit override outside that
  root would break the isolation guarantee. Operators wanting a
  different anchor location should set `BRIDGE_DATA_ROOT` (moves the
  v2 anchor for the entire install), not `BRIDGE_AGENT_WORKDIR`
  per agent.

- **Memory-daily v2 wiring** (#381). `bridge-memory.py` adds
  `--per-agent-state-dir` + `--shared-aggregate-dir` args; 5 helpers
  signature-unified to consume them. `scripts/memory-daily-harvest.sh`
  3 exec branches all pass these args under v2. Shared aggregate path
  canonicalized to `$BRIDGE_SHARED_ROOT/memory-daily/aggregate`.
  Aggregate moved from `recursive_write_paths` to `recursive_read_paths`
  — enforces the contract "ab-shared = read-only public, only
  controller writes".

- **Queue gateway v2 anchoring** (#381). `requests/` and `responses/`
  paths anchor under `$BRIDGE_AGENT_ROOT_V2/<agent>/` in v2 mode;
  legacy path retained for `BRIDGE_LAYOUT` unset.

### Test coverage

- `tests/isolation-v2-pr-c/smoke.sh` ships rootless R1-R7 / S1-S5 /
  E1 / M1 acceptance cases, plus the new S3b (file-mode rejection) and
  the rewritten S4 integration test that drives the actual
  `bridge_isolation_v2_exec_with_secret_env` production helper (not a
  test-side re-implementation). X1-X3 root-required operator probes
  documented in the smoke header.

### v0.6.19 upgrade / migration notes

#### Auto

- v0.6.18 → v0.6.19 binary upgrade is straightforward — `BRIDGE_LAYOUT`
  unset means every new resolver falls back to its legacy path. Legacy
  installs see no behavior change after this upgrade. The new
  per-agent-private path activates only on `BRIDGE_LAYOUT=v2` +
  `BRIDGE_DATA_ROOT=<path>`.

#### Operator-required (v2 opt-in only — skip if staying on legacy)

If you want to evaluate v2 isolation on a non-production install:

1. Set `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=/srv/agent-bridge`
   (or any preferred path) in your shell environment or
   `agent-roster.local.sh`.
2. Run `agent-bridge agent prepare <agent>` for each agent. The
   prepare path will:
   - Create the per-agent group `ab-agent-<agent>` (idempotent).
   - Add the isolated UID + controller as supplementary members.
   - Create the `$BRIDGE_AGENT_ROOT_V2/<agent>/` tree with the layout
     above.
   - Plant `credentials/launch-secrets.env` (mode 0640, controller-write
     only) carrying any per-agent secrets that previously lived in the
     env-file.
3. Restart the agent so its supplementary group memberships and new
   anchor paths take effect.

The legacy ACL-based path keeps working in parallel until PR-D (migration
tool) and PR-E (legacy ACL removal) ship in upcoming releases. Operators
should NOT enable on production yet — the migration tool + ACL removal
are still in flight.

## [0.6.18] — 2026-04-27

### Highlights — production isolation runtime stability

The unblock target for installs stuck on v0.6.17 with linux-user isolation:

- **Teams + MS365 plugin spawn under isolated UID** (#357). Splits chmod
  from env-file read so `chmod` EPERM on a setfacl-grant-owned `.env`
  no longer aborts plugin startup. `bun --no-install` direct path for
  the isolated MCP spawn while the package.json `start` script keeps the
  install-then-run shape for shared-mode operators.
- **Channel state symlinks auto-created at isolation prepare** (#363).
  For each declared `plugin:<id>` channel, a root-owned symlink at
  `~/<isolated>/.claude/channels/<id>` → `$workdir/.<id>/` is planted
  so inbound webhooks from controller-side dispatcher reach the plugin
  reading from `~/.<channel>/`. Closes the silent webhook-disappearance
  symptom on Teams / Discord / Telegram / MS365.
- **Dev-channels picker auto-accept hardened** (#364). Per-state advance
  budget (4-action trust/summary preserved; new env-overridable
  devchannels budget defaults to 12) + caller passes the expected state
  into the advance helper so a state transition (devchannels → trust
  mid-loop) cannot debit the wrong counter and bypass the trust
  fail-fast budget.
- **POSIX ACL mask drift preflight repair** (#366). Daemon-side helper
  (gated on `bridge_agent_linux_user_isolation_requested` + Linux host)
  re-applies `m::rwX` mask + controller named-user ACL on channel
  state `.env` files before `bridge_agent_channel_status` is computed,
  so mask-drift-only failures self-heal silently. Real credential
  problems still flow through to the existing `[channel-health] (miss)`
  task, with a new `## ACL state` diagnostics section embedded in the
  task body. Non-fatal sudo guard at helper entry — daemon never
  exits via `bridge_die` from this preflight even if sudo is missing.
- **Marketplace symlink ACL fail-loud** (#369, #362). The
  `bridge_linux_share_plugin_catalog` marketplace block already had two
  of three required ACL calls but unguarded; PR adds the missing
  `bridge_linux_acl_add_default_dirs_recursive` and promotes all three
  to `|| bridge_die` so a partially-applied ACL chain no longer leaves
  a planted-but-unusable symlink. Plus a `bridge_warn` when a
  marketplace is in `known_marketplaces.json` but the on-disk tree is
  missing — operators get a diagnostic instead of silent plugin drop.
- **Peer A2A through gateway with explicit proxy signal** (#327).
  Scoped per-agent `agent-env.sh` carries peer ids + non-secret metadata
  + `BRIDGE_AGENT_PROXY=1` so isolated agents enumerate peers correctly
  and the queue-gateway routes A2A submissions without the controller's
  roster file ever being read by the isolated UID.
- **Per-UID `installed_plugins.json` honors `BRIDGE_AGENT_PLUGINS`**
  (#348, #346 r2 #347). The bridge writes a manifest filtered to the
  per-agent plugin allowlist (declared channels auto-included) so an
  isolated session only spawns the MCP servers the operator declared,
  closing the v0.6.17 plugin-fan-out regression that triggered preflight
  install loops on third-party marketplaces.

### Stall watchdog quieting on idle admin

- **stall scan skipped for loop=1 + claimed=0 + refresh_pending=0**
  (#374). The stall watchdog was re-firing `[Agent Bridge]: stall
  detected` every 20-30 minutes against `loop=1` admin agents drained
  to `claimed=0 inbox=empty` because `process_stall_reports`'
  decision-to-scan condition included `loop_mode == "1"` unconditionally.
  Classifier then false-positived on benign Claude UI text. The new
  guard skips the per-agent scan for the genuinely-idle state.

### Memory-daily source-class hygiene

- **memory-daily cron + harvester filter on static source class**
  (#376 Tracks A+C). `bootstrap-memory-system.sh` step 3b now uses a new
  `list_active_static_claude_agents` helper to register the
  `memory-daily-<agent>` cron, so dynamic claude agents (operator-
  attached TUI, no `~/.agent-bridge/agents/<name>/` home) never get the
  cron in the first place. `scripts/memory-daily-harvest.sh` adds a
  defense-in-depth source-class refusal that exits 0 (no
  `[cron-followup]` generated) when invoked against a dynamic agent.
  Tracks B (apply-time migration cleanup of existing dynamic-agent
  crons) and D (docs) deferred to follow-up PRs.

### Daemon, escalation, hooks

- **admin-gateway escalation routing to the affected agent's surface**
  (#367, #345 Track B). `bridge_escalate` for an agent whose
  notification target is unreachable now routes to that agent's own
  TUI (dynamic) or notify-target (static) rather than admin's queue —
  preserves the contract documented in #345 §"admin is not a router".
- **codex composer state-machine + type_and_submit fallback** (#368,
  #331 Track B). The tmux composer for codex agents tracks composer
  state explicitly and falls back to type-then-submit when paste-only
  submission fails on the first try.
- **system-config mutation gated behind admin + operator wrapper**
  (#341). Hooks now refuse `agent-bridge config set` writes from
  non-admin sessions and surface a structured operator-confirmation
  prompt for the admin path.
- **escalate skips admin relay for dynamic agents** (#343, #351).
  Aligns with #345 — dynamic agents are operator-attached, so
  `agent-bridge escalate question` for a dynamic agent goes straight
  to the operator's TUI instead of through admin's inbox.
- **session_nudge_sent uses queue state as delivery oracle** (#337,
  #331 Track A).
- **stall: `matched_line_hash` dedup key for nudge cap** (#355,
  #329 Track D). Stall nudges deduplicate on a stable hash of the
  matched substring instead of full transcript so a re-render of the
  same UI text doesn't compound the cap counter.
- **stall regex narrowed to transport-qualified forms** (#336,
  #329 Track A). Reduces false-positives on benign rate_limit / auth
  vocabulary in user transcripts.
- **context-pressure HUD anchoring + 7-day FP-rate counter** (#338,
  #344, #353).
- **daemon refuses 'stop' when active agents present** (#319,
  #314 Layer 3 + #315 Track 3). `--force` flag required to override.
- **SessionStart auto-clears `AGENT_SESSION_ID` on `/clear` matcher**
  (#318, #314 Layer 1). Operator no longer has to manually clear the
  per-session env after a `/clear`.

### Memory / wiki / cron

- **harvest-daily `--from`/`--to` range + `--missing-only`** (#322,
  #335). Re-PR after #332 revert.
- **wiki-daily-ingest watermark + smoke fixture for strand-recovery /
  clamp / failure gate** (#321, #334). Re-PR after #332 revert.
- **cron weekly wiki-copy-full-backfill catch-all + same-slot
  regression guard** (#320, #354).
- **cron pre-flight memory guard defers dispatch on pressured hosts**
  (#330, #263 Track B).
- **cron stagger wiki-daily-ingest to 06:00 to avoid memory-daily
  race** (#333, #320 Track A).
- **bootstrap-memory: opt-in `--backfill-history N` for first-run
  harvest gap** (#322 Track C, #356).
- **harvest-daily strict YYYY-MM-DD parser** (#340, #322 r1 deferred).

### Admin role + docs

- **admin role boundary + Self-Cleanup of Own Queue +
  Static-vs-Dynamic** (#306, #303-A, #304-A; admin runtime wire #326).
- **status: `garden` column for admin's stale blocked tasks** (#328,
  #303 Track C).
- **agent compact + handoff primitives for autonomous static-agent
  maintenance** (#360, #304).
- **upgrade docs: lead with `upgrade --apply`** (#316, #315).
- **bidirectional channel routing rule in Task Processing Protocol
  template** (#359, #342).
- **admin role spec — admin is not a human-channel gateway** (#349,
  #345 Track A).

### CLI surface

- **bare `agent-bridge` prints help summary** (#310, #283 Track D).
- **`bridge_suggest_subcommand` curated aliases for cron + help**
  (#309, #283 Track C).
- **`bridge-commands.md` auto-discovers subcommand reference from
  CLI help** (#313, #283 Track A).
- **status + list flag agents whose workdir no longer exists**
  (#312, #305 Track C).
- **smoke + cli: fixture cleanup + project-root helper silence**
  (#311, #305 A+B).
- **skill template heredocs: Cron section + agb dispatcher note**
  (#308, #283 Track B follow-up).
- **skill template — expand cron-manager + agent-bridge CLI surface**
  (#307, #283 Track B).

### Isolate-v2 redesign foundation (opt-in, default off)

The v2 isolation contract replaces named-ACL grants with a POSIX group
+ setgid + umask model. PR-A (primitives) and PR-B (shared read-only
asset relocation, dual-mode resolver) ship in v0.6.18 **gated behind
`BRIDGE_LAYOUT=v2`** (default `legacy`). Legacy installs see no behavior
change. PR-C (per-agent private root + secret extraction), PR-D
(migration tool + dry-run/apply/rollback), PR-E (legacy ACL helper
gate), and PR-F (default flip) are upcoming releases.

- **PR-A: layout primitives + group/umask helpers** (#370). New module
  `lib/bridge-isolation-v2.sh` adds path variables (`BRIDGE_DATA_ROOT`,
  `BRIDGE_SHARED_ROOT`, `BRIDGE_AGENT_ROOT_V2`,
  `BRIDGE_CONTROLLER_STATE_ROOT`), opt-in flag (`BRIDGE_LAYOUT=v2`),
  group helpers (idempotent `groupadd`/`usermod` with `rc=9` success
  treatment), `chgrp_setgid_recursive` using `find -type d|f -exec`
  for cross-platform symlink safety, errexit-safe umask wrappers using
  `trap "umask $saved" RETURN`, and group-name input sanitization for
  Linux 32-char + `[a-z_][a-z0-9_-]*` limits.
- **PR-B: shared read-only asset relocation (dual-mode resolver)**
  (#371). Resolver in `bridge_linux_share_plugin_catalog`,
  `bridge_resolve_plugin_install_path`, and
  `bridge_known_marketplaces_lookup` consults a new
  `bridge_isolation_v2_shared_plugins_root` helper that returns the
  v2 path (`$BRIDGE_DATA_ROOT/shared/plugins-cache/`) when populated
  (`installed_plugins.json` present), else falls back to legacy
  `$controller_home/.claude/plugins`. Migrated installs that have
  moved controller-managed plugin state to `/srv/agent-bridge/shared/`
  and have no `~/.claude/plugins` directory are now correctly served
  by the share helper.

### Wave orchestration plugin (Phase 1.1, new subcommand)

- **`agent-bridge wave` CLI skeleton + state JSON + brief writer**
  (#373, design doc #365). First sub-phase of the wave-orchestration
  plugin per the operator-decided design (PR #365). Ships the
  `wave dispatch|list|show|templates|close-issue` surface, durable
  per-wave state at `state/waves/<wave-id>.json`, README mirror at
  `shared/waves/<wave-id>/README.md`, and a generated 11-section brief
  skeleton per member with the close-keyword footgun warning. Members
  start `pending` — Phase 1.2 will wire worker startup + queue task
  creation; Phases 1.3-1.6 add codex adapter, PR automation, main-agent
  feedback loop, and full close-issue validation. New subcommand only
  — no impact on existing CLI behavior.

### Reverts

- **wave: PRs #323/#324/#325 merged without pair-review** (#332).
  Reverted; the same content shipped in re-PRs #333 / #334 / #335
  with codex pair-review.

### v0.6.18 upgrade / migration notes

#### Auto (covered by `bridge-upgrade.sh`)

- v0.6.17 → v0.6.18 binary upgrade is straightforward — no schema or
  state-file shape changes. The five isolation runtime fixes (#357,
  #363, #364, #366, #369) take effect on the next agent restart;
  operator does not need to run `setfacl` or `apply-channel-policy`
  by hand.
- The stall watchdog gate (#374) and memory-daily source-class filter
  (#376 Tracks A+C) take effect on the next daemon cycle / next
  `bootstrap-memory-system.sh` apply respectively.

#### Operator-required

1. **(Optional, recommended) memory-daily cron cleanup for already-
   polluted installs**: operators whose installs were bootstrapped
   before v0.6.18 will already have `memory-daily-<agent>` crons
   registered for dynamic agents. These will silently no-op after
   v0.6.18 (Track C harvester refusal exits 0), but they remain dead
   weight on the cron board until removed. To clean up:

   ```bash
   ./agent-bridge cron list --pattern 'memory-daily-' --json \
     | python3 -c '
   import json, sys
   for c in json.load(sys.stdin):
     print(c["id"], c["agent"])
   ' \
     | while read id agent; do
         src="$(./agent-bridge agent show "$agent" --json 2>/dev/null \
           | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"source\") or \"\")")"
         if [[ "$src" == "dynamic" ]]; then
           ./agent-bridge cron delete "$id"
         fi
       done
   ```

   Track B (apply-time migration) will land in a follow-up PR; until
   then this one-off cleanup is recommended.

2. **(Optional, isolate-v2 opt-in)** `BRIDGE_LAYOUT=v2` is **default
   off** in v0.6.18. Operators wishing to evaluate the v2 layout on a
   non-production install can set `BRIDGE_LAYOUT=v2` +
   `BRIDGE_DATA_ROOT=/srv/agent-bridge` (or any preferred path) and
   populate `$BRIDGE_DATA_ROOT/shared/plugins-cache/installed_plugins.json`
   from the controller's `~/.claude/plugins/` tree. PR-B's dual-mode
   resolver picks up the v2 root automatically once populated. Do
   NOT enable on production — PR-C/D/E/F (per-agent private root,
   migration tool, ACL helper gate, default flip) are still upcoming.

3. **(Optional)** `agent-bridge wave` is a new subcommand with no
   impact on existing flows. Run `agent-bridge wave templates` to see
   the Phase 1.1 surface; full multi-PR wave dispatch (worker
   startup, queue tasks, codex review) lands in Phases 1.2-1.5.

## [0.6.17] — 2026-04-25

### Documentation
- `CHANGELOG.md` and `OPERATIONS.md` get an explicit "v0.6.16 upgrade /
  migration notes" section that distinguishes operator-required steps from
  what `bridge-upgrade.sh` does automatically. The original v0.6.16 entry
  was complete on the per-PR change description but mixed automatic and
  manual concerns; operators upgrading from v0.6.15 → v0.6.16 needed to
  read each PR body to know what to run by hand. This release surfaces:
  - **Auto** (covered by `bridge-upgrade.sh`): apply-channel-policy.sh
    re-run (singleton + new BRIDGE_AGENT_PLUGINS overlay), daemon stop +
    restart with the new orphan sweep + heartbeat + sibling supervisor.
  - **Operator-required**:
    1. (Linux) v0.6.16 daemon verify after upgrade — single
       `bridge-daemon.sh run$` PID per user via
       `pgrep -af 'bridge-daemon\.sh run$'`.
    2. (Optional, recommended) per-agent plugin allowlist —
       `BRIDGE_AGENT_PLUGINS["<agent>"]="plugin1 plugin2"` in
       `agent-roster.local.sh` then `bash scripts/apply-channel-policy.sh
       && agb agent restart <agent>`. Closes the ~250 MCP / ~1 GB RSS
       scenario from #272.
    3. (Optional, per agent) daily-note migration —
       `bridge-memory.py migrate-canonical --home
       ~/.agent-bridge/agents/<agent> --user default --apply
       --i-know-this-is-live`. Default dry-run; `--apply` mandatory + the
       new `--i-know-this-is-live` guard required when `--home` resolves
       to the live `BRIDGE_HOME` (refused by default; the guard exists
       because `_resolve_bridge_bin` always routes admin task creation
       through the live binary regardless of `--home`).
    4. (Optional, per host) liveness watcher install — NOT auto-installed
       by upgrade; only fresh `bootstrap` adds it. Existing installs run
       `bash scripts/install-daemon-liveness-launchagent.sh --apply --load`
       (macOS) or `bash scripts/install-daemon-liveness-systemd.sh
       --apply --enable` (Linux). Pair with `--skip-liveness` on bootstrap
       if you do NOT want it installed automatically on a fresh host.
    5. (Optional, per cron) `--strict-mcp-config` opt-in — set
       `metadata.disableMcp=true` on individual cron jobs that don't call
       MCP, or set `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP=1` install-wide
       in the daemon environment.
- **Backward-compat regression note**: installs that intentionally used
  `<home>/users/<user>/memory/` as a multi-tenant partition will see
  `bridge-memory.py summarize-weekly --user <id>` and
  `summarize-monthly --user <id>` no longer aggregate from that
  partition. Migrate via the command above, or document the multi-tenant
  intent in your local roster and continue indexing-only via
  `collect_index_documents` (still walks both roots). See
  `docs/agent-runtime/memory-schema.md`.
- **Do not run `bridge-daemon.sh stop` separately before `upgrade --apply`** —
  the upgrader handles daemon orchestration internally. Stopping the daemon
  manually on a v0.6.13 host can cascade into all-agent tmux respawn with
  stale `AGENT_SESSION_ID` resume (see issue #314). On hosts upgraded past
  v0.6.13 the cascade is mitigated by hardening waves shipped in v0.6.14-0.6.16,
  but `upgrade --apply` remains the only sanctioned entrypoint.
- **Recommended upgrade order on a host with running agents**:
  ```bash
  # Recommended upgrade on a host with running agents — single entrypoint
  agent-bridge upgrade --apply

  # (Linux) verify single daemon PID
  pgrep -af 'bridge-daemon\.sh run$'

  # (Optional) per-agent plugin allowlist + restart specific agents
  $EDITOR ~/.agent-bridge/agent-roster.local.sh   # add BRIDGE_AGENT_PLUGINS
  bash ~/.agent-bridge/scripts/apply-channel-policy.sh
  agb agent restart <agent>

  # (Optional, per agent) daily-note migration
  bridge-memory.py migrate-canonical --home ~/.agent-bridge/agents/<agent> \
    --user default --apply --i-know-this-is-live

  # (Optional, per host) liveness watcher install
  bash ~/.agent-bridge/scripts/install-daemon-liveness-launchagent.sh \
    --apply --load
  ```

This release does NOT change any code path — only `VERSION` and
`CHANGELOG.md`. Operators on v0.6.16 do not strictly need to upgrade to
v0.6.17; pulling latest `main` is sufficient.

## [0.6.16] — 2026-04-25

### Added
- New `agb agent forget-session` complement: parallel-wave operator pattern
  validated and shipped a large hotfix wave on top of v0.6.15. See PR list
  below for full scope.
- `BRIDGE_AGENT_PLUGINS["<agent>"]` per-agent plugin allowlist (issue #272,
  PR #298). `scripts/apply-channel-policy.sh` writes
  `agents/<agent>/.claude/settings.local.json` with `enabledPlugins=false`
  for every globally-installed plugin not in the allowlist. Channels
  declared via `BRIDGE_AGENT_CHANNELS` are auto-included so an oversight
  cannot break a required transport. Legacy agents without the key keep
  full-set behaviour. Closes the ~250 MCP process / ~1 GB RSS scenario the
  issue documented.
- New `bridge-watchdog-silence.py` sibling supervisor (issue #265 proposal
  C, PR #293). Reads daemon_tick audit log; if no tick in
  `BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS` (default 600s), emits
  `daemon_silence_detected` + restarts daemon. Cooldown protected. Spawned
  by `bridge-daemon.sh start`, killed by `stop` before the daemon itself.
- New launchd LaunchAgent (macOS) + systemd `.service` + `.timer`
  (Linux) liveness watcher (issue #265 proposal D, PR #292). Checks the
  heartbeat file mtime every 60s; restarts daemon on staleness. Sibling to
  the daemon plist/unit, lives outside the bridge process tree. Opt-out
  via `--skip-liveness` to bootstrap.
- Daemon writes a `daemon.heartbeat` file alongside the `daemon_tick`
  audit row (PR #292 prep). Throttled by the same
  `BRIDGE_DAEMON_HEARTBEAT_SECONDS`.
- Per-job `metadata.disableMcp` (4 aliases) + install-wide
  `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP` env opt-in `--strict-mcp-config`
  for cron disposable Claude children (issue #263 partial, PR #297). Local
  bench: ~5–10s real → ~3.2–3.7s real per fire (~78% CPU saved). Channel-
  relay safety override built-in.
- New `interactive_picker` stall classification + admin escalation
  (PR #295). Daemon detects `/rate-limit-options`, `claude --resume` long-
  resume, and verbatim picker tail patterns; routes through the same
  admin-escalation branch as `auth` (no nudge — picker takes a keystroke,
  not text). Picker-specific recommended message distinguishes safe-default
  Enter from billing-impact options.
- `bridge-memory.py migrate-canonical --home <home> [--user <id>] [--apply]`
  folds legacy `<home>/users/<user>/memory/*.md` into the unified
  `<home>/memory/` root (issue #220, PR #296). Default mode is dry-run; pass
  `--apply` to perform an atomic move and write
  `<home>/memory/_migration_log.json` (schema
  `memory-canonical-migration-v1`). Idempotent — a second `--apply`
  on a converged install reports `moved: 0`. Collisions (the same
  `<date>.md` exists in both roots) are renamed to
  `<date>.legacy.md` in the canonical root and an admin task is
  filed best-effort via `agent-bridge task create --to patch`. The
  manifest accumulates a `runs[]` history so multi-pass migrations
  retain provenance. `--i-know-this-is-live` flag required to run
  `--apply` against the live `BRIDGE_HOME` (refused by default to
  prevent the demonstrated accident class — codex review of PR #296).
- `BRIDGE_MEMORY_LEGACY_PROBE` env var now gates the harvester's
  legacy `<home>/users/default/memory/<date>.md` read-only probe.
  Defaults to `1` for one release so partially-migrated installs
  don't see false-positive backfills; set to `0` after running
  `migrate-canonical --apply` everywhere. Probe removal target:
  v0.7.

### Fixed
- Daily-note canonical path is now unified at `<agent-home>/memory/<date>.md`
  for every user, including `default` (issue #220). Closes the
  `_daily_notes_base` split that PR #218 only papered over with a
  read-only legacy probe in the harvester. The actual writer
  (`bridge-memory.py daily-append`) has always taken no `user`
  argument and landed in `<home>/memory/`; the summarizer's `--user`
  flag previously redirected reads into a separate
  `<home>/users/<user>/memory/` tree that no writer ever populated,
  so split-brain symptoms (missed daily notes after PR #218 in
  rebuild-index, monthly cascades reading the wrong tree) are
  resolved by aligning the resolver. Multi-tenant
  `users/<user>/memory/` partitions remain an indexed escape hatch
  (`collect_index_documents` still walks them) but are no longer the
  bridge writer's target — see `docs/agent-runtime/memory-schema.md`.
- `bridge_linux_prepare_agent_isolation` now grants the queue-gateway
  agent directory + root the necessary ACLs (`--x` for the isolated UID,
  `r-x` + default ACL for the controller) so `bridge-queue-gateway.py
  serve-once`'s glob doesn't silently return empty when the root is
  `root:root 700` (PR #287, issue from operator). New
  `tests/isolation-queue-gateway-acl.sh` (Linux-only) covers isolate,
  cross-agent isolation, isolated-uid write access, serve-once
  consumption, and unisolate ACL strip. `bridge-state.sh diagnose acl`
  scanner reaches the new ACL paths without changes.
- Documentation-only update: `KNOWN_ISSUES.md` adds entry #11 closing
  historical issue #194 daemon-exit observability — the
  v0.6.15 hardening (#261/#262/#270/#273/#274/#279/#281/#289/#293/#292)
  subsumes every observability gap the original tracking issue named
  (PR #299).

## [0.6.15] — 2026-04-25

### Added
- `agb agent forget-session <agent>` clears persisted `AGENT_SESSION_ID`
  from all authoritative state files (active env, history env, optional
  linux-user overlay) under a per-agent lock (issue #268, PR #280).
  Idempotent: a second call exits with `already_forgotten` and no
  rewrite. Concurrent callers serialize via `flock` (with `mkdir`
  fallback for hosts without flock) so only one writer ever logs the
  cleared audit row. `bridge-start.sh` and `bridge-run.sh` now warn on
  `--no-continue` when a persisted id remains, and `agent show --json`
  surfaces a `session_source` field naming which file the active id
  came from. `--fresh --persist` one-shot recovery, tombstone for
  forgotten ids, and tmux duplicate-session race hardening are
  intentionally deferred to follow-up PRs per the spec round.
- "External Tool Latency and User Visibility" section in
  `docs/agent-runtime/common-instructions.md` (issue #271, PR #278).
  Six directive bullets: pre-call announcement on slow external calls,
  30s/2m/5m visibility tiers (status → escalation → assumed-failure),
  no `sleep` loops or silent polling, explicit "this will take a
  while" up-front for deliberate long jobs, user-reply-first as the
  first action of any post-failure turn. Triggering incident: a
  21-minute silent MCP wait that broke the user contract.

### Fixed
- Daemon main loop now wraps high-risk subprocess invocations in
  `bridge_with_timeout` (issue #265 proposal A, PR #279) and the
  same helper now wraps every `tmux send-keys` call site in
  `lib/bridge-tmux.sh` (PR #281). The original 34h hang documented
  in #265 was a `tmux send-keys` blocked on a closed Discord SSL
  pipe; PR #279 capped the daemon python sites first, PR #281
  closed the actual hang vector. Default 30s for daemon python
  sites (`BRIDGE_DAEMON_SUBPROCESS_TIMEOUT_SECONDS`) and 10s for
  tmux IPC (`BRIDGE_TMUX_SEND_TIMEOUT_SECONDS`). On 124/137 exit
  the helper writes a `daemon_subprocess_timeout` audit row tagged
  with the call-site label. Hosts without `timeout`/`gtimeout`
  fall back to running unwrapped after a one-time
  `daemon_subprocess_timeout_unavailable` warn.
- Closed PR #239's 14-bullet bundle has been re-landed as eight
  scope-isolated PRs after the original umbrella PR cycled through
  CLAUDE.md's three-round limit. The split shipped in five waves
  using the new wave-style operator pattern (parallel
  `upstream-issue-fixer` dispatch + `codex:codex-rescue` review).
  Bullet 6 (broken-launch state file from circuit breaker) was
  already in #262; bullet 9 was a duplicate of bullet 1. The
  remaining bullets landed as:
  - PR #282 — smoke fixture hardening: fake `claude` binary in
    isolated smoke PATH so init preflight does not depend on a real
    Claude install, bootstrap smoke pinned to `--shell zsh
    --skip-systemd`, daemon side-work reduced by default with
    per-block re-enables, plugin liveness cooldown / watchdog
    dedupe / admin manual-stop fixture stabilizations (PR #239
    bullets 3 + 4 + 11 partial + 13 partial).
  - PR #284 — `agent-bridge audit` reads `BRIDGE_AUDIT_LOG`
    instead of hard-coding `$BRIDGE_HOME/logs/audit.jsonl`, and
    auto-memory seeding is allowed when both `BRIDGE_HOME` and
    the target settings path are ephemeral (bullets 1 + 2).
  - PR #285 — Claude resume smoke fixtures explicit for realpath
    and stale-session cases (no longer silently passing on a
    missing-channel launch path), and `bridge_watchdog_problem_key`
    strips volatile `heartbeat_age_seconds` from the dedupe hash
    while keeping `heartbeat_present` and drift fields (bullets
    10 + 14).
  - PR #286 — upgrade dry-run restart analysis sources `bridge-lib.sh`
    from `SOURCE_ROOT` instead of assuming the target `BRIDGE_HOME`
    contains it; large upgrade JSON payloads route through a temp
    file instead of process argv (avoiding Linux `Argument list
    too long`); restart-analysis subshell scrubs caller-side
    `BRIDGE_*` exports so `--target <fresh-temp-home> --dry-run`
    reports the target's roster (`considered=0`), not the live
    caller's (bullets 7 + 8 + r2 env isolation).
  - PR #288 — `runtime/credentials` and `runtime/secrets` are
    secured to `0700`/`0600` after canonical template overlay so
    repo-managed credential templates do not inherit `0644` and
    leak (bullet 12).
  - PR #289 — `process_channel_health` and `process_usage_monitor`
    in `bridge-daemon.sh` now honour
    `BRIDGE_CHANNEL_HEALTH_ENABLED` / `BRIDGE_USAGE_MONITOR_ENABLED`
    env gates so PR #282's smoke env exports are no longer silently
    dead (bullet 11 daemon side).
  - PR #290 — restored safe-mode launch helpers
    (`bridge_build_safe_claude_launch_cmd`,
    `bridge_safe_mode_resume_mode`, `bridge_build_safe_launch_cmd`)
    so `bridge-run.sh --safe-mode` (already wired up) can build
    minimal Claude launches without channel flags; smoke fixture
    clears the admin manual-stop overlay before the admin crash
    daemon-sync block so the upgrade-restart fixture's bulk
    manual-stop does not silently disable admin alerting
    (bullets 5 + 13).

## [0.6.14] — 2026-04-25

### Fixed
- `bridge-stall.py` no longer self-loops on the agent's own narration
  of a past provider error (issue #264, PR #270, three rounds). The
  classifier had matched `PATTERN_GROUPS` regexes inside
  `looks_like_agent_output`, treating any agent reply containing
  `429` / `rate limit` / `timeout` as agent UI and re-firing a fresh
  stall against the agent's own text every daemon tick. r1 collapsed
  the loop but regressed glyph-less raw provider errors arriving
  immediately after an `[Agent Bridge]` nudge; r2 restored that
  capture path; r3 added the `join` mode to the stall-side
  `bridge_capture_recent` call so `tmux capture-pane` runs with `-J`
  and a long agent reply does not wrap into a glyph-less continuation
  line that classify mistakes for raw provider output.
  `AGENT_GLYPH_PREFIXES` documents the Claude UI markers that the
  layered classify-pass excludes (`❯`, `>`, `›`, `⏺`, `⎿`, `✢`, `✻`,
  `✱`, `ℹ`, `✓`, `✗`).
- `bridge-queue.py` cron-dispatch dedup now preserves fresh and
  pre-fire sibling slots so high-frequency crons survive worker-pool
  backlog (issue #266, PR #275). The previous dedup cancelled every
  non-newest open slot regardless of whether the newest had been
  fired; under recovery from a daemon hang, every fresh slot was
  superseded by the next before any worker could claim it
  (`cs-line-poll-5m` ran zero successful fires across 144 slots in
  36h). Two layered guards: a grace window
  (`BRIDGE_CRON_SUPERSEDE_GRACE_SECONDS`, default 60s) preserves
  unclaimed siblings while they may still get picked up, and a
  newest-not-fired guard preserves all unclaimed siblings while the
  newest itself is still queued. Claimed-but-not-newest siblings are
  still cancelled (genuine duplicate work). Normal operation is
  unchanged because newest fires quickly and the guards stay
  inactive.
- `bridge-daemon.sh stop` now sweeps every own-user
  `bridge-daemon.sh run` process, not just the PID recorded in
  `BRIDGE_DAEMON_PID_FILE` (issue #269, PR #273, two rounds). An
  earlier daemon that lost its pid-file (install moved paths,
  `bridge-daemon.sh run` invoked manually for diagnostics, orphan
  re-parented to PPID=1) survived stop + systemd's
  `Restart=always` and ran concurrently with the systemd-managed
  daemon, silently ignoring later env drop-ins like
  `BRIDGE_SKIP_PLUGIN_LIVENESS=1`. The new helper
  `bridge_daemon_all_pids` matches own-user processes by cmdline
  (path-agnostic, scoped to `pgrep -U "$(id -u)"` so other users on
  the same host are never touched), excludes the caller's own PID,
  and is overridable via `BRIDGE_DAEMON_STOP_PATTERN` for isolated
  tests. `cmd_stop` audits `killed_count`, `failed_count`,
  `orphan_count`, and `recorded_pid` so after-the-fact inspection can
  tell sweeping cycles from clean stops.

### Added
- Periodic `daemon_tick` audit event so a hung daemon main loop is
  externally observable (issue #265 partial, PR #274, proposal B
  only). The previous daemon kept emitting "alive" to launchctl and
  `agent-bridge status` while the bash main loop was wedged at
  `__wait4` for 34 hours after a `tmux send-keys` blocked on a
  closed Discord SSL pipe — every observable health check stayed
  green and audit went silent. The daemon now writes a
  `daemon_tick` audit row at the end of each completed sync cycle,
  throttled by `BRIDGE_DAEMON_HEARTBEAT_SECONDS` (default 60s,
  ~1.4k lines/day; set to 0 to disable). Detail fields surface
  `loop_step` (the value of `BRIDGE_DAEMON_LAST_STEP` when the tick
  fired), `interval_seconds`, and `heartbeat_interval_seconds` so
  operators and a future audit-silence supervisor can pinpoint
  which loop step the daemon was in immediately before going
  silent. Followups for proposals A (per-call `timeout`s on every
  external invocation), C (sibling supervisor that restarts the
  daemon on audit silence), and D (launchd liveness watcher on a
  heartbeat file) are tracked separately on issue #265.

## [0.6.13] — 2026-04-25

### Changed
- Upgrade restart summary labels renamed from `would_restart` /
  `restarted` / `would_restart_agents` / `restarted_agents` to
  `restart_eligible` / `restart_attempted_ok` and the matching
  `_agents` pairs (issue #257, PR #259). The prior names
  over-promised at both layers — dry-run predicted eligibility
  (not success), apply recorded a `bridge-agent.sh restart` exit-0
  count (not agent health). `agent-bridge upgrade --dry-run` now
  additionally prints an `agent_restart_note` disclaimer reminding
  operators that runtime failures (plugin resolution, settings
  corruption, dependency outages) only surface at apply. This is a
  small JSON-key breaking change for any external consumer of the
  `agent_restart` payload; in-tree consumers (smoke) are updated in
  the same release.

### Fixed
- `hooks/tool-policy.py::protected_alias_reason` no longer
  substring-matches the queue DB and roster filenames across the
  entire Bash command text (issue #252, PR #260). The prior check
  blocked any invocation whose body merely mentioned the suffix —
  `gh issue comment --body "…state/tasks.db…"`,
  `git commit -m "…roster file…"`, `rg '…state/tasks.db' docs/`,
  even the description of the bug report itself. The rewrite
  `shlex.split`s the command, skips message-body option flags
  (`--body` / `-m` / `--message` / `--title` / `--description` /
  `--notes` / `--subject`), routes file-valued flags
  (`--body-file` / `-F` / `--file` / `--input`) through the same
  path comparison positional tokens use, splits each token on
  shell control operators (`;` / `&&` / `||` / `|` / `&` /
  newline) and peels a single redirection prefix (`<` / `>` /
  `>>` / `2>` / `&>`), then expands `~` / `$VAR` before the
  `Path ==` check. `sqlite3 <abs>/state/tasks.db`,
  `sqlite3 "$BRIDGE_HOME"/state/tasks.db`, `cat <abs roster>`,
  and `git commit -F <abs roster>` still block with the intended
  reasons; incidental suffix mentions pass through.
- `bridge-upgrade.sh` now surfaces per-agent restart-failure
  diagnostics on the apply summary (issue #256 Gap 1, PR #261).
  The restart report tuple grew from 5 to 7 columns to carry the
  failing `bridge-agent.sh restart` exit code and the agent's
  most recent `.err.log` tail (or `.log` tail when `.err.log`
  is empty — the silent-exit common case). The JSON payload's
  `agent_restart` object now includes a `failed_details` list
  with `{agent, exit_code, last_log_tail}` entries, and the
  text summary prints one
  `agent_restart_failed_detail_<agent>: exit=<N> tail=<flat>`
  line per failure. The aggregator tolerates older 5-column
  tuples so a half-upgraded host does not crash the parser, and
  a PEP 604 `str | None` annotation slipped into r1 was fixed
  in r2 (Python 3.9.6 compatibility).
- `bridge_daemon_autostart_allowed` now honours the broken-launch
  quarantine marker and stops relaunching an agent whose
  `bridge-run.sh` rapid-fail circuit breaker has tripped (issue
  #256 Gap 2, PR #262). The missing
  `bridge_agent_write_broken_launch_state` writer (called from
  `bridge-run.sh:512` since the circuit breaker landed but never
  defined anywhere in the tree) is now present in
  `lib/bridge-state.sh`, so the marker is actually written on
  trip. Matching `bridge_agent_clear_broken_launch` helper is
  wired onto the `agent-bridge agent start` / `safe-mode` /
  `restart` entry points, guarded behind the dry-run
  short-circuit and restart preflight so an inspection or a
  pre-launch failure does not silently unquarantine the agent.
  Root cause of the 137-relaunch-in-2h13m #254 repro on the
  reference host.

## [0.6.12] — 2026-04-25

### Fixed
- `scripts/apply-channel-policy.sh` no longer silently disables the
  singleton channel plugins for non-admin agents that explicitly own
  them via `BRIDGE_AGENT_CHANNELS["<agent>"]="plugin:…"` in the roster
  (issue #254, PR #255). The v0.6.11 admin-bypass overlay assumed the
  admin agent was the sole router for every singleton channel, but
  multi-persona deployments (e.g. `dev` owns discord while `dev_mun`
  owns telegram) had their owning agent's plugin blanket-disabled —
  claude silently exited during plugin resolution and the agent
  entered a restart loop. The script now walks every reachable roster
  file, parses `BRIDGE_AGENT_CHANNELS` entries (including dotted agent
  ids like `foo.bar`), and writes a per-agent
  `.claude/settings.local.json` that selectively re-enables only the
  singleton plugins each agent actually owns. Admin retains the
  existing full re-enable. When two or more agents declare the same
  singleton plugin, a `WARNING: '<plugin>' declared by multiple
  agents (…)` line is emitted on stderr — the upstream bot API still
  enforces one-connection-per-token, so "most recently restarted
  wins" is surfaced instead of both agents silently failing. A bash
  4+ self-exec guard identical to `bridge-lib.sh` now protects the
  script from macOS's default `/bin/bash` 3.2, and an admin grep that
  previously aborted under `set -euo pipefail` when the roster had no
  `BRIDGE_ADMIN_AGENT_ID` line is now tolerant of that shape.

## [0.6.11] — 2026-04-25

### Fixed
- `bootstrap-memory-system.sh` no longer aborts on macOS installs with
  hyphenated or dot-named agent ids (queue task #886, PR #250). Two
  regressions introduced in 0.6.10 are addressed together: (a) the
  script now re-execs under Bash 4+ when picked up by macOS's default
  `/bin/bash` 3.2 (mirrors the guard in `bridge-lib.sh`), and (b)
  `memory_daily_gate_on` normalises every character outside the bash
  identifier alphabet to `_` before building the
  `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>` env lookup, so agents
  like `agb-dev-claude` and `foo.bar` no longer trip `invalid variable
  name` during indirect expansion. Operators overriding the env must
  use the underscore-normalised key; the roster-level associative
  array form (`BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0`) is
  unchanged.
- `scripts/apply-channel-policy.sh` now writes a per-agent local
  overlay at `agents/<admin>/.claude/settings.local.json` that
  re-enables `telegram@claude-plugins-official` /
  `discord@claude-plugins-official` for the configured admin agent
  (issue #244, PR #246). Claude Code's settings merge order prefers
  `.claude/settings.local.json` over the shared-effective
  `.claude/settings.json` symlink, so the admin keeps the router role
  while every other agent stops contending on the bot tokens. Admin
  id is resolved only from an explicit signal (env
  `BRIDGE_ADMIN_AGENT_ID` or a roster-file grep) and is a no-op when
  the admin home does not yet exist, keeping the bypass safe on
  smoke fixtures and pre-bootstrap hosts.

## [0.6.10] — 2026-04-24

### Fixed
- `hooks/tool-policy.py::other_agent_homes` no longer classifies the
  `agents/shared` symlink (or `.claude` / `_template` siblings) as
  peer agent homes (issue #240, PR #242). Every Claude-authored Write
  to `$BRIDGE_SHARED_DIR` on 0.6.9 was being rejected with
  `cross-agent access is blocked: shared` because `path.resolve()`
  collapsed the alias onto the real shared tree. The filter is now an
  exact-name allowlist (`shared`, `_template`, `.claude`) — no
  prefix/symlink heuristic — so agents whose names legitimately start
  with `_` or `.` (e.g. `_real_agent_name`, `.real_dot_agent`) keep
  their cross-agent isolation.

## [0.6.9] — 2026-04-24

### Added
- `agent-bridge diagnose acl [--json]` scanner (issue #233 stage 3,
  PR #237): a read-only sweep over `/`, `/home`, the controller's
  home, `BRIDGE_HOME`, `BRIDGE_AGENT_HOME_ROOT`, and `BRIDGE_STATE_DIR`
  that flags named-user ACL entries left behind by earlier
  isolate/unisolate cycles. Distinguishes access vs. default ACL
  entries and prints the exact `setfacl -x` command to drain each
  one. Linux-only; non-Linux hosts and hosts without `getfacl` exit 0
  with a benign banner. `--json` mode emits
  `{"platform":..., "controller":..., "findings":[…]}` for machine
  consumption.
- Restored `next-session.md` auto-expiry helpers in
  `lib/bridge-state.sh` (issue #228, PR #229):
  `bridge_path_age_seconds`, `bridge_agent_next_session_digest`,
  `bridge_agent_next_session_is_delivered`,
  `bridge_agent_next_session_age_seconds`,
  `bridge_agent_clear_next_session_state`, and
  `bridge_agent_maybe_expire_next_session`. All six were lost during
  commit 7bf4e7d's lib trim; `bridge-run.sh:237` still referenced the
  last one and printed `command not found` on every Claude-engine
  launch. Restored verbatim (with the marker path routed through the
  current `bridge_agent_next_session_marker_file`
  `runtime_state_dir/next-session.sha` convention).
- SessionStart hook persists the NEXT-SESSION.md digest (PR #229):
  `hooks/bridge_hook_common.py::_stamp_next_session_delivered` now
  writes `sha1(content.rstrip(b"\n"))` to the per-agent marker path
  when `bootstrap_artifact_context` surfaces a handoff. The hook
  honours `BRIDGE_ACTIVE_AGENT_DIR` so deployments with a rerooted
  active-agent dir (e.g. linux-user isolation) land the marker where
  the bash reader actually looks. Closes the auto-expiry loop that
  was introduced in 1e75c0c but silently broken since 7bf4e7d.

### Fixed
- `scripts/*.sh` executable bit preserved across `agent-bridge upgrade`
  (issue #222, PR #225): `bridge-upgrade.py` now trusts the git
  index mode, not the checkout's filesystem mode, so a dev worktree
  with drifted permissions no longer propagates wrong modes
  downstream. A new `mode_drift` classification + `sync_mode` action
  repairs byte-identical live files whose exec bit went missing.
  `bootstrap-memory-system.sh::bootstrap_install_scripts` repairs the
  same drift defensively. `scripts/install-daemon-launchagent.sh` and
  `scripts/oss-preflight.sh` promoted to git mode 100755.
- Bun plugin orphan accumulation across agent restarts (issue #223,
  PR #226): `bridge-mcp-cleanup.py` DEFAULT_PATTERNS now matches the
  plugin root itself —
  `bun run --cwd .../.agent-bridge/plugins/` and
  `bun run --cwd .../claude-plugins-official/` — so
  `is_orphan_candidate`'s parent-chain check can classify the
  `bun server.ts` child as an orphan when it is reparented to PID 1.
  Non-greedy regex tolerates whitespace-bearing home directories.
- Admin-inbox alert fatigue (issue #230, PR #231):
  - `process_context_pressure_reports` only emits on severity-bucket
    transitions; a sustained warning/info bucket no longer re-broadcasts
    every 30 minutes. `critical` still uses the legacy cooldown
    rebroadcast because it's an ongoing emergency worth pinging on.
  - `dispatch_cron_work` gates `[cron-followup]` tasks behind a
    consecutive-failure counter keyed on `CRON_FAMILY`. Default
    threshold 3 (configurable via
    `BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD`); counter resets on
    success or after a burst-triggered create. File update is
    `flock`-serialised on hosts that ship flock.
  - `process_crash_reports` skips manual-stop-armed agents entirely —
    no more `crash_loop_report mode=refresh` audits on an
    intentionally-offline agent.
- `bridge-run.sh` no longer prints
  `bridge_agent_maybe_expire_next_session: command not found` on every
  Claude-engine launch (issue #228, PR #229). See **Added** for the
  helpers and the SessionStart writer that completes the feature.
- Linux-user isolation no longer poisons `/` and `/home` with
  named-user ACL entries (issue #233, PRs #235/#236/#237):
  - Stage 1 (PR #235, `lib/bridge-migration.sh`): `unisolate` now
    strips `u:<os_user>` and `u:<controller>` named-user entries
    (access + default) from the shallow paths isolate is known to
    touch (`/`, `/home`, controller home, isolated home, BRIDGE_HOME,
    BRIDGE_AGENT_HOME_ROOT, memory-daily root + shared) and removes
    `u:<os_user>` recursively from agent-scoped trees including
    hooks/shared/runtime/lib/plugins/scripts/.claude, `memory-daily/
    <agent>`, `memory-daily/shared/aggregate`, and the root helper
    files (`agent-bridge`, `agb`, `VERSION`, `bridge-*.sh`,
    `bridge-*.py`). Default-ACL directories are swept with
    `find -type d -exec setfacl -d -x`.
  - Stage 2 (PR #236, `lib/bridge-agents.sh`, `lib/bridge-cron.sh`):
    `bridge_linux_grant_traverse_chain` now requires an explicit
    `stop_path`; `/` and empty strings warn + skip. A new
    `bridge_linux_traverse_stop_for` helper returns the controller's
    home when the target is under it, empty for system paths. Every
    call site passes a controller-scoped stop — no more walking to
    `/`. The `bridge_linux_grant_traverse_chain "$controller_user"
    "$isolated_claude_dir"` call that tagged `/` and `/home` with the
    operator UID is gone; replaced by scoped grants on
    `$user_home` + `$isolated_claude_dir` only.
  - Stage 3 (PR #237, `bridge-diagnose.sh`): `agent-bridge diagnose
    acl` scanner (see **Added**) lets operators audit shared roots
    for any lingering residue without running `unisolate`.
- Hook queue CLI no longer FileNotFoundErrors when a dynamic agent
  has no default home (PR #232, Sean Oh / SYRS-AI):
  `hooks/bridge_hook_common.py::queue_cli` routes through a new
  `queue_cli_cwd()` fallback chain
  (`BRIDGE_AGENT_WORKDIR` → `agent_default_home` → `cwd` →
  `bridge_script_dir` → `/`). Artifact lookup still uses
  `current_agent_workdir()` so handoff paths aren't affected. Smoke
  adds a `CODEX_DYNAMIC_NO_HOME_AGENT` regression asserting the hook
  exits 0 with valid Codex JSON and doesn't auto-create the missing
  home.

## [0.6.8] — 2026-04-23

### Added
- linux-user isolation ACL contract expansion for memory-daily
  (issue #219):
  - `bridge_linux_prepare_agent_isolation` grants the isolated `os_user`
    `r-x` on `state/memory-daily/` (traverse only), `rwX` on
    `state/memory-daily/<agent>/` (per-agent manifest tree), and `rwX`
    on `state/memory-daily/shared/aggregate/` (shared aggregate files).
  - Legacy root-level `admin-aggregate-*.json` files migrate into
    `shared/aggregate/` during isolation prep (sudo-root `mv`) and
    during `bootstrap-memory-system.sh --apply` (controller `mv`).
  - `bridge_cron_run_dir_grant_isolation` (`lib/bridge-cron.sh`) grants
    the target `os_user` rwX on the per-run cron dir just before queue
    task creation. The grant is **best-effort**: memory-daily runs as
    the controller UID under v1.3 and does not need the isolated UID to
    own the run dir, so failure is ignored by the default caller. Other
    callers that rely on the grant can branch on the return code.
- `scripts/memory-daily-harvest.sh` under linux-user isolation stays in
  controller UID and passes `--transcripts-home=<target_home>` so
  `_scan_transcripts` reads the isolated user's `~/.claude/projects/`
  via the new controller r-X ACL. No `sudo` re-exec — that preserves
  the harvester's access to the controller-owned queue DB (read
  `task_events`, dedupe `_task_status`, write backfill tasks via
  `bridge-task.sh create`). When `<target_home>/.claude/projects/` is
  not readable (fresh agent before first session, or ACL not yet
  re-applied), the stub falls back to `--skipped-permission --os-user`
  for a structured skip + admin aggregate notify.
- `bridge_linux_prepare_agent_isolation` grants the controller `r-X`
  on the isolated user's `~/.claude/` + `~/.claude/projects/` (plus a
  default ACL so a future `projects/` inherits). This is the single
  cross-UID read lens; no write grant.
- `bridge_migration_sudoers_entry` is now `NOPASSWD: SETENV: tmux, bash`
  (adds the `SETENV:` tag used by `bridge-start.sh` launch path for
  env-preserving sudo exec). `bridge_linux_can_sudo_to` switches its
  probe from `sudo -n -u <os_user> true` to
  `sudo -n -u <os_user> -- <bash> -c 'exit 0'` so the probe matches
  the entry (otherwise already-isolated installs would fall back to
  shared-mode launch after upgrade).
- `agent-bridge isolate <agent> --reapply` — idempotent re-install of
  per-agent ACLs without re-running ownership migration. Required to
  pick up ACL-contract changes on already-isolated installs.
- Cron dispatch ordering reshuffle in `bridge-cron.sh::dispatch_cron_run`:
  run_dir artifacts (`request.json` / `status.json` / `manifest.json`)
  + per-run ACL grant are now written **before** the queue task is
  created. `dispatch_task_id` / `task_id` are seeded with sentinel
  `0` and atomically rewritten to the real queue id via new helpers
  `bridge_cron_update_request_task_id` / `bridge_cron_update_manifest_task_id`.
  The `already_enqueued` short-circuit now validates that the existing
  request carries a positive `dispatch_task_id` — a stranded run from
  a prior failed queue-create step is cleaned and re-enqueued instead
  of being skipped forever. `bridge_cron_run_dir_grant_isolation` is
  best-effort (non-fatal) under v1.3: memory-daily now runs as the
  controller UID so the grant is no longer load-bearing, and hosts
  without passwordless root sudo must not block dispatch because of
  an ACL the harvester does not need. Other families that spawn
  isolated subprocesses can still benefit from the grant when ACL
  infrastructure is available.
- Docs: `docs/agent-runtime/memory-daily-harvest.md` §10 rewritten;
  new `docs/handoff/219-linux-isolation-e2e.md` (Linux server admin
  patch E2E runbook).
- Smoke additions: scenario 9 (shared/aggregate path), scenario 14
  (stub isolation + readable `.claude/projects` → `--transcripts-home`
  dispatch, no sudo), scenario 15 (unreadable target → structured
  `--skipped-permission` fallback). Total 10/10 PASS on macOS mock.

### Changed
- Python harvester writes aggregate state under
  `state/memory-daily/shared/aggregate/` rather than the memory-daily
  root. Controller-context migration ensures backward compatibility
  with existing installs.

### Notes
- macOS hosts have no linux-user isolation path; behaviour unchanged.
- Full linux E2E validation runs on the user's Linux server (see the
  handoff doc). macOS CI covers mock-level branch logic only.

Fixes #219

## [0.6.7] — 2026-04-23

### Added
- `memory-daily-<agent>` per-agent cron, autoregistered by
  `bootstrap-memory-system.sh` for every active Claude agent whose refresh
  gate is on. Schedule `0 3 * * *` (Asia/Seoul). Disabling the gate on a
  subsequent `--apply` deletes the stale cron.
- `bridge-memory.py harvest-daily` subcommand — detection-only reconcile
  kicker with manifest schema v1, state machine
  (`checked / queued / resolved / skipped-permission / disabled / escalated`),
  semantic-empty parser, source-confidence tiering (strong / medium / weak),
  legacy-path probe, `(agent, date)` dedupe, 24h cooldown, and
  attempts>3 escalation. Aggregate state
  (`state/memory-daily/admin-aggregate-skip.json`,
  `admin-aggregate-escalated.json`) merged with `fcntl.flock`. New
  `--skipped-permission` / `--os-user` flags wire the
  skipped-permission branch (minimal manifest + permission aggregate
  merge), and `--transcripts-home` overrides the base for
  `~/.claude/projects` scanning (used by the stub's sudo wrap and by
  smoke fixtures).
- `scripts/memory-daily-harvest.sh` — cron payload stub. Parses
  `agent show --json` so workdir / profile-home / isolation.mode /
  isolation.os_user each survive whitespace-bearing paths (per-field
  python3 parse). Derives the sidecar path from `CRON_REQUEST_DIR`
  (runner-exported) with a fallback under
  `state/memory-daily/<agent>/adhoc.authoritative.json` for manual
  invocation. Under `linux-user` isolation with a user mismatch, the
  stub forwards `--skipped-permission --os-user <user>` so the Python
  harvester writes `state=skipped-permission` and merges `(agent, date)`
  into `admin-aggregate-skip.json`. (A sudo re-exec is deliberately not
  used: the isolated UID cannot write the controller-owned cron/state
  trees until `bridge_linux_prepare_agent_isolation` grants those paths
  — tracked separately.)
- Runner-level authoritative sidecar enforcement for the `memory-daily`
  family in `bridge-cron-runner.py`. Sidecar is the preferred source in the
  normal path and in the parse-exception recovery path, with
  `child_result_source` and `sidecar_error_note` audit fields in
  `result.json`.
- Daemon refresh gating in `bridge-daemon.sh` — `session_refresh_queued` is
  emitted only when `actions_taken` contains `queue-backfill`; otherwise
  `session_refresh_skipped` is emitted with
  `reason=no_queue_backfill_action`. `process_memory_daily_refresh_requests`
  clears stuck pending refresh state ahead of the disabled-gate skip
  (`session_refresh_pending_cleared`, `reason=gate_off`).
- `lib/bridge-cron.sh::bridge_cron_actions_taken_contains` helper.
- Docs: `docs/agent-runtime/memory-daily-harvest.md`.
- Smoke: `tests/memory-daily-harvest/smoke.sh` covering scenarios 2, 4, 8,
  9 (skipped-permission writes manifest + aggregate), 10, residual-risk
  sidecar recovery (11), stub isolation-mismatch dispatch (12), and
  stub default-path dispatch (13).

### Changed
- `bridge-cron-runner.py`: `run_codex` and `run_claude` signatures accept an
  optional `request_file` so the runner can export `CRON_REQUEST_DIR` to the
  child process environment.
- `bridge-daemon.sh` cron worker completion path now gates the memory-daily
  session-refresh on `actions_taken`.

### Notes
- Canonical `users/default/memory` path alignment is tracked separately. This
  release probes the legacy path read-only to suppress false-positive
  backfills.
- Session `/wrap-up` remains the primary daily-note writer and is out of
  scope here.

Fixes #216
