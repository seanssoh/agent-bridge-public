# Changelog

All notable changes to Agent Bridge are documented here. This project adheres
loosely to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and tracks
version bumps via the `VERSION` file.

## [Unreleased]

## [0.16.0-beta2] — 2026-06-04

A **beta hotfix** on `0.16.0-beta1` — fixes a launch-blocking isolation bug (#1513) surfaced during beta1 Linux validation, so a freshly-provisioned isolated agent with a `plugin:teams` channel starts correctly. Same `agb upgrade` path; no schema/contract change vs beta1.

### Fixed

- **Isolated `plugin:teams` agent aborts at launch on a 0700 legacy mirror (#1513, via #1514).** A sibling facet of #1506/#1508 on the tree that fix did not cover. `bridge-run.sh` runs the legacy Teams-MCP prune **as the iso user** against the legacy `$BRIDGE_AGENT_HOME_ROOT/<a>` mirror; on a freshly-created isolated agent that mirror dir was scaffolded `0700` (controller umask), so the iso user can't traverse it and `Path.is_file()` raises `EACCES` — which Python 3.10's `is_file()` does **not** swallow — crashing the prune with an uncaught traceback that `bridge-run.sh` hardened into `aborting launch: stale Teams MCP cleanup failed` (the webhook port never binds). Two-layer fix: **(1)** `prune-legacy-teams-mcp.py::prune_file()` now catches the existence-probe `OSError` and returns a non-fatal `skipped … reason=stat-failed:<errno>` (a prune helper that can't *read* a stale-entry candidate must never abort a launch; genuine prune-action failures still fail loud); **(2)** the isolate path (`bridge_linux_prepare_agent_isolation`, beside the #1506 normalization) now sets the "other" traverse bit on the legacy mirror **dir** (`0755` dir only — inner `0600` files and owner/group untouched), covering both `create --isolate` and `isolate`/`--reapply`. Linux iso v2 only.

## [0.16.0-beta1] — 2026-06-04

A **beta** introducing **A2A Rooms** — a new room / leader (방장) / join-on-approval model that unifies internal-team messaging and cross-bridge A2A under one membership boundary, replacing all-to-all internal A2A and the N²-edge external pairing. Shipped on a beta tag for live testing; this cut lands the **single-node** foundation (control plane + iso-enforced ACL). Also lands the **#1497 HOME/path SSOT** (Phase 1+2) and the **#1506 isolate group/mode normalization** fix. Every item is codex pair-reviewed; the A2A security boundary went through multiple adversarial review rounds (the iso-actor trust model is the load-bearing piece).

### Added

- **A2A Rooms — control plane (BETA) (#1505, A2A rooms P1a).** A new `rooms.db` membership store + `agb room` CLI (`create` / `list` / `show` / `invite` / `rotate-invite` / `join` / `approve` / `deny` / `kick` / `leave` / `adopt-all`). A room has a leader (방장); agents join by an invite link (token stored as `sha256` only) and are admitted on leader approval; membership changes bump a monotonic per-room `epoch` and re-persist a canonical sorted roster. The message envelope gains optional `room_id`/`room_epoch` (v1 back-compat), and the cross-bridge receiver gains a fail-closed `room_scoped_check` seam. **Leader/controller authorization is OS-enforced**: the acting agent is derived from the process OS user (`pwd.getpwuid(os.getuid())`) compared to the leader's expected OS user — never a client-supplied `--from`/`BRIDGE_AGENT_ID` — and the operator/controller bypass is anchored to the owner of the real `rooms.db` (a managed iso agent can't own it). Shared-mode (single UID) is advisory by design. Single-node, contract-freezing: the multi-node transport (Tailscale | Cloudflare Zero Trust), node-to-node bootstrap bundle, and cross-node roster broadcast + relay land in subsequent betas. Design: `docs/design/a2a-rooms-design.md`.
- **A2A Rooms — internal-queue ACL enforcement (BETA) (#1510, A2A rooms P1b).** A new `rooms_acl` mode (default **off** → zero behavior change): when set to `enforce`, an inter-agent durable queue message is allowed only when sender and recipient **share a room**. The enforcement actor is the **OS-enforced** identity — the queue gateway derives it from the request-file owner uid (file transport) or `SO_PEERCRED` (socket transport), never a client-supplied `--from`/`BRIDGE_AGENT_ID`. The gateway-child trust is anchored to the owner of the **real task DB** the create writes (`os.stat(get_db_path()).st_uid`): the gateway runs as the controller and spawns the queue child with no uid drop, so a genuine child owns the controller's task DB, while a direct managed agent can't chown it → falls to its real OS identity. The membership check reads the rooms.db **canonically co-located with that task DB**, never a caller-redirectable `BRIDGE_A2A_ROOMS_DB`, so no fake-rooms/real-task mix is possible. Minimal, non-spoofable exemptions (controller/daemon/cron/receiver by OS uid, self-message, target-in-no-room). `agb room adopt-all` provides the migration so enabling `enforce` strands no existing agent. Fail-closed under `enforce`; shared-mode advisory.

### Changed

- **#1497 HOME/path SSOT — Phase 1 + 2 (#1504, #1507).** Phase 1 closes the per-**agent** home channel: `bridge-run.sh` exports a distinctly-named `BRIDGE_AGENT_HOME_RESOLVED` (the v2-aware identity home) on both launch and roster-refresh, `agent show --json` emits a resolver-derived `agent_home`, and the Python hook layer consumes the resolved scalar → v2 → roster-CLI → legacy (no stale-legacy short-circuit beating v2). Phase 2 consolidates the **operator**-home resolver: a single canonical `lib/operator_home.py::operator_home()` replaces four duplicated `bridge_home_dir()` implementations + six inline resolvers in `bridge-queue.py`, byte-identical for set/unset `BRIDGE_HOME`; the consumers load it by its exact co-located file path (importlib), so no same-named module on `sys.path` can shadow the queue-DB/home resolution.

### Fixed

- **`isolate` left pre-existing profile files at `0600`/`group=controller` (#1506, via #1508).** On the create→isolate path, `agent-bridge isolate` `chown`-ed the existing tree to the agent OS user but never normalized group+mode, so scaffolded profile files kept `group=<controller>`/`0600` instead of the iso v2 contract (`group ab-agent-<a>`, dirs `2770` setgid, files `0660`) — leaving the controller/watchdog unable to read them and emitting a high-pri `scan_error` false-positive. The shared `bridge_linux_prepare_agent_isolation` path now normalizes the existing home/workdir/runtime/logs tree right after the chown via the existing exec-bit-preserving, symlink-safe, idempotent, Linux-only helper, with the v3 channel-state dirs excluded so `.env` channel secrets stay owner-only `0600`.

### Internal / CI

- **`beta5-2-kappa-state-audit-reconcile` T1.c flake filed (#1509).** The smoke's awk-range read of `bridge-state.sh` is non-hermetic and intermittently false-reds `unit/static smoke`; tracked for a hermetic fix.

## [0.15.4] — 2026-06-03

A new-items wave on top of `0.15.3` — eleven fixes triaged from upstream issues/PRs, every item codex pair-reviewed and CI-green (syntax + unit/static + oss-preflight + lint-heredoc-ban + lint + integration smoke). The marquee items are the **invalid `PermissionDenied` hook-key fix** (current Claude Code rejects it and skips the *entire* settings.json → plugins/MCP/channel bots silently offline), the **v2-split handoff delivery fix** (the Python hook layer was v2-blind, so `NEXT-SESSION.md` was silently dropped on v2-split installs), the **usage-endpoint-429-as-rotation-signal** (credential roadmap Phase 0), and the **bridge-lib re-exec secret hardening** (credential Phase-0 security gate).

### Security

- **bridge-lib.sh Bash 3.2→4 re-exec hardening (#1454, via #1491).** Hardens the Bash 3.2→4 re-exec so caller-controlled code — a shadowed `source`/`builtin`/function or a `PATH`/startup-file shadow — cannot execute during the window where the inherited environment is still present (the path a malicious shadow would have used to capture the operator's ambient secret). New `lib/bridge-secret-scrub.sh` primitive + a builtin `${BASH_SOURCE[0]%/*}` script-dir + privileged `exec -p`. The threat model is explicitly bounded (operator-approved): the operator's ambient secret env is **inherited by design** (the bridge does not scrub the launch environment), and an inherited `SHELLOPTS=xtrace`+`PS4`, initial-shell `BASH_ENV`, or an invoking-shell `DEBUG` trap all fire before the script's first line — so they are an out-of-scope launch-env-control boundary (consistent with #1443), stated across all three contract surfaces.

### Fixed

- **Invalid `PermissionDenied` hook key skips the whole settings.json (#1495, via #1499).** Current Claude Code rejects a top-level `PermissionDenied` hooks key with `Invalid key in record` and **skips the entire file** — so `enabledPlugins`, `skipDangerousModePermissionPrompt`, every setting is ignored, taking plugins/MCP servers and channel bots offline. The legacy block shipped in the tracked base `agents/.claude/settings.json` (since #93) and `merge_settings` preserved it across every re-render. Removed from the base, and the render/migration now prunes any `hooks.<event>` outside the **complete bridge-managed event allowlist** (warns to stderr, stdout stays pure JSON) — so the prune strips the legacy key while preserving every event the bridge itself wires (PreToolUse/PostToolUse/PostToolUseFailure/UserPromptSubmit/Notification/Stop/SubagentStart/SubagentStop/PreCompact/PostCompact/PermissionRequest/SessionStart/SessionEnd).
- **v2-split handoff silently dropped (#1497, via #1498).** On a v2 split-layout install the Python hook layer was v2-blind and resolved an agent's home/workdir to the legacy v1 tree, so the `NEXT-SESSION.md` handoff was never delivered (no delivered-marker, no `[bridge:handoff-pending]` enqueue). `bridge-run.sh` now exports a distinctly-named `BRIDGE_AGENT_WORKDIR_RESOLVED` scalar (the bare `BRIDGE_AGENT_WORKDIR` is an associative-array name, so its scalar export silently no-ops — the #1213/#1217 collision class) on both the initial launch and the roster-refresh relaunch path; the hook resolvers consult `BRIDGE_AGENT_ROOT_V2`/`BRIDGE_DATA_ROOT` (mirroring bash `bridge_agent_default_home`) before the legacy fallback, while keeping the roster-CLI fallback reachable for dynamic/shared-mode agents whose workdir is a project directory.
- **`<admin>-dev` codex pair workspace drift on v2 (#1492, via #1500).** The documented `<admin>-dev` pair drifted to the admin's old/base shared cwd instead of following the admin's rewritten v2 effective workdir, breaking pair-review reproducibility. A tight predicate (static/shared pair named `<admin>-dev`, admin == `BRIDGE_ADMIN_AGENT_ID`, explicit workdir == the admin's base) now follows the admin's *resolved* workdir; identity, home, and hooks stay distinct (only the workspace is shared), with no live-process relocation.
- **`BRIDGE_AGENT_ENGINE`/`BRIDGE_AGENT_WORKDIR` map reads abort under `set -u` (#1407, via #1457).** A scalar-clobbered or unset associative map arithmetic-indexed the agent id under `set -u` → `<agent>: unbound variable` abort. Both reads now route through a `bridge_var_is_assoc` helper that inspects only the `declare` flag token (so a scalar/indexed value whose *contents* contain the flag text can't false-positive into the aborting read).
- **Cron-aware stale health (#1464, via #1465).** Schedule-driven static agents are no longer false-flagged stale just because they sit idle between scheduled wakes, while a genuinely overdue/stalled cron job (last run ≫ its cadence) still classifies stale — a cadence/next-due gate (reusing the scheduler's occurrence walker, robust to sparse-monthly and irregular schedules) instead of a blanket activity grace.
- **Stale `[task-complete]` spool replays dropped (#1472).** A confirmed-done `[task-complete]` entry in the pending-attention spool is dropped on flush instead of re-submitted; queued / missing / read-failure entries still replay (fail-safe preserve).
- **Admin cross-agent cron exemption broken via the wrapper (#1474, via #1490 — a `0.15.3` regression).** `bridge_load_roster` now exports `BRIDGE_ADMIN_AGENT_ID` after sourcing the roster so it survives the `exec` into `bridge-cron.sh` (the `agent-bridge`/`agb` wrapper path had lost it).

### Credential roadmap (Phase 0)

- **Usage-endpoint 429 as a proactive-rotation signal (#1468, via #1496).** The native usage probe was defeated by the very rate-limit it should detect — the usage endpoint is throttled (`429 rate_limit_error`) exactly when the account is near-limit, so the probe bailed and wrote nothing and proactive OAT rotation never fired (a catch-22). A genuine `429 rate_limit_error` now persists a near-limit `native-oauth-probe` cache (`used_percent` ≥ threshold, `reset_at` from `Retry-After`) so the existing monitor→rotation chain fires, idempotent per `(token, rate-limit window)` with no over-rotation or pool-loop, and no token bytes persisted (a token-free sha256-prefix discriminator).

### Internal / CI

- **#1454 security-canary moving-base footgun (#1494).** The `1454-bridge-lib-reexec-secret-canary` plain-TEETH case referenced `origin/main` as its "pre-fix vulnerable" reference, which became the *fixed* file once #1454 merged → it red-blocked `unit/static smoke` on every subsequent PR. Marker-guarded to skip when the base already carries the fix; the synthesized teeth carry coverage with no moving-base dependency.
- **Daily-backup exclude regression coverage (#1462, via #1493).** Locks in the regression test for the regenerable per-agent tree excludes (`.claude/security/agent-sdk-venv`, `.local/share/claude/versions`) that shipped in `0.15.3` (#1478).

## [0.15.3] — 2026-06-03

A process-stability + Codex-provisioning batch on top of `0.15.2`. Every item is codex pair-reviewed and CI-green (syntax + unit/static + oss-preflight + lint-heredoc-ban + lint + integration smoke). The marquee items are the incident-#8807 process-explosion fail-safes (resource guard + MCP-orphan reaper + cron-backfill coalesce) and the Codex provisioning upgrade wave (#8945: AGENTS.md task-protocol template + engine-aware nudge, 5 new audit-only hooks, availability-gated doctor + watchdog contract fix, agent-scoped slash commands + permission profiles).

### Added

- **Codex provisioning upgrade wave (#8945, 4 tracks).** Brings the bridge's Codex provisioning up to codex-cli 0.135/0.136 capability:
  - **Track A — Codex AGENTS.md template + engine-aware nudge (#1484).** A dedicated `agents/_template/codex/AGENTS.md` with an explicit Task Processing Protocol (claim→process→done, full `agb` paths, literal-nudge interpretation) so a Codex agent stops interpreting a one-line nudge as a single command; `bridge_scaffold_codex_entrypoint` now prefers the Codex template for Codex engines (Claude unchanged, fallback preserved); and the urgent nudge body in `bridge-send.sh` is engine-aware (Claude one-liner, Codex explicit multi-step, fail-safe on unknown engine).
  - **Track B — Codex hook expansion (#1485).** Five new audit-only-by-default Codex hooks — PreCompact, PostCompact, SubagentStart, SubagentStop, PermissionRequest — rendered by `bridge-hooks.py ensure-codex-hooks`. The PermissionRequest hook is bounded/redacted (an allowlist of known Codex tool identifiers + the `mcp__server__tool` shape persist; everything else collapses to `redacted-tool` + a one-way `tool_sha256`), deduped/throttled, fail-open and recursion-guarded, with no allow/deny side effect unless an explicit enforcement env is set.
  - **Track C — agent-scoped Codex slash commands + permission profiles (#1487).** Four custom-prompt templates (`agb-inbox/claim/done/handoff`) and three real Codex config profiles (`bridge-reviewer` read-only, `bridge-worker` workspace-write, `bridge-admin`) installed **agent-scoped** under `<agent_home>/.codex/` (selected via `codex -p bridge-<role>`), never the controller's global `~/.codex`.
  - **Track D — availability-gated `codex doctor` + watchdog AGENTS.md contract + version surface (#1486).** A `codex doctor` smoke that gracefully skips when the `codex` CLI is absent (no false release blockers); a watchdog fix so a Codex agent's `AGENTS.md` is recognized in either the workdir or the agent home (eliminates the `--allow-shared-workdir` false drift); and a non-fatal operator advisory on a `codex --version` major/minor change.

### Fixed

- **Incident #8807 — process-explosion fail-safes.** A wave fan-out (each fixer ≈ a full Claude + MCP fleet) accumulated orphaned processes until memory exhaustion made `fork()` fail and forced a host reboot. Three structural fail-safes:
  - **Resource guard at every daemon spawn site (#1479, P0a).** `lib/bridge-resource-guard.sh` fail-OPEN pre-flight defers a disposable-child spawn (leaving the work queued) when memory is pressured or per-uid process count crosses a threshold; wired at every `bridge-daemon.sh` spawn site (cron worker, cron-dispatch, supp-refresh, auto-start) with throttled audit/warn.
  - **MCP-orphan reaper patterns tightened + extended (#1482, P0b).** The periodic MCP-orphan reaper's `DEFAULT_PATTERNS` are tightened to bridge-owned provenance (plugin-cache-anchored crm/shopify/bun matchers) and extended to the missing signatures, with a PID-reuse revalidation before TERM/KILL and an early sweep at the top of the sync cycle. Deliberately never matches Pencil.app's `mcp-server-darwin-arm64` or live `codex resume` pairs.
  - **Cron backfill coalesce (#1481, P1).** A daemon restart after downtime no longer replays a burst of missed picker-sweep/idempotent occurrences into the inbox; catch-up is coalesced (keep-latest, cap 1) before enqueue.
- **Engine→binary mapping for the daemon autostart gate (#1483).** The always-on auto-start gate in `bridge-daemon.sh` probed `command -v <engine>` against the engine identifier, so a roster entry with `engine=antigravity` (CLI binary `agy`) was permanently skipped with `engine-cli-missing:antigravity` even when the binary was installed under its real name. A new `bridge_engine_binary_name()` helper in `lib/bridge-engine-descriptor.sh` maps engine identifier → CLI binary (`claude→claude`, `codex→codex`, `antigravity→agy`); the daemon gate now routes its PATH probe through that helper and the audit reason reports the real binary (`engine-cli-missing:agy`) for traceability, with a legacy bare-engine fallback for unknown engines. On the operator's `sean-mac`, the `patch-agy` static agent had 94 consecutive false-positive failures before this fix.
- **`bridge-core.sh` heredoc-stdin → `python3 -c` + daily-backup excludes (#1466 / #1462, #1478).** Removes two footgun-#11 heredoc-stdin sites in `bridge_now_iso`/`bridge_nonce`, and excludes regenerable per-agent trees (`.claude/security/agent-sdk-venv`, `.local/share/claude/versions`) from the daily backup so the walk+gzip stops blowing the timeout on multi-agent installs.
- **A2A iso-boundary fixes (#1473 / #1474).** `agb agent list` no longer false-reports a stopped agent from inside an iso UID (iso-readable all-agent state aggregate), and genuine controller/admin cross-agent cron provisioning is allowed via a non-forgeable daemon-staging gate.
- **Daemon cron-nudge hygiene (#1458 / #1471).** Cron backlog is kept out of human "ACTION REQUIRED" nudges, and attached human cron followups are escalated correctly.

### Changed

- **wave-orchestration skill synced to the repo (#1477).** The repo-tracked `.claude/skills/wave-orchestration/SKILL.md` now matches the evolved 5-phase skill, including Phase 3.5 (monitor dispatched fixers — wedge detection + the rule that a taken-over wedge-recovery PR still gets a Phase-4 pair-review).

## [0.15.2] — 2026-06-01

A stabilization + headless-hardening batch on top of `0.15.1`. Every item is on `main`, CI-green (syntax + unit/static + oss-preflight + lint-heredoc-ban + lint + integration smoke), and codex pair-reviewed. The marquee items are headless Claude OAT self-rotation (proactive native probe + reactive 429), a Darwin-gated macOS Claude `apiKeyHelper` auth path with a deep inherited-env credential-leak hardening pass, a whole-fleet crash-loop fix on per-agent-HOME installs, and the long-standing daemon "ACTION REQUIRED" nudge double-fire fix.

### Added

- **Native Anthropic usage probe for headless proactive OAT rotation (#1437 / #1443).** On a headless cron host with no `claude-hud`, the daemon can now source utilization directly from the Anthropic `api/oauth/usage` endpoint with the active OAT and map it into the existing `.usage-cache.json` shape, so the proactive rotation/threshold path fires *before* a 429. Additive `--native-usage-cache` source, consumed only when `_source==native-oauth-probe` (the per-agent #831 guard stays intact). Credential transit is hardened: the OAT is never placed in a forgeable env var or on-disk path — it is delivered to the probe over an inherited fd on an unlinked `0600` file, the probe self-re-execs under `bash -p` (privileged mode imports no environment functions), and `BASH_ENV` / `ENV` / `BASH_XTRACEFD` are unset, closing the exported-function and startup-file-hook credential-leak classes. See `OPERATIONS.md` §"Native usage probe". *(Pre-flight: the live `api/oauth/usage` GET is verified on the operator's headless host before relying on it in production — the endpoint is undocumented/internal.)*
- **Gated macOS Claude `apiKeyHelper` auth (#1444 / #1449 / #1452).** A Darwin-only, operator-gated path that serves the Claude OAT to a macOS host via a managed `apiKeyHelper` script (Keychain-free), with the same comprehensive inherited-env credential-leak hardening as the usage probe (`bash -p` re-exec, `BASH_ENV` / `ENV` / `BASH_XTRACEFD` unset, per-process-random-nonce-gated fd transit on an unlinked `0600` file). The settings writer is Darwin-gated so non-Darwin (iso-v2 Linux) never writes or leaks a controller `apiKeyHelper` path; `disable` removes only the genuinely managed value, so an operator's own symlink survives (raw-value compare). See `OPERATIONS.md` §"macOS apiKeyHelper".

### Fixed

- **Whole-fleet agent crash-loop on per-agent-HOME installs (#1439).** When the Claude CLI boot outpaced the session-id detect window on a per-agent-HOME install, the whole fleet could crash-loop; the detect path now degrades to a fresh session instead of fail-looping.
- **Daemon "ACTION REQUIRED" nudge double-fire (#1199 / #1451).** The queued-task Stop-hook re-injected an "ACTION REQUIRED … claim immediately" nudge for a task the agent had *just claimed*, because the queue summary counted `queued + claimed`. It now counts only genuinely-`queued` tasks, and a just-claimed task no longer triggers an immediate re-nudge. (Codex Stop-hook anti-abandonment is preserved separately via the open-claimed count.)
- **Reactive Claude OAT rotation on a headless cron 429 (#1437 / #1441).** A cron run that hits an Anthropic 429 now triggers an OAT rotation reactively on headless hosts (the complement to the proactive #1443 probe — together they complete #1437).
- **Fail-safe daemon spool rederive + dedupe-on-claim (#1425).** The daemon's spool rederive is now fail-safe (a malformed/partial spool entry no longer wedges the rederive pass), with dedupe-on-claim semantics documented.
- **Codex launch flag `features.codex_hooks` → `features.hooks` (#1446).** codex-cli 0.135.0 deprecated `features.codex_hooks`; the launch flag now emits `features.hooks` (recognizing the legacy form as already satisfying hooks — dedup, no double-pin), clearing the `[features].codex_hooks deprecated` boot warning.
- **v2 per-agent-workdir layout covered by protected globs (#1448).** The system-config protected globs now cover the v2 `data/agents/*/workdir/.discord|.telegram/access.json` layout, with segment-aware matching (each `*` bounded to a single path segment).
- **Claude submit via CSI-u Enter for Claude Code 2.1.158+ (#1450 — external contributor: Jong Ko).** Claude Code 2.1.158+ changed Enter handling so the legacy `C-m` no longer submitted; the tmux submit path now emits a CSI-u Enter for Claude engines (Codex / non-Claude unchanged), mode overridable via `BRIDGE_TMUX_CLAUDE_SUBMIT_KEY_MODE`, with a gated fallback to legacy `C-m`.

### Security

- **`apiKeyHelper` inherited-env credential-leak hardening (#1452, relates to #1444).** A retro Phase-4 security review of the early-merged #1444 found inherited-env credential-leak vectors in `bridge-run.sh` + the helper wrapper. The credential is now captured and the well-known env vars unset *unconditionally before any external command or subshell*; `bridge-run.sh` re-execs under `bash -p` (privileged mode imports no environment functions, closing the exported-function-shadow class in one shot); `BASH_ENV` / `ENV` / `BASH_XTRACEFD` are unset; and the legacy-path credential survives the re-exec only over a per-process-nonce-gated fd on an unlinked `0600` file. Cron keychain-free preflight gets an explicit scrubbed `env=`. Out-of-scope residuals (initial-process `BASH_ENV` startup sourcing, a same-UID caller forging the nonce, the shared `bridge-lib.sh` re-exec) are tracked in #1454.

### Docs

- README index + CLAUDE.md release-ritual sync (#1435 / #1436), `OPERATIONS.md` §"Native usage probe" / §"macOS apiKeyHelper", and `KNOWN_ISSUES.md` CSI-u / apiKeyHelper notes, all carried to `v0.15.2`.

## [0.15.1] — 2026-05-31

A stabilization batch on top of `0.15.0` plus one opt-in feature. Every item below is on `main`, CI-green (unit/static + oss-preflight + lint-heredoc-ban + lint + syntax + integration), and codex pair-reviewed.

### Added

- **`agb setup template-sync` — seed new agents from a reference agent (#1427).** An opt-in wizard that reads a reference agent's roster config (model, effort, permission_mode, skills, plugins, channels) and writes a controller-owned defaults profile into `agent-roster.local.sh`; `agent create` then materializes those as **explicit per-agent roster fields**, so a freshly-installed bridge's new agents no longer come up bare (Sonnet / low-effort / no plugins). Reference read is **roster-only** (never introspects the reference's `~/.claude`, plugin cache, or MCP runtime) and **never copies credentials/tokens/MCP secrets** — channels are carried as declarations only (re-run the per-channel `setup` wizards for creds); `permission_mode=legacy` is never propagated. The whole command is gated on the same operator-tui / operator-trusted-id boundary as `agent create`, and the roster-write verbs (`agent roster materialize-fields` / `write-template-profile`) are independently gated + audited — an agent-direct caller cannot mutate the roster through any path, including caller-controlled writer-command overrides. The live accessors are unchanged, so old rosters with unset fields keep the legacy-launch contract. See `docs/template-sync-design.md`. *(Pre-flight: verify a live admin-session run before relying on it in production.)*

### Fixed

- **Text crons 100% failed on a fresh `0.15.0` non-iso single-user macOS host (#1421).** Under the daemon's process-wide `umask 077`, every cron run dir landed `0700/0600` (the group-widening that marks non-shell runs is iso-gated), so `shell_artifact_route` mis-classified text crons as the controller-private shell route and aborted them as `request_artifact_tampered`. `cmd_run` now peeks the controller-private body and only commits to the shell path for an actual shell payload. Also: `claude_config_dir_for_request` falls back to the first existing per-agent `.claude` dir when no `.credentials.json` exists (macOS Keychain / API-key hosts) instead of returning `None`.
- **Daemon nudge/alert hygiene — external-contributor reports (#1408, #1409, #1411 via #1424).** A2A outbox-stuck + unclaimed-task admin alerts now refresh a **single** open task per stable prefix via an atomic `bridge-queue.py upsert-open` (was ~116 duplicate high-priority tasks for ~6 real conditions); the Claude busy-gate detects the mid-turn `Working` / `esc to interrupt` banner so daemon nudges to a busy agent are spooled + re-delivered instead of stranded as `submit_lost_post_grace`; and the queued-task "ACTION REQUIRED" nudge gains an `attached`-session skip so an attached admin session no longer accumulates `[deferred]` replays.
- **iso-v2 active shared-tree split-brain on v2 migrate (#1431).** The v2 migration now relocates the active shared tree, resolving a `0.15` split-brain.
- **`bridge-cron --kind shell` dead-end on macOS / non-iso (#1426 via #1433).** `--help` and the create-time error now state the iso-v2 / Linux-only requirement up front and point to the supported scheduled-shell fallbacks (OS crontab, or a `--kind text` cron running `bash <script>`); documented in `OPERATIONS.md` with `pgrep` portability guidance. (Non-iso controller-shell execution was deliberately deferred — it would weaken the iso-v2 boundary.)

### Changed

- Built-in launch default model `claude-opus-4-7` → `claude-opus-4-8` (with #1432) — applies to new-shape launch rows only; existing explicit roster entries are untouched and there is no silent upgrade.

### Docs

- `0.15.0` stable version references + public repo URL migration to `seanssoh/agent-bridge-public` (#1420).

## [0.15.0] — 2026-05-31

Promotes `0.15.0-rc1` to **stable**, plus the A2A cross-bridge self-heal stack, the handoffd supervision layer, and two fresh-install/managed-agent hardening fixes that landed and were verified after the rc. Everything in `0.15.0-rc1` (the minor bump for OS-state risk separation, the hardened iso-v2 isolation stack, and the full fresh-install/upgrade OOTB-acceptance campaign — see that section below) carries forward unchanged. Each item below is on `main`, CI-green (unit/static + oss-preflight + lint-heredoc-ban + lint + syntax + integration), and codex pair-reviewed; the security-critical A2A surfaces additionally went through adversarial-verify sweeps + codex security review (which caught real bind-env-propagation and fail-closed-contract gaps the sweeps rated clean — the layered review earned its keep).

### A2A cross-bridge self-heal — IP churn no longer needs a human (#1401, #1403, #1404, #1406)

The recurring toil where a peer's (or your own) Tailscale IP changed after a re-login and silently broke cross-bridge handoffs (stale `handoff.local.json` peer/listen IP → `reject_addr_mismatch`, requiring a manual re-discover + edit + daemon restart on **both** sides) is closed end-to-end:

- **P0 runtime Tailscale-identity resolution (#1401).** `handoff.local.json` peers + `listen` may now carry a Tailscale `node_id` (StableID) and/or `tailscale_name` (MagicDNS/hostname) in addition to the legacy raw `address`. Sender (peers test + POST), inbound `do_POST` source-address auth, and the receiver bind all resolve the live IP at use-time via `tailscale status --json` — so an IP change is picked up transparently with nothing stored to go stale. The **fail-closed bind proof is preserved**: an identity resolves only to a *candidate*, which must still be in the node's own `tailscale_addresses()` set or the receiver refuses to serve. Fully back-compatible with raw-`address` configs.
- **P-self-heal-1 daemon auto-rebind + config hot-reload (#1403).** A running `bridge-handoffd` re-resolves its listen identity on a 45s / SIGHUP reconcile and **auto-rebinds** when the local node's Tailscale IP drifts (no manual restart), and hot-reloads `handoff.local.json` so a newly-paired peer / migrated identity takes effect live — both fail-closed (a malformed reload never drops the bind proof or allowlist). `agb a2a reconcile`.
- **P-self-heal-2 `agb a2a migrate-identity` (#1404).** Rewrites existing raw-IP peers/listen to identity keying (dry-run default, fail-closed, 0600-from-start atomic write) so old configs gain the self-heal.
- **P-self-heal-3 signed peer-identity-update IP-change announce (#1406).** When a node's reconcile detects its own Tailscale IP changed, it pushes an HMAC-signed `peer-identity-update` to each paired peer; the receiver **corroborates the claim against its own `tailscale status` view** (never trusts the self-asserted wire IP), checks the tailnet `remote_addr`, and only then updates that peer's stored identity — closing the first-contact / not-yet-migrated convergence gap with zero human edits on either side. Independently validated by a real multi-tailnet-IP-change field incident (crm-dev mesh outage).

### A2A handoffd supervision — silent receiver death is now visible + self-healing (#1405)

The A2A receiver previously had no supervision: a silent exit left port 8787 unbound with no auto-restart and no alarm — a "send-OK / receive-dead" half-state discovered only when a peer manually probed. The daemon now supervises it as a managed child: a two-stage liveness check (process gate + a new `bridge-handoffd.py healthz` GET probe that catches a bound-but-wedged serve loop), **auto-restart via the full fail-closed `bridge-handoff-daemon.sh start` preflight** (never a raw serve; the restart re-runs the entire bind proof + peer-secret gate), a crash-loop cap (5 restarts / 600s) that latches an alarm + files one cooldown-gated admin task rather than hammering, exit-cause capture (`receiver-exit.json` + audit row), a `receiver-down-while-active` alarm surfaced in `agent-bridge status`, and systemd-defer when an `agb-handoffd.service` unit owns the lifecycle. A persistent bind-proof failure (tailnet down) alarms-and-holds — it never auto-restarts onto a degraded contract, and never inherits the smoke-only `BRIDGE_A2A_ALLOW_TEST_BIND` / `BRIDGE_A2A_DEV_INSECURE_BIND` escape hatches (scrubbed from every supervisor-owned subprocess).

### `agb a2a setup` wizard — P1 skeleton (#1415)

A new agent-driven, decision-gated, idempotent/resumable `agb a2a setup` that automates the A2A cross-bridge setup runbook except the secret exchange: **S0** preflight (Tailscale present / authenticated — the one human gate is the browser login), **S1** self-config writing an identity-keyed `listen`, **S2** discover + pick a peer (the secret comes via `--peer-secret-env`, never a plaintext flag), **S5** activate via the fail-closed `bridge-handoff-daemon.sh start`, **S6** handshake (dry-run by default; live behind `--live-handshake`). State is derived from observable facts (no on-disk wizard state to go stale), and `--show-state --json` reports the current step + next action for the agent loop. Fail-closed throughout: a peer is written only once it is both secret-bearing **and** resolvable (a live tailnet-identity match or a pre-placed raw `address`); an unresolvable or secretless peer is refused before any 0600-atomic config write, and S5 refuses to activate a config whose peers cannot resolve. Secret pairing (§4d) and roster/allowlist negotiation (§4e) are deferred to P2/P3.

### Fixes

- **Dynamic-agent loader hardening — #1407 (#1410 + #1412).** Three surface aborts that fired on an empty-session + `continue=1` install (assoc-array indexed reads under `set -u` when a `BRIDGE_AGENT_*` map was unset/clobbered to a scalar, and `printf '- …'` markdown bullets parsed as options) are fixed: a centralized guarded `bridge_agent_created_at` accessor + `printf --` end-of-options, then a follow-up that repairs any roster map a sourced dynamic env-file clobbered to a scalar (`bridge_ensure_roster_maps_assoc`, before the indexed writes) — closing the class for every `BRIDGE_AGENT_*` map the loader touches, not just one read. Reported by an external contributor (Mejurix).
- **Onboarding-state parser anchored to the field line (#1416).** `bridge_agent_onboarding_state` (and the watchdog twin) matched the bare `Onboarding State:` substring anywhere in `SESSION-TYPE.md`, so a checklist-body line that quotes the field as instruction text could be picked up; the parse is now anchored to the top-block metadata field line (`^…- Onboarding State:`) and the templates de-trapped, with a teethed regression smoke. (The deeper managed-project workdir-vs-home dual-copy identity drift this surfaced is tracked separately for the lifecycle-redesign work.)
- **Version surfacing.** `agent-bridge status` and upstream-issue drafts already carry the bridge `VERSION` — confirmed, no change needed.

## [0.15.0-rc1] — 2026-05-30

First **release candidate** for the 0.15.0 line (supersedes the `0.15.0-beta1` … `0.15.0-beta5-5` pre-releases). Headline: a minor bump for OS-state risk separation, a hardened iso-v2 isolation stack, and a long fresh-install/upgrade OOTB-acceptance campaign that closed the daemon, isolation, channel-setup, and cron edge cases that only surface on a clean install or an old-beta→latest upgrade. Validated by a clean-Linux-VM beta2→beta5-5 upgrade regression test (no upgrade regressions; net-fixed the shared-agent-start blocker) plus a macOS-VM (Sequoia, shared-mode / no-isolation) upgrade verify confirming the Linux/iso-v2-centric changes are side-effect-free on macOS, per-lane codex pair-review, and adversarial-verify sweeps.

### What's new since `0.15.0-beta5-5` (the release-candidate hardening)

- **Daemon singleton-lock fd-leak — fully closed (#1388 + #1390).** The daemon held its PID-file flock without close-on-exec, so daemon-launched children (the `tmux new-session` server, and the detached supp-groups-refresh worker that triggers + survives its own daemon restart) inherited the fd and pinned the flock after the daemon died → a respawn restart-cycle (`daemon_spawn_lock_busy`) that could leave the daemon permanently down on an unlucky host. Now the lock fd is closed for daemon-launched children (the 3 synchronous `bridge-start.sh`/tmux launch sites via a helper, and the backgrounded supp-refresh worker via a subshell-local `exec {fd}>&-`); the daemon keeps the fd + flock for its lifetime. Found by the upgrade regression test; cross-engine-reviewed; LIVE-verified on a Linux VM (restart-cycle eliminated, zero non-daemon lock holders).
- **CI/portability hardening + a comprehensive unit/static smoke-gate close.** iso cron `agb cron create` cleanup-trap robustness under `set -u` (#1387); `1379` iso-cron-staging heredoc-in-capture extracted to file-as-argv (footgun #11); `beta5-2-mu` channel-creds `stat` made GNU/BSD-portable. Then the **full required-smoke suite was run per-script on Linux** and every inherited smoke/fixture drift fixed in one pass — `β-1231` fresh-install-seed-sudoers stderr status contract (#1230 / #1393), `I-beta4-a2a-3-gaps` T4/T6 tick greps anchored for the #1338 subshell-isolate wrap (teeth preserved), `a2a-cross-bridge` live-reader for the #1318 stopped-target guard, `agent-doctor` engine PATH stubs (#1317-C), `beta5-2-nu-daemon-path-quarantine` engine-presence driver, `H-bootstrap-memory-iso-rebuild` sudo-test across the 2770 iso boundary, `H-beta4-iso-ownership` `declare -gA` roster maps (set -u), `J-beta4-workflow-docs` `BRIDGE_BASH_BIN` + admin-roster seed. Finally a tree-wide **GNU-first `stat` fallback** audit (the BSD-first `stat -f '<fmt>' … || stat -c …` idiom captures the GNU `statvfs` blob, since GNU `-f` is *filesystem status* not *format*): the `telegram-relay-residue-cleanup` inode-anchor flake and the `smoke-test` read-mode-sync assertion were flipped to GNU-first, and the audit surfaced one **latent product bug** — `picker-sweep.sh`'s rotation-lock mtime read captured the blob and the numeric guard then zeroed it, silently disabling staleness detection on every Linux host (now GNU-first, real epoch restored). Smoke/fixture alignment only, apart from that one `picker-sweep` product fix. A further cluster of macOS-authored smokes surfaced one-by-one as each earlier blocker was fixed (the required suite aborts on the first failure, so a fix unmasks the next): all were the same two root classes. **Engine-presence (#1317-C):** `J-beta4-workflow-docs` T7b, `agent-create-idle-timeout`, `1105-agent-add-audit`, and `1136-always-on-no` run a real `agent create/add --engine claude`, whose `command -v <engine>` pre-flight hard-dies on an engine-less CI runner — they now seed `claude`/`codex` PATH stubs (the agent-doctor pattern). **Markerless v2-layout:** `1380-admin-autostart-recovery`'s three daemon-recovery subshells and `1355-1356-ms365-wizard`'s T3 enumerator subshell pin `BRIDGE_LAYOUT=v2` so the v0.8.0 resolver takes the env-override branch instead of hard-dying on a markerless home (the resolver no-ops on the macOS dev host, which is why none of these were ever caught locally). Enumerated by running the **exact CI-selected required subset on a clean engine-less x86 Linux container** (matching the runner: real non-root user, `sudo`+`NOPASSWD`, `rsync`/`sqlite3`/`bun`, a real `.git`), continue-on-fail, separating genuine failures from environment artifacts. All smoke/fixture alignment, no product behavior change beyond the one `picker-sweep` fix. **All required smokes (`unit/static`) + `lint-heredoc-ban` + `oss-preflight` green on Linux.**

### Included from the 0.15.0 pre-release line (see the `0.15.0-betaN` sections below for full detail)

- **Minor bump 0.14.5→0.15.0**: OS-state risk separation (Track F).
- **Fresh-install / OOTB isolation-v2 closures**: setup-pending grace window (#1353); FD-aware `setup teams --app-password-file`/`--*-stdin` (#1354); ms365 wizard default scopes + redirect-URI Entra probe (#1355/#1356); iso-v2 boundary docs + `agent show` quickref (#1357); nudge eligibility 2-stage recheck (#1323); iso-agent `agb cron create` staging delegation + daemon-readable request/result (#1359/#1379/#1383); persona onboarding runbooks + `agent show` next-actions (#1360); shared-mode agents fall through to controller HOME for session detect (#1370); shared-mode codex-pair PATH via the daemon engine resolver — nvm/pyenv/volta/asdf (#1352); `write_agent_state_marker` controller-owned state-leaf (#1342); fresh iso agent `session.lock` on the controller-owned state leaf (#1378); admin autostart recovery on resume-state failure (#1384, realizing the long-deferred J #1370).
- **Security**: credential-text audit-leak class closure with a two-layer (SSOT choke-point + at-source) redactor (#1358); MS365 refresh_token resilient auto-refresh — single-flight, transient/permanent split, deep secret redaction hardened via adversarial-verify sweeps (#1343).

### Known / deferred (non-blocking, pre-existing)

- Live re-verify left to operator discretion: Track Q admin auto-restart raw-VM admin-kill E2E (code-cleared + gate-correct), MS365 token-refresh natural ~1h expiry monitor (#1343).
- Roots tracked as follow-ups: `#1367` (Track F sealed-paste), `#1353` root (`awaiting_channel_setup` state machine), `#1359` root (daemon IPC socket), `#1398` (A2A inbound `--force` past the #1318 stopped-target guard), `#1399` (`bootstrap-memory-system.sh` pipefail on an admin-less roster).

## [0.15.0-beta5-5] — 2026-05-29

### Highlight — beta5-4 fresh-install verify v2 fixup + admin liveness recovery

patch's beta5-4 fresh-install verify v2 (clean Linux VM, 22h+ controller session = max stale-group exposure) confirmed **N #1378 GREEN** (fresh iso agent start completes end-to-end) and **O #1379's core GREEN** (daemon reads the iso-staged cron request + creates the job), but surfaced a residual on the result-write leg. Separately, the live `patch` admin agent went down after beta5-4 and couldn't self-recover, which finally realized the long-deferred **J #1370** as a concrete daemon fix. beta5-5 closes both. `-beta5-5` prerelease, tag `v0.15.0-beta5-5`, GitHub **Pre-release**.

Lane → PR map: P #1385 (#1383) / Q #1384 (#1384, J #1370).

### Fixed — Track P: iso cron result.json is daemon→iso readable (#1383, PR #1385)

O #1379 fixed the iso→daemon *request*-read leg; this closes the daemon→iso *result*-read leg. On the fresh-install path the per-agent staging subdir has no setgid bit yet, so the daemon wrote `<uuid>.result.json` in the controller's own default group → the iso UID hit `PermissionError [Errno 13]` reading its own cron result (the cron job ran, but the result-feedback was unreadable). New `_resolve_result_gid` (controller-side twin of `_resolve_staging_gid`: actor-name-only canonical gate, rejects the controller egid + `ab-shared`, root-aware `_writer_can_chown`) + `_resolve_result_gid`-driven `chgrp ab-agent-<a>` 0660. The result write is **fail-loud-but-publish** (loud stderr on chgrp/verify failure but always publishes) — deliberately distinct from the request leg's fail-loud-refuse, because the result file is the only channel back to the iso poller and refusing would strand it. #1379 request leg AST-unchanged; #1359/#1379 isolation preserved.

### Fixed — Track Q: recover admin autostart on resume-state failure (#1384, J #1370)

The live admin agent could not self-recover after a daemon-managed start failed (e.g. an empty/invalid persisted resume session id), leaving the operator without an admin surface. New `bridge_daemon_start_agent_with_recovery()` wraps both always-on warm starts and on-demand queued wakes: after a single base start attempt, if the agent **is the admin** (`bridge_admin_agent_id` gate) it repairs empty resume state, retries `--no-continue`, then `--safe-mode --no-continue`, auditing every attempt. Non-admin agents fall straight through — exactly one start attempt + existing backoff, byte-equivalent warning behavior (no recovery ladder, no extra attempts). Realizes the deferred J #1370. Authored by patch-dev (cm-prod). Live raw-VM admin-kill E2E is patch's post-merge verify.

### Known carry-over / pending verify

- **Live re-verify pending**: P #1383 (patch confirms the iso UID now reads its own `.result.json`), Q #1384 (patch's raw-VM admin-kill E2E — code-cleared by codex, not yet live-tested), M #1343 (MS365 token refresh — patch monitors test_clean's natural ~1h expiry).
- **Stable-prep lint sweep** (deferred, beta-informational): the `lint-heredoc-ban --baseline-check` CI job stays red on 2 INHERITED C1 heredoc-in-capture sites in `scripts/smoke/1379-iso-cron-staging-group.sh:254/318` (from beta5-4's #1379, not deadlocking in practice). A full `lint-heredoc-ban` + `iso-helper-baseline` sweep should bundle into the stable cut. oss-preflight itself is green.
- Inherited: β-1231-1236 T5 stderr/stdout, #1367 (Track F root), #1353 root (awaiting_channel_setup), #1359 root (daemon IPC socket).

## [0.15.0-beta5-4] — 2026-05-29

### Highlight — beta5-3 fresh-install verify fixup (2 OOTB blockers)

patch's beta5-3 fresh-install acceptance verify on a clean Linux VM (cm-prod-agentworkflow-vm01) returned **8 lanes GREEN** (K/A/CD/L/E/I + OAT) but surfaced two OOTB blockers that only a brand-new iso v2 agent on a long-running controller session hits — neither reproduces on an existing iso agent (regression on an existing agent is necessary but not sufficient; this is exactly why the fresh-install acceptance gate exists). Both are the same iso v2 controller-stale-supplementary-group class (a `usermod -aG` does not refresh the live controller/daemon process's group set, so a freshly-created agent's `ab-agent-<a>` GID is absent until re-login — confirmed by patch's `/proc/<pid>/status` diagnosis). `-beta5-4` prerelease, tag `v0.15.0-beta5-4`, GitHub **Pre-release**.

Lane → PR map: N #1380 (#1378) / O #1381 (#1379).

### Fixed — Track N: fresh iso agent start no longer fails on session.lock (#1378, PR #1380) — OOTB blocker

A freshly-created iso v2 agent (`agent create <new> --isolate && agent start <new>`) aborted with `session.lock: Permission denied` — `bridge_agent_session_lock_file` resolved into the iso DATA tree `data/agents/<a>/runtime/` (`root:ab-agent-<a>` 2750/2770), which the controller (whose live process has a stale supplementary-group set after `usermod -aG`, the #1025 class) cannot open. The lock is a controller-only serialization primitive (the agent UID never flocks it), so it now anchors on the controller-OWNED state leaf `bridge_agent_idle_marker_dir` (→ `state/agents/<a>/`, emitted `controller:ab-agent-<a>` 2770) — the controller writes it via OWNER bits, independent of the stale group. Shared/non-iso lock path is byte-identical; Track L idle-markers coexist in the same setgid leaf.

### Fixed — Track O: iso cron staging file is daemon-readable (#1379, PR #1381) — #1359 follow-up

`agb cron create` from an iso v2 agent staged a file the daemon couldn't read (group was the iso UID's user-private `agent-bridge-<a>`, not the shared `ab-agent-<a>`) → 30s pickup timeout → silent cron-create failure. The staging writer now `chgrp`s the file to the canonical actor group (`ab-agent-<a>`, 0660) + self-heals the per-agent subdir to 2770+setgid. Hardened over two review rounds: `AGB_STAGE_FILE_GROUP` is an untrusted gid-selection hint (the allow-list is actor-name-derived only — `ab-shared`/other groups are rejected, closing a cross-agent surface), and the chgrp is fail-loud (post-stat `st_gid` verify; on mismatch it unlinks + errors `rc 73` with no uuid instead of silently publishing the un-readable file). #1359 per-agent ownership isolation preserved.

### Known carry-over / pending verify

- **Deferred from beta5-3 verify (not blockers)**: M #1343 (MS365 token refresh — patch monitors test_clean's natural ~1h token expiry), J #1370 (shared-mode admin auto-restart — needs a raw-VM admin role, not patch's own session). Both code-cleared; awaiting natural/raw-VM verification.
- The broader iso v2 controller/daemon stale-supplementary-group ROOT (a `usermod -aG` doesn't refresh a live process): Track N sidesteps it for the lock via a controller-owned path; the daemon-side group-refresh complement is added only if patch's beta5-4 end-to-end re-verify shows a stale-group barrier remaining past the lock.
- Inherited: β-1231-1236 T5 stderr/stdout (informational), #1367 (Track F root), #1353 root (awaiting_channel_setup), #1359 root (daemon IPC socket).

## [0.15.0-beta5-3] — 2026-05-29

### Highlight — beta5-2 OOTB-followup wave (12 lanes A–M, ~13 issues) + #1370 regression + CI housekeeping

patch's beta5-2 fresh-install + cosmax-channel bring-up surfaced an OOTB regression/UX-gap backlog (6 issues + 1 comment), then 2 more lanes folded in (cron-iso #1359, onboarding meta #1360), plus a beta5-2 #1316 regression (#1370) caught on the operator's macOS shared-admin host. wave-orchestration: parallel fixer dispatch off `feat/wave-beta5-2-followup-integration`, per-lane codex pair-review (r1→r6 chains on the security lane), integration-branch burn-in, then this release cut. cross-bridge: #1370's fix originated as cross-fork PR #1371 from `patch@hoon-mac`, independently verified (workflow 4-lens + codex pair, teeth proven) and absorbed as Track J with the required smoke update. A second sub-wave then folded in three more out-of-scope issues the operator flagged — shared-mode codex-pair PATH (#1352, Track K), iso-v2 state-marker (#1342, Track L), and MS365 refresh-token resilience (#1343, Track M) — the last hardened through two read-only adversarial secret-leak sweeps on top of codex pair-review (key-name redaction alone missed a `_raw` free-text envelope + the auth-code-path twin sink + the top-level OAuth `error` field). `-beta5-3` prerelease, tag `v0.15.0-beta5-3`, GitHub **Pre-release**.

Lane → PR map: A #1366 / B #1363 / CD #1365 / E #1362 / F #1368 / G #1369 / H #1361 / I #1364 / J #1372 / K #1377 / L #1376 / M #1375 / housekeeping #1373.

### Fixed — Track A: setup-pending grace window (#1353, PR #1366)

`agent create --isolate --channels … always_on=yes` no longer floods the daemon log with 4× channel-validator-miss auto-start backoff before the operator runs `setup`. A `state/agents/<a>/setup-pending` marker (grace `BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS`, default 900s) makes the daemon silently skip pre-setup validator misses; the setup verbs clear it. Tactical scope — `awaiting_channel_setup` state machine is the follow-up root. Dry-run no longer leaks the marker; iso-v2 marker-write failure hard-fails (no noncanonical fallback).

### Fixed — Track B: setup teams FD-aware `--app-password-file` (#1354, PR #1363)

`setup teams --app-password-file <(…)` process-substitution path (`/dev/fd/63`) now reads via try-open-and-read instead of a stat-gate; added first-class `--app-password-stdin` / `--client-secret-stdin` (mutually exclusive with the `--*-file` flag). Single-trailing-newline strip preserved (handler-level greedy `.strip()` removed). Error message names the process-substitution + tempfile/stdin alternatives.

### Fixed — Track CD: ms365 wizard default scopes + redirect-URI Entra probe (#1355 + #1356, PR #1365)

`--yes` mode no longer requires `--default-scopes` — the Graph minimal convention set (Mail.Read/Mail.Send/Calendars.ReadWrite/offline_access) is the documented default with `default_scopes_source: convention-default` in output; explicit empty `--default-scopes ""` is a fail-loud error (argparse `default=None` sentinel), not a silent fallback to broad scopes. redirect-URI is probed against the Entra app registration via Graph (fail-loud if unregistered, audited skip on insufficient app permission). Verbatim URI compare (no query/fragment stripping).

### Fixed — Track E: iso v2 boundary docs + `agent show` quickref (#1357, PR #1362) — docs

CLAUDE.md "Working with isolated agents (iso v2)" gains an agent's-own-POV table (what blocks where + the CLI-verb workaround), and `agb agent show` (iso-effective agents only) emits an `iso_boundary_quickref` section (text + `--json` list). Generic `<controller-user>` placeholder, no host-specific account names.

### Fixed — Track F: admin credential-routine carve-out + audit token-leak class closure (#1358, PR #1368) — SECURITY

Admin agents can run the rotation routine `bash bridge-auth.sh claude-token add --stdin` (strict-prefix carve-out, env+roster admin agreement required) without the OAuth-credential tool-policy guard blocking it. Six review rounds closed the entire credential-text audit-leak class with a two-layer defense: a Layer-1 SSOT choke-point (`bridge_hook_common.write_audit` recursively redacts every audit `detail`, so all current/future writers inherit it) + Layer-2 at-source redaction in the tool-policy writers, the `permission_escalation` deny `reason` (→ audit + `[PERMISSION]` queue task body), and the `system_config_mutation` non-Bash operation. Redactor is idempotent (negative-lookahead, no `<REDACTED><REDACTED>` compounding). Root sealed-paste path → follow-up #1367.

### Fixed — Track G: nudge eligibility 2-stage recheck + audit surface (#1323, PR #1369)

`nudge appears dropped` false-positive rate cut: eligibility recheck is now a 2-stage check (stage 1 at 2s, stage 2 at 5s total — not 2+5) before the drop verdict; silent skip now emits an audit row + `agb status` counter (operator surface). Real rapid-succession dedup race covered (T4 sources the actual `bridge_daemon_should_skip_nudge` / `record_nudge` path).

### Fixed — Track H: agb cron create iso-agent staging delegation (#1359, PR #1361)

iso v2 agents can `agb cron create` without the controller-owned `jobs.json` `PermissionError` (no more system-crontab workaround + bridge-native double-fire race). iso UID stages the mutation to `state/cron-staging/<uuid>.json` (mode 660 ab-shared); the daemon applies it under controller privilege + writes a result file. Per-agent ownership isolation enforced controller-side (actor must match filename + caller uid). Stale-staging swept before apply; malformed actor_uid rejected (no crash); cross-agent mutation rejected for all kinds. Tactical — daemon-IPC socket is the follow-up root.

### Fixed — Track I: persona-based onboarding runbooks + agent next-actions (#1360, PR #1364)

`docs/onboarding/{first-install,create-static-agent,plugin-enabled-agent,troubleshooting-auth-and-channels}.md` give first-installer / static-agent-creator / plugin-agent personas a short action-oriented route. `agb agent show` gains a `next_actions` section (missing channel creds → setup, missing plugin seed, broken session → dry-run); `agent create` completion is engine/channel/isolation-persona-aware. CLAUDE.md scoped back to the contributor contract. No site-specific secrets in public docs.

### Fixed — Track J: shared-mode agents fall through to HOME for session detect (#1370, PR #1372) — beta5-2 #1316 regression

`bridge_resolve_agent_claude_config_dir` now gates on `bridge_agent_linux_user_isolation_effective`: shared-mode agents (incl. admin) and every agent on non-Linux hosts fall through to empty so `--continue` session-id detect uses the controller HOME `~/.claude` (the #1073 design intent). beta5-2 Lane θ #1316 (.claude dir-tree normalize) had scaffolded an empty `<agent-home>/.claude` that passed the `-d` guard, sending detect to an empty tree → empty session-id → `bridge-start.sh` `set -e` silent exit → admin always-on auto-restart failure. The stale `1015-resume-claude-config-dir` smoke T7/T8 was re-modeled iso-effective with shared-mode negative controls. Originally authored by patch@hoon-mac (cross-fork PR #1371), absorbed here with the required smoke update.

### Fixed — Track K: shared-mode codex pair PATH — daemon engine resolver (#1352, PR #1377)

Auto-provisioned shared-mode codex pairs (e.g. `<admin>-dev`) on nvm/pyenv/volta/asdf user-local Node no longer die `codex: command not found` (exit 127 → circuit-breaker → escalation flood). Root: beta5-2's `bridge_augment_engine_path` resolver gated its nvm branch entirely on `$NVM_DIR` (never exported by a systemd-user non-login daemon) with no `$HOME/.nvm` fallback. Fix unifies the shared launch codepath (`bridge-run.sh`) with the resolver, derives the nvm root from `$NVM_DIR` OR `$HOME/.nvm`, adds a volta branch, and selects the version bin dir semver-aware (`sort -V`) AND engine-presence-verified (`bridge_dir_has_engine_cli`: default-if-engine → highest-semver-with-engine → graceful no-op) so a multi-version install never prepends a stale or engine-less dir. iso sudo-wrap PATH unchanged.

### Fixed — Track L: write_agent_state_marker A0-derive + Path B best-effort (#1342, PR #1376)

iso v2 agent stop no longer logs `ensure_matrix_path failed … marker=idle-since` on every stop. The Stop hook runs inside the iso UID but both fast paths gated on the roster-resolved `os_user`; when empty/indeterminate (#1048) they fell through to a Path B chown the iso UID cannot do. `bridge_isolation_v2_write_agent_state_marker` now derives the expected iso UID from the agent name (matching `matrix_rows_for_agent` / the Track J fallback) when the roster lookup is empty, and Path B distinguishes privileged genuine-drift (hard-fail, preserved) from unprivileged best-effort (idle marker is best-effort: direct write + chmod stay authoritative). #1165 Gap 6 completion; Track A/J in `bridge-state.sh` untouched (different file).

### Fixed — Track M: MS365 refresh_token resilient auto-refresh (#1343, PR #1375) — SECURITY

MS365 OAuth no longer outages ~1h after setup. Auto-refresh was partially wired; the real causes were its failure modes: a concurrent-refresh race clobbered the rotating refresh_token, transient and permanent failures were indistinguishable, and there was zero audit. Fix adds per-UPN single-flight, transient/permanent classification (keep-and-retry on transient; `token_expired` marker + actionable re-auth on permanent), and redacted `ms365_token_refreshed`/`ms365_refresh_failed` audit. The redaction was hardened beyond codex pair-review through two read-only adversarial sweeps: a deep `redactResponseBody` (key-layer + value-shape `scrubSecretShapedText`) is the single choke-point from any response/resource body to any sink (audit + thrown + pair_poll textResult + status marker + graph helper); the `_raw` non-JSON envelope is summarized to `{_raw_len,_raw_sha256}`; the top-level OAuth `error` field is scrubbed everywhere `error_description` is. Live token persistence stays verbatim (no over-redaction); honest OAuth codes / AADSTS / GUID / state / nonce round-trip. TokenFile schema + `.env` vars unchanged (no Track CD drift); token files 0600.

### CI housekeeping (PR #1373)

bridge-daemon.sh footgun #11 ×3 (Track H staging-row/result/swept JSON parsers) extracted to `lib/cron-helpers/staging.py` `parse-row`/`parse-result`/`parse-swept` file-as-argv subcommands (output byte-identical). raw-pathlib drift resolved by `_safe_path_check` wrap + noqa (ceiling held at 0, no baseline bump). iso-helper + lint-heredoc baselines re-synced.

### Known carry-over

- β-1231-1236-fresh-install-seed-sudoers T5: `daemon_group_refresh_sudoers=missing` printed to stderr where the smoke expects stdout (bridge-init.sh) — inherited, beta-cycle informational, follow-up.
- #1367 (admin sealed-paste `agb auth claude-token receive`) — Track F root, deferred.
- #1353 root (`awaiting_channel_setup` state machine for Track A) — deferred.

## [0.15.0-beta5-2] — 2026-05-28

### Highlight — beta5-1 patch-verify wave (6 lanes ι/κ/λ/μ/ν/ξ, 28 issues) + CI housekeeping

Patch's beta5-1 OOTB verify surfaced 26+2 follow-up defects spanning daemon escalation, state audit, A2A, cron+channel creds, daemon PATH+quarantine, and Teams/agent-id propagation. Sean directive: "전부다 수정해서 새로 베타 5-2 릴리즈" (fix all, not subset). Wave-orchestration parallel dispatch (6 lanes), 18+ codex review rounds (r1→r3 chains, 5-round-cap respected). 6 lanes implement-ok, merged in dep-graph order (ν → κ rebases inside ν's quarantined==0 gate, then ι/λ/μ/ξ).

Bundled: PR #1350 CI housekeeping (baseline ratchet absorption + 4 smoke design-bug fixes — 9 amend rounds). Long-standing pre-existing debt in heredoc/iso-helper/raw-pathlib baselines + 1115/1121/1140/1207/1209/H-bootstrap smokes that the unit/static gate had not actually run since the beta cycle began (oss-preflight/heredoc gates had been SKIPping smoke for the entire stabilization period). Per [[feedback-fresh-install-acceptance-gate]] the real acceptance gate is patch's fresh-install VM verify; smoke gate is informational during beta cycles.

Lane → PR map: ι #1344 / κ #1345 / λ #1346 / μ #1347 / ν #1348 / ξ #1349 / housekeeping #1350.

### Fixed — Lane ι daemon escalation family (#1320 + #1321 + #1322 + #1323 + #1318-B, PR #1344)

bridge_notify_send H3 embed (option A — H3 logic moved INSIDE bridge_notify_send so all 8 production call sites benefit without per-site renames). Wrapper bridge_notify_send_with_miss_queue removed. 3 heredoc-stdin sites extracted file-as-argv to `lib/daemon-helpers/mcp-miss-queue-enqueue.py`, `mcp-miss-queue-drain-parse.py`, `unclaimed-task-filter.py`. Smoke T3d drives production path (real bridge_notify_send + stubbed bridge_notify_python). bridge-daemon.sh heredoc ceiling 0/0 restored.

### Fixed — Lane κ activity_state picker_blocked exclusion (#1319 + #1324 + #1325, PR #1345)

`bridge_write_agent_snapshot` now emits `activity_state` column (picker_blocked computed via stall.env grep). `bridge-queue.py` `daemon-step` excludes `{picker_blocked, working}` from `idle_agents` set + stale-claim requeue skips non-idle/non-inactive — previously picker_blocked agents were wrongly classified as idle and had their claimed tasks requeued. Backwards-compat preserved via `.get("activity_state", "")` default on legacy 9-column snapshots. T8 functional / T9 teeth / T10 back-compat. After Lane ν merged, κ rebased so picker_blocked branch lives inside ν's `quarantined == 0` gate (quarantine wins over picker_blocked).

### Fixed — Lane λ A2A HMAC-first auth order (#1326 + #1331, PR #1346) — SECURITY

`bridge-handoffd.py` drift-band timestamp classification returned 503 BEFORE HMAC signature verification → forged signature with drift-band timestamp would return 503 transient → sender retries with bad sig (auth fail-open). Reordered `do_POST`: `a2a.verify_signature()` runs immediately after body-hash check, BEFORE timestamp band classification. Bad sig (any timestamp) → 401. Valid sig + drift band → 503 + Retry-After. Valid sig + beyond grace → 401 (replay defense intact). Empty `X-AGB-Signature` → 401. `hmac.compare_digest` preserved (constant-time). T1b/T1c/T1d/T1e + teeth (17/17 smoke, 11/11 a2a regression).

### Fixed — Lane μ cron skip manual-stop + state preserve + channel cred iso readable (#1327 + #1328 + #1329, PR #1347) — SECURITY

`bridge-setup.py:_post_write_normalize_channel_cred_group` — 3 strict gates: (1) `_iso_v2_effective_host()` non-iso skip; (2) `grp.getgrnam(group)` check before mutation, KeyError → audit-skip; (3) chgrp returncode gated → chmod 0640 ONLY after chgrp landed `ab-agent-<a>` successfully. Closes a security gap where chmod 0640 ran unconditionally after `chgrp` failure, widening secrets to controller primary group on non-iso-v2 hosts (direct repro: cred 0600 → AFTER 0640 group=staff). T6b/T6c/T_teeth.r2.

### Fixed — Lane ν daemon PATH + quarantine UX + engine preflight + skills setpriv (#1317 + #1333, PR #1348)

`bridge_write_roster_status_snapshot` now sets `activity_state=quarantine-broken-launch` when `state/agents/<a>/broken-launch` marker present (was only wired into bridge-agent.sh list/show before — agb status + cron readiness couldn't see quarantined no-tmux agents). Quarantine short-circuit at TOP of activity_state computation; active-branch override (idle/working/starting) gated behind `quarantined == 0`. Lane κ's picker_blocked block lands inside this gate after rebase. T6a/T6b/T6c/T6d.

### Fixed — Lane ξ BRIDGE_AGENT_ID propagation + CLAUDE.md atomic + FORCE_FRESH order + task create on stopped agent (#1330 + #1332 + #1334 + #1318-A, PR #1349)

`bridge-start.sh:864-893` inlines `BRIDGE_AGENT_ID` into `SESSION_CMD` so Teams MCP at `plugins/teams/server.ts:2782-2802` sees it populated (was unset → PreCompact lookup fail). `bridge-run.sh:136-142` exports BRIDGE_AGENT_ID before roster load. FORCE_FRESH order aligned at `bridge-start.sh:609-652`. CLAUDE.md atomic materialization at `lib/bridge-agent-layout.sh:255-288` via `bridge_isolation_v2_chgrp_file_iso_group`. `bridge-task.sh:383-454` stopped-target guard + self-target exemption + --force flag + audit. 3 daemon target_bridge sites at `bridge-daemon.sh:1530-1537, 2452-2458, 4537-4543` use --force.

### CI housekeeping (PR #1350)

Mechanical baseline absorption + smoke design-bug fixes:
- `.lint-heredoc-baseline.tsv` — +25 sites / -7 stale entries (beta3-5 wave smoke shims, no footgun #11 sites)
- `scripts/baselines/iso-helper-baseline.txt` — 122 boundary callsites absorbed (#857 follow-up tracks migration)
- `scripts/baselines/raw-pathlib-baseline.txt` — +18 sites
- `scripts/smoke/C-beta4-logger-and-spec.sh` — `smoke@example.invalid` → `smoke@example.com` (preflight allowlist)
- `scripts/smoke/1121-agent-delete-os-purge.sh` + `1140-purge-home-os-cleanup.sh` — sudo shim (CI passwordless-sudo was bypassing rm shim, masking warn assertion)
- `agent-bridge` + `1115-cli-usage-drift.sh` — `iso-run` added to `_top_valid` array + TEMPLATE_ONLY_HIDDEN_TOPLEVEL pin
- `1207-stale-supp-groups-allowlist.sh` + `1209-ms365-redirect-resolver.sh` — iso-v2 env envelope (BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT)
- `H-bootstrap-memory-iso-rebuild.sh` — `chmod o+x SMOKE_TMP_ROOT` for iso UID traversal + fail-loud fixture-touch

## [0.15.0-beta5-1] — 2026-05-28

### Highlight — beta5 patch-verify hotfix (3 lanes, 3 issues)

Patch's beta5 OOTB verify on `cm-prod-agentworkflow-vm01` (post v0.15.0-beta5 upgrade) surfaced 3 follow-up issues. Sean directive: ship as beta5-1 hotfix. Lane parallel dispatch, codex r1-r2 convergence per lane, ~2h wall-clock issue-file → merge. All 3 merged + 17/18 lane smokes PASS under bash 5.3.9 (G-beta4-watchdog-noise T3 pre-existing macOS umask). `-beta5-1` prerelease, tag `v0.15.0-beta5-1`, GitHub release marked **Pre-release**.

Lane → PR map: 1 #1305 / 2 #1308 / 3 #1309.

### Fixed — session_id detect race + empty-overwrite under per-agent session lock (#1304, Lane 1 PR #1305)

beta5 Lane β PR #1300 wrapped `detect-claude-session-id.py` in iso UID sudo, but two residual bugs remained: (A) `os_user` not propagated to ALL detect call sites — some daemon ticks went through non-sudo path → `detect_empty`; (B) empty detect result silently overwrote a previously-successful persisted session_id. Patch's direct repro at cm-prod 20:08 UTC: PID 2830345 sudo-path SUCCESS (`session_id_persisted 54f1742e`); 11s later PID 2838856 non-sudo → `detect_empty` → empty value persisted → CLOBBERED 54f1742e. End state: `history.env AGENT_SESSION_ID=''`.

- **Caller audit verdict**: all 3 production callers (`lib/bridge-state.sh:256` / `:3831-3837`, `bridge-sync.sh:146-152`) already thread `_iso_sudo_user`. Added `BRIDGE_TEST_TRACE_DETECT_CALLERS=1` env var to prove this on demand (stderr `[detect-trace] fn=<helper> caller=<fn> os_user=<value>`).
- **Empty-detect guard under per-agent session lock (r2 root)**: `bridge_persist_agent_state` now wraps empty-detect guard + write under `bridge_agent_session_lock_file` (flock -w 30 + mkdir fallback for non-flock hosts). Re-read of `bridge_agent_persisted_session_id` happens INSIDE the lock. If sibling PID won the race, rehydrate in-memory map + skip persist + audit `session_id_detect_empty_persist_skipped reason=interleave_caught_under_lock`. `bridge_clear_persisted_session_id` (forget-session) shares the same lock.
- **Explicit-clear bypass**: `BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1` for `bridge_clear_agent_session_id` (forget-session / resolver rc=1).
- Smoke: `scripts/smoke/beta5-1-session-id-detect-race.sh` T1-T8 + T_interleave_under_lock + T_lock_contention.

### Fixed — dev-channel auto-accept on --no-attach daemon recovery path (#1306, Lane 2 PR #1308)

After `agent-bridge upgrade --apply`, daemon auto-recovered iso v2 agents via `--no-attach`. Claude showed `--dangerously-load-development-channels` picker. `bridge-start.sh` logged "controller-side auto-accept armed" but the actual `1\r` was NEVER sent to tmux. 23-minute hang observed at cm-prod, only resolved by manual `tmux send-keys`.

- **Root cause**: controller-side picker's attach/foreground gate prevented key send when no tmux client attached. Daemon `--no-attach` recovery → no client → gate blocked.
- **`bridge-start.sh`** — direct-send branch added to `bridge_start_schedule_dev_channels_accept`. Picker auto-accept now fires on tmux-session-exists + picker-text-detected. NO attach gate. (Option A per [[feedback-root-vs-symptom-framing]] — gate removal, not timeout extension.)
- Smoke: `scripts/smoke/dev-channel-auto-accept-no-attach.sh` T1-T4 + teeth (re-add attach gate → key NOT sent + attached-mode back-compat + non-dev-channel no-overhead).

### Fixed — plugin_mcp_liveness_giveup auto-clear on agent recovery (#1307, Lane 3 PR #1309)

`plugin_mcp_liveness_giveup` was sticky. After 5 restart failures, daemon stopped Teams channel wake attempts and never auto-reset when agent recovered. Cm-prod timeline: picker block (#1306) → 5 liveness restart fails → giveup → 23 min manual unblock → agent `activity_state: idle` → BUT `notify_status: miss` persisted indefinitely → Sean's Teams messages undelivered 5+ min.

- **`bridge-daemon.sh`** — 6 new helpers (`bridge_agent_mcp_giveup_arm/active/ts/clear/note_activity_state`, `bridge_recheck_mcp_liveness`) + `process_mcp_liveness_giveup_recovery` tick step.
- **Two-layer defense (r2 root)**:
  1. Daemon main-loop reorder: `process_mcp_liveness_giveup_recovery` BEFORE `process_plugin_liveness`. Recovery emits `plugin_mcp_liveness_recovered` audit + clears giveup ledger BEFORE the existing silent-clear path can wipe it.
  2. `bridge_clear_plugin_liveness_state_if_no_giveup` helper wraps 5 silent-clear sites — preserves giveup keys when active, lets recovery tick process them.
- **Triggers**: (B) `activity_state` transition non-idle → idle observer (primary) + (A) `BRIDGE_MCP_LIVENESS_GIVEUP_FALLBACK_SECS` (default 300s = 5min) timer for missed transitions (defense-in-depth).
- Smoke: `scripts/smoke/mcp-liveness-giveup-auto-clear.sh` T1-T5 + T_production_order + 2 teeth cases (guard-alone-sufficient + both-reverted-audit-missing).

### Notes

- **Convergence rounds**: Lane 1 r1→r2 (codex r1 BLOCKING: guard not under lock — interleaving race); Lane 2 r1 (smoke bash hardcode portability — caught BEFORE merge by codex r1); Lane 3 r1→r2 (codex r1 BLOCKING: production ordering bypass + smoke gap). Each lane required orchestrator-driven rebase at merge time (Lane 1 + Lane 2 dropped each other's cross-contamination; Lane 3 dropped Lane 1+2's).
- **Worktree shared-stash footgun ([[feedback-worktree-stash-shared-git-dir]])** hit 4 more times this loop (Lane 2 fixer, Lane 3 R1 fixer, Lane 3 R2 fixer + orchestrator's automated python regex itself partially failed during Lane 3 rebase). Pattern is durable enough that future fixer briefs include explicit "DO NOT USE `git stash`" callout.
- **A2A patch verify** pending. Acceptance: post-upgrade iso v2 agent reaches ready state without manual tmux intervention, session_id persists across 60s daemon-tick window, Teams messages delivered after activity_state transitions to idle.

## [0.15.0-beta5] — 2026-05-28

### Highlight — beta4 patch-verify follow-up (3 lanes, 3 issues)

Patch's beta4 OOTB verify on `cm-prod-agentworkflow-vm01` surfaced 3 follow-up issues (#1297 / #1298 / #1299). Lane parallel dispatch, ~2 codex review rounds per lane, ~30 min wall-clock from issue file to merge. All 3 merged + 18/18 lane smokes PASS (3 beta5 + 11 beta4 + 4 beta3) under bash 5.3.9. `-beta5` prerelease, tag `v0.15.0-beta5`, GitHub release marked **Pre-release**.

Lane → PR map: α #1302 / β #1300 / γ #1301.

### Fixed — beta3→beta4 upgrade backfill iso v2 workdir profile group normalize (#1297, Lane α PR #1302)

`agent-bridge upgrade --apply` left existing beta3 workdir profile files (`CLAUDE.md`, `SOUL.md`, etc.) at `0600 iso-uid:controller-gid`. Controller couldn't grep CLAUDE.md → `agent restart` failed + rollback also failed → agent stopped. Lane G PR #1291 (#1270, beta4) introduced `bridge_isolation_v2_normalize_workdir_profile_group` but only fired on `agent create`, not upgrade backfill.

- **`lib/bridge-isolation-v2-workdir-backfill.sh`** — normalize runs unconditionally per iso v2 agent on every backfill pass.
- **`lib/bridge-isolation-v2.sh`** R2 — `bridge_isolation_v2_chgrp_file_iso_group` adds portable stat-skip (GNU `stat -c '%G:%a'` / BSD `stat -f '%Sg:%Lp'`) so already-correct files are no-op. Empty stat falls through to mutation path. Owner intentionally unchecked (helper normalizes group+mode only).
- Smoke: `scripts/smoke/α-beta5-upgrade-backfill-normalize.sh` T1-T4 + `T_idempotent_no_mutation_on_correct` (override counter on `_bridge_isolation_v2_run_root_or_sudo`; assert 0 invocations on already-correct files).

### Fixed — iso v2 session_id detect controller-can't-read 0600 jsonl (#1299, Lane β PR #1300)

beta4 Lane A PR #1286 (#1277) fixed path resolution to iso UID's `/home/agent-bridge-<a>/.claude/`. But Claude Code wrote session jsonl as `0600 iso-uid:ab-agent-<a>`. Controller (`awfmanager`) was in `ab-agent-<a>` group but `0600` has no group-read bit → `detect-claude-session-id.py` returned empty → no session resume on iso v2.

Per [[feedback-root-vs-symptom-framing]]: do NOT relax jsonl mode; elevate the reader instead.

- **`lib/bridge-agents.sh`** — new `bridge_linux_sudo_as_user` + `bridge_resolve_agent_iso_sudo_user` helpers.
- **`lib/bridge-state.sh`** — `bridge_detect_claude_session_id` 5th arg `os_user`, `bridge_resolve_resume_session_id` self-resolves + wraps, `bridge_detect_session_id` 6th-arg passthrough. 2 caller updates: `bridge_claude_resume_session_id_for_agent`, `bridge_refresh_agent_session_id`.
- **`bridge-sync.sh`** — `refresh_missing_session_ids` passes os_user.
- Sudo wrap shape: `sudo -n -u <iso-uid> bash -c 'exec python3 "$@"' bash <args>` to satisfy `bridge_migration_sudoers_entry` template ("tmux + bash only; Python spawned as a child of bash -c").
- Smoke: `scripts/smoke/Beta-beta5-session-id-detect-sudo.sh` T1-T10 + R2 portable `SMOKE_BASH_BIN` resolver (works on ubuntu-latest CI, macOS Homebrew bash 5.3.9, and macOS `/bin/bash` 3.2 re-exec).

### Fixed — upgrade reconcile structured helper status + manual mode parity (#1298, Lane γ PR #1301)

`agent-bridge upgrade --apply` iso-reconcile logged 4 `[failed]` rows per iso v2 agent ("helper emitted no status line for ..."). Conflated 3 distinct conditions (path missing / permission denied / helper error) into a single `failed` signal. Manual `agent-bridge isolation reconcile --apply` skipped agent-home-contract → false-OK.

- **`lib/bridge-agents.sh`** — `bridge_linux_normalize_isolated_home_contract` emits structured per-target status lines (`denied`/`error`) at every early-return path. Symlink + non-dir targets emit `error` (not `failed` — that's reserved for genuine apply-time failures: mkdir/chown/chmod refused).
- **`lib/bridge-isolation-v2-reconcile.sh`** R2/R3 — classifier distinguishes:
  - `missing` → `MISSING`/rc=1 (drift)
  - `denied`/`error` → `DEGRADED`/rc=0 (probe failure, WARN, NOT drift)
  - `failed` → `FAILED`/rc=1 (legitimate apply failure)
  - Apply-mode symlink preempt removed (helper is single source of truth).
  - Check-mode: symlink + exists-but-not-dir → `DEGRADED`/rc=0; genuinely-absent → `MISSING`/rc=1.
- **Manual mode parity** — `bridge_isolation_v2_apply_install_tree_matrix` with `reason=manual` + no `--agent` + no `--all-agents` ⇒ implicit `--all-agents`. Operator-driven manual reconcile now checks agent-home-contract by default (Option 2a).
- Smoke: `scripts/smoke/gamma-beta5-reconcile-helper-status.sh` T1-T11 + 5 teeth (helper revert / preempt resurrect / r2-shape regression). Real fixture coverage: symlink target (T8) + regular-file target (T9) + check-mode regular-file (T11).

### Notes

- Convergence rounds: Lane α (r1→r2, codex 2 rounds + orchestrator rebase); Lane β (r1→r2, codex 2 rounds — bash hardcode portability); Lane γ (r1→r2→r3, codex 3 rounds — symlink/non-dir contract + check-mode parity + orchestrator rebase).
- Wave-orchestration parallel dispatch hit the `.git/refs/stash` shared-state footgun mid-wave ([[feedback-worktree-stash-shared-git-dir]]): Lane β's WIP was visible to Lane α + Lane γ worktrees. Both fixers correctly recovered (Lane α restored polluted files + re-applied only own delta; Lane β recovered via `git fsck --lost-found`). Lane γ + Lane α both required orchestrator-driven rebase to drop Lane β cross-contamination revert at merge time.
- Patch reported manual workaround applied for #1297 on `cm-prod-agentworkflow-vm01`. beta5 closes the regression — upgrade backfill normalize on next `agent-bridge upgrade --apply`.

## [0.15.0-beta4] — 2026-05-28

### Highlight — Full backlog closure, 11 lanes / 3 sub-waves, 30 issues

Operator-cued autonomous beta loop directive 2026-05-27: "베타 4를 위해서 싹다 제대로 수정하자. 웨이브 스킬 사용해서 멀티 에이전트로 빠르게 처리 해줘." Wave-orchestration skill applied: 11 parallel lanes across 3 sub-waves, 30 issues closed (wave plan named 28; Lane H also closes cross-check pair #1208 + #1215 with full fixes for the lock-file ownership + .ms365 directory mode), ~28 codex review rounds total, plus integration review + QA gate (15/15 lane smokes PASS under bash 5.3.9). `-beta4` prerelease, tag `v0.15.0-beta4`, GitHub release marked **Pre-release**.

Lane → PR map: A #1286 / B #1285 / C #1284 / D #1287 / E #1288 / F #1290 / G #1291 / H #1289 / I #1292 / J #1293 / K #1294, plus integration fix-up #1295.

### Fixed — iso v2 path resolution + sanitized metadata access root (#1272 + #1277 + #1279 + #1213, Lane A PR #1286)

Path A0 of iso v2 metadata access was broken on Lane A: `session_id` capture wrote to controller's `~/.claude/...` instead of iso UID's home, `audit.jsonl` was emitted empty when controller couldn't traverse iso workdir, and `BRIDGE_AGENT_ISOLATION_MODE` scalar export silently failed (assoc array collision with same name).

- **`bridge-lib.sh`** — new `bridge_load_sanitized_agent_metadata` reads `state/agents/<a>/agent-meta.env` (0640 group=ab-agent-<a>, NO secrets) with iso-UID-scoped prefix guard + 2-stage user-match (snippet peek `BRIDGE_AGENT_OS_USER` + `id -un` compare, prefix-independent).
- **`lib/bridge-agents.sh`** — `bridge_agent_claude_config_dir` returns iso UID's home via `getent passwd <iso-uid> | cut -d: -f6` on Linux iso v2 agents; same getent-based resolver in `bridge_agent_os_user` / `bridge_agent_default_os_user` (honor `--os-user` override).
- **`lib/bridge-state.sh`** — `bridge_agent_audit_dir` analog resolver; canonical resolver shared with `bridge_agent_state_dir_self_heal`.
- **`lib/bridge-isolation-v2.sh`** — sanitized metadata write site on `agent create` + reapply paths; mode `2770`/`0640` enforced.
- **`bridge-init.sh`** — install-time scaffold for sanitized metadata snippet.
- Smoke: `scripts/smoke/A-beta4-iso-path-resolution.sh` T1-T_canonical + 2-stage user-match teeth + R4 audit_dir_ensure + R5 session_id_detect_empty audit emit.

### Added — teams + ms365 interactive setup wizard with reachability probes (#1268 + #1271, Lane B PR #1285)

`agent-bridge channel setup` for `plugin:teams` / `plugin:ms365` was a manual edit of `.teams/.env` or `.ms365/.env`. R3 added an interactive wizard that drives the operator through the same fields PLUS three reachability probes (teams local-bind, teams messaging endpoint, ms365 redirect) with die-by-default on probe failure and `--allow-probe-failure` escape hatch.

- **`lib/bridge-setup-wizard.sh`** (new) — `bridge_setup_wizard_teams` / `bridge_setup_wizard_ms365` interactive flows.
- **`bridge-init.sh`** — wizard invocation on `agent create --channels plugin:teams,plugin:ms365` opt-in.
- Smoke: `scripts/smoke/B-beta4-setup-wizard.sh` T1-T10 + probe-failure teeth.

### Fixed — bridge_info → stderr + manifest spec `plugin:` prefix strip + restart preflight (#1273 + #1274, Lane C PR #1284)

`bridge_info` log lines were leaking into stdout, polluting `--json` callers. Manifest spec parsing didn't strip the `plugin:` prefix so identity comparison missed for `--channels plugin:teams` vs `teams`. `agent restart` preflight didn't verify channel manifest spec consistency before stop+start, leaving a stale-config window.

- **`lib/bridge-core.sh`** — `bridge_info` routes to stderr unconditionally (was stdout when `BRIDGE_VERBOSE=1`).
- **`lib/bridge-plugins.sh`** + **`scripts/python-helpers/claude-plugin-manifest-has-spec.py`** — strip `plugin:` prefix before identity match.
- **`lib/bridge-agents.sh`** — `agent restart` preflight now diffs sanitized manifest before stop; rolls back on drift.
- Smoke: `scripts/smoke/C-beta4-logger-and-spec.sh` T1-T7 + caller-align over R1 manifest migration.

### Fixed — daemon singleton spawn guard via `flock` + atomic PID + audit emit (#1276, Lane D PR #1287)

Two daemons could race-spawn on a fresh-install first-wake with no existing PID file; `daemon-already-running` check raced against the PID write.

- **`lib/bridge-daemon-control.sh`** — `bridge_daemon_ensure_singleton` uses `flock -n` (non-blocking) on lifetime-hold lock; atomic PID write under lock; emits `daemon_started` audit row with the new lock-acquisition decision evidence. Fail-closed: if flock returns busy AND existing PID is alive, abort with structured stderr + bridge-task admin alert.
- **`bridge-daemon.sh`** — entry-point invocations of singleton guard wired in.
- Smoke: `scripts/smoke/D-beta4-daemon-lifecycle.sh` T1-T7 including T2b race-window cover + T2c alert-task creation.

### Fixed — fresh-install first-wake reconcile gate + daemon wake state-dir self-heal (#1265 + #1269, Lane E PR #1288)

`agent-bridge` fresh-install first wake on iso v2 hit Lane A3's reconcile gate (no `state/agents/<a>/launch.history` → continue=1 + session_id empty → `bridge_die` "session-id missing"), even though the agent had never been launched. Also: daemon's three wake sites lacked `bridge_agent_state_dir_self_heal` calls so a fresh-install always-on agent spun on `start-command-failed`.

- **`bridge-run.sh`** (R1 + R2 + R3) — fresh-state branch: `launch.history` absent → fresh state → proceed without `--resume`, info log, audit emit, touch marker. R3 canonical path: `_gate_launch_history="$(bridge_agent_idle_marker_dir "$AGENT")/launch.history"` — same helper as `bridge_agent_state_dir_self_heal` (canonical `BRIDGE_STATE_DIR` per-agent, not hardcoded `BRIDGE_HOME/state`).
- **`bridge-daemon.sh`** — three wake sites wired `bridge_agent_state_dir_self_heal` (`always_on_wake`, `on_demand_wake`, `cron_dispatch_wake`); per-site `trigger=` audit-detail markers.
- Smoke: `scripts/smoke/E-beta4-fresh-install-gate-state-dir.sh` 9 tests including T_state_dir_relocated (`BRIDGE_HOME` ≠ `BRIDGE_STATE_DIR`) + T_dry_run_seq production real-launch invocation (engine=shell + LAUNCH_CMD=true).

### Fixed — OAuth controller-fallback aliveness propagation + sudoers glob + bootstrap JSON-to-stderr (#1261 + #1228 + #1230, Lane F PR #1290)

`agent-bridge auth status` aliveness was invisible (wrapper discarded helper stdout); install-daemon-systemd's `probe_sudo_self_refresh` checked the wrong command shape (no `-u $controller_user` runas → didn't mirror the sudoers template's `({{controller_user}})` runas or the rendered ExecStart's `-u $CONTROLLER_USER -H`); `bridge-bootstrap.sh` printed `[init]` info to stdout causing `bridge-init.sh --json` to fail JSON parse.

- **`bridge-auth.py`** — schema migrated `alive/near-expiry` → `fresh/near_expiry`; full JSON propagation.
- **`bridge-auth.sh`** — wrapper forwards JSON instead of swallowing.
- **`scripts/install-daemon-systemd.sh`** (R2 + R3) — `probe_sudo_self_refresh` uses `sudo -n -u "$controller_user" -ln` mirroring sudoers + ExecStart. `BRIDGE_INSTALL_DAEMON_TEST_SUDO_PROBE_JSON` deterministic test seam (file-as-argv per footgun #11).
- **`bridge-init.sh`** + **`bridge-bootstrap.sh`** — `[init]` / OAT advisory log lines routed to stderr; JSON contract holds end-to-end.
- Smoke: `scripts/smoke/F-beta4-oauth-bootstrap.sh` T1-T12 + T_probe_runas_mismatch_fallback + T_probe_runas_match_sudo_self + T_execstart_runas_grep + teeth.

### Fixed — watchdog quiet-by-default + scan_error iso UID readability probe + CLAUDE.md group fix (#1266 + #1270 + #1254, Lane G PR #1291)

`bridge-watchdog.py:detect_fresh_install` returned `fresh_install=True` permanently after admin's `onboarding-pending` marker existed (no completion writer; no age window). `_scan_error_category` misclassified workdir/file permission corruption as `controller-cache-stale`. `lib/bridge-isolation-v2.sh` set up CLAUDE.md with wrong group on iso v2 admin paths.

- **`bridge-watchdog.py`** (R2 + R3) — `detect_fresh_install` 3-stage precedence: `onboarding-complete` marker > SESSION-TYPE.md "complete" > `onboarding-pending` marker + 24h TTL. R3 Option A: home-mtime fallthrough removed entirely → quiet-by-default ("fresh install" requires explicit positive signal). `_scan_error_category` runs iso UID readability probe (`sudo -n -u <iso-user> -- test -r <path>` via canonical `bridge_iso_paths.sudo_run_as`) → split `controller-cache-stale` (iso readable, controller not) vs `iso-uid-side` (iso also can't read).
- **`bridge-init.sh`** — `bridge_init_write_onboarding_complete_marker` + `bridge_init_remove_onboarding_pending_marker` (mode 0600, schema agent/written/reason).
- **`lib/bridge-isolation-v2.sh`** — `bridge_isolation_v2_normalize_workdir_profile_group` enforces CLAUDE.md group=ab-agent-<a> mode 0660.
- Smoke: `scripts/smoke/G-beta4-watchdog-noise.sh` 10 tests + T_no_marker_no_session_recent_home + T_malformed_pending (Cases A-G coverage) + T6/T6b 3-way scan_error split.

### Fixed — iso v2 ownership audit script + known_marketplaces.json ownership (#1278 + #1208 + #1215, Lane H PR #1289)

First boot abort on Linux iso v2 fresh install was masked by a silent retry; root cause was `known_marketplaces.json` seeded root:640 instead of `agent-bridge-<a>:ab-agent-<a> 0660`. Also surfaced: `known_marketplaces.json.lock` root:600 ownership gap, `.ms365` directory missing exec bit.

- **`lib/bridge-isolation-v2.sh`** + **`bridge-plugins.sh`** — chown after seed; lock file ownership; `.ms365` dir mode 2770.
- **`scripts/audit/iso-v2-ownership-audit.sh`** (new, R3 hardened) — workdir-root triple-check (owner+group+mode 2770/2750) + canonical `bridge_agent_workdir` resolver + `.env` triple-check (owner+group+mode 0600) + `bridge_reset_roster_maps` call (closes pre-existing assoc-array no-op bug) + `BRIDGE_AUDIT_TEST_FORCE_LINUX` seam for macOS smoke hosts.
- Smoke: `scripts/smoke/H-beta4-iso-ownership.sh` T1-T_canonical + T_audit_executes_against_bad_fixture + teeth.

### Fixed — A2A 3 gaps: systemd template + outbox retry verify + stuck alert ack-after-success (#1262, Lane I PR #1292)

A2A cross-bridge had three gaps preventing first-class operator use on fresh installs: handoff daemon systemd unit was manual-install; outbox retry semantics were intact (per beta22 commit 06b84c1) but unverified; outbox stuck rows had no admin alert path.

- **Gap 1**: `bridge-init.sh --enable-a2a` flag + `bridge_init_scaffold_a2a` helper + new `scripts/install-handoffd-systemd.sh` renders systemd-user unit; bootstrap advisory prints `systemctl enable --now agb-handoffd` activation guidance.
- **Gap 2**: smoke T3/T4 pin retry primitive (exponential backoff verified).
- **Gap 3** (R2 + R3): `bridge-daemon-helpers.py` split `cmd_a2a_stuck_decide` (pure read) vs new `cmd_a2a_stuck_ack` (atomic ledger stamp). `bridge-daemon.sh::process_a2a_outbox_stuck_scan_tick` calls `a2a-stuck-ack` ONLY for successful `task create` rows — failed creates preserve ledger for next-scan re-emit. R3 smoke driver `scripts/smoke/I-beta4-helpers/run-stuck-scan-tick.sh` extracts function body verbatim from `bridge-daemon.sh` via `awk`, mocks `$BRIDGE_HOME/agent-bridge` rc=1 then rc=0 → asserts warning + ledger unstamped → next scan stamps.
- Smoke: `scripts/smoke/I-beta4-a2a-3-gaps.sh` T1-T6 + T_stuck_task_create_failure_preserves_ledger + T_daemon_scan_tick_handles_create_failure + teeth.

### Fixed — workflow + iso v2 docs + release downgrade audit + wiki-graph default-off (#1280 + #1281 + #1267 + #1263, Lane J PR #1293)

Iso UID couldn't read controller-owned 0600 body file when called via `agb a2a send --body-file`. Docs (CLAUDE.md / developer-handover / OPERATIONS.md) lacked iso v2 agent constraint section. Daemon emitted release-downgrade notification redundantly when `installed >= target`. Wiki-graph + librarian default-on caused unexpected automation on fresh installs.

- **`bridge-queue.py`** + **`bridge-a2a.py`** (R2 + R3) — `_sudo_read_body_file` / `_sudo_read_text` sudo-wrap body file read; emit `body_file_sudo_fallback` audit row with canonical schema (`iso_uid` field, `exception` + `exception_type` when applicable).
- **`bridge-release.py`** + **`bridge-daemon-helpers.py`** (R3) — full SemVer 2.0.0 prerelease comparator with undotted normalization (`betaN`→`beta.N`, `rcN`→`rc.N`); installed-prerelease vs latest-stable same-core upgrade detected correctly; `release_notification_downgrade_skip` audit row emitted only for true downgrades.
- **`CLAUDE.md`** + **`docs/developer-handover.md`** + **`OPERATIONS.md`** — "Working with isolated agents (iso v2)" section in all three.
- **`bootstrap-memory-system.sh`** + **`bridge-bootstrap.sh`** — `BRIDGE_WIKI_GRAPH_ENABLED` gate; fresh installs default false; activation advisory printed.
- Smoke: `scripts/smoke/J-beta4-workflow-docs.sh` T1-T10 + T9d (semver: alpha<beta<rc<final, beta9 vs beta10, beta2 vs beta10, rc1 vs rc10) + T10d (audit row schema iso_uid + exception/exception_type) + teeth.

### Fixed — 5 nits batch (#1282 + #1283 + #1247 + #1253 + #1255, Lane K PR #1294)

- **#1282** `bridge-run.sh` filters `absent path=` / `unchanged path=` log noise.
- **#1283** `bridge-diagnose.sh acl` retired (deprecation shim only); iso v2 group/UID diagnostics intact.
- **#1247** new `agent-bridge admin set --auto-restart on|off` CLI surface (writes admin agent config via `scripts/python-helpers/admin-set-config.py` file-as-argv).
- **#1253** `agb claim --note <text>` + `--note-file <path>` propagation through `bridge-queue.py::emit_event(claim_note=...)`.
- **#1255** (R2 + R3 + R4) `hooks/tool-policy.py` flipped admin roster carve-out from blacklist (`_bash_command_has_no_write_intent`) to whitelist (`_bash_command_has_read_intent` → delegates to canonical `_is_read_intent_bash`). Added `_FIND_MUTATION_FLAGS` frozenset (`-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`, `-fprint`, `-fprint0`, `-fprintf`, `-fls`) so admin can run `find <roster> -name '*.sh'` (read) but NOT `find <roster> -delete` / `-exec mutator {}` / `-fls /tmp/leak` (mutation/exec/exfil).
- Smoke: `scripts/smoke/K-beta4-nits.sh` 7 tests including T6 (admin carve-out 20+12 cases) + T7 (find mutation flag filter, classifier + gate + teeth).

### Fixed — integration cleanup (#1295)

`scripts/ci-select-smoke.sh:110` master `__ALL__` required list omitted `D-beta4-daemon-lifecycle` during the wave's additive merges. Single-line registration restored.

### Notes

- **Pre-existing under macOS bash 3.2**: `scripts/smoke/G-beta4-watchdog-noise.sh` T3 (`bridge_isolation_v2_normalize_workdir_profile_group` chgrp/chmod) requires bash 4+ assoc arrays loaded via `bridge-lib.sh`; passes under Homebrew bash 5.3.9. Not a beta4 regression — same behavior at `1504047` baseline. Document in operator-host install advisory.
- **Pre-existing under shellcheck --severity=warning**: `scripts/smoke/queue.sh:445-447` from commit `2283221c`; present unchanged in base `1504047`. Not counted as beta4 regression.
- **Convergence rounds**: ~28+ codex review rounds total across 11 lanes plus integration review. Lane K alone hit r4 (operator-escalation cliff edge).
- **Wave-orchestration skill applied**: 3-sub-wave parallel dispatch + per-PR convergence + Phase 5 integration review + QA gate (15/15 lane smokes PASS under bash 5.3.9). Operator-cued release per [[feedback-release-requires-explicit-permission]] + [[feedback-autonomous-beta-release-loop]].

## [0.15.0-beta3] — 2026-05-27

### Highlight — Wave-1 OOTB blocker closure (#1246 / #1248 / #1249 / #1250 / #1251 / #1252) + Lane B plugin UX

Operator-cued autonomous beta loop directive 2026-05-27: ship beta3 → A2A patch verify → loop until GREEN. Driven by patch's fresh-install OOTB verify on `cm-prod-agentworkflow-vm01` against beta2, which surfaced 10 issues. Wave-1 closed the blocker trio (#1246/#1248/#1252) + restart semantics #1251 + plugin UX bundle #1249/#1250 across 4 parallel lanes with 1-3 codex review rounds each. Wave-2 (#1247 + #1254) and Wave-3 (nits #1253/#1255) deferred pending patch fresh-install verify against this beta.

`-beta3` prerelease, matching tag `v0.15.0-beta3`, GitHub release marked **Pre-release**.

### Fixed — daemon supp-group pre-check authoritative + state/agents/<a>/ self-heal (#1246 + #1252, Lane A12 PR #1260)

`agent create <agent> --isolate` was emitting `daemon_group_refresh: skipped-daemon-already-has-group` even when the running daemon's supplementary group set was provably stale (the freshly-created `ab-agent-<agent>` GID was NOT in `/proc/<daemon_pid>/status` → `Groups:`). The systemd-user auto-restart branch was bypassed; downstream session-id capture (#1248) + nudge path (#1252) both broke.

- **`lib/bridge-daemon-control.sh`** — `_bridge_daemon_control_daemon_has_gid` rewritten to read authoritative `/proc/<daemon_pid>/status` Groups line instead of on-disk cache. New `_bridge_daemon_control_proc_owner_on_disk_groups` resolver (Uid → user → id -G) lets decision-evidence emit both `on_disk=<GIDs>` AND `in_proc=<GIDs>` so operators can diagnose stale-cache vs genuine-need-refresh quickly. Format: `[daemon-control] supp-group check: pid=<P> on_disk=<GIDs> in_proc=<GIDs> target_gid=<G> action=<refresh|skip> reason=<rationale>`.
- **`lib/bridge-state.sh`** — new `bridge_agent_state_dir_self_heal` verifier with auto-repair. For iso-v2 agents (gated on `bridge_agent_linux_user_isolation_effective` after r3): pre-existing dirs verify mode `2770` AND group `ab-agent-<a>`; newly-created dirs get `mkdir -m 2770 -p` + `chgrp ab-agent-<a>` + post-chgrp verify. 6 structured fail reasons: `mkdir`, `chgrp`, `chgrp_verify`, `chmod`, `chmod_verify`, `group_resolver_empty`. Non-iso agents: helper creates dir but no-ops ab-agent enforcement (codex r2 catch — r1/r2 had over-enforced on all creates and broke ordinary `agent create`).
- **`lib/bridge-channels.sh`** — `bridge_write_idle_ready_agents` calls self-heal helper + emits structured `[nudge-skip] agent=<a> task=<id|none> reason=<state-dir-missing|...>` audit line on failure. No silent drops.
- **`bridge-agent.sh::run_create`** — synchronous self-heal call BEFORE returning `create:ok` (blocks until dir materialized with correct mode/group on iso-v2).
- **`bridge-daemon.sh`** — three existing nudge-skip code paths (live-queued-empty / age-gate-failed / dedup-cooldown) now also emit structured `[nudge-skip]` lines with the actual task id (`task=none` only when no task in scope).
- Smoke: `scripts/smoke/A12-beta3-1246-1252-daemon-supp-group-and-state-dir.sh` 17 tests including iso-v2 enforcement + non-iso passthrough + 3 teeth-checks (one per codex finding). ci-select-smoke.sh 5-site registration.

### Fixed — `agent restart` session_id fail-loud + `--no-continue`/`continue=1` reconcile + bridge-start.sh swallow removed (#1248, Lane A3 PR #1259)

`agent restart` on iso-v2 agent spawned a fresh Claude session instead of resuming. `session_id: ""` even with `continue: 1`. Layered cause: layer 1 was Lane A12 (state-dir write blocked by stale daemon group); layer 2 was silent swallow in the write helper; layer 3 was `--no-continue` vs `continue=1` propagation divergence.

- **`lib/bridge-state.sh`** (layer 2) — write rc propagation + `bridge_die` on persist failure with structured reason (`state_dir_write_failed:session_id agent=<a> path=<file> rc=<N>`). `[session-id]` audit-log breadcrumb on success.
- **`bridge-run.sh`** (layer 3) — new reconcile gate: `continue=1 + session_id present` → `--resume <id>`; `continue=1 + session_id empty` → `bridge_die` with (a)/(b)/(c) remediation text; `continue=0` or `--no-continue` → no resume verb. Dropped the silent stderr swallow on session-id capture.
- **`bridge-start.sh`** (codex r1 BLOCKING fix) — `:982` previously routed `bridge_refresh_agent_session_id` through `>/dev/null 2>&1 || true`. With Layer 2's `bridge_die` semantics this swallowed the structured stderr AND `|| true` couldn't catch `exit` from inside the function — `bridge-start.sh` died silently after tmux creation. R2 dropped both swallows; structured reason now surfaces.
- Smoke: `scripts/smoke/A3-beta3-1248-restart-session-id-resume.sh` 9 tests + caller audit (all 5 callers in repo enumerated). ci-select 3-site registration.

### Added — `agent restart` 3-phase transactional flow + auto-rollback + `restart.in-progress` marker (#1251, Lane C1 PR #1256)

`agent-bridge agent restart <agent>` that errored partway through (after stopping prior tmux session, before successfully launching new one) used to leave the agent **stopped** with channel update intact. Watchdog fired `[watchdog] agent profile drift`; operator had to manually re-start.

- **Phase 1 — pre-flight validation** (BEFORE the kill): channel-spec canonical resolution (Lane G beta1), plugin catalog seeded (Lane β beta2), daemon supp-group present (Lane A12 beta3, conditional via `declare -f` guard), engine binary exists, session-id state consistent (Lane A3 beta3). Any check fails → abort, agent stays running, no state mutation.
- **Phase 2 — snapshot + marker + execute**: snapshot captured from `agent-roster.local.sh` managed block BEFORE the channel update (codex r1 fix — earlier ordering captured the failing config). Marker `state/agents/<a>/restart.in-progress` written with schema (SSOT comment): `pid=<orchestrator-pid>`, `started=<unix-ts>`, `ttl=<seconds>` (default 60), `state=in_progress|rolled_back|completed`, `reason=<structured>`. Apply changes; stop + start tmux.
- **Phase 3 — success cleanup or auto-rollback**: on success — remove marker + snapshot. On failure (any step) — restore roster from pre-update snapshot, re-start with PRIOR channels, marker state=rolled_back with structured reason.
- Marker contract for Lane C2 (deferred #1254): `bridge_agent_restart_marker_active` requires both `kill -0 <pid>` AND TTL window AND `state=in_progress` (codex r1 fix — earlier version ignored PID liveness, allowed crashed orchestrator to block watchdog for full TTL).
- Marker file mode `0640` + group `ab-agent-<a>` on Linux iso-v2 (codex r1 fix — earlier umask-default 0600 was unreadable by iso UID).
- Smoke: `scripts/smoke/C1-beta3-1251-restart-preflight-rollback.sh` 11 tests including production-ordering rollback + dead-PID marker + marker mode + 5 teeth-checks. ci-select 3-site registration.

### Added — `agb plugins add-marketplace` integrated verb + iso-v2 banner + seed auto bun-install with fail-loud (#1249 + #1250, Lane B PR #1258)

For iso-v2 agents, controller `claude plugin install` silently diverges from what the iso agent will actually load. The 5-step operator dance (claude marketplace add → claude plugin install → agent update --channels-add → agent restart) silently failed at restart with `Claude plugin '<name>@<marketplace>' is not declared`. Separately, `agb plugins seed` reported `node_modules=missing` alongside `criticality=channel-required` and proceeded — silent runtime failure later.

- **`agb plugins add-marketplace <url-or-path> [--channels <plugin-ref>,...]`** — single integrated verb: clone marketplace to shared cache (or register local path), run `bridge-plugins.sh seed --marketplace-root <path>`, apply iso v2 chmod (mode `2770` + chgrp `ab-shared`). Idempotent.
- **`agb plugins help install`** advisory text — iso-v2 banner explaining controller / iso-agent plugin namespaces are separated by design.
- **`agb plugins seed` auto bun-install** — when `node_modules=missing` AND deps declared (`dependencies`/`peerDependencies`/`bun.lockb`/`package-lock.json` present): runs `bun install` automatically. On failure with `criticality=channel-required`: emits structured `seed_status=incomplete node_modules=install_failed plugin=<name> criticality=channel-required rc=<N>` tokens (codex r2 fix — r1 dropped these and only printed generic remediation) + exits non-zero. `--no-auto-install` flag opts out (air-gapped).
- New file-as-argv helper: `lib/upgrade-helpers/plugins-seed-parse-sync-output.py` (mode 100755 — codex r2 fix; r1 was 100644).
- Smoke: `scripts/smoke/B-beta3-1249-1250-plugin-ux.sh` 7 tests with T6 grep-asserting all 3 structured tokens. ci-select 3-site registration.

### Deferred to Wave-2 / Wave-3

`agent restart` failure leaves stopped → handled by Wave-1 C1 (#1251). The following remain queued pending patch fresh-install verify:

- Wave-2 (#1254 watchdog scan_error vs restart-in-progress + #1247 admin set auto-restart preserving session) — consumes C1's marker schema.
- Wave-3 (#1253 `agb claim --note` + #1255 roster read-block softening) — nits, may defer further if not surfaced by patch verify.

## [0.15.0-beta2] — 2026-05-26

### Highlight — 7-lane parallel OOTB closure (#1231–#1238 + #6607)

Operator-cued 2026-05-26 ~13:00 KST verbatim: "니가 만든 15.0 베타 1 버전 쓰레긴데? ... 에이로 다시 해서 빨리 쉽 해!" Patch's fresh-install + fresh `agent create --isolate --channels plugin:teams,plugin:ms365,plugin:cosmax-*` surfaced 8 OOTB-failing issues that beta1's regression check on existing iso agents missed. **Methodology fix going forward**: every future beta requires a fresh-install + fresh-iso-agent-create OOTB verify gate (regression check ≠ acceptance test).

`-beta2` prerelease, matching tag `v0.15.0-beta2`, GitHub release marked **Pre-release**.

### Fixed — iso v2 scaffold ownership + bridge-auth file-as-argv (#1238, Lane α PR #1239)

`agent create --isolate` left `<iso-agent>/home/` and credentials with stale controller ownership → the iso UID could not read its own home. `lib/bridge-agents.sh:4157-4179` adds a chown handoff for `"$workdir"` + `"$_v2_agent_root/home"` (scope-limited; credentials + runtime/logs/requests/responses still controller-owned). `bridge-auth.sh:218-233` previously routed `python3 - <<'PY'` through `bridge_auth_run_privileged` → wrapper's first-attempt-then-sudo retry consumed the heredoc on first invocation, leaving sudo fallback with EOF. Extracted to `lib/upgrade-helpers/auth-legacy-claude-config-env.py` (file-as-argv; mode 0700) per the same footgun #11 pattern that produced v0.13.7-v0.13.9 helpers. Counter-proof T3c in `scripts/smoke/1238-iso-scaffold-ownership.sh` simulates the wrapper retry-fallback and would fail loudly on any future revert to heredoc-stdin.

### Fixed — fresh init seeds bundled plugin catalog + verifier-gated sudoers status (#1231 + #1236-sudoers, Lane β PR #1242)

`agb agent create --isolate --channels plugin:teams,plugin:ms365` on a fresh v2 install `bridge_die`'d with "plugins-cache is not populated" because Claude never wrote `installed_plugins.json` there and the operator had to discover `agb plugins seed` from the error. Two-layer fix per codex r1 spec: (1) `bridge-init.sh` runs idempotent `<live-cli> plugins seed` (bundled marketplace) after host-profile resolution, gated on `bridge_isolation_v2_active`; non-fatal on failure. (2) `bridge_linux_share_plugin_catalog` in `lib/bridge-agents.sh:2624-2667` detects empty-cache + declared-plugin and runs the same seed via subprocess before failing. Same path: `bridge-init.sh:688-730` + `agent-bridge:582-624` no longer emit contradictory `[init] daemon-refresh sudoers: installed` + `daemon_group_refresh_sudoers=missing|invalid` on adjacent lines; gates the success line on `bridge_daemon_control_check_sudoers` returning `ok`, otherwise emits `manual-required: daemon_group_refresh_sudoers=<reason>` with remediation. 6-test smoke + ci-select registration in 4 sites (r2).

### Fixed — setup-teams target-scope + agent update --channels alias + launch_cmd reconcile + agent update --help short-circuit (#1232 + #1235 + #1236, Lane γ PR #1244)

`bridge-setup.sh` channel wizards (`setup-teams|discord|telegram|ms365`) wrote managed-CLAUDE-block plugin lines into the operator's home but not into iso v2 agents' isolated home → `agent create --channels plugin:teams` later failed. New helper `bridge_setup_ensure_claude_channel_plugin_for_needle` wired into all 4 run_* entry points + iso v2 target-scoping. `agent update --channels foo,bar` now accepts the new alias and `bridge_normalize_channels_csv` canonicalizes through the same canonical-table from beta1 Lane G. `launch_cmd` dev-channel reconcile on `agent update` so updated channels actually propagate to the running launch_cmd. `agent update --help` short-circuits BEFORE the bind path so it never spawns a sudo prompt to discover the help text. 1117-cli-help-universal-gate prunes `agent update` from KNOWN_BROKEN_VERBS (145 assertions). New 9-test smoke + ci-select registration in 3 sites (r2).

### Fixed — daemon `--start-policy hold|auto` + channel-miss auto-hold parity across 3 wake paths (#1234, Lane δ PR #1245)

`agent update --start-policy hold|auto` lets operators explicitly suppress autostart while channel setup is intentionally incomplete. Persisted as `BRIDGE_AGENT_START_POLICY[<agent>]` (associative array — never scalar, refs #1213). `bridge_daemon_check_channel_status_or_hold` helper (`bridge-daemon.sh:3753-3768`) records `channel-required-validator-miss:<channel> <path>` and sets policy=hold instead of the opaque `start-command-failed`. Helper wired into all THREE wake paths: (a) `process_on_demand_agents` always-on branch; (b) `process_on_demand_agents` queued on-demand branch (codex r1); (c) `bridge_daemon_cron_dispatch_wake` (codex r2 — third bypass surfaced in r3 cycle). Smoke T5/T6 extract production functions verbatim via `awk` and assert source-anchor pins; teeth-verified counter-proofs catch any future revert. New 6-test smoke + ci-select registration in 2 sites (r2/r3).

### Added — watchdog rescan verb + engine-native codex AGENTS.md contract (#1233 + #1237, Lane ε PR #1240)

Codex now has an engine-native required-file contract: `CODEX_REQUIRED_FILES = ("AGENTS.md",)` in `bridge-watchdog.py`. Claude-only drift signals (managed-CLAUDE-block, onboarding state) ignored for codex; codex still errors on missing `AGENTS.md`. Engines with no implemented contract surface `unsupported_engine_contract` instead of silent OK. `agent-bridge watchdog rescan [--agent <a>] [--json] [--apply]` is the explicit operator verb (writes `<bridge_home>/shared/watchdog/latest.md`); `scan` remains stdout-only. Daemon cooldown preserved on tick path.

### Added — plugins list / marketplaces read-only verbs with --json (#1236-plugins, Lane ζ PR #1241)

`agb plugins list [--json]` and `agb plugins marketplaces [--json]` provide structured read-only inspection of the bundled marketplace + cache state. Four file-as-argv helpers under `lib/upgrade-helpers/plugins-{list,marketplaces}-{json,pretty}.py`. Smoke covers empty/populated cache + JSON shape + `show --json` sentinel. ci-select registration in 3 sites (r2).

### Fixed — patch hook anchored admin bridge-verb allowlist with shape-deny + audit (#6607, Lane η PR #1243)

`hooks/tool-policy.py` previously left admin `agent-bridge|agb auth claude-token add|sync|rotate` + `escalate question` + `a2a send --body-file` shapes wedged under credential/env-dump and protected-path denies. **Anchored verb allowlist** (NOT full admin bypass — codex r1 rejected that as broad-injection risk) inserted in the policy chain: credential/env-dump → protected-path → wrapper → roster/queue → **anchored verb allowlist** → peer/shared. `_extract_flag_value()` distinguishes `_FLAG_ABSENT` from `_FLAG_MALFORMED` (codex r2 finding); a2a allowlist DENIES malformed shapes (`--body-file` alone, `--body-file --to peer`, duplicate `--body-file` with traversal). Distinct audit row `tool_policy_admin_bridge_verb_denied_shape` for shape-rejected. 25-test smoke + ci-select registration in 2 sites (r2).

### Internal — ci-select-smoke.sh registration discipline

Codex caught registration gaps in 5 of 6 lane R1 reviews (β/γ/δ/η/ζ). Future wave briefs should pre-emptively include ci-select registration as an explicit fixer responsibility — the systemic gap added ~30min per lane to the wave cycle.

## [0.15.0-beta1] — 2026-05-26

### Highlight — minor bump for 4-lane backlog closure (G + F + H + I)

Operator-cued 2026-05-26 ~04:42 UTC verbatim: "저것까지도 다 해 + 병렬 처리로 해서 싹다 하라고 해" — full backlog closure via parallel dispatch. **Minor version bump (0.14.5 → 0.15.0)** chosen over beta28 because Track F touches OS state (sudoers/systemd daemon refresh, autonomous detection in poll loop) — mixing into the v0.14.5 beta-series would muddy risk profile.

`-beta1` prerelease; matching tag `v0.15.0-beta1`, GitHub release marked **Pre-release**. Stay on beta per Sean's standing rule. v0.14.5 GA promotion remains a separate operator-cued decision (durable rule).

### Fixed — channel-spec canonical resolution (#1221, Lane G PR #1223)

`agent create --channels "plugin:teams,plugin:ms365"` had inconsistent suffix-resolution: `plugin:teams` auto-resolved to `@agent-bridge`, but `plugin:ms365` stayed un-suffixed → silently dropped from `launch_cmd` → `agent start` aborted with `Claude plugin 'ms365' is not declared`.

- **`lib/bridge-agents.sh`** — new `bridge_builtin_plugin_marketplace` canonical-table helper, refactored `bridge_qualify_channel_item` (`:5014-5046`) to consult it.
- **Canonical mapping** (codex r1 A-prime, NOT "all to @agent-bridge"):
  - `teams`, `ms365`, `mattermost` → `@agent-bridge`
  - `discord`, `telegram` → `@claude-plugins-official`
- Explicit `@<marketplace>` suffixes preserved verbatim (incl. `plugin:teams@cosmax-marketplace`).
- Removed redundant early-return at `:4720-4725` — explicit-suffix forms now fall through to tail return.
- 16-test smoke `scripts/smoke/G-channel-spec-resolution.sh` covers positive/negative/regression/cross-builtins.

### Fixed — `bootstrap-memory-system.sh` iso v2 PermissionError (#1222, Lane H PR #1225)

Post-upgrade `bootstrap-memory-system.sh --apply` aborted with `rm: Permission denied` on iso v2 agents' `workdir/memory/index.sqlite.rebuilding-<STAMP>` because controller (`awfmanager`) cannot write into iso-owned `2770 ab-agent-*` per the no-group-relax contract.

- **`bootstrap-memory-system.sh`** — sources `bridge-lib.sh` + calls `bridge_load_roster` BEFORE setting `_BRIDGE_ISO_HELPERS_LOADED=1` (codex r1 BLOCKING fix: without `bridge_load_roster` the isolation predicate always returned 0 in bootstrap shell → fall-through to legacy controller-direct path → bug unchanged). `step_rebuild_one` apply path detects iso v2 via `bridge_agent_linux_user_isolation_effective` and runs the ENTIRE rebuild/publish block (stale-tmp rm + `bridge-memory.py rebuild-index` + sqlite validate + `mkdir -p memory/` + `mv -f tmp_db db`) under iso UID via `bridge_isolation_run_as_agent_user_via_bash`.
- **Approach H.2 picked** — NO new broad `bridge_iso_run --op rm` added (security risk avoided). Whole rebuild block under iso UID, not just `rm`.
- Distinct drift signatures via exit codes ≥ 10: `rebuild-failed` (10), `validate-failed` (11), `stale-tmp-unlink-failed-as-iso-uid` (12), `memory-mkdir-failed-as-iso-uid` (13), `mv-into-place-failed-as-iso-uid` (14), `validate-harness-mktemp-failed` (15).
- Smoke `scripts/smoke/H-bootstrap-memory-iso-rebuild.sh` — T1-T7 host-agnostic source-structure assertions + T7.1 `bridge_load_roster`-called-after-source guard + T7.2 runtime predicate-true proof with **negative-control-first** pattern (catches future "auto-loader" refactors that would break this contract) + T8 Linux+sudo opt-in real reproducer.

### Added — daemon supplementary-group autonomous self-refresh (Lane F PR #1224)

Closes KNOWN_ISSUES §28 daemon staleness class. Pre-fix: every `agent create` emitted `[경고] supplementary group cache does not include the freshly created 'ab-agent-<slug>' ... daemon_group_refresh: manual-required-systemd-unit-stale`. Operator had to manually `agent-bridge init sudoers daemon-refresh --apply` + `bash scripts/install-daemon-systemd.sh --apply --enable` + `systemctl --user restart agent-bridge-daemon.service`.

- **F.B-prime picked**, NOT F.A: SIGHUP/setgroups cannot refresh supplementary groups of a running process. The daemon's existing HUP trap correctly just exits; the proper boundary is PAM/initgroups via process restart (already encapsulated in `bridge_daemon_refresh_after_group_membership_change` at `lib/bridge-daemon-control.sh:293-604`).
- **`bridge-daemon.sh`** — refactored `bridge_daemon_warn_if_supp_groups_stale` (`:64-128`) into a pure data helper (`bridge_daemon_detect_stale_supp_groups`) + presentation wrapper. Added 5 new helpers + `cmd_supp_refresh_worker`. `bridge_daemon_supp_groups_poll_and_dispatch` wired near top of main poll loop (`:7293-7324`), before `cmd_sync_cycle`/queue gateway/spawn work.
- **Detached refresh worker dispatch** — daemon dispatches an external `bridge-daemon.sh supp-refresh-worker` process via the existing sudo-self systemd unit (NOT a synchronous helper call that would kill its own parent). Guarded via existing lock at `lib/bridge-daemon-control.sh:360-374`. One missing group per refresh attempt (avoids restart storms). Throttle state under `state/daemon.supp-refresh.state` with atomic write.
- **`KillMode=process`** at `scripts/install-daemon-systemd.sh:232-246` already limits restart impact to the daemon process — agent tmux + plugin children unaffected. Brief interrupt expected on queue gateway socket listener, sync cycle, idle nudges (one cycle).
- Sudoers contract clarified: `agent-bridge init sudoers daemon-refresh --apply` template at `scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template:46-47` authorizes ONLY daemon `restart --force --internal-reason=group-refresh` + daemon `run`. Group mutation itself runs via `bridge_isolation_v2_ensure_user_in_group` (`lib/bridge-isolation-v2.sh:625-654`).
- Smokes (two layers): `F-daemon-supp-groups-mock.sh` (12 host-agnostic tests, stubs id/getent/pid/systemd, asserts detection + classification + throttle + NO SIGHUP path); `F-daemon-supp-groups-real.sh` (Linux + sudo gated, opt-in via `BRIDGE_SMOKE_F_REAL_OPT_IN=1`, creates transient `ab-agent-smoke-*` group + verifies `/proc/<pid>/status` Groups updates).

### Added — agent description defaults + `agent describe` CLI + admin convention docs (Lane I PR #1227, Sean mid-flight addition)

Downstream agents reading their roster could not identify the admin/system agent's role — the `BRIDGE_AGENT_DESC` schema existed but defaults were terse (`"$admin_agent admin role"`) and there was no read-only CLI getter, so operators on downstream installs (cosmax-* server etc.) inherited empty/useless descriptions. Cross-host agents had to guess role from contextual issue-comment signatures.

- **`bridge-init.sh:522-540`** — admin default upgraded to: "Agent Bridge admin/coordinator for this install. Owns onboarding, roster/queue triage, upgrade/release waves, and operator-facing decisions."
- **`agent-roster.local.example.sh:17-36`** — 4 role exemplars (admin / codex pair / antigravity pair / system) near the existing desc block.
- **`bridge-agent.sh:2108-2180`** — new `agent describe <agent>` read-only CLI: stdout = description + newline on set + exit 0; unset = no stdout + stderr hint pointing to `BRIDGE_AGENT_DESC["<agent>"]` in `agent-roster.local.sh` + exit non-zero. `-h/--help` from day one (avoids #1114/#1117 help-drift class). NO `describe set` write path in beta1.
- **`bridge-agent.sh:2045-2055`** — `agent show` text-mode unset hint added (JSON keeps raw empty string for unset/placeholder distinguishability).
- **`docs/agent-runtime/admin-agent-convention.md`** — new doc namespace; covers description convention + distinction from `BRIDGE_AGENT_CLASS` (authorization vs identity). Linked from `docs/agent-runtime/admin-protocol.md:188-190`.
- **Schema fidelity** (codex r1 critical correction): uses existing `BRIDGE_AGENT_DESC` assoc array, NOT a duplicate `BRIDGE_AGENT_DESCRIPTION` (which would re-introduce the #1213 assoc-array/scalar collision class). Existing schema infrastructure at `lib/bridge-core.sh:821-839`, `lib/bridge-agents.sh:852-855`, `bridge-agent.sh:1065-1069, :1517-1549, :1587-1592, :2011-2044` preserved.
- Smoke `scripts/smoke/I-agent-description-roster.sh` (8 assertions): set/unset display in text + JSON + list, describe success/fail, `declare -p` confirms `declare -A`, env has NO scalar `BRIDGE_AGENT_DESC` export.
- `scripts/smoke/1117-cli-help-universal-gate.sh` picks up the new `describe` verb (now 144 assertions, was 143).

### Added — `docs/agent-runtime/plugin-authoring-iso-v2.md` (PR #1218)

Standalone docs PR landed ahead of the v0.15.0-beta1 wave: contract for plugin authors targeting linux-user installs. +349/-0.

### Fixed — `scripts/iso-helper-ratchet.sh` baseline drift (release commit)

Pre-existing drift from beta27 ms365 setup wizard work (PR #1220): `bridge-setup.py` 22→30 + `scripts/smoke/1209-ms365-redirect-resolver.sh` 0→21. Plus Lane I removed one boundary callsite in `bridge-init.sh` (3→2). Baseline regenerated to clear `oss-preflight` failure. Net delta = beta27 surface that legitimately routed through the controller-side path (operator-supplied credential files, setup wizard env writers).

### Notes

- **#219 verify-and-close** (MS365 redirect URI for test_iso_v23) — patch operates post-ship per coordination: either `agent-bridge setup ms365 test_iso_v23 --redirect-uri ...` (now possible per Lane B/C beta27 + Lane G beta1) or `agent retire test_iso_v23 --quarantine`.
- v0.14.5 GA promotion — separate operator-cued decision.
- `BRIDGE_AGENT_OS_USER` same-class collision — no Python hook consumer confirmed; shell array readers only. Left alone (was deferred from beta27).
- `scripts/smoke/1115-cli-usage-drift.sh` T1 `iso-run missing from _top_valid` — pre-existing on stabilize, NOT introduced by any lane in this wave. Separate fix needed in `agent-bridge` to add `iso-run` to `_top_valid` array.
- Pre-existing `scripts/smoke/1121-agent-delete-os-purge.sh` C5 Linux flake (failing across beta22-25 series) — still not addressed.

## [0.14.5-beta27] — 2026-05-26

### Highlight — 5-track backlog closure via 3-lane parallel dispatch

Operator-cued 2026-05-26 01:58 KST verbatim "일단 저 백로그들 다 꼼꼼히 개발해서 새 베타버전 쉽 하라고 전달해줘". 5 backlog items shipped via 3-lane parallel fixer dispatch (Sean's earlier engineering question about parallel stability handled with lane-bundling to avoid same-file conflicts: Lane 1 = A, Lane 2 = B+C ms365 bundle, Lane 3 = D+E hooks bundle). 3 PRs (#1217 + #1219 + #1220) merged sequentially with codex pair-review per lane.

`-beta27` prerelease; matching tag `v0.14.5-beta27`, GitHub release marked **Pre-release**. Stay on beta per Sean's standing rule. Track F (daemon supp-groups self-refresh) deferred to v0.15.0 dedicated wave.

### Removed — #1204 D1 TEAMS_DELIVERY_MODE 완전 제거 (Lane 1, PR #1217)

Sean's directive verbatim 2026-05-25 17:22 UTC: "지워버려 필요 없는 모드잖아."

Full removal from `plugins/teams/server.ts`:
- `resolveDeliveryMode()` + supporting `DeliveryMode` type + warning at `:171-190`
- `handleActivity` bridge/both branching at `:1133-1227` replaced with unconditional `await mcp.notification(...)` (direct MCP push) + existing retry-on-failure
- Legacy `TEAMS_BRIDGE_MODE/AGENT` warning at `:171-174`
- Dead `deliverViaBridgeQueue()`, `truncateForTitle()`, `buildChannelMeta()` removed
- Dead Node imports removed: `mkdtempSync`, `rmdirSync`, `tmpdir`

`plugins/teams/README.md:156-168` Delivery Mode section replaced with one-liner "Inbound delivery via direct MCP push — no configuration required."

`scripts/smoke/launch-dev-channels-injection.sh` updated: removed `assert_explicit_teams_delivery_mode_is_preserved`, added `assert_teams_delivery_mode_source_grep_gate` that enforces `git grep -i 'TEAMS_DELIVERY_MODE'` is empty outside CHANGELOG. Latent bug bonus: `scripts/smoke-test.sh` stale `assert_contains "ignoring deprecated TEAMS_BRIDGE_MODE"` (string source never shipped) replaced with two anti-presence checks.

Net deletion: +57 / -243 across 4 files.

### Fixed — #1209 MS365 redirect URI fail-loud + setup wizard (Lane 2, PR #1220)

**Root cause**: `plugins/ms365/server.ts` defaulted `REDIRECT_URI` to `http://localhost:3978/auth/callback`. Any non-localhost deployment hit `AADSTS50011` at first OAuth click. No setup wizard prompted for the correct URI.

- **`plugins/ms365/server.ts`** — new `resolveRedirectUri()` priority: explicit non-localhost → returned; explicit localhost + `MS365_REDIRECT_URI_ALLOW_LOCALHOST=1` → returned (local-dev escape hatch); else fail-loud throw naming `agent-bridge setup ms365 <agent>`. `startAuthCode` now takes redirectUri as parameter (defense in depth). Both `pair_start` and `exchangeAuthCode` call the resolver.
- **`bridge-setup.py`** — new `inspect_ms365_dir()`, `derive_ms365_redirect_uri()`, `print_ms365_result()`, `cmd_ms365()`, `ms365_parser`. Wizard resolves redirect URI from 5 sources in priority: explicit `--redirect-uri`, `--messaging-endpoint`, `.teams/state.json.validation.messaging_endpoint` (per codex's data-source correction — runtime `TEAMS_MESSAGING_ENDPOINT` env is not propagated), interactive prompt, existing `.ms365/.env`. Uses `_isolation_aware_mkdir(mode=0o2770)` + `_isolation_aware_save_text(mode=0o600)` per beta26 #1208/#1215 lessons.
- **R2 narrow fix** (codex r1 BLOCKING): setup wizard rerun must preserve `MS365_REDIRECT_URI_ALLOW_LOCALHOST=1` line. `inspect_ms365_dir()` reads the flag; `cmd_ms365()` reconstructs with strict-eq "1" match (aligns with runtime `=== '1'`); env_lines reconstruction appends the flag immediately after `MS365_REDIRECT_URI=`. Plus optional `--allow-localhost` CLI flag for cleaner first-time setup.
- **`bridge-setup.sh`** — `run_ms365()` mirroring `run_teams()` shape; usage block, sub-command help, dispatch case, suggestion list.

Migration impact: existing agents with unset or localhost `MS365_REDIRECT_URI` will fail-loud at next `pair_start`. Recovery: `agent-bridge setup ms365 <agent>` (Track B wizard) or manual `.ms365/.env` edit or `MS365_REDIRECT_URI_ALLOW_LOCALHOST=1` for local dev.

### Fixed — #1210 MS365 scope quote normalization (Lane 2, PR #1220)

**Root cause**: `plugins/ms365/server.ts` `pair_start` passed `String(args.scopes ?? DEFAULT_SCOPES)` directly into `URLSearchParams`. Quoted env/arg values flowed through and became `%22...%22` in `authorize_url`, triggering `AADSTS70011: scope ... is not valid` on Azure.

- New `normalizeScopes(raw: string): string` helper trims whitespace, strips one matching outer quote pair (single or double), splits on whitespace, rejoins with single space. Applied at pair_start handler before URLSearchParams.

Per codex's r1 KEY FINDING: this was NOT a URLSearchParams swap (beta26 already used URLSearchParams correctly). The bug was input-side normalization.

### Fixed — `BRIDGE_AGENT_INJECT_TIMESTAMP` assoc-array/scalar collision (Lane 3, PR #1219)

**Root cause**: same class of bug as beta26 #1213. `bridge-run.sh:212-228` exported `BRIDGE_AGENT_INJECT_TIMESTAMP` as a scalar after `lib/bridge-core.sh` had already declared it as `declare -g -A` (associative array). Bash silently writes to `NAME[0]` and refuses to export the assoc array. Child claude env had no `BRIDGE_AGENT_INJECT_TIMESTAMP` entry. The inject-timestamp feature defaulted to enabled (silent fail-open) regardless of operator's set value.

- **`bridge-run.sh`** — added `export BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="$(bridge_agent_inject_timestamp "$AGENT")"` alongside the existing silent-no-op bare export. Matches the existing `BRIDGE_AGENT_CLASS_FOR_HOOK` scalar-alias pattern. Stale "deferred" comment updated.
- **`hooks/bridge_hook_common.py`** — `agent_timestamp_enabled()` reads `BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED` first, falls back to bare `BRIDGE_AGENT_INJECT_TIMESTAMP` for manual/non-bridge launches.
- Assoc array at `lib/bridge-core.sh:829, 867` NOT renamed or unset (breaking downstream array readers would re-introduce #1213-class regression).

### Added — hook PermissionError audit telemetry (Lane 3, PR #1219)

Adjacent fail-open audit for 2 marker writer sites in the hook tree (patch-dev #1205 deep-dive carryover):

- **`hooks/pre-compact.py:_write_started_marker()`** — wraps marker write sequence with `try/except (PermissionError, OSError)` BEFORE the existing outer `except Exception`. Under `under_isolated_uid()` → emits `write_audit("hook_permission_fail_open.precompact.started_marker", ...)` + returns. Else re-raises (caught by outer swallow → existing exit-0 behavior preserved).
- **`hooks/session_start.py:_write_compact_completed_marker()`** — same pattern with audit name `hook_permission_fail_open.session_start.completed_marker`.

Codex r1 adjudicated interpretation (a): preserve outer silent-swallow + add iso-only audit telemetry. Smaller blast radius, matches hook UX goal. Smoke verifies controller side emits NO audit (proving inner re-raise path taken) while function still returns cleanly.

### Added — 4 new regression smokes

- `scripts/smoke/1209-ms365-redirect-resolver.sh` — **16 tests** (12 base + 4 R2 ALLOW_LOCALHOST preservation): resolver priority table, Python wizard derivation from all 5 sources, bash wrapper help, `.ms365` dir mode 02770 + file mode 0600 regression, ALLOW preservation on rerun, CLI flag, strict-eq matching.
- `scripts/smoke/1210-ms365-scope-normalize.sh` — 8 tests: quoted env, single-quoted env, whitespace collapse, plain round-trip, args.scopes path, full authorize_url shape (no `"` / no `%22`).
- `scripts/smoke/beta27-D-inject-timestamp-resolved.sh` — 13 tests: assoc-array no-op reproducer, RESOLVED scalar propagation, fallback for manual context, RESOLVED=0 makes `agent_timestamp_enabled()` False.
- `scripts/smoke/beta27-E-hook-permission-fail-open-markers.sh` — 5 tests: iso UID + force PermissionError → exit 0, no traceback, audit event recorded; controller UID → exit 0, no traceback (outer swallow), NO audit event.

All 4 registered in path-arm triggers AND `add_all_required_static`.

### Notes

- **Track F (daemon supp-groups self-refresh)** — deferred to v0.15.0 dedicated wave. Medium-high risk (touches OS state: sudoers OR systemd-user unit + daemon SIGHUP handler). Beta26 already added a "daemon_group_refresh: manual-required-systemd-unit-stale" warning so operators know what to do meanwhile.
- **`BRIDGE_AGENT_OS_USER`** — same-class assoc-array/scalar collision as fixed Track D, but codex grep confirmed no Python hook consumer exists (shell code reads the assoc array directly). Left in place; not a runtime issue.
- v0.14.5 GA promotion remains a separate operator-cued decision (durable rule).

## [0.14.5-beta26] — 2026-05-26

### Highlight — 4-track OOTB clean closure

Operator-cued **twenty-sixth prerelease**. Closes the residual iso v2
OOTB blockers that surfaced during beta25 fresh-agent verify on
cm-prod-agentworkflow-vm01: the third-party marketplace SessionStart
hook gap, the bash assoc-array/scalar-export collision that silently
bypassed PR #1206's fail-open for ~12 hours, the channel-validator
early-missing-return that the beta25 read-fallback couldn't reach, and
the `.ms365` directory mode that needed an exec bit.

After this release, fresh OOTB `agent create test_iso --linux-user
--channels plugin:teams,plugin:ms365,plugin:cosmax-*` →
`agent start` should succeed **without any operator `sg`, `chown`,
`chmod`, or `settings.json` manual patch**, and the hook traceback
noise that was previously visible to operators (claimed fixed in
beta25 but silently bypassed) should finally be gone.

`-beta26` prerelease; matching tag `v0.14.5-beta26`, GitHub release
marked **Pre-release**. Stay on beta per Sean's standing rule.

### Fixed — #1212 bridge-hooks.py @agent-bridge filter blocks third-party plugin hooks (#1216)

- **`bridge-hooks.py`** — `agent_bridge_development_plugin_settings()`
  drops the `value.endswith("@agent-bridge")` filter at lines 106-107.
  Accepts any `plugin:<name>@<marketplace>` spec. Uses `rsplit("@", 1)`
  so marketplace is the rightmost segment. Deduplicates full plugin
  specs preserving insertion order for `enabledPlugins`. Collects
  marketplace ids from all accepted specs.
- `extraKnownMarketplaces` now emits per-marketplace entries with
  shape `{ "source": { "source": "directory", "path": "<mirror>" } }`.
  `agent-bridge` entry unchanged (path = `BRIDGE_HOME`). Third-party
  marketplace path = `$BRIDGE_HOME/data/shared/plugins-cache/
  marketplaces/<marketplace-id>` (the beta24 D4 mirror).
- Safety guards: marketplace id matches `[A-Za-z0-9._-]+`, not `.` or
  `..`, no leading dot, `(marketplaces_root / id).is_dir()`. Plugin
  stays in `enabledPlugins` even if mirror missing.
- Effect: third-party marketplace plugins' SessionStart hooks now fire
  on agent launch. CRM token-sync hook substitutes the real M365
  access token into the cached `.mcp.json` before claude reads it, so
  CRM HTTP MCP tools register correctly on first session start.

### Fixed — #1213 bash assoc-array vs scalar-export collision bypasses fail-open (#1216)

- **Root cause**: `bridge-run.sh:212-213` did
  `export BRIDGE_AGENT_ISOLATION_MODE="$(...)"` for a name already
  bound to `declare -g -A BRIDGE_AGENT_ISOLATION_MODE` in
  `lib/bridge-agents.sh:3410`. Bash silently writes the value to
  `NAME[0]` and refuses to export the assoc array. Child claude env
  had no `BRIDGE_AGENT_ISOLATION_MODE` entry. PR #1206's
  `_under_isolated_uid()` predicate required this var equal
  `"linux-user"`, so it returned False under iso v2, the fail-open
  branch never fired, and the traceback flood Sean reported as "에러
  미쳤네" persisted in every iso v2 session.
- **`hooks/bridge_hook_common.py`** — introduced
  `_current_agent_under_foreign_uid() -> str | None`, computed from
  `BRIDGE_AGENT_ID` (set) + `BRIDGE_CONTROLLER_UID` (numeric) +
  `os.geteuid() != controller_uid`. Used in **both**
  `_under_isolated_uid()` and `current_isolated_agent()`. The latter
  is also consumed by `queue_cli()` for iso hook gateway routing — if
  only `_under_isolated_uid()` had been fixed, the env collision would
  still keep iso hook queue ops off the gateway path.
- Diagnostic fallback in `_current_isolation_mode()`: explicit
  `BRIDGE_AGENT_ISOLATION_MODE` env if set, else `linux-user` when
  foreign-UID predicate proves it, else `shared`. So tracebacks /
  diagnostics no longer mis-report `shared` under a proven foreign UID.
- `BRIDGE_AGENT_OS_USER` same-class collision audited: no Python hook
  consumer depends on it (shell code reads the assoc array
  directly). Left in place; not a runtime issue.
- `BRIDGE_AGENT_INJECT_TIMESTAMP` has the same class of collision at
  `bridge-run.sh:212` vs assoc array in `lib/bridge-core.sh`; hook
  reads it at `bridge_hook_common.py:955`. Comment marker added at
  `bridge-run.sh:212` for beta27 follow-up. Not blocking #1213 P0.

### Fixed — #1214 channel-validator bypasses beta25 #1207 read-fallback (#1216)

- **Root cause**: `bridge_channel_env_file_readiness` had an early
  `[[ ! -e "$file" ]] -> missing` return at
  `lib/bridge-agents.sh:5607-5609`. Under stale controller
  supplementary groups, EACCES looks absent to the controller — so
  the function returned `missing` before the beta25 #1207 read
  fallback inside `bridge_iso_run_path_under_allowlist` could ever
  run. beta25 release notes' #1207 closure claim was incomplete.
- **`lib/bridge-agents.sh`** — removed the early missing-return.
  Replaced with: controller-readable fast path
  (`[[ -r "$file" ]]`), else if
  `bridge_agent_linux_user_isolation_effective "$agent"`, route
  directly through `bridge_iso_run --op env-has-any-key` **without**
  the outer `bridge_isolation_can_sudo_to_agent` pre-gate (which had
  its own short-circuit). rc mapping: `0 → present`, `30 → missing`,
  `31 → missing` (semantic missing key), `32 → unreadable`,
  `20 → controller-blind`, `40 → controller-blind` (never map a
  permission failure to `missing`).
- `bridge_agent_channel_runtime_ready_for_item` at
  `lib/bridge-agents.sh:5863, 5868, 5873, 5894` now uses
  `bridge_channel_access_file_present` (the same iso-aware probe
  family the status-reason path already uses at `:6946, 6978, 7006,
  7101`), so required-channel runtime readiness and status_reason
  agree under iso v2 stale supp-groups.
- Effect: `agent start` on a fresh iso v2 agent from a stale
  controller shell no longer emits cryptic "missing MS365 client id"
  / "missing Teams app id" when the file is present.

### Fixed — #1215 `.ms365` directory created without exec bit (#1216)

- **`bridge-setup.py`** — channel-dir call sites pass explicit
  `mode=0o2770` to `_isolation_aware_mkdir` for `.teams`, `.discord`,
  `.telegram`, `.mattermost`, `.ms365`. The directory needs the `x`
  bit to be traversable; setgid keeps group inheritance.
- **`plugins/ms365/server.ts:63-67`** — `STATE_DIR` is now
  `mkdirSync(..., { recursive: true, mode: 0o770 })` plus an explicit
  `chmodSync(STATE_DIR, 0o2770)` immediately after. The explicit
  `chmodSync` repairs existing bad-mode `.ms365` directories on next
  ms365 startup (self-heal). `tokens/` and `pending/` stay `0o700`;
  token files and `.env` stay `0o600`.
- **`plugins/teams/server.ts`** — same self-heal pattern for the
  Teams `STATE_DIR`. Shared callback dirs (which have their own
  `ab-shared`/`3770` reconciler contract) are explicitly NOT touched.
- Effect: `setup teams` no longer leaves `.ms365` with mode
  `drw---S---` blocking subsequent reads; operators no longer need
  `chmod 0770 .ms365` workaround.

### Added — 4 new regression smokes (#1216)

- `scripts/smoke/1212-bridge-hooks-marketplace.sh` (7 tests) — 3-spec
  launch cmd + synthetic mirror dirs + safety/idempotency cases.
- `scripts/smoke/1213-iso-uid-predicate.sh` (8 tests) — UID-based
  predicate matrix, source guard (no mode-string lookup in
  `_under_isolated_uid()` body), bash array/scalar collision
  reproducer.
- `scripts/smoke/1214-channel-validator-iso-fallback.sh` (11 tests) —
  stub controller-blind + stub iso probe, assert
  `bridge_agent_runtime_channel_status_reason` doesn't false-miss; rc
  mapping table preserved.
- `scripts/smoke/1215-ms365-dir-mode.sh` (8 tests) — Linux-gated:
  fresh `.ms365` mode `02770`, self-heal from `02660`, `.env` and
  token files stay `0600`.
- All 4 registered in both path-arm triggers AND
  `scripts/ci-select-smoke.sh::add_all_required_static` for `__ALL__`
  scheduled sweeps.

### Fixed — CI/lint hygiene (#1216)

- 6 new H3 here-string sites in 1213/1214 smokes rewritten to
  tmpfile-staged argv form (pipe/argv-safe).
- Pre-existing C3 site at `scripts/iso-helper-smoke.sh:380` migrated
  to a new `scripts/smoke/iso-helper-smoke-py-roundtrip.py`
  file-as-argv helper (file-as-argv pattern matching
  `lib/upgrade-helpers/`). iso-helper-smoke still 25/25.
- `scripts/oss-preflight.sh::check_email_patterns` extended with
  `\bgit@github\.com:` carve-out anchored on the literal SSH URL
  prefix. Pre-existing tracked SSH-URL examples in CHANGELOG.md,
  `bridge-dev-plugin-cache.py`, `lib/bridge-agents.sh`, and
  `tests/isolation-plugin-sharing.sh` no longer trip the preflight.

### Notes

- **#1204** (`TEAMS_DELIVERY_MODE` full code removal — Sean D1 verbatim
  2026-05-26 17:22 UTC: "지워버려 필요 없는 모드잖아") — separate PR for
  beta27 or v0.15.0 wave.
- **#1209 + #1210** (MS365 OAuth: hardcoded `localhost:3978/auth/
  callback` default + scope literal quotes) — patch-dev deep-dive
  findings, beta27 / v0.15.0 scope.
- `BRIDGE_AGENT_INJECT_TIMESTAMP` same assoc-array/scalar-export
  collision class as #1213 — beta27 follow-up (commented at
  `bridge-run.sh:212`).
- Pre-existing `scripts/smoke/1121-agent-delete-os-purge.sh` C5 Linux
  flake (warning-text mismatch `RM_F_FAIL` vs `failed to remove
  sudoers drop-in`) has been failing across beta22-25 series; not
  introduced by beta26. Tracked for separate hardening.
- Adjacent hook PermissionError sites (`pre-compact.py`,
  `session_start.py` marker writers, other `bridge_hook_common`
  marker sites) — audit only, deferred to v0.15.0+ when actually
  exercised.
- Daemon supp-groups self-refresh on agent create/delete — v0.16
  systemd design item (KNOWN_ISSUES §28).

## [0.14.5-beta25] — 2026-05-26

### Highlight — OOTB first-touch closure for iso v2 + hook fail-open

Operator-cued **twenty-fifth prerelease**. Closes the last three iso v2
OOTB first-touch gaps surfaced during the beta23/beta24 acceptance verify
sweep:

- **#1205** — iso v2 hooks dump traceback on expected `PermissionError`.
  Operator perceived "agb 안돼" was actually hook stderr spam; iso v2
  filesystem boundary was working as designed. Fix wraps the two known
  uncaught sites in iso-UID-gated `try/except`; controller/shared-mode
  raise-on-error preserved.
- **#1207** — controller stale supplementary groups break
  `bridge_iso_run` allowlist canonicalization → channel-required
  validator false-misses. KNOWN §28 escalated by beta23's
  `bridge_iso_run` strict canonical gate. Fix adds a read/probe-only
  literal-path fallback that uses an isolated-side existence probe to
  distinguish stale-supp-groups vs truly-missing root. Write +
  publish-root ops stay canonical-only — beta23 symlink-ancestor
  escape protection is **not** weakened.
- **#1208** — D2 plugin manifest propagation created
  `known_marketplaces.json.lock` as `root:600`, blocking iso UID
  catalog-write at agent start. Fix keeps the lock (race protection
  between seed-side D2 and start-time catalog updates) but normalizes
  metadata to `root:ab-agent-<X> 0660`. Shell-side post-normalizer
  self-heals beta24 installs.

After this release, fresh OOTB `agent create test_iso --linux-user
--channels plugin:teams,plugin:ms365,plugin:cosmax-*` → `agent start`
should succeed without any operator `sg`, `chown`, or `chmod`.

`-beta25` prerelease; matching tag `v0.14.5-beta25`, GitHub release
marked **Pre-release**. Stay on beta per Sean's standing rule.

### Fixed — #1205 iso v2 hooks dump traceback on PermissionError (#1206)

- **`hooks/bridge_hook_common.py`** — added public `under_isolated_uid()`
  wrapper around the existing private `_under_isolated_uid()` predicate.
  `save_timestamp_state()` now wraps the entire mkdir + write + chmod
  + replace sequence in `try/except (PermissionError, OSError)`: under
  iso UID return silently; controller/shared raise. Transitively fixes
  `prompt_timestamp_context()` and `session_start.py:remember_session_start()`.
- **`hooks/tool-policy.py`** — `other_agent_homes()` wraps
  `root.iterdir()` AND `candidate.is_dir()` in the same iso-UID-gated
  pattern. Returns `[]` under iso (peer enumeration is intentionally
  blocked by iso v2 filesystem layout); re-raises under controller.
- New host-agnostic smoke `scripts/smoke/1205-hook-iso-fail-open.sh`
  with 6 tests including negative checks that controller UID and
  isolation-env-absent still raise (prevents silent swallowing of
  controller-side regressions). 5 `# noqa: iso-helper-boundary`
  annotations on smoke generator lines for ratchet.

### Fixed — #1207 stale supp-groups break bridge_iso_run allowlist canonicalization (#1211)

- **`lib/bridge-isolation-helpers.sh`** — `bridge_iso_run_path_under_allowlist`
  signature extended with `<op>` parameter; dispatcher passes it.
- New `_bridge_iso_run_collect_raw_roster_roots` mirrors
  `_bridge_iso_run_collect_canonical_roots` but returns only
  bridge-owned roster roots: `bridge_agent_workdir`,
  `bridge_agent_default_home`, `bridge_agent_linux_user_home`,
  `bridge_agent_idle_marker_dir`. `BRIDGE_ISO_RUN_ALLOWLIST_EXTRA` is
  **not** included.
- New `_bridge_iso_run_op_allows_literal_fallback` op classifier:
  allows fallback for `stat`, `read-file`, `read-json`,
  `env-has-any-key`, `read-env-key`, `scan-profile`. Rejects fallback
  for `mkdir-p`, `atomic-write`, `rename`, `state-marker-write`,
  `publish-root-file`, `publish-root-symlink` (canonical-only —
  preserves beta23 escape protection).
- New `_bridge_iso_run_iso_side_root_exists` probe uses
  `bridge_isolation_run_as_agent_user_via_bash` with `[[ -d "$1" ]]`
  / `[[ -e "$1" ]]` to confirm root visible from iso UID.
- Fallback predicate requires ALL: (a) lexically under raw roster
  root, (b) raw path + raw root have no `..` segment and are absolute,
  (c) canonical comparison failed because controller could not
  canonicalize, (d) iso-side probe rc=0.
- **`lib/bridge-agents.sh`** — diagnostic warning emitted after
  `ensure_user_in_group` when current shell's `id -G` lacks the new
  `ab-agent-<X>` group. Operator hint only; first-touch no longer
  depends on the operator following the warning.
- New smoke `scripts/smoke/1207-stale-supp-groups-allowlist.sh`
  (14 tests including positive read/probe path + negative `..` +
  negative iso-probe-missing + **negative write/publish-root must
  still rc=40** key escape-protection regression check).

### Fixed — #1208 known_marketplaces.json.lock created as root:600 blocks iso UID launch (#1211)

- **`lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`** —
  reads `BRIDGE_PLUGIN_LOCK_GROUP` env. After `os.open(lock_path, ...)`
  and BEFORE `fcntl.flock`, applies `os.fchown(fd, -1, gid)` +
  `os.fchmod(fd, 0o660)`. Falls back gracefully when env unset.
- **`bridge-plugins.sh`** — D2 call site passes
  `env BRIDGE_PLUGIN_LOCK_GROUP=$agent_group` to the Python helper.
- **`bridge_plugins_seed_propagate_iso_known_marketplaces()` post-normalizer** —
  after Python helper returns, normalizes existing
  `$iso_plugins_dir/known_marketplaces.json.lock` AND
  `installed_plugins.json.lock` (if present) to `root:$agent_group 0660`.
  Self-heals beta24 installs without `agent delete --purge-home`.
- Lock kept (NOT removed) — protects against lost read-modify-write
  races between seed-side D2 and start-time catalog updates.
- Data manifests (`known_marketplaces.json`, `installed_plugins.json`)
  remain `root:ab-agent 0640` — lock is coordination state, not
  authority over plugin allowlists.
- New smoke `scripts/smoke/1208-lock-metadata-normalize.sh` (7 tests
  including regression check that pre-existing `0600 root` lock is
  normalized to `0660` + correct group).

### Notes

- **#1204** (`TEAMS_DELIVERY_MODE` full code removal) — Sean's D1
  decision (verbatim 2026-05-26 17:22 UTC: "지워버려 필요 없는 모드잖아").
  Separate PR for beta26 or v0.15.0 wave.
- **#1209 + #1210** (MS365 OAuth: hardcoded localhost callback + scope
  literal quotes) — patch-dev deep-dive findings, beta26 / v0.15.0
  scope.
- Adjacent hook PermissionError sites (`pre-compact.py`,
  `session_start.py` marker writers, other `bridge_hook_common` marker
  sites) — audit only, deferred to v0.15.0+ when actually exercised.
- Daemon supp-groups self-refresh on agent create/delete — longer-term
  v0.16 systemd design item.

## [0.14.5-beta24] — 2026-05-26

### Highlight — seed marketplace mirror + iso v2 plugin status fail-closed

Operator-cued **twenty-fourth prerelease**. Closes #1201 + #1202 — the
two directory-source external marketplace blockers that surfaced during
beta23 OOTB acceptance verify (cosmax-ep-approval + cosmax-crm channels
on isolated v2 agents).

Codex pair-review took two rounds: r1 surfaced 3 BLOCKING (seed not
fatal on mirror failure, requested-vs-effective isolation predicate
gate, smoke ratchet regression) + 3 named SHOULD-FIX. r2 closed all
items. CI workflow ripgrep install added so `oss-preflight` no longer
fails for missing `rg` binary on the Linux runner.

`-beta24` prerelease; matching tag `v0.14.5-beta24`, GitHub release
marked **Pre-release**. Stay on beta per Sean's standing rule.

### Fixed — #1201 `agb plugins seed` doesn't create marketplace mirror (#1203)

- **`bridge-plugins.sh:bridge_plugins_seed_mirror_marketplace_root`** —
  new helper that mirrors `<source_root>` → `$plugins_cache/marketplaces/
  <marketplace_id>/` with `rsync -a` (no `--delete`), `.git/` excluded,
  canonical modes (`2750/0640`) and group `ab-shared` via
  `bridge_plugins_apply_canonical_modes` / `bridge_isolation_v2_chgrp_setgid_recursive`.
  Marketplace id validated through existing safe-alias rules; helper
  fails loudly on unsafe id, missing rsync, mkdir failure, or rsync
  failure.
- **`bridge_plugins_cmd_seed` D4 step** — mirror creation is now fatal
  for non-bundled external marketplaces. Failure path invokes
  `bridge_die` before D3/D2/`[ok] seeded` so an external marketplace
  that didn't actually mirror leaves the command in a clear error
  state, not a misleading success. Bundled `agent-bridge` marketplace
  is exempt; the existing controller fallback at
  `lib/bridge-agents.sh:1838-1844, 2006-2013` handles it as before.
- **D2 propagation uses mirror path** — `bridge_plugins_cmd_seed` now
  passes `$plugins_cache/marketplaces/$_seed_mkt_name` (the mirror) into
  per-UID D2 propagation, not the original `$marketplace_root`. The
  merge helper writes the mirror path into per-UID
  `known_marketplaces.json` so iso UIDs become controller-stable: the
  original external `/tmp/pi-registry/`-style path can disappear
  without breaking iso agents.

### Fixed — #1202 `claude plugin install` fails for directory-source marketplaces in iso v2 `agent start` (#1203)

- **`lib/bridge-agents.sh:_bridge_claude_plugin_bridge_manifest_has_spec`**
  — new helper that consults the bridge-owned manifests for plugin
  presence: per-UID `~/.claude/plugins/installed_plugins.json` first
  (via existing root/sudo path), then
  `$BRIDGE_SHARED_ROOT/plugins-cache/installed_plugins.json`. Either
  declaring the spec returns the existing `enabled` token for
  backward-compatible call sites.
- **`bridge_claude_plugin_status` short-circuit** — for **effective**
  linux-user isolated v2 agents (`! bridge_isolation_disabled_by_env &&
  bridge_agent_linux_user_isolation_effective`), bridge manifests
  win over controller `~/.claude/plugins/installed_plugins.json` and
  `claude plugin list`. Controller says missing but bridge manifest
  present → returns `enabled` → no install call. Controller says
  enabled but bridge manifest missing → returns `missing` (prevents
  masking a missing shared-cache mirror). Non-isolated / shared-mode /
  `BRIDGE_DISABLE_ISOLATION=1` agents preserve legacy install/enable
  behavior byte-for-byte.
- **`bridge_ensure_claude_plugin_enabled` fail-closed branch** — for
  effective isolated v2 + `missing`, `claude plugin install --scope
  user` no longer runs as the repair path. Bridge emits actionable
  `agb plugins seed [--marketplace-root <path>]` guidance and exits
  non-zero so the operator sees the actual root cause (mirror missing
  for a declared channel) instead of a cryptic claude CLI failure.

### Added — regression smoke

- **`scripts/smoke/1201-1202-directory-marketplace-seed.sh`** —
  10-test regression smoke covering: helper happy path + safe-alias
  rejection + canonical mode/ownership; mirror discovery via
  `bridge_known_marketplace_info`; `bridge_plugins_cmd_seed` caller-
  level fatal behavior on forced helper failure (T10); bridge-manifest
  status short-circuit recording that `bridge_ensure_claude_plugin_enabled`
  does NOT invoke a stubbed `claude plugin install` when the bridge
  manifest declares the spec; missing-spec iso path fails with seed
  guidance.
- Registered in `scripts/ci-select-smoke.sh` for `bridge-plugins.sh`,
  `bridge-dev-plugin-cache.py`, `lib/bridge-agents.sh`, and any new
  helper files.
- 4 deliberate boundary-fixture lines annotated `# noqa:
  iso-helper-boundary` so `scripts/iso-helper-ratchet.sh` (the
  beta23-introduced regression gate) recognizes them as test fixtures,
  not new raw production callsites.

### Fixed — CI: missing ripgrep blocks `oss-preflight`

- **`.github/workflows/ci.yml`** — `apt-get install -y ripgrep` step
  added to the `oss-preflight` job before `scripts/oss-preflight.sh`
  runs. Previously the Linux runner image lacked `rg`, so both
  `oss-preflight` and `iso-helper-ratchet` (also invokes `rg`)
  silently failed before any code check executed.

### Migration

- Fresh `agent create` — fixed by the new mirror + existing
  `bridge_linux_share_plugin_catalog` retrofit.
- Existing **stopped** iso agents — self-heal on next `agent start`:
  `bridge-start.sh` already re-runs `bridge_linux_share_plugin_catalog`
  before plugin ensure, so the mirror + bridge-manifest status path
  pick up automatically.
- Existing **running** iso agents — operator restart required to pick
  up the regenerated per-UID catalog and the new status logic. No
  `agent create` rerun.

### Notes

- **#1204** (`TEAMS_DELIVERY_MODE=bridge` is the silent-drop root cause,
  not a workaround) and **#1205** (iso v2 hook scripts dump traceback
  on expected PermissionError instead of failing open) are both filed
  for beta25 fast-follow. Neither blocks beta24's acceptance scenarios.
- `TEAMS_DELIVERY_MODE=bridge` should NEVER be injected into any
  agent's `.teams/.env`. Direct channel mode (MCP injection) works
  end-to-end; the bridge-mode delivery silently skips when
  `BRIDGE_AGENT_ID` is unset, which it always is from the teams plugin
  subprocess perspective.

## [0.14.5-beta23] — 2026-05-26

### Highlight — `bridge_iso_run` unified facade + 4-commit Option A convergence

Operator-cued **twenty-third prerelease**. Closes a 1-week
regression bomb (beta9 → beta22, controller-blind family) by routing every
controller→isolated-agent boundary read, write, mkdir, stat, and root-publish
operation through a single audited helper. Single PR (#1200) — codex
pair-review took two rounds: r1 surfaced a path-allowlist escape
(lexical-only gate bypassable via `..` or symlink ancestor, including for
`publish-root-file` root-published writes); r2 verified the canonicalization
fix closes all 5 escape vectors with rc=40 and target files NOT created.

iso v2 contract preserved byte-for-byte: NO ACL, NO `ab-shared` group
relaxation, NO shared-mode, NO group changes. The helper exposes two
execution classes behind one facade — agent ops (`sudo -n -u <iso-uid>`) for
agent-owned runtime files, and root-publish ops for `root:ab-agent-<X> 0640`
metadata (`installed_plugins.json`, `known_marketplaces.json`) so the
isolated UID still cannot rewrite its own plugin allowlist.

`-beta23` prerelease; matching tag `v0.14.5-beta23`, GitHub release marked
**Pre-release**. Stay on beta per Sean's standing rule.

### Added — `bridge_iso_run` unified facade (#1200)

- **`lib/bridge-isolation-helpers.sh:bridge_iso_run`** — single helper with
  12 ops: `stat`, `read-file`, `read-json`, `env-has-any-key`,
  `read-env-key`, `mkdir-p`, `atomic-write`, `rename`, `state-marker-write`,
  `scan-profile`, `publish-root-file`, `publish-root-symlink`. Structured rc
  band (`0` success / `10` not-isolated / `20` sudo-unavailable / `30` absent
  / `31` semantic-missing-key / `32` unreadable-even-to-iso / `40`
  unsafe-path).
- **Canonicalized path allowlist** (R2) — `..` segments rejected before
  canonicalization (operator-readable error signal). Canonical allowlist
  roots resolved once via `realpath` / `python3 -c
  os.path.realpath(...)` / `cd -P` fallback chain (macOS BSD compatible).
  For not-yet-created destinations the deepest existing ancestor is
  canonicalized and the tail is re-checked for `..` / symlink-ancestor
  escapes. Applied BEFORE `publish-root-file` / `publish-root-symlink`
  reach the root-published `mktemp/tee/chown/chmod/mv` chain.
- **Path allowlist roots**: `bridge_agent_workdir`,
  `bridge_agent_default_home`, `bridge_agent_linux_user_home`,
  `bridge_agent_idle_marker_dir`, plus `BRIDGE_ISO_RUN_ALLOWLIST_EXTRA` for
  smoke harness only.
- **CLI shim**: `agent-bridge iso-run --agent <a> --op <op> ...` (Python
  callers route through this; never reimplement sudo/path logic in
  Python).
- **Python adapter**: `lib/bridge_iso_paths.py:iso_run(agent, op, ...)` —
  pure `subprocess.run` shim to the CLI.
- **Footgun #11 compliance**: every op script is single-quoted bash with
  pipe-only stdin. No heredoc-stdin, no `<<<` here-string, no
  process-substitution capture in the helper body.

### Migrated — channel credential/status callsites (#1200)

- `bridge_channel_env_file_readiness`, `bridge_channel_access_file_present`,
  `bridge_agent_plugin_port_from_env_file`, `bridge_init_runtime_present`
  now route through `bridge_iso_run`. The #1196 beta22 codepath (`rc=20` /
  undefined-rc → controller-blind) is preserved byte-for-byte under the
  new rc band: rc 31 = semantic missing-key, rc 32 = unreadable from iso
  UID.
- Removed 6 stale `migrate isolation v3 --check` controller-blind operator
  guidance messages — Option A's only recovery surface is the
  passwordless sudoers entry.

### Removed — shared-mode escape-hatch (#1200)

- `bridge-start.sh` no longer suggests `BRIDGE_DISABLE_ISOLATION=1` as
  remediation option (c) on plugin-channel readiness failures. Shared-mode
  was rejected by the final contract (cross-agent token leak: cosmax-crm
  OAuth, ms365 client secret).

### Added — regression gate (#1200)

- `scripts/iso-helper-ratchet.sh` — baseline-by-count `rg` sweep on
  tracked source for raw `.env` / `access.json` /
  `installed_plugins.json` / `known_marketplaces.json` / `webhook-port` /
  `settings.effective.json` / `agent-env.sh` references. New raw callsites
  fail PR. Baseline at `scripts/baselines/iso-helper-baseline.txt`,
  whole-file allowlist at `scripts/baselines/iso-helper-allowlist.txt`.
  Wired into `scripts/oss-preflight.sh`. Sister to existing
  `scripts/lint-heredoc-ban.sh` + `scripts/lint-raw-pathlib-on-isolated.sh`.
- `scripts/iso-helper-smoke.sh` — 25 unit tests covering allowlist gate
  variants, all 12 ops, CLI shim, Python adapter round-trip, 5 escape
  vectors (`..` traversal, symlink ancestor, not-yet-created destination,
  publish-root-file dotdot escape, publish-root-symlink via symlink
  ancestor — all expecting rc=40 with target file NOT created).
- `docs/developer-handover.md` Section 8 — public contract reference.

### Compatibility wrappers (#1200) — accepted by codex r2

Documented in helper docstrings + PR body; the ratchet baseline freezes
existing raw-boundary footprint so new callsites MUST use `bridge_iso_run`:

- Plugin catalog/manifest writers
  (`bridge_write_isolated_known_marketplaces_catalog`,
  `bridge_write_isolated_installed_plugins_manifest`,
  `bridge_linux_share_plugin_catalog`,
  `bridge-plugins.sh:bridge_plugins_seed_propagate_iso_known_marketplaces`,
  `bridge-dev-plugin-cache.py:ensure_known_marketplace_for_root`,
  `bridge-dev-plugin-cache.py:_update_installed_plugins_manifest`) — retain
  inline `mktemp + python + chown + chgrp + chmod + mv -f` chain because
  refactoring through `publish-root-file` would not safely transport the
  `flock` + lock-on-same-fd patterns (especially the dev-plugin-cache
  locking pattern whose lock fd must outlive the python invocation).
- Watchdog/hooks/skills writers (`bridge-watchdog.py:scan_agent`,
  `bridge-hooks.py:cmd_render_isolated_home_settings`,
  `lib/bridge-hooks.sh:bridge_install_isolated_home_settings`,
  `lib/bridge-skills.sh:bridge_isolated_home_install_one_skill`,
  `lib/bridge-skills.sh:bridge_ensure_project_claude_guidance`) — already
  route through `bridge_linux_sudo_root` + the same controller-side
  `mktemp + chmod + chown + mv` chain. Refactoring would change behavior
  under sudo-policy expiry mid-chain without behavioral improvement.
- `bridge-discord-relay.py:load_dm_allowlist` + DM fanout — multi-agent
  iteration scope exceeded the safe single-PR budget. Captured in the
  ratchet baseline for future migration.

### Fixed — nudge duplicate firing (#1199)

- **`bridge-run.sh`** — inbox-bootstrap inject path now records the nudge
  via `bridge_task_note_nudge` after the `bridge_tmux_send_and_submit`
  call. Previously the inject path wrote no nudge audit row, so the
  daemon's next nudge tick saw empty `last_nudge_key`, computed
  `has_new_queue_ids=True`, and re-fired the same nudge — observed as
  spam during agent first-start. Tactical 5-LOC fix pushed direct to
  `stabilize/v0.14.5-vm-passes` (commit `c09383f`) to unblock beta23 cut
  without bundling into the larger #1200 PR.

### Notes

- #959 (Claude Code MCP notification handler wake bug) is **NOT** addressed
  by this release. External Anthropic bug. `TEAMS_DELIVERY_MODE=bridge`
  remains the production path; channel mode may be less likely to fail
  from local state/permission bugs after Option A but the wake gap is
  unchanged.

## [0.14.5-beta22] — 2026-05-25

### Highlight — channel-validator controller-blind + L1-D fail-closed + A2A deliver tick + bundled-plugin start hook

Operator-cued **twenty-second prerelease**. patch's beta21 verify
confirmed L1-M/N PASS but surfaced 3 P0/P1 issues blocking the 6 OOTB
acceptance gates: #1196 channel-validator iso-blind regression, L1-D
EPERM persistence with architectural root in sudo-wrap path, and #1197
A2A delivery scheduler wedge. Plus #1190/#1191 bundled-plugin
provisioning was wired only in `setup` + `upgrade`, missing fresh-
install + `agent start` path. All four closed in one PR (#1198).

`-beta22` prerelease; matching tag `v0.14.5-beta22`, GitHub release
marked **Pre-release**. Stay on beta per Sean's standing rule.

### Fixed — #1196 channel-validator iso-blind regression (#1198)

- **`lib/bridge-agents.sh:bridge_channel_env_file_readiness`** —
  single-mapping fix: `probe_rc=2` from
  `bridge_isolation_run_as_agent_user_via_bash` now maps to existing
  `controller-blind` state (NOT new `unverifiable`). Channel readiness
  enum already documents `present|missing|unreadable|controller-blind`,
  and `bridge_agent_missing_channels_csv` already excludes
  `controller-blind` from restart hard-reject (`lib/bridge-agents.sh:
  6429-6435`). Any other impossible probe error from an isolated agent
  prefers `controller-blind + diagnostic` over `missing` to avoid
  false-negative miss.

- Closes restart hard-reject on previously-working iso agents with
  valid `.teams/.env` + `.ms365/.env` files when the iso UID probe
  declines (rc=2). `setup ms365 <agent>` CLI was NOT the actual
  blocker (validator only checks `.env` keys, not `access.json`);
  deferred.

- **Regression test**: `scripts/test-channel-probe-isolated.sh`
  extended (+C5b/+C5c/+C9b) — `bridge_isolation_can_sudo_to_agent
  rc=0` + `bridge_isolation_run_as_agent_user_via_bash rc=2` →
  readiness `controller-blind` + channel stays out of
  `missing_channels_csv`.

### Fixed — L1-D EPERM cross-owner atomic-rename architectural root (#1198)

- **`bridge-start.sh`** — fail-closed when linux-user isolation
  requested + declared channels include `plugin:*` channels targeting
  iso HOME + `SUDO_WRAP_ACTIVE=0` (passwordless sudo unavailable).
  Operator guidance: enable passwordless sudo for the iso UID, OR
  remove plugin channels, OR use shared-mode isolation. Previously
  the path silently degraded to shared-mode + warn → then controller-
  side `bridge-dev-plugin-cache.py` wedged on cross-UID atomic-rename
  EPERM. Root cause was the wrong path being taken; the iso write
  helper alone wouldn't fix it when sudo itself was unavailable.

- **Race safety for shared `known_marketplaces.json` writer paths**:
  - **`bridge-dev-plugin-cache.py:ensure_known_marketplace_for_root`**
    — added sidecar `known_marketplaces.json.lock` `flock` (matches
    the pattern `merge_installed_plugins` already uses).
  - **`lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`**
    — same sidecar flock + read-under-lock.
  - Prevents lost updates when seed-side + start-path canonical
    writers race on the same per-UID file.

- **Existing helpers used** — `lib/bridge_iso_paths.py:
  write_text_atomic_as_owner` + `lib/bridge-isolation-helpers.sh:
  bridge_isolation_write_file_as_agent_user_via_bash` for agent-owned
  output targets. Canonical per-UID plugin manifests stay
  `root:ab-agent-<X>` mode 0640 (tamper-boundary contract documented
  at `lib/bridge-agents.sh:2241-2248` + `2513-2522` preserved). No new
  `bridge_iso_atomic_write` helper introduced.

### Fixed — #1197 handoff daemon scheduler wedge → bridge-daemon loop integration (#1198)

- **`bridge-daemon.sh:cmd_sync_cycle`** — new `process_a2a_deliver_tick`
  step. Throttled invocation of `bridge-a2a.py deliver` via state file
  `$BRIDGE_STATE_DIR/handoff/deliver-tick.env` (carries
  `A2A_DELIVER_NEXT_TS` / `A2A_DELIVER_LAST_TS`). Default interval
  `BRIDGE_A2A_DELIVER_INTERVAL_SECONDS=30` (`0` disables). Wrapped in
  `bridge_with_timeout` so HTTP/socket hang can't wedge the main
  daemon loop.
- No-op silently when `handoff.local.json` is absent; doesn't
  log-spam on installs that aren't A2A pairs.
- Compact tick log: `a2a_deliver tick start` / `end rc=N processed=M`.

- **NOT** a new scheduler in `bridge-handoffd.py` — that daemon's
  main loop is `ThreadingHTTPServer.serve_forever()` (receiver-only),
  no scheduler tick lives there. Real wedge is the missing main-loop
  integration of the existing `bridge-a2a.py deliver` one-shot.

- **`bridge-a2a.py outbox list`** — extended query to surface
  staleness fields without schema change:
  - `age_seconds = now - created_ts`
  - `due_for_seconds` for pending/retry rows whose `next_attempt_ts <= now`
  - `next_attempt_in_seconds` for retry rows not yet due
  - `lease_stale_seconds` for `status='sending'` with expired lease
  - Text rendering adds `due=31m` / `next=45s` / `lease_stale=3m`
    suffix to the existing list row.
  - JSON output includes all four numeric fields.

  Closes Sean's "업스트림 안 일해?" misdirection — a stuck outbox row
  is now visibly diagnosable via `agb a2a outbox list`.

- **`scripts/smoke/a2a-cross-bridge.sh`** extended (+3 cases):
  daemon-tick drains outbox to acked, no-op without config (no
  log-spam), staleness fields shown in text + JSON.

### Fixed — Bundled plugins start-time wiring (#1190 / #1191) (#1198)

- **`bridge-start.sh`** — invokes
  `bridge_provision_bundled_plugins_node_modules` before
  `bridge-dev-plugin-cache.py` sync when the agent declares
  `plugin:<bundled>@agent-bridge` channels with a `package.json`.
  Helper existed but was only wired into `setup teams` and `upgrade
  --apply` paths — fresh-install agents on `agent start` missed the
  `bun install` for ms365/cosmax-ep-approval. Idempotent (helper's
  internal staleness check at `lib/bridge-channels.sh:848-863` avoids
  unnecessary reinstall). Fails closed when bun is unavailable and a
  channel-required bundled plugin would otherwise hit a module-not-
  found at MCP startup.

### Tests

- **`scripts/smoke/a2a-cross-bridge.sh`** — +3 beta22 cases:
  daemon-tick drains outbox, daemon-tick no-op without config, outbox-
  list staleness fields. Total 16/16 PASS on the beta22 fixer's VM
  validation pass.

- **`scripts/test-channel-probe-isolated.sh`** — +C5b/+C5c/+C9b
  regression cases for the controller-blind mapping (C5b/C5c assert
  the new behavior + C9b documents the bash 3.2 macOS quirk in
  awk-extracted helpers — pre-existing, unrelated).

### Verification

- **VM acceptance** (OrbStack `agb-clean-test`, Ubuntu noble arm64,
  IN-PLACE UPGRADE from beta21) — 7-step matrix:
  - Gates 1, 2, 3, 6, 7: **PASS** (clean install + iso agent create
    + agent start with linked-verified plugins + iso REPL queue +
    daemon health OK + A2A tick drain).
  - Gate 4 (stop+start session resume): **PARTIAL** — start-path
    itself replays linked-verified cleanly on restart with no EPERM;
    the claude session crashes on stub creds (out of beta22 scope
    — real creds exercise resume continuity).
  - Gate 5 (`agent-bridge watchdog scan`): **PRE-EXISTING FAIL** —
    same `PermissionError ... CLAUDE.md` on test_iso3/5/8 on the
    base `dda10e3` commit; unrelated to beta22.

- **Pre-existing test/runtime issues observed** (NOT caused by this
  PR, verified on base):
  - `scripts/test-channel-probe-isolated.sh` C9/C9b bash 3.2 macOS
    `set -u` × empty-array footgun (defensive `local -a items=()`
    hardens but doesn't fully fix the bash 3.2 quirk; Linux + bash
    5.x unaffected).
  - `scripts/smoke-test.sh` spool-count flake (non-deterministic on
    both base and PR).
  - `1121-agent-delete-os-purge` C5 (`bridge_warn` stderr vs smoke
    stdout capture mismatch) — admin-merged via override (Phase
    2/3/L1/L2 pattern).

## [0.14.5-beta21] — 2026-05-25

### Highlight — P0 wave-1 hotfix: state-leaf + iso-uid queue + start-path catalog

Operator-cued **twenty-first prerelease**. patch's beta20 verify confirmed
3 P0 wave-1 hotfix items blocking "iso agents as first-class citizens":
session-resume break across restart, iso UID `agb task create` EACCES,
and existing-iso-agent `marketplace-mismatch` on `agent start` after
new marketplace seed. All closed in one PR (#1193) with codex r1
guidance baked into the fixer brief.

`-beta21` prerelease; matching tag `v0.14.5-beta21`, GitHub release
marked **Pre-release**. Stay on beta per Sean's standing rule.

### Fixed — L1-M state/agents/<a>/ contract aligned with grant matrix SSOT (#1193)

- **`lib/bridge-isolation-v2-reconcile.sh`** — `agent-state-leaf`
  reconciler row aligned to the existing per-agent grant matrix SSOT
  (`lib/bridge-isolation-v2.sh:1596-1622`): `controller:ab-agent-<X>:2770
  required` for linux-user agents, `controller:controller_group:2770
  required` for shared-mode. Was previously `controller:ab-shared:0710
  optional`, leaving a 5-step contract drift where iso UID couldn't
  mkdir into `state/agents/<X>/` even though the per-agent grant matrix
  expected to find it pre-created. Bridge writes (session-id, idle-since,
  compact-snapshot) now succeed on every iso agent restart.

- **Closes Claude `--resume <session_id>` failure on iso agent restart**.
  test_iso3-class agents on patch's host accumulated 5 orphan `*.jsonl`
  transcripts from successive fresh sessions; beta21 ensures session
  continuity across restart. The 5 orphan transcripts on patch's host
  stay as historical artifacts (no migration in this hotfix).

### Fixed — L1-N iso UID queue access via scoped env + roster_local skip (#1193)

- **`lib/bridge-state.sh:bridge_load_roster`** — extended scoped env
  discovery to also try the v2 runtime path
  `$BRIDGE_AGENT_ROOT_V2/<agent>/runtime/agent-env.sh` when
  `BRIDGE_AGENT_ID` is set (legacy path `state/agents/<agent>/
  agent-env.sh` checked first for back-compat). Scoped env sets
  `BRIDGE_GATEWAY_PROXY=1` so queue commands route through the
  daemon-side gateway instead of touching the SQLite DB directly,
  bypassing the protected `BRIDGE_ROSTER_LOCAL_FILE` entirely.

- **Queue-safe roster_local skip** (narrow, NOT global) — when
  scoped env discovery fails AND effective UID is non-controller
  AND `$BRIDGE_ROSTER_LOCAL_FILE` is unreadable AND the calling verb
  is a known queue-safe verb (`task create`/`done`/`claim`, `inbox`,
  `ack`), skip the source with one-shot `bridge_warn`. Non-queue verbs
  fail-closed with actionable error pointing to scoped env or controller-
  side invocation. **`BRIDGE_ROSTER_LOCAL_FILE` stays at 0600** —
  no chmod.

- **`bridge-task.sh`, `bridge-queue-gateway.py`, `agent-bridge`** —
  queue verbs wired through the new discovery + skip path.

- **`bridge-queue-gateway.py:atomic_write_json` chmod 0640 tail** —
  controller-side response writes were landing at default umask 077
  (0600 owned by controller), blocking the iso UID's response poll
  even after L1-N unblocked the request side. `os.chmod(tmp, 0o640)`
  + the setgid parent dir's ab-agent-<X> group inheritance gives
  BOTH sides group read. Surface bounded by per-agent group
  composition (controller + the iso UID).

### Fixed — L1-D canonical share_plugin_catalog on start/restart path (#1193)

- **`bridge-start.sh`** — calls `bridge_linux_share_plugin_catalog
  "$os_user" "$user_home" "$controller_user" "$AGENT"` immediately
  after `bridge_write_linux_agent_env_file` and before SESSION_CMD
  launch (Linux-only). Was previously only invoked during
  `bridge_linux_prepare_agent_isolation` (agent create / reapply
  flows), missing the case where an operator seeds a new marketplace
  AFTER agent create.

- Uses the CANONICAL writer (not the seed-only D2 merge helper from
  beta20 PR #1189). Per-UID `known_marketplaces.json` +
  `installed_plugins.json` + marketplace symlinks re-derived from
  shared cache on every start/restart, overwriting stale/manual
  entries. **Closes the "operator drifted existing iso agent →
  marketplace-mismatch" regression** patch flagged on beta20 verify.

- `BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1` mode skips the share
  call (preserves suppress-aware launcher contract). Normal start
  with missing shared cache fails loud per existing UX.

### Tests

- **NEW `scripts/smoke/l1n-iso-uid-queue-roster-skip.sh`** — exercises
  scoped env v2-runtime-path discovery and queue-safe roster_local
  skip. Fixture simulates iso UID context (non-controller UID,
  unreadable roster_local) + verifies `task create` succeeds via
  scoped env + gateway, and a non-queue command fails-closed.

- **`scripts/smoke/phase2-install-tree-reconciler.sh`** extended —
  asserts `agent-state-leaf` row uses `2770 ab-agent-<X> required`
  for linux-user agents.

### Verification

- **VM acceptance** (OrbStack `agb-clean-test`, Ubuntu noble arm64,
  IN-PLACE UPGRADE from beta20) — 8-step matrix PASS per fixer
  report (state-leaf 2770, restart preserves session resume,
  `agb task create` from iso UID via gateway, `agent start` re-applies
  marketplace catalog, `agent-bridge isolation reconcile --check
  --agent <X>` agent-state-leaf row OK).

- **Pre-existing CI fragility unchanged** — `1121-agent-delete-os-purge`
  C5 (`bridge_warn` stderr vs smoke stdout capture mismatch) still
  fails on `main` / `stabilize` independent of this PR. Merged via
  admin override (Phase 2/3/L1/L2 pattern).

## [0.14.5-beta20] — 2026-05-25

### Highlight — L2 daemon supp-groups refresh + L1 wave 2 plugin-install closure

Operator-cued **twentieth prerelease**. Two parallel tracks land in
beta20 closing the v0.14.5 isolation wave's remaining UX gaps:

- **L2 Variant 3A (PR #1188)** — automatic daemon supplementary-groups
  refresh via sudo + passwordless sudoers + sudo-wrapped systemd-user
  ExecStart. Closes patch's 3 phase3-pass supp-groups family symptoms.
  GID actually lands in `/proc/<daemon_pid>/status` Groups after
  `agent create --linux-user` — architectural fix verified.

- **L1 wave 2 (PR #1189)** — 6 plugin-install gaps (A/D/F/G + J/K)
  closed in one PR. External-marketplace install, per-iso known_
  marketplaces propagation, bundled-plugin `bun install` at upgrade
  time, node version probe with fail-soft.

Sean's standing directive: stay on beta tags. rc1 / v0.15.0 promote
remains operator-explicit-go. `-beta20` prerelease; matching tag
`v0.14.5-beta20`, GitHub release marked **Pre-release**.

### Fixed / Added — L2 Variant 3A: automatic daemon supp-groups refresh (#1188)

- **`lib/bridge-daemon-control.sh` (NEW, ~898 lines)** — public helper
  `bridge_daemon_refresh_after_group_membership_change --group <name>
  --reason <text> [--dry-run]`. Detects `/proc/<daemon_pid>/status`
  Groups drift, acquires non-destructive lock, attempts fresh-credential
  restart via sudo, polls new daemon, verifies GID present. Status
  contract: `ok|ok-systemd-sudo-self|skipped-non-linux|
  skipped-daemon-not-running|skipped-daemon-already-has-group|
  manual-required-sudoers|manual-required-sudo-refresh-no-gid|
  manual-required-systemd-unit-stale|failed-restart|failed-timeout|
  failed-systemctl-restart|failed-systemd-refresh-no-gid`. systemd
  active path uses `systemctl --user restart`, non-systemd path uses
  direct `sudo -n -u <controller> bridge-daemon.sh restart`. Lock
  contention re-checks under lock before mutating.

- **`scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template`
  (NEW)** — generator template, 2 authorized commands: `bridge-daemon.sh
  restart --force --internal-reason=group-refresh` (r3) AND `bridge-
  daemon.sh run` (r4 — sudo-wrapped systemd ExecStart). Named user,
  absolute paths, no wildcards, `SETENV: BRIDGE_*` whitelist.

- **`scripts/install-daemon-systemd.sh`** — auto-detects daemon-refresh
  sudoers; when present, renders systemd-user unit with sudo-wrapped
  ExecStart + `Environment=BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self`
  marker. Keeps `KillMode=process` and `Restart=always` semantics.

- **`bridge-daemon.sh`** — `cmd_restart --internal-reason=group-refresh`
  bypasses operator-facing bare-stop active-agent guard. Audit log entry.

- **`agent-bridge init sudoers daemon-refresh --apply|--check`** — CLI
  to install/regenerate/verify sudoers from template with `visudo -cf`
  validate + atomic install at mode `0440 root:root`.

- **4 hook sites** (`bridge-agent.sh:cmd_create` + `cmd_delete`,
  `lib/bridge-migration.sh` isolate first-time + --reapply) — call
  helper after group membership mutation. Refresh is non-fatal —
  agent operation completes regardless of refresh result. Output:
  `daemon_group_refresh: <status>` in text + JSON.

- **`bridge-init.sh` + `bridge-upgrade.sh`** integration — Linux
  server profile: sudoers first → unit regen (sudo-wrapped if sudoers
  ok) → daemon-reload → restart-if-active.

### Fixed / Added — L1 wave 2: plugin-install gaps for external marketplaces (#1189)

- **A: `bridge_plugins_cmd_seed` propagates marketplace to controller
  registry** — calls `claude plugin marketplace add` on controller
  after seeding the shared cache. Idempotent (skips if list already
  contains entry). Closes "Plugin not found in marketplace" on first
  `agent start` after external-marketplace seed.

- **D: same seed propagates to per-iso `known_marketplaces.json`** —
  writes root-owned `/home/agent-bridge-<a>/.claude/plugins/
  known_marketplaces.json` mode `0640 root:ab-agent-<a>` for each iso
  agent whose channels reference the target marketplace.
  `lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`
  (file-as-argv, no heredoc) does the JSON merge.

- **F: external marketplace clone dir gets `o+rX` recursive** — when
  seeding from a `--marketplace-root` under operator HOME on Linux
  with iso isolation active, `chmod -R o+rX` so iso UIDs can read
  the marketplace source. Opt-out via `--no-iso-chmod`.

- **G: `plugins-channel-trees` row converges from absent state** —
  reconciler row switched to use shell glob iteration over actual
  plugin subdirs (`teams`, `ms365`, `cosmax-marketplace`, etc.) with
  per-subdir individual rows (`plugins-channel-tree-<name>`). Was
  emitting `skipped (absent)` literal glob row that didn't walk
  per-channel dirs; now emits one optional `dir_recursive` row per
  detected plugin subdir.

- **J: bundled-plugin `bun install` at install/upgrade time** —
  `lib/upgrade-helpers/bundled-plugins-bun-install.sh` (new, file-as-
  argv). Walks `$BRIDGE_HOME/plugins/<name>/` and runs `bun install`
  when package.json exists and node_modules is absent/stale. Wired
  into `bridge_provision_teams_plugin_runtime` and `bridge-upgrade.sh`.

- **K: node version probe with fail-soft** — install/upgrade emits
  `[bundled-plugins][node-check] node v<X> OK (>= 14)` or warns
  `node v<X> < 14 — bundled plugins may fail to spawn. Install via
  your package manager or nvm install --lts.` Non-fatal; lets the
  install continue.

### Fixed — 3 heredoc-stdin sites caught by lint baseline ratchet

- **`bridge-plugins.sh:535`** `done <<<"$eligible"` → materialize to
  `mktemp` file, read via `< "$tmp"`, cleanup after loop.
- **`bridge-plugins.sh:551`** `IFS=',' read -r -a items <<<"$csv"` →
  parameter-expansion split loop (no subprocess, no tmp file).
- **`lib/bridge-isolation-v2-reconcile.sh:1107`** `done < <(compgen -G
  "$data_root/plugins/*")` → shell glob + nullglob save/restore.
- **`bridge-upgrade.sh:2274`** redirect `install-daemon-systemd.sh
  --apply` stdout to stderr so the new sudoers/systemd integration
  doesn't pollute `agent-bridge upgrade --json` envelope.

### Tests

- **`tests/daemon-control/smoke.sh` (NEW, 28 cases)** — 21 r3 unit
  smokes (parser, lock, status strings, sudoers template render,
  visudo validation, helper invocation) + 7 r4 unit smokes (systemd
  branch detection, sudo-wrapped unit shape, `manual-required-systemd-*`
  paths, drift detector on `/proc/.../status`).

- **`scripts/smoke/phase2-install-tree-reconciler.sh`** — T1 asserts
  per-channel `plugins-channel-tree-<name>` rows appear in matrix;
  T9 new functional fixture for L1 wave 2 row converge-from-absent
  flow.

### Verification

- **L2 VM acceptance** (OrbStack `agb-clean-test`, systemd-user Linux):
  5+1 PASS. `/proc/<daemon_pid>/status` Groups contains `ab-agent-
  test_iso5` GID 980 after `agent create` (architectural fix verified).
  Process tree: systemd-user → sudo → bash bridge-daemon.sh run.
  `bridge-send.sh --urgent` lock writes succeed. `agent restart`
  channel readiness without `sg` wrapper.

- **L1 wave 2 VM acceptance** (in-place upgrade beta19 → branch):
  8/8 PASS. Controller's `claude plugin marketplace list` includes
  seeded external marketplace, iso UID's `known_marketplaces.json`
  contains the entry mode 0640, fixture clone dir traversable by iso
  UID, `resolve_marketplace_root` from iso UID resolves correctly.
  Bundled `bun install` ran on ms365 + mattermost from absent state.
  Iso UID `bun -e 'import {Server} from "@modelcontextprotocol/sdk/..."'`
  returns within 1s.

- **Pre-existing CI fragility unchanged** — `1121-agent-delete-os-purge`
  C5 / `1140-purge-home-os-cleanup` C4 / cron-shell-runner T36b timing
  flake fail on `main` and `stabilize` independent of this PR. Both
  merged via admin override (Phase 2 pattern).

## [0.14.5-beta19] — 2026-05-25

### Highlight — beta19 L1 wave: install-tree row expansion + Teams shim + bun traversal

Operator-cued **nineteenth prerelease**. After Phase 3 (beta18) PASSED
its bidirectional Cosmax Teams DM gate, patch's [phase3-pass] report
surfaced 5 new findings — all surfaced AFTER the contract baseline
closed, all manual-workaround-able but architecturally Phase 2-row-shaped.
Sean directive: keep iterating — rc1/v0.15.0 holds until L1+L2 close.
This is L1. L2 (Variant 3 admin-driven daemon self-restart) follows.

`-beta19` prerelease; matching tag `v0.14.5-beta19`, GitHub release
marked **Pre-release**.

### Fixed / Added — Install-tree row expansion (5 new state-scaffold rows) (#1187)

- **`lib/bridge-isolation-v2-reconcile.sh`** — 5 new `state_scaffold`
  rows. Codex r1 corrected the brief: `dir` kind does NOT mkdir absent
  dirs (`lib/bridge-isolation-v2-reconcile.sh:330-340`), so writer
  paths created on first inbound (Teams callbacks, channel activity
  index) needed `state_scaffold`:

  | Row | Path | Owner:Group | Mode | Notes |
  |---|---|---|---|---|
  | `shared-ms365-callbacks-dir` | `$BRIDGE_HOME/shared/ms365-callbacks` | controller:ab-shared | **3770** | sticky+setgid+group-write — writers create/unlink callback files; sticky prevents cross-UID delete |
  | `state-channels-root` | `$BRIDGE_HOME/state/channels` | controller:ab-shared | 0710 | parent traverse only |
  | `state-channels-teams-dir` | `$BRIDGE_HOME/state/channels/teams` | controller:ab-shared | **3770** | isolated Teams writer creates `<agent>.json`; sticky limits cross-agent overwrite |
  | `state-queue-dir` | `$BRIDGE_HOME/state/queue` | controller:ab-shared | 0710 | iso UID `agb inbox` access (closes the 30s gateway-timeout symptom) |
  | `state-queue-bodies-dir` | `$BRIDGE_HOME/state/queue/bodies` | controller:ab-shared | 0710 | sibling per `bridge-queue.py:310-315` body storage |

### Fixed — Teams plugin runtime (#959 + activity-index mode) (#1187)

- **`plugins/teams/server.ts`** — local `createExpressResponseShim`
  wraps the native `http.ServerResponse` for `processActivity(req, res, ...)`
  calls (the `/api/messages` path only). Implements `status(code)` and
  `send(body)` with Buffer/string/object/null variants. Closes #959
  (TypeError 500 since first commit `9bbb09e` — BotFrameworkAdapter
  expects Express-style response, was passing native HTTP res).
  Migration to `CloudAdapter.processActivityDirect` is the cleaner
  long-term answer but out of scope for this stabilization PR.

- **`plugins/teams/server.ts`** `writeTeamsActivityIndex` — tmp file
  write at `0640`, chmod final file `0640` post-rename. Reason: the
  activity-index lives under `state/channels/teams/<agent>.json` and
  is created by the isolated Teams writer UID. The controller daemon
  route lookup (`bridge-channels.py:289-304`) must read it; the
  previous `0600` mode blocked that. Setgid on the parent directory
  (mode 3770) makes group `ab-shared`, so the controller can read
  the file while world stays locked out.

- **NEW `_smoke-shim` CLI subcommand** for plugin smoke fixtures.

### Fixed — Bun runtime traversal for isolated UIDs (#1187)

- **`lib/bridge-channels.sh`** — new helper
  `bridge_ensure_bun_runtime_traversable_for_isolated`. When `bun` is
  installed under `$HOME/.bun/` (the common bun installer default),
  `chmod o+x` on `$HOME/.bun` and `$HOME/.bun/bin` so isolated UIDs
  can traverse the symlink chain to the real `bun` binary. **Closes the
  "Teams MCP tool 없네요" symptom**: PATH-visible `/usr/local/bin/bun`
  pointed at `$HOME/.bun/bin/bun`, and isolated UIDs could not
  traverse `$HOME/.bun` (mode 0700) → bun missing from iso PATH → Teams
  MCP server never spawned. Helper is no-op when bun lives elsewhere,
  no-op on non-Linux, and opt-out via `BRIDGE_BUN_CHMOD_OPT_OUT=1`.

- **`lib/upgrade-helpers/bun-traverse-chmod.sh` (NEW)** — standalone
  helper invoked from `bridge-upgrade.sh` (file-as-argv, no heredoc-
  stdin per footgun #11). Wired after the install-tree reconciler pass
  during upgrade, so in-place upgraders (patch's beta19 verify path)
  pick up the traverse fix without a fresh `agb setup teams`.

- **`lib/bridge-channels.sh:bridge_provision_teams_plugin_runtime`** —
  helper invoked after Bun resolved/installed and before node_modules
  provisioning. Keeps the PR #1090 invariant intact (setup still
  requires PATH-reachable bun, doesn't fallback to `$HOME/.bun/bin/bun`
  symlink-only).

### Tests

- **`scripts/smoke/phase2-install-tree-reconciler.sh`** — T1 extended
  to assert all 5 new L1 rows appear in matrix output; T9 NEW
  functional fixture starts from absent dirs, runs `--apply`, asserts
  exact owner/group/mode (`3770` writer dirs, `0710` parent dirs);
  T3 idempotence Linux-gated for macOS sticky-bit limitation.

- **`scripts/smoke/teams-shim-roundtrip.sh` (NEW, 6 variants)** —
  pipes 6 response variants (Buffer / string / object / null /
  double-send / write-after-end) through `createExpressResponseShim`
  with a fake native response and asserts contract: status code set,
  body once, content-type inferred for objects.

- **`scripts/smoke/bun-runtime-traverse.sh` (NEW, 3 cases)** —
  fixture-based test of the bun helper: under-HOME bun → traverse
  bits added (o+x, NOT o+r); opt-out → no chmod; non-HOME bun →
  no-op.

- **`tests/precompact-notify/teams-mattermost-adapter.sh`** — T9
  asserts activity-index file mode is `0640`.

### Verification

- **VM acceptance** (OrbStack `agb-clean-test`, Ubuntu noble arm64,
  IN-PLACE UPGRADE from beta18) — 8 steps PASS:
  1. `agent-bridge upgrade --apply --channel current` — 126 files
     copied, bun-traverse helper fired during upgrade.
  2. `reconcile --check --all-agents --json` — all 5 new L1 rows
     `status: ok` (3770/0710/3770/0710/0710).
  3. Reused `test_iso3` from Phase 3.
  4. Bun-traverse verified: `~/.bun` and `~/.bun/bin` widened from
     0750 → 0751 (traverse-only, no read bit). Iso UID
     `bun --version` → `1.3.14`.
  5. `agb inbox test_iso3` from iso UID returns in **0.15s** (was
     30s gateway timeout pre-fix).
  6. Teams shim via `_smoke-shim`: `endCalls=1, statusCode=202,
     contentType=application/json`, no TypeError. `processActivity`
     500 closed.
  7. Iso UID writes `shared/ms365-callbacks/iso-test-state-*.json`
     (rc=0); file lands `agent-bridge-test_iso3:ab-shared 664` via
     setgid.
  8. Iso UID writes `state/channels/teams/test_iso3.json` via
     `_smoke-record-activity`: mode `0640`, group `ab-shared`,
     controller `json.load(...)` parses cleanly.

- **Known carryover** — Phase 3 `plugins-channel-trees` row
  (`dir_recursive` over `$BRIDGE_HOME/plugins/*`) reports `skipped`
  on absent-on-fresh state. Manual `chgrp -R ab-shared` +
  `chmod -R g+rX` unblocks the activity-index write smoke step.
  Recursive row needs converge-from-absent enhancement; folded into
  the next reconciler-row pass (does not block beta19).

- **Pre-existing CI fragility unchanged** — `1121-agent-delete-
  os-purge` C5 / `1140-purge-home-os-cleanup` C4 / `mattermost-plugin`
  (CI bun, VM no-bun) fail on `main` and `stabilize` independent of
  this change. Separate follow-up.

## [0.14.5-beta18] — 2026-05-25

### Highlight — Phase 3 isolation contract fix (8 gaps + restart-reverter regression)

Operator-cued **eighteenth prerelease** cut for remote-host
re-verification of Phase 3 — patch's clean install on `v0.14.5-beta17`
surfaced 8 isolation contract gaps and the architectural restart-
reverter (workarounds reset on every `agent restart`). codex r1
implement-ok; single-PR fixer (#1186) closes all 8 gaps + the
restart-reverter root cause.

`-beta18` prerelease; matching tag `v0.14.5-beta18`, GitHub release
marked **Pre-release**.

### Fixed / Added — Install-tree row expansion + isolated HOME contract helper (#1186)

- **`lib/bridge-agents.sh`** — new helper
  `bridge_linux_normalize_isolated_home_contract "$agent" "$os_user"
  "$user_home"`. Normalizes the isolated-UID's HOME root
  (`$os_user:ab-agent-<a>` mode `2750`) + `.claude/`, `.claude/plugins/`,
  `.claude/session-env/` (`root:ab-agent-<a>` mode **`3770`**: sticky +
  setgid). Symlink rejection + path-anchor guard
  (`BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT`) + live-tmux-session refuse
  (override via `BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1`). Sticky mode
  preserves the integrity boundary on root-owned `settings.json` /
  `settings.effective.json` (isolated UID cannot unlink), while the
  group-write bit unblocks the SessionStart hook's `.claude/session-env`
  mkdir via the supplementary-group path. Operator override available:
  `BRIDGE_ISO_HOME_CONTRACT_MODE=2770` falls back to non-sticky with a
  `bridge_warn` audit line.

- **3 helper call sites** route through the new function:
  1. `bridge_linux_prepare_agent_isolation` (agent-create path) —
     replaces the inline `chgrp` + `chmod 2770` block.
  2. **`bridge_install_isolated_home_settings` at
     `lib/bridge-hooks.sh:530-535` — THE restart-reverter**. Was
     recreating `.claude` as `root:$os_user 0750` after every restart,
     reverting the prepare-side contract. Now delegates to the helper.
     **Closes #1165 Gap 2 regression at the architectural root**, not
     the symptom.
  3. `bridge_auth_prepare_credential_file` (credential-prepare isolated
     branch) — replaces the inline `mkdir/chown $os_user:$primary_group/
     chmod 0700` parent-dir step. Token sync helper PermissionError on
     isolated agent credentials path now closed (no `sg ab-agent-<a>`
     wrapper needed).

- **4 new install-tree reconciler rows** in
  `lib/bridge-isolation-v2-reconcile.sh` (controller-side HOME tree):
  - `claude-plugin-dir` — `$BRIDGE_HOME/.claude-plugin` owner controller
    group ab-shared mode 0750 (optional when absent).
  - `plugins-root` — `$BRIDGE_HOME/plugins` owner controller group
    ab-shared mode 0750 (readable root for plugin discovery; optional
    when absent).
  - `plugins-channel-trees` — `$BRIDGE_HOME/plugins/*` group ab-shared
    `g+rX` recursive (`dir_recursive`; protected-path guard active).
  - `agents-root` — `$BRIDGE_HOME/agents` owner controller group
    ab-shared mode 0710 (required: iso UID traverse, no list).

- **New row kind `agent_home_contract`** in the reconciler with
  `mechanism=helper:bridge_linux_normalize_isolated_home_contract`,
  emitted only when `--agent` is provided. 4 child rows from the helper
  (HOME / `.claude` / `.claude/plugins` / `.claude/session-env`).
  Computed literal `os_user` and literal `agent_group` inside
  `bridge_isolation_v2_install_tree_matrix_rows` — the existing token
  resolver doesn't handle `agent_user` / `ab-agent-<a>` tokens.

- **`lib/bridge-isolation-v2.sh:1659-1662`** — stale
  `isolated-user-home` matrix text updated (`0700` → `2750`) so a
  future audit doesn't find conflicting contract documentation.

### Fixed — Reconciler parse path (footgun #11 H3 recurrence)

- **`lib/bridge-isolation-v2-reconcile.sh`** — replace `<<<` here-string
  tab-split with pure parameter expansion. The here-string class is
  the same Bash 5.3.9 footgun the lint baseline ratchet refuses; no
  subprocess, no tmp file, no procsub — just `${var%%$'\t'*}` /
  `${var#*$'\t'}` chains.

### Tests

- **`scripts/smoke/phase3-agent-home-contract.sh` (NEW)** — 7 cases
  covering helper signature, Linux gate, path-anchor guard, symlink
  rejection, live-session rejection, sticky/non-sticky mode toggle,
  reconciler dispatcher registration. Registered alongside phase2
  smoke in `scripts/ci-select-smoke.sh`.

- **`scripts/smoke/phase2-install-tree-reconciler.sh`** T1 asserts the
  4 new install rows appear in matrix output.

- **`scripts/smoke/1165-track-a-scaffold-modes.sh`** T2/T2b/T2c
  updated: fails if `bridge_install_isolated_home_settings` (and the
  prepare path) contains `chown "root:$os_user" "$target_dir"` or
  `chmod 0750 "$target_dir"`; passes only when the helper is called.
  Closes the smoke-coverage gap that let the #1165 Gap 2 regression
  through to beta14 → beta17.

- **`tests/isolation-claude-read-lens/smoke.sh`** updated to follow
  the helper delegation: asserts prepare path calls the helper +
  helper body contains the mkdir/chown/chmod primitives,
  ab-agent-group resolution, and `3770` default mode.

- **`scripts/smoke/1118-v2-engine-binary-path.sh`** — T1/T1b/T1c now
  pin `BRIDGE_DATA_ROOT` alongside `BRIDGE_LAYOUT=v2`. Phase 2's
  `BRIDGE_LAYOUT=v2`-only pin was incomplete: the validator at
  `lib/bridge-layout-resolver.sh:128-141` rejects partial env
  override (requires both vars together) and falls through to
  fresh-install-candidate hard-die. Closes the latent fail that
  Phase 2 PR admin-merged with.

### Verification

- **VM acceptance** (OrbStack `agb-clean-test`, Ubuntu noble arm64)
  — 8 steps PASS via fixer's destructive clean-install repro:
  bridge-init.sh OK; iso agent create OK; reconcile `--check` rc=0
  across all rows including the 4 new Family 1 + 4 new
  `agent_home_contract`; agent start + restart preserves contract on
  all 8 paths from patch's table (**architectural fix verified**);
  iso UID can mkdir `.claude/session-env` + `.claude/plugins`;
  controller HOME `.claude-plugin` / `plugins` / `agents` traversable
  by iso UID; token sync without `sg` wrapper succeeds; sticky bit
  blocks iso UID unlink of root-owned settings files.

- **Pre-existing CI fragility (unchanged)** — `1121-agent-delete-os-purge`
  C5 / `1140-purge-home-os-cleanup` C4 / mattermost-plugin (CI bun)
  fail on `main` and `stabilize` independent of this change.
  `bridge_warn` stderr vs smoke stdout capture mismatch; separate
  follow-up.

## [0.14.5-beta17] — 2026-05-25

### Highlight — declarative install-tree reconciler (Phase 2 architectural refactor)

Operator-cued **seventeenth prerelease** cut for remote-host acceptance
of the Phase 2 refactor. After eight A2A-driven QA cycles (beta9-beta16)
applied helper-layer fixes (#1165 → #1170 → #1175 → #1178), Phase 1 VM
testing on `agb-clean-test` proved the install tree itself was never
designed for v2 isolated UID access. Phase 2 replaces the accreted
inline chmod/chgrp patches with a single declarative matrix +
reconciler. Stabilization-mode release: codex pair-review was skipped
on the merge (per the operator's mode-switch directive); the
verification gate is remote-host clean install + bidirectional Teams
DM on the acceptance peer.

`-beta17` prerelease; matching tag `v0.14.5-beta17`, GitHub release
marked **Pre-release**.

### Fixed / Added — Declarative install-tree reconciler (#1180)

- **`lib/bridge-isolation-v2-reconcile.sh` (NEW, ~1151 LOC)** —
  declarative matrix + reconciler owning install-tree ownership and
  mode contracts for v2 isolation. 7 row kinds (`path_traverse`,
  `dir`, `dir_recursive`, `file_glob`, `state_scaffold`,
  `credential_grant`, `marker_read_path`). Public API:
  `bridge_isolation_v2_apply_install_tree_matrix --mode check|apply
  [--agent <name>|--all-agents] [--reason install|upgrade|
  agent-create|manual] [--json]`. Deny-by-default protected-path
  guard refuses `agent-roster*`, `handoff.local*`, `*.pem`/`.key`/
  `.token`, `.credentials.json`, `state/history/`, `runtime/
  credentials|secrets/`, `*.lock`.

- **Four invocation triggers** — install (bridge-init), upgrade
  (`bridge-upgrade.sh --apply` via `lib/upgrade-helpers/
  isolation-v2-reconcile.sh`), agent-create
  (`bridge_linux_prepare_agent_isolation`), and manual operator
  escape hatch (`agent-bridge isolation reconcile [--check|--apply]
  [--agent <X>|--all] [--json]`).

- **`bridge_isolation_v2_migrate_normalize_layout`** — Layer 13/14
  inline chmod/chgrp block (commits `195be18` + `36fb70f` on the
  stabilize branch) removed; the reconciler owns the same surface
  through declarative rows with the per-row protected guard.

- **Layer 17 marker writer guard** — `lib/bridge-marker-bootstrap.sh`
  gains `_bridge_marker_writer_is_controller_uid`. Marker writers
  (`bridge_isolation_v2_migrate_marker_write` +
  `bridge_isolation_v2_migrate_marker_write_minimal`) refuse the
  write when the effective UID is neither root nor the controller,
  closing the Phase 1 VM failure mode where an isolated UID under a
  stray sudo-handoff tried to write the marker into its own home.

- **Dispatcher `BRIDGE_CONTROLLER_UID` recovery refinement** —
  the `agent-bridge` dispatcher recovery block (added in beta14 #1165
  Gap 8) now skips when `marker_owner == 0`. After the #1161 marker
  chown contract (root-owned marker), the recovery's read of the
  marker owner produced `BRIDGE_CONTROLLER_UID=0`, mis-resolving
  every downstream `controller` token to root.

### Added — Python helper lift (Phase 2 D7)

- **`lib/bridge_iso_paths.py`** — three new canonical helpers:
  `safe_realpath`, `ensure_dir`, `write_text_atomic_as_owner`.
  Consumers (`bridge-hooks.py`, `bridge-setup.py`,
  `bridge-watchdog.py`) updated to delegate to the canonical names;
  the bash inline atomic-write script body lives once in the module
  rather than duplicated across consumers.

- **`scripts/lint-raw-pathlib-on-isolated.sh`** scope expanded from
  two files (`bridge-setup.py` + `bridge-hooks.py`) to all
  `bridge-*.py` at repo root via glob-at-lint-time. Baseline
  regenerated; ratchet ceilings recorded for 42 files (~860 sites).
  New sites must explicitly `noqa` or refactor through the canonical
  helpers.

### Tests

- **`scripts/smoke/phase2-install-tree-reconciler.sh`** — 8-case
  smoke covering matrix-row generation, `--check` drift detection,
  `--apply` idempotency, state-scaffold creation, credential-grant
  routing, marker non-write guard from isolated UID, protected-files
  exclusion, and regression boomerang.

- **`scripts/smoke/{1120,1139,1145}-*.sh`** — patched to monkey-patch
  the canonical `bridge_iso_paths.sudo_run_as` in addition to the
  `bridge-hooks._sudo_run_as` alias, restoring stub recording after
  the D7 helper lift moved the actual escalation into the canonical
  module.

- **`scripts/smoke/1118-v2-engine-binary-path.sh`** — T1/T1b/T1c
  pin `BRIDGE_LAYOUT=v2` in the inner subshell so the layout
  resolver takes the env-override path on a fresh CI checkout
  without a `state/layout-marker.sh` on disk.

### Verification

- **VM acceptance** (OrbStack `agb-phase2-fresh`, Ubuntu noble
  arm64) — destructive clean install on a fresh VM: `bridge-init.sh`
  fresh-install path OK, v2 marker written; first isolated agent
  create OK with auto-provisioned `ab-shared` + `ab-agent-worker`
  groups and `2770 root:ab-agent-worker` workdir; reconciler
  `--check` 9/10 rows OK; smoke sweep 110/113 PASS (3 pre-existing
  fails: missing `bun` on bare VM, plus #1121+#1140 which also fail
  on `main`).

- **Known cosmetic follow-up** — #1182 `runtime-dir` reconciler row
  reports `mismatch` when `runtime/` is empty on a fresh install
  (probe falls back to `(none)`; actual perms are correct).
  Non-blocking, scheduled for the next reconciler-row pass.

## [0.14.5-beta16] — 2026-05-24

### Highlight — exhaustive pathlib audit + canonical helper extraction (#1175 — eighth A2A QA cycle)

Operator-cued **sixteenth prerelease** — eighth cycle of the A2A-driven
QA loop, and the first to apply operator-coaching directly: cycles 9-10
had each fixed one site of the same family with the next call surfacing
the same bug. Operator decision: exhaust-audit + single PR closes the family.

Remote QA peer audited `bridge-setup.py` + `bridge-hooks.py` end-to-end
and filed #1175 with the full inventory (4 HIGH in bridge-setup.py,
14 HIGH in bridge-hooks.py). Single-PR wave (PR #1176). Two-round
codex chain (r1 BLOCKING found a hidden sibling beyond patch's
inventory: `next_backup_path` whitelisted but callsite gap → r2
implement-ok). Integration r1 implement-ok (task #6093).

`-beta16` prerelease; matching tag `v0.14.5-beta16`, GitHub release
marked **Pre-release**.

### Fixed — Canonical safe-path helpers + exhaustive sweep (#1175 subsumes #1173)

- **#1175 (PR #1176)** — 4 deliverables:

  1. **`lib/bridge_iso_paths.py` (NEW, 517 LOC)** — canonical shared
     module consolidating 7 previously-duplicated helpers:
     `_isolated_workdir_owner`, `_resolve_isolated_owner_for_path`,
     `sudo_run_as` (int rc) + `sudo_run_as_capture` (CompletedProcess),
     `safe_path_check`, `safe_read_env`, `safe_load_json`,
     `_parse_dotenv_text`. Both `bridge-setup.py` and `bridge-hooks.py`
     import from the shared module.

  2. **`bridge-setup.py` sweep** — 4 HIGH sites rewritten through
     safe wrappers (including L392 `_isolation_aware_mkdir` which was
     patch's next reproducer on beta15).

  3. **`bridge-hooks.py` sweep** — 14+ HIGH sites rewritten
     (PostToolUse paths — the traceback-flood source — all guarded;
     closes the #1173 sister).

  4. **`scripts/lint-raw-pathlib-on-isolated.sh`** + baseline file —
     hard CI fail when new raw `Path.exists()` / `is_file()` / etc
     lands outside the canonical wrappers or the
     `# noqa: raw-pathlib-controller-only` whitelist. Baseline starts
     at 0/0.

  Two review rounds: r1 BLOCKING — codex caught a hidden sibling
  beyond patch's inventory: `next_backup_path` was whitelisted via
  noqa but its only callsite (`cmd_link_shared_settings`) only
  established sudo-readable existence, not controller-readable. On a
  blind isolated dir the raw `candidate.exists()` raises before the
  intended sudo-backed `shutil.copy2`/`rm` recovery → wedged
  `HOOK_STATUS=permission_denied` even though the function has sudo
  fallback machinery. r2 made `next_backup_path` accept an `os_user`
  kwarg, routed the collision probe through `safe_path_check`,
  removed the noqa exemption. Boomerang regression test T4b verified:
  revert the fix → exact `PermissionError(13)` shape from r1 returns.

  Smoke `1175-exhaustive-pathlib-audit.sh` carries 13 cases including
  T5 lint self-test/check/boomerang and T6 back-compat aliases.

### Subsumed

- **#1173** (bridge-hooks.py:_safe_path_check sister) — closed by
  the canonical extraction.

## [0.14.5-beta15] — 2026-05-24

### Highlight — beta14 Track A Python-side sibling (#1170 — seventh A2A QA cycle)

Operator-cued **fifteenth prerelease** — closes the Python-side
sibling that beta14 Track A's bash-side `_isolation_aware_mkdir` fix
exposed. Seventh cycle of the A2A-driven QA loop. Remote QA peer's
beta14 verification confirmed `agent create` clean, but the very
next step (`agb setup teams`) aborted with a PermissionError
traceback from `bridge-setup.py:_safe_path_check`'s raw
`pathlib.Path.exists()` (controller process not in
`ab-agent-<a>` group → `path.stat()` raises). Function's docstring
promised sudo-escalate behavior; implementation didn't deliver.

Single-PR wave (PR #1172). Two-round codex chain. Integration r1
implement-ok (task #6062). `-beta15` prerelease; matching tag
`v0.14.5-beta15`, GitHub release marked **Pre-release**.

### Fixed — `_safe_path_check` proactive sudo-escalate (#1170)

- **#1170 (PR #1172)** — `bridge-setup.py:_safe_path_check` now does
  proactive sudo-escalate when `os_user` is provided:
  ```
  # flag = '-e' for check="exists", '-h' for check="is_symlink"
  subprocess.run(['sudo', '-n', '-u', os_user, 'test',
                  flag, str(path)],
                 capture_output=True, timeout=5, text=True)
  ```
  Disposition by sudo rc + stderr:
  - rc=0 → True
  - rc=1 + `sudo:` stderr (policy/auth failure) → fall through to
    direct pathlib (do NOT treat as path-absent)
  - rc=1 + clean stderr (authoritative `test` rc=1) → False
  - `TimeoutExpired` / `FileNotFoundError` (sudo missing/stuck) →
    fall through
  - Direct pathlib `PermissionError` → fail-closed False (was
    raise — bubbled traceback to operator)

  Two review rounds:
  - r1 BLOCKING: initial impl conflated `sudo` rc=1 (policy failure)
    with `test` rc=1 (path absent). `sudo -n -u root test -e /tmp`
    exits rc=1 with `sudo:` stderr when sudo not authorized; the
    PR would have treated this as "path absent" and dropped
    preserved `.env` / `access.json` config during `setup teams|
    telegram|discord` rebuild. Plus SHOULD-FIX: brief promised 5s
    timeout but `_sudo_run_as` didn't plumb `timeout=` to
    `subprocess.run`.
  - r2 implement-ok: switched to direct `subprocess.run` (bypasses
    `_sudo_run_as` for this call site so timeout actually applies),
    added stderr-prefix discrimination, smoke gained T8 (sudo
    policy failure → fall through) + T9 (clean rc=1 → authoritative
    False) + T10 (TimeoutExpired → fall through).

### Filed as backlog (carryover from beta15 review)

- **#1171** — `agent-bridge upgrade --channel stable` silently
  downgrades prerelease installs to the most recent GA. UX nit
  flagged during beta14 verification (cycle 10) when patch hit
  the footgun trying to upgrade to beta14. Recovery is one
  `--channel current` command. Backlog priority — recoverable.
- **#1173** — `bridge-hooks.py:_safe_path_check` (line ~1421-1450)
  has the same reactive-shape bug as #1170. Docstring claims
  "Mirror of bridge-setup.py" but implementation is the old raw
  pathlib check. Probably surfaces in a subsequent verification
  round when isolated agent's tools touch controller-only paths
  the hooks side mediates. Filed during PR #1172 r1 review as
  non-blocking follow-up. Best path: extract canonical
  `_safe_path_check` into shared module both files import.

## [0.14.5-beta14] — 2026-05-24

### Highlight — v2 isolation × channel plugin surface expansion (#1165 — sixth A2A QA cycle)

Operator-cued **fourteenth prerelease** — surface expansion from the
beta9-13 isolation cluster (closed at beta13) into the v2-isolation
× channel plugin (Teams) contract. Sixth cycle of the A2A-driven QA
loop. Remote QA peer's beta13 verification confirmed v0.14.5 isolation
core contract closed; the next real-world end-to-end exercise (create
fresh `linux-user` isolated Claude agent, attach Teams channel,
exchange bidirectional DM with operator) surfaced 8 distinct contract
gaps that each required manual `sudo chmod/chown` workarounds before
the agent could even boot.

These are **NOT v0.14.5 regressions** — they are pre-existing v2
contract gaps that the beta9-13 closure made reachable for the first
time on this install. Most predate v0.14.5.

3-track parallel wave (PR #1166 + #1167 + #1168). 10 codex review
rounds across the wave through integration (Track A r1→r2, Track B
r1→r2→r3→r4, Track C r1→r2, integration r1→r2) + the release-PR
review. `-beta14` prerelease; matching tag `v0.14.5-beta14`, GitHub
release marked **Pre-release**.

### Fixed — Track A: scaffold/mode widening (Gaps 1-4 of #1165)

- **PR #1166** — Gaps 1-4 covered:
  - **Gap 1** (`bridge-setup.py:_isolation_aware_mkdir`): added
    `mode=`/`agent=` kwargs; v2 group lookup via new pure-Python
    `_v2_agent_group_name(agent)` mirror of bash
    `bridge_isolation_v2_agent_group_name` (Linux 32-char
    hash-truncation + Darwin 255-char pass-through); priority order
    `group=` > `agent=` > `id -gn` legacy. Cross-language pair —
    bash + Python helpers must change in lockstep. r1 BLOCKING
    caught `id -gn` derivation was wrong (returns primary group, but
    v2 puts `ab-agent-<X>` only as supplementary).
  - **Gap 2** (`lib/bridge-agents.sh:3886`): `~/.claude` mode 2750
    → 2770. SessionStart hook needs group-write under
    `ab-agent-<a>` (per-agent v2 group) membership. Hook process
    effective UID investigation deferred to future round.
  - **Gap 3** (`lib/bridge-channels.sh:608`): `chmod -R go+rX
    node_modules` moved BEFORE the early-return on existing
    `node_modules/` so re-runs of `agb setup teams` widen
    pre-existing controller-umask-0700 trees. r1 BLOCKING caught
    chmod was skipped on the idempotent path.
  - **Gap 4** (`bridge-agent.sh:686`): legacy
    `$BRIDGE_AGENT_HOME_ROOT/$agent` added to v2 scaffold
    `chmod 0755` list so the markerless-existing-install upgrade
    path doesn't strand the per-agent template dir as 0700.

### Fixed — Track B: sudo-escalate channel readiness + idle-since marker (Gaps 5-6 of #1165)

- **PR #1168** — Gaps 5-6 covered with a security-careful 4-round
  codex chain:
  - **Gap 5** (`lib/bridge-agents.sh:5425`): new
    `bridge_channel_access_file_present` helper sudo-escalates the
    controller `-f` test on isolated `.teams/access.json` (and
    Discord/Telegram/Mattermost equivalents). Same family as PR
    #1149's controller-direct-touch fix.
  - **Gap 6** (`lib/bridge-isolation-v2.sh:bridge_isolation_v2_write_agent_state_marker`):
    new three-path writer for the Stop-hook `idle-since` marker:
    - **Path A0** (NEW) — when effective UID matches the agent's
      `bridge_agent_os_user`, do an atomic direct write (mktemp +
      chmod 0660 + mv -f) with hard-fail on chmod failure (parity
      with the sudo helper exit-8 and Path B return-1 contracts).
      This is the load-bearing path for the Stop-hook scenario
      (hook runs as iso UID = target UID, no sudo needed).
    - **Path A** — when euid mismatches but sudo helper is available
      (controller writing as iso UID), use
      `bridge_isolation_write_file_as_agent_user_via_bash` (existing
      helper from #832).
    - **Path B** — legacy `ensure_matrix_path` fallback for
      non-isolated installs.

    Round-by-round: r1 BLOCKING (widen state-agent-dir to
    `ab-shared` was a cross-agent integrity vector — any iso agent
    could write `manual-stop` / `broken-launch` into another agent's
    state dir, disabling autostart) → r2 BLOCKING (narrow sudo-as-iso
    helper requires `operator ALL=(os_user)` sudoers and isolated
    Stop hook running as agent-X can't `sudo -u agent-X` because the
    per-agent sudoers entry doesn't grant agent-to-self) → r3
    BLOCKING (silent chmod failure inconsistent with helper/Path B
    hard-fails) → r4 implement-ok. The 4-round chain hardened both
    the security model and the correctness contract.

### Fixed — Track C: PostToolUse hook + agb dispatcher controller-UID recovery (Gaps 7-8 of #1165)

- **PR #1167** — Gaps 7-8 covered:
  - **Gap 7** (`hooks/bridge_hook_common.py:write_audit`): new
    `_under_isolated_uid()` helper gates the PermissionError/OSError
    swallow on a 3-condition AND: `current_isolated_agent()` is set
    (env signal) AND `BRIDGE_CONTROLLER_UID` is non-empty and
    parseable AND `os.geteuid() != int(BRIDGE_CONTROLLER_UID)`.
    Missing/unparsable CONTROLLER_UID fails closed (re-raise) so
    controller-side processes inheriting linux-user env do NOT
    silently swallow permission failures. r1 BLOCKING caught the
    initial swallow was env-only (controller UID with iso env also
    swallowed).
  - **Gap 8** (`agent-bridge`): dispatcher recovers
    `BRIDGE_CONTROLLER_UID` from `state/layout-marker.sh` owner via
    `stat -c '%u'` (GNU) / `stat -f '%u'` (BSD) when env is unset.
    Allows direct
    `agb <subcmd>` invocation from inside an isolated Claude session
    without re-running through the start-sudo wrapper. Recovery
    placed between BRIDGE_HOME resolution and `source bridge-lib.sh`
    so the marker validator sees the recovered UID. Markerless
    installs gracefully no-op.

### Known carryover — Gap 9 (Teams MCP spawn-at-session-start)

The operator's completion criterion for v0.14.x line closure is
bidirectional Teams DM echo on a fresh isolated agent. Gaps 1-8
unblock the agent boot path + channel readiness check + scaffold
modes + hook flood + dispatcher recovery, but there's a suspected
9th gap (Teams MCP plugin auto-spawn at session start vs. spawn-on-
first-tool-call) that the remote QA peer hasn't isolated to a
specific code site yet. May surface in beta14's verification round
as a separate follow-up issue.

### Wave shape

3-track parallel dispatch (`wave-orchestration` skill). Each track's
fixer ran in isolated worktree; codex pair-review at each round.
10 codex review rounds through integration (Track A 2, Track B 4,
Track C 2, integration 2) plus the release-PR review for this cap.
Track B's 4-round chain reflects the security depth of the
marker-writer surface: each round uncovered a deeper architectural
assumption that needed fixing.

## [0.14.5-beta13] — 2026-05-24

### Highlight — beta12 install-path follow-up (#1161 — fifth A2A QA cycle)

Operator-cued **thirteenth prerelease** — closes the marker file mode
+ parent-dir traversal gap that beta12's validator/exemption fix
exposed at the install-path layer. Fifth cycle of the A2A-driven QA
loop. Remote QA peer reported beta12 structurally correct but
isolated UIDs still could not read the marker because:

1. Marker file was `0640` (group-only), and the marker's
   `ab-shared` group did not actually contain the isolated UIDs on
   the live install (Patch B latent bug, deferred).
2. Marker parent directory was `0750` and `state/` was `0710`, so
   even with file `0644` an isolated UID couldn't traverse the
   parent chain to reach it.

Single-PR wave (PR #1162). Two-round codex chain. Integration r1
implement-ok (task #5993). `-beta13` prerelease; matching tag
`v0.14.5-beta13`, GitHub release marked **Pre-release**.

### Fixed — isolation-v2 marker readable by isolated UIDs (#1161)

- **#1161 (PR #1162)** — Two-layer fix for marker accessibility from
  isolated context, choosing the simplest end-to-end path over
  invasive group-membership investigation:
  - **Marker file mode 0640 → 0644** at all three writer sites
    (`lib/bridge-isolation-v2-migrate.sh:bridge_isolation_v2_migrate_marker_write` +
    `bridge_isolation_v2_migrate_marker_write_minimal`, plus the
    fresh-init writer
    `lib/bridge-layout-resolver.sh:bridge_layout_write_v2_marker`).
    Marker content is non-secret (`BRIDGE_LAYOUT=v2` +
    `BRIDGE_DATA_ROOT=<abs-path>`). Validator's mode gate at
    `lib/bridge-marker-bootstrap.sh` (mode_int & 0o22) rejects
    group/world WRITE only; world-readable stays valid.
  - **Marker parent dir + `state/` + `state/agents/` mode 0750/0710
    → 0711** at the same three writer sites + `normalize_layout` in
    `lib/bridge-isolation-v2-migrate.sh:925-942` + the matrix spec
    rows `state-root` / `state-agents-root` in
    `lib/bridge-isolation-v2.sh:1567-1586` (spec-then-apply pair
    kept in lockstep). Mode 0711 grants owner full, group execute
    (parity with prior 0710), others execute (the new traversal
    bit). Directory contents stay non-listable for non-owner; only
    specific files reachable by full path. Direct state children
    remain protected by their own modes (`0600` files, `0700`
    nested dirs, `2770` per-agent leaves).

  Two review rounds: r1 BLOCKING (file mode alone insufficient
  because parent dir still 0750 — POSIX traversal fails before file
  mode matters; codex caught) → r2 added parent-dir + state
  normalize + matrix spec pair → implement-ok. New smoke
  `1161-marker-readable-by-isolated.sh` with 8 cases including
  cross-UID `sudo -n -u nobody cat <marker>` (T8 Linux-only;
  patch's host exercises the real end-to-end gate).

### Deferred — `ab-shared` group membership latent bug

`bridge_isolation_v2_ensure_user_in_group "$os_user" "$_v2_shared_grp"`
(`lib/bridge-agents.sh:3807-3811`) is supposed to add isolated UIDs
to the `ab-shared` group during `agent create`. On the remote QA
host, `getent group ab-shared` showed only the controller user. The
helper returns failure on sudo failure
(`lib/bridge-isolation-v2.sh:649-651`), so this is an unproven
runtime/group-refresh hypothesis — the call may not be executed in
the linux-user prepare path for that install, or the group-set
refresh after `usermod -aG` may not propagate to already-running
controller processes (see KNOWN_ISSUES §28). With #1161's chmod 0644
+ 0711 parent-traversal fix, the marker is now world-readable so
this no longer blocks end-to-end agent start. The membership bug is a
latent issue that will be addressed in a follow-up release once the
A2A QA loop stabilizes.

## [0.14.5-beta12] — 2026-05-24

### Highlight — beta11 follow-up exposed long-standing marker validator gap (#1158)

Operator-cued **twelfth prerelease** — closes a long-standing
isolation-v2 marker validation gap that beta11's controller-helper
fixes finally exposed. Fourth cycle of the A2A-driven QA loop. Remote
QA peer reported beta11 closed #1155 at create-time but `agent start`
hit a different wall earlier obscured by the now-fixed Permission
denied flood.

Single-PR wave (PR #1159). Three-round codex chain. Integration r1
implement-ok (task #5975). `-beta12` prerelease; matching tag
`v0.14.5-beta12`, GitHub release marked **Pre-release**.

### Fixed — isolation-v2 marker validator accepts controller-UID owner (#1158)

- **#1158 (PR #1159)** — `lib/bridge-marker-bootstrap.sh:bridge_isolation_v2_marker_validate`
  previously accepted only **root** or **current-process** owner for
  the layout marker. Controller-owned markers (owner UID = the
  controller's numeric UID) were rejected when consumed from an
  isolated context (`sudo -u agent-bridge-<a>`), so
  `bridge-die: Agent Bridge v0.8.0 requires
  isolation-v2 (POSIX group + setgid)` aborted every isolated agent
  start. This was a **long-standing** ordering gap, not a beta11
  regression — beta9/10's controller-side Permission denied flood
  crashed agents before they ever reached the marker check.

  Three-layer fix:
  - **Marker validator identity exemption** — accepts
    `BRIDGE_CONTROLLER_UID` (already exported by
    `lib/bridge-agents.sh:3461-3462`) in addition to root and current
    process. The group/world-write mode reject (the load-bearing
    security gate) stays intact.
  - **`bridge-start.sh` inline env prefix** — propagates
    `BRIDGE_CONTROLLER_UID=$(id -u)` into the sudo-wrapped child's
    environment BEFORE `bridge-lib.sh` sources the marker bootstrap.
    Load-bearing for production: codex r1 caught that without this
    propagation, the marker validator fix is a no-op because
    `bridge-lib.sh` sources `bridge-marker-bootstrap.sh` before
    `bridge-state.sh` (where the env file would otherwise be loaded).
  - **`bridge_agent_preserved_env_vars` defensive add** —
    `BRIDGE_CONTROLLER_UID` added to the sudo `--preserve-env=` list.
    No-op currently (controller doesn't export the variable at fork
    time outside `bridge-cron.sh`), but defensive for any future
    controller-export path.

  Three review rounds: r1 BLOCKING (identity exemption correct but
  load-order makes it no-op) → r2 BOTH-strategy fix + load-order
  smoke → r3 BLOCKING (load-order smoke missing from ci-select-smoke.sh)
  → implement-ok. New smokes `1158-marker-controller-uid-exemption.sh`
  (7 cases) + `1158-marker-load-order.sh` (4 cases), both registered
  in `__ALL__` static + bridge-start + marker-bootstrap selectors.

## [0.14.5-beta11] — 2026-05-24

### Highlight — beta10 fix-completion wave (#1155 — third A2A QA cycle)

Operator-cued **eleventh prerelease** — closes the 7th controller-touch
site that beta10 missed. Third cycle of the A2A-driven
upstream→fixer→downstream release loop introduced in beta9; the remote
QA peer's beta10 verification reported 2/4 gates PASS, with a single
missed helper (`bridge_bootstrap_project_skill`) responsible for the
remaining failures and for the stdout flood during `agent start`.

Single-PR wave. PR codex pair-reviewed (r1 BLOCKING — engine-agnostic
skip dropped Codex `.agents/skills` + smoke Claude-only → r2
implement-ok). Integration r1 implement-ok (task #5956). `-beta11`
prerelease; matching tag `v0.14.5-beta11`, GitHub release marked
**Pre-release**.

### Fixed — v2 isolation: `bridge_bootstrap_project_skill` engine-aware guard (#1155)

- **#1155 (PR #1156)** — `bridge_bootstrap_project_skill`
  (`lib/bridge-skills.sh`) — beta10's 6-site Step-A guard application
  missed this helper. The function calls `bridge_write_managed_markdown`,
  which does shell-level `mkdir -p` + `mv` on
  `$workdir/.claude/skills/agent-bridge/{SKILL.md,references/...}`
  for Claude or `$workdir/.agents/skills/agent-bridge/...` for Codex.
  Two of the five call sites (`bridge-start.sh:481`, `:534`) were
  unredirected, so failures flooded operator stdout during
  `agent start` even though `agent create` looked clean.

  Engine-aware fix:
  - **Claude + v2 isolation** → DEFER (the isolated-home replacement
    path `bridge_sync_isolated_home_claude_skills` already installs
    skills at `$isolated_home/.claude/skills/`, where v2 Claude reads
    via `CLAUDE_CONFIG_DIR`)
  - **Codex + v2 isolation + Step A pending** → DEFER (workdir not
    yet owned by isolated UID; agent start re-triggers the helper
    after ownership normalization)
  - **Codex + v2 isolation + Step A complete** → SUDO-ESCALATE
    (Codex has no `CODEX_CONFIG_DIR` / isolated-home read path; it
    reads `.agents/skills/agent-bridge/` from the workdir directly,
    so the install path is sudo-rendered via `bridge_linux_sudo_root`:
    mktemp render → `mkdir -p` → `install -m 0644` → `chown` isolated
    UID → atomic `mv -f`, same race-correct pattern as PR #1153 r3
    `bridge_ensure_project_claude_guidance`)
  - **Legacy non-isolated** → unchanged

  Side-fix: `bridge-setup.sh` doctor diagnostic path corrected from
  `.codex/skills` (nonexistent) to `.agents/skills` (production
  contract per `bridge_project_skill_dir_for`).

  Two review rounds: r1 BLOCKING ×2 (engine-agnostic skip dropped
  Codex; smoke Claude-only with wrong production path stub) → r2
  implement-ok. New smoke `1155-bootstrap-skill-guard.sh` with 6
  cases covering both engines, Step-A-pending defer, and the
  sudo-escalate ownership/mode/argv contract.

## [0.14.5-beta10] — 2026-05-24

### Highlight — beta9 fix-completion wave (#1151 — second A2A QA cycle)

Operator-cued **tenth prerelease** — closes the v2-isolation gaps that
the remote QA peer flagged in her beta9 4-gate verification (1/4 PASS
on beta9; #1144 was clean but #1145 only partial). Second cycle of the
A2A-driven upstream→fixer→downstream release loop introduced in
beta9.

Every PR was codex pair-reviewed; the integration branch passed r1
codex review (task #5938 implement-ok). `-beta10` prerelease;
matching tag `v0.14.5-beta10`, GitHub release marked **Pre-release**.

### Fixed — v2 isolation: controller-side helper guard generalized (#1151)

- **#1151 (PR #1153)** — beta9's PR #1149 added an ownership-based
  defer at exactly **one** controller-touch site
  (`bridge_link_claude_settings_to_shared`). beta9 verification on a
  remote Linux v2 host proved the same race / post-Step-A wall
  recurred at five sibling helpers. This PR lifts the predicate into a
  shared helper `bridge_agent_workdir_step_a_complete(agent, workdir)`
  in `lib/bridge-agents.sh` and applies it at six total sites with
  per-site policy:
  - **DEFER** (return 0 when isolation effective + Step A pending,
    agent start re-triggers): `bridge_link_claude_settings_to_shared`,
    `bridge_link_shared_claude_skill`,
    `bridge_ensure_auto_memory_isolation`,
    `bridge_ensure_memory_precompact_hook` — workdir-side writes that
    are either re-driven on next launch (auto-memory, link-settings)
    or shadowed by the isolated-home rendering path
    (precompact-hook → isolated-home settings render).
  - **SUDO-ESCALATE** (proceed via isolated-UID sudo for v2 isolated
    agents post-Step-A, fall back to controller-direct for legacy):
    `bridge_sync_claude_runtime_skills` (extended
    `bridge_sync_isolated_home_claude_skills` to consume
    `bridge_agent_skills_csv "$agent"` — configured non-shared runtime
    skills are now synced into `$isolated_home/.claude/skills/` where
    v2 Claude reads them via `CLAUDE_CONFIG_DIR`),
    `bridge_ensure_project_claude_guidance` (post-Step-A v2 path now
    sudo-reads via O_NOFOLLOW Python helper then sudo-installs + chown
    + atomic mv).

  Three review rounds: r1 (DEFER at all 5 sites — wrong: dropped
  configured runtime skills + project CLAUDE.md) → r2 (SUDO-ESCALATE
  at the two load-bearing sites — but with `sudo cat` that followed
  symlinks, a controller-side privilege escalation vector) → r3
  (symlink-safe O_NOFOLLOW Python helper + rc-capture fix for the
  exit-code-2 no-op sentinel) implement-ok. New smokes
  `1151-step-a-helper.sh` (6 cases, predicate truth table) +
  `1151-r2-sudo-escalate.sh` (6 cases including T9 symlink-refusal
  regression contract + T10 sentinel-detection regression contract).

### Documented — supplementary group refresh after first v2 isolated agent (#1151)

- **#1151 (PR #1152)** — Linux supplementary group set is a process
  credential established at login / `setgroups` / `newgrp` and
  inherited across `fork`+`exec`; a later `usermod -aG` does NOT
  propagate to already-running processes, and `exec $SHELL` from
  inside the stale shell preserves the credential. After the first v2
  isolated agent create, the controller user IS a member of the new
  `ab-agent-<a>` group on disk but the daemon + operator shell still
  hold the pre-add set. New OPERATIONS.md subsection §"Supplementary
  group refresh after first v2 isolated agent" + KNOWN_ISSUES.md §28
  document the resolution paths (full relogin / ssh reconnect /
  `newgrp ab-agent-<a>` for a single-group refresh, followed by
  `agent-bridge daemon restart` so the daemon inherits the new set).
  Two review rounds: r1 BLOCKING (`exec $SHELL -l` recipe was wrong)
  → r2 implement-ok.

### Internal — Python helper extraction (footgun #11 baseline)

The symlink-safe-read + render-body extractions in PR #1153 net-
decrement the lint baseline by one C1 (deadlock-class capture) site:
`scripts/lint-heredoc-ban.sh --baseline-check` reports
`C1=104 C2=54 C3=315 C4=0 H3=364 SAFE=642`. New helpers:
`lib/skills-helpers/claude-md-safe-read.py` (O_NOFOLLOW probe + 4 exit
codes) and `lib/skills-helpers/claude-md-render.py` (render body
file-as-argv).

## [0.14.5-beta9] — 2026-05-24

### Highlight — beta8 fix completion wave (A2A-driven QA loop)

Operator-cued **ninth prerelease** — closes the two remaining
post-beta8 issues that an operator-provided remote Linux QA peer
reported via the **A2A cross-bridge handoff** (v0.14.5-beta4+
feature). First production use of A2A for the upstream feedback
loop: remote QA admin → A2A → upstream maintainer inbox →
wave-orchestration → release → A2A reply. Both issues were
upstreamed with complete reproductions and code diagnostics
embedded in the issue body.

Every PR was codex pair-reviewed; the integration branch passed
two-round codex review (task #5906 r1 BLOCKING — missing __ALL__
smoke registration; task #5908 r2 implement-ok). `-beta9`
prerelease; matching tag `v0.14.5-beta9`, GitHub release marked
**Pre-release**.

### Fixed — v2 isolation create-time race (beta8 root cause)

- **#1145 (PR #1149)** — `lib/bridge-hooks.sh:bridge_link_claude_settings_to_shared`
  (the shell-side wrapper that invokes `bridge_hooks_python link-shared-settings`)
  now **defers under v2 isolation when the workdir owner ≠ the
  roster-resolved os_user** (Step A — `bridge_linux_prepare_agent_isolation`
  — pending). Root cause: the v2 fresh-create flow scaffolded the
  workdir as the controller user before Step A normalized
  ownership to the isolated os_user; the controller-side
  `cmd_link_shared_settings` (`bridge-hooks.py`) raced ahead, walked into the wrong
  ownership, and `path.mkdir()` fell through to controller-direct
  create → cascade of PermissionError tracebacks on every subsequent
  round. The deferral guard uses exact roster owner match (NOT a
  prefix glob) so custom `--os-user svc-foo` agents proceed correctly
  and sibling `agent-bridge-other` workdirs do NOT false-positive
  Step-A-complete. Agent start re-triggers the hook once Step A runs.
  Three review rounds: r1 (existence-based guard missed scaffold
  ordering) → r2 (prefix-glob too loose, custom os_user broken) → r3
  (exact roster match) implement-ok. Smoke `1145-option1-deferral-guard.sh`
  carries 8 cases including T2c/T2d regression contract (must fail
  against r2 prefix-glob by design).
- **#1145 (PR #1146)** — companion containment: `cmd_link_shared_settings`
  (`bridge-hooks.py:1479`) now **catches OSError** and emits a structured `HOOK_STATUS=permission_denied`
  warning instead of a Python traceback when the link operation cannot
  proceed. Belt-and-suspenders for any unforeseen state where the
  upstream deferral guard misses; routine pre-Step-A flows do not
  trigger this path because the guard fires first. Plus
  `_isolated_workdir_owner` uid-first lookup +
  `_ensure_dir_with_sudo` sudo-to-self short-circuit.

### Fixed — upgrade-complete task body (beta8 regression)

- **#1144 (PR #1147)** — `bridge-upgrade.sh` now **captures
  `INSTALLED_VERSION` on the apply path** (and BEFORE any
  `git checkout TARGET_REF` / pull step). Beta8 only assigned
  `INSTALLED_VERSION` inside the `--check` subcommand branch, so the
  normal `apply` path left it unset and the post-upgrade
  `[upgrade-complete]` task body rendered `from_version: unknown`
  via the `${INSTALLED_VERSION:-unknown}` fallback. r1 added the
  apply-path capture but placed it AFTER the `SOURCE_ROOT` checkout —
  which is fine for `--source <other-checkout>` upgrades but corrupts
  the read for git-clone installs where `SOURCE_ROOT == TARGET_ROOT`
  (the checkout itself mutates the live VERSION file before the
  capture reads it). r2 moved the capture above the checkout +
  pull blocks and added a `# END:` sentinel comment so the smoke's
  marker-based extraction has a stable boundary. Two review rounds:
  r1 (capture-after-checkout ordering) → r2 (moved before checkout)
  implement-ok. Plus: the
  persistent post-task body file is no longer `rm -f`'d after a
  successful task create — `bridge-queue.py` stores the body_path
  verbatim for bridge-managed paths, and the admin runbook + `agb
  show <id>` consumers open the file directly. Smoke
  `1144-upgrade-complete-task.sh` extended with T5 covering the
  SOURCE_ROOT == TARGET_ROOT ordering hazard.

### A2A cross-bridge loop (operator directive 2026-05-24)

First operational use of A2A for the upstream → fixer → downstream
release loop. Each beta release now triggers an A2A message to the
operator-provided remote QA peer requesting update + QA + new-issue
upstream-via-inbox-task; the loop continues until the QA peer
confirms no new findings. Setup itself surfaced a UX backlog issue
(#1148) — bidirectional handshake needed 5+ round-trips on the first
pair (`inbound_allowlist` semantics + peer id confusion + 403 source
address mismatch debugging).

## [0.14.5-beta8] — 2026-05-24

### Highlight — beta7 fix completion wave

Operator-cued **eighth prerelease** — closes 2 incomplete beta7 fixes that
the operator reproduced on a live Linux server during beta7 QA. Both
issues were follow-ups to merged beta7 PRs whose live-host behavior
diverged from the test-fixture coverage.

Every PR was codex pair-reviewed; the integration branch passed a final
codex review (task #5870 implement-ok). Operator runs Linux-VM QA
personally on a fresh install.
`-beta8` prerelease; matching tag `v0.14.5-beta8`, GitHub release marked
**Pre-release**.

### Fixed — v2 isolation deployment (beta7 follow-up)

- **#1139 (PR #1142)** — `bridge-hooks.py:_isolated_workdir_owner` now
  resolves the owning **uid first** and returns when it matches
  `agent-bridge-*`, before falling through to the gid-based getpwall()
  enumeration. The beta7 fix (#1133) gated the uid-lookup on
  `st_uid != getuid()` AND relied on gid for ancestor walks — but the
  failing host's `.claude/` dir is `agent-bridge-<a>:awfmanager 0700`
  (controller gid, isolated uid), so the gid enumeration returned None
  and `_ensure_dir_with_sudo` fell back to controller `mkdir` →
  PermissionError. Plus: new `bridge_agent_onboarding_markers_complete`
  helper — `bridge_agent_onboarding_state` now downgrades parsed
  `complete` to `partial` when canonical markers are missing (closes
  the false-positive on half-scaffolded workdirs).
- **#1140 (PR #1141)** — `agent delete --purge-home --purge-crons` now
  reaps **OS home dir** (`/home/agent-bridge-<a>/`) AND **v2 workdir
  tree** (`$BRIDGE_HOME/data/agents/<a>/`) in addition to the
  user/group/sudoers cleanup PR #1129 already shipped. New internal
  helpers `_bridge_isolation_v2_reap_os_home_dir` +
  `_bridge_isolation_v2_reap_v2_workdir` parallel to the sudoers reap;
  production hardcodes the strict path patterns, smoke uses tmpdir
  arg (no env-controlled bypass per #1121 r3 contract). Respects
  `BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT` for non-default installs.

## [0.14.5-beta7] — 2026-05-24

### Highlight — post-beta6 stabilization + v2 isolation deployment unblock wave

Operator-cued **seventh prerelease** in the v0.14.5 stabilization window. A
14-PR wave on `release/v0.14.5-beta7-integration` lands the v2-isolation
deployment fixes uncovered while bringing up beta6 on a fresh Linux server
(5 newly-reported issues #1118-#1122) plus 7 post-beta6 follow-up fixes
including the carried-over migrator apply scope (#1087, deferred from
beta6 to beta7), CLI `--help` universal contract (#1114 + 16 audit sites),
and the `--always-on no` symmetric inverse feature (#1136).

Every PR was codex pair-reviewed; the full integration branch passed a
final codex r2 review (footgun #11 regression caught + resolved in PR
#1135). Operator runs Linux-VM QA personally.
`-beta7` prerelease; matching tag `v0.14.5-beta7`, GitHub release marked
**Pre-release**.

### Fixed — watchdog (v2 isolation interop)

- **#1113 (PR #1123)** — `bridge-upgrade.sh` now back-fills the canonical
  identity markers (`CLAUDE.md`, `SOUL.md`, `SESSION-TYPE.md`,
  `MEMORY-SCHEMA.md`, `MEMORY.md`) from `agents/<a>/` into
  `data/agents/<a>/workdir/` for v2-migrated agents whose runtime workdir
  was empty post-beta6 (`status: error` on every legacy agent). Idempotent
  + roster-active only.
- **#1119 (PR #1124)** — `bridge-watchdog.py` no longer crashes on a
  single v2-isolated agent's `PermissionError`. Per-agent `try/except`
  isolates failures; new `status="scan_error"` + `error_kind` +
  `error_path` row keeps the other agents scanning.
- **#1108 follow-through** — back-fill (#1113) + permission-error
  containment (#1119) together close the watchdog cascade on legacy v2
  installs.

### Fixed — v2 isolation deployment

- **#1118 (PR #1126)** — engine binary resolution for `linux-user`
  isolated agents: controller's `~/.local/bin/claude` was not on the
  service user's PATH, so first-start died with `start-command-failed`.
  Engine binary now resolved to absolute path on the controller and
  threaded through the sudo wrapper via `BRIDGE_ENGINE_BIN`. Env-prefix
  preservation in `launch-cmd-engine-bin-rewrite.py` keeps
  `PATH=$VAR:$PATH claude ...` style delayed expansion intact.
- **#1120 (PR #1133)** — controller-side ops on v2-isolated workdirs no
  longer leak `PermissionError` (in `bridge-hooks.py:_ensure_dir_with_sudo`
  + `agent show` false-missing). `_isolated_workdir_owner` enumerates
  `/etc/passwd` by primary gid (truncation-safe for long agent names);
  `bridge_agent_onboarding_state` adds `unverifiable` state for
  controller-blind paths with sudo probe fallback.
- **#1121 (PR #1129)** — `agent delete --purge-home` now reaps the
  per-agent sudoers drop-in at `/etc/sudoers.d/agent-bridge-<a>` alongside
  user/group/home. Production path is hardcoded
  `/etc/sudoers.d`; smoke uses the internal helper directly with a
  tmpdir (no env-controlled bypass).
- **#1122 (PR #1131)** — admin Claude Code sessions auto-promote
  `caller-source` to `operator-trusted-id` when
  `BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID` (both non-empty). Removes
  the per-command `BRIDGE_CALLER_SOURCE=` override friction. Audit row
  records the auto-promotion.

### Fixed — agent CLI + audit

- **#1105 (PR #1127)** — `agent add` now emits the
  `system_config_mutation` audit row that `agent update` already emitted
  (closes audit-trail asymmetry from PR #1102). Emission position: after
  `bridge_write_role_block` succeeds, before `_CREATE_ROLLBACK_COMPLETE=1`
  (rollback path never emits).
- **#1106 (PR #1128)** — daemon nudge fanout now re-queries task
  eligibility in the shell dispatcher immediately before dispatch via new
  `bridge-daemon-helpers.py nudge-eligibility-recheck`. Closes the
  micro-race window between Python eligibility decision and shell
  delivery (PR #1103 follow-up).

### Fixed — CLI `--help` contract

- **#1114 (PR #1132)** — `--help` / `-h` now accepted across **16
  subcommand groups + sub-subcommand handlers** that previously
  rejected it (operator had to read the error message to discover
  available verbs). Critical safety fix: `daemon ensure --help` no
  longer silently starts the daemon. Includes 2 r1 follow-up fixes
  (bridge-send `help` payload swallow + free-form-positional dispatcher
  tightening).
- **#1115 + #1116 (PR #1125)** — usage template + `_top_valid`
  typo-suggestion list now include `a2a`, `plugins`, `skills`,
  `isolation`, `wave` (previously dispatched but not documented).
  `agent` / `cron` usage lines synced with dispatcher.

### Added — features

- **#1087 (PR #1130)** — MIGRATOR `apply` contract gaps closed
  (deferred from beta6 #1086). Inclusive clean-target gate covers every
  apply write path with real content backup. Layout-resolver shim
  (`scripts/python-helpers/migrate-layout-shim.sh`) eliminates path
  drift; verify + apply both consume it. Atomic apply via stage-publish
  + rollback restores file bytes on mid-flight failure. Secrets written
  at mode 0600. Cron env scrub uses allowlist. Shim fails-closed on
  non-v2 marker. `BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE` env-gate removed —
  `apply` is the user-facing default.
- **#1117 (PR #1134)** — universal `--help`/`-h` CI smoke gate
  (`scripts/smoke/1117-cli-help-universal-gate.sh`) — 139 assertions
  across 52 `_top_valid` candidates + dispatched verbs. 14 KNOWN_BROKEN
  entries pinned for follow-up. Ratchet semantics: if a pinned verb
  starts passing, smoke fails to prompt operator to prune.
- **#1136 (PR #1137)** — `agent update`/`add --always-on no` (must
  pair with `--idle-timeout <N>`) — symmetric inverse to `--always-on
  yes` (#1093). Pure declarative: persistence identical to bare
  `--idle-timeout`, side effect is new `expressed_intent` audit field
  (`always_on_yes` / `always_on_no`) so operators can grep for
  policy-flip events even when numeric values are identical
  (re-affirmation case).

### Internal — footgun #11 scanner extension

- **PR #1135 (codex r2 integration review)** — scanner extended to
  catch bare `bash <<TAG` AND `bash << TAG` (whitespace form), with
  capture-aware classification (C1 capture-wrapped, C4 non-capture).
  Fixed the pre-existing site at
  `scripts/smoke/isolated-agent-delete-reap.sh:63`. Self-test fixture
  grew from 18 → 23 positives. `RE_BASH_BARE_HEREDOC` scoped to require
  the `bash` keyword so string content (e.g. assertion labels
  `elapsed << interval`) doesn't false-positive.

## [0.14.5-beta6] — 2026-05-23

### Highlight — clean-cut foundation wave

Operator-cued **sixth prerelease** in the v0.14.5 stabilization window. A
24-PR wave on `release/v0.14.5-beta6-integration` lays the foundation for
the upcoming v1.0 clean-cut refactor: the typed three-layer agent layout
(identity / workspace / engine materialization), descriptor-driven engine
provisioning, hooks-SSOT consolidation, and a standalone legacy → clean
install migrator (export/plan/verify; `apply` deferred to beta7 #1087).
The wave also folds in **17 newly-reported upstream issues** (#1062, #1063,
#1065, #1073-#1078, #1082, #1083, #1093, #1096, #1099-#1101, #1108).

Every PR was codex pair-reviewed (`agb-dev-claude` + `agb-dev-codex`); the
integration branch additionally passed a full-branch codex review (r1
returned 2 BLOCKING + 1 SHOULD-FIX → addressed in PR #1111 → r2
`implement-ok`). Operator runs Linux-VM QA personally on a fresh install.
`-beta6` prerelease; matching tag `v0.14.5-beta6`, GitHub release marked
**Pre-release**.

### Added — typed layout + engine descriptor

- **#1060 (PR #1081)** — typed agent-layout resolver
  (`lib/bridge-agent-layout.sh`) + minimal engine descriptor
  (`lib/bridge-engine-descriptor.sh`). Establishes the three-layer
  v2 model: identity source → workspace materialization target →
  engine-specific entrypoint. Lays the foundation for cleanly
  decoupling identity authoring from engine packaging. D1-D5 smokes +
  three release-gate smokes lock the resolver contract.

### Added — managed tmux bootstrap

- **#1058 (PR #1080)** — managed tmux UX defaults block for Claude/Codex
  TUI sessions. The bootstrap installs documented defaults (window/pane
  titles, status line, key bindings) so first-time users get a sensible
  TUI without hunting through dotfiles.

### Added — descriptor-driven Codex static provisioning

- **#1067 (PR #1088)** — Codex static agents now provision through the
  engine descriptor: AGENTS.md entrypoint, per-agent `.codex/hooks.json`,
  and an upgrade-time propagation helper. Replaces ad-hoc Codex profile
  scaffolding with the same descriptor pipeline Claude uses.

### Added — hooks SSOT

- **#1068 (PR #1092)** — `bridge-hooks.py` is now the canonical hooks
  source-of-truth. The session-template's `hooks.json` reduces to `{}`
  (minimal marker), the per-agent install wires through the SSOT
  renderer, wrapper directories consolidate to a single layout, and
  predicates carry legacy-wrapper migration courtesy for in-place
  upgrades.

### Added — agent CLI flags

- **#1093 (PR #1102)** — `agent add` and `agent update` accept
  `--idle-timeout`, `--loop yes|no`, and `--always-on` for setting daemon
  behavior at create or modify time instead of requiring a separate edit.
  Create-path audit gap deferred to #1105.

### Added — Teams MCP proactive send

- **#1083 (PR #1085)** — Teams MCP gains a `send_message` tool so an
  agent can proactively initiate a 1:1 Teams thread (vs only replying).
  Fail-closed gate keeps it disabled when the Teams channel is not
  configured.

### Added — standalone legacy-install migrator

- **#1086** — `scripts/migrate-legacy-install.sh` ships
  `export` / `plan` / `verify` for migrating a legacy-shaped install to
  a clean target. `apply` is deferred to beta7 (#1087) with codex r1
  contract gaps documented inline. `verify` is intentionally a
  target-FS inspection helper for beta6; layout-resolver integration
  bundles with `apply`.

### Fixed — channel runtime config under BRIDGE_HOME

- **#1062 (PR #1071)** — channel runtime-config files were resolved
  against `$HOME` instead of `$BRIDGE_HOME`, so isolated installs read
  the controller's config. Resolution now anchors on `$BRIDGE_HOME`.

### Fixed — Teams setup secret leak

- **#1063 (PR #1072)** — `bridge-setup.sh` Teams client-secret prompt
  exported the secret as a CLI argument, exposing it in `ps`/`/proc`.
  The secret is now passed via stdin only.

### Fixed — docs reconcile

- **#1065 (PR #1069)** — `README`, `CLAUDE.md`, `AGENTS.md`, and
  `docs/audit-2026-05-15.md` references to old versions, removed plans,
  or relocated audit files reconciled to current state.

### Fixed — cron isolated-UID grant

- **#1079** — cron run dirs (`state/cron`, `state/cron/runs`) did not
  carry the group-write + default-ACL grant that isolated-UID agents
  need. The grant now applies gated on `linux-user` isolation, and the
  per-agent leaf is `chgrp`'d to `ab-agent-<agent>` so the isolated UID
  can write its own job artifacts. 4-round codex convergence to land
  the gate + matrix rows + leaf chgrp.

### Fixed — claude-token sync for isolation modes

- **#1082 (PR #1084)** — `claude-token` sync was a no-op for shared
  agents and used the wrong group for isolated agents, breaking auth
  refresh. Shared mode is now correctly a no-op; isolated mode writes
  to `ab-shared` so the isolated UID can read the refreshed token.

### Fixed — Teams bun runtime + plugin node_modules

- **#1074 (PR #1090)** — Teams channel setup did not provision the bun
  runtime + plugin `node_modules`, so the Teams MCP failed on first use
  with `bun: command not found` or missing dependency errors.
  Provisioning now lands at channel-setup time.

### Fixed — per-agent CLAUDE_CONFIG_DIR cred seed

- **#1075 (PR #1094)** — `CLAUDE_CONFIG_DIR` was not seeded with the
  controller's credentials, so per-agent Claude sessions hit a fresh
  login flow on every cold start. Cred file is now seeded with a
  parent-symlink reject guard.

### Fixed — agent create atomicity + purge-home

- **#1076 (PR #1095)** — partial-failure `agent create` left an
  orphaned half-scaffolded home. Create now stages into a temp dir and
  atomically renames on success (rollback trap removes the temp dir on
  failure). `agent delete --purge-home` now also removes the workdir
  sibling and the isolation-v2 data root entries.

### Fixed — migrate-isolation-v2 wrong dir

- **#1077 (PR #1089)** — `migrate-isolation-v2` repair tool walked the
  tracked profile path (`agents/<a>/`) instead of the v2 runtime root
  (`data/agents/<a>/workdir`), so the repair was a no-op on actual v2
  installs. Now uses the v2 root resolver.

### Fixed — channel-agent isolation umbrella (#1078)

- **#1091** — umbrella for #1078 (F1+F2+F3+F5): plugin-catalog seed,
  data-root + data-agents-root matrix rows, chain-of-0700 walker.
  F4/F6 (channel cleanup symmetry + uninstall path) deferred to
  follow-up.

### Fixed — channel-agent first-run config seed

- **#1073 (PR #1097)** — first-run config prompts fired on every cold
  start of a channel agent because `CLAUDE_CONFIG_DIR` was unseeded.
  Pre-seed now runs after `bridge_linux_prepare_agent_isolation` via
  `sudo -n -u <iso> bash -c 'exec python3 ...'` (4-round codex
  convergence to land the right sudoers contract).

### Fixed — cron-dispatch auto-wake

- **#1096 (PR #1098)** — cron-dispatch rows targeting a `stopped` static
  agent did not wake the target, so the dispatched task sat queued
  forever. Daemon now auto-wakes a stopped static target when a
  cron-dispatch row targets it.

### Fixed — idle-nudge age gate

- **#1099 (PR #1103)** — daemon idle-nudge fired on any in-flight
  task age, including tasks legitimately mid-flight. The gate now widens
  to a task-level invariant (claimed-but-not-progressed > nudge
  threshold). Shell-fanout race deferred to #1106.

### Fixed — audit --since timezone normalization

- **#1100 (PR #1104)** — `agb audit list --since <naive>` compared a
  naive timestamp against tz-aware records, returning empty for valid
  input. Naive `--since` now normalizes to local TZ.

### Fixed — defensive BRIDGE_LAYOUT unset

- **#1101 (PR #1107)** — pane launch envelope inherited a stale
  `BRIDGE_LAYOUT` from the caller's shell, breaking layout resolution
  inside the new pane. Envelope now defensively unsets it.

### Fixed — watchdog scans wrong tree on v2

- **#1108 (PR #1109)** — `bridge-watchdog.py` enumerated
  `agents/<a>/` (tracked profile) but v2 runtime profiles live under
  `data/agents/<a>/workdir/`, causing false-positive
  `missing_files: CLAUDE.md, SOUL.md, ...` on every v2 agent every
  scan. Resolver now anchors on the registry-stored agent record.

### Changed — repo hygiene

- **#1110** — removed three stale planning / handoff docs (618 lines):
  `docs/handoff/219-linux-isolation-e2e.md`,
  `docs/stabilization-plan-2026-05-15.md`,
  `docs/audit-2026-05-15.md`. Replaced with topical CHANGELOG note
  for the historical reference.

### Fixed — beta6 r2 integration review

- **#1111** — codex full-branch r1 review surfaced 2 BLOCKING + 1
  SHOULD-FIX: scaffold smoke driver-fail on hardcoded sed line ranges
  (fixed via new heredoc-aware `scripts/smoke/helpers/extract-shell-fn.py`),
  MIGRATOR verify ↔ LAYOUT seam contract drift (verify contract
  amended — target-FS inspection only, resolver integration to beta7
  #1087), and CHANGELOG stale reference cleanup. r2 `implement-ok`.

## [0.14.5-beta5] — 2026-05-23

### Highlight — fresh-install bug-fix wave

Operator-cued **fifth prerelease** in the v0.14.5 stabilization window. A
13-issue parallel fixer wave bundling bugs registered 2026-05-22 (most found
during fresh-install verification on a brand-new server), shipped through the
`release/v0.14.5-beta5-integration` branch. Every PR was codex pair-reviewed
(`agb-dev-claude` + `agb-dev-codex`); the integration branch additionally
passed a full-branch codex review and a live Linux-VM verification of the
isolation-v2 fixes. Targeted modular smokes and the `lint-heredoc-ban`
baseline pass; the full `scripts/smoke-test.sh` run hits only the known
pre-existing #4793 leaked-agent-dirs / status-activity environmental failures.
`-beta5` prerelease; matching tag `v0.14.5-beta5`, GitHub release marked
**Pre-release**.

### Fixed — daily-backup

- **#1039** — `DAILY_BACKUP_LAST_PRUNED_COUNT` recorded a byte value, not a
  count: an empty `error_detail` field collapsed under `IFS=$'\t' read`,
  shifting `free_bytes` into `pruned_count`. The daily-backup payload is now
  parsed without IFS-whitespace collapsing, plus a `pruned_count` sanity bound.
- **#1041** — the daily-backup SQL snapshot was not restorable:
  `dump_sqlite_snapshot()`'s `iterdump()` emitted `sqlite_sequence` maintenance
  before the AUTOINCREMENT tables existed. The dump now defers those
  statements so the snapshot restores cleanly via stdlib `executescript`.

### Fixed — wiki tooling

- **#1040** — `wiki-mention-scan` matched bash `[[ ]]` expressions inside
  fenced code blocks as wikilinks; fenced (and `~~~`-fenced) regions are now
  blanked before wikilink matching.
- **#1042** — `wiki-daily-ingest` enqueued librarian Lane-B tasks whenever the
  `librarian` role merely existed. The enqueue is now gated on librarian
  ingest being *enabled* for the host profile AND a same-install guard
  (`BRIDGE_AGB` / task DB / state root all resolve under `$BRIDGE_HOME`), so an
  isolated fixture cannot leak tasks into the live DB.

### Fixed — A2A cross-bridge

- **#1043** — `agb a2a daemon start` reported success but the A2A receiver
  died when the launching shell exited. The receiver now double-forks into its
  own session (portable macOS + Linux) and the liveness check verifies the pid
  is genuinely this install's receiver (`--pidfile` identity match), so a
  stale/foreign pidfile no longer yields a false "already running".

### Fixed — hooks

- **#1054** — the tool-policy guard's `_is_read_intent_bash` split commands on
  `|`/`;`/`&` without quote-awareness, wrongly denying read-only commands like
  `grep -E 'a|b'` against protected paths. The split is now quote-aware and
  fails closed on an unbalanced quote (an un-parseable command is never
  classified read-intent).
- **#1055** — the codex SessionStart hook emitted `hookSpecificOutput.matcher`,
  which Codex 0.133.0's `deny_unknown_fields` schema rejects; the codex-format
  output now emits only `hookEventName` + `additionalContext`.

### Fixed — isolation-v2

- **#1045 / #1046** — a fresh v2 install's `agent create` (and the bootstrap
  admin scaffold) populated the agent profile under `home/` while the runtime
  resolved the agent's cwd to the sibling `workdir/`, leaving the runtime
  `workdir/` empty. `agent create` now defaults the scaffold target to the
  resolved `workdir/`, fully populated; the `home/` sibling is still
  materialized.
- **#1048** — `bridge_isolation_v2_matrix_rows_for_agent` fell back to
  `linux-user` for any non-`shared` isolation-mode value (including an empty
  result from a concurrently-rewritten roster), making a shared-mode agent
  demand a nonexistent `ab-agent-<agent>` group. The indeterminate fallback now
  resolves to `shared`.

### Fixed — agent policy

- **#1047** — `agent create` was ungated while `agent delete`/`update`
  required a trusted caller source. `agent create` is now gated symmetrically
  on the same caller-source contract (`agent-direct` denied,
  `operator-tui`/`operator-trusted-id` allowed); sanctioned non-interactive
  callsites (bootstrap admin create, librarian provision, smokes) pass a
  trusted source.

### Restored — codex pair auto-provisioning

- **#1052 / #1053** — install-time auto-provisioning of the `<admin>-dev` codex
  pair is restored, gated on codex-CLI detection AND a `server` host profile
  (a `dev` profile stays admin-only). Stale post-#4769 guidance — the
  picker-sweep cron skip message, the `CLAUDE.md` reviewer reference, and the
  README / admin-protocol contract — is corrected to the new server/dev split.

## [0.14.5-beta4] — 2026-05-22

### Highlight — runtime-friction closeout wave (+ verification re-cut)

Operator-cued **fourth prerelease** in the v0.14.5 stabilization window. Bundles
the six PRs that landed after `v0.14.5-beta3` (2026-05-21): two close-out PRs
merged directly to `main` (#1009, #1008) plus a four-fixer runtime-friction wave
(#1007, #1015, #1010, #1014) shipped through the `feat/wave-v0145-integration`
branch. Every PR was codex pair-reviewed (`agb-dev-claude` + `agb-dev-codex`);
the integration branch additionally passed a full-branch codex review and a
`scripts/smoke-test.sh` pass. No new features. `-beta4` prerelease; matching tag
`v0.14.5-beta4`, GitHub release marked **Pre-release**.

**Re-cut (2026-05-22):** `v0.14.5-beta4` was re-cut to fold in the bug found
during its own live-VM verification plus the issues/PRs opened against beta4.
The first-cut content above is retained; the re-cut adds the five follow-up
items in the "Re-cut" subsection below, delivered by four PRs (#1024, #1026,
#1027, #1029 — #1027 carries both #1025 and #1021). All four re-cut PRs were
codex pair-reviewed through the `feat/wave-v0145-b4recut-integration` branch,
which passed a full-branch codex review; the `#1025`/`#1028` isolated-create
fixes were re-verified live on an OrbStack Oracle Linux 9 VM
(`agent create --isolate` → `rc=0`, clean `start_dry_run`). The
`v0.14.5-beta4` tag and GitHub prerelease are updated to the merged re-cut
release commit.

**Re-cut round 2 (2026-05-22):** still before any download, `v0.14.5-beta4` was
re-cut a second time to fold in two further bug-class issues (#1031, #679) — see
the "Re-cut round 2" subsection below. The tag and prerelease move again to the
round-2 release commit.

**Re-cut round 3 (2026-05-22):** still before any download, `v0.14.5-beta4`
was re-cut a third time to fold in the **A2A cross-bridge task handoff**
feature (#1032) plus a macOS portability fix found while validating it
(#1037) — see the "Re-cut round 3" subsection below. This round adds a new
feature, so the "No new features" note above applies to the first cut and
re-cut rounds 1–2 only. A2A was rigorously validated across a macOS VM and a
Linux VM over real Tailscale before this fold-in. The tag and prerelease move
again to the round-3 release commit.

### Re-cut — verification follow-ups (2026-05-22)

- **Isolated `agent create` no longer aborts** (#1025) — the isolation-v2
  isolated-create scaffold built `runtime/agent-env.sh` with a controller-side
  non-`sudo` write under the `root:ab-agent-<name>` `0750` agent root, so the
  create aborted with `Permission denied`. The env file is now staged and
  installed in one privileged `install -o <controller> -g <agent_grp> -m 0640`
  (atomic owner/group/mode, no TOCTOU window), matching the v2 matrix contract.
- **`start_dry_run` workdir false-error fixed** (#1028) — after #1025 unblocked
  create, the post-create `start_dry_run` still emitted a false
  `[오류] workdir … 존재하지 않음` because the controller-side `[[ -d ]]` check
  cannot traverse the `0750` agent root. The workdir existence checks are now
  privilege-aware (sudo-backed) for linux-user isolated agents.
- **isolation-v2 apply no longer corrupts shared plugin perms** (#1021) —
  `migrate isolation v2 --apply` recursively re-grouped shared plugin
  `node_modules` to a private agent group, breaking other isolated agents that
  load the same plugin source. The recursive chgrp/chmod now excludes shared
  plugin material.
- **`agent update` no longer leaks secrets** (#1023) — `agent update
  --launch-cmd-*` printed credential-bearing env values (OAuth/MS365 secrets)
  into terminal output, `--json`, dry-run, and `audit.jsonl`. Sensitive env
  values are now redacted across every output surface (value redacted, key name
  kept) — case-insensitively on `SECRET`/`TOKEN`/`PASSWORD`/`KEY`/`CREDENTIAL`/
  `AUTH`/`AUTHORIZATION`/`BEARER`/`COOKIE`/`SESSION`/`JWT`.
- **Teams channel notification no longer silent-drops** (#1022) — the direct
  `notifications/claude/channel` metadata is kept flat/string-only; the rich
  nested `attachments` array is retained for the bridge queue/audit/replay body.

### Re-cut round 2 — additional bug fixes (2026-05-22)

`v0.14.5-beta4` was re-cut a second time (still before any download) to fold in
two more bug-class issues. Both PRs were codex pair-reviewed through the
`feat/wave-v0145-b4r2-integration` branch, which passed a full-branch codex review.

- **Teams attachment downloads authenticate** (#1031) — a Teams user pasting or
  dragging an inline image triggered a download that failed `HTTP 401`:
  `streamDownload()` issued a bare unauthenticated `fetch()`. The download now
  attaches the bot's `Authorization: Bearer` token, scoped by **exact-host
  match** to the Bot Framework / AMS attachment endpoints only (no token leak to
  other hosts); the pre-signed `file.download.info` path stays unauthenticated.
- **wiki-daily-ingest skips PreCompact dumps** (#679) — Lane B ingested the
  PreCompact hook's `pre-compact-dump-{auto,manual}*.json` capture envelopes,
  accumulating stuck captures. Lane B now excludes exactly those two dump
  shapes; ordinary raw captures (including unrelated `pre-compact-dump-*` names)
  are still ingested.

The #1010 isolated-agent reap path exercises destructive `userdel` / `setfacl` /
`groupdel`; CI and review verified the gating *decision* (Linux-only, exact
generated-user match). The live destructive path still warrants a Linux-host
spot check before stable `v0.14.5`.

### Re-cut round 3 — A2A cross-bridge task handoff (2026-05-22)

`v0.14.5-beta4` was re-cut a third time (still before any download) to fold in
the A2A feature and its verification follow-up. Both PRs were codex
pair-reviewed.

- **A2A cross-bridge task handoff** (#1032, PR #1035) — an agent on one Agent
  Bridge install can enqueue a task directly into another install's inbox
  queue, replacing the manual copy-paste / ssh relay. A direct-mesh push
  gateway over a Tailscale tailnet: each install runs an HMAC-authenticated
  receiver daemon (`bridge-handoffd.py`) bound to a tailnet IP only — failing
  closed on a wildcard/loopback bind or an address it cannot prove against
  `tailscale ip` — plus a durable SQLite sender outbox with retry/backoff and
  `message_id` dedupe. New CLI surface `agb a2a
  send|outbox|inbox-dedupe|peers|deliver|daemon`; data-only, git-ignored,
  mode-0600 config `handoff.local.json`. New modules `bridge-handoffd.py`,
  `bridge-a2a.py`, `bridge_a2a_common.py`, `bridge-handoff-daemon.sh`,
  `lib/bridge-a2a.sh`. See `docs/a2a-cross-bridge.md`.
- **A2A receiver locates the `tailscale` CLI outside `PATH`** (#1037) — the
  receiver preflight resolved `tailscale` via `PATH` only, so a daemon started
  from cron/launchd/systemd on a macOS host with Homebrew-installed Tailscale
  failed closed even though Tailscale was installed and up. Discovery now
  probes `PATH` then well-known install locations (`/opt/homebrew/bin`,
  `/usr/local/bin`, the macOS app bundle, `/usr/bin`);
  `BRIDGE_A2A_TAILSCALE_CLI` overrides. The fail-closed contract — exact
  membership in `tailscale ip` output, no CIDR-shape guessing — is unchanged.

A2A was validated on `agb-mac-seq` (macOS Sequoia) ↔ `agb-test` (Oracle Linux
9) over real Tailscale — happy-path handoff both directions, allowlist
rejection, HMAC auth failure, body-size cap, dedupe idempotency + hash
conflict, receiver-down → outbox-retry → recovery, daemon lifecycle, secret
rotation overlap, fail-closed wildcard/loopback bind, clock-skew rejection,
and `remote_addr` enforcement: 12/12 pass, no secret leakage in audit logs.

### Operator-visible

- **Session resume under custom `CLAUDE_CONFIG_DIR`** (#1015) — static Claude
  agents with a custom `HOME` / `CLAUDE_CONFIG_DIR` (isolation-v2) no longer
  start a fresh session on every restart. The resume + detect session-id helpers
  now resolve `~/.claude` from the agent's config dir, not the daemon HOME;
  unregistered/test callers keep the daemon-HOME fallback unchanged.
- **Runtime friction trio** (#1014) — (A) a freshly-pushed task no longer gets a
  redundant `ACTION REQUIRED` idle-nudge within the redelivery window; (B) a
  stale `BRIDGE_LAYOUT=legacy` is no longer baked into the generated agent
  env file when a v2 layout marker exists, and the warning text gives accurate
  remediation; (C) a `cd $BRIDGE_HOME && grep agent-roster.local.sh`-style read
  of the protected roster is correctly classified as a read across all shell
  separators, while writes to it stay denied.
- **Isolated-agent delete cleanup** (#1010) — `agent delete` on a linux-user
  isolated agent now reaps the dedicated OS user and strips its named-user
  traversal ACEs (best-effort, Linux-only, exact generated-user match required).
- **Watchdog engine-aware contract** (#1009) — the watchdog's profile-file /
  managed-`CLAUDE.md` drift checks no longer false-positive on `codex` /
  `antigravity` agents; a genuinely unknown engine still surfaces as drift.
- **Machine-local common-instructions override** (#1008) — an upgrade-preserved
  `shared/COMMON-INSTRUCTIONS.local.md` is appended to the generated shared docs
  under explicit markers; absent/empty/unreadable degrades to a byte-identical
  no-op.

### Test harness

- `smoke_setup_bridge_home` now isolates the cron state vars and
  `BRIDGE_LAYOUT_MARKER_DIR` so an isolated daemon's cron tick can no longer
  read or rewrite the operator's live `cron/jobs.json` (#1007).
- All five new wave smokes are registered in `scripts/smoke-test.sh` and wired
  into `scripts/ci-select-smoke.sh` self-edit + production-file triggers.

## [0.14.5-beta3] — 2026-05-21

### Highlight — ACL-deprecation set (#998) + accumulated stabilization wave

Operator-cued **third prerelease** in the v0.14.5 stabilization window. Bundles
15 commits that landed after `v0.14.5-beta2` (2026-05-20): the three-PR
ACL-deprecation set (#998) plus the 2026-05-20 stabilization wave and HUD fix.
Every PR was codex pair-reviewed (Waves 2026-05-20/21: `agb-dev-claude` +
`agb-dev-codex`). No new features. `-beta3` prerelease; matching tag
`v0.14.5-beta3`, GitHub release marked **Pre-release**. Stable `v0.14.5`
follows once the wave burns in on operator hosts.

The ACL set was additionally validated by a live VM QA pass (2026-05-21) on
OrbStack Linux (`agb-test`, Oracle Linux 9) and a macOS VM (`agb-mac-seq`,
Sequoia 15.7.3) — real `setfacl` / isolated-UID / `ab-shared` group behavior,
all green, no defect attributable to #995/#999/#1000.

### Operator-visible — ACL-deprecation set (#998)

The recurring `mask::---` ACL-regression family (#778/#441/#534/#543/#851) is
closed by replacing per-agent named-user `setfacl` ACEs with `ab-shared`
group-mode ownership. The isolated-agent OS users are already `ab-shared`
members (the upgrade's isolation-v2 migration backfills membership), so there
is no per-agent ACL to maintain or silently break.

- **Queue gateway socket** (#995, closes #994) — named-user ACEs replaced by
  group ownership: socket `chgrp ab-shared` + `0660`, instance dir
  `chgrp ab-shared` + `2770` (setgid). `SO_PEERCRED` request authorization is
  unchanged. When `ab-shared` is absent: `0600` owner-only fallback (smoke/dev)
  or a hard fail with an actionable create-the-group message (live runtime).
- **Controller Claude credential** (#999, #998 PR A) — `~/.claude/.credentials.json`
  moves from named-user ACEs to `ab-shared` group-mode (`0640`, group
  `ab-shared`, extended ACLs stripped). The verifier enforces the **exact**
  contracted file mode — a widened mode (`0660`/`0670`/`0770`…) now fails the
  check instead of false-passing (RC3 apply/verify-divergence guard).
- **Channel-dotenv stop-gap retired** (#1000, #998 PR B) — the runtime
  `apply_channel_state_dotenv_acl` self-heal is removed; the v3 channel-dotenv
  contract (isolated-UID owns its own `0600` dotenv, no extended ACL) is
  canonical, and `agent-bridge migrate isolation v3 --check/--apply` is the
  recovery path. The v3 detector now flags **any** extended ACL (named *or* a
  residual `mask::` *or* `default:`), so a mask-only residual is reported as
  drift instead of false `already-canonical`.

### Operator-visible — 2026-05-20 stabilization wave + HUD

- **HUD token-rotation usage cache restored** (#977) — `claude-hud` v0.0.12+
  dropped the OAuth-polling loop that wrote `.usage-cache.json`; a stdin-tap
  script in the HUD statusLine pipeline restores the cache that the
  token-rotation / rate-limit monitor depends on.
- **Isolated agent Teams-path regression fixed** (#993, closes #989) — a
  channel-list change + restart no longer leaves the cached
  `runtime/agent-env.sh` with a stale pre-v2 `*_STATE_DIR`; the shared
  refresh helper now also covers the `bridge-setup.sh` (`setup teams/discord/
  telegram`) and upgrade-time relay-cleanup mutation paths.
- **`upgrade --restart-agents` attached-skip notice** (#996, closes #980) —
  agents skipped because their tmux session is attached are now surfaced in
  the upgrade output, the `[upgrade-complete]` task body, and a dedicated
  deduplicated `[restart-required]` task.
- **agent restart preserves `--resume`** (#985, closes #981) — the session id
  is snapshotted before the kill so an operator-initiated restart resumes the
  prior conversation instead of starting fresh.
- **Daily-backup defaults** (#983, closes #974/#975) — `plugins/cache` excluded
  from the backup walk; `BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS` default raised
  300→600s. **Persistent exclude config** (#997, closes #979) — a
  `state/daily-backup/excludes.conf` file (one relpath per line) is now read in
  addition to the env var; no shell eval, survives upgrades.
- **upgrade picker-sweep** (#984, closes #978) — a one-shot picker-sweep runs
  after `--restart-agents` so codex agents are not left at the cwd-confirm
  picker until the next cron tick.
- **SOUL.md / CLAUDE.md scaffold-placeholder detection** (#988) — SessionStart
  surfaces a warning when an agent's profile still carries unfilled template
  tokens despite `SESSION-TYPE.md` marked complete.
- **pre-compact dump routing fixed** (#982, closes #976) — the pre-compact hook
  populates `suggested_entities` so librarian routes session dumps to the
  `agents` wiki kind instead of falling through to `operating-rules` and
  triggering a `[librarian-ambiguous]` escalation loop.
- **isolated restart + socket listener recovery hardened** (#992), **Teams
  inbound text extraction + CRLF normalization** (#986/#987).

### Known follow-ups (not in this prerelease)

- `agent delete` does not clean up an isolated agent's dedicated OS user or its
  stale traversal ACEs on ancestor dirs — tracked as #1010.
- A dedicated `controller_credential_group` apply→check regression smoke for
  #999 — tracked fast-follow.
- Antigravity (`agy`) engine support is on a separate preview track
  (`v0.14.5-antigravity-preview`); it folds into a later beta once tested.

## [0.14.5-beta2] — 2026-05-20

### Highlight — Teams inbound regression close-out wave (3 fixes)

Operator-cued **second prerelease** in the v0.14.5 stabilization window. Bundles three independent fixes that landed after v0.14.5-beta (2026-05-19). All three were caught + pair-reviewed by codex (Wave 2026-05-20: `agb-dev-claude` + `agb-dev-codex`). No new features. This is a `-beta2` prerelease; the matching tag is `v0.14.5-beta2` and the GitHub release is marked **Pre-release**. Stable `v0.14.5` follows once the wave burns in on operator hosts.

### Operator-visible

- **Teams inbound delivery — direct channel restored for isolated + shared agents** (refs #959 / PR #970). The v0.14.5-beta `TEAMS_DELIVERY_MODE` env opt-in was a queue-based workaround for the wake-drop symptom; this fix closes the underlying contract violations that broke direct channel delivery in the first place. Two distinct root causes were addressed:
  - **Isolated agents (`dev_mun` class)** — stale `~/.agent-bridge/agents/<agent>/.mcp.json` could contain bare `mcpServers.teams` entries that shadowed the plugin namespace (`plugin:teams@agent-bridge`). New helper `scripts/python-helpers/prune-legacy-teams-mcp.py` removes legacy bridge-managed shadows from agent root + workdir `.mcp.json` files; user-authored MCP entries are preserved. Launch path is now plugin-scoped only — dev-plugin private `.mcp.json` server entries are no longer auto-promoted to global `server:<name>` selectors.
  - **Shared agents (`sales_choi` class)** — managed hook commands rendered as `~/.agent-bridge/hooks/...` collided with v2 shared launch `HOME=<bridge_home>/agents/<agent>/home`, breaking `UserPromptSubmit` even though Teams delivery itself worked. Managed hook commands are now normalized to absolute bridge-home paths on both shared and isolated agents; Claude settings are mirrored into the launched `CLAUDE_CONFIG_DIR` so hook resolution no longer depends on runtime `HOME`.
  - 5 new regression smokes guard the path: `hooks.sh` (absolute hook paths + shared Claude config-home mirror), `isolated-settings-rendering.sh` (isolated renderer absolute-hook + symlink + user-key preservation), `launch-dev-channels-injection.sh` (plugin-scoped launch), `prune-legacy-teams-mcp.sh` (preserve user MCPs while pruning managed shadows), `shared-settings-preserve-user-keys.sh` (shared renderer user-key preservation + dev-plugin settings).
  - The fix also closed a transient regression caught by the existing `upgrade-shared-settings-propagate` smoke: the rerender plan's `expected` JSON was not receiving the same hook-path normalization as the effective settings file, causing "operator overlay wins over managed default" to report `needs-rerender` instead of `rerendered`. Plan path now mirrors the normalization symmetrically (`bridge-agent.sh` plan JSON ↔ `bridge-hooks.py` rendering).
- **picker-sweep rate-limit rotation — cross-process race fixed** (closes #971). Two concurrent picker-sweep cron runs could both pass `_psw_rate_limit_rotation_due` simultaneously and both call `bridge-auth.sh claude-token rotate`, burning two Claude tokens for one rate-limit event. The in-process `rate_limit_rotation_attempted` flag only deduped within a single sweep. New `mkdir`-based cross-process lock under `$BRIDGE_HOME/state/picker-sweep/rotation.lock` serializes the due-check + claim + rotate + cooldown-write critical section. PID-based stale reclaim with `BRIDGE_PICKER_SWEEP_ROTATION_LOCK_STALE_SECONDS` (default 300s); never reclaims silently (WARN log audit trail). Defer path logs `"another sweep holds the rotation lock"` and sets the in-process flag so the deferring sweep doesn't re-log on subsequent agents. New `picker-sweep-concurrent-rotation` smoke launches 2 parallel sweeps and asserts exactly 1 rotate call per round (5 rounds default; verified to fail at round 1 with "got 2" when the lock is disabled).
- **bridge-stall codex glyph false-negative — real provider errors no longer suppressed** (closes #965). The original `bridge-stall.py` glyph-block skip swallowed every non-empty line under a codex agent glyph/continuation prefix (`•` / `│` / `└` — tool bullet, continuation body, continuation tail) until the next blank, so a real stall like `• Running smoke\nError: HTTP 429 too many requests\n` was classified as silent — hiding actually rate-limited agents from the stall detector. The fix introduces `RAW_ERROR_PREFIXES_RE` (anchored at raw line start, word-boundary + separator) matching `Error:` / `Err:` / `Warning:` / `Fatal:` / `Panic:` / `Exception:`. The match runs against the **pre-strip** line, so only flush-left provider output escapes; indented tool/diff continuations stay suppressed. Casual narration like "the user got an error" does not match. 9 new regression cases cover 3 recovery shapes, 5 false-positive guards, and 1 multi-block reset.

### Architecture follow-up tracked

- **#972 plugin canonical runtime identity (umbrella, NOT in this release)**: the Teams root cause is the first visible symptom of a broader class — every bridge-managed plugin needs one canonical runtime identity per agent (declaration, cache, state dir, settings, launch selector, transcript namespace must all agree), with preflight quarantine of legacy shadows + success measured at transcript-origin level. 6-track plan: generic preflight classifier → 3 lifecycle callsite wirings → `ARCHITECTURE.md` contract section → `agent doctor` canonical-identity output → CI smoke matrix (Teams + non-Teams plugin) → `TEAMS_DELIVERY_MODE` deprecation timeline. Tracks the structural fix; not in v0.14.5-beta2 scope.

### Internal

- `.lint-heredoc-baseline.tsv` re-synced for PR #970's line-number shifts; 5 new sites accepted with audit-trail (`Phase 6 PR F (PR #970 Teams)` for the two new C3 sites, all H3 sites remain `Phase 5 PR E`). `lint-heredoc-ban` CI gate stays green.
- Codex pair-review chain (Wave 2026-05-20): 9 acceptance criteria on #970 + 8 on #971 + regression-test coverage on #965; r1→r2→r3 rounds converged within the CLAUDE.md soft-agreement protocol.

## [0.14.5-beta] — 2026-05-19

### Highlight — prerelease patch wave (4 operator-visible fixes + 1 CI unblock)

Operator-cued **prerelease** bundling the 4 operator-visible fix PRs merged to `main` after the v0.14.4 ship (2026-05-18) plus a smoke-only CI gate restoration. Targets the v0.14.5 stabilization window: post-upgrade onboarding drift (#906), v2 shared-mode boot wedge (#909), watchdog alert noise (#905/#907), a Teams inbound-wake fallback for #959, and the smoke-only fix (#969) that restored the `unit/static smoke` CI gate after main had been red for 2+ days. No new features; behavior of existing callers is preserved unless the bug shape changed.

This is a `-beta` prerelease; the matching tag is `v0.14.5-beta` and the GitHub release is marked **Pre-release**. Stable `v0.14.5` will follow once the bundle has burned in.

### Operator-visible

- **`agent-bridge upgrade --apply` no longer regresses onboarded admins back to `Onboarding State: pending`** (closes #906 / PR #964). The v2 migrator now scans all three layout roots (`agents/<agent>/`, `data/agents/<agent>/{home,workdir}/`) for prior onboarding state before stamping `SESSION-TYPE.md` from template. One-way ratchet: pending → complete only; operators are never un-onboarded by an upgrade. Watchdog no longer files recurring high-priority profile-drift tasks for already-completed admins, and `restart_readiness` stays `ready` instead of flipping to `onboarding-pending`.
- **`agent create <name>` on a v2-active shared-only install stays bootable** (closes #909 / PR #963). Previously the v2 isolation logic emitted a `linux-user` matrix (per-agent UID `agent-bridge-<X>`, group `ab-agent-<X>`) regardless of the agent's `isolation_mode`; on a shared-only install those identities don't exist, `chown` failed, and the daemon entered a ~15–30s restart loop the operator could not exit from inside an agent session (`agent update --loop off` is a TTY-protected mutation). The matrix now branches on `bridge_agent_isolation_mode`: shared agents get a controller-owned row family (operator + operator-primary-group, modes 2750 / 2770), no isolated-user-home, no per-agent plugin rows. Linux-user matrix is byte-identical to legacy shape. Belt-and-braces guard in `apply_row` also skips (warn + rc=0) when a resolved owner or group does not exist on the host.
- **Watchdog stops filing admin-inbox tasks for two non-actionable conditions** (closes #905 + #907 / PR #962):
  - **Engine-aware profile check (#905)** — Codex agents no longer drift on missing Claude-profile files (`CLAUDE.md`, `SOUL.md`, `MEMORY-SCHEMA.md`, `MEMORY.md`, `SESSION-TYPE.md`). The required-file set is now per-engine; codex returns empty, and onboarding-stale + managed-block checks are Claude-only.
  - **Dynamic-agent fresh-state skip (#907)** — newly-provisioned dynamic agents (e.g. `librarian`) no longer trip the `missing_block` warn signal for the system-provisioned fresh shape (`onboarding_state: pending` + `missing_managed_claude_block: yes`). Actionable drift (broken symlinks, etc.) still surfaces — only the default fresh-provision shape is suppressed. Legacy listing-only fallback (`--no-registry-anchored` or registry lookup failure) preserves pre-fix Claude-required behavior so a broken registry never silently disables drift detection.
- **Teams inbound — new `TEAMS_DELIVERY_MODE` env opt-in for queue-based fallback** (refs #959 / PR #961). Issue #959 surfaced a window where `notifications/claude/channel` is acked at the MCP layer but Claude Code silently drops the wake, leaving the agent idle while `messages.jsonl` is populated. Root cause lives in Claude Code; this patch ships an operator-visible workaround:

  | Mode      | Behavior |
  | --------- | --- |
  | `channel` | Current behavior (default). One `mcp.notification` per message. No change for existing installs. |
  | `bridge`  | Skip the channel notification; enqueue the message via `bridge-task.sh create`. Daemon wakes the agent through the standard inbox path. |
  | `both`    | Fire the notification AND enqueue the queue task. Belt-and-braces; operator accepts possible duplicate delivery. |

  Resolved once at module load (invalid values warn once on boot, not per message). Bridge-enqueue failures log to stderr but never throw — only channel-mode failures still surface to the Teams webhook so it retries. README §Delivery Mode rewritten with the three modes and trade-offs. Operators repro-ing #959 should set `TEAMS_DELIVERY_MODE=both` to keep both wake paths alive while the upstream notification-handler fix is investigated.

### Dev / CI unblock (no operator-visible behavior change)

- **`unit/static smoke` CI gate restored** (PR #969). main had been CI-red since 2026-05-17 13:01 UTC because (a) `scripts/smoke/upgrade-source-preservation.sh:117` asserted unquoted `BRIDGE_ADMIN_AGENT_ID=patch` after the writer in `bridge-setup.sh` started emitting the quoted form `BRIDGE_ADMIN_AGENT_ID="patch"` (defensive against future values with spaces), and (b) `scripts/smoke/admin-pair-no-auto-backfill.sh:C1` called `bridge-init.sh --dry-run` which early-gates with `bridge_init_require_command codex` even though the GH Actions Ubuntu runner has no `codex` (or `claude`) binary on PATH. Fix is smoke-only: assertion now matches the quoted writer form, and the dry-run probe plants exit-0 `codex` + `claude` shims in a mktemp dir and prepends to PATH for the probe scope only. No production code changed (bridge-init.sh, bridge-setup.sh untouched). No CI image changed. Operator + dev hosts that have the real engine binary on PATH are unaffected (the shim is shadowed and dry-run never invokes it).

### Files changed (vs v0.14.4)

- `bridge-agent.sh` (+34) — `agent create` runs `bridge_isolation_v2_apply_grant_matrix_for_agent --apply` for shared agents on a v2-active install
- `bridge-upgrade.py` (+92) — three onboarding-state preservation helpers + migration call site
- `bridge-watchdog.py` (+187) — engine-aware required-files + dynamic-agent fresh-state suppression + 2 helper extractions
- `lib/bridge-isolation-v2.sh` (+262) — `matrix_rows_for_agent` shared-mode branch, `apply_row` belt-and-braces, 2 new identity helpers
- `plugins/teams/README.md` (+16) — §Delivery Mode rewrite (3-mode table + trade-offs)
- `plugins/teams/server.ts` (+244) — `DELIVERY_MODE` resolver + `deliverViaBridgeQueue()` + reworked `handleActivity` delivery block
- `scripts/smoke/isolation-v2-macos-noise-suppression.sh` (+2) — touched in PR #962 path
- `scripts/smoke/watchdog-registry-anchored.sh` (+96) — 3 new cases (C8/C9/C9b) for the watchdog fix
- `scripts/smoke/admin-pair-no-auto-backfill.sh` (+16/-5) — codex/claude shim for the dry-run probe (PR #969 CI unblock)
- `scripts/smoke/upgrade-source-preservation.sh` (+1/-1) — assertion matches writer's quoted form (PR #969 CI unblock)

### Verification

- All 4 PRs went through codex pair-review and shipped `implement-ok` before merging to `main`.
- macOS / Linux compatibility preserved across all 4 paths (the v2 matrix fix in particular explicitly verifies macOS no-group surface with the belt-and-braces guard).
- Operator host-level verification deferred — this is the purpose of the `-beta` channel.

### Issues closed

- #905, #906, #907, #909

### Issues referenced (not closed)

- #959 — operator-visible workaround shipped via `TEAMS_DELIVERY_MODE` (PR #961 is `refs #959`, not `closes`). The issue remains open pending live verification and an upstream Claude Code fix to the notification-handler silent-drop.

## [0.14.4] — 2026-05-18

### Highlight — Teams plugin: bidirectional file attachments (Phase 1)

Operator-cued single-PR patch release. Adds bidirectional file attachment support to the Microsoft Teams channel plugin (`plugins/teams/`), closing issue #957. 1 PR (#958), 3-round codex pair-review chain.

### Operator-visible

- **Inbound attachments** — Teams attachments with general-file content types (PDF, DOCX, ZIP, octet-stream, images, audio, video, plain text, etc.) now download to `<TEAMS_STATE_DIR>/attachments/<message_id>/<filename>` and surface in the channel notification meta `attachments` array, the same way `image/*` and Teams-native file picker uploads already did. Adaptive cards and other Teams card content types (`application/vnd.microsoft.card.*`, `application/vnd.microsoft.teams.card.*`) remain `skipped_non_file` by design — operator scope is "general files only".
- **Outbound attachments** — the `reply` MCP tool now accepts an optional `attachments` array of `{path, name?}` objects. Personal-chat only (Phase 1). Files are delivered via the Teams file consent card flow: the bot sends a consent card, the user clicks Accept, the bot uploads to the URL Teams provides, and Teams attaches the file in the conversation. Group / channel outbound is deferred to Phase 2 (requires SharePoint upload via Microsoft Graph); group-chat invocations return a structured `attachments_not_supported_in_groupchat` error so the agent can fall back to text-only.
- Defaults: 50 MB per file (clamped to 1 GB via `TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES` env), 10 attachments per message. Outbound allow root defaults to `${TEAMS_STATE_DIR}/outbound` and can be overridden via `TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT`.

### Security hardening (caught during codex pair-review)

The 3-round chain surfaced and fixed several classes of attack surface before merge:

- **Symlink escape at consent time and at upload time** — both the allow-root containment check and the upload-time read now `realpath`-resolve the supplied path and `lstat`-reject symbolic links outright. Stored record holds the realpath-pinned inode chain; upload-time re-validates inside the consent lock against the live filesystem state. Size drift since consent now refuses the upload (was a warning in an earlier round).
- **Consent-store race condition** — per-process promise-chain mutex serializes every load-mutate-save sequence on `outbound-consents.json`. Token is reserved (deleted from store + persisted) INSIDE the lock BEFORE the PUT begins, so a concurrent accept-replay during a slow upload hits the 404 path instead of attempting a second PUT to the single-use upload URL.
- **Token-to-conversation binding** — invoke handler now verifies `activity.conversation.id` matches the stored `conversation_id` and (when both sides populate it) `activity.from.aadObjectId` matches the stored `aad_object_id`. Asymmetric aad state (one side present, the other absent) logs a stderr warning before proceeding with conversation-only bind. Mismatch drops the consent record as compromised.
- **Allow-root sanity** — `resolveOutboundAllowRoot` asserts the resolved path is a directory (`statSync.isDirectory()` after realpath); a file-valued env override is rejected at first use with both the original and resolved paths in the error.
- **Corrupt state file recovery** — malformed `outbound-consents.json` is renamed to `outbound-consents.json.corrupt-<epoch_ms>-<pid>-<uuid8>` (collision-resistant) and logged to stderr; the plugin starts with a fresh store rather than crashing or silently overwriting evidence.

### Docs

- `plugins/teams/README.md`: updated `Tools` section to document the optional `attachments` parameter; added a new `Outbound Attachments` section paralleling the existing `Inbound Attachments` documentation; removed the "outbound not implemented" disclaimer.

## [0.14.3] — 2026-05-18

### Highlight — daemon-hang root-cause wave (#946 5-layer fix) + dynamic launch UX fix + Phase 1 footgun #11 ratchet infrastructure

Operator-cued patch release rolling up the 2026-05-17/05-18 daemon-hang diagnosis + fix wave (#946 5-layer root-cause cascade), one operator-reported dynamic-launch UX regression (#955 / queue task #4813), one footgun #11 follow-up (#953 / queue task #4807), and the first phase of the footgun #11 CI ratchet infrastructure (#954 / queue task #4812). 8 PRs total. The #946 cascade is operator-visible (daemon no longer wedges silently on macOS Bash 5.3.9); #955 fixes the silent admin-role hijack reported during VM validation; #954 adds dev/CI infrastructure with zero runtime behavior change.

### Operator-visible

- **Daemon no longer wedges silently** when `tick_subshell` operations stall (#946 / PRs #947 + #949 + #950 + #951 + #952). 5-layer root-cause fix from codex pair-review on the OrbStack VM hang reproducer:
  - **L1** (PR #951): `bridge-core.sh` now validates `BRIDGE_SCRIPT_DIR` exists at startup and at every helper invocation. Previous behavior: stale `BRIDGE_SCRIPT_DIR` (e.g. after source-checkout move) silently broke every helper subprocess without any error path. New behavior: explicit `_or_die` with re-resolution from `BASH_SOURCE`.
  - **L2 + L4** (PR #952): daemon tick subshell calls wrapped in `bridge_with_timeout` (5s ceiling); `idle_ready` writer failures now explicitly fall through to maintenance pass instead of nudge skip (prior behavior starved maintenance and left the daemon visible-running but functionally idle).
  - **L3** (PR #950): silence-watchdog now captures full stderr from resolver die paths, classified as `resolver_die` with stderr preview, surfacing in `state/silence-watchdog.json` `detail.resolver_die` field. Operators can grep `detail.resolver_die` to identify the L1 vector.
  - **Entry fix** (PR #947): `scripts/smoke-test.sh` correctly exports `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT` at auto-isolation site so the matrix runs past step 266 without false-failing on the v2 root.
  - **Picker auto-unstick** (PR #949): `scripts/picker-sweep.sh` now explicitly handles Claude's "Bypass Permissions" and "Enable auto mode" interactive picker shapes (WARNING-header anchored + dual-header detection + dual-check for warning text + accept line). Operators no longer have to manually attach to a wedged static session to advance the picker.
- **`agent-bridge --claude --name <new-dynamic-name> --no-attach` no longer silently hijacks to a same-engine static role** (#955 / queue task #4813). Previous behavior: when cwd's project_root hosted exactly one static role for the requested engine, `SPAWN_PREFERENCE=wake` defaulted in non-TTY mode and woke that static role instead of the operator's named dynamic worker. The explicit `--name` was dropped on the floor and a marker line printed: `[info] 새 dynamic worker 'X' 대신 정적 역할 'Y'를 깨웁니다`. New behavior: non-TTY default is `shared` (operator gets a new dynamic worker on the current checkout). `--prefer wake` / `--prefer new` still honored for operators who explicitly opt in. TTY interactive picker unchanged. Added regression smoke (`scripts/smoke/dynamic-launch-no-admin-fallback.sh`) with C1/C2/C3 + positive-control + temp-daemon-leak-prevention coverage.

### Stability hardening — footgun #11 / read_comsub deadlock class (follow-up to v0.14.2's PR #940)

- `bridge-daemon.sh` + `lib/bridge-cron.sh` extracted 20 latent footgun #11 sites to standalone helpers (#953 / queue task #4807). Same pattern as `lib/upgrade-helpers/` (v0.13.9) and `lib/agent-cli-helpers/` (v0.14.2 / PR #940): nested `$()` + heredoc-stdin sites now invoke `bash <helper-script> <argv...>` with the parent process spooling argv to tempfiles where needed, never via stdin-heredoc-to-subprocess pipeline. 7 daemon sites → `lib/daemon-helpers/` (6 fn-based + 1 inline). 13 cron sites → `lib/cron-helpers/`. `bridge-core.sh` source made idempotent so helpers can source it without double-init. CI lint-heredoc-ban ratchet now covers `bridge-daemon.sh` (ceiling=0) and `lib/bridge-cron.sh` (ceiling=0).

### Dev / CI infrastructure — footgun #11 Phase 1 ratchet

- **`scripts/audit-footgun-11.sh` + `.lint-heredoc-baseline.tsv` + `scripts/lint-heredoc-ban.sh --baseline-check`** (#954 / queue task #4812). Category-aware (C1/C2/C3/C4/H3) snippet-hash ratchet against an opt-in baseline TSV. Detects:
  - cross-line capture state (paren-type stack tracking C captures vs G groups across multi-line `$( ... )` constructs, with case-arm strip + escape-swallow + `#`-comment-break paren-gating)
  - per-(path, hash, category) occurrence counts (silent copy-paste of an already-baselined footgun in the same file fails the ratchet)
  - deletion drift (current_count < baseline_count fails with `--baseline-update` guidance, preventing stale capacity from masking later regressions)
  - whitespace tolerance for `<<  'PY'` (Bash-legal but easily-missed shape)
- New CI step runs `scripts/smoke/lint-heredoc-scanner-self.sh` (Ubuntu, Bash 4+) which exercises the audit + baseline-check + a real-tree assertion that `STRIP_CASE_ARM_FIRES > 0` (proving the strip runs in production code, not just fixtures).
- Initial baseline: C1=104, C2=54, C3=314, C4=0, H3=366, SAFE=593 (TOTAL=1431 sites). All existing sites accepted; future additions must justify entry into the baseline TSV via the metadata columns (owner + Phase tag).
- Phase 2-6 PR pipeline scope is annotated per-row in the baseline so the next migration waves can scope by `Phase N PR X`.
- Zero runtime behavior change. Bash 3.2 fixture parse caveat documented inline (CI runs on Ubuntu under Bash 4+).

### Docs

- `CLAUDE.md`: explicit operator-permission requirement for version releases. Standing autonomy on stabilization work does NOT include the release ship itself. Operator cues the release.

## [0.14.2] — 2026-05-17

### Highlight — stability + completeness pass (22 fixes from 2 sessions + OrbStack VM E2E discoveries)

Operator-cued patch release rolling up the 2026-05-16 noise-reduction wave + the 2026-05-17 stability + lifecycle-cleanup waves. 22 PRs total; nothing is feature-additive except #933 (blocked-notify queue contract). The OrbStack VM lifecycle E2E test on 2026-05-17 surfaced 2 Linux-specific regressions (#936 layout-resolver false-evidence + #937 ARG_MAX overflow) that are also in this release. Post-merge wave from patch (queue tasks #4793-#4798) addressed 6 agent-lifecycle cleanup gaps.

### Operator-visible

- `agent-bridge` / `agb` CLI on macOS Bash 5.3.9 no longer hangs on `registry` / `list` / `show` (queue task #4773 / PR #940). Same class as the v0.13.7-v0.13.10 footgun #11 wave; bridge-agent.sh sites that used `bridge_agent_manage_python "$(...)" <<'PY'` now spool JSON to tempfiles and invoke standalone helpers in `lib/agent-cli-helpers/`. Lint-heredoc-ban ratchet expanded to cover `bridge-agent.sh` (ceiling=9).
- `agent delete --orphan-tasks` now actually closes orphaned tasks (queue task #4797 / PR #943). Previously the agent registry entry was removed but `assigned_to=<deleted-agent>` task rows remained `blocked`, leading to ghost inboxes (operator saw 27-day-old crm-cli + 22-day admin-smoke entries). New cancel path sets `status=cancelled` + clears lease + emits `cancelled` task_event.
- Watchdog no longer reports false "profile drift" alerts for orphan directories that were never registered (queue task #4796 / PR #941). Enumeration is registry-anchored by default; orphan dirs surface as a separate `orphan_directory` category.
- Daemon no longer retries `auto-start backoff` for deleted agents (queue task #4795 / PR #942). `agent delete` + `agent retire` clear daemon-autostart state; daemon sync pass also sweeps stale entries every tick.
- `BRIDGE_LAYOUT=legacy` warning no longer fires on every CLI invocation (queue task #4798 / PR #944). `bridge-upgrade.sh` self-cleans stale tmux server env vars on every non-dry-run upgrade; the warning is gated to once-per-process.
- `bridge-init.sh` clean install on Linux no longer false-trips `markerless(existing-install)` on empty `state/cron/workers/` subdirs (PR #936). Layout-resolver evidence probe matches its documented intent ("have content") — switched from `compgen -G` to `find -type f`.
- `scripts/smoke-test.sh` no longer leaks empty agent directories to live `$HOME/.agent-bridge/agents/` when `BRIDGE_HOME` is unset (queue task #4793 / PR #939). Smoke now auto-isolates to a `mktemp -d` parent, and cleanup defensively wipes (with fingerprint guard) any smoke-shaped dirs that escaped to the live install.
- `bridge-upgrade.sh` status-print + analyze subcommand no longer hits Linux ARG_MAX (E2BIG) on big upgrade manifests (PRs #937 + #938). 14 sites total converted to file-as-argv pattern. macOS unaffected.
- `bridge-cron.sh` `bridge_cron_write_completion_note` + `bridge_cron_write_followup_body` no longer wedge on Bash 5.3.9 (PR #928). Same footgun #11 class as the v0.13.7-9 hotfix wave (bridge-upgrade.sh covered there; cron module covered here).
- Daily backup timeout now configurable via `BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS` env (default 300s, up from hardcoded 120s) (refs #745 / PR #935). Larger installs (operator's 1.4GB tarball) no longer always-fail at the 120s ceiling.
- Daemon now wraps 6 previously-unprotected `$(...)` captures with `bridge_with_timeout` (PR #931, the Track B-1 fix from the 2026-05-16 daemon wedge incident). Each call site has a distinct label so `daemon_subprocess_timeout` audit rows distinguish them.
- Inbox-nudge sweep no longer fires identical payloads multiple times into mid-tool-call agents (refs #767 / PR #932). Per-agent fingerprint dedup via `BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS` (default 60s) + clock-skew guard for NTP step-back resilience.
- Worker agents that block mid-plan now auto-notify the requester (refs #697 / PR #933). `claimed → blocked` transition with a non-empty note emits a `[task-blocked]` notification task to the original requester (mirrors the existing `[task-complete]` pattern). Idempotent per transition.

### Removed

- **Auto-backfill of the `<admin>-dev` codex pair** (reverts #517; queue task #4769 / PR #934). `lib/bridge-admin-pair.sh` and the `bridge_ensure_admin_codex_pair` helper, the `bridge-upgrade.py inject-admin-pair-block` subcommand, the SOP-block injection on every `migrate-agents` upgrade pass, and the `bridge-init.sh` / `bridge-upgrade.sh` admin-pair backfill sites are all removed. v0.14.0 silently registered a sibling `<admin>-dev` codex agent on every upgrade and (combined with the `:-admin` init fallback) shifted `BRIDGE_ADMIN_AGENT_ID` away from the operator's chosen value (typically `patch`) to literal `admin`, which defeated the model-diversity intent of the documented `patch (claude) + patch-dev (codex)` standard pair. The admin pair is now an explicit one-time setup: `agent-bridge setup admin <agent>` writes the identifier, and `agent-bridge agent create <admin>-dev --engine codex …` registers the sibling if the operator wants one.
- **Silent admin-scalar writes from `agent reclassify` (operator-invoked AND upgrade-invoked)** (PR #934). `bridge_agent_reclassify_static_admin` no longer upserts `BRIDGE_ADMIN_AGENT_ID` when reclassifying a dynamic-but-static-shaped agent. The previous behavior fired from both `agent reclassify --apply` and the automatic reclassify pass that `bridge-upgrade.sh` runs on every non-dry-run upgrade. The identifier is now written by exactly one code path: `agent-bridge setup admin <agent>` (`bridge-setup.sh::run_admin`). Operators recovering an admin agent that is mis-recorded as `dynamic` run `agent-bridge agent reclassify --apply` THEN `agent-bridge setup admin <agent>`.

### Changed

- `bridge-init.sh` admin-agent default fallback flipped from `:-admin` to `:-patch` so admin-id-unset fresh installs land on the documented standard identifier (PR #934).
- Post-upgrade advisory in `bridge-upgrade.sh` for hosts with auto-created admin/admin-dev directories (PR #934): non-destructive recipe pointing at `agent-bridge agent retire admin-dev` → `retire admin` → `setup admin patch` to restore the patch-only contract. No auto-retire.
- `bridge-cron.py` `subprocess.run` / `check_output` calls now have explicit `timeout=` kwargs (PR #930). Defensive fix against `/proc` over NFS or downstream-tool hangs.
- BSD/GNU portability for `mktemp -t TEMPLATE` (PR #929): 17 sites converted to portable positional form `mktemp ${TMPDIR:-/tmp}/TEMPLATE.XXXXXX`. r1 had an extension-suffix bug (`name.XXXXXX.md` is literal on BSD); r2 fixed by moving extension before the X-block (`name.md.XXXXXX`). Production sites only; test fixture in `tests/isolation-v2-pr-c/` intentionally left untouched.

### Stability hardening — footgun #11 / read_comsub deadlock class

- `lib/bridge-cron.sh` `bridge_cron_write_completion_note` + `bridge_cron_write_followup_body` (PR #928). Two unmigrated sites in cron module. Pre-capture nested `$()` into locals before the `python3 - <<'PY'` heredoc invocation.
- `bridge-upgrade.sh` ARG_MAX overflow: 6 sites in status-print + analyze subcommand + `bridge_upgrade_print_channel_guard_summary` function (PR #937 + r2 + r3). Discovered during OrbStack VM Scenario 2 (Oracle 9): `python3 - "$ANALYSIS_JSON"` etc. hit `Argument list too long` on large manifests. Switched to tempfile-as-argv pattern (mirrors `lib/upgrade-helpers/`).
- `bridge-upgrade.sh` audit sweep: 8 additional ARG_MAX-risky sites at lines 1362/1373/1606/1653/1844/2350/2376/2408 (PR #938).
- `bridge-agent.sh` registry/list/show: 3 critical sites with double-nested `$()` + heredoc-stdin (queue #4773 / PR #940). Extracted to standalone helpers in `lib/agent-cli-helpers/` (mirrors `lib/upgrade-helpers/`). `set +e` / `_rc=$?` / `set -e` / `rm -rf` cleanup at each call site (RETURN trap is bypassed by errexit on Bash 5.3.9 — empirically verified).
- `bridge-agent.sh` delete path: 4 additional latent footgun #11 sites surfaced + fixed during queue #4797 work (PR #943). Mirrors PR #940 pattern with 4 new `lib/agent-cli-helpers/` files.
- Daemon spawn-site timeout coverage (Track B-1 from 2026-05-16 daemon wedge, PR #931): 6 sites in `bridge-daemon.sh` at lines 1092/1154/1278/1367/2618/3558/5222 wrapped with `bridge_with_timeout`. Each label distinct so audit-row attribution is unambiguous. Root cause of the 2026-05-16 operator wedge: `wait_for → waitchld → __wait4` blocked indefinitely on disk-pressure heredoc child.

### Fixes from 2026-05-16 noise-reduction wave (carried forward)

- `picker-sweep` allow-list missed "I am using this for local development" + codex cwd-confirm pane (PR #923).
- `classify_stale` exempts dynamic-source agents from uniform thresholds (PR #924) — idle is normal for operator-driven container agents.
- `_ENV_DUMP_PATTERNS` tool-policy regex tightened to stop false-positive on natural-language `env`/`printenv` (5 rounds of codex iteration, PR #925). Catches GNU `--name=value` long-opts, separated-arg long-opts (`--unset NAME`), utility-less verbs (`env VAR=val`, `-u VAR`, `-0`, `--null`, FD redirects), while preserving legitimate `genv` invocations.
- `bridge_export_env_prefix` no longer re-exports stale `BRIDGE_LAYOUT` / `BRIDGE_DATA_ROOT` from possibly-stale parent (PR #926). Every CLI command no longer warns about stale-marker conflict.
- `bridge_worktree_doctor` reaps orphaned children when pruning worktree directories (PR #927). Per-token anchor catches interpreter-exec zombies (`python /worktree/script` shape).

### Stabilization / completeness

- Layout-resolver evidence probe fixed: empty `state/cron/` subdirectories no longer false-trip `markerless(existing-install)` classification (PR #936). Discovered during OrbStack VM Scenario 1 (Ubuntu noble) — blocked every clean Linux install path. macOS unaffected (already on v2 marker).
- Watchdog enumeration: registry-anchored default instead of `agents/` directory listing (queue #4796 / PR #941). Orphan dirs reported in separate `orphan_directory` category (additive JSON keys; existing daemon consumers unaffected).
- Daemon stale-always-on sweep: drops auto-start backoff state for agents removed from registry (queue #4795 / PR #942). `agent delete` + `agent retire` explicitly clean state. Daemon sync pass also sweeps every tick.
- Tmux server stale layout-var cleanup: `bridge-upgrade.sh` calls `tmux setenv -u -g` on every non-dry-run upgrade (queue #4798 / PR #944). Warning gated by per-process sentinel `_BRIDGE_LAYOUT_STALE_ENV_WARNED`.
- Smoke-test BRIDGE_HOME isolation: auto-isolate to `mktemp -d` when unset + cleanup defensive sweep with fingerprint guard (queue #4793 / PR #939). Stops smoke runs from leaking ~10 empty agent dirs into live install per run.
- Backup timeout config var (refs #745 / PR #935): `BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS` env (default 300s) replaces hardcoded 120s. `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS` default bumped 180s → 360s.

### Features

- `feat(queue)`: auto-notify requester on `claimed → blocked` transition (refs #697 / PR #933). Worker silent stalls now surface in dispatcher inbox. The only feature-additive entry in this release; rest are fixes/hardening.

### Daemon resilience (continued from operator-visible section)

- Fingerprint-based dedup for inbox-nudge sweep (refs #767 / PR #932). Companion busy-aware gate still pending as a follow-up.

### Tests

- Multiple new regression smokes in `scripts/smoke/`:
  - `admin-pair-no-auto-backfill.sh` (PR #934)
  - `layout-evidence-empty-subdir.sh` (PR #936)
  - `smoke-isolation-no-live-leak.sh` (PR #939)
  - `bridge-agent-cli-no-deadlock.sh` (PR #940)
  - `watchdog-registry-anchored.sh` (PR #941, 7 cases)
  - `daemon-stale-always-on.sh` (PR #942)
  - `agent-delete-task-gc.sh` (PR #943)
  - `tmux-server-bridge-layout-cleanup.sh` (PR #944)
  - `tmux-server-bridge-layout-cleanup-driver.sh` (PR #944, standalone driver to avoid footgun #11)
  - Enhanced `daily-backup.sh` with `step_timeout_resolution` (PR #935, 5 stub cases + rc=124 detail wiring grep)

### Lint

- `scripts/lint-heredoc-ban.sh` ratchet expanded: `bridge-agent.sh` now covered with ceiling=9 (current count post-fix). `bridge-upgrade.sh` ceiling unchanged at 18. Prevents footgun #11 regression in the two highest-risk modules.

### Migration

- Operators with `BRIDGE_ADMIN_AGENT_ID=admin` (auto-set by v0.14.0): see post-upgrade advisory for retire recipe (PR #934).
- Operators with `BRIDGE_LAYOUT=legacy` in tmux server env: `agent-bridge upgrade --apply` v0.14.2 auto-cleans (PR #944).
- Operators with deleted-agent backoff log spam: `agent-bridge upgrade --apply` v0.14.2 starts the next daemon sweep tick which clears stale state (PR #942).
- Operators with orphan agent dirs in `~/.agent-bridge/agents/`: PR #941 watchdog stops alerting on them; manual `rm -rf` still needed to fully clean.

## [0.14.1] — 2026-05-16

### Highlight — completeness pass after v0.14.0 E2E (8 fixes)

Operator-cued patch release. E2E install + onboarding + comm test on a fresh Ubuntu 24.04 VM uncovered 6 regressions in the v0.14.0 clean-install / fresh-host flow, plus 2 audit-A backlog items. All ship together.

### Operator-visible

- macOS `ensure_matrix_path failed` stop-hook spam silenced on **Linux** too — the platform discriminator now checks v2 primitives readiness (`getent ab-shared`) before engaging. Hosts without `agent-bridge migrate isolation v2 --apply` no longer emit the warning on every daemon write tick.
- Fresh-install admin onboarding now auto-triggers — `bridge-start.sh` sends a single Korean nudge ~8s after the claude tmux session settles, so the agent's `SESSION-TYPE.md` first-session checklist fires without the operator typing first.
- macOS rerender failure caused by BSD `mktemp ".XXXXXX.py"` template returning the literal path → silenced. `bridge-agent.sh:1959` + `bridge-review.sh:300,402` use BSD-portable templates. Repo-wide grep-lint catches future regressions.

### Stages landed

**Discovered during E2E test (2026-05-16, agb-clean-test Ubuntu 24.04)**:

- PR #916 — clean install regressions:
  - `bridge_layout_resolver_has_existing_evidence` skips `agents/_*/` (e.g. `_template/`) reserved dirs so a fresh deploy doesn't get misclassified as `markerless(existing-install)`.
  - `deploy-live-install.sh --restart-daemon` skips daemon-restart when `state/layout-marker.sh` is absent (defer to `bridge-bootstrap.sh`).

- PR #917 — codex-absent host:
  - `bridge_ensure_admin_codex_pair` early-returns when `command -v codex` is absent. No crash-loop `<admin>-dev` on hosts without codex CLI.
  - `bridge_init_register_default_picker_sweep` skips registration when target `<admin>-dev` agent is not in roster. Operator skip message points to `bridge-bootstrap.sh` re-run for backfill.

- PR #918 — fresh-install onboarding nudge:
  - `bridge-start.sh` adds `bridge_start_should_send_onboarding_nudge` gate + `_send_onboarding_nudge_async` helper. Admin/`Onboarding State: pending` agents get an automatic nudge ~8s after spawn.

- PR #919 — completeness backlog (4 fixes):
  - **Discriminator primitives-readiness check** (highest impact): `bridge_isolation_v2_enforce` on auto policy now requires `getent ab-shared` before returning yes. Fresh installs no longer spam `ensure_matrix_path failed`.
  - `bridge-hooks.py` settings.effective.json.tmp `os.replace` retries once on `FileNotFoundError` then falls back to soft warning.
  - `bridge-start.sh` tmux new-session captures stderr; `duplicate session` race-with-daemon surfaces a clear `[info]` line.
  - Audit smoke contracts updated for the new readiness-aware gate (`scripts/smoke/isolation-v2-platform-discriminator.sh`, `isolation-v2-bucket2-gates.sh`, `tests/isolation-v2-primitives/smoke.sh`).

**Discovered during v0.13.x → v0.14.1 upgrade test (this PR)**:

- Engine-CLI preflight in daemon auto-start loop — when an agent's engine binary (`claude`, `codex`) is not on PATH, the daemon now skips the spawn attempt and records a backoff failure as `engine-cli-missing:<engine>` (`daemon_info`, not `bridge_warn`). Avoids the 10-retry burst of `[경고] always-on auto-start failed: <agent>` when the host doesn't have the engine installed.

**Backlog from audit-A (audit-2026-05-15)**:

- PR #914 — BSD-portable `mktemp` template (3 sites). Always-required regression-class smoke `bsd-mktemp-portability` ratchets the bug class.
- PR #915 — `write_agent_heartbeat` cat-failure tempfile leak (audit A17). Explicit `if ! cat ... ; then rm; return; fi` replaces the ineffective RETURN trap.

### Verification

Each PR independently verified with codex review (`implement-ok`):
- agb-clean-test (Ubuntu 24.04, Bash 5.2.21): full E2E install → bootstrap → onboarding → dynamic agent → cross-agent comm
- linux-systemd-test (Debian Bash 5.2.15): v0.8.5 → v0.14.1 single-step `agent-bridge upgrade --apply` confirms graceful leap

### Upgrade path

`agent-bridge upgrade --apply` on any v0.7.x / v0.8.x / v0.9.x / v0.10.x / v0.11.x / v0.12.x / v0.13.x install lands cleanly at v0.14.1 in one atomic step. No intermediate hop needed — the v0.13.7-v0.13.9 heredoc-chain fixes are already in main.

Hosts that hit the v0.14.0 fresh-install regressions can re-run `agent-bridge upgrade --apply` to land the v0.14.1 fixes. No special migration script required.

See `OPERATIONS.md §"Upgrade"` for the recipe + operator follow-up notes per release.

## [0.14.0] — 2026-05-16

### Highlight — v0.14.x stabilization milestone (S0-S3 + S5 Track A1/A2)

First operator-cued release after v0.13.10's hotfix wave. Batches the v0.14.x stabilization plan's foundational stages per operator's "버전 좀 크게 올리지마" directive: stabilization PRs do NOT bump VERSION/CHANGELOG individually; the next release PR is operator-cued and aggregates accumulated user-visible items.

**Operator-visible changes**:
- macOS isolation-v2 noise (`ensure_matrix_path failed` stop-hook spam) silenced via platform-discriminator gate. `BRIDGE_LAYOUT=legacy` env-leak hard-die demoted to warning when a valid v2 marker pins the install to v2.
- New `BRIDGE_ISOLATION_REQUIRED=auto|yes|no` env knob (default `auto`: Linux→enforce, else→silent no-op). Explicit override lets operators force enforcement on macOS or disable on Linux for self-test.

### Stabilization stages landed

**S0 — `docs/stabilization-plan-2026-05-15.md` (PR #901)**

Master roadmap after 4-round codex consensus. Stage S0→S10 plan with OrbStack VM matrix per stage, §"Version policy" (stabilization PRs never bump VERSION; release PRs batched), and §"Linux VM policy" (linux-systemd-test + agb-test fixtures, bash-539-test required before S10-late).

**S1 — `docs/audit-2026-05-15.md` + 5-doc catch-up (PR #902)**

254-line structured audit archive — 5 audit subagents' output cross-referenced under a universal `id | severity | file:line | owner-stage | status` schema:
- Audit A: 31 bug-surface findings (A01-A31)
- Audit B: 17 stability findings (B01-B17) + 9-row hardcoded-timeout catalog
- Audit C: 20 top-impact isolation-v2 sites (C01-C20) + 5 buried-assumption surprises (C-S1..C-S5)
- Audit D: 10 refactor categories (D01-D10)
- Audit E: 17 test/docs findings (E01-E17), E03 flipped to closed (stale-checkout false alarm), E06-E10 closed by this PR

Doc catch-up: `ARCHITECTURE.md` (+14 lib/ modules), `KNOWN_ISSUES.md` (§26 fixed-in-v0.13.x + §27 outstanding), `CLAUDE.md` (Recent critical patches section), `OPERATIONS.md` (v0.13.x hotfix wave operator follow-up), `README.md` intro.

**S1.5 — Heredoc-ban ratchet lint (PR #903)**

Count-based ratchet lint preventing NEW heredoc-stdin subprocess sites in `bridge-upgrade.sh` (footgun #11 carry-over). 18-site ceiling (current count); `BRIDGE_UPGRADE_HEREDOC_CEILING` env override; `--list` + `--self-test` modes. Broad-match contract: any non-comment line containing `(bash -s|python3 -) ... <<EOF|PY` counts. 18-positive / 5-negative inline self-test fixture. Wired into `scripts/oss-preflight.sh` (existing CI job). 3 codex rounds (BLOCKING `$()` wrapper → BLOCKING nested `$()` + SHOULD-FIX doc-string → implement-ok via broad-match path).

**S2 — Operator-visible blockers (PR #904)**

Track 2A: `bridge_isolation_v2_ensure_matrix_path` + `bridge_isolation_v2_apply_row` group_setgid path early-return on Darwin. Silences `[경고] write_agent_state_marker: ensure_matrix_path failed` stop-hook spam per Sean's mac stop-hook output.

Track 2B: `bridge_layout_resolver_validate_env` legacy|v1 branch demotes `BRIDGE_LAYOUT=legacy` env hard-die to a warning when a valid v2 marker exists on disk. Codex itself hit this surface running the consensus check via `agb inbox`.

2 new smoke tests (`isolation-v2-macos-noise-suppression.sh` + `layout-resolver-marker-over-env.sh` with 4 cases including C4 v1-marker false-positive guard).

**S3 — Platform discriminator foundation (PR #908)**

New `lib/bridge-isolation-discriminator.sh` with 3 predicates (audit C design):
- `bridge_isolation_discriminator_auto_resolve` (cached) — resolves `BRIDGE_ISOLATION_REQUIRED=auto|yes|no` (default `auto`: Linux→yes, else→no)
- `bridge_isolation_v2_enforce` — Bucket 2 enforcement gate (return 0 if v2 should enforce)
- `bridge_isolation_v2_require_linux` — Bucket 3 contract gate (die if not Linux)

S2's ad-hoc `uname == Darwin` gates rewired through the discriminator (3 sites). Discriminator standalone-safe: `_platform` helper falls through `BRIDGE_HOST_PLATFORM_OVERRIDE` → `bridge_host_platform` → direct `uname -s`. `_enforce` calls `auto_resolve` in-place (no `$()`) so the cache var persists in the parent shell across multiple calls. v2 module self-sources the discriminator when sourced standalone.

8-case smoke (`isolation-v2-platform-discriminator.sh`) covering all 3 predicates + cache contract + standalone source.

**S5 Track A1 — Bucket 2 gates for v2 module remaining primitives (PR #910)**

audit C08 (`bridge_isolation_v2_chgrp_setgid_recursive` in `lib/bridge-isolation-v2.sh`) + audit C13 (`bridge_isolation_v2_migrate_normalize_layout` in `lib/bridge-isolation-v2-migrate.sh`) gated via `bridge_isolation_v2_enforce`. 6 new smoke cases (G1-G6, missing-group assertion shape to prove gate engagement vs. silent short-circuit).

**S5 Track A2 — Bucket 2 gate for v2-reapply strip_layout_acls (PR #911)**

audit C-S2 — `bridge_isolation_v2_reapply_strip_layout_acls` gated to pre-empt the tool-presence (`command -v setfacl`) check on non-Linux hosts. Prevents Homebrew-installed Linux setfacl on Darwin from false-passing the check and reaching BSD-incompatible setfacl semantics. Records distinct `skipped:platform-discriminator` action row. 4 new smoke cases (G7-G10 including standalone-source regression guard).

### Verification

Each PR verified on:
- macOS (host dev environment)
- OrbStack VM `linux-systemd-test` (Debian Bash 5.2.15)

Smoke regression matrix:
- S1.5 heredoc-ban: count=18 ceiling unchanged
- S2 noise-suppression: T1/T2 PASS
- S2 layout-resolver: C1-C4 PASS
- S3 discriminator: D1-D8 PASS
- S5 bucket2-gates: G1-G10 PASS

### Stages NOT in this release (deferred per plan)

- **S4 → S5.5** (Bash 3.2 re-exec removal): operator-visible behavior change; requires S5 platform-discriminator to be stable on main + docs require Bash 4+ at install time + codex compatibility checkpoint.
- **S5 Tracks B/C/D**: scope investigation showed daemon/channels/state/agent files have very few clear discriminator-gate sites beyond what's covered by transitive gating through Track A. Plan's 140-site estimate was speculative; actual high-value Bucket 2 gating is captured in A1/A2.
- **S6 (Bucket 3 contract errors + Bucket 4 splits)**: next operator-cued cycle.
- **S7-S10**: long-tail cleanup waves.

### Operator follow-up

After upgrading, the `BRIDGE_LAYOUT=legacy` warning + new env knob behavior are operator-visible. Sean's mac runtime had stop-hook noise pre-upgrade; the discriminator gate + S2 fixes silence it. If you still see `ensure_matrix_path failed` after `agent-bridge upgrade --apply`, file an issue with the host-profile context.

## [0.13.10] — 2026-05-15

### Highlight — v2 isolation bundle (3-track wave): unblock v0.7.x → v0.13.x leap end-to-end + close #686 / #895

v0.13.7/v0.13.8/v0.13.9 fixed the Bash 5.3.9 heredoc deadlock CHAIN (3 surface variants). After v0.13.9 unblocked the leap's hang, the next gate was the v2-isolation layer: markerless-existing-install reject + shared-mode agent resolver semantics + scaffold/workdir mismatch coverage. v0.13.10 ships three tracks bundled in one release:

**Track A — markerless-existing-install marker-only migrate (PR #897, closes blocker on patch host)**

`bridge_isolation_v2_migrate_apply_for_upgrade` gained a marker-only fast-path that fires under `BRIDGE_UPGRADE_CONTEXT=1` + `bridge_isolation_v2_roster_has_isolated_agents` rc=1 (confirmed no isolated agents). Writes a wire-compatible v2 marker (mode 0640, `BRIDGE_LAYOUT=v2` + `BRIDGE_DATA_ROOT=...`) without group operations. Works on any host (macOS, Linux, BSD) without sudo. New `BRIDGE_UPGRADE_CONTEXT=1` env propagation through `bridge_upgrade_with_target_env`'s `env -i` allowlist. New regression smoke `scripts/smoke/isolation-v2-marker-only-migrate.sh` with 6 cases including T6 post-marker boot assertion (validates shared-mode agents still resolve to legacy explicit workdir + reach CLAUDE.md via `env -i` fresh subprocess).

Operator-host context: this fixes patch task #4526/#4538 (Linux retry blocked at preflight) + Sean's mac install 2026-05-15 17:01 broken state (apply-live partially ran during isolation-v2 dseditgroup sudo failure, recovered via backup rollback).

**Track B — close #686 with regression smoke for v2 home/+workdir/ scaffold (PR #898)**

Issue #686 (v0.8.5 cycle, 2026-05-07) reported `bridge_scaffold_agent_home` materializing `home/` but `bridge_agent_workdir` resolving to `workdir/`. Verified functionally fixed at current main (v0.13.9): `_scaffold_v2_workdir` materialized in both isolated (sudo-handoff at `bridge-agent.sh:536-542`) and non-isolated (plain mkdir at `bridge-agent.sh:547-550`) branches. New regression smoke `scripts/smoke/v2-scaffold-home-and-workdir.sh` pins the fix with T1 (non-isolated) and T2 (Linux-only isolated/sudo-handoff). T2 uses `bridge_linux_sudo_root mkdir/chown/chmod` semantics matching PR #677/#688's fresh-install pre-state.

Closes #686.

**Track C — fix #895 `bridge_agent_workdir` honors explicit cwd for shared mode under v2 (PR #899)**

Issue #895 (2026-05-15, @ymprince WSL2 OSS user, Linux 6.6.87.2-microsoft-standard-WSL2). `bridge_agent_workdir` unconditionally returned `$BRIDGE_AGENT_ROOT_V2/<agent>/workdir` whenever `BRIDGE_AGENT_ROOT_V2` was set, regardless of isolation mode. The v2-anchor override existed for the `linux-user` privacy invariant (per-agent group, mode 2750) but was firing for `shared` mode agents too, silently re-rooting `agb --claude --name <agent>` dynamic ad-hoc spawns into an empty `.claude/`+`.omc/` stub. The whole "open project, run `agb --claude --name worker`" UX was broken for fresh projects without a matching static role (`--prefer new` gated on `STATIC_CANDIDATES > 0`).

Fix: gate the v2-anchor override on `bridge_agent_isolation_mode`. `linux-user` keeps current behavior (anchor wins, privacy invariant enforced); `shared` (and any other mode, including default-fallback) falls through to existing explicit-then-default resolution. New regression smoke `scripts/smoke/dynamic-agent-shared-mode-workdir.sh` with 3 cases (shared explicit cwd / linux-user anchor / no isolation_mode default-fallback).

Closes #895.

### Wave-orchestration patterns realized

- **Bundle dependency ordering**: Track A's marker-only fast-path was r1-BLOCKING by codex until Track C's resolver fix landed (marker activation without resolver branching would have silently broken shared-mode legacy paths). Resolved by merging C first → rebasing A → adding T6 post-marker regression assertion → merging A → rebasing B.
- **Latent test bug surfaced by changed-files coverage**: Track A's `lib/bridge-isolation*.sh` edit was the first PR since #882 to pull `isolation-v2-migrate-macos-skip.sh` into ci-select required, exposing a latent T5 expectation bug (helper returns rc=2 when `BRIDGE_AGENT_IDS` undeclared but smoke expected rc=1). T5 expectation corrected.
- **`set -u` + undeclared assoc array footgun**: Track B's T2 smoke driver was post-#895 broken (Linux-only) because the driver declared `BRIDGE_AGENT_WORKDIR` but not `BRIDGE_AGENT_OS_USER` or `BRIDGE_AGENT_ISOLATION_MODE`. `bridge_agent_isolation_mode` reads `${BRIDGE_AGENT_OS_USER[$agent]-}` under `set -u`, which errors on undeclared arrays (bash treats the key as a separate variable lookup). The `2>/dev/null` in `bridge_agent_workdir` swallowed the error silently and the resolver fell through. Production never trips this because `bridge_load_roster` declares both arrays before any resolver call; the fix makes the test driver match the production invariant.
- **ci-select required-static registration is necessary, not optional**: each new smoke must be registered in `scripts/ci-select-smoke.sh::add_all_required_static` for the changed-files-aware required selector to actually execute it in PR CI. All three tracks landed initial-r1 commits that forgot this registration; codex caught it each time.

### Operator-host follow-up

For installs blocked at the v0.7.x → v0.13.x leap by the markerless-existing-install reject:

1. Confirm install unchanged: `cat ~/.agent-bridge/VERSION` should show the pre-upgrade version.
2. Re-pull source: `cd <source-checkout> && git fetch origin && git checkout v0.13.10`.
3. Re-run upgrader: `./agent-bridge upgrade --apply`.

The marker-only fast-path fires automatically when the install has no isolated agents in its roster, which is the canonical v0.7.x → v0.13.x upgrade shape. Operators who later add isolated agents via `agent-bridge agent add --isolated` will handle group setup at that opt-in moment (separate from upgrade).

If the upgrader still aborts on a host with isolated agents already in the roster, file a follow-up referencing this changelog entry — the marker-only fast-path is intentionally scoped to the no-isolated-roster case and the group-setup path is deferred to a v0.14.x cleanup.

## [0.13.9] — 2026-05-15

### Highlight — hotfix: heredoc-stdin **producer-side** wedge (3rd variant, v0.7.x → v0.13.x leap still blocked on v0.13.8)

Third release cycle of the same Bash 5.3.9 deadlock bug class. Operator-host (patch, Linux ec2-user, task #4538) retry on v0.13.8 STILL HANGS. The v0.13.7/v0.13.8 fixes closed the consumer-side variants (`<<<` here-string and parent-`$()`-over-heredoc-stdin); v0.13.9 closes the **producer-side** variant.

Sample evidence on patch host: main bash thread parked in `heredoc_write -> write(libsystem_kernel)` at `bridge-upgrade.sh:871` — the inner `bridge_upgrade_with_target_env $BASH -s -- … <<'EOF' … EOF` pattern inside `bridge_upgrade_channel_guard_report`. The parent bash writes the heredoc body to the child's pipe stdin and blocks because the child (slow start: `source bridge-lib.sh` + `bridge_load_roster`) hasn't drained the pipe yet.

The only robust fix is to **remove the heredoc-stdin path entirely** for every leap-path body. v0.13.9 moves each leap-path body to a standalone file under `lib/upgrade-helpers/` and invokes it via `bash $file args` / `python3 $file args` (file-as-argv, no heredoc anywhere).

### Fixed

- **bridge-upgrade.sh heredoc-stdin producer-side wedge (PR #894)**. Six call-sites + six new helper files:

    | bridge-upgrade.sh function/inline site | New helper file |
    |---|---|
    | `bridge_upgrade_channel_guard_report` body (bash `<<'EOF'`) | `lib/upgrade-helpers/channel-guard-report.sh` |
    | `bridge_upgrade_channel_guard_json` body (python `<<'PY'`) | `lib/upgrade-helpers/channel-guard-json.py` |
    | `bridge_upgrade_agent_restart_json` body (python `<<'PY'`) | `lib/upgrade-helpers/agent-restart-json.py` |
    | Inline `RECORDED_SOURCE_ROOT` (python `<<'PY'`) | `lib/upgrade-helpers/recorded-source-root.py` |
    | Inline `ISOLATION_V2_MIGRATION_JSON` (bash `<<'EOF'`) | `lib/upgrade-helpers/isolation-v2-migrate.sh` |
    | `bridge_upgrade_emit_failure_json` body (python `<<'PY'`, codex r1 BLOCKING catch) | `lib/upgrade-helpers/emit-failure-json.py` |

  The `bridge_upgrade_capture_to_var` helper from v0.13.8 stays in place. It's no longer load-bearing (inner heredoc is gone), but it's still used at the migrated callsites for defensive style and consistency with what shipped in v0.13.8.

  Codex review chain: r1 caught `emit_failure_json` (EXIT-trap path) as BLOCKING — fixed. r2 caught helper body byte-formatting drift — fixed. r3 flagged 18 additional non-leap-path python heredoc sites as BLOCKING. r4 verified the orchestrator's CLAUDE.md 3-round-cap triage: those 18 sites are all alternate-subcommand (--check/--analyze/--rollback) or post-apply (after apply-live succeeds), so they are deferred to v0.13.10 as a defensive cleanup pass.

### Operator-host follow-up

If your v0.13.8 upgrade is still blocked:

1. Confirm install unchanged: `cat ~/.agent-bridge/VERSION` should still show the pre-upgrade version. apply-live did not run.
2. Re-pull source: `cd <source-checkout> && git fetch origin && git checkout v0.13.9`.
3. Re-run upgrader: `./agent-bridge upgrade --apply`.
4. If the apply succeeds but the script HANGS post-apply (script doesn't exit, VERSION has already advanced), it's a v0.13.10 carry-over python heredoc. `pkill -f bridge-upgrade.sh` is safe (install is upgraded). File a follow-up referencing task #4538.

### Carry-over to v0.13.10

- Migrate 18 remaining python heredoc-stdin sites at bridge-upgrade.sh lines 662, 761, 784, 1130, 1243, 1252, 1297, 1308, 1534, 1581, 1798, 2144, 2260, 2266, 2278, 2287, 2313, 2345 to standalone `lib/upgrade-helpers/*.py` files following the v0.13.9 pattern.
- Add a `<<EOF` / `<<'PY'` ban lint rule for `bridge-upgrade.sh` to prevent regression of the bug class.

## [0.13.8] — 2026-05-15

### Highlight — hotfix: heredoc-stdin `$()` capture deadlocks (v0.7.x → v0.13.x leap still blocked on v0.13.7)

Operator-host retry on v0.13.7 (Linux ec2-user, Bash 5.3.9, patch task #4526 / #4532) still wedged. The `<<<` here-string sites PR #890 fixed were the right class but the wrong instances — the wedge moved one variant over to parent `$()` command substitution capturing a child whose stdin is fed by a **heredoc** (`bash -s -- … <<'EOF' …` or `python3 - … <<'PY' …`). Same Bash 5.3.9 `read_comsub` bug, different surface.

Confirmed wedge at `bridge-upgrade.sh:1383` (`CHANNEL_GUARD_REPORT="$(bridge_upgrade_channel_guard_report …)"` — function body at line 831 invokes `bridge_upgrade_with_target_env … bash -s -- … <<'EOF' … EOF`). Defensive migrations follow for every other heredoc-stdin site the apply path would have hit next plus the rollback path.

### Fixed

- **bridge-upgrade.sh heredoc-stdin `$()` capture deadlocks (PR #892)**. Adds a `bridge_upgrade_capture_to_var <var> <cmd …>` helper that stages `<cmd>`'s stdout to a tempfile (`mktemp` — single-line stdout, empirically safe under Bash 5.3.9) and reads it back via the `$(< file)` bash builtin form (no subshell fork → cannot wedge `read_comsub`). Six `$()` capture sites for four heredoc-stdin helpers are migrated:

    - `CHANNEL_GUARD_REPORT` (line 1420) — primary wedge from task #4532
    - `CHANNEL_GUARD_JSON` (line 1422) — defensive, same shape, next on path
    - `ROLLBACK_AGENT_RESTART_JSON` × 2 (lines 1454, 1477) — rollback path
    - `AGENT_RESTART_JSON` × 2 (lines 1703, 2286) — apply path, both placeholder and real-report variants

  Plus two inline `$( cmd … <<EOF … EOF )` sites that don't go through a helper function:

    - `RECORDED_SOURCE_ROOT` (line 1175) — `python3 - … <<'PY'` capture, single-tree install branch (`SOURCE_ROOT == TARGET_ROOT`). Migrated defensively.
    - `ISOLATION_V2_MIGRATION_JSON` (line ~1595) — `bash -s -- … <<'EOF'` capture on the **apply path**, surfaced by codex r1 review as BLOCKING. Existing `set +e ; … ; rc=$? ; set -e` failure-handling frame preserved intact.

  The helper itself uses `"$@" >tmp || _rc=$?` rather than `if ! "$@" >tmp; then …` because the latter would reset `$?` to 0 inside the then-branch (the inverted pipeline status), masking real failures from the caller under `set -e`. The chosen idiom disarms `set -e` for the wrapped call AND preserves the original rc. Verified by a 5-case functional smoke (heredoc bash-s, heredoc python3, 5000-row output, failure rc=5 round-trip, empty output, no `/tmp/agb-upg-capture.*` residue).

  Functions intentionally left unchanged because they are not on the wedge surface:

    - `bridge_upgrade_collect_agent_restart_report` / `bridge_upgrade_reconcile_agent_restart_recovery`: use `bash -lc 'script'` (script passed as argv, stdin inherited — not heredoc-fed).
    - `bridge_upgrade_propagate_claude_shared_settings`: delegates to `bridge-agent.sh rerender-settings` — no inline heredoc.
    - `bridge_upgrade_installed_field`: heredoc python, but only called during `--check-only` (off the leap path) and produces single-field tiny output.

  Verification: `bash -n` + `shellcheck` clean across the whole `*.sh` / `agent-bridge` / `agb` / `lib/*.sh` / `scripts/*.sh` set. Codex r1 surfaced one BLOCKING missed site (ISOLATION_V2_MIGRATION_JSON) → fixed → codex r2 implement-ok.

### Operator-host follow-up

If your v0.13.7 upgrade is still blocked by this deadlock:

1. Confirm install is unaffected: `cat ~/.agent-bridge/VERSION` should still show the pre-upgrade version. `apply-live` did not run.
2. Re-pull source: `cd <source-checkout> && git fetch origin && git checkout v0.13.8`.
3. Re-run upgrader: `./agent-bridge upgrade --apply`.

If a leap retry on v0.13.8 still hangs, capture the trace (`BASH_XTRACEFD` to a file) and file an upstream issue — there may be a third variant of this bug class still hiding in the script.

## [0.13.7] — 2026-05-15

### Highlight — hotfix: bridge-upgrade.sh here-string deadlocks blocking v0.7.x → v0.13.x leap

Operator-host (Linux ec2-user, task #4526) reported `agent-bridge upgrade --apply` silently hanging on every retry (6 attempts) of a v0.7.6 → v0.13.6 leap path. Bash stuck in `read_comsub` — waiting for a pipe `<<<` here-string never closed. footgun #11 / #265 / #800 / #815 class on Bash 5.3.9.

Wedge point at `bridge-upgrade.sh:251` (the `python3 -c '<script>' <<<"$tags"` invocation inside `bridge_upgrade_latest_stable_tag`), plus three sites at lines 537, 566, 615 inside the agent-restart recovery `-lc` body.

### Fixed

- **bridge-upgrade.sh here-string deadlocks (PR #890)**. Four `<<<` here-string sites replaced with safe forms — pipe (`git tag … | python3 -c …`) for the tag enumeration, and `printf '%s\n' "$var" > tempfile; … < tempfile` (with `trap … EXIT` cleanup) for the report consumers. Trailing newline preserved via `printf '%s\n'` because command substitution strips the `\n` that `<<<` would have added; without the explicit `\n` the last row of the report would be dropped. Inner `bash -lc` body's new tempfile is scoped to the subshell and does not conflict with the outer `_bridge_upgrade_exit_handler` trap.

  Verification: `bash -n` + `shellcheck` clean; isolated `bridge_upgrade_latest_stable_tag` smoke (3-tag fixture, 10s timeout) returns `v0.13.6` instantly with no hang. Codex r1 implement-ok across the 8-item checklist. Single file (+23/-7 LOC).

### Operator-host follow-up

If your v0.13.6 upgrade is blocked by this deadlock:

1. Confirm install is unaffected: `cat ~/.agent-bridge/VERSION` should still show the pre-upgrade version. `apply-live` did not run.
2. Re-pull source: `cd <source-checkout> && git fetch origin && git checkout v0.13.7`.
3. Re-run upgrader: `./agent-bridge upgrade --apply`.

## [0.13.6] — 2026-05-15

### Highlight — operator-host audit wave (8 PRs, single session)

8 PRs landed on top of v0.13.5 in a single session driven by patch-host diagnostics on a Linux production install. Three high-priority operational regressions plus four targeted improvements plus one emergency hotfix:

- **ADMIN-PROTOCOL.md propagation** (#880) — was referenced but never installed.
- **admin agent hook exemption** (#881) — admin diagnostic reads were being silently blocked.
- **macOS upgrade path unblocked** (#882) — isolation-v2 migration was demanding sudo on hosts where the v2 layout has no operational effect.
- **daemon periodic Claude token sync** (#883) — token sync only fired on rotation events; cron-only agents went stale and hit 429 (mgt_ahn on 2026-05-15 03:49 KST).
- **cron PATH for node-manager binaries** (#885) — fnm/nvm/asdf/volta stable alias paths now augmented automatically.
- **cleanup payload renderer** (#886) — empty stdin no longer leaks raw `json.JSONDecodeError`, and the heredoc-stdin pattern that swallowed the caller's piped JSON is gone.
- **bridge-notify default discord** (#887) — agents without a discord channel no longer emit `discord account not found: default` noise.
- **ci-select conflict marker hotfix** (#888) — emergency: PR #887's squash-merge left raw git conflict markers in `scripts/ci-select-smoke.sh`, breaking every subsequent CI invocation. Hotfix removed the markers and collapsed the merged dispatch row.

PR #884 (isolated UID credential sync via sudo helper) was opened, then closed without merging after on-host diagnosis confirmed the original gap was a false reading — sales_sean's credential file lives at the isolated UID's real home (`/home/agent-bridge-sales_sean/.claude/.credentials.json`), not the controller-side mirror; PR #883's periodic sync covers the actual stale-token symptom this PR had been chasing.

### Fixed

- **ADMIN-PROTOCOL.md wire-up (PR #880, refs operator report 2026-05-15)**. `bridge-docs.py:23` `AGENT_SHARED_LINKS` tuple was missing `ADMIN-PROTOCOL.md`, so admin agent homes never received the symlink even though the managed CLAUDE.md block referenced it. Added the tuple entry plus a `render_shared_admin_protocol_md` renderer that reads `docs/agent-runtime/admin-protocol.md` as the SSOT, prepends a managed-by header, and emits the body verbatim. Wired symlink loop at `bridge-docs.py:1333` then auto-creates `ADMIN-PROTOCOL.md -> ../shared/ADMIN-PROTOCOL.md` in every agent home. New smoke `scripts/smoke/admin-protocol-shared-link.sh` (9 cases) pins the propagation contract.

- **Admin agent hook exemption pass (PR #881)**. Hooks were treating admin agents (the operator's own delegated principal) the same as any peer, so diagnostic reads like `ls ~/.claude/.credentials.json` were silently blocked with `Claude OAuth credentials are blocked inside tool calls`. Added read-intent exemption for admin agents:
  - `hooks/tool-policy.py`: Bash credential surface (raw text, env-dump, argv path) and Read/Glob/Grep/NotebookRead credential-path checks now allow admin + read-intent and audit via `agent_admin_credential_read_allowed`. `_is_read_intent_bash` extended to catch numeric-fd write redirections (`1>file`, `99>>file`) so a compromised admin cannot exfiltrate by piping a read through an output redirect.
  - `hooks/prompt-guard.py`: low / medium severity prompt-guard hits become `prompt_guard_admin_warn_only` audit rows for admin agents (high / critical still hard-block — compromised admin defense).
  - Roster / system-config / task DB mutation deny paths remain in force for admin too (wrapper-required, per the existing #341 contract).
  - New smoke `scripts/smoke/admin-hook-exemption.sh` (11 cases) pins read vs write classification, audit shape, and the high-severity hard-block.

- **isolation-v2 migration macOS no-op (PR #882, refs operator report 2026-05-15 via task #4522)**. `bridge_isolation_v2_migrate_apply_for_upgrade` was platform-agnostic — markerless installs unconditionally tried to apply the v2 layout, and `bridge_isolation_v2_privilege_preflight` then demanded root / passwordless sudo. macOS shared-agent installs have no isolated UIDs and the v2 layout (group + setgid + named-user) has no operational effect there, but the operator was still being prompted for sudo and the upgrade aborted on refusal. Fix:
  - New helper `bridge_isolation_v2_roster_has_isolated_agents` (`lib/bridge-isolation-v2.sh:1083`) returns 0 (has isolated), 1 (confirmed no isolated), or 2 (unknown — predicate or `BRIDGE_AGENT_IDS` unavailable). The rc=1 vs rc=2 split (codex r1 catch) lets the caller skip ONLY when explicitly confirmed safe.
  - `bridge_isolation_v2_migrate_apply_for_upgrade` gates the skip on `uname -s != Linux && rc == 1`. Unknown roster state falls through to the existing preflight so the operator sees the real cause instead of a silent skip.
  - New smoke `scripts/smoke/isolation-v2-migrate-macos-skip.sh` (5 cases) pins both branches (Darwin+confirmed-shared skip; Darwin+isolated, Linux+isolated, predicate-missing all fall through).

- **Daemon periodic Claude token sync (PR #883, refs operator report 2026-05-15)**. Three static Claude agents on a production Linux host went 62 hours without a token refresh — patch refreshed via its live Claude session, but dev_mun / sales_choi / mgt_ahn were cron-only and never had a live session to self-refresh. The daemon's sync branch only fires on `sync_recommended=1` from token-recovery, which never triggers for cron-only agents. mgt_ahn hit a 429 on 2026-05-15 03:49 KST. Fix:
  - New `bridge_daemon_periodic_token_sync_due` + `_tick` in `bridge-daemon.sh`'s main poll loop. Every `BRIDGE_CLAUDE_TOKEN_SYNC_INTERVAL_SECONDS` (default 3600, set to `0` to disable) the tick calls `bridge-auth.sh claude-token sync --agents <scope>` and writes a `claude_token_periodic_sync` audit row regardless of any rotation / recovery event.
  - Hot-loop guard: state file timestamp is refreshed on both success and failure (so a persistently-failing sync emits one `status=failed` audit row per interval, not every tick).
  - `BRIDGE_CLAUDE_TOKEN_PERIODIC_SYNC_ENABLED=0` kill switch; `BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS` (default `static`) selects the scope.
  - New smoke `scripts/smoke/daemon-periodic-token-sync.sh` (5 cases) pins first-call due / not-due skip / overdue refire / failure-without-hot-loop / interval=0 disable. Fixture files split off the original heredoc bodies to satisfy footgun #11.

- **cron PATH augmentation for node-manager binaries + interpreters (PR #885, closes #874)**. fnm / nvm / asdf / volta-managed `codex` / `claude` binaries were invisible to cron because the runner's `COMMON_BIN_DIRS` only listed plain stable paths. Operators had to manually `npm install -g` and symlink `node` on every fresh host. Fix:
  - `bridge-cron-runner.py:COMMON_BIN_DIRS` now includes `~/.local/share/fnm/aliases/default/bin`, `~/.nvm/versions/node/default/bin`, `~/.asdf/shims`, `~/.volta/bin` (stable alias paths only — per-version paths are intentionally excluded because `fnm use <other>` breaks them).
  - `BRIDGE_CRON_EXTRA_PATH` env override for operator-specific augmentation. Iteration order ensures extras win over built-in fallbacks at PATH position 0 (codex r1 catch on the `insert(0, …)` semantics).
  - New smoke `scripts/smoke/cron-path-augmentation-874.sh` pins the registration contract.

- **cleanup payload renderer empty-stdin handling (PR #886, closes #872)**. `lib/bridge-cleanup.sh` rendered the "Backup residue cleanup" section of the `[upgrade-complete]` task body by piping JSON into a `python3 - <<'PY' ... PY` heredoc-stdin invocation. The heredoc body itself became `python3`'s stdin, so the caller's piped `CLEANUP_JSON` never reached the renderer; an empty payload leaked raw `json.JSONDecodeError: Expecting value: line 1 column 1 (char 0)` into every operator's task body. Fix:
  - Extracted the renderer body to `scripts/python-helpers/cleanup-payload-renderer.py` and invoked it as `python3 <fixture-path>` (post-#800 footgun #11 mitigation pattern). The caller's piped JSON now reaches the renderer as designed.
  - Renderer handles `empty stdin → friendly no-actions message`, `invalid JSON → operator-readable parse error (no traceback leak)`, `valid JSON → structured summary`.
  - New smoke `scripts/smoke/cleanup-payload-empty-stdin-872.sh` (3 cases).

- **bridge-notify default-discord silent-skip (PR #887, closes #875)**. `bridge-notify` was emitting `discord account not found: default` into `[cron-followup]` task bodies for codex agents that had no discord channel configured. Now `bridge_notify_send --account default` with a missing default account silently skips with a `bridge_notify_skipped` (reason=no_default_account) audit row, exiting 0. `--account <named>` with a missing named account remains a hard failure (intentional configuration error).

- **ci-select conflict-marker emergency hotfix (PR #888)**. PR #887's squash-merge inherited an unresolved `scripts/ci-select-smoke.sh` conflict against PR #883's `daemon-periodic-token-sync` dispatch row, and the merge committed the file with raw `<<<<<<<` / `=======` / `>>>>>>>` markers intact. This was a hard bash syntax error that broke every subsequent CI invocation. Hotfix removed the markers and collapsed the merged dispatch row into a single line including all PR #880/#881/#882/#883/#885/#887 dispatch tokens. **Operator-side mitigation if a v0.13.6 release artifact was already pulled between `791b75b` and `ee36c5b`**: re-pull main; `bash -n scripts/ci-select-smoke.sh` should report no errors. The release tag below is cut from `ee36c5b` or later, so consumers of the tag are not affected.

### Closed (issue tracker)

- #872 — cleanup payload empty-stdin renders raw `json.JSONDecodeError`
- #874 — bridge-cron-runner PATH augmentation for fnm/nvm/asdf
- #875 — bridge-notify spurious `discord account not found: default`

### Operator-host follow-up procedure for v0.13.6

After upgrading a linux-user-isolated install to v0.13.6:

1. `agent-bridge upgrade --apply` (or the operator's preferred path).
2. Monitor `~/.agent-bridge/logs/daemon.log` for `claude_token_periodic_sync` audit rows over the next 1-2 hours. Expected cadence: every `BRIDGE_CLAUDE_TOKEN_SYNC_INTERVAL_SECONDS` (default 3600).
3. Verify cron-only agents now have fresh credential mtimes:
   ```
   for a in <cron-only-agents>; do
     sudo -u "agent-bridge-$a" stat -c '%Y' ~agent-bridge-$a/.claude/.credentials.json 2>/dev/null
   done
   ```
   Each should be within the last interval.
4. For macOS shared-agent installs: no operational action required — the v2 isolation migration silently skipped (audit JSON shows `"skipped":true, "reason":"macos-shared-agent"`).

### Carry-over

- **PR-5 stop-gap retirement (#857)** — pending one cycle of v3 migrate validation in Linux production. Track for v0.14.0.
- **#859 (plugin install isolated-UID)** — separate design pass.
- **#879 (dev-channels watcher race)** — multi-isolated-agent restart race condition. Surface is large; deferred to next cycle for root-cause investigation.
- **OpenAI strict-mode schema audit on other JSON schemas** — bridge-cron-runner's `RESULT_SCHEMA` was caught in v0.13.5; other schemas should be similarly audited to prevent the next strict-mode tightening from breaking them.

## [0.13.5] — 2026-05-15

### Highlight — hotfix: bridge-cron-runner RESULT_SCHEMA violates OpenAI Structured Outputs strict mode

Live cron failure on the operator's Linux server surfaced an upstream API behavior shift: OpenAI Responses API's Structured Outputs strict mode now rejects schemas where the `required` array does not include every key in `properties` at every nested object level. The previous `RESULT_SCHEMA` in `bridge-cron-runner.py` violated this in two places, breaking every codex-driven cron with `payload_kind=text` (picker-sweep being the canary). Hotfix release.

Operator-observed error verbatim:
```
'required' is required to be supplied and to be an array including every key in properties. Missing 'urgency'.
```

### Fixed

- **bridge-cron-runner RESULT_SCHEMA strict-mode compliance (PR #877)**. Top-level `required` listed 9 of 12 properties (missed `forward_target`, `summary_short`, `channel_relay`). `channel_relay.required` listed 1 of 5 properties (only `body`; missed `urgency`, `transport`, `target`, `subject`). Fix uses the `anyOf [{actual_type}, {"type": "null"}]` pattern for conditional top-level fields so codex emits `null` when the field is not applicable. Strict mode is now satisfied:
  - All 12 top-level properties listed in top-level `required`.
  - All 5 `channel_relay.properties` keys listed in `channel_relay.required` (codex emits either the full object or `null`).
  - `forward_target.required` was already correct (had all 3 of 3).

  The runtime validator (`validate_result` + `normalize_forward_target` + `normalize_channel_relay`) is null-safe — `result.get(key)` returns `None` for null values, normalizers return `None` on `None` input, and existing intent-conditional branches preserve the same semantics. **No validator code changes.**

  Prompt text at `bridge-cron-runner.py:1415-1423` updated to explicitly instruct codex to emit `null` for conditional fields when not applicable (the schema enforces this through Structured Outputs, but explicit prompt instruction reduces model confusion).

  New regression smoke `scripts/smoke/cron-runner-schema-openai-strict.sh` walks `RESULT_SCHEMA` and asserts the invariant: every `properties` block has a `required` array containing all its keys. `scripts/ci-select-smoke.sh` wires the smoke as required when `bridge-cron-runner.py` changes.

  Codex pair-review r1 → `implement-ok` (no findings). CI all green. PR #877 merged at `40f08f9`.

### Operator-host run procedure for v0.13.5

After upgrading a Linux install (the failure surface) to v0.13.5:

```
agent-bridge upgrade --apply
agent-bridge cron enable picker-sweep-<id>  # re-activate any cron disabled during diagnosis
# Watch next cron cycle:
tail -f ~/.agent-bridge/logs/cron-runner.log
```

The cron should successfully complete codex round-trips. If the failure recurs, capture the codex CLI stderr — the upstream API may have shifted further and additional schema updates would be needed.

### Why this is a release-grade hotfix

- Production cron blocked since the upstream API change. Every 10-minute cycle was a failure spam.
- The fix is contained: schema + prompt only; validator and downstream code unchanged.
- Smoke regression prevents re-introduction.

### Unaffected installs

- **macOS shared-agent installs**: not directly affected (cron-runner uses the same code path on all OSes, but the failure mode only surfaces when codex CLI is actually invoked against a live OpenAI Responses API in strict mode — local mocks / dry-runs would not have triggered it). If macOS install runs codex-driven crons, this hotfix still applies.
- **agent-bridge installs that don't use codex engine for cron**: not affected at all (the schema is only used when dispatching via codex).

## [0.13.4] — 2026-05-15

### Highlight — #857 PR-6: operator-facing channel dotenv migration tool

Adds `agent-bridge migrate isolation v3` — the in-place migration helper that converges every existing linux-user-isolated agent's channel state files (`.env`, `access.json`, `state.json`, `mcp.json` per provider) toward the v0.13.4 canonical contract: owner=isolated-UID, group=ab-agent-<slug>, mode=0600, no extended ACL. The new write path landed in v0.13.3 (PR-2); PR-6 migrates the existing files that were created under the legacy controller-owned + named-user ACL grant shape.

Default mode is `--dry-run` — operators see the planned mutations before they happen. `--apply` is required for the actual migration. After one production cycle of v3 migrate validation, #857 PR-5 retires the runtime ACL stop-gap (`bridge_isolation_v2_apply_channel_state_dotenv_acl`) and the umbrella issue #857 closes.

### Added

- **`agent-bridge migrate isolation v3` tool (PR #871, refs #857 PR-6)**. New module `lib/bridge-isolation-v3-channel-dotenv.sh` (~530 LOC) + `bridge-migrate.sh` `v3)` dispatcher arm + smoke 9 cases. Modes:
  - `--check` — drift detection only
  - `--dry-run` (default — never mutates without explicit opt-in) — emits `would` rows describing the planned mutations
  - `--apply` — perform the mutations
  - `--agent <name>` — scope to one agent (default: every linux-user-isolated agent in roster)
  - `--json` — JSON output (schema matches v2 reapply for piping compatibility)

  The tool walks each agent's 5 channel state dirs (`.discord`, `.telegram`, `.teams`, `.ms365`, `.mattermost`) and asserts the canonical state per file. Reuses v2 reapply's mutation primitives (`bridge_isolation_v2_reapply_chown_chmod_file`, `bridge_isolation_v2_reapply_run_priv`, `bridge_isolation_v2_reapply_record_action`, `bridge_isolation_v2_reapply_has_named_acl`, `bridge_isolation_v2_reapply_probe_owner_group_mode`) — no duplication of the direct-then-sudo, ACL-strip-before-chmod ladder. Path guards mirror the stop-gap helper at `lib/bridge-isolation-v2.sh:2127-2160` (refuse symlinks, non-regular files; require parent-dir basename `.<provider>`; require workdir-scope under `<agent_workdir>/.<provider>/`). macOS / non-Linux hosts no-op (returns 0 silently — no stdout, no temp-file leak), mirroring v2 reapply's contract.

  Active-session safe: mutates only ownership/mode/ACL on existing channel dotenv files. Does NOT stop/start the daemon, does NOT touch the queue, does NOT chgrp recursively. Operators may run `--apply` on a live install; worst case is a transient probe miss during the chown window, which the stop-gap self-heals on the next start cycle.

  Smoke `scripts/smoke/857-pr6-isolation-v3-channel-dotenv-migrate.sh` covers 9 cases (A1-A9): no isolated agents, canonical tree, legacy ACL drift, mattermost mcp.json migration, symlink refused, non-regular file refused, `--agent` scoping (valid + unknown), `--json` output, idempotent re-run after `--apply`. Wired into `scripts/ci-select-smoke.sh` as required when `lib/bridge-isolation-v3-channel-dotenv.sh`, `bridge-migrate.sh`, or `lib/bridge-isolation-v2-reapply.sh` changes.

  CLI help at `scripts/cli-help/agent-bridge-usage.txt` documents the new verb. `bridge-lib.sh` sources the new module after `bridge-isolation-v2-reapply.sh` so callers outside `bridge-migrate.sh` can also reach the public entry.

  Codex pair-review: r1 → `implement-ok` (no findings on the v3 module / dispatcher / wire-up). Three smoke false-positives discovered by CI Linux were fixed in follow-up commits before merge (substring match on `drift=0` summary token, assertion of agent name in fixture-rooted path, `bridge_die` mock semantics) — pure smoke assertion fixes, zero behavioral change to the v3 migrator. Codex r2 sanity on the smoke fix → `implement-ok`.

### Operator-host run procedure for v0.13.4

After upgrading a linux-user-isolated install to v0.13.4:

```
agent-bridge migrate isolation v3              # default --dry-run; emits `would` rows
agent-bridge migrate isolation v3 --apply       # perform mutations after reviewing dry-run output
```

Verify post-apply:

```
for a in <isolated-agent-names>; do
  for ch in discord telegram teams ms365 mattermost; do
    f="$BRIDGE_AGENT_HOME_ROOT/$a/.$ch/.env"
    [[ -f "$f" ]] || continue
    stat -c '%U:%G %a' "$f"                                  # → agent-bridge-<slug>:<grp> 600
    getfacl "$f" 2>&1 | grep -E '^user:[^:]+:' || echo "(no named-user ACL — expected)"
  done
done
```

After successful migration, channel dotenvs match what v0.13.3's PR-2 (#868) produces for fresh `agb setup <channel>` runs. The runtime ACL stop-gap (`bridge_isolation_v2_apply_channel_state_dotenv_acl`) becomes a no-op on migrated agents — PR-5 retires it next cycle after one cycle of production validation.

### Macros for non-Linux installs

`agent-bridge migrate isolation v3` is a contract no-op on macOS / non-Linux hosts (returns 0 silently). Shared-agent installs (no linux-user isolation) don't need to run it; new setup paths produce mode-0600 files directly via PR-2's `_isolation_aware_save_*` helpers when applicable. macOS installs see no behavior change from v0.13.4.

## [0.13.3] — 2026-05-14

### Highlight — #857 PR-2 + PR-3 combined: channel setup dotenv writes via sudo-as-isolated-UID + local smoke gate unblock

Follow-up to v0.13.1 (#857 PR-1, the sudo-as-isolated-UID **write** helper). PR-2 and PR-3 of the umbrella plan #857 are combined into one PR (`bridge-setup.py` is a shared file; splitting was rejected as churn). After this release, every channel setup command (`agb setup discord|telegram|teams|mattermost`) writes its dotenv (`.env` / `access.json` / `state.json` / `mcp.json`) as the isolated UID at mode 0600 on linux-user-isolated installs, removing the controller's direct write on channel dotenvs entirely.

The runtime ACL stop-gap (`bridge_isolation_v2_apply_channel_state_dotenv_acl` from #851 / PR #855) remains in place as a safety net for one cycle while live installs validate PR-2's behavior; #857 PR-5 will retire the stop-gap in a future release.

### Added

- **Isolation-aware channel setup writes (PR #868, refs #857 PR-2 + PR-3 combined)**. `bridge-setup.py` gains four new helpers symmetric to the existing read-side `_sudo_run_as` / `_isolated_workdir_owner` family:
  - `_ISOLATED_WRITE_SCRIPT` — inline mirror of `bridge_isolation_write_file_as_agent_user_via_bash` (`lib/bridge-isolation-helpers.sh:181`). Single-quoted Python literal so `$variables` resolve inside the sudo'd bash only. Same rc band (0 = success, 2 = sudo missing, 5-9 = script-rc shifted; rc=127 added in Python on `FileNotFoundError`). No heredoc / here-string anywhere — footgun #11 (memory note `feedback_bash_heredoc_write_class_recurrence`, originating from #815 Wave D, Bash 5.3.9 heredoc_write deadlock class).
  - `_sudo_write_as(os_user, dest_path, content, mode=0o600)` — symmetric to the existing `_sudo_run_as`. Streams content via `subprocess.run(..., input=content)` (NOT heredoc). Returns `CompletedProcess`; callers inspect rc.
  - `_resolve_isolated_owner_for_path(path)` — walks up from `path` to the nearest existing ancestor and returns its isolated `agent-bridge-<slug>` owner via `_isolated_workdir_owner`. Necessary because `mkdir` running as the controller would create a controller-owned dir, hiding the isolated lineage from a single-level `path.parent` lstat (codex r1 catch on PR #868).
  - `_isolation_aware_mkdir(path)` — `mkdir -p` with isolation awareness. If the nearest existing ancestor is isolated-owned, escalates to `sudo -n -u <owner> bash -c 'set -e; umask 0077; mkdir -p "$1"; exit 0'` so missing components land at mode 0700 owned by the isolated UID. Otherwise falls back to `Path.mkdir(parents=True, exist_ok=True)`. Same `SetupError`-on-failure ergonomics as `_sudo_write_as`.
  - `_isolation_aware_save_text` / `_isolation_aware_save_json` — call the walker, then either delegate to `_sudo_write_as` (isolated lineage) or fall back to the existing `save_text` / `save_json` (controller-owned). `save_text` / `save_json` themselves are untouched and continue to serve non-channel callers (runtime config caches, claude-plugin caches, etc.).

  Ten `save_text` / `save_json` call sites across `cmd_discord` / `cmd_telegram` / `cmd_teams` / `cmd_mattermost` are rewired to the new `_isolation_aware_save_*` variants; four `<channel>_dir.mkdir(parents=True, exist_ok=True)` calls become `_isolation_aware_mkdir(<channel>_dir)`. This covers the mattermost case the umbrella plan implicitly excluded — `lib/bridge-agents.sh:3380-3438` only precreates `discord/telegram/teams/ms365` from `BRIDGE_AGENT_CHANNELS` at agent-create time and omits mattermost, so first-time `agb setup mattermost <agent>` previously had no precreated dir and would have landed on a controller-owned path even with PR-1 in place. The new `_isolation_aware_mkdir` covers this and any other channel added post-create.

  After PR-2: channel dotenv files born at mode 0600 owned by the isolated UID. Controller never opens these files for writing. Read path was already isolated via PR #836 (v0.12.0) — `bridge_channel_env_file_readiness` at `lib/bridge-agents.sh:4239-4302` delegates to `bridge_isolation_run_as_agent_user_via_bash` when the controller can't `[[ -r ]]` the file.

  Codex pair-review: r1 → `needs-more` (controller-side `mkdir` before isolated save) → r2 (walker + `_isolation_aware_mkdir`) → `implement-ok`. Cumulative diff +193 / -14 in a single file. No VERSION/CHANGELOG churn in the feature PR itself; no `setfacl` removal (that's #857 PR-5, deferred).

### Fixed

- **Local smoke gate unblock — shellcheck SC2026 on apostrophe-bearing comment (PR #869)**. `bridge-upgrade.sh:551` previously contained the literal `$'tab'` apostrophe pair inside a `bash -lc '...'` body. Shellcheck's static analyzer (SC2026 info severity) flagged the inner apostrophes as terminating the outer single-quoted string, which exited rc=1 under `set -euo pipefail` in `scripts/smoke-test.sh:210`. Pre-existing since PR #834 (v0.13.0 cycle, 2026-05-12) — broke local `./scripts/smoke-test.sh` while GitHub CI stayed green (different shellcheck invocation). Pure comment rewrite, no runtime behavior change. Restores the CLAUDE.md preflight contract (`./scripts/smoke-test.sh` required-green) for any subsequent local-validated PR.

### Operator-host verification notes for v0.13.3

After upgrading a linux-user-isolated install to v0.13.3, the next `agb setup <channel> <agent>` for a channel not declared in `BRIDGE_AGENT_CHANNELS` at agent-create time should produce:

```
stat -c '%U:%G %a' "$BRIDGE_AGENT_HOME_ROOT/<agent>/.<channel>/"          # → agent-bridge-<slug>:<group> 700
stat -c '%U:%G %a' "$BRIDGE_AGENT_HOME_ROOT/<agent>/.<channel>/.env"      # → agent-bridge-<slug>:<group> 600
getfacl "$BRIDGE_AGENT_HOME_ROOT/<agent>/.<channel>/.env"                 # owner+group+other only; NO `user:<controller>:r--`
```

The runtime ACL self-heal helper `bridge_isolation_v2_apply_channel_state_dotenv_acl` (called from `bridge-start.sh:479` and `bridge-daemon.sh:3573`) remains in place this cycle as a safety net — verify the new flow works in production for one cycle before #857 PR-5 retires the helper.

Note a slight mode divergence: dirs precreated at agent-create time by `bridge_linux_install_isolated_channel_symlink` (`lib/bridge-agents.sh:3570`) get mode `2770` (group r-w-x + setgid). Dirs created lazily by `_isolation_aware_mkdir` at setup time get mode `0700` (stricter, no group, no setgid). The 0700 case still works correctly because the subsequent save delegates ownership probing to the directory itself; the divergence is cosmetic and aligning it (either tightening precreate to 0700 or loosening the lazy path to 2770) is a future polish, not a correctness issue.

## [0.13.2] — 2026-05-14

### Highlight — v0.11.0 → v0.13.0 upgrade migration perm regressions fixed

Hotfix release closing **#864** — three permission-class regressions discovered by the operator during v0.11.0 → v0.13.0 live install verification. Each blocked `agent start` for isolated agents and required a manual `chown`/`chmod` workaround to unstick. Without this hotfix, every fresh upgrade host has every isolated agent silently failing to start under the auto-restart backoff loop.

### Fixed

- **v0.13.0 upgrade migration permission regressions — R1+R2+R3 bundled (PR #866, closes #864)**.
  - **R1 — `state/layout-marker.sh` ownership**: post-upgrade the marker retained `ec2-user:ab-controller mode 0640`. `bridge_isolation_v2_marker_validate` (`lib/bridge-marker-bootstrap.sh:64-75`) rejects markers whose owner UID is neither root nor the current controller UID — so under `sudo -u agent-bridge-<name>` the marker is rejected, layout falls back to `markerless(existing-install)`, `bridge_die`. Fix: `bridge_isolation_v2_migrate_marker_write` (`lib/bridge-isolation-v2-migrate.sh:1343-1367`) now chowns the marker to `root:${BRIDGE_SHARED_GROUP:-ab-shared}` via the existing `_bridge_isolation_v2_run_root_or_sudo` direct-first/sudo-fallback helper after the atomic tmp+chmod+mv-f write. Root ownership satisfies the validator's `owner_uid == 0` short-circuit regardless of which UID is running.
  - **R2 — new `scripts/*` subdirs created mode 0700**: the v0.13.0 upgrade installed `scripts/python-helpers/`, `scripts/cli-help/`, `scripts/smoke/4494-integrated-helpers/`, `scripts/smoke/835-static-admin-launch-helpers/`, `scripts/smoke/heredoc-regression-helpers/` as `drwx------ ec2-user:ec2-user` (umask=077 inheritance during the apply-live overlay). Isolated agent UID couldn't traverse them → `python3` failed to open `scripts/python-helpers/sha1-batch.py` (PR #856's batched-sha1 hot path on agent start). Fix: `bridge-upgrade.sh:1606-1611` runs `find "$TARGET_ROOT/scripts" -type d -exec chmod a+rX {} +` immediately after apply-live (gated on `DRY_RUN==0`). Uppercase `X` ensures files don't get unwanted +x. apply-live's `bridge-upgrade.py:1746-1766` already writes file modes explicitly via `write_bytes(..., target_mode)`; this fixes the parallel dir-mode gap.
  - **R3 — isolated `~/.claude/plugins/` mode 2750**: per-agent isolation grant left `/home/agent-bridge-<name>/.claude/plugins/` as `drwxr-s--- root:ab-agent-<name> 2750`. Group r-x+setgid but NO write. Dev-plugin-cache (`bridge-dev-plugin-cache.py:955-983`) needs to flock `installed_plugins.json.lock` during agent-start step 4, fails with EACCES, channel-required plugin cache aborts, launch fails. Fix: three coordinated changes set mode 2770 with setgid preserved — `bridge_linux_share_plugin_catalog` fresh-create path (`lib/bridge-agents.sh:2310-2324`), `bridge_isolation_v2_migrate_normalize_layout` upgrade path (`lib/bridge-isolation-v2-migrate.sh:1024-1045`), grant matrix row (`lib/bridge-isolation-v2.sh:1430-1443`). Scope is `~/.claude/plugins/` ONLY; `~/.claude/` itself stays 2750 (read-only catalog), other 2750 matrix rows (shared root/cache/aggregate, agent root, credentials) unchanged.

  Regression smoke `scripts/smoke/864-upgrade-perm-regressions.sh` (6 assertions: R1=1, R2=3, R3=2) exercises all three on synthesized v0.11.0 → v0.13.0 fixtures. Uses python3 for portable mode reads (`stat -f '%Lp'` on macOS BSD strips the setgid bit, which would break R3's 2750↔2770 distinction). Wired into `scripts/ci-select-smoke.sh` as required when `bridge-upgrade.sh`, `lib/bridge-isolation-v2*.sh`, `lib/bridge-marker-bootstrap.sh`, or `lib/bridge-agents.sh` change.

  Operator-host context: the regressions are discovered as a sequence (marker → scripts → plugins) — fixing one unblocks the next failure stack frame, no overlap. Without this hotfix, an operator running `agent-bridge upgrade --apply` from v0.11.0 to v0.13.0 sees all isolated agents enter auto-restart backoff with no dashboard signal beyond `auto-start backoff <agent> (failures=N, retry_in=Ns, reason=start-command-failed)`. The upgrade JSON output still shows generic `partial_failures` rather than structured `agent_perm_regression_<N>` rows; surfacing this in the upgrade JSON is tracked as a follow-up polish.

## [0.13.1] — 2026-05-14

### Highlight — Wave 3 #825 fix + #857 PR-1 foundation for ACL deprecation

Post-v0.13.0 follow-up wave. Two PRs landed within the same operator-clock as v0.13.0:

1. **#825 closed (PR #862)** — controller-side dev-channels auto-accept watcher silent failure since v0.11.0. Fix is intentionally robust to the underlying root cause (foreground-detector basename regex `claude|claude-*|claude.*` may or may not be the proximate cause depending on the operator's specific Claude invocation — hypothesis was inconclusive on macOS).
2. **#857 PR-1 (PR #861)** — first step of the 6-PR ACL deprecation umbrella. Adds `bridge_isolation_write_file_as_agent_user_via_bash` symmetric to PR #836's read helper. Subsequent PRs (PR-2/-3/-4) will use this to rewire channel dotenv setup flows; PR-5 will remove the channel-dotenv ACL stop-gap from #851 (PR #855).

### Fixed

- **Pane-content trigger for controller dev-channels auto-accept watcher (PR #862, closes #825)**. `bridge_start_schedule_dev_channels_accept` now polls `bridge_tmux_pane_has_dev_channels_picker` (a new helper that grep'es the tmux pane for the development-channels picker text — "I am using this for local development") BEFORE the foreground process-name gate. When the picker text appears, the watcher exports `BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND=0` and sends `C-m` regardless of the foreground basename. Where the foreground gate is still load-bearing, `lib/bridge-tmux.sh` now consults `bridge_tmux_process_tree_has_claude` (the existing process-tree descendant walker from PR #836's family) as a permissive variant — the basename regex `claude|claude-*|claude.*` is left narrow to avoid accidentally matching unrelated `node`/`bun` processes. New regression `scripts/test-controller-dev-channels-accept.sh` with 4 cases (R1 positive control, R2 negative control — the bug, R3 picker-sweep neighbor guard ensuring `scripts/picker-sweep.sh`'s allow-list does NOT overlap with dev-channels picker text, R4 timeout-still-works for the no-picker/no-foreground edge). Generated fixture files are written with `{ printf '%s\n' ... } > file` blocks (footgun #11 — heredoc-stdin and `<<<` here-strings are forbidden anywhere in the smoke). Cross-platform stat extraction uses GNU `-c '%a'` first with BSD `-f '%Lp'` fallback for portability across macOS dev and Linux CI.

### Added

- **Sudo-as-agent-UID write helper `bridge_isolation_write_file_as_agent_user_via_bash` (PR #861, refs #857 PR-1)**. Symmetric to PR #836's read helper at `lib/bridge-isolation-helpers.sh:80`. Signature: `<agent> <dest_path> [mode]` with default mode `0600`. Reads content from stdin pipe (NOT staging file, NOT env, NOT heredoc/here-string at call sites). Inside the isolated UID, an inline `bash -c` script does temp-file-in-destination-dir (same-fs atomic rename), `umask 0077`, `chmod $mode` BEFORE `mv -f` so the published file lands with the correct mode without a readable-by-others window. RC contract mirrors the read helper exactly: 0 = isolated+sudo+success, 1 = not isolated (caller falls back to direct write), 2 = isolated+no passwordless sudo, 3+ = script returned non-zero with rc preserved (rcs<3 shifted into 3+ band). Pre-check via the existing `bridge_isolation_can_sudo_to_agent` for DRY with the read helper. New smoke `scripts/smoke/857-pr1-isolation-write-helper.sh` with 7 mocked-sudo cases (A1-A7: default mode, custom mode, dest-dir missing, mktemp fail, stdin pipe fail, chmod fail, mv fail) plus 1 env-gated real two-UID case (B1, requires `BRIDGE_ISOLATION_HELPERS_TEST_UID` + passwordless sudo to that user — explicit `SKIP:` log when env is unset). Wired into `scripts/ci-select-smoke.sh` as required when `lib/bridge-isolation-helpers.sh` changes. **PR-1 only.** Caller rewires land in subsequent umbrella PRs.

## [0.13.0] — 2026-05-14

### Highlight — v0.11.0 fallout cleared + agb perf 94.5% faster + ACL stop-gap + controller-blind plugin trust

Single release rolling up Wave 1 (v0.11.0 post-upgrade fallout, 6 bug cluster) plus Wave 2 (#851 channel-dotenv ACL stop-gap, #848 dispatcher perf 1.008s → 0.055s, #852+#853 unified controller-blind plugin status + marketplace self-heal) plus a docs-policy directive (wave-orchestration evaluation for all agent session types). Ten issues closed: #819, #820, #821, #822, #823, #824, #848, #851, #852, #853. Two umbrella issues filed for the long-term direction: #857 (deprecate controller-side ACL grants on channel dotenvs — codifies the `feedback_acl_deprecation` policy and lays out a 6-PR migration plan reusing PR #836's `bridge_isolation_run_as_agent_user_via_bash` pattern) and #859 (defer claude plugin install to isolated UID instead of controller).

This is the first release where the **wave-orchestration directive is propagated by default to every Agent Bridge session type** (admin / static / dynamic / cron) via the canonical `docs/agent-runtime/common-instructions.md`. Agents now evaluate "is this multi-issue / multi-track work?" before processing and reach for the skill when 2+ disjoint issues or Track A/B/C splits are in scope. PR #854 added the directive; this release ships it.

### Added

- **`docs/agent-runtime/common-instructions.md` — Multi-Item Work — Wave Orchestration 평가 section (PR #854)**. Adds a per-session-type directive: before starting work that spans 2+ issues, PRs, or tracks, evaluate whether `wave-orchestration` applies. Signals to invoke (2+ disjoint issues, Track A/B/C splits, large changes that benefit from per-track PRs, codex pair-review required for >300 LOC specialized work, user mentions "backlog / parallel / wave / track"); signals to skip (single small bug / typo / <50 LOC, design brainstorm needed, same-file conflicts forcing serialization); result handling (invoke skill + surface decision, or proceed single-task with mid-task re-evaluation); dynamic-agent specific re-evaluation on ad-hoc work with hidden back-references. Root `CLAUDE.md` gets a parallel pointer paragraph between Editing Principles and Working With Codex Reviewers. No code paths touched; propagation works via `agents/_template/CLAUDE.md` line 17 referencing the canonical doc.

- **Stop-gap channel dotenv mask repair `bridge_isolation_v2_apply_channel_state_dotenv_acl` (PR #855, closes #851)**. New helper in `lib/bridge-isolation-v2.sh` (~line 2034) symmetric to `bridge_isolation_v2_apply_controller_credentials_read_grant` but for per-agent channel dotenv files (`<agent_home>/.{teams,ms365,discord,telegram,mattermost}/.env`). Repairs runtime regressions where Teams/MS365 plugin writes propagate `umask=077` onto the parent directory and the dotenv ACL `mask` falls back to `---`, nullifying the named-user `r--` grant and blocking `agent start` with `auth=unreadable ready=no`. Helper is roster-aware: includes `ctrl_user` AND every isolated-agent in the current roster in both the keep-set (no stale-strip) and the final `setfacl -m u:<X>:r-- m::r-- o::---` invocation — mirrors the credentials helper's r12 pattern. Two trigger points: (1) `bridge-daemon.sh:3566` daemon health-loop self-heal, env-gated `BRIDGE_CHANNEL_HEALTH_DOTENV_SELFHEAL` **default-off** (operator opts in); fires only on `*unreadable:*` reasons emitted by the existing channel-health probe (Teams `lib/bridge-agents.sh:5537-5541`, MS365 `:5575-5579`); (2) `bridge-start.sh:429-435` pre-launch re-assert BEFORE the `bridge_agent_channel_status_reason` check so the heal-then-recheck flow opens `agent start` on the regressed-state path. Per-agent flock removed in r2 scope reduction (the helper can race with the daemon path when both fire; tracked as known stop-gap limitation). Smoke fixture `scripts/test-channel-dotenv-mask-repair.sh` adds Case 5 (controller-grant preservation: ec2-user grant present + roster grant present + no stale strip) and Case 6 (post-repair status check passes). Race-stress case 7 explicitly omitted per scope. The PR is a **MINIMUM STOP-GAP** classified in the body — long-term shape lives in umbrella issue #857 which removes the ACL surface entirely (channel dotenvs become isolated-UID-owned with mode 0600, controller delegates reads/writes via `bridge_isolation_run_as_agent_user_via_bash`). This release ships the stop-gap; #857's PR-1 through PR-6 will remove it.

- **Controller-blind plugin status + agent-start marketplace self-heal (PR #858, closes #852 #853)**. Two regressions on third-party Claude marketplace plugins shared one root cause: the controller crossing the isolation boundary to inspect state that lives inside the isolated UID's mode-700 home OR in the controller's own drift-prone `claude plugin marketplace list`. The fix unifies them per codex design consult (approach A — trust the registry, not approach B — sudo hop). `bridge_claude_plugin_status` (lib/bridge-agents.sh ~5807) gains an optional `agent` argument; when isolation is active AND the per-UID `installed_plugins.json` lists the spec, the function returns `enabled` without running `os.access` (which would always false-fail across the boundary). The manifest is written by `bridge_write_isolated_installed_plugins_manifest` at isolation-prepare time and is the canonical source of truth — file reachability inside an opaque UID home is not a useful signal. Six callers thread the new arg: `bridge_ensure_claude_plugin_enabled`, `bridge_ensure_claude_channel_plugins_for_csv`, `bridge_ensure_claude_channel_plugins`, `bridge_ensure_claude_launch_channel_plugins`, `bridge_claude_channel_plugins_ready_for_csv`, `bridge_agent_channel_diagnostics_tsv`. Single-arg legacy call shape preserved. New helper `bridge_claude_marketplace_ensure_present_for_isolated` (~line 5954) runs BEFORE `claude plugin install` for an isolated agent: if the marketplace is missing from `claude plugin marketplace list` but declared in `known_marketplaces.json`, it self-heals via `claude plugin marketplace add <repo>` then proceeds with install. Warn-and-continue on failure (never `bridge_die` — drift recovery degrades gracefully if CLI is unhealthy). Isolation-gated; non-isolated installs unchanged. New Python helpers `scripts/python-helpers/claude-plugin-manifest-has-spec.py` and `…/claude-known-marketplaces-extract-repo.py` live as standalone files (footgun #11 clean — no heredoc-stdin). Smoke `tests/isolation-plugin-sharing.sh` adds `third-party-plugin-trust` sub-case with 12 assertions: trust path returns `enabled`, missing-manifest negative returns `missing` (proves no false-positive fabrication), `@agent-bridge` fast-path preserved, marketplace self-heal fires and invokes `marketplace add` on drift, self-heal is no-op for non-isolated agents, present-list/missing-catalog and directory-source negative cases. Long-term shape (defer plugin install to isolated UID side via `bridge-run.sh` running inside that UID) is tracked in follow-up #859.

### Fixed

- **v0.11.0 post-upgrade fallout — 6 bug cluster (PR #834, closes #819 #820 #821 #822 #823 #824)**. Operator-bundled batch landing the regressions surfaced during a live `agent-bridge upgrade --apply` on a multi-agent server install:
  - **#819 — bridge-dev-plugin-cache materialized non-isolated agent plugins under controller HOME**. `bridge-dev-plugin-cache.py` now honors per-agent `BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT` + `BRIDGE_CLAUDE_PLUGINS_ROOT` env overrides set by `bridge-run.sh` (lines 512-532) before exec. Atomic `os.replace` on `installed_plugins.json` write (lock + tempfile), required-plugin manifest failures propagate to `required_failures` instead of being swallowed (`bridge-dev-plugin-cache.py:976-1051`, `:1190-1216`, callers at `bridge-run.sh:544-552`). One agent's plugin updates no longer clobber another's.
  - **#820 — resume resolver re-selects rejected transcript via fs-scan after forget-session**. Per-agent `state/agents/<agent>/resume-quarantine.json` (atomic write, lock-guarded) lists rejected session ids. `bridge_resolve_resume_session_id` accepts an `exclude_csv` arg (positional 6); auto-fetches the quarantine via `bridge_agent_resume_quarantine_ids` when the caller supplies only `agent`. `scripts/python-helpers/resolve-claude-resume-session-id.py` (the externalized helper from v0.12.0) gains argv[5] = exclude_csv and skips quarantined stems during fs-scan, treats `candidate in exclude` as quarantined and resolves to the freshest non-quarantined stem (rc=2). Single quarantine writer at `bridge-run.sh:821` — by-design, because id-staleness is only knowable after claude exec rejects with `No conversation found with session ID`. New regression smoke `scripts/test-resume-quarantine.sh`.
  - **#821 — `bridge_upgrade_collect_agent_restart_report` had no per-agent timeout**. Wrapped `bridge-agent.sh restart` calls at `bridge-upgrade.sh:418-463` with `bridge_with_timeout` (default 60s via `BRIDGE_UPGRADE_RESTART_TIMEOUT_SECONDS`). Exit codes 124/137 map to a distinct `restart-timeout` classification at `:468-475`; the for-loop continues after individual timeouts so one hung agent no longer blocks the whole upgrade.
  - **#822 — upgrade reported restart_failed even when daemon subsequently launched agent**. New `bridge_upgrade_reconcile_agent_restart_recovery` at `bridge-upgrade.sh:516-615` runs between `bridge_upgrade_collect_agent_restart_report` and `bridge_upgrade_agent_restart_json`. Settle window default 20s via `BRIDGE_UPGRADE_RECOVERY_SETTLE_SECONDS` with 1s poll-and-early-break. JSON/text output separates `recovered_by_daemon` rows at `:707-723`/`:749-795` so the operator sees the post-reconcile state.
  - **#823 — prompt-guard `bridge_runtime_secret_access` matched on presence-only filename**. Rule body in `bridge_guard_common.py:51-95` replaces presence-only path matching with a verb-gated bidirectional 80-char window. Verb list: read/cat/dump/upload/leak/edit/delete/write/exfiltrate/copy/mv/tail/less/more. Negative coverage at `scripts/test-prompt-guard-rules.sh:179-196` (prose mentions don't trip; verb + non-credential `.env` doesn't trip).
  - **#824 — `agent show <X>` text formatter shifted fields when session_id empty**. `bridge-agent.sh:1695-1717` uses tab-to-US sentinel parsing to preserve empty middle fields and refuses non-30-column rows. Producer emits exactly 30 columns at `:1237-1270`. Regression `scripts/test-agent-show-formatter.sh`.

- **`agb` / `agent-bridge` dispatcher cold-start 94.5% faster (PR #856, closes #848)**. `agent-bridge --help` mean wall-clock drops from 1.008s to 0.055s on macOS Bash 5.3.9. Three reductions land together: (1) `bridge_sha1_batch` helper + `scripts/python-helpers/sha1-batch.py` real-file invocation — one `python3` invocation hashes N stdin inputs instead of N spawns; roster hydration in `lib/bridge-state.sh:1119` precomputes every history key in a single batched call (`mapfile -t … < <(printf '%s' "$_hash_inputs" | bridge_sha1_batch)` — the `<<<` here-string form would re-trip the Bash 5.3.9 `heredoc_write` deadlock class). (2) `bridge_load_roster` per-process memoization (`BRIDGE_ROSTER_CACHE_LOADED` flag) with `bridge_roster_cache_invalidate` companion wired into mutate-then-reload call sites: `bridge-init.sh` (×2), `bridge-agent.sh`, `bridge-run.sh` (signature-changed path), `lib/bridge-admin-pair.sh`, `bridge-daemon.sh` main-loop (×2), AND `bridge-sync.sh::prune_missing_dynamic_agents` (set `PRUNED_DYNAMIC["$agent"]=1` immediately after `bridge_archive_dynamic_agent` success, before the remove attempt — so archive-success + remove-fail still invalidates) + `bridge-sync.sh::refresh_missing_session_ids`. `BRIDGE_ROSTER_CACHE_DISABLE=1` escape hatch for tests. Defensive `invalidate + reload` immediately before `bridge_render_active_roster`. (3) `--help` / `-h` / `--version` / `-V` short-circuit moved to TOP of `agent-bridge` (line 138-157) BEFORE `source bridge-lib.sh` at line 157 — help text extracted to `scripts/cli-help/agent-bridge-usage.txt` with `__CLI_NAME__` placeholder substituted via `sed -e 's|__CLI_NAME__|$CLI_NAME|g'` (pipe delimiter so `/` and `&` in CLI names don't break). VERSION reads from the VERSION file directly. Positional `version` subcommand still flows through the slow path (back-compat). Side benefit: `--help` and `--version` now work on layout-required-guard installs (the guard no longer fires for the fast path). New smoke `scripts/smoke/bridge-sync-roster-memo.sh` (6 cases: prune-invalidates, no-churn-preserves, refresh-invalidates, refresh-no-churn, pruned-render-exclusion, and T6 the regression for archive-success + remove-fail — T6 fails against r2 head `c11d89d` and passes on r3 head `f396e29`, locking the post-cycle correctness). CI gate in `scripts/ci-select-smoke.sh:193-205` wires the new smoke as required when `bridge-sync.sh` or `lib/bridge-state.sh` change.

## [0.12.1] — 2026-05-14

### Highlight — #835 static admin launch deadlock closed

Patch release closing issue #835 (static Claude launch builder deadlock before engine spawn) via a 4-wave chain. The 2026-05-14 operator wedge — `bridge_agent_launch_cmd patch` hanging in `heredoc_write` and `agb status` reporting the agent as healthy while the engine was never spawned — is structurally fixed (Wave A removes 6 launch-cmd Python heredocs in `lib/bridge-state.sh`; Wave A' extracts the channel-state-dirs upstream helper in `lib/bridge-agents.sh`), surface gap closed (Wave B adds `starting/stalled before engine` activity state), and regression-guarded (Wave C ships `scripts/smoke/835-static-admin-launch.sh` wired into the required CI suite). Follow-up #838 (surviving #815 site in `bridge_resolve_resume_session_id`) closed by chain. No user-facing API changes; no env var additions; existing parsers continue to work.

### Fixed

- **Regression smoke `scripts/smoke/835-static-admin-launch.sh` — Wave C of issue #835** (closes #835). Three-case fixture closing acceptance criterion 5 of #835 ("Add a regression smoke that fails if a static admin startup hangs before spawning the engine"). Case 1 asserts `bridge_agent_launch_cmd <static-claude-admin>` returns under 2s (default `BRIDGE_SMOKE_LAUNCH_CMD_DEADLINE=2`) — the exact pre-Wave-A failure mode on the operator's 2026-05-14 wedge would have hung the call indefinitely inside `heredoc_write`; the case is wrapped in `timeout --foreground 20s` so a regression terminates the suite deterministically instead of hanging it. Case 2 asserts `bridge_agent_engine_process_alive` returns rc=1 against a synthesized tmux session whose only descendant is a `sleep` (no `claude`/`codex` child — the operator's stalled-before-engine shape that Wave B rendered as `starting`). Case 3 is the positive control — a tmux session whose inner command is a symlinked `sleep` invoked by basename `claude` reads as kernel-truthful `comm=claude` and the predicate returns rc=0. Cases 2/3 layer atop Wave B's `scripts/smoke/status-engine-detect.sh` (which already covered the predicate at the unit level with 4 cases); Wave C re-exercises the engine-alive predicate through a separate integration driver so a future refactor that breaks Wave B's invariants also fails here. Driver bodies tracked under `scripts/smoke/835-static-admin-launch-helpers/` (`static-admin-roster.sh`, `launch-cmd-driver.sh`, `engine-alive-driver.sh`) rather than embedded as heredoc-to-file bodies — heredoc-to-file with multi-line bash recurs the Bash 5.3.9 `heredoc_write` deadlock class the production fix in PR #845/#846 addresses, see `feedback_bash_heredoc_write_class_recurrence.md` and Footgun #11. Wired into `scripts/ci-select-smoke.sh` required suite via four trigger rows: (1) `add_all_required_static` (catches `bridge-lib.sh`/`lib/bridge-core.sh`/`lib/bridge-agents.sh`/roster moves), (2) `bridge-daemon.sh|...|lib/bridge-state.sh` (Wave A surface), (3) `bridge-start.sh|...|bridge-agent.sh|...|lib/bridge-tmux.sh` (Wave B surface), (4) `bridge-setup.py|...|bridge-status.py` (Wave B status downstream); a new `scripts/python-helpers/launch-cmd-*.py` row ensures any modification to Wave A's extracted Python helpers re-runs the regression smoke. Wave B's `scripts/smoke/status-engine-detect.sh` was simultaneously wired in (Wave B added the smoke but did not edit the CI selector). Total wall time ~1.3s on a 2024 MacBook Pro. Issue #835 closes on this PR merge.
- **Extract `bridge_extract_development_channels_from_command` Python heredoc to helper file — Wave A' of issue #835** (refs #835 Wave A'). PR #845 (Wave A of #835) closed the 6 launch-command builders in `lib/bridge-state.sh` but flagged in its own changelog that `lib/bridge-agents.sh::bridge_extract_development_channels_from_command` — reached via the channel-state-dirs chain when `bridge_agent_launch_cmd` rebuilds a static admin's command — still inlined an equivalent heredoc-stdin form and was upstream of the launch-cmd hot path. The python body moves to `scripts/python-helpers/extract-dev-channels-from-command.py`, invoked via `python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/extract-dev-channels-from-command.py" "$command"` instead. Behavior is preserved byte-for-byte (15-case parity test).
- **`agb status` distinguishes `starting/stalled before engine` from `working` when tmux exists but no `claude`/`codex` descendant is in the pane process tree — Wave B of issue #835** (refs #835 Wave B). The operator's 2026-05-14 wedge on the static admin `patch` left a live tmux pane (running only `bridge-run.sh patch --continue` nested bash shells, no engine child) while `bridge_agent_is_active` returned true and the existing snapshot path defaulted to `activity_state="working"`, hiding the launch-cmd heredoc deadlock behind a healthy-looking status row. New helper `bridge_agent_engine_process_alive` (in `lib/bridge-tmux.sh`) walks the agent's tmux pane process tree (same BFS shape as `bridge_tmux_process_tree_has_claude`) and returns true only when a process whose `comm` matches the agent's declared engine kind descends from the pane root. The three `activity_state` writers gain a fourth state `starting` (between idle / working / stopped). `bridge-status.py` dashboard widens the state column from 7 to 8 chars. Downstream consumers absorb safely: `bridge-queue.py` priority math treats `starting` like not-working; `bridge-doctor.py` sees it as "neither stopped nor idle". Regression smoke `scripts/smoke/status-engine-detect.sh` exercises 4 cases: (1) basename predicate unit, (2) no-tmux-session → rc=1, (3) tmux pane running only `sleep` (no engine descendant) → rc=1, (4) tmux pane with a `claude`-symlinked `sleep` → rc=0 for engine=claude, rc=1 for engine=codex. Wave A (PR #845, launch-cmd heredoc extraction) and Wave A' (lib/bridge-agents.sh helper extract) cover the wedge; this wave closes the detection gap. Issue #835 closes after Wave C lands.
- **Extract launch-cmd Python heredocs to helper files — Wave A of issue #835** (refs #835 Wave A). The 6 launch-command builders in `lib/bridge-state.sh` previously inlined their Python bodies through bash stdin redirection: `bridge_codex_launch_with_hooks` (codex feature-flag injection), `bridge_claude_launch_with_channels`, `bridge_claude_launch_with_development_channels`, `bridge_claude_launch_with_channel_state_dirs` (env STATE_DIR rewriter with the byte-preserving env_prefix walker from PR #776 / PR #790), `bridge_build_static_claude_launch_cmd` (the wedge point operator hit on 2026-05-14 for the static admin `patch`), and `bridge_build_safe_claude_launch_cmd`. On Homebrew Bash 5.3.9 those bash-read forms can wedge in `heredoc_write` when the wrapper is invoked inside a command substitution from an absolute-path-sourced shell — same class that closed #800 / #815 / #827 / #840 for the daemon, CLI, status, and session-id hot paths. The python bodies move to `scripts/python-helpers/launch-cmd-codex-hooks.py`, `…-claude-channels.py`, `…-claude-dev-channels.py`, `…-claude-channel-state-dirs.py`, `…-static-claude-build.py`, `…-safe-claude-build.py`, invoked via `python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/<helper>.py"` instead. Behavior is preserved byte-for-byte (the byte-preserving walker, the `false` → `claude` repair, the duplicate-collapse with single-space gap strip — all intact in the new files). Wave B (`agb status` tmux-without-engine detection so the surface no longer over-reports `active` on a started-but-not-yet-spawned admin) and Wave C (regression smoke fixture) stay pending — issue #835 remains open until all three waves land. Note: `bridge_agent_launch_cmd` for a static admin still hits an equivalent inline-Python heredoc-stdin in `lib/bridge-agents.sh::bridge_extract_development_channels_from_command` (reached via the channel-state-dirs chain) on Bash 5.3.9 — that site is upstream of the 6 Wave A sites and pre-existing on `main` HEAD; tracked for a follow-up wave.

## [0.12.0] — 2026-05-14

### Highlight — live recovery follow-ups + heredoc resilience reinforcement

Post-v0.11.0 follow-up wave triggered by the 2026-05-14 `crm-test` live recovery on the operator's host (running into #815 heredoc stalls). Nine PRs landed across two task chains: the v0.11.0 hotfix queue (#830 prompt-guard default-off revert, #831 usage monitor per-agent state, #832 channel-health probe controller-blind degradation) and the dynamic-startup recovery wave (#837 #826 grace, #840 #827 live session id pre-transcript, #839 #828 skill auto-help opt-in, #842 #4494 Wave D integrated smoke). Plus follow-up #838 filed for a surviving #815-class site in `lib/bridge-state.sh::bridge_resolve_resume_session_id` that Wave A/B/C/D didn't cover.

### Changed

- **Integrated dynamic-recovery regression smoke `scripts/smoke/4494-integrated-dynamic-recovery.sh` — Wave D of #4494**. Single fixture that exercises the 3 fixes from #826 (PR #837, bridge-sync grace), #827 (PR #840, live Claude session id pre-transcript), and #828 (PR #839, skill auto-help opt-in) in one end-to-end flow simulating the operator's 2026-05-14 `crm-test` recovery: dynamic agent .env preserved through a slow start, live `sessions/<pid>.json` accepted before transcript, agent-bridge --help recursion suppressed on default render path, total wall time under 10s. Wired into `scripts/ci-select-smoke.sh` required suite. Driver bodies tracked under `scripts/smoke/4494-integrated-helpers/` (heredoc-to-file with multi-line bash bodies deadlocks on Bash 5.3.9 — see `feedback_bash_heredoc_write_class_recurrence.md`).
- **`bridge-sync.sh` dynamic-prune start grace is configurable; default 300s (Issue #826)**. `prune_missing_dynamic_agents` used to remove a dynamic agent's `state/agents/<name>.env` after only 15 seconds when no tmux session was visible — fine when the agent's first start completed within those 15s, fatal when the start was slow (operator hit this on 2026-05-14 recovering `crm-test` against the #815 heredoc stalls). The hard-coded 15s threshold is now operator-controlled via `BRIDGE_DYNAMIC_START_GRACE_SECONDS` (integer seconds; default 300s = 5min — the operator's live-recovery hotfix value, which absorbs normal Claude / Codex bootstrap + plugin / hook init). Malformed values (empty, non-integer, negative) fall back to the 300s default so a typo cannot break the daemon sync cycle. The stale-prune path is unchanged: any dynamic env older than the grace is still archived and removed exactly as before. Regression coverage in `scripts/smoke/dynamic-start-grace.sh` exercises the resolver (default / override / malformed-fallback), preserves a 60s-old dynamic under the default grace, still prunes a 6h-old dynamic, and confirms an active-tmux agent is never pruned regardless of age. The smoke sources `bridge-sync.sh` and exercises `prune_missing_dynamic_agents` against a stubbed dependency surface (rather than running the full sync pipeline) because the downstream `bridge_resolve_resume_session_id` + `bridge_render_active_roster` helpers run `python3 - <<'PY'` heredoc-stdin and hit the Bash 5.3.9 macOS deadlock class (#815 / Footgun #11) — independent of #826 and out of scope for this PR. To make the smoke possible, `bridge-sync.sh`'s imperative tail moved into a `bridge_sync_main` function guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`; behavior when run directly is unchanged.
- **Full Subcommand Reference generation in `bridge_render_project_bridge_reference` is now opt-in via `BRIDGE_RENDER_SKILL_AUTO_HELP=1`** (refs #828, Wave C of the #828 dynamic-start recovery wave). On a degraded runtime — particularly the heredoc-deadlock conditions tracked in #815 — `lib/bridge-skills.sh::bridge_render_project_bridge_reference` would re-enter the CLI stack during dynamic agent start because the trailing "## Full Subcommand Reference" block auto-generates by invoking `agent-bridge --help` (via `bridge_cli_top_level_subcommands` + `bridge_cli_subcommand_help_summary`, which both shell out to `"$cli" --help` and re-source bridge-lib for the help dispatcher). Operator observed during `crm-test` recovery on 2026-05-14 that `bridge-start.sh --dry-run --no-attach --no-continue` did not become reliable until that auto-help block stopped running on the default path. The block is now gated behind `BRIDGE_RENDER_SKILL_AUTO_HELP=1`; default agent start / attach renders only the curated intent-grouped sections (Roster / Start / Task Queue / Cron / Urgent / Stop / Share) and never recurses into `agent-bridge --help`. Operators (or doc-refresh flows) that explicitly want the auto-discovered subcommand reference set `BRIDGE_RENDER_SKILL_AUTO_HELP=1` before re-running `bridge-setup.sh`. Adds regression smoke `scripts/smoke/skill-render-no-help-recursion.sh` (sentinel-file pattern — stubs `agent-bridge --help` via `BRIDGE_CLI_NAME`, asserts the sentinel stays empty on the default path and gets populated on the opt-in path). The existing `scripts/smoke-test.sh` Track A render assertion was updated to cover both shapes (default skips, opt-in emits). No CLI surface change; existing rendered skill files continue to work on disk until the next regeneration. Companion tracks: dynamic-start grace (#826) and Claude session id rejection (#827) ship as separate PRs.
- **Accept live Claude session id before transcript jsonl exists — issue #827.** `lib/bridge-state.sh::bridge_detect_claude_session_id` and `bridge_resolve_resume_session_id` now accept the session id from a same-cwd `~/.claude/sessions/<pid>.json` record whose pid is alive even when the matching `~/.claude/projects/<slug>/<sid>.jsonl` transcript has not yet materialized. Operator's 2026-05-14 live recovery of `crm-test` confirmed the symptom: a fresh Claude Code interactive session created `sessions/<pid>.json` before the transcript jsonl, the previous detect path skipped that record because no transcript existed, the resolver rejected the candidate for the same reason, and `AGENT_SESSION_ID` stayed empty until locally patched. Dead-pid records without a transcript remain rejected (so stale session JSON files left behind by a previously crashed agent cannot mask a missing transcript). The acceptance gate is narrow: `os.path.realpath(record.cwd) == os.path.realpath(workdir)` AND `os.kill(record.pid, 0)` returns true (PermissionError means another user owns the pid → still alive). The python bodies of both functions moved into `scripts/python-helpers/detect-claude-session-id.py` and `scripts/python-helpers/resolve-claude-resume-session-id.py` (invoked via `python3 -c`-equivalent file invocation) instead of the previous heredoc-stdin form — that earlier form wedged on Bash 5.3.9 in the `heredoc_write` deadlock class (issue #815 / #800) when the function was called inside a command substitution from a shell sourced via absolute path, which is exactly how the new smoke fixture exercises it. Regression smoke `scripts/smoke/claude-live-session-pretranscript.sh` covers T1 live accept (alive pid, no transcript → detect + resolve both return the synthesized id), T2 dead pid + no transcript (rejected, resolver rc=1), T3 stale dead pid in a fresh cwd (still rejected — guards against cwd-aliasing artifacts). Codex session id detection is intentionally untouched.
- **`BRIDGE_PROMPT_GUARD_ENABLED` default reverted to `0` on every host** (operator hotfix 2026-05-14). PR #813 (v0.11.0) introduced a host_profile-aware default that flipped prompt guard to default-on for `host_profile=server` installs. Operators reported the auto-enable produced too many spurious blocks on real channel / MCP / intake traffic, so the default reverts to off everywhere — operators who want prompt guard on opt in explicitly via `BRIDGE_PROMPT_GUARD_ENABLED=1` (same shape as v0.10.0 and earlier). `lib/bridge-guard.sh::bridge_prompt_guard_default` always returns `0` (host_profile branch removed); `bridge_guard_common.py::prompt_guard_enabled` uses `default=False`. `lib/bridge-host-profile.sh::bridge_host_profile_emit_dev_advisories` drops the prompt-guard skip line from the dev advisory block since there is no longer a prompt-guard default to skip. `picker-sweep` retains its v0.11.0 default-on behavior (server: auto-enabled + auto-cron-registered; dev: default-skipped); only prompt guard reverts.
- **Destructive regression smoke `scripts/smoke/heredoc-regression.sh` — Wave D of issue #815** (refs #815 Wave D). Six-case fixture guards every Wave A/B/C surface from reintroducing the heredoc-deadlock or detection-gap regressions: (1) large tmux capture through `lib/bridge-tmux.sh::bridge_tmux_session_has_prompt_from_text` completes in <2s; (2) 50-agent roster summary recipe (`mktemp + printf > tmp + while read < tmp`, the exact shape `lib/bridge-agents.sh::bridge_list_active_agents_numbered` uses) completes in <1s; (3) `daemon::process_context_pressure_reports` happy path matches expected audit entries (the exact Wave B r1 trailing-newline regression vector); (4) `bridge_daemon_health_signal` returns `health=ok` / `health=silent` / `health=down` per the derivation table (stubbed `bridge_daemon_pid` per sub-scenario); (5) BSD colonized-offset legacy heartbeat `2026-05-13T07:30:05+09:00` parses to a numeric age via the Wave C r2 offset normalization (the r1 BLOCKING regression vector that silently returned empty / rc=1 on BSD `date -j -f` and masked silent-but-alive as `health=down`); (6) `cmd_start` silent-but-alive detection cross-references case 4b plus a drift check that `BRIDGE_DAEMON_TICK_FRESH_SECONDS` default (120s) stays consistent across `lib/bridge-state.sh` + `bridge-daemon.sh` — the inline silent-detection block in `cmd_start` was deliberately not extracted (brief permits the case 4b fallback when extraction is awkward) because it's tightly coupled to the daemon's start sequence (`kill -TERM`/`kill -KILL`/`bridge_stop_silence_watchdog`/audit-emit/fall-through). Wired into `scripts/ci-select-smoke.sh` required suite unconditionally (`add_required heredoc-regression` after the diff-driven loop, in the `else` branch alongside the legacy guard) so it runs on every PR regardless of diff. Driver bodies are tracked under `scripts/smoke/heredoc-regression-helpers/` rather than embedded as `cat <<EOF >$driver` heredoc bodies in the smoke wrapper itself — heredoc-to-file with a multi-line body recurs the Bash 5.3.9 `heredoc_write` deadlock class the fixture is guarding against (see `feedback_bash_heredoc_write_class_recurrence.md`). The fixture's own self-audit (in the verification matrix) greps for `done <<<"\$|<<<"\$capture|python3 - <<|source /dev/stdin <<<` patterns in the fixture source and fails the smoke if any reintroduce. Issue #815 closes on this PR merge.
- **CLI hot-path heredoc / here-string elimination — Wave A of issue #815** (refs #815 Wave A). On a stale live macOS runtime the CLI hot path (`agb status`, `agb agent list --json`, `agb inbox <agent>`, `agb daemon start`) was hanging inside Bash `heredoc_write` while sourcing `lib/bridge-agent-update.sh` (two `$(cat <<'PY' ... PY)` source-time captures) and while iterating large tmux / queue / roster captures via `done <<<"$text"`. Wave A removes those four classes from the CLI startup path: (1) the two source-time Python captures in `lib/bridge-agent-update.sh::bridge_agent_update_apply_launch_cmd` / `…_apply_channels` move into `scripts/python-helpers/agent-update-apply-launch-cmd.py` + `agent-update-apply-channels.py` invoked via `python3 "$BRIDGE_SCRIPT_DIR/..."` (no source-time read remains); (2) the 8 `done <<<"$text"` sites in `lib/bridge-tmux.sh` (`bridge_tmux_session_has_prompt_from_text`, `bridge_tmux_session_has_pending_input_from_text`, `bridge_tmux_codex_post_paste_is_clean`, `bridge_tmux_codex_submit_landed`, `bridge_tmux_type_and_submit`, `bridge_tmux_pending_attention_flush`, `bridge_tmux_claude_last_prompt_is_ghost_text`, `bridge_tmux_codex_last_prompt_is_placeholder`) and the 2 sites in `lib/bridge-agents.sh` (`bridge_agent_channel_diagnostics_text`, `bridge_list_active_agents_numbered`) are routed through `mktemp + printf … > $tmp + done < $tmp` with a per-function `trap RETURN` cleanup, per the wave-orchestration Footgun 11 recipe; (3) the top-level `agent-bridge` dispatcher skips the eager pre-dispatch `bridge_load_roster` for `status` / `daemon` / `agent` / `task` / `inbox` — each of those subcommands `exec`'s its own dispatch script which already loads the roster lazily on first use, so behavior is unchanged but startup wall time stays under 5s even when the roster is large and stale. Wave B (`bridge-daemon.sh` daemon-path heredoc-stdin sites), Wave C (`daemon_tick` freshness watchdog semantics), and Wave D (regression smoke fixture) stay pending — issue #815 remains open until all four waves land.
- **`daemon_tick` freshness as a first-class health signal + auto-repair on silent-but-alive — Wave C of issue #815** (refs #815 Wave C). Operator's live host had `state/daemon.heartbeat` stuck at `2026-05-13T07:30:05+09:00` for 18h while `agb daemon status` still reported a live pid — symptom of the daemon being alive but silent. Wave A + Wave B fixed the *structural* wedge (Bash `heredoc_write` deadlocks in CLI / daemon paths); Wave C closes the *detection* gap so pid liveness is no longer the only health signal. Adds two helpers to `lib/bridge-state.sh`: `bridge_daemon_heartbeat_age_seconds` (reads `state/daemon.heartbeat`, parses both bare-epoch and ISO-string formats, returns age in seconds) and `bridge_daemon_health_signal` (emits `tick_age_seconds=` / `tick_fresh=` / `health=ok|silent|down` key=value lines derived from pid liveness × tick freshness with threshold `BRIDGE_DAEMON_TICK_FRESH_SECONDS` defaulting to 120s — 2× the daemon's 60s tick cadence, so stale after 2 missed ticks). `agb daemon status` consumes the helper and adds an additive single-line `health: ...` summary alongside the existing grep-grammar fields (existing parsers keying off `running pid=` / `stopped` are unaffected). `agb daemon start` detects pid-alive-but-tick-stale and runs an auto-repair sequence (`kill -TERM` with 5s grace then `kill -KILL`, stop silence watchdog cleanly, remove stale pid + heartbeat, fall through to fresh start) instead of the prior "already running" no-op. The repair path is audit-logged (`daemon_start_repair_silent` + `daemon_start_repair_silent_killed`) and prints an explicit `[daemon] silent daemon detected (pid=N, tick stale by Ns) — repair sequence: kill + restart` line to stderr. New daemon emits one initial `daemon_tick` + writes `state/daemon.heartbeat` immediately at the top of `cmd_run` before the first sync cycle, so a `daemon stop && daemon start && daemon status` triple shows `health: ok` within 1s instead of waiting up to 60s for the first periodic boundary. The existing silence-watchdog active-repair branch (`bridge-watchdog-silence.py::attempt_restart` with cooldown via `read_cooldown` / `write_cooldown`) already satisfies the watchdog half of the acceptance criterion — no changes needed there. Wave D (destructive regression smoke fixture exercising stale dynamic envs + active patch / patch-dev + dynamic agents + large tmux captures) stays pending — issue #815 remains open until Wave D lands.
- **Daemon hot-path heredoc / here-string elimination — Wave B of issue #815** (refs #815 Wave B). Same deadlock class as Wave A, applied to `bridge-daemon.sh` so a fresh `agb daemon start` and every subsequent sync cycle never wedge in Bash `heredoc_write` while parsing analyzer captures, queue summaries, parsed-marker TSVs, or shell-formatted helper output. Wave B routes the 11 `while … done <<<"$text"` loops in `bridge-daemon.sh` (alert_rows + rotation_rows in `process_usage_monitor`, summary_output in `process_stall_reports` + `process_context_pressure_reports` + `process_on_demand_agents`, expired_rows in `process_permission_task_timeout_fanout`, parsed/pending_parsed in `_bridge_precompact_handle_started`/`_handle_completed`, ready_rows in `start_cron_dispatch_workers`, orphans_tsv in `process_memory_daily_orphan_sweep`, nudge_output in `cmd_sync_cycle`) through tempfiles via the Footgun 11 recipe (`mktemp + printf … > $tmp + done < $tmp` with `trap … RETURN` cleanup combined per scope — Bash allows only one RETURN trap per function). Replaces the 8 `source /dev/stdin <<<"$shell_output"` sites in the same file (analysis_shell in stall/context-pressure analyzers, open_task_shell in `nudge_agent_session`, route/render/send shell in the two precompact handlers) with `printf > $tmp + source "$tmp"` plus `# shellcheck disable=SC1090`. Routes the 2 `bridge_with_timeout … python3 … <<<"$capture"` analyzer invocations (`bridge-stall.py analyze`, `bridge-context-pressure.py analyze`) through `< file` to keep the multi-KB tmux-capture text off the here-string path. Converts the daily-backup hot-path state writer (`bridge_daily_backup_compose_state`, was `cat <<EOF`) to grouped `printf '%s\n'` so the cooldown-pinning success/failure/warn paths stop emitting a heredoc on every backup tick. Subprocess-timeout audit: confirms the analyzer + release-monitor + dashboard-post + cron-sync hot paths already pass through `bridge_with_timeout`; wraps two previously unwrapped daemon hot-path subprocesses — `bridge-sync.sh` (30s, called from `cmd_sync_cycle::bridge_sync` step) and `agent-bridge upgrade --check` (30s, called from `process_release_monitor` after a release alert resolves) — under `bridge_with_timeout` so a stuck child cannot freeze the loop. No behavior change: every site already absorbed empty / failure output (`|| true`, empty-string guards), so a tempfile-routed empty read takes the same path. Wave C (`daemon_tick` freshness watchdog semantics) and Wave D (regression smoke fixture) stay pending — issue #815 remains open until all four waves land.

## [0.11.0] — 2026-05-14

### Highlight — onboarding split (server vs dev), essential-default flip, wave-orchestration as admin default

Post-v0.10.0 follow-up wave (PR #809 / #811 / #812 / #813). Four PRs that together reshape the **operator experience after `bridge-init.sh`**: dev laptops and server hosts now diverge cleanly at the first init question, the two essentials operators kept forgetting to opt into (picker-sweep, prompt-guard) flip to default-enabled on hosted installs, and the admin agent's default workflow is now the parallel wave-orchestration pattern instead of sequential one-PR-at-a-time work. No CLI breakage, no `BRIDGE_HOME` migration step — every existing `state/install/host-profile.json` value is honored, and explicit env overrides (`BRIDGE_*_ENABLED=0`) still win in both directions.

### Changed

- **`memory-daily-<agent>` cron added to the profile=dev gated set** (refs Issue #713 follow-up). Until now the host-profile helper deliberately preserved `memory-daily-*` on every host on the rationale that long-term context harvesting is universally useful. Operator decision 2026-05-13 reverses that for dev hosts: Claude Code's own session-memory system (`~/.claude/projects/<repo>/memory/`) already covers the long-term-context use case on a developer laptop, so running the daily harvester is duplicative there. `BRIDGE_HOST_PROFILE_PRODUCTION_CRON_PREFIXES=("memory-daily-")` was added alongside the existing exact-name list, and `bridge_host_profile_list_production_crons` now matches both. Re-enable any time with `agb cron update memory-daily-<agent> --enable`. Server profile unchanged — memory-daily stays on hosted installs.
- **`wave-orchestration` skill is now the documented default workflow for admin agents** (refs PR #706). The bundled wave-orchestration skill already auto-distributes to every admin / dynamic agent's `.claude/skills/` via `bridge_bootstrap_claude_shared_skills`. The admin-pair-programming SOP managed block (`lib/bridge-admin-pair.sh:bridge_admin_pair_managed_block` + `bridge-upgrade.py:render_admin_pair_block`, byte-identical) now adds a "Default workflow — `wave-orchestration`" section after the existing 6-step plan/review loop. When the operator asks for a feature / fix / multi-issue ship, the admin agent defaults to parallel `wave` (2-4 issue-fixer dispatches into isolated worktrees with codex-pair review via queue or `codex:codex-rescue` subagent fallback) instead of sequential one-PR-at-a-time work. Single-track work still uses the original pair-programming protocol unchanged. `bridge-upgrade.py inject-admin-pair-block` re-renders on the next `agent-bridge upgrade --apply`, so existing installs converge automatically.
- **`bridge-init.sh` host_profile question moved before channel bootstrap; `dev` answer now also short-circuits channel setup and emits the heavy-feature advisory in one block** (refs Issue #713 follow-up). Previously `bridge_host_profile_run` fired after `Discord/Telegram/Teams/Mattermost` setup, so a developer-laptop install was forced to walk through (or `--skip-channel-setup` past) the channel branches before being told it could skip them. The question now runs immediately after admin-agent + `<admin>-dev` codex-pair materialization and immediately before the channel setup blocks; on `host_profile=dev` the call site flips `skip_channel_setup=1` and appends an init warning when the operator-passed `--channels` is non-empty (so the explicit channel csv is acknowledged rather than silently dropped). `bridge_host_profile_emit_dev_advisories` (new helper in `lib/bridge-host-profile.sh`) prints a unified "this is what dev profile skips" block: external-channel bootstrap, multi-tenant v2 isolation migration (stays opt-in via `agent-bridge migrate isolation-v2`), librarian / wiki-* maintenance crons (already disabled by the existing offer), and the operator's `--admin <name>` + `<name>-dev` static-pair-only floor (codex r2 round threaded `admin_agent` through the helper so the advisory renders the real pair names rather than the literal `patch`/`patch-dev` defaults; no extra static roles get auto-created — operators add them in `agent-roster.local.sh` when they upgrade to server). Server / CI / `--json` paths are unchanged: non-interactive still defaults to `server`, and `--reconfigure` still re-prompts. Idempotent against re-runs (the existing `[host-profile] already=…` sentinel still wins).
- **`BRIDGE_PICKER_SWEEP_ENABLED` and `BRIDGE_PROMPT_GUARD_ENABLED` defaults flipped to `1`; `host_profile=dev` opts both back out** (Track D follow-up to refs #713 / refs #809). Fresh hosted installs (`host_profile=server` or non-interactive default-server) now run picker-sweep and prompt-guard by default — they were essential-class features previously gated behind unwritten opt-in env vars. Explicit env overrides are unchanged: operators who set `BRIDGE_PICKER_SWEEP_ENABLED=0` / `BRIDGE_PROMPT_GUARD_ENABLED=0` still win, and operators on a dev host who want either feature can set the env to `=1` to override. Dev hosts (`host_profile=dev`) remain quiet by default — `bridge_host_profile_is_dev` (new helper in `lib/bridge-host-profile.sh`) gates the default-on at the runtime read site in `scripts/picker-sweep.sh`, `lib/bridge-guard.sh::bridge_prompt_guard_enabled_default`, and `bridge_guard_common.py::prompt_guard_enabled`. `bridge-init.sh` now auto-registers the `picker-sweep` bridge-native cron (`*/10 * * * *`, payload routed through the `<admin>-dev` codex pair per OPERATIONS.md §B to avoid the picker-via-Claude loop) on `host_profile=server` installs when no job titled `picker-sweep` is already present; idempotent on re-run. The new registration fires on fresh init / `agb init --reconfigure` only — existing installs without a `state/install/host-profile.json` do NOT get retroactive cron registration; operators must re-run init or set the env override manually. `bridge_host_profile_emit_dev_advisories` lists the two skipped essentials so dev operators see why their install is quiet by default. New helper file `lib/bridge-init-default-crons.sh` houses the auto-register so additional server-default crons stay scoped to one place.

### Internal — wave orchestration metadata

- 4 PRs landed in <6 hours of operator-clock-time, all squash-merged with `implement-ok` notes and codex-rescue pair-review (r1/r2/r3 chains as needed). Three of the four hit `needs-more` at r1 and converged at r2 (PR #809 admin_agent threading in advisory, PR #813 heredoc-stdin survival in registrar + outdated opt-in docs); PR #812 reached r3 on a docstring/code drift catch.
- `wave-orchestration` skill `references/footguns.md` gained a new entry — **Footgun 11: Bash heredoc / here-string deadlock against a slow consumer** (PR #811). Codifies the #800 `python3 - <<'PY'` root cause + the 2026-05-13 `<<<"$var"` recurrence into a single brief-template recipe (`mktemp + < file`). Skill documentation only; no runtime change. Already paid off in this same cycle — PR #813 r1 needs-more cited the new footgun entry verbatim when the registrar still piped its python script via heredoc-stdin.
- Issue #810 filed — `credential helper: close the same-UID FS readability residual from #799 (Path A')`. Design seed for the residual `KNOWN_ISSUES.md §25` defense-in-depth limit (deliberate `Path.home()` enumeration in agent-controllable interpreter code). Brainstorm-pending; not an implementation issue.

## [0.10.0] — 2026-05-13

### Highlight — credential file delivery + daemon hang fixes + worktree doctor

This release cycle (PR #799/#801/#802 + #803/#804/#805/#806/#807) landed 8 PRs across credential isolation, daemon timeout hardening, and operational surface. Headline: PR #799 closed the env-injection credential leak class (Path A architecture, 5-round codex review chain ending at AST-audited exhaustive enumeration of remaining final-path operations). PR #801 + #806 structurally eliminated the `$(python3 - <<'PY')` heredoc-write deadlock class across the daemon main loop (#800 root cause + parallel-PR regression). PR #807 ships `agent-bridge worktree doctor` for safe stale-worktree cleanup with repo-level stash-safety guard.

### Added — new user-facing surface

- **`agent-bridge auth claude-token` subcommand** (PR #799): per-agent Claude OAuth token registry with rotation, quota recovery, and file-based credential delivery. Token written to per-agent `~/.claude/.credentials.json` (NOT env-injected); rotation atomic via `write_private_file_atomic` with chown-before-replace + `_ensure_claude_dir_safe` parent symlink check. `fcntl.flock` `registry_lock` makes concurrent rotate/recover/check safe across daemon + manual CLI. New fcntl-locked `claude-oauth-tokens.json` registry under `$BRIDGE_RUNTIME_SECRETS_DIR`.
- **Watchdog canonical install** (PR #802): `scripts/install-watchdog-silence-launchagent.sh` (macOS, KeepAlive=true + RunAtLoad=true) + `scripts/install-watchdog-silence-systemd.sh` (Linux, Type=simple Restart=always). Both wired into `bridge-bootstrap.sh` alongside daemon-liveness install. `DAEMON_SCRIPT` default now resolves via env override → `$BRIDGE_HOME/bridge-daemon.sh` → `~/.agent-bridge/bridge-daemon.sh` → `SCRIPT_DIR` (last-resort dev fallback with explicit warning). `state/silence-watchdog.pidlock` (fcntl) blocks concurrent run.
- **`agent-bridge watchdog cleanup-orphans`** (PR #802): reaps watchdog instances with ppid=1 + script path outside canonical allow-list. Validated against 10 orphan instances on operator host.
- **`agent-bridge worktree doctor [--dry-run|--apply|--max-age-days|--target-branch|--include-stale|--prune-branches|--repo]`** (PR #807): stale worktree cleanup with repo-level stash-safety guard. Default `--dry-run`. Stash present anywhere in repo blocks all removals (load-bearing — `feedback_worktree_stash_shared_git_dir.md`).
- **`bridge-daemon-helpers.py`** (PR #801, expanded PR #806): 13 subcommands corresponding to the daemon's parsing/lookup callsites. Replaces `$(python3 - <<'PY')` heredoc-stdin pattern that was the root cause of the 34h silent daemon hang in #800.

### Fixed — daemon hang / heredoc deadlock class

- **34-hour silent daemon hang root cause** (PR #801, refs #800 Track A, refs #265 Proposal A): 9 unwrapped `$(python3 - <<'PY')` callsites in `bridge-daemon.sh` moved out of heredoc-stdin into `bridge-daemon-helpers.py` subcommands. Each wrapped in `bridge_with_timeout <secs> <label>` with per-site budget (5s JSON-only / 15s nudge_live_state hot path / 60s daily-backup). Highest-impact site (`nudge_live_state`) has explicit per-agent `skip_this_tick` audit-only fallback — sibling agents continue. Smoke fixture (`scripts/smoke/daemon-heredoc-timeout.sh`) exercises real subcommand bodies via FIFO + sqlite EXCLUSIVE lock stall vectors (the actual #800 hang class).
- **PR #799 introduced 4 NEW heredoc regression sites** (PR #806): PR #799's cron auth + token rotation/recovery paths were developed in parallel with PR #801 and missed the #800 wrapping convention. PR #806 wrapped the four new sites (`usage_rotation_candidates_parse`, `rotation_status_parse`, `recovery_status_parse`, `sync_status_parse`) using same Pattern A helper subcommand. Plus 2 library sites in `lib/bridge-core.sh` (`core_match`) and `lib/bridge-skills.sh` (`skills_resolve_target`) wrapped with Pattern B (`python3 -c "$SCRIPT"` here-string variable). Registry now 13 entries.

### Fixed — Claude OAuth credential isolation (Path A)

- **`CLAUDE_CODE_OAUTH_TOKEN` env-injection leak class** (PR #799 r1-r5 chain, refs `feedback_credential_env_injection_anti_pattern.md`): credential delivery moved from `launch-secrets.env` env injection to per-agent `~/.claude/.credentials.json` file. Path B (hook-deny defense-in-depth) ESCALATE recommendation from codex r3 led to architecture pivot. Now: tool execution UID can still read its own credential file (Finding 1 same-UID FS readability residual — documented in `KNOWN_ISSUES.md §25` with credential-helper pattern noted as planned future enhancement), but no interpreter `os.environ` / `%ENV` / `ENV[]` leak. Hook deny rules from r2-r3 retained as belt-and-suspenders.
- **Symlink-attack hardening** (PR #799 r2): bash `bridge_auth_claude_credentials_file_for_agent` + Python `_ensure_claude_dir_safe` reject symlinked `.claude/` dirs. `cd -P` real-path verification requires resolved path to stay under isolated user home. macOS `/var` ↔ `/private/var` prefix mismatch handled.
- **Rotation atomicity** (PR #799 r2): `write_private_file_atomic` chowns tempfile to isolated UID BEFORE `os.replace` (NOT after — that was the r1 race). Removed post-replace chmod (r5 redundancy elimination — `rename(2)` preserves mode bits via inode rename).
- **`bridge-cron-runner.py` 401 on claude -p** (PR #799): runner now resolves per-agent `CLAUDE_CONFIG_DIR` from `launch-secrets.env`. Previously fell back to controller default `~/.claude` and hit 401 even while interactive sessions worked.

### Fixed — operational hardening

- **`bridge_with_timeout` self-defeat on bare macOS** (PR #804, refs PR #802 r2 caveat): wrapper relied on `timeout(1)`/`gtimeout(1)`; bare macOS without GNU coreutils ran wrapped command unwrapped. Added tier-2 Python `subprocess.run(timeout=)` fallback using `python3 -c "$SCRIPT"` here-string pattern (NOT heredoc-stdin). 3-tier chain: timeout(1) → python3 → unwrapped exec (last resort). Tier-3 audit wrapped in subshell `(...) || true` to contain `bridge_require_python` exit when python3 is also missing.
- **Channel runtime readiness false-negative** (PR #803, refs #779): `bridge_agent_channel_runtime_ready_for_item` now does LISTEN port probe after file/env-key checks. `bridge_port_is_listening` helper (Linux `ss` + macOS `lsof` portable, fail-open on minimal hosts). Teams branch only — discord/telegram outbound, ms365 shares teams listener. Legacy roster (no `TEAMS_WEBHOOK_PORT`) preserved via empty-port short-circuit.
- **`agent-bridge show --json alive=null`** when tmux session absent (PR #805, refs #780): multi-signal OR — tmux session OR `agents/<X>/runtime/agent.pid` alive OR channel LISTEN. Existing `active` field preserved unchanged for backwards compat; new `alive` + `alive_signals` fields surface in `--json`.
- **CI smoke v0.8.0 isolation-v2 marker noise** (PR #799 Wave 1, indirect): `scripts/smoke/lib.sh:smoke_setup_bridge_home` writes `$BRIDGE_STATE_DIR/layout-marker.sh` with `BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT`. Resolved the markerless(existing-install) abort that was masking real regressions across PR #799 r1-era CI runs.

### Process — codex pair-review chains this cycle

- **PR #799 — 5-round Path A cycle** (after 3-round Path B abandonment): r1 same-UID accepted residual + symlink + chown race → r2 symlink/atomic fix → r3 drop bash legacy helper → r4 drop Python unchanged-content fast paths → r5 drop redundant post-replace chmod. r5 codex AST-walker independent audit matched fixer's enumeration exactly (6 final-path chmod/chown calls all in allow-listed context: 3 in save_registry controller-owned, 1 in probe_claude_token sandboxed tempdir, 2 in write_private_file_atomic tempfile pre-replace). Convergent-pattern technical-override of 4-round cap policy — documented in `project_pr799_path_a_shipped.md`.
- **PR #801 — r1 smoke-fixture-realism finding**: codex r1 audit confirmed production code correctness (path resolution, no-stdin contract, arg order, per-agent nudge skip) but flagged smoke harness used synthetic helpers. r2 extended smoke with real subcommand stall vectors (FIFO no-writer for `mcp_orphan_cleanup_parse` blocking `Path.read_text()`, sqlite `BEGIN EXCLUSIVE` for `nudge_live_state` blocking `sqlite3.connect.execute`). Smoke now legitimately catches the production hang class.
- **PR #802 — r2 SCRIPT_DIR silent-fallback BLOCKING**: codex r1 caught that fallback chain's SCRIPT_DIR last-resort returned without warning — exactly the failure mode #800 Track C was fixing. r2 added explicit warning before SCRIPT_DIR fallback return. Documented caveat about `bridge_with_timeout` PATH dependency carried over to PR #804.
- **PR #806 catches regression class**: PR #799 + PR #801 developed in parallel against same base; PR #799 added 4 NEW heredoc-stdin sites that PR #801's audit had no visibility into. PR #806 was the audit follow-up. Pattern worth flagging: **parallel PR development on same surface needs cross-PR audit before merge or immediate follow-up after merge**.

### Internal — wave orchestration metadata

- 8 PRs landed across this release cycle in <5 hours of operator-clock-time, all squash-merged with structured `implement-ok` notes and codex-rescue pair-review.
- New fixer footgun discovered: **Edit/Write tool CWD pollution**. Track F fixer's first round of edits landed in operator's primary checkout instead of own fixer worktree (Edit tool with parent-process CWD on operator path). Worktree-relative absolute paths now mandatory in fixer briefs.
- New runtime footgun discovered: **Bash 5.3.9 here-string heredoc-write deadlock**. `<<<"$porcelain"` into multi-record read loop deadlocks in `heredoc_write` — same #800 class. Workaround: `mktemp + < file`.

### Carry-over to next cycle

- Finding 1 (same-UID FS readability) — `KNOWN_ISSUES.md §25` notes credential-helper / separate Claude launcher identity as planned future enhancement.
- One-shot script heredoc sites (`bridge-intake.sh`, `bridge-bootstrap.sh`, `bridge-bundle.sh`, `scripts/wiki-daily-ingest.sh`, `scripts/repair-task-db.sh`, `scripts/export-public-snapshot.sh`) still use heredoc-stdin pattern. Lower priority than daemon main-loop sites; tracked for future audit pass.
- Worktree doctor stash-safety policy refuses all removal when ANY stash present — operator's current checkout has 5 in-flight stashes blocking cleanup of 156 stale fixer worktrees. Resolve stashes (or use git stash drop for known-stale ones) to enable cleanup.

## [0.9.9] — 2026-05-11

### Highlight — every-upgrade isolated-UID breakage fixed (#792 CRITICAL hotfix)

`scripts/deploy-live-install.sh` was using `cp -p` which preserved source-tree perms (0700 for shell scripts, 0600 for libs/hooks). Every `agent-bridge upgrade --apply` broke isolated-UID agents on next restart with a cascading 6-symptom failure list (bridge-run.sh EACCES, lib/hook unreadable, marketplace.json PermissionError, plugins/ms365/bun.lock install-failed, .credentials.json ACL mask cancellation, .env mask cancellation). Operators were applying a 6-point manual chmod+setfacl recovery after every upgrade. Fixed in PR #796 via per-file-class mode contract + post-deploy critical-perm verification.

### Fixed

- **`scripts/deploy-live-install.sh` strips perms on every upgrade** (PR #796, refs #792): replaced bare `cp -p` with `cp -p` + per-file-class chmod (`deploy_live_install_set_mode` helper). Added post-deploy `deploy_live_install_verify_critical_perms` sanity sweep with cross-platform stat (GNU `%a` + BSD `%Lp`). Non-fatal warning preserves operator recovery path. Per-class matrix: bridge-*.sh/agent-bridge/agb/hooks 0755, lib/marketplace.json/plugins-*.json 0644. ACL mask restore for `~/.claude/.credentials.json` and per-agent `.env` is documented out-of-scope (those live outside `$TARGET_ROOT`, handled in `lib/bridge-isolation-v2.sh` grant matrix).
- **`bridge-upgrade.py:create_daily_backup_archive` aborts whole archive on isolated-UID EACCES** (PR #794, refs #785): per-member catch on `os.lstat` and `archive.add` for both `PermissionError` and raw `OSError(errno=EACCES)`. `skipped_isolated` list (bounded 50 + truncation marker + last 10 when len > 60) propagates to `result["skipped_isolated_count"]` AND `cmd_daily_backup_live` CLI JSON payload. Snapshot loop got the same defensive guard. Pattern mirrors existing `agent_migration` precedent.
- **Orphan `memory-daily-<agent>` cron jobs never garbage-collected** (PR #797, refs #791): new `process_memory_daily_orphan_sweep` helper in `bridge-daemon.sh`. Each sync pass enumerates `family=memory-daily` cron jobs, cross-checks source agent against `BRIDGE_AGENT_IDS`, emits ONE `[health]` task per UTC day per orphan group with body listing `agent-bridge cron delete <job-id>` suggestions. Marker file at `$BRIDGE_STATE_DIR/memory-daily-orphan-sweep/<UTC-day>.surfaced` suppresses re-emit. Idempotent — does NOT auto-disable jobs (operator's explicit Option A preference). Mock unit test at `scripts/test-memory-daily-orphan-sweep.sh` (282 LOC, 16 assertions × 4 scenarios).
- **MS365 plugin state-dir not canonicalized on launch** (PR #790, refs #786): `bridge_claude_launch_with_channel_state_dirs` (`lib/bridge-state.sh`) now canonicalizes `MS365_STATE_DIR` alongside existing Discord/Telegram/Teams. Frozen-roster `launch_cmd` with stale pre-v2 `MS365_STATE_DIR=…/agents/<X>/.ms365` (under 2750 SetGID parent) gets rewritten to canonical `agents/<X>/workdir/.ms365` (under 2770 ab-agent-X group). Plus 3-round codex catch: duplicate-vector dedupe (multiple stale STATE_DIR spans collapse to one canonical) + surgical separator strip at drop site (preserves quoted multi-space content in non-target env values like `OTHER="a  b"`). Symmetric across all 4 channel state VARs.
- **Controller watcher times out before Claude foreground** (PR #793): split `bridge_start_schedule_dev_channels_accept` budget into foreground gate (`BRIDGE_START_DEV_CHANNELS_CLAUDE_FOREGROUND_TIMEOUT_SECONDS`, default 600s — waits for tmux pane foreground to become `claude`) and existing 60s accept window. On cold-plugin-cache restarts where `bridge-run.sh` runs `bridge_run_sync_dev_plugin_cache` for 3-5min before `exec claude`, the prior single 60s budget burned down before Claude even started. Plus in-loop `bridge_tmux_session_exists` check inside `bridge_tmux_wait_for_claude_foreground` so a hard plugin-cache failure that exits the tmux session mid-wait returns rc=1 promptly instead of polling the full budget. New runtime smoke `tests/tmux-wait-foreground-liveness/smoke.sh` covers the session-liveness path.

### Added

- **`scripts/picker-sweep.sh` — opt-in auto-unstick utility for stuck Claude Code pickers** (PR #664, SYRS-AI fork contribution): scans every tmux session, detects rate-limit / resume-from-summary pickers via closed-pattern allow-list, sends Enter on default option. Default disabled (`BRIDGE_PICKER_SWEEP_ENABLED=0`); operators opt in via OS crontab or bridge-native cron. Strict line-anchored regex requires both `_PICKER_OPTION_LINE_RE` AND (optionally for log diagnostic) `_PICKER_TAIL_RE` to match — defends against false-positives from PR bodies / docs / logs that quote picker text. Test seams allow `scripts/smoke/picker-sweep.sh` to exercise with mock tmux + mock queue. See `OPERATIONS.md` "picker-sweep utility" for registration paths.

### Hygiene

- **SC2088 false-positive in `bridge_expand_user_path`** (PR #795 Track D): replaced `'~/'*) printf '%s%s' "$HOME" "${raw#\~}"` with `\~/*) printf '%s%s' "$HOME" "${raw:1}"` — byte-equivalent across 8 inputs, shellcheck-clean. The case pattern `'~/'*` (tilde inside quotes) was triggering SC2088 since v0.9.6 push, blocking all gated CI checks (integration smoke, legacy-full-smoke, live/tmux/daemon smoke, unit/static smoke) for 4 consecutive release pushes. v0.9.9 is the first release with green lint since v0.9.5.

### Process — codex-rescue caught 3 BLOCKING vectors this cycle

- **PR #790 r1**: duplicate STATE_DIR spans → 2 canonical entries. Inherited from a latent main-branch bug; PR #790 just exposed it for MS365. r2 dedupe.
- **PR #790 r2**: global `re.sub(r" {2,}", " ", env_prefix)` cleanup mangled quoted multi-space env values. r3 surgical drop-site strip.
- **PR #797 r1**: call-site wiring `|| true` silent-swallow instead of `|| daemon_warn`. r2 wiring fix + tracked unit test.

All 3 vectors were quote/substitution semantic issues that fresh-install probes would have missed. Pattern matches the v0.9.5-v0.9.8 "operator-host artifact reproducer required" lesson — now baked into review brief template.

### Internal

- Wave orchestration pattern (per `~/.claude/skills/wave-orchestration/`): 4 fixers + 3 codex reviews dispatched in parallel; 5 squash-merges + 2 codex iteration cycles + 1 fork-side merge conflict resolution + 1 cross-account auth dance (SYRS-AI fork PR), all without operator interaction.

## [0.9.8] — 2026-05-10

### Highlight — v0.9.7 carry-over (#786): RC6 ms365 leak + memory-daily aggregate

운영자가 v0.9.7 ship 후 production 검증에서 발견한 2 finding (#786) 모두 fix. v0.9.5 → v0.9.6 → v0.9.7 → v0.9.8 cycle 의 같은 architectural 패턴 반복 (operator host 의 v1-isolation leftover artifact 가 codex review 의 fresh-install reproducer 로 재현 안 됨) 을 review brief 자체에 lesson 강제 적용 — focus item #1 = "operator's exact production state reproducer".

### Process — review brief 가 operator-host artifact reproducer 의무 명시

운영자 frustration: "왜 계속 같은 문제 반복돼.. 해결되기 전까지 무제한 리뷰 하도록 해". v0.9.5/v0.9.6/v0.9.7 process lesson (release-PR review brief 에 operator's actual production state reproducer 명시) 가 매 release 후 lesson 으로 기록만 되고 다음 release brief 작성 시 누락. v0.9.8 부터 review brief 가 처음부터 operator-host artifact inventory 명시:

- v1-isolation leftover symlinks (`source/<plugin>/node_modules → /controller/cache/...`)
- pre-v2 `installPath` in `installed_plugins.json`
- 운영자 ad-hoc workaround state (chmod 2770, named-user ACL grants)

이 강제 효과: PR #787 r1 catch (intra-marketplace symlink) 와 PR #788 r1-r4 catches (chmod, symlink exfiltration, TOCTOU race, JSON validation) 모두 lesson 적용 후 codex 가 catch. 이전 cycle 에서는 catch 못 했을 vector.

### Fixed (#787 — RC6 ms365 leak, refs #786 Finding 1)

- `bridge-dev-plugin-cache.py:overlay_source_to_cache` + `_overlay_dir` — symlink-to-outside-marketplace detect + skip + WARN. operator host 의 v0.7→v0.8 isolation migration leftover (`source/ms365/node_modules → /home/ec2-user/.claude/plugins/cache/...`) 가 isolated UID 권한으로 read 시도 → `PermissionError: [Errno 13]` → ms365 sync `install-failed`. v0.9.7 이 다른 3 plugin (teams, cosmax-crm, cosmax-ep-approval) 는 작동했지만 ms365 만 silent fail.
- 2-round codex destructive-probe: r1 catch — `source_root = source_path.resolve()` boundary 가 너무 narrow (plugin-specific path), intra-marketplace `node_modules → ../dist` 를 outside-source 로 잘못 분류. r2 fix — caller chain 으로 marketplace root 전달, marketplace boundary 사용.

### Fixed (#788 — memory-daily aggregate matrix vs harvester mismatch, refs #786 Finding 2)

- `scripts/memory-daily-harvest.sh` — isolated UID 시 `--shared-aggregate-dir` 안 넘김 (per-agent fragment 만 쓰도록). 이전엔 isolated UID 가 controller-only `aggregate/` 에 직접 write 시도 → EACCES.
- `scripts/memory-daily-reduce.sh` (NEW) — controller-side reducer. agents/<X>/runtime/memory-daily/*.json fragment → admin-aggregate-<agent>-<date>.json. operator 가 controller crontab 에 wire (v0.9.9 에서 자동 등록 검토).
- `lib/bridge-isolation-v2.sh:bridge_isolation_v2_memory_daily_shared_aggregate_dir` — self-contradicting comment fix. 매트릭스 row 가 design A (r-x for isolated UIDs) binding 이라고 명확.
- 4-round codex destructive-probe (security-heavy):
  - r1: cp -p preserved fragment mode (0660) vs aggregate contract (0640) → drop -p + explicit chmod 0640
  - r2 BLOCKING: symlink fragment 가 controller secret 으로의 path-traversal exfiltration vector → 3 defense layer (reject symlink agent_dir, reject symlink fragment, cp -P TOCTOU defense)
  - r3 BLOCKING: TOCTOU race 후 Layer 2 [[ -L ]] check 사이 swap 가능 → post-cp [[ -f && ! -L ]] re-check + JSON parse gate
  - r4 implement-ok: 8/8 probes PASS (TOCTOU swap blocked, malformed JSON rejected, valid JSON published, mode 0640, group ab-shared 보존)

### Verified (operator-host artifact + canonical state)

- operator's exact ms365 leftover artifact (`source/ms365/node_modules → /controller/cache/...`) → cache materializes without node_modules + WARN
- intra-marketplace symlink (e.g. `node_modules → ../dist`) → cache recurses + materializes
- agent-controlled symlink fragment exfiltration vector → blocked at Layer 2
- TOCTOU race attack on symlink check → blocked at Layer 4 (post-cp)
- malformed JSON fragment → rejected at Layer 5 (JSON parse gate)
- aggregate file mode 0640 + ab-shared group inheritance from setgid parent
- chmod 2770 운영자 workaround state coexists with new harvester (no regression)

### Known carry-over (v0.9.9 트랙 후보)

- `installed_plugins.json` rewrite ordering (#786 suggested fix item 3 — 이번 PR 는 cache materialization 만 fix; pre-v2 installPath 가 cache fail 시 안 고쳐지는 것은 별도)
- v1-isolation cleanup helper — `agent-bridge upgrade --apply` 가 `source/<plugin>/node_modules → /controller/...` symlink 을 자동 detect + remove (currently operator manual `rm`)
- memory-daily reducer 의 cron 자동 등록 (`bridge-cron.sh` 에 controller-side cron job)
- design v2 §"Per-Agent Cache Tradeoffs" content-addressed package store proposal

## [0.9.7] — 2026-05-10

### Highlight — v0.9.6 verification surfaced 6 RCs → unified isolation grant matrix

운영자의 v0.9.6 검증 후 후속으로 RC1-RC6 (#781) 발견. 모두 같은 architectural gap — isolated agent's required-access matrix 가 single contract 가 아니어서 path 마다 ad-hoc grant 가 다른 mechanism (group, named ACL, mode) 으로 흩어져 있었음. v0.9.7 은 이를 single isolation-grant-matrix 로 통합:

| # | Symptom | Mechanism (v0.9.7) |
|---|---|---|
| RC1 | `state/agents/<X>/` group `ab-controller` (v2 contract violation) | matrix row enforces `ab-agent-<X>` + setgid 2770 |
| RC2 | `idle-since` controller-owned 0600, isolated hook unlink fail | new `bridge_isolation_v2_write_agent_state_marker` route, group-aware writer |
| RC3 | `~/.claude/.credentials.json` ACL `mask::---` wipe → `/login` infinite loop | single named-user ACL exception (Anthropic credential), path guard prevents v0.9.5/v0.9.6 mask-break recurrence, multi-agent roster-aware grant + strip |
| RC4 | `runtime/` not traversable | matrix row `agent-runtime` covers |
| RC5 | `logs/` not traversable | matrix row `agent-logs` covers |
| RC6 | `dev-plugin-cache` "linked OK" 거짓 success log + ms365 cache dir 부재 | `bridge-dev-plugin-cache.py` pre-link assert + post-link verify under isolated UID + per-agent isolated cache (real directory copy, NOT symlink to shared source) + criticality split (channel-required block / optional warn-and-continue) |

운영자 binding principle (per design v2): 각 isolated agent 가 **자기 plugin 자기 install 자기 login** — cross-agent 간섭 방지. shared cache 자체가 간섭 매개라 per-agent isolated cache 필수. disk overhead 100-300MB / agent 감수 (4 agents = 400MB-2GB).

### Process — codex destructive-probe 22 round (operator-authorized round-cap waiver)

운영자 자율 위임: "캡 같은거 필요 없어 될떄까지 완전하게 완료해" + "내가 자고 일어나면 다 되어 있어야해". CLAUDE.md 의 3-round cap 명시적 waiver. PR #782 16 round + PR #783 6 round = 총 22 round. 각 round 가 새 vector catch:

**PR #782 (matrix foundation + RC1-RC5, 16 round):**
- r1-r6: RC3 helper deep-dive (mode → owner+group → mask → named-user → ancestor → other → file_mode → apply/check sym → Linux stat group_class quirk)
- r7: 1 BLOCK + 2 WARN (strict r--, stale strip, effective annotation parse)
- r8-r10: helper hard-fail + reapply wrapper exit propagation + 2 other matrix-apply callers `|| true` swallow
- r11: RC3 multi-agent + write_marker + hook stderr
- r12-r13: load reapply.sh + (g) all-roster check + drop daemon writer fallbacks (5 writers total) + r12 path bug
- r14-r15: webhook ensure + chmod 0660 + daemon audit visibility + synthetic marker rc + scrub guard order + legacy `--help`
- r16: next-session.sha path divergence (Python hook write vs bash reader)

**PR #783 (RC6 + per-agent cache + criticality, 6 round):**
- r1: symlink-to-source = cross-agent collision (operator binding principle violation)
- r2: real directory copy + 4-branch unification (3 BUG)
- r3: self-contained per-agent (node_modules 포함) + chmod 0700 + derive node_modules_status from cache
- r4: symlink-to-dir handling (is_dir() first) + parent chmod 0700
- r5-r6: channel-required wins both-lists + _is_required_channel decision tree fix

각 round 의 fix 가 v0.9.5/v0.9.6 false-positive 가 운영자 host 에서 재발할 수 있는 vector. 운영자 자율위임 ROI: 22 round 는 release 후 hotfix cycle 보다 훨씬 싸다.

### Fixed (#782 + #783 — refs #781)

- **`lib/bridge-isolation-v2.sh`** — new `bridge_isolation_v2_matrix_rows_for_agent` enumerator (18 rows from design v2 + 4 plugin rows = 22 total), `bridge_isolation_v2_apply_grant_matrix_for_agent` (apply/check), `bridge_isolation_v2_apply_row` per-row dispatcher, `bridge_isolation_v2_ensure_matrix_path` for daemon writers, `bridge_isolation_v2_write_agent_state_marker` atomic write, `bridge_isolation_v2_apply_controller_credentials_read_grant` + `bridge_isolation_v2_check_controller_credentials_read_grant` (RC3 single exception, multi-agent roster-aware, all 5 ACL conditions enforced + (f)(g) roster checks). Path guard in `bridge_isolation_v2_acl_scrub` (RC3 recurrence prevention) + scrub file-path refusal.
- **`lib/bridge-isolation-v2-migrate.sh`** — `bridge_isolation_v2_migrate_normalize_layout` propagates matrix-apply failure (was `|| true`).
- **`lib/bridge-isolation-v2-reapply.sh`** — `bridge_isolation_v2_reapply_one_agent` consumes matrix rows; dispatch wrapper accumulates per-agent errors → non-zero exit. action label `error:matrix_apply_failed` (was `warn:matrix_partial`).
- **`lib/bridge-agents.sh`** — `bridge_linux_prepare_agent_isolation` propagates matrix apply failure.
- **`lib/bridge-state.sh`** — daemon writers (`mark_idle_now`, `mark_manual_stop`, `note_prompt_ready`) route through matrix-aware writer + drop direct-write fallback. `bridge_agent_next_session_marker_file` aligned with Python hook path (state/agents/<X>/, was runtime/).
- **`lib/bridge-channels.sh`** — webhook-port + missing-marker retry writers + ensure_matrix_path now hard-fail. synthetic marker call propagates rc.
- **`lib/bridge-notify.sh`** — `bridge_claude_session_try_mark_prompt_ready` propagates mark_idle_now rc.
- **`bridge-daemon.sh`** — nudge_scan step emits `daemon_step_warning` audit on idle-ready writer failure.
- **`bridge-dev-plugin-cache.py`** — RC6 pre-link assertion + post-link verify under isolated UID, per-agent real directory cache (no shared symlink), node_modules included in copy, chmod 0700 on every cache + parent dir, criticality split (channel-required block / optional warn).
- **`bridge-run.sh`** — Python exit code propagation for criticality split.
- **`agent-bridge`** — new `isolation verify --agent <X> [--json] [--strict-optional]` subcommand. Pre-source bypass for `isolation verify --help` (operator can read syntax on legacy/markerless installs).
- **`hooks/bridge_hook_common.py`** — next-session.sha writer emits stderr WARN on OSError (no longer silent return None) + uses bridge_active_agent_dir() (matches bash reader after r16).
- **`bridge-lib.sh`** — sources `bridge-isolation-v2-reapply.sh` so `reapply_eligible_agents` is available to all v2 helpers (not just bridge-migrate.sh).

### Verified (codex destructive-probe + operator-state reproducer)

- 모든 6 RC 가 operator's RC1-5 workaround state 에서 single `migrate isolation v2 --apply` 한 번으로 canonical state 로 converge.
- `agent-bridge isolation verify --agent <X>` 가 모든 22 row 에 대해 pass/mismatch/not-applicable 정확히 분류.
- multi-agent (4 agent) 시나리오: 각 agent 가 own plugin 자기 install + own login + own credential, cross-agent interference 0.
- per-agent cache disk overhead measured ~200-400MB/agent for typical bridge plugin set.

### Process lessons (carry forward to v0.9.8+)

1. **release-PR codex review brief 에 operator's current production state reproducer 의무화** (v0.9.6 lesson 적용). orbstack 검증이 fresh-setup 만 다루면 frozen-roster 같은 actual state 놓침.
2. **각 round 의 catch 가 새 vector 면 5+ round 정당화**. 동일 vector 반복이면 cap 적용. PR #782 16 round, PR #783 6 round 모두 each catch new vector 였음.
3. **apply/check symmetry 가 architectural concern**. 한 path 에서 hard-fail propagation 추가하면 모든 caller chain 에서 swallow 안 되도록 sweep 필요. PR #782 r9-r15 가 정확히 이 sweep.

### Known carry-over (v0.9.8 트랙 후보)

- `bridge-upgrade.sh` 의 path guard / convergence 정밀 검증 (PR 3 deferred — operator host 검증 후 hotfix 가능)
- `scripts/oss-preflight.sh` orbstack reproducer with operator-actual production state
- `docs/agent-runtime/v2-isolation-migration.md` 22-row matrix 문서화
- `KNOWN_ISSUES.md` v0.9.5/v0.9.6 false-positive 패턴 lessons
- design v2 §"Per-Agent Cache Tradeoffs" 의 future content-addressed package store proposal (cross-agent dedup without shared mutable state)

## [0.9.6] — 2026-05-09

### Highlight — REAL #771 fix (v0.9.5 was a false-positive on frozen-roster)

`v0.9.5` 의 `bridge_write_linux_agent_env_file` regen call 은 운영자의 R5 진단으로 **false-positive** 확인. Linux 서버에서 `migrate isolation v2 --apply` 후 `cat agents/<X>/runtime/agent-env.sh | grep TEAMS_STATE_DIR` 가 여전히 stale `…/agents/<X>/.teams` (pre-v2 path) 반환. log 는 `agent_env_regen ok` 라고 했지만 실제 파일 내용은 안 바뀜.

진단 결과 root cause 는 `lib/bridge-state.sh` 의 `bridge_claude_launch_with_channel_state_dirs` helper. 이 함수는 launch 시점에 cached `BRIDGE_AGENT_LAUNCH_CMD[$agent]` 의 env-prefix 에 canonical `TEAMS_STATE_DIR` / `MS365_STATE_DIR` / `DISCORD_STATE_DIR` / `TELEGRAM_STATE_DIR` 를 주입하는 것이 책임이지만, 기존 loop 가:

```python
for name, value in assignments:
    if f"{name}=" in env_prefix:
        continue       # ← BUG: name 만 보고 skip → stale value 보존
    env_prefix += f"{name}={shlex.quote(value)} "
```

처럼 `<NAME>=` substring 만 검사하고 SKIP. fresh-setup agent (env_prefix 비어 있음) 는 append branch 가 fire 해서 정상이지만, frozen-roster (v0.7→v0.8 migrate 시점에 cached 된 stale `TEAMS_STATE_DIR=…/agents/<X>/.teams`) 는 `name` 이 이미 존재해서 skip → 매 restart 마다 stale path 가 그대로 통과 → bun teams server.ts silent-exit before bind. v0.9.5 의 regen 은 cached file 를 새로 쓰지만 **새로 쓴 내용 자체가 같은 helper 를 통과해서 같은 stale path 를 다시 박아넣는 cycle** 이라 효과 없음. v0.9.5 orbstack 검증은 fresh-setup 만 exercise 했고 frozen-roster scenario miss.

Fix: skip 대신 **byte-preserving in-place replace**. 6 라운드 codex destructive-probe 로 다음을 모두 통과:

- top-level 만 매칭 (quote 안에 nested `NAME=…` substring 무영향)
- `$VAR` / `${VAR}` / `$(cmd)` / `` `cmd` `` expansion 보존 (관련 없는 token 의 expansion 안 죽임)
- `$()` / `` ` ` `` / `${}` 안에 `NAME=` 가 있어도 opaque value 로 처리 (literal `)` / `}` 가 나와도 close 안 봄)
- duplicate dedup (last-wins shell semantic 깨지지 않게 모든 occurrence 교체)
- 새 canonical value 는 `shlex.quote` 로 hard-quote (literal `$` 등 안전)

`agent-bridge upgrade --apply` + `migrate isolation v2 --apply` + agent restart 한 번 으로 자동 회복.

### Process — codex destructive-probe 6 라운드 (operator-authorized round-cap waiver)

운영자 자율 위임: "캡 같은거 필요 없어 될떄까지 완전하게 완료해". CLAUDE.md 의 3-round cap 명시적 waiver 후 6 라운드 진행. 각 라운드 모두 새 vector catch (마지막 2 라운드는 hardening, 처음 4 라운드는 production-relevant):

| 라운드 | codex catch | 분류 |
|---|---|---|
| r1 | skip-if-name-present false-positive | critical (operator hit) |
| r2 | regex global subn 가 quoted value 안의 nested NAME= 도 덮음 | production-relevant |
| r3 | shlex.split + shlex.quote round-trip 가 `$VAR` expansion 죽임 | production-relevant |
| r4 | byte-preserving walker 가 `$()` / `` ` ` `` / `${}` 안 봄 | production-relevant |
| r5 | `_skip_paren_subst` 가 `${...}` 안 honor → brace-default 의 literal `)` 로 paren 조기 close | hardening |
| r6 | `_skip_paren_subst` + `_skip_brace_subst` mutual-recurse 추가, `$/${/backtick` 모든 nesting opaque | hardening (closes surface) |

각 라운드의 fix 는 21 destructive probe matrix 로 bash-eval round-trip 검증 (Homebrew bash 5+). `frozen-roster motivating case → fresh setup → empty prefix → idempotent same-value → partial-name overlap → quoted-stale → value-with-space → duplicate dedup → quote-context (probe 9) → $VAR (10) → literal $ in new value (11) → backtick no NAME (12) → mixed quoting (13) → $() (14) → backtick (15) → ${} (16) → nested $() (17) → $() in dquote (18) → codex r5 reproducer (19) → ${} containing $() (20) → backtick in ${} (21)`.

### Process lesson — false-positive 의 의미

v0.9.5 가 false-positive 였던 이유는 orbstack 검증 시나리오가 fresh-setup 만 (= operator 가 리눅스 서버에서 한 번도 본 적 없는 상태) 다뤘기 때문. 운영 호스트의 frozen-roster 상태 (= operator 의 actual state) 를 재현 안 했음. 다음 release process 에는 release-PR codex review brief 에 "operator's current production state 를 reproducer 로 명시" 항목 추가 필요. v0.9.5 CHANGELOG 의 "Verified on Linux" 표는 fresh-setup row 로 한정 → frozen-roster row 추가했다면 release 전 catch 했을 것.

### Fixed (#776 — refs #771)

- `lib/bridge-state.sh:bridge_claude_launch_with_channel_state_dirs` — env-prefix 의 `<NAME>=value` assignment 를 quote-state-aware top-level walker 로 식별 후 byte-preserving in-place replace. 4 helper (`_skip_dquote`, `_skip_paren_subst`, `_skip_backtick`, `_skip_brace_subst`) mutual-recurse 로 nested substitution / quote 모두 opaque 처리. matching 안 된 token 의 raw bytes (포함 `$VAR` / `$()` / backtick 등 expansion) 그대로 통과. matching token 만 `f"{name}={shlex.quote(value)}"` 로 substitute (last-wins shell semantic 위해 모든 occurrence 교체).

### Verified on Linux (orbstack Oracle Linux 9)

| Test case | Original | Without fix | With v0.9.6 fix |
|---|---|---|---|
| Frozen-roster `TEAMS_STATE_DIR=/stale/.teams` | `/stale/.teams` | restart 시 stale 통과 | **`/workdir/.teams` 로 교체 ✓** |
| Fresh-setup (no existing TEAMS) | append OK | (regression-clean) | **append fires ✓** |
| Quoted-value 안 nested NAME= | (n/a) | global subn 이 nested 도 덮음 (r2 vector) | **opaque ✓** |
| `OTHER=$HOME` 와 같은 token | (n/a) | shlex round-trip 이 `'$HOME'` 으로 hard-quote (r3 vector) | **expansion 보존 ✓** |
| `$()` / backtick / `${}` 안 NAME= | (n/a) | walker 가 안 봄 (r4 vector) | **opaque ✓** |
| `${UNSET:-) NAME=...}` (literal `)`) | (n/a) | paren 조기 close (r5 vector) | **brace-default opaque ✓** |

### Known carry-over (v0.9.7 트랙 후보)

- **#772** Stop hook → agent-bridge CLI → mkdir BRIDGE_STATE_DIR denied (isolated uid). non-blocking 이지만 stderr spam.
- **#767** daemon inbox-nudge 폭주 (no dedup, no busy-aware gate).
- **runtime_ready false-positive**: `bridge_agent_channel_runtime_ready_for_item` 이 file/key presence 만 체크, 실제 server LISTEN 안 봄. v0.9.6 fix 가 server bind 정상화하지만 detect-future-failure 위해 LISTEN check 추가는 별도 enhancement.
- v0.9.3 residual #B (creds.json ACL mask `---`) + #C (state/agents/<X>/ mode 2750) — root cause 미확정.

## [0.9.5] — 2026-05-09

### Highlight — #771 Teams server N-of-1 spawn 종결 + writer symlink hardening

`v0.9.5` 는 운영자가 #771 로 보고한 "isolated Teams plugin server 가 4 에이전트 중 1명 (mgt_ahn) 만 LISTEN" 증상의 두 root cause 를 함께 fix. 운영자의 R3+R4 진단으로 확정된 dispatch 경로 분기: `agent-bridge migrate isolation v2 --apply` (공백, repair tool) 가 `bridge_isolation_v2_reapply_one_agent` 로 라우팅되며 이 함수의 두 결함이 결합:

1. **stale `runtime/agent-env.sh`**: isolated agent 의 cached `BRIDGE_AGENT_LAUNCH_CMD[$agent]` 가 v0.7→v0.8 isolate 시점에 한 번 작성되고 이후 regenerate 안 됨. 거기 박힌 `TEAMS_STATE_DIR=…/agents/<X>/.teams` 가 v2 layout 이후 (`/workdir/.teams`) 와 불일치 → 매 restart 마다 stale path 주입 → bun teams server.ts silent-exit before bind → `ss -tln :3980` 에 LISTEN 없음 → router proxy "Unable to connect" 반복 → Sean 메시지 silent drop. 비isolated mgt_ahn 는 daemon 의 live launch_cmd 계산 path 라 영향 없음 = 4 에이전트 중 1명만 살아있던 이유.

2. **channel `.env` mode 0640**: `setfacl -bR` strip 후 `group::---` 잔존 가능 (특정 `acl` 패키지 빌드) → controller 가 base group bit 로 read 불가 → `creds_status=unreadable` → channel readiness probe fail. v2 design contract (lib/bridge-agents.sh:3917-3919 주석: "v2: no ACL repair retry. The per-agent group + setgid contract handles controller access") 가 명시한 group rw 와 불일치.

`agent-bridge upgrade --apply` 로 자동 반영. v0.9.x layout/contract 변경 없음. 운영자 호스트에서 #771 본 적 있다면 v0.9.5 적용 후 `migrate isolation v2 --apply` + agent restart 한 번 으로 자동 회복.

### Process — orbstack Linux end-to-end 검증 + codex destructive-probe 3 라운드

이번 release 는 v0.9.4 의 process commitment ("isolation/migrate/upgrade path 만지는 release 는 orbstack Linux 검증 의무") 두 번째 적용. PR #774 의 codex review 가 destructive-probe brief 로 3 라운드:
- r1: 4 finding 잡음 (HIGH security symlink attack, MED helper-not-loaded silent skip, LOW idempotency, style nit)
- r2: r2 fix 적용 + Finding 1 의 partial gap (rm-survives) 추가 catch
- r3: r3 fix 적용 + 6/6 PASS implement-ok

각 라운드의 fix 모두 orbstack Oracle Linux 9 VM 에서 실측 검증. 운영 호스트로 release 가기 전 코드 결함을 사전 차단.

### Fixed (#774 — refs #771)

- `lib/bridge-isolation-v2-reapply.sh:bridge_isolation_v2_reapply_one_agent` 가 recursive perm walk + ACL strip 직후 `bridge_write_linux_agent_env_file "$agent" "$_env_file"` 호출 추가. writer 가 live roster + 현재 `bridge_agent_workdir` (BRIDGE_AGENT_ROOT_V2 honor + `/workdir` append) 로 launch_cmd 재계산해서 cached `BRIDGE_AGENT_LAUNCH_CMD` refresh. mktemp + cmp short-circuit 으로 stable content 시 mtime/ctime 보존 (action row `ok:already-canonical`). helper-not-loaded 시 explicit `error:helper_not_loaded` action row + errors_file append (load-order regression visibility).

- channel `.env` per-path assert mode 0640 → 0660 (`workdir/.teams/.env`, `workdir/.ms365/.env`). v2 design contract 의 group rw 명시. doc table (lib/bridge-isolation-v2-reapply.sh:57-59 + 1085-1090) 동기화.

### Hardening (#774, security — defense in depth)

- `lib/bridge-agents.sh:bridge_write_linux_agent_env_file` 가 `cat >"$file"` redirect 직전 `[[ -L "$file" ]]` 체크 추가. 발견 시 `bridge_linux_sudo_root rm -f` (또는 plain rm) 로 symlink 제거. **post-rm verify 후 symlink 가 살아남았으면** (sudo unavailable / parent dir unwritable) `bridge_warn` + `return 1` — 절대 redirect write 통과 안 함. 이전엔 `[[ -O "$file" ]]` 가 link target (controller-owned) 으로 follow 되어 rm branch skip → cat 이 link 통해 controller 파일 (e.g. `~/.claude/.credentials.json`, 다른 agent env) 덮어쓰는 vector 존재. v0.9.5 의 새 reapply regen call 이 이 vector 노출시켰을 것이라 예방적 fix. 모든 writer caller 가 혜택 (defense in depth).

### Verified on Linux (orbstack Oracle Linux 9)

| Test case | Original | Without fix | With v0.9.5 fix |
|---|---|---|---|
| Symlink at runtime/agent-env.sh → target | target=PROTECTED | target overwritten by cat | **target=PROTECTED ✓** |
| Symlink survives rm (parent dir 0500) | symlink intact | cat through link | **rc=1, bridge_warn, target intact ✓** |
| stale TEAMS_STATE_DIR (pre-v2 path) | `…/agents/<X>/.teams` | restart inject stale | **regen → `…/workdir/.teams` ✓** |
| .env post-strip group bit | `group::---` | controller unreadable | **group rw (mode 0660) ✓** |

### Known carry-over (v0.9.6 트랙 후보)

- **#772** Stop hook → agent-bridge CLI → mkdir BRIDGE_STATE_DIR denied (isolated uid). non-blocking 이지만 stderr spam.
- **#767** daemon inbox-nudge 폭주 (no dedup, no busy-aware gate).
- **runtime_ready false-positive**: bridge_agent_channel_runtime_ready_for_item 이 file/key presence 만 체크, 실제 server LISTEN 안 봄. Fix 1+2 가 server bind 정상화하면 자연 해소되지만 detect-future-failure 위해 LISTEN check 추가는 별도 enhancement.
- v0.9.3 residual #B (creds.json ACL mask `---`) + #C (state/agents/<X>/ mode 2750) — root cause 미확정.

이상 4건 모두 v0.9.6 사이클에서 같은 process (orbstack 재현 → 정밀 fix → codex destructive-probe → release).

## [0.9.4] — 2026-05-09

### Highlight — v0.9.3 regression fix (chgrp_setgid_recursive 가 plugin script exec bit 죽임)

`v0.9.4` 는 v0.9.3 PR #768 가 도입한 destructive 회귀를 종결한다. v0.9.3 의 `bridge_isolation_v2_chgrp_setgid_recursive` 의 file_mode=0660 blanket chmod 가 `agents/<X>/home/.claude/plugins/cache/.../scripts/*.sh` (originally 0750) 의 exec bit 를 죽여서 SessionStart hook fail (`crm-mcp-token-sync.sh: Permission denied`) 발화. 운영자가 v0.9.3 적용 직후 발견 후 `chmod g+rx` 워크어라운드로 unblock. v0.9.4 가 helper 자체의 destructive contract 를 수정해서 워크어라운드 불필요화.

`agent-bridge upgrade --apply` 로 자동 반영. v0.9.x isolation-v2 layout / contract 변경 없음.

### Process change — release 전 orbstack Linux 검증 의무화

이번 v0.9.4 가 처음으로 **release 머지 전 orbstack Oracle Linux 9 VM 에서 end-to-end 재현 + fix 검증** 을 거쳤다. 이전 v0.9.1/v0.9.2/v0.9.3 가 모두 darwin tempdir 만 보고 release 했고 그 결과 release 후 운영 호스트에서 회귀가 처음 발견되는 패턴이 반복됨. v0.9.4 부터:
- isolation/migrate/upgrade path 만지는 변경은 orbstack VM 검증 의무
- codex review brief 에 destructive-change probe (executable / setuid-setgid / symlink / xattr 영향) 항목 추가
- helper 함수의 implicit destructive contract 는 caller 마다 trace 후 호출 사이트 영향 명시

### Fixed (#770 — refs #746, refs #768)

- `lib/bridge-isolation-v2.sh:bridge_isolation_v2_chgrp_setgid_recursive` 가 file 의 mode 를 numeric `chmod $file_mode` (e.g. literal 0660) 로 blanket 적용하던 destructive contract 를 `X` (uppercase, "x only if dir or already has any exec") 활용한 symbolic chmod 로 교체. translation table:

  | numeric | symbolic |
  |---|---|
  | 0660 | `u-s,g-s,g+rwX,o-rwx` |
  | 0640 | `u-s,g-s,g+rX,g-w,o-rwx` |
  | 0600 | `u-s,g-s,g-rwx,o-rwx` |

  `u-s,g-s` 는 정규 file 에서 setuid/setgid bit 명시적 제거 (privilege escalation 표면 방어 — codex r2 catch). user perm 미변경 (file owner = agent UID 가 이미 rw 보장). dir 은 literal numeric `dir_mode` 그대로 (e.g. 2770 의 setgid 는 의도적 — 신규 file group 상속).

- `lib/bridge-isolation-v2.sh:bridge_isolation_v2_verify_chgrp_setgid_recursive` 의 file mode sample 검사를 mask `& 0666` 로 변경 — exec-aware. 이전엔 exec-preserved file (e.g. 0770) 이 expected file_mode (0660) 와 mismatch → return 1 → caller 에 false-positive (codex r1 catch). masked 비교는 "did chmod run at all" 의 rw bit 검증을 유지하면서 exec bit 보존을 허용.

### Verified on Linux (orbstack Oracle Linux 9)

| File | Original | After v0.9.3 (regression) | After v0.9.4 (fixed) |
|---|---|---|---|
| Plugin script | 0750 | **0660 NOT-EXECUTABLE** | **0770 EXECUTABLE** ✓ |
| CLAUDE.md | 0640 | 0660 | 0660 |
| MEMORY-SCHEMA | 0600 | 0660 | 0660 |
| Setuid file | 4640 | (untested) | **0660 STRIPPED** ✓ |
| Setgid file | 2640 | (untested) | **0660 STRIPPED** ✓ |
| verify rc | (always 1 with exec files) | 1 false-positive | **0** ✓ |

### Known carry-over (v0.9.5 트랙 후보)

- **#772** Stop hook → agent-bridge CLI → `mkdir BRIDGE_STATE_DIR` denied (운영자 격리 user uid). non-blocking 이지만 stderr spam (stop 사이클당 3회 이상). 같은 isolation-v2 perm 클래스, 다른 surface (hook layer).
- **#771** Teams plugin server N-of-1 spawn — 4 에이전트 등록인데 1개만 LISTEN. 운영자의 sales_sean / dev_mun / sales_choi Teams 메시지 silent drop. (channel layer)
- **#767** daemon inbox-nudge 폭주 (no dedup, no busy-aware gate). transcript 오염, 기능 차단 없음. (daemon scheduler layer)
- v0.9.3 발견 회귀 #B (creds.json ACL mask `---`) + #C (state/agents/<X>/ mode 2750) — root cause 미확정, v0.9.3 patch scope 외. 운영자 워크어라운드로 unblock 상태.

이상 4건 모두 v0.9.5 사이클에서 동일한 process (orbstack 재현 → 정밀 fix → 검증) 로 처리.

## [0.9.3] — 2026-05-09

### Highlight — REAL #746 fix (the v0.9.1 / v0.9.2 attempts hit the wrong code path)

`v0.9.3` 는 #746 (v0.7→v0.8 migrated 호스트의 workdir 내부 파일 perm drift) 의 **실제 root cause** 를 잡는다. v0.9.1 (#749) 와 v0.9.2 의 13 PR audit wave 가 모두 #746 에 fix 를 시도했지만 운영 호스트에서 동작 안 함이 확인됐고, 운영자 진단 끝에 **dispatch 경로 차이** 가 root cause 로 확정됨.

핵심: `agent-bridge migrate isolation v2 --apply` (공백 form, 운영자가 production 에서 쓰는 repair tool) 는 `bridge_isolation_v2_reapply_one_agent` 로 dispatch 되며, 이 함수의 target path 테이블은 writable-sub 디렉토리들 (`workdir/`, `runtime/`, ...) 자체와 hand-picked 파일 리스트 (`.teams/.env`, `.ms365/.env`, `agent-env.sh`, `launch-secrets.env`, `.claude/`) 만 assert. **workdir 내부 파일들 (CLAUDE.md, MEMORY-SCHEMA.md, memory/*, SOUL.md) 은 절대 안 만짐.** v0.9.1 #749 가 추가한 verify+sudo-retry 는 `bridge_isolation_v2_chgrp_setgid_recursive` 에 들어갔는데, 이 helper 는 `bridge_isolation_v2_migrate_normalize_layout` 에서만 호출 — `agent-bridge migrate isolation-v2 apply` (하이픈 form, 전체 마이그레이션 도구) path 만 커버. 두 CLI 가 완전히 다른 함수로 분기되는 걸 #749 가 인지 못 함.

운영자 진단 데이터 (post-v0.9.2): `grep -c bridge_isolation_v2_verify_chgrp_setgid_recursive lib/bridge-isolation-v2.sh` = 3, `grep -c workdir-verify lib/bridge-isolation-v2-migrate.sh` = 3 (코드는 디스크에 들어왔음), 그러나 `migrate isolation v2 --apply` 출력의 workdir-verify 라인 수 = 0 (호출 안 됨). 시나리오 C 확정 — 코드는 있지만 호출 dispatch 가 다른 분기로 빠짐.

`agent-bridge upgrade --apply` 로 자동 반영. v0.9.x isolation-v2 layout 변경 없음. 운영자 호스트가 #746 cascade 를 보았다면 본 v0.9.3 적용 후 `agent-bridge migrate isolation v2 --apply` 한 방에 자동 회복.

### Fixed (#768 — refs #746)

- `lib/bridge-isolation-v2-reapply.sh:bridge_isolation_v2_reapply_one_agent` 에 writable-sub recursive 정규화 추가 (47 LOC, single function). per-path assert 직후 + ACL strip 직전 구간에 삽입. `bridge_isolation_v2_chgrp_setgid_recursive "$agent_grp" 2770 0660 "$agent_root/$sub"` 호출을 `home / workdir / runtime / logs / requests / responses` 각각에 대해 수행. apply 모드에선 실제 chgrp+chmod, check/dry-run 모드에선 `would` / `drift` action row 만 emit. helper 호출은 #749 의 verify+sudo-retry 자동 상속 — drift 감지 시 sudo retry, 그래도 drift 면 명료한 `bridge_warn`. per-sub 실패는 best-effort (errors_file append + record_action error, 다음 sub 로 continue) — repair tool 의 "fix what you can, surface what failed" 철학과 일치.

### Reproduction + verification

darwin tempdir BRIDGE_HOME 에서 운영자 증상 정확히 재현 (workdir DIR 은 canonical 2770/ab-agent-X, 내부 contents 는 0640/0750 + 잘못된 group). pre-fix 의 `migrate isolation v2 --apply` 는 contents 를 안 건드림 → 운영자 production 호스트 결과와 100% 일치. patched source 는 recursive 호출이 contents 를 정상 정규화 (Linux 검증 운영자 호스트에서 post-merge 진행).

### Carry-over from v0.9.2

#767 (daemon inbox-nudge dedup + busy-aware gate) — 별도 트랙. v0.9.4 후속 사이클에서 처리.

## [0.9.2] — 2026-05-09

### Highlight — post-#746/#747 wave-orchestrated bug-class sweep (13 PR)

`v0.9.2` 는 v0.9.1 (`c3a09a0`, 2026-05-09 13:10 KST) 머지 직후 동일 패턴의 silent-failure / set-e-cascade / redirection-leak 을 codex-rescue + 로컬 grep 으로 코드베이스 전체 audit 한 결과 (umbrella #752) 13 PR 을 4 wave 로 병렬 처리한 hotfix 묶음이다. 모든 PR codex-rescue pair-review 통과 + squash-merge.

핵심 trigger: v0.9.1 의 #746 fix (`bridge_isolation_v2_chgrp_setgid_recursive` self-verify + sudo retry) 와 #747 fix (`scripts/wiki-v2-rebuild.sh` skip-and-continue) 가 land 한 직후, 같은 bug-class 가 다른 위치에도 있는지 audit 진행. 발견: 4 HIGH + 11 MED + 19 LOW. 운영자 결정에 따라 모두 wave-orchestration 으로 fix.

`agent-bridge upgrade --apply` 로 자동 반영. v0.9.0 isolation-v2 layout 변경 없음.

⚠ **Known issue (carry-over)**: v0.9.1 운영 호스트에서 #746 fix 가 *defensive* 였음에도 여전히 drift 자동 회복 안 됨. 운영자 진단 결과 새 verify 코드가 실행 경로에 진입조차 못 함 — root cause 미확정 (가설: `bridge-upgrade.sh` 가 lib/bridge-isolation-v2*.sh 를 live runtime 에 복사 안 했을 가능성). v0.9.2 적용 후 다시 검증 필요. 미해결 시 v0.9.3 에서 정밀 fix.

### HIGH (4 PR)

- **#753 H1 — `lib/bridge-migration.sh:644-680`** unisolate 의 default-ACL 제거 path 가 `find -exec setfacl … {} + 2>/dev/null \|\| true` 로 rc 무시 + post-verify 없어서 stale ACL 잔존 가능했던 문제. `find -print0 \| xargs -0 -r setfacl` (xargs rc 전파) + `getfacl --skip-base -R \| grep` post-verify + drift 시 sudo retry. (`443c514`)
- **#755 H2 — `lib/bridge-isolation-v2.sh:878-908`** Linux setfacl scrub 의 self-verify+sudo-retry — #749 의 H2 카운터파트. `getfacl --absolute-names --skip-base -R \| grep -E '^(user\|group\|default:user\|default:group):[^:]+:'` 로 residual ACL 감지 → sudo retry → re-verify. (`fad0cbf`)
- **#754 H3 — `lib/bridge-isolation-v2-migrate.sh:1664-1722`** `apply_for_upgrade` 의 marker-present idempotent skip 경로에서 normalize_layout 실패가 warn-only 였던 contract break. rc 캡처 + `status:partial` JSON envelope (last_error / remediation 필드 포함) + 비-0 return. 모든 envelope 에 `status` 필드 추가 — M10 (W3d) 에서 consume. (`ddbe5fa`)
- **#756 H4 — `lib/bridge-migration.sh:138-148`** `bridge_migration_isolate --reapply` 의 `bridge_linux_prepare_agent_isolation` 실패 시 warn-only 였던 contract break. `if !; then bridge_warn 'refusing to mark reapply complete'; return 1; fi` 로 fatal 화. (`666954c`)

### MED (8 PR — Bug-A cascade + Bug-B/C/D bundles)

- **#757 M1+M2 — `bridge-sync.sh:46-58 + :110-116`** 동적 에이전트 archive/remove 루프 + 세션 상태 persist 루프 둘 다 set -e 하에서 한 에이전트 실패 시 cascade abort. 둘 다 `if !; then bridge_warn; continue; fi`. (`462b78a`)
- **#758 M3 — `lib/bridge-state.sh:2674-2696`** `bridge_reconcile_idle_markers` 의 inactive-branch 와 non-numeric-branch 둘 다 cascade 보호 추가. (`6f3993a`)
- **#760 M4 — `bridge-agent.sh:2116-2136`** `run_rerender_settings` 의 per-target 프로브 실패가 후속 모든 타겟 rerender 를 죽이던 cascade. `if !; then bridge_warn; emit error JSON row via env-passed-vars python3 -c; failed_count++; continue; fi`. failed_count 가 함수 rc 결정 → upgrade caller 가 partial-failure 인지 가능. (`e93325b`)
- **#759 M5 (r2) — `scripts/apply-channel-policy.sh:707-811`** per-agent allowlist overlay 루프의 Python 명령 치환 두 군데 모두 `if !; then warn; overlay_fail++; continue; fi` 가드 + 모든 overlay 실패 시 `(( overlay_fail>0 && overlay_ok==0 ))` → `exit 1` (pipefail 로 outer 전파). 운영자가 모든 agent 의 settings.local.json 이 malformed JSON 인 케이스를 silent rc=0 가 아니라 명료하게 보게 됨. (`2c9a536`)
- **#761 W3a — `lib/bridge-tmux.sh:1138`** pending-attention lock PID write 의 redirection-order leak. `printf '%d' $$ >"$pid_file" 2>/dev/null` → `printf '%d' $$ 2>/dev/null >"$pid_file"`. (`b13d859`)
- **#763 W3b — `lib/bridge-isolation-v2.sh:840-873`** Darwin ACL scrub `chmod -R -P -N` 의 self-verify+sudo-retry — H2/#755 의 macOS 카운터파트. `find -print0 \| xargs -0 ls -leOd \| grep -E '^[[:space:]]+[0-9]+:'` 로 residual 감지 (Darwin 은 getfacl 없으므로 ls -le 활용). (`3d79953`)
- **#764 W3c — `lib/bridge-migration.sh:155-180 + :255-275`** `bridge_install_isolated_home_settings` 호출 두 군데 (reapply / fresh isolate) warn-only → `if !; then bridge_warn 'refusing to mark X complete'; return 1; fi` (H4 패턴 mirror). (`ad42b61`)
- **#762 W3d — `bridge-upgrade.sh:1441/1622/1638`** upgrade 의 부분-실패 path 세 군데 (shared rerender failed_count, channel-policy `\|\| true`, profile relink failed_count) 모두 `_upgrade_partial_failures` 배열로 캡처. 최종 JSON envelope `status:"partial"\|"ok"` + `partial_failures:[…]` (sorted/dedup). NOT upgrade-fatal — 복구 가능한 부분 실패는 운영자에게 명확히 보이게 surface 만. (`a4af479`)

### LOW sweep (1 PR)

- **#765 W4 — 11 files / 19 sites** bash redirection-order leak 일괄 swap (`> "$f" 2>/dev/null` → `2>/dev/null > "$f"`). 모두 `\|\| true`-protected 였으므로 cosmetic 이지만 누적 stderr noise (degraded fs / cron 출력 / daemon log) 정리. 사이트: bridge-daemon.sh × 5, bin/agb, bridge-cron.sh, bridge-run.sh × 2, bootstrap-memory-system.sh, lib/bridge-isolation-v2.sh, lib/bridge-isolation-v2-migrate.sh × 3, lib/bridge-hooks.sh × 2, lib/bridge-state.sh, scripts/bridge-daemon-liveness.sh, scripts/librarian-idle-exit.sh. (`550710b`)

## [0.9.1] — 2026-05-09

### Highlight — v0.9.0 post-upgrade hotfix wave (2 PR)

`v0.9.1` 은 v0.9.0 적용 호스트에서 같은 날 발견된 두 cascade 를 닫는다. 핵심 trigger: 운영 호스트가 `agent-bridge upgrade --apply` + `agent-bridge migrate isolation v2 --apply` 를 차례로 통과하고 *exit 0 + all dir entries `ok`* 를 보았으나, 정작 `agents/<X>/workdir/` 안의 pre-existing 파일은 v0.7→v0.8 이전 owner-group 을 그대로 유지 → controller user (`ec2-user`, `ab-agent-<X>` 그룹 멤버) 가 `workdir/CLAUDE.md` 를 read 못 함 → 토요일 06:00 KST `wiki-v2-rebuild` cron 이 PermissionError 로 abort, `set -euo pipefail` 가 sweep 전체를 죽임 → 한 에이전트의 perm drift 가 다른 5 에이전트의 weekly index rebuild 까지 silent miss 시키는 cascade.

`agent-bridge upgrade --apply` 로 자동 반영. v0.9.0 isolation-v2 layout 변경 없음. v0.9.0 적용 호스트가 같은 cascade 를 보았다면 본 v0.9.1 적용 후 다음 토요일 cron slot (2026-05-16 06:00 KST) 에서 자동 회복.

### Fixed (#749 — refs #746)

- `lib/bridge-isolation-v2.sh` 에 belt-and-braces 가드 두 겹 추가. 새 helper `bridge_isolation_v2_verify_chgrp_setgid_recursive(group, dir_mode, file_mode, root)` 가 tree 를 walk 하면서 모든 dir/file 의 group 이 expected 와 일치하는지 + 하나의 sample dir / file 의 mode 가 expected 와 일치하는지 확인 (mode 비교는 `printf '%04o' "$((8#$mode))"` 정규화로 BSD/macOS `stat -f %A` 와 GNU `stat -c %a` parity). `bridge_isolation_v2_chgrp_setgid_recursive` 가 4 find-exec passes 직후 self-verify 호출 → drift 감지 시 `sudo -n find … -exec chgrp/chmod {} +` (no direct-first) 로 retry 후 재검증 → 여전히 drift 면 명료한 `bridge_warn` 후 return 1. 이전엔 stderr-silenced direct-first 가 find 가 0 반환했음에도 per-file chgrp 실패가 propagate 안 되는 환경 (Amazon Linux GNU findutils 등) 에서 silent no-op 로 끝나고 sudo retry path 가 미진입했다. `lib/bridge-isolation-v2-migrate.sh:bridge_isolation_v2_migrate_normalize_layout` per-agent loop 에 `[migrate] workdir-verify ok|FAIL agent=<X> grp=<grp>` 명시 로깅 — FAIL → return 1 → full apply path 의 `bridge_die` (v2 marker 미진행), upgrade path 는 warn-only (operator 가 grep 으로 식별 가능). rootless smoke regression 무영향 (caller's primary group + 2770/0660 tempdir tree 에서 verify 가 trivial pass).

### Fixed (#748 — refs #747)

- `scripts/wiki-v2-rebuild.sh` 의 `mkdir -p "$(dirname "$live_db")"` + `: 2>/dev/null >> "$lock_file"` 두 lock-init step 을 같은 file 의 기존 `LOCK_BUSY` / `FAIL` / `VALIDATE_FAIL` / `SWAP_FAIL` block 과 동일한 `if !; then log_audit; skipped++; continue; fi` shape 으로 가드. 새 audit tag `MKDIR_FAIL` / `LOCK_INIT_FAIL`. bash redirection 순서 footgun 회피 — `: >> "$lock_file" 2>/dev/null` 은 `>>` open 실패 시 bash 가 `2>/dev/null` 적용 *전에* `Permission denied` diagnostic 을 stderr 로 leak; `: 2>/dev/null >> "$lock_file"` 로 stderr 를 먼저 redirect. `set -euo pipefail` + ERR trap 보존. 단일 에이전트의 perm drift 가 weekly sweep 전체를 죽이던 cascade 종결 — 한 에이전트의 lock-init fail 은 한 에이전트의 skip 이고 그 이상이 아님.

## [0.9.0] — 2026-05-09

### Highlight — isolation-v2 migration tooling + canonical state docs

`v0.9.0` 은 v0.7→v0.8 isolated-agent transition 의 ownership/ACL drift 를 자동 회복하는 새 CLI 명령을 추가하고, 그 contract 를 운영 문서로 명문화한다. minor bump 정당화: 새 CLI subcommand surface (`agent-bridge migrate isolation v2`).

핵심 trigger: 이슈 #737 (운영자가 본 isolated agent 의 cascade — `agents/<X>/.claude/` 누락, plugin state files mode 0600 controller-그룹, `/home/agent-bridge-<X>/.claude/` 가 root 소유 + named-user ACL with controller 만 + agent 본인 access 끊김 등). v0.7 시절의 transitional ACL 잔재가 v0.8 hard-cut (PR #641 — KNOWN_ISSUES §16) 후에도 정리 안 된 상태가 진짜 결함이었다. v2 contract 는 운영자 mental model "kill ACLs" 와 정확히 일치 — layout 자체엔 named-user POSIX ACL surface 0개. 새 명령 `migrate isolation v2 --apply` 가 이 잔재를 자동 strip + canonical state 적용.

`agent-bridge upgrade --apply` 후 isolated agent 가 `agents/<X>/...` cascade fail 하면:

```
agent-bridge migrate isolation v2 --check        # drift report
agent-bridge migrate isolation v2 --dry-run      # planned actions
agent-bridge migrate isolation v2 --apply        # apply fix
agent-bridge agent start <agent>                 # restart
```

### Added (#742 — refs #737 Q1/Q2/Q3) ★ Highlight

- 새 CLI subcommand `agent-bridge migrate isolation v2 [--check|--dry-run|--apply] [--agent <name>] [--json]` (lib/bridge-isolation-v2-reapply.sh, ~880 LOC). Modes: `--check` 는 drift report only, `--dry-run` 은 planned actions, `--apply` 는 mutation. `agents/<agent>/*` (root:ab-agent-<agent> 2750, subdirs 2770, credentials 2750, agent-env.sh 0640, plugin state files 0640) + `/home/agent-bridge-<agent>/*` (agent 본인 owner 0700, 모든 named-user POSIX ACL strip) 둘 다 cover. `~/.claude/.credentials.json` 미터치 (PR #641 hard-cut 후 v2 contract 외 surface). non-Linux 즉시 silent skip. macOS / non-Linux 호스트는 무영향. idempotent — 두 번째 `--apply` 는 진정한 no-op (path-local stat + named-ACL canary). credentials/launch-secrets.env 도 canonical assertion. `--json` 출력 schema: per-agent `{agent, isolated, actions[], errors[]}` + top-level `total_agents` / `total_repaired`.

### Fixed (#741 — refs #737 Q5)

- `bridge-setup.py` 의 `inspect_discord_dir` / `inspect_telegram_dir` / `inspect_teams_dir` 가 isolated agent 의 owner-only `.env` 를 controller 로 read 시 발생하던 PermissionError 를 PR #718 family sudo-fallback 패턴으로 해소. `_safe_read_env` / `_safe_load_json` / `_safe_path_check` / `_isolated_workdir_owner` / `_sudo_run_as` / `_parse_dotenv_text` helpers (모두 bridge-setup.py 내부 미러). sudo 미설치 시 rc 127 → 명료한 `PermissionError` ("sudo not available; cannot read X as Y. Recovery requires either installing sudo or running this command as the agent user directly.") + cause chain (`from exc`). non-Linux 는 `_isolated_workdir_owner` 가 None 반환으로 fallback 분기 미진입 — 기존 동작 보존. ms365 inspect 는 `bridge-setup.py` 에 없음 (별도 surface). 운영자가 `agent-bridge setup teams <agent>` recovery path 를 정상 사용 가능.

### Fixed (#740 — refs #737 Q6)

- `agent-bridge agent delete --purge-home` 가 isolated agent 의 *actual Linux home* (`/home/agent-bridge-<agent>/`) 도 제거. `getent passwd <user>` 로 정확한 home path 추출 + regex guard `^/home/agent-bridge-[a-zA-Z0-9_-]+$` 으로 운영자 home / system path 보호. `bridge_linux_sudo_root rm -rf` 사용 (root-owned). 실패 시 warn 만 (agent 자체는 이미 delete 됨, fail-loud 금지). Linux user account 자체 (`userdel`) 제거는 scope-out (별도 follow-up). non-Linux short-circuit. retire 분기 보존.

### Documentation (#739 — refs #737)

- `OPERATIONS.md` 에 새 섹션 "Isolation v2 canonical state and migration" — canonical state table ($BRIDGE_DATA_ROOT 환경변수 명시) + migration runbook + POSIX ACL 역할 정리. `KNOWN_ISSUES.md §16` 보강 — "v0.7 → v0.8 migration ACL leftovers" 부분 (manual recovery 명령 + 예외 없는 strip-only 정책). 신규 `docs/agent-runtime/v2-isolation-migration.md` — 깊이 있는 reference (drift signature, --check/--dry-run/--apply 사용법, manual recovery, diagnostic 명령). 모든 docs `ACL preservation count: 0` / `strip-only pass` 언어 통일 — PR #641 hard-cut contract 와 일관 (KNOWN_ISSUES §16 line 269-271, 288-292).

## [0.8.9] — 2026-05-08

### Highlight — second post-upgrade hotfix wave (5 PR)

`v0.8.9` 은 v0.8.8 적용 호스트에서 발견된 추가 cascade 4건 + 별도 tool-policy hotfix 1건을 닫는다. 핵심: **PR #734 (closes #731)** 가 isolated agent 의 업그레이드 silent skip + JSONDecodeError 를 종결한다 — `bridge_agent_canonical_dir` 의 `cd -P` 이 isolated workdir 에서 PermissionError 일 때 `bridge_linux_sudo_root` fallback + 최종 path passthrough, 그리고 `bridge-upgrade.sh` 의 `SHARED_SETTINGS_RERENDER_JSON` 두 python heredoc 에 빈/non-JSON 방어 (`sys.exit(0)` + WARN + `raw[:200]` preview). 이 이전엔 isolated agent host 의 업그레이드가 raw traceback + "rerender failed for one or more agents" 로 끝났고 *어느 agent / 어느 step* 인지 알 수 없었다.

다른 4 PR: librarian memory-daily 의 8-day 빈-슬롯 backfill loop 를 sender-gated self-signal filter 로 종결 (#732 closes #728), bootstrap-memory-system 에 `--re-jitter` flag 추가하여 long-running install 에서 모든 memory-daily 크론이 동일 minute 으로 회귀했을 때 collapse 검증 후 분산 (#733 closes #729), v0.8 layout split 후 broken 된 agent profile 의 shared-doc / skill symlink (workdir/COMMON-INSTRUCTIONS.md off-by-2, home/.claude/skills/X off-by-1) 재연결 helper 추가 (#735 closes #730), 그리고 별도 tool-policy hotfix 로 `agent-bridge config set` wrapper 가 path-argv gate 를 정상 통과하도록 (#726).

`agent-bridge upgrade --apply` 로 자동 반영. v0.8 isolation-v2 layout 변경 없음. isolated agent 호스트가 v0.8.8 적용 시 raw JSONDecodeError traceback 을 보았다면 본 v0.8.9 적용 후 해당 trace 사라짐.

### Fixed (#734 — closes #731)

- `bridge-agent.sh:bridge_agent_canonical_dir` 가 `cd -P` PermissionError 시 `bridge_linux_sudo_root sh -c 'cd -P "$1" && pwd -P' _ "$path"` fallback 시도. `command -v bridge_linux_sudo_root` guard 로 helper 미설치 install 안전. 최종 fallback 은 입력 path passthrough (caller 의 `[[ -d ]]` 가 이미 valid 임을 증명). non-Linux platform 은 `bridge_linux_sudo_root` 가 즉시 return 으로 sudo 호출 안 됨. `bridge-upgrade.sh:1444` 와 `:2039` 두 python heredoc 에 빈/non-JSON 방어 — empty raw 는 WARN + `sys.exit(0)`, JSONDecodeError catch 후 WARN + `raw[:200]` preview. raw traceback 사라지고 어느 agent/step 가 문제인지 식별 가능.

### Fixed (#732 — closes #728)

- `bridge-memory.py` 의 librarian 활동 분류기에 sender-gated self-signal filter. `_is_system_sender` helper 가 `from_field` 가 `memory-daily` / `cron-dispatch` / `cron-followup` prefix 와 매치할 때만 True; `_is_self_signal_event` 가 sender gate 를 hard short-circuit (title regex / payload_kind 평가 전). human-authored task 가 우연히 `... checked ok` 같은 제목이어도 sender 가 system 이 아니면 보존. system sender 의 self-signal-shaped title (예: `[memory-daily] backfill ...`) 은 필터링; bare cron-dispatch (system + non-matching title) 도 필터링. `_scan_queue_events` 가 task title + created_by 를 JOIN 하고, `_queue_backfill` 가 모든 post-filter activity bucket 이 비어있으면 audit log + return (no backfill task 생성). 8-day 빈-슬롯 backfill loop 종결.

### Fixed (#733 — closes #729)

- `bootstrap-memory-system.sh --apply --re-jitter` flag 추가. long-running install 에서 모든 `memory-daily-<agent>` 크론이 같은 minute 으로 fan-out 된 케이스를 *진짜* collapse (≥2 cron at same minute) 일 때만 강제 jitter overwrite. 단일 cron at minute 0 + hour 3 + dow `*` 는 operator override 로 간주, 보존 + hint `skipped-single-minute-cron-not-collapsed`. `prepopulate_memory_daily_minute_counts` pre-pass 가 모든 static agent 의 minute count 를 사전 집계 (order-dependent 회피). drift report 에 `simultaneous=N` 어노테이션 + `memory_daily_simultaneous_fire_max` / `re_jitter_requested` top-level field 추가. `--re-jitter` 단독 사용 (apply 없이) → exit 2.

### Fixed (#735 — closes #730)

- `bridge-hooks.py` 에 새 subcommand `relink-profile-paths` 추가. v0.8 isolation-v2 layout split 후 broken 된 agent profile symlink 를 재연결: `agents/<agent>/workdir/{COMMON-INSTRUCTIONS,CHANGE-POLICY,TOOLS}.md` → `../../../shared/<DOC>.md` (3 levels up to BRIDGE_HOME), `agents/<agent>/home/.claude/skills/<skill>` → `../../../../../.claude/skills/<skill>` (5 levels up to `$BRIDGE_HOME/.claude/skills/<skill>`, NOT `$HOME` — on-disk skill mirror 가 BRIDGE_HOME 안에 있다). 진짜 파일 / non-symlink 가 자리 점거 시 skipped + warn entry (no clobber). isolated agent 는 PR #718 의 `_sudo_run_as` helper 재사용. `bridge-upgrade.sh` 가 daemon restart 전 `relink-profile-paths --all-agents --json` 호출 + JSON parse guard.

### Fixed (#726)

- `bridge-hooks.py` tool-policy gate 가 `agent-bridge config set <key> <value>` wrapper invocation 을 path-argv 패턴으로 인식해 deny 하던 문제 종결. wrapper-allowlist 분기를 path-argv 검사 *전* 으로 이동. 운영자가 `agent-bridge config set log.level debug` 같은 합법적 wrapper 호출을 다시 사용 가능.

## [0.8.8] — 2026-05-08

### Highlight — v0.7→v0.8 post-upgrade cascade 회복 + #720 admin kill-loop root cause

`v0.8.8` 은 v0.7→v0.8.7 업그레이드 직후 호스트에서 발견된 cascade 실패를 한 번에 닫는다. 핵심: PR #721 — `apply-channel-policy.sh` 가 v0.8 isolation-v2 layout 에서 owner re-enable overlay 를 `OWNER_HOME/.claude/settings.local.json` 에 쓰지만 Claude 는 `OWNER_HOME/workdir/.claude/settings.local.json` 을 본다. overlay 가 도달 못 해서 singleton plugins (discord/telegram) 이 disabled 유지 → `bridge-run.sh` plugin pre-flight fail → tmux 죽음 → daemon 재시작 → admin/owner kill-loop. 이게 #715 §A "plugin-MCP-liveness 무한 restart" 의 **진짜 root cause**. PR #716 (MCP-liveness max-restart counter) 는 hardening.

다른 7 PR 은 sudo-handoff trio (#718 — watchdog scan + manual-stop clear + cmd_link_shared_settings), daemon stale supplementary-group preflight (#717 — closes #712), bridge-start post-launch tmux has-session polling + agb admin slow-path conditional (#719 — refs #715 §C #714 §5), dashboard offline static + agb attach remediation hint (#724 — refs #714 §6/7), static-role workdir auto-rebuild on missing (#723 — refs #714 §3), bridge-init host profile onboarding + production cron gating (#725 — closes #713), human-facing plain-language SSOT (#722 — closes #711).

`agent-bridge upgrade --apply` 로 자동 반영. v0.8 isolation-v2 layout 변경 없음. 운영 호스트가 kill-loop 중이라면 본 v0.8.8 적용 후 `agent-bridge daemon restart` + admin agent 재기동으로 회복.

### Fixed (#721 — closes #720)

- `scripts/apply-channel-policy.sh` 가 v0.8 isolation-v2 layout split 후 owner re-enable overlay 를 `OWNER_HOME/.claude/settings.local.json` (한 단계 위) 에 쓰던 결함을 종결. 새 helper `_apply_channel_policy_link_workdir_overlay` 가 admin/owner/allow 3 site 모두 `OWNER_HOME/workdir/.claude/settings.local.json` 가 한 단계 위 overlay 를 가리키는 idempotent symlink (`ln -sfn`) 를 생성. 진짜 파일이 자리에 있으면 silent skip + warn (no clobber); mkdir 실패 (isolated user 소유 workdir) 시 silent skip + warn. DRY_RUN / QUIET 기존 패턴 보존. `bridge-run.sh` plugin pre-flight 가 owner workdir 에서 singleton plugins 를 정상 enabled 로 보면 admin kill-loop 종결.

### Fixed (#717 — closes #712)

- `bridge-daemon.sh start` 에 supplementary group preflight 추가. v1→v2 migration 후 stale shell 에서 daemon 재시작 시 `id -G` (passwd 기준) ⊃ 현재 process 의 supplementary GID 를 확인해 누락된 v2 isolation groups (`ab-controller`, `ab-shared`, `ab-agent-*`) 가 있으면 refuse + bilingual remediation. linux-user isolation 미사용 install (예: macOS, controller_group 부재) 은 silent passthrough. `BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS=1` escape hatch. KNOWN_ISSUES.md §23 에 진단 / 회복 절차 등록.

### Fixed (#718 — refs #715 §B + #714 §2/3 + #694)

- Isolated agent multi-site PermissionError sudo-handoff trio. (1) `bridge-watchdog.py:scan_agent` 를 try/except 로 감싸 isolated CLAUDE.md PermissionError 가 전체 walk 를 죽이지 않도록 + warn placeholder. (2) `lib/bridge-state.sh:bridge_agent_clear_manual_stop` 에 `bridge_linux_sudo_root` fallback (PR #692 패턴 재사용) — controller user 가 isolated marker dir (mode 2750) 에 unlink 못 해도 root 로 처리. (3) `bridge-hooks.py:cmd_link_shared_settings` — mutating ops (rm/cp/symlink) 와 metadata probe (`is_symlink`/`exists`/`realpath`) 모두 try/PermissionError → `sudo -n -u <agent-user>` fallback 으로 routed. `_isolated_workdir_owner` 는 `lstat()` 사용 (symlink workdir 자체 owner). `_sudo_run_as` 는 `sudo` 미설치 시 stderr warn.

### Fixed (#719 — refs #715 §C + #714 §5)

- `bridge-start.sh` 세션 시작 후 짧은 `tmux has-session` 폴링 (default `BRIDGE_START_VERIFY_POLL_ATTEMPTS=10` × `BRIDGE_START_VERIFY_POLL_INTERVAL_SECONDS=1` = 10s). 폴링 도중 세션이 죽으면 `BRIDGE_START_VERIFY_LOG_TAIL_LINES=20` (default) 만큼 agent log 를 읽어 surface + 비-0 exit. `agent-bridge` admin slow-path 는 child 호출에 `_admin_rc=0; cmd ... || _admin_rc=$?` 패턴으로 `set -e` 우회 — child nonzero 시 diagnostic heredoc + `exit "$_admin_rc"` 실행. agb admin 60s arming + 죽은 세션 거짓 보고 cliff 종결.

### Fixed (#723 — refs #714 §3)

- `bridge-start.sh` 의 `WORK_DIR` 누락 분기를 정확히 v2 canonical static path 만 auto-rebuild 하도록 한정. 비교는 `[[ -n "$BRIDGE_AGENT_ROOT_V2" && "$WORK_DIR" == "$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir" ]]` 의 prefix string 비교. 외부 임의 `--workdir` / typo 경로는 기존 `bridge_die` 보존. v2 canonical missing 시 plain `mkdir -p` → `bridge_linux_sudo_root mkdir -p` fallback (root-owned parent).

### Changed (#724 — refs #714 §6/7)

- `bridge-status.py` default filter 에 `source=static` OR 분기 추가 — offline static agent 도 dashboard default 에 노출 (이전엔 `--all-agents` 만). `agent-bridge` attach 실패 시 stderr 로 `[hint] bash bridge-start.sh <agent>` / `[hint] agb admin` remediation 한 줄씩 출력 + 에러 텍스트 명료화 (`에이전트 'X'의 tmux 세션이 없습니다`).

### Changed (#716 — refs #715 §A — hardening)

- `bridge-daemon.sh:bridge_report_plugin_liveness_miss` 에 `RESTART_ATTEMPTS` per-(agent,channel-key) 카운터 추가. `BRIDGE_PLUGIN_LIVENESS_MAX_RESTARTS` (default `5`) 초과 시 `plugin_mcp_liveness_giveup` audit 1회 emit + restart 중단 (sentinel) — 같은 key 가 다른 missing-CSV 로 바뀌면 attempts 0 reset. 60s cooldown / attached-session skip / channel-status guard 보존. (#720 가 owner kill-loop 의 진짜 driver 라 본 PR 은 안전망 hardening; backoff 는 미래 transient MCP failure 시나리오에 가치.)

### Added (#725 — closes #713)

- `bridge-init.sh` first-run 에 host profile 질문 (`a` server / `b` dev) + `state/install/host-profile.json` 영속화 (`chmod 0644`). non-interactive (TTY 부재) 입력은 자동 `server` (production install 회귀 차단) + stderr audit-log. `profile=dev` 면 production-style maintenance crons 10개 (`librarian-watchdog`, `wiki-mention-scan`, `wiki-daily-ingest`, `wiki-hub-audit`, `wiki-weekly-summarize`, `wiki-monthly-summarize`, `wiki-copy-full-backfill`, `wiki-dedup-weekly`, `wiki-v2-rebuild`, `wiki-repair-links`) 를 disable 제안 (default-yes). `memory-daily-*` 는 항상 보존. 재실행 시 `[host-profile] already=<dev/server> (set_at=…)` grep-able sentinel 출력 + `--reconfigure` 만 강제 재질문. 신규 helper `lib/bridge-host-profile.sh`.

### Added (#722 — closes #711)

- `docs/agent-runtime/common-instructions.md` 에 "Plain Language Default — 사람한테 답할 때" 섹션 추가. 사람-facing surface (Discord/Telegram 등) 답변에 5초 안에 이해되는 짧은 한국어 default + 영어 단어/축약어 절제 + 글머리표 분리 contract 명문화. agent-to-agent task body / log / diff / 코드 인용은 정확성 우선이라 그대로. install-level deviation 은 `agent SOUL.md` 또는 `docs/agent-runtime/active-preferences.md` 에서 override.

## [0.8.7] — 2026-05-08

### Highlight — closes #708 v0.7→v0.8 migration grep-flag-injection abort

`v0.8.6` shipped earlier today closing the v0.7→v0.8 admin-pair migration chain. An operator running `bridge-upgrade.sh --apply` on a v0.7.8 install whose `agents/` directory contained a stray dir starting with `-` (e.g. `agents/--help` from a flag-typo'd pre-v0.8 `agent create` or a manual `mkdir`) hit `isolation-v2 migration failed (rc=1) reason=groups-ensure`. v0.8.7 closes that single finding with a 2-line defensive fix.

**Operators on v0.8.6: upgrade to v0.8.7.** No separate v0.8.6 stop required. If your v0.8.6 install already aborted with `reason=groups-ensure` and you have a `--`-prefixed orphan dir under `agents/`, move it under `backups/` (any name) and rerun `bridge-upgrade.sh --apply` from the v0.8.7 source.

### Fixed

- **#708 v0.7→v0.8 migration aborted when an orphan agent dir name started with `-`** (`lib/bridge-isolation-v2-migrate.sh::bridge_isolation_v2_migrate_capture_all_agents_snapshot`): an operator running `bridge-upgrade.sh --apply` on a v0.7.8 install whose `$BRIDGE_AGENT_HOME_ROOT` contained a stray dir like `agents/--help` (created by an earlier flag-typo'd `agent create` on a pre-v0.8 install or a manual `mkdir`) hit `isolation-v2 migration failed (rc=1) reason=groups-ensure`. Root cause: the markerless directory walk called `grep -qFx "$name" "$roster_lookup"` without the `--` end-of-options separator. When `$name` started with `-`, GNU grep parsed it as a flag (`-q -F -x --help`), printed its help text to stdout (which `2>/dev/null` does not silence), and the curly-brace block's stdout was piped into `sort -u > "$snapshot"` — so `state/migration/all-agents.snapshot` ended up containing ~70 lines of grep help text mixed with real agent ids. Downstream `ensure_groups_and_memberships` then ran `bridge_isolation_v2_agent_group_name` on the polluted lines, validation failed (e.g. `'                            ACTION is 'read' or 'skip'' has invalid chars`), the migration aborted, and `restart_agents` failed for every agent. v0.8.7 hotfix: (a) add `-*` to the case-filter denylist so `--`-prefixed dirs are skipped from the walk entirely; (b) add `--` to the `grep -qFx` invocation as defense-in-depth so any future callsite that drops the case filter cannot regress the same way. Operators on v0.8.6 with a stray `--`-prefixed orphan dir can move it under `backups/` (which the case filter already excluded) and rerun `bridge-upgrade.sh --apply` without manual intervention. Closes #708.

## [0.8.6] — 2026-05-08

### Highlight — closes 4 v0.7→v0.8 admin-pair migration findings + bundles wave-orchestration

`v0.8.5` shipped on 2026-05-08 closing 16 OrbStack VM E2E findings. Within hours an operator running `agent-bridge migrate isolation-v2 dry-run` on a v0.7.8 install with the documented `bridge_ensure_admin_codex_pair` pattern (`patch` + `patch-dev` co-located on admin's workdir for shared SOUL/MEMORY/CLAUDE.md pair-programming) hit a chain of defects that hard-blocked the migration. v0.8.6 closes the chain:

1. **Migration preflight admin-pair whitelist** — recognize the `<admin>-dev` shared-workdir pattern instead of flagging it as misalignment.
2. **`bridge_expand_user_path` helper sourcing** — moved to `lib/bridge-core.sh` so the migrate dispatch chain doesn't fall through to a `command not found` false-negative.
3. **Public wrapper bypass arming** — `agent-bridge upgrade` / `agent-bridge migrate` now arm the layout resolver bypass before sourcing `bridge-lib.sh`, gated on marker absence so already-migrated v0.8.x installs keep using normal marker resolution.
4. **`features.fast_mode=true` policy pinning** — every codex agent launch (admin-pair backfill, isolated create, dynamic spawn, v0.7→v0.8 migration) now pins fast_mode alongside codex_hooks, idempotently injected into already-rostered launch_cmds at runtime.

Plus the `wave-orchestration` skill is now bundled and auto-distributed to every Agent Bridge agent on bootstrap.

**Operators on v0.8.5: upgrade to v0.8.6.** The wrapper marker-gate ensures markered v0.8.x → v0.8.6 upgrades take the normal marker path (no behavior change). Operators on v0.7.x with admin-pair patterns are now able to run `agent-bridge migrate isolation-v2 ...` / `agent-bridge upgrade --apply` directly from a v0.8.6 source checkout without hitting the v0.8.0 fail-fast self-referential remediation loop.

### Added

- **`wave-orchestration` skill bundled in upstream** (`.claude/skills/wave-orchestration/`, `lib/bridge-skills.sh::bridge_bootstrap_claude_shared_skills` + `bridge_isolated_home_shared_skill_names`): the shared parallel-PR-ship orchestration spine (brief writing → `issue-fixer` dispatch into isolated git worktrees → `codex-rescue` review for >300 LOC specialized work or orchestrator-direct review for mid-size → squash-merge with structured `implement-ok` note → cleanup) is now distributed to every Agent Bridge agent on bootstrap. Pre-Wave the skill lived only in operator-level `~/.claude/skills/` — admin / dynamic / static agents needed manual symlinks. Now the same shared-skill bootstrap that already distributes `agent-bridge-runtime` / `cron-manager` / `memory-wiki` / `patch-permission-approval` also installs `wave-orchestration` so any agent that wakes can dispatch a wave with the same field-tested footgun catalog (8 documented footguns, brief template, codex-rescue setup recipe, 4 worked wave examples). The bundled `issue-fixer` agent (under the skill's `agents/` dir) is project-agnostic — operators copy to `~/.claude/agents/issue-fixer.md` once for `subagent_type: "issue-fixer"` to be available, or fall back to `general-purpose`. Generalized from the operator-private Agent Bridge build: machine-specific paths (operator's plugin cache, `/Users/<u>/...`) replaced with portable `command -v codex` / `PATH=...` resolution; Agent Bridge integration section explains queue-based dispatch (`bridge-task.sh create --to <peer>`) as the alternative to `Agent` tool dispatch for codex peers without that tool.

### Fixed

- **v0.7→v0.8 migration preflight rejected admin-pair shared-workdir installs** (`lib/bridge-isolation-v2-migrate.sh::bridge_isolation_v2_migrate_check_profile_home_overrides`, `lib/bridge-core.sh::bridge_expand_user_path`): two layered defects surfaced by an operator running `agent-bridge migrate isolation-v2 dry-run` on a v0.7.8 install with the documented PR #691 admin-pair pattern (`patch` + `patch-dev` co-located on the admin's workdir for shared SOUL/MEMORY/CLAUDE.md pair-programming). (a) The preflight rejected `<admin>-dev`'s explicit `BRIDGE_AGENT_PROFILE_HOME` pointing at the admin's workdir as a "misalignment", even though `bridge_ensure_admin_codex_pair` documents same-workdir as the entire point of the pair (`pair_workdir="$(bridge_agent_workdir "$admin")"` + `agent create --allow-shared-workdir`). The preflight wording was `[경고]` but the same code path called `bridge_die` on `--apply`, hard-blocking the migration. Whitelist the admin-pair pattern: a `<admin>-dev` agent whose admin exists in the roster, whose admin and pair both run in shared mode, and whose override expands to the admin's workdir is now accepted as the documented co-located pattern. Whitelist is intentionally tight — operators with stale shared-mode overrides unrelated to the pair pattern still see the misalignment warning. (b) `bridge_expand_user_path` lived in `bridge-agent.sh` (the executable) but was called from `lib/bridge-isolation-v2-migrate.sh` whose dispatch goes through `bridge-migrate.sh -> bridge-lib.sh` — `bridge-agent.sh` was never sourced, so the helper was undefined at the call site. The override fell through as the empty string, and an operator who *aligned* their `BRIDGE_AGENT_PROFILE_HOME` to exactly the v2 path was still silently flagged as mismatched (false-negative whose only stderr signal was a `bridge_expand_user_path: command not found` line that operators reasonably read as cosmetic). Move the helper to `lib/bridge-core.sh` (sourced by every consumer through `bridge-lib.sh`) as a bash-native implementation — byte-equivalent for the controller-relative paths the roster uses, no python startup, no sourcing dependency on the executable. The migration preflight also normalizes paths (trailing-slash strip) before the compare so `/x/` vs `/x` no longer flags. Operator-side workaround (manually `unset BRIDGE_AGENT_PROFILE_HOME[<admin>-dev]` before migration) is no longer required.
- **public `agent-bridge upgrade` / `agent-bridge migrate` failed at v0.8.0 layout fail-fast on markerless v0.7.x installs** (`agent-bridge` wrapper, `lib/bridge-layout-resolver.sh::_bridge_layout_resolver_bypass_active`): an operator running `agent-bridge upgrade --apply` (or `agent-bridge migrate isolation-v2 dry-run/apply`) from a v0.8.5 source checkout against a still-markerless v0.7.x live install hit `Agent Bridge v0.8.0 requires isolation-v2` and a self-referential `remediation: run agent-bridge upgrade --apply to migrate` — i.e. the documented remediation was the very command that just died. The wrapper sourced `bridge-lib.sh` (firing the resolver) BEFORE its dispatch `case` could exec `bridge-upgrade.sh` / `bridge-migrate.sh`; those underlying scripts arm `BRIDGE_LAYOUT_RESOLVER_BYPASS=upgrade-migrate:<nonce>` themselves but only after they're exec'd, by which time the wrapper has already fail-fasted. Workarounds (path-shadowing the v0.7.x live CLI, or invoking `bridge-upgrade.sh` / `bridge-migrate.sh` directly) were undocumented. Wave-5+1 hotfix arms the same bypass in the wrapper for `upgrade` / `migrate` subcommands BEFORE the bridge-lib.sh source (mirroring the existing `init` / `bootstrap` arming for `fresh-install:<nonce>`), and extends `_bridge_layout_resolver_bypass_active`'s handshake to accept `agent-bridge` alongside `bridge-upgrade.sh` / `bridge-migrate.sh` as the owner script. Process-tree descendant gate via owner-PID is preserved, so a leaked env crossing into a sibling tree still fails the check. Closes the OrbStack VM verify finding from PR #704 r1.
- **codex agents launched without `features.fast_mode=true`** (`bridge-agent.sh::bridge_agent_default_launch_cmd`, `lib/bridge-state.sh::bridge_codex_launch_with_hooks`, `lib/bridge-state.sh::bridge_build_dynamic_launch_cmd` + `bridge_build_resume_launch_cmd`): every codex agent launch now pins `features.fast_mode=true` alongside `features.codex_hooks=true`. Pre-hotfix the codex CLI ships fast_mode as a stable=true default, but an operator `~/.codex/config.toml` that flips it to false (or a downstream policy override) silently dropped every agent off the fast inference path — admin-pair backfill, isolated agent create, dynamic agent spawn, and v0.7→v0.8 migration all carried only `codex_hooks`. Pin `fast_mode` in the same injection point so the policy is auditable from the roster's stored launch_cmd, and idempotently inject it into already-rostered launch_cmds at runtime via `bridge_codex_launch_with_hooks` (the helper now ensures BOTH features are present, recognizing `--enable <feature>` and `-c features.<feature>=true` forms). Closes the Wave-5+1 operator request to make fast-mode the policy default for every codex call (skill, plugin, pair backfill, migration).

## [0.8.5] — 2026-05-08

### Highlight — closes 16 release-blocker findings surfaced by the v0.8.4 OrbStack VM E2E retest chain

`v0.8.4` shipped on 2026-05-07. Follow-up OrbStack Linux VM end-to-end verification (Debian 12 + Oracle 9.7) found a 4-wave chain of release-blocker regressions: silent failed-upgrade JSON, daemon stop/start/status disagreement, scaffold predicate misfire on `agent create --isolate`, partial-state status/show/doctor crashes, v2 layout `home/`-vs-`workdir/` divergence, admin-pair backfill spurious warning, and v0.7→v0.8 migration aborts on long-running agent sessions. Wave-5 closes the 3 follow-up findings the Wave-4 retest surfaced: fresh-init missing live CLI, scaffold sudo silent-failure masking, and isolated-agent rerender state-surface mismatch. v0.8.5 is the first v0.8.x release where the OrbStack VM E2E acceptance gate (3 scenarios: fresh Debian install, Oracle 9.7 v0.8.x→v0.8.x upgrade, v0.7.7 → v0.8.x migration) passes deterministically.

**Operators on v0.8.4: upgrade to v0.8.5.** No separate v0.8.4 stop is required; `agent-bridge upgrade --apply` from a v0.8.4 install converges to v0.8.5 in one pass.

### Fixed

- **fresh `agent-bridge init` left no live CLI under `$BRIDGE_HOME`** (`bridge-init.sh::bridge_init_ensure_live_cli`): on a non-dry-run init from a source checkout, `~/.agent-bridge/agent-bridge` was never materialized — `bridge-init.sh` only scaffolded `state/`, `runtime/`, `shared/`, the v2 marker, and the admin/admin-pair role blocks; the only code that copies tracked source into `$BRIDGE_HOME` was the standalone `scripts/deploy-live-install.sh` (documented in `OPERATIONS.md` as the upgrade path, never wired into fresh init). Operators and the OrbStack VM E2E retest harness (task #4280 Scenario A) followed the documented post-clone flow `git clone … && bash bridge-init.sh && ~/.agent-bridge/agent-bridge agent create …` and got `~/.agent-bridge/agent-bridge: No such file or directory`. The new `bridge_init_ensure_live_cli` step runs after preflight on the non-dry-run path, short-circuits when the live CLI already exists or when `$SCRIPT_DIR == $BRIDGE_HOME` (re-init / self-deploy), and otherwise dispatches `scripts/deploy-live-install.sh --target $BRIDGE_HOME` through `bridge_init_run_step` so a deploy failure fail-fasts the whole init rather than swallowing into a silent partial state. `agent-bridge init` is now a single self-contained post-clone entry point. Closes the front-line CLI-path failure surfaced repeatedly across Wave-3 / Wave-4 retests (#4226 noted as known limitation, #4280 escalated).
- **`agent rerender-settings --apply` reported `needs-rerender` indefinitely for v2 linux-user-isolated agents** (`bridge-agent.sh::bridge_agent_shared_settings_plan_json`, `bridge-agent.sh::run_rerender_settings`): for isolated agents the apply-success branch reused the pre-apply plan as the post-apply state (`after_json="$before_json"`), and the plan helper itself read settings from `$workdir/.claude/settings.json` plus the per-agent shared `settings.effective.json` — neither of which is the path `bridge_install_isolated_home_settings` actually writes. The renderer for isolated agents installs both `settings.json` (root-owned symlink) and `settings.effective.json` (root-owned regular file) under `<isolated-home>/.claude/`, mode `0750 root:os_user`, which the controller (other) cannot stat without sudo. Result: every rerun of `agent rerender-settings --apply` for an isolated agent landed rc=0 but the row still reported `link.ok=false` / `effective.matches_expected=false` / `status=needs-rerender`. Task #4280 Wave-4 retest Scenario B surfaced this on `bob`: two consecutive applies, both rc=0, both still flagged `bob` as needs-rerender. The plan helper now detects `bridge_agent_linux_user_isolation_effective`, points the python at `<isolated-home>/.claude/{settings.json,settings.effective.json}`, and runs the read under `bridge_linux_sudo_root` so root traversal succeeds. The apply-success branch re-probes via the helper instead of cloning `before_json`. Non-isolated agents continue to read the workdir/.claude paths via plain `python3`. Refactored the inline python script body to a single staged-temp file shared by both branches so future plan-helper changes apply uniformly. Investigated against task #4280 OrbStack VM E2E retest, scope-controlled to `bridge_agent_shared_settings_plan_json` + the apply-success branch in `run_rerender_settings`.
- **scaffold sudo-handoff silenced every failure on `agent create --isolate`** (`bridge-agent.sh::bridge_scaffold_agent_home`): every `bridge_linux_sudo_root mkdir/chown/chmod` in the v2 sudo-handoff block was wrapped in `2>/dev/null || true`, so when the controller's sudo NOPASSWD whitelist did not cover those operations (the canonical `bridge_migration_install_sudoers` entry only whitelists `tmux + bash`) the entire block silently no-op'd and the plain `mkdir -p "$home"` further down the function reported raw `mkdir: cannot create directory …: Permission denied`. Operators chasing this on the OrbStack VM E2E retest (task #4280 Scenario A.b, ~2026-05-07) had no signal that sudo was the actual cause — the scaffold appeared to skip sudo entirely and crash on a parent-perms problem. Each `mkdir/chown/chmod` step now `bridge_die`s with the failed path and a remediation hint pointing at the sudo NOPASSWD whitelist when the operation fails. Same-state idempotent reruns continue to be a bytewise no-op. Scope-controlled to the per-agent root + `$home` + v2 sibling workdir/ — paths the predicate has already confirmed are isolated-managed. The v2 ancestor parents (`$BRIDGE_DATA_ROOT`, `$BRIDGE_AGENT_ROOT_V2`) are intentionally NOT normalized here even though the canonical contract in `lib/bridge-isolation-v2.sh:36-47` says `agents/` should be `root:root 0755`: `bridge_agent_default_home` resolves shared-mode agents' home to the same v2 root, so locking the parents to root-owned would break the non-isolated v2 `agent create` path which reaches plain `mkdir -p "$home"` without a sudo handoff (caught by codex review on PR #701 r1). Operators who want the full canonical layout should use the migration tool, which owns parent normalization. Fresh `agent-bridge agent create <name> --engine codex --isolate --os-user <u>` on Debian/Oracle Linux now either completes rc=0 (sudo + isolation correctly configured) or fails with an actionable `bridge_die` naming the exact path and operation that needs operator attention. Investigated against task #4280 OrbStack VM E2E retest.
- **#698 v0.7→v0.8 migration aborted when v0.7.7 agents stayed active in tmux** (`lib/bridge-isolation-v2-migrate.sh::bridge_isolation_v2_migrate_orchestrate_stop`): the per-agent stop loop bounded-retried `bridge-agent.sh stop <agent>` and aborted the entire upgrade with `agents still active after per-agent stop loop: <N>` whenever a v0.7.7 daemon-spawned tmux session refused to die in the loop window (CLI holding the foreground, tmux server still tracking attached client). Wave-3 OrbStack VM E2E retest #4226 Scenario C surfaced this on Oracle Linux 9.7: live `VERSION` + `installed_version` stayed at `0.7.7`, `apply-live` never ran, operator had to manually `tmux kill-session` for every alive session before retrying. Added a force-kill fallback after the existing retry loop: still-active agents are looked up via `bridge_agent_session`, escalated through `bridge_kill_agent_session` (`tmux kill-session -t <session>` + 1s bounded re-poll), and the force-killed list is written to `state/migration/force-killed-sessions.json` (timestamped) so post-migration audit can see which sessions were stopped non-cooperatively. The migration only aborts now if force-kill ALSO fails to clear the active set, with a more actionable `agents still active after force-kill fallback: <N> (sessions: <list>)` reason. First-run upgrade now succeeds even when daemon-spawned agent sessions are alive. The force-kill outcome is also visible to programmatic operators reading `agent-bridge upgrade --apply --json`: on success the `isolation_v2_migration` payload carries `force_killed_sessions` (list of agent ids) and `force_killed_sidecar` (target-root-relative path) when non-empty; on the force-kill-failure abort path the upgrade failure envelope's `error.detail` (and `state/migration/last-error.json`) now carry a structured `reason: "force-kill-failed"` body with `remaining_count`, `forced_pairs` (the stuck `agent/session` names), and `force_killed_sessions` instead of the previous generic `isolation-v2 migration failed` detail. (refs #698)
- **#683 daemon stop/start/status post-upgrade inconsistency** (`bridge-daemon.sh::cmd_start`, `lib/bridge-state.sh::bridge_daemon_pid`): `bridge-daemon.sh start` now detects stale pid files via `kill -0` (and via cmdline mismatch on the recorded pid, to handle pid recycling), reports `stale pid file (pid=NNNN no longer alive), starting fresh`, removes the stale pid file, and proceeds. `bridge_daemon_pid` rejects a recorded pid whose cmdline no longer ends in `bridge-daemon.sh run`, so `cmd_status` and `cmd_start` agree on daemon-up determination on the post-upgrade verification path that surfaced the contradictory `start: already running pid=NNNN` / `status: stopped socket_listener=off` output (Scenario B / Oracle 0.8.2 → 0.8.4 OrbStack VM E2E retest, task #4195).
- **#691 admin-pair backfill emitted spurious warning post-#686 fix** (`bridge-agent.sh::run_create`, `lib/bridge-admin-pair.sh::bridge_ensure_admin_codex_pair`): added `agent create --allow-shared-workdir` opt-out so the admin-pair backfill (which legitimately layers `<admin>-dev` onto the admin's already-scaffolded workdir) bypasses the non-empty-workdir guard. Post-#686, `bridge_scaffold_agent_home` materializes both `home/` and `workdir/`, and `bridge_bootstrap_project_skill` populates `<workdir>/.agents/skills/agent-bridge/` for codex admins — `run_create`'s existence check tripped on that managed content and `bridge_die`d, which `bridge-init.sh` swallowed into a non-fatal "admin-pair backfill failed" warning + a missing `<admin>-dev` registration + missing CLAUDE.md SOP block. Fresh `bridge-init.sh --admin admin --engine codex --skip-channel-setup` now finishes rc=0 with no admin-pair warning and the pair + SOP block both materialize.
- **#677 isolated agent scaffold Permission denied on `agent create`** (`bridge-agent.sh::bridge_scaffold_agent_home`): scaffold now uses sudo-handoff (`bridge_linux_sudo_root mkdir/chown/chmod`) to pre-create the per-agent v2 root and `$home` with controller ownership when `bridge_agent_linux_user_isolation_effective` returns true, so the rest of the scaffold (template renders, mkdirs, chmods) runs as plain controller writes. `bridge_linux_prepare_agent_isolation` (which runs after scaffold) then normalizes ownership/mode to the canonical `root:ab-agent-<name> 2750` per-agent root + `<isolated>:ab-agent-<name> 2770` subdirs and `chown -R $os_user $workdir` transfers scaffolded contents to the isolated UID. Closes the front-line failure that PR #675 had scope-controlled out — fresh `agent create <name> --engine codex --isolate --os-user <u>` on Debian / Oracle Linux now completes rc=0 with no Permission denied. Mirrors PR #675's `bridge_state_sudo_install_v2_file` sudo-handoff pattern in `lib/bridge-state.sh`.
- **#693 isolated agent scaffold permission still failed post-PR #688/#690** (`bridge-agent.sh::bridge_scaffold_agent_home`, `bridge-agent.sh::run_create`): PR #688's sudo-handoff block was correct in principle but its predicate (`bridge_agent_linux_user_isolation_effective "$agent"`) read `BRIDGE_AGENT_ISOLATION_MODE[<agent>]` / `BRIDGE_AGENT_OS_USER[<agent>]` from the in-memory roster — and at scaffold time those maps have not yet seen the new agent (the role block is written and the roster is reloaded by `run_create` AFTER `bridge_scaffold_agent_home` returns). The predicate therefore always returned false on `agent create --isolate`, the entire sudo block silently no-op'd, and plain `mkdir -p "$home"` failed because `data/agents/` is `root:root mode 755`. Pass `isolation_mode` + `os_user` as explicit parameters to `bridge_scaffold_agent_home` from `run_create` and use them directly inside the predicate (legacy roster-driven branch retained for any pre-#693 callsite that omits the new args). Fresh Debian / Oracle Linux `agent create <name> --engine codex --isolate --os-user <u>` now actually exercises the PR #688 sudo path and completes rc=0. Investigated against task #4211 OrbStack VM E2E retest Scenario A.
- **#694 status/show/doctor still crashed on partial isolated agent state post-PR #688** (`lib/bridge-state.sh::bridge_load_static_agent_history`, `bridge-status.py::workdir_display`): two more failure sites the PR #688 fix to `pending_upgrade_conflict_count` did not cover. (a) `bridge_load_static_agent_history` did `source "$file"` after `[[ -f "$file" ]]` succeeded, but the existence test stats parent dirs (group r-x is enough) while reading the file requires the controller's process credential set to include the per-agent group — and supplementary group membership is cached at process start, so a fresh shell after `agent create --isolate` cannot read `runtime/history.env` until re-login. The unhandled `Permission denied` propagated out of `bridge_load_roster`, taking down every `bridge-agent.sh`-loaded entry point (status, show, doctor, list, ...). Added a `[[ -r "$file" ]]` guard before `source` so the load gracefully degrades to the "history file absent" fallback (no restored `AGENT_SESSION_ID`; next session-id rewrite restores it). (b) `bridge-status.py::workdir_display` called `Path(expanded).is_dir()` which can raise `PermissionError` on the same partial-state agent's `data/agents/<agent>/workdir/` subtree, crashing `agent-bridge status --all-agents`. Wrapped in `try/except OSError` and surface a `[unreadable]` tag in the dashboard row so operators retain observability instead of losing the entire render. Mirrors the graceful-walk pattern PR #688 added one site upstream.
- **#680 `bridge-init.sh` first-run on fresh install exited rc=1 with empty log** (`bridge-agent.sh::run_create`): on a fresh v2 install, `agent create` invoked `bridge-start.sh <agent> --dry-run` purely as informational diagnostic capture, but `bridge_agent_workdir` resolves to `<agent-root>/workdir/` while `bridge_scaffold_agent_home` materializes `<agent-root>/home/` — the dry-run failed `workdir가 없습니다`, command-substitution propagated rc=1 to `set -e`, and `agent create` aborted silently before printing anything. `bridge-init.sh` redirected create's stdout to `/dev/null`, leaving operators with rc=1 + empty log on first-run init while the rerun (which short-circuits via `bridge_agent_exists`) succeeded. The dry-run capture now tolerates non-zero rc and surfaces the actual rc through the printed `start_dry_run:` field; first-run `bridge-init.sh` exits rc=0 on a clean home, idempotent rerun preserved, the underlying scaffold-vs-resolver mismatch remains visible in the create output for follow-up. (refs #680)
- **#681 `agent-bridge status --all-agents` PermissionError crash on partial isolated agent state** (`bridge-status.py::pending_upgrade_conflict_count`): the `home.rglob("*.upgrade-conflict")` walk used by the dashboard's `pending upgrade-conflicts` warning line propagated the first `PermissionError` raised by an unreadable `data/agents/<broken-agent>/workdir/` subtree out of the function, crashing the entire status render. Replaced with an explicit `os.scandir` stack walk that catches `PermissionError`/`OSError` per directory: a single denied subtree is skipped, iteration continues, and operators retain dashboard observability of the partial-create state they need to triage. `backups/...` exclusion behavior preserved.
- **#682 v0.7→v0.8 migration emits invalid `--json` on failure + leaves `installed_version` stale at 0.7.7** (`bridge-upgrade.sh`): two related findings from v0.8.4 OrbStack VM E2E retest task #4195 Scenario C. (a) `agent-bridge upgrade --apply --json` rc=1 path now emits a single valid JSON envelope on stdout with `error: { reason, detail, remediation }`, the `isolation_v2_migration` payload, and the version fields — instead of dropping out of the JSON contract entirely on `bridge_die` / `set -e` aborts. Wired through an EXIT trap that fires when `JSON=1` and `_BRIDGE_UPGRADE_JSON_EMITTED=0`; the migration block populates `_BRIDGE_UPGRADE_DIE_{REASON,DETAIL,REMEDIATION}` so the envelope carries actionable detail rather than just `rc=1`. (b) `installed_version` / `installed_ref` / `installed_head` (the metadata under `state/upgrade/last-upgrade.json`) now advances atomically with the live `VERSION` write — the `write-state` call moved from the very end of the apply path to immediately after `apply-live`, so any subsequent helper failure (shared-settings rerender, migrate-agents, daemon-restart-blocked-by-supplemental-group-cache) cannot leave the two states desynchronized. The previous tail position produced the observed `live VERSION=0.8.4 + installed_version=0.7.7` mismatch on rc=1 paths.
- **#686 v2 layout: `bridge_scaffold_agent_home` only created `home/` while resolver expected `workdir/`** (`bridge-agent.sh::bridge_scaffold_agent_home`): scaffold now also materializes the v2 sibling `workdir/` (`<BRIDGE_AGENT_ROOT_V2>/<agent>/workdir`) per the canonical ASCII layout in `lib/bridge-isolation-v2.sh` (both subdirs are required, distinct purposes — `home/` is the isolated process HOME, `workdir/` is the project tree the agent operates in). On v2 fresh installs, `bridge-start.sh --dry-run` previously failed `workdir가 없습니다` because `bridge_agent_workdir` returns `<agent-root>/workdir/` while the scaffold materialized only `<agent-root>/home/`. This closes the silent-fail mode that PR #685 made visible (`start_dry_run: warn (rc=1)`). Legacy installs (no `BRIDGE_AGENT_ROOT_V2`) keep `home == workdir` and are unaffected. (refs #686)

## [0.8.4] — 2026-05-07

### Highlight — closes 5 release-blocker regressions surfaced by v0.8.3 OrbStack VM E2E

`v0.8.3` shipped on 2026-05-07 with the silent-data-loss fix for v0.7.x → v0.8.x upgrades, but follow-up OrbStack Linux VM end-to-end verification (Debian 12 + Oracle 9.7) found 5 release-blocker regressions: fresh install rejection, silent failed upgrade, broken Linux isolation, broken v0.7.x → v0.8.3 migration, and non-idempotent rerender. v0.8.4 closes all five plus a host regression in `agent-bridge agent doctor`.

**Operators on v0.8.3: upgrade to v0.8.4.** Operators on v0.7.x → v0.8.3 migrations that aborted on Linux: re-run `agent-bridge upgrade --apply` after upgrading to v0.8.4 source.

### Fixed

- **#665 fresh install rejected on markerless install** (`bridge-init.sh`, `bridge-bootstrap.sh`, `agent-bridge`, `lib/bridge-layout-resolver.sh`): both the underlying scripts and the public `agent-bridge init` / `agent-bridge bootstrap` CLI wrappers now arm a one-shot `BRIDGE_LAYOUT_RESOLVER_BYPASS=fresh-install:<nonce>` env so the v0.8.0 fail-fast guard accepts a clean home as a fresh install while still rejecting `markerless(existing-install)`. Trap on EXIT prevents env leakage to sibling shells. Resolver argv handshake updated to accept the wrapper argv pattern. (#674)
- **#666 silent failed upgrade — `rc=0 + files_copied=0 + version mismatch`** (`bridge-upgrade.py::analyze_live`): the per-file classifier now force-deploys (`upstream_only`) on cross-version upgrade when `base_ref` is not resolvable, instead of falling back to `keep_live`. Same-version reruns (operator drift) and missing-VERSION corner stay on `keep_live`. Dev clones with `0.0.0-dev` source sentinel correctly classify as unknown-skip. (#671)
- **#667 Linux isolation v2 broken** (`lib/bridge-isolation-v2.sh`, `lib/bridge-agents.sh`, `lib/bridge-isolation-v2-migrate.sh`, `lib/bridge-state.sh`): two layered fixes. (a) `bridge_isolation_v2_agent_group_name` on Linux now hash-truncates long agent names instead of hard-rejecting (`<first-N-chars>-<7-char-sha256>`). Darwin keeps full 255-char names. (b) Per-agent root mode stays at `2750` (was 2750→2770 attempt in r1, reverted) — `2770` would break the credentials/ isolation guarantee because group rwx on parent lets group members `rmdir credentials/`. Controller-write sites under `BRIDGE_AGENT_ROOT_V2/<agent>/` (e.g., `runtime/history.env`) now route through the sudo-handoff helper `bridge_state_sudo_install_v2_file` (mirrors PR #673's cross-UID install pattern). `apply_for_upgrade` runs `normalize_layout` before the marker-present skip so existing v0.8.0~v0.8.3 installs get re-pinned to canonical modes. (#675)
- **#668 v0.7.7 → v0.8.3 migration aborted on Linux daemon restart** (`lib/bridge-isolation-v2-migrate.sh::orchestrate_restart`, `bridge-upgrade.sh`): root cause was supplemental-group-cache — `usermod` adds the operator to the new `ab-controller` group but the running shell's group set is cached until next login, so spawning the daemon from this shell inherits stale groups and dies. The non-launchd branch now treats `bridge-daemon.sh start` + `wait_daemon_present` as best-effort: warns + advances the marker + lets `apply-live` install v0.8.x code. Operator finishes by re-login + `agb daemon start`. The `upgrade --json` payload now surfaces `migration_requires_relogin: true` via the `isolation_v2_migration` field for JSON-mode operators. (#674)
- **#669 rerender cross-UID Permission denied not idempotent** (`bridge-agent.sh::run_rerender_settings`, `lib/bridge-hooks.sh`): for v2 linux-user-isolated agents, the rerender helper now detects `bridge_agent_linux_user_isolation_effective` up-front and routes through `bridge_install_isolated_home_settings` (sudo-handoff, foreign-UID atomic install), instead of the original `bridge_link_claude_settings_to_shared` path that hit `PermissionError` on `<workdir>/.claude/`. The previous `|| true` swallow at the rerender call site is dropped — internal helper failures (mkdir/render/install/atomic-mv/symlink) now propagate `rc=1` + increment `failed_count` + surface in audit JSON instead of silently reporting success. Migration callsites still use `|| bridge_warn` for best-effort. (#673)
- **#670 agent-doctor leaked stale temporary BRIDGE_HOME hook paths into `~/.codex/hooks.json`** (`lib/bridge-doctor.sh::bridge_doctor_invoke_agent`): every doctor child invocation (CRUD steps + cleanup-trap delete) now exports `BRIDGE_CODEX_HOOKS_FILE=$BRIDGE_HOME/.codex/hooks.json` inside the wrapper subshell only. Codex CLI then reads/writes the doctor's isolated hooks.json instead of the operator's real `~/.codex/hooks.json`. The redirected hooks.json dies with the temp BRIDGE_HOME on exit. Operator's global config sha256 byte-identical before/after doctor run. (#672)

### Known issues / v0.8.5 follow-up

- **`bridge_scaffold_agent_home` Permission denied for short-name isolated agents on `agent create`**: a separate failure point from #667. The scaffold path runs before `bridge_linux_prepare_agent_isolation` and may still hit `mkdir: cannot create directory data/agents/<agent>: Permission denied` on Linux. Fix scope-controlled out of v0.8.4 r2 to keep PR size bounded; tracked for v0.8.5.
- **non-blocking migration warnings** (deferred from #668): non-launchd daemon-start errors are uniformly labeled supplemental-group-cache (unrelated daemon failures get swallowed); systemd path is not distinguished from no-init fallback; `tests/isolation-v2-pr-f/smoke.sh` is stale relative to current v0.8.0 rejection behavior; concurrent init invocations on different `--data-root` race without an init-level lock.

### Operator notes

- **v0.8.3 was not OrbStack-VM-verified** despite the release notes claiming end-to-end coverage. v0.8.4 should be the first v0.8.x release where the OrbStack VM E2E (3 scenarios: fresh Debian install, Oracle 9.7 v0.8.x→v0.8.x upgrade, v0.7.7 → v0.8.x migration) passes end-to-end. Wave-end VM retest pending.
- The wave that produced v0.8.4 used 1 ephemeral `upstream-issue-fixer` per track + `codex:codex-rescue` review per PR, with `orchestrator-direct` review fallback when the codex broker hit the `'mode,'` model config error mid-wave (memory `feedback_codex_review_parallel_subagent.md`).

## [0.8.3] — 2026-05-07

### Highlight — fixes silent data loss on v0.7.x → v0.8.x upgrade

`v0.8.3` is the working version on the v0.8.x line. v0.8.0 / v0.8.1 / v0.8.2 silently lost agent context on every upgrade because `apply_for_upgrade` never invoked `emit_plan` — the migration wrote markers and created v2 directories but never moved v1 files into them. Operators saw "running" agents post-upgrade with empty `workdir/` while CLAUDE.md, MEMORY.md, memory/, .claude/, and skills/ sat orphaned at the v1 paths.

**Operators on v0.8.0 / v0.8.1 / v0.8.2: skip those releases. Upgrade v0.7.x → v0.8.3 directly.** Most v0.8.x installs that hit the silent data loss can be recovered: the v1 content is still on disk at `agents/<n>/` because v0.8.x never deleted it. Reset by removing `state/layout-marker.sh`, deleting `state/migration/`, removing `ab-agent-*` groups, then re-deploy v0.7.8 source first to flatten v0.8.x binary residue, then upgrade to v0.8.3.

### Fixed

- **Silent data loss** (`lib/bridge-isolation-v2-migrate.sh:apply_for_upgrade` and `apply`): the upgrade hot path now invokes `emit_plan` to generate proper 4-col `(mapping_id, legacy_src, v2_dst, delete_eligible)` rows for `mirror_all`. Files now actually relocate from v1 paths (`agents/<n>/CLAUDE.md`) to v2 paths (`agents/<n>/workdir/CLAUDE.md`, `agents/<n>/home/.claude/`, etc.). Verified via OrbStack VM end-to-end on Oracle Linux 9.7. (#660)
- **linux-user-isolated agents now mirror correctly** (`mirror_one`, `emit_row`): cross-UID source detection via `stat`; sudo-wrapped `mkdir`/`rsync`/`rm` so the controller can read isolated agent files without supplementary group membership being active in its current process. Without this, `agents/<isolated>/.claude` (mode 0600 owned by `agent-bridge-<n>`) was invisible to the controller's mirror. (#660)
- **macOS launchd KeepAlive race** (`lib/bridge-isolation-v2.sh`, `orchestrate_stop/restart`): the daemon respawned within 1-2s of `bridge-daemon.sh stop`, racing the migration's 10s `wait_daemon_gone` poll and aborting every macOS upgrade. v0.8.3 uses `launchctl bootout` / `launchctl bootstrap` (modern macOS lifecycle, NOT deprecated `launchctl load`) to fully unload the daemon during migration. Cross-run recovery via `state/migration/launchd-restore.json`. Linux unaffected. (#661)
- **32-char group-name limit was Linux-only but enforced everywhere** (`bridge_isolation_v2_agent_group_name`): macOS `dseditgroup` tolerates 255+ chars; the Linux `groupadd` 32-char ceiling was rejecting long-named agents on macOS unnecessarily. Branch the cap by `uname`. (#658)
- **Misleading `non-agent dir` warning for v1-layout agents** (`capture_all_agents_snapshot`): the `home/` subdir filter now distinguishes v1-layout-in-roster (silent — they migrate via the roster path) from genuinely-orphan dirs (warned). (#660)
- **Rollback never reversed file relocation** (`bridge_isolation_v2_migrate_rollback`): now iterates the manifest in reverse for `delete_eligible=1 && verify_status=ok` rows, restoring v1 paths via `mv` (same-fs) or `rsync + rm` (cross-fs). `tac` (Linux) / `tail -r` (BSD) for portability. (#660)
- **Rollback restart yanked attached agents** (`orchestrate_restart`): now respects the same attached-agent skip the dry-run pass already reported. (#660)
- **Empty-source global rows aborted the migration** (`emit_row`): the `runtime_shared` mapping (empty `runtime/shared` tree → populated `shared/`) hit transient `rsync_fail_23` and aborted the entire migration over zero load-bearing content. Skip global rows where the source dir contains no files or symlinks. (#660)

### Operator notes

**v0.7.x → v0.8.3 upgrade flow**:

1. `agent-bridge upgrade --apply` from any v0.7.x install. Migration is automatic.
2. **First run may exit with rc=1** with downstream Python warnings about `shared Claude settings rerender failed for <isolated-agent>`. This is a known v0.8.3 limitation — the migration itself succeeded (manifest reports 0 mirror failures, marker is written, files are relocated), but the post-migration Python helper hits permission errors on isolated agents' `home/.claude/settings.json` because supplementary group membership isn't yet active in its process. **Re-run `agent-bridge upgrade --apply`** — second run is idempotent and exits rc=0 cleanly.
3. macOS hosts: launchd integration is automatic. No manual `launchctl` required.
4. Linux per-UID isolated agents: passwordless sudo required. The migration uses sudo for cross-UID `mkdir`, `rsync`, `rm`, `setfacl`, `chgrp`.
5. After migration: agents' content lives at `agents/<n>/workdir/` (CLAUDE.md, MEMORY.md, memory/, skills/, users/) and `agents/<n>/home/.claude/`. v1 paths for `delete_eligible=0` rows (CLAUDE.md, MEMORY.md, etc.) are retained for dual-read until a future commit step.

**Recovering from v0.8.0 / v0.8.1 / v0.8.2 partial state**:

```bash
sudo systemctl stop agent-bridge   # or: agent-bridge daemon stop
sudo rm -f ~/.agent-bridge/state/layout-marker.sh
sudo rm -rf ~/.agent-bridge/state/migration ~/.agent-bridge/state/isolation-v2
sudo groupdel ab-agent-* 2>/dev/null || true
sudo groupdel ab-shared ab-controller 2>/dev/null || true
# Re-deploy v0.7.8 to flatten v0.8.x binary residue:
git -C ~/.agent-bridge-source checkout v0.7.8
bash ~/.agent-bridge-source/scripts/deploy-live-install.sh
# Then upgrade to v0.8.3:
git -C ~/.agent-bridge-source fetch origin && git -C ~/.agent-bridge-source checkout v0.8.3
~/.agent-bridge/agent-bridge upgrade --source ~/.agent-bridge-source --version 0.8.3 --apply
# (re-run if rc=1 — second run is idempotent)
```

### Known limitation (v0.8.4 follow-up)

`bridge-agent.sh rerender-settings` and `bridge-upgrade.py:cmd_migrate_agents` hit `Permission denied` reading isolated agents' v2-located config files even after migration completes, because supplementary group membership for the controller's process is frozen at process start. Workaround: re-run `agent-bridge upgrade --apply` (idempotent; second run succeeds rc=0 because group membership has propagated to a fresh subshell). v0.8.4 will fix the Python helpers to use sudo when reading cross-UID paths.

### Verified

- VM smoke (Oracle Linux 9.7, kernel 6.19, Bash 5.1): v0.7.8 → v0.8.3 upgrade with 1 shared agent + 1 linux-user-isolated agent. Manifest 26 rows, 0 mirror failures. `agents/<n>/workdir/` populated with full v1 content. `agents/<n>/home/.claude/` migrated. Layout marker written. agent list works.
- bash -n / shellcheck clean across all touched files.

## [0.8.2] — 2026-05-06

### Highlight — emergency hotfix: Linux per-UID isolated upgrade unblocked

`v0.8.2` is an emergency hotfix on top of v0.8.1 (which itself unblocked macOS upgrade earlier the same day). v0.8.0 + v0.8.1 `agent-bridge upgrade --apply` still failed on Linux hosts that contained at least one per-UID isolated agent: the T3 migration tool's `cmd_migrate_agents` walked every agent home as the controller UID and called `Path.exists()` on paths inside the isolated agent's `0700`-mode `memory/` subtree, which the controller cannot stat. The list-comprehension at `bridge-upgrade.py:524` then propagated `PermissionError` and aborted the entire multi-agent migration loop before any other agent could be touched. This wedged the host: T1's hard-cut to v2 means v0.8.0+ refuses to run normally until the migration completes, and the migration could not complete while a single isolated agent existed.

v0.8.2 fixes the migration tool with a two-layer change: (1) `migrate_agent_home` no longer walks the `memory/` subtree of `agents/_template/` — per-agent memory wiki is agent-owned data, not template content, and is created on first agent launch; (2) `cmd_migrate_agents` wraps each `migrate_agent_home` call in a try/except for `PermissionError` and records a structured `skipped_isolated` entry (with `agent` + `reason`) in the JSON output so a single denied agent never aborts the multi-agent loop. The downstream payload retains every field that pre-v0.8.2 consumers parse (`agent_count`, `agents_with_additions`, `added_files`, `created_dirs`, `updated_files`, `agents`); three new fields — `migrated_count`, `skipped_isolated_count`, `skipped_isolated` — are additive.

Operators on Linux hosts who attempted v0.8.0 / v0.8.1 upgrade and got blocked: re-run `agent-bridge upgrade --apply` after pulling v0.8.2. The migration is idempotent. v0.8.2 includes both v0.8.1's macOS `flock` fix and this Linux per-UID fix.

### Fixed

- `bridge-upgrade.py:migrate_agent_home` no longer enumerates the `memory/` subtree of the template tree. The skip happens at the top of the `template_root.rglob("*")` loop, parallel to the existing `session-types` skip. The per-agent memory wiki layout is created by the agent's own initializer on first launch under v0.8.0+; the upgrader's contract for isolated agents is that the controller does not enter per-agent owner-only subtrees. Closes #652.
- `bridge-upgrade.py:cmd_migrate_agents` catches `PermissionError` per-agent and records `{"agent": "<name>", "reason": "PermissionError: <path> (per-UID isolated tree)"}` in a new `skipped_isolated` JSON field. Defense in depth — covers any future template addition that re-introduces a 0700 path under an isolated agent's home.

### Added

- New JSON fields on `bridge-upgrade.py migrate-agents` output: `migrated_count` (number of agents whose homes were touched), `skipped_isolated_count` (number of agents the controller could not stat), `skipped_isolated` (list of `{agent, reason}` entries for operator visibility). All existing fields are unchanged.
- `scripts/smoke/upgrade-isolated-agent-migrate.sh` — regression smoke covering: T1 normal agent migration with `memory/` skipped from the template walk; T2 0000-mode agent home reported as `skipped_isolated` with no abort; T3 mixed run keeps the normal agent's migration intact while recording the locked one. Uses chmod-only on macOS + Linux; the controller-side `Path.exists()` failure path is identical with or without cross-UID, so chmod-only is sufficient regression coverage.
- `scripts/smoke-test.sh` and `scripts/ci-select-smoke.sh` — wire the new smoke into the required suite + the `bridge-upgrade.py|bridge-upgrade.sh|VERSION` trigger row.

### Operator notes

- Linux hosts that hit the v0.8.0 / v0.8.1 `PermissionError: [Errno 13] ... agents/<a>/memory/.gitkeep` block: re-run `agent-bridge upgrade --apply` after pulling v0.8.2. No manual filesystem cleanup required — the new code never enters `memory/` and the second-layer try/except absorbs any residual unreachable subtree.
- Per-agent `memory/` tree was never meant to be controller-managed in v2; v0.8.2 codifies that. If your operator workflow depended on the upgrader populating `memory/.gitkeep` under an agent home, that responsibility moves to the agent's first-launch initializer (which already creates the wiki layout for new agents).
- `skipped_isolated_count > 0` in the migration JSON is informational, not a failure. An entry there means the upgrader observed an isolated agent home that the controller cannot stat into; the agent's own next launch will rebuild whatever it needs.

### Verified

- `python3 -m py_compile bridge-upgrade.py` clean.
- `bash -n scripts/smoke/upgrade-isolated-agent-migrate.sh` clean; `shellcheck` clean.
- New smoke 3/3 PASS on macOS (chmod-only simulation): normal-agent migrated; 0000-mode locked-agent reported as `skipped_isolated`; mixed run keeps both behaviors.
- No code changes outside `bridge-upgrade.py:migrate_agent_home`, `bridge-upgrade.py:cmd_migrate_agents`, the new smoke, the smoke-test wiring, `VERSION`, and this CHANGELOG entry.

## [0.8.1] — 2026-05-06

### Highlight — emergency hotfix: macOS upgrade unblocked

`v0.8.1` is an emergency hotfix on top of the v0.8.0 release shipped 6 hours earlier. The v0.8.0 isolation-v2 migration acquired its lock with `flock(1)`, which macOS does not ship by default — every `agent-bridge upgrade --apply` on macOS bailed out at `lib/bridge-isolation-v2-migrate.sh:107` with `flock: command not found` and a confusing "another isolation-v2 migrate operation is in progress" follow-up because the failed `exec 9>"$lock"` left a 0-byte lock file behind. v0.8.1 replaces the `flock`-based primitive with a portable `mkdir`-based atomic lock + PID-file stale-owner detection that works on macOS / Linux / Bash 3.2 baseline with zero external dependencies.

Operators on macOS hosts who attempted v0.8.0 upgrade and got blocked: re-run `agent-bridge upgrade --apply` after pulling v0.8.1. The migration is idempotent and `no_v080_code_installed=yes` on the v0.8.0 failure means apply-live did NOT run, so retry is safe. No manual lock cleanup required — the new code auto-detects stale owners.

### Fixed

- `lib/bridge-isolation-v2-migrate.sh:bridge_isolation_v2_migrate_acquire_lock` no longer depends on `flock(1)`. The lock is now an atomic `mkdir` of `<state>/migration/migrate-isolation-v2.lock.d/`, with `owner.pid` written inside for stale detection. If a prior holder died without releasing, the next acquirer reads `owner.pid`, runs `kill -0` on it, and on a dead PID removes the lock dir + retries once. Race-after-cleanup falls through to a clean `bridge_die`.
- `bridge_isolation_v2_migrate_release_lock` (new helper) plus an EXIT trap ensure the lock dir is cleaned on normal exit AND on crashes (best-effort `rm -rf`; failure is tolerated since the next acquirer's stale-detection handles it).

### Added

- `scripts/smoke/isolation-v2-migrate-lock-portability.sh` — regression smoke verifying lock acquire/release works without `flock` on PATH, that a live owner blocks a second acquirer, and that a stale PID file (dead process) is auto-cleaned + the lock reacquirable. Exercised on every PR via `scripts/smoke-test.sh`.

### Operator notes

- macOS hosts that hit the v0.8.0 `flock: command not found` block: re-run `agent-bridge upgrade --apply` after pulling v0.8.1. No manual lock file cleanup required.
- If the migration was somehow partially applied: the per-agent markers under `$BRIDGE_STATE_DIR/migration/isolation-v2/agents/` are atomic + idempotent. Re-running picks up where it left off.
- The new lock is at `<state>/migration/migrate-isolation-v2.lock.d/` (directory, was a file in v0.8.0). The old `migrate-isolation-v2.lock` 0-byte file is harmless and can be deleted at leisure (`rm $BRIDGE_STATE_DIR/migration/migrate-isolation-v2.lock`).

### Verified

- Unit-tested (Bash 5.x): first-acquire, release, re-acquire, live-owner-blocks-second-acquire, stale-PID-cleanup. All pass.
- Smoke `scripts/smoke/isolation-v2-migrate-lock-portability.sh` 3/3 pass with `flock` stripped from PATH.
- `bash -n` and `shellcheck` clean.
- No code changes outside the lock primitive (acquire/release helpers + 1 trap line).

## [0.8.0] — 2026-05-06

### Highlight — isolation v2 hard-cut + first-class diagnostic + write-shape redesign

`v0.8.0` is the long-planned cut-over from ACL-based isolation (v1) to POSIX-group-based isolation (v2). Operators upgrading from v0.7.x will run an automatic migration during `agent-bridge upgrade --apply` that creates per-agent groups, scrubs extended ACLs, and switches every isolated agent's home to `2770` setgid. The v1 ACL helper surface (`bridge_linux_grant_*`, `bridge_linux_acl_*`, `bridge_linux_repair_*`) is fully deleted (~1000 LoC removed). Three release headlines: a closed-loop `agent doctor` CRUD self-check addressing the constraints that hit PR #615's 4-round cap (#619 → #646), a write-shape detector redesign for Codex companion role hooks that replaces the brittle r1-r5 patches with a default-deny block-mode allowlist + maintained common-shape parser (#639 → #642), and a cross-class isolated read closure for the librarian × isolated-UID memory read failure (#583 → #645). `BRIDGE_DISABLE_ISOLATION=1` is available as a runtime rollback hatch in case v2 hits unforeseen issues post-deploy (T5).

Breaking change for v0.7.x → v0.8.0 upgraders: see KNOWN_ISSUES #16 (Claude first-launch login flow on v2 Linux) and #17 (engine-CLI runtime-only path validation). The migration tool surfaces `migration_requires_relogin=yes` to the upgrade output when macOS supplemental group cache requires re-login.

### Changed (T1 — PR #622, `266d604`)

- Layout resolver hard-cut: `BRIDGE_LAYOUT=v1` and `legacy` now fail-fast at `bridge_resolve_layout()` with a `bridge_die` migration message. v2 is the only accepted layout. See `lib/bridge-layout-resolver.sh:135-160`.

### Removed (T2 — PR #641, `6a546a2`)

- 11 v1 ACL helper definitions deleted from `lib/bridge-agents.sh`: `bridge_linux_grant_engine_cli_access`, `bridge_linux_grant_bin_dir_access`, `bridge_linux_grant_claude_credentials_access`, `bridge_linux_grant_traverse_chain`, `bridge_linux_acl_add`, `bridge_linux_acl_add_recursive`, `bridge_linux_acl_remove_recursive`, `bridge_linux_acl_add_default_dirs_recursive`, `bridge_linux_acl_repair_channel_env_files`, `bridge_linux_repair_isolated_claude_read_lens`, `bridge_linux_repair_claude_credentials_access`. 38 `bridge_isolation_v2_active` runtime branches flattened to v2-only. ACL preflight blocks deleted from `bridge-start.sh:294-308` and `bridge-daemon.sh:3046-3047`. Net: ~1000 LoC removed.

### Added (T3 — PR #640, `2911cb9`)

- Upgrade-integrated v2 migration. `agent-bridge upgrade --apply` now invokes `bridge_isolation_v2_migrate_apply_for_upgrade` between the conflicts-reconcile and apply-live phases. Per-agent enumeration walks `roster ∪ $TARGET_ROOT/agents/*/home` (not active-only), creates `ab-agent-<n>` groups, adds controller UID via `usermod -aG` (Linux) / `dseditgroup` (Darwin), scrubs extended ACLs (`setfacl -bR` Linux / `chmod -R -P -N` Darwin), then chmods to v2 contract (`2750/2770/0660/0640`). Per-agent completion markers at `$BRIDGE_STATE_DIR/migration/isolation-v2/agents/<n>.env` with atomic write; global marker only when all per-agent markers present. Privilege preflight with `no_v080_code_installed=yes` remediation hint on permission failure. Bypass scope hardening: `BRIDGE_LAYOUT_RESOLVER_BYPASS=upgrade-migrate:<nonce>` + `OWNER_PID` handshake validates caller is descendant of bridge-upgrade.sh process tree (rejects external env, init pid 1, non-bridge-upgrade owner cmd). Portable stat shim (`bridge_marker_stat_uid` / `bridge_marker_stat_mode`) handles macOS `stat -f` vs Linux `stat -c`. Surfaces `migration_requires_relogin=yes` to the upgrade output for macOS supplemental group cache.

### Added (T4 — PR #645, `64fc342`)

- `scripts/smoke/v2-cross-class-read.sh` — Linux + passwordless sudo gated smoke verifying that v2 isolation lets controller UID + system-class agents read isolated agents' `memory/projects/`, `memory/shared/`, `memory/decisions/` via `ab-agent-<n>` group permission. Negative case: unrelated UID denied. POSIX-only assertion: no extended ACLs (`getfacl --skip-base` empty). **Closes #583.**

### Added (T5 — PR #648, `e5afd5d`)

- `BRIDGE_DISABLE_ISOLATION=1` runtime rollback hatch via `lib/bridge-isolation-runtime.sh`. Short-circuits v2 secret-env wrap and umask 007 in `bridge-run.sh`; skips v2 isolation prep in `bridge-start.sh`. Status surface emits `isolation=disabled-by-env` in `agent show` and `agent list`. Narrow scope: no v1 ACL re-enable, no marker mutation, no `migrate commit`. Daemon unchanged — env propagates through cron worker spawn naturally. See OPERATIONS.md "Rollback hatch" section.

### Added (#619 — PR #646, `c0e0882`)

- `agent doctor` CRUD self-check (`lib/bridge-doctor.sh`, ~970 lines). Centralized `bridge_doctor_invoke_agent` wrapper isolates `BRIDGE_AGENT_HOME_ROOT` per child via subshell + exec. Closed denial enumeration with strict 3-pattern already-gone subset (matches production strings verbatim at `bridge-agent.sh:2879`, `lib/bridge-agents.sh:318`, `bridge-agent.sh:3381`). Pinned-path final safety net via `rm -rf -- "${root:?}/${fixture:?}"` with verify-gone. Step-7 self-assertion: `delete rc=0 + path-still-exists → fail` propagates to overall exit. 7-step CRUD coverage matrix (create/update/registry/show/reclassify/retire/delete) with pass/fail/n/a + structured JSON envelope. Smoke at `scripts/smoke/agent-doctor.sh` covers admin gate, JSON envelope, concurrent refusal, inherited-env isolation. **Closes #619.** Production `agent delete --purge-home` semantics unchanged.

### Added (#639 — PR #642, `7524f6d`)

- codex-task-mode-policy.py write-shape detector redesign (Option C: default-deny block-mode allowlist + maintained common-shape parser). Replaces PR #636 r1-r5 brittle classifier patches. Closed allowlist of read-only commands (`git status/diff/log/show/ls-files`, `ls`, `cat`, `head`, `tail`, `grep`, `find` without `-exec/-delete`, `wc`, `python -c` with read-only AST validator). Common-shape write-target extractor for 15 verbs (rm, cp, mv, install, touch, sed -i, chmod, chown, dd, ln, mkdir, rmdir, truncate, tee, patch). Multi-command splitting (`;`/`&&`/`||`/`|`). exec/bash/sh recursion bounded at depth 4. Grant grammar (`write:` / `shell:`) preserved with shape grant matcher tightened (head must match runtime command). Substitution detection fail-closed in block mode. Heredoc fail-closed (scanner doesn't consume body). PR #636 r1-r5 fixes preserved (fd redirection, git long flags, patch -i/install -t, attached -tDEST/-oFILE, combined-cluster -rt). Audit-only default `BRIDGE_CODEX_TASK_MODE_POLICY=audit` retained. Comprehensive smoke at `scripts/smoke/codex-task-mode-policy-comprehensive.sh` (64 cases) + 53/53 PR #636 §5 regression replay. **Closes #639.** No new Python dependency.

### Added (v0.7.9 prep rollup — merged into release/v0.8.0 at `5d2ad9a`)

- 9 commits from the deferred v0.7.9 prep cycle landed alongside v0.8.0 work: PR #624 (absolute-path guard load), #634 (lint cleanup), #632 (cron disable idempotent), #631 (ghost text disable via settings), #635 (cron mutation audit), #633 (nudge marker recovery), #638 (systemd KillMode=process), #625 (cron payload.kind=shell runner), #636 (codex companion-role policy + output shape + brief validator).

### Operator notes

- Run `agent-bridge upgrade --apply` from any v0.7.x install. Migration is automatic; markers persist under `$BRIDGE_STATE_DIR/migration/isolation-v2/`.
- macOS upgraders may need to log out + back in for `ab-agent-*` group membership to take effect for already-running shells. The migration surfaces `migration_requires_relogin=yes` when this applies.
- Linux Claude agents on first launch will see the Claude login picker — run `claude login` once per isolated UID, OR pre-populate `$BRIDGE_AGENT_ROOT_V2/<agent>/home/credentials/launch-secrets.env` with `ANTHROPIC_API_KEY=...`.
- Engine CLI (claude/codex) must be in a base-readable path (`/usr/local/bin`, `/opt/...`). Controller-home installs (`~/.local/bin`) silently fail at runtime with `command not found` (KNOWN_ISSUES #17).
- If v2 hits unforeseen issues, set `BRIDGE_DISABLE_ISOLATION=1` in the daemon env and restart. See OPERATIONS.md.
- Cosmetic follow-ups filed: #644 (codex-task-mode-policy audit-log accuracy), #647 (agent doctor cosmetic nits), #649 (rollback hatch polish).

### Verified

- `bash -n` clean across all touched .sh files
- `shellcheck` clean of new errors
- 64-case comprehensive smoke for #639 passes; 53/53 r1-r5 regression replay passes
- `agent-doctor` smoke 6/6 (T3 self-assertion case deferred per spec)
- T4 cross-class read smoke verified by inspection (Linux+sudo CI canonical)
- Codex pair-review on every PR (T2 r2 + T3 r2 closed all blockers; T4 / #619 / #639 r1 implement-ok)

## [0.7.8] — 2026-05-06

### Highlight — surface-reply-enforce + linux-user umask + macOS sudo guard

`v0.7.8` is a bug-fix release on the v0.7.x line consolidating 25 PRs across hooks, daemon, channels, isolation, cron, wiki-ingest, watchdog, and the doctor surface. Three headlines: surface-reply-enforce now matches `plugin:<x>:<y>` source tags, closing a 30-day silent-pass regression that let Discord/Telegram/Teams channel replies bypass the enforcement hook (#602); `bridge-run` applies the linux-user isolation umask `0007` regardless of layout, preventing POSIX ACL mask collapse on legacy ACL-backed isolation (#608); and `bridge_linux_sudo_root` now guards on platform so `agent delete --purge-home` actually deletes on macOS instead of failing through a Linux-only sudo path (#620). The release also lands #597 Tracks A–D (precompact route primitive + activity-index, daemon observer + send primitive + EMA, Teams/Mattermost managed-send adapters, Discord relay activity-index) and #598 Tracks 1–4 (`agent registry --json`, orphan-agent-dir doctor detector, `agent retire` primitive with quarantine + audit, test-fixture name validation). Issue #580 is fully resolved by Track 1 (`agent delete` subcommand) plus the Track 2 successor (typed-flag completion + help + admin CRUD policy). Carry-forward correctness fixes consolidated from the v0.7.x line: cron memory-daily jitter + dispatch parallel default (#579), cron-scheduler minute-boundary cursor (#581), wiki-ingest PreCompact raw envelope enqueue (#582), wiki-ingest isolated-private-root skip (#583 Track C), doctor clean-`/exit` cold-restart suppression (#588), watchdog cross-home pid-file refusal (#591), daemon log SSOT (#590), autocompact static/dynamic windows (#593), idle-counter latch (#589), per-agent settings preservation (#613), deferred-retry cron scheduling (#614), and system-class Bash carve-outs (#612).

All changes auto-apply on `agent-bridge upgrade --apply` to v0.7.8+. No operator action required for the common path.

### Added (#597 Track A — PR #601, 86282e4)

- Precompact route primitive + activity-index schema. Channel route layer for precompact envelopes lands ahead of the daemon observer (Track B), giving downstream adapters a stable target before the producer ships.

### Added (#597 Track B — PR #611, a1e90e6)

- Precompact daemon observer + send primitive + EMA. Daemon now produces precompact envelopes through the route primitive established in Track A; EMA-based pacing throttles bursty producers.

### Added (#597 Track C — PR #610, 9bea879)

- Teams + Mattermost managed-send adapters. Both channels gain the managed-send path required for the precompact route, alongside the existing Discord/Telegram coverage.

### Added (#597 Track D — PR #609, 78d11e3)

- Discord relay activity-index + suite smoke. Closes the activity-index parity gap and adds a relay-suite smoke that exercises the new envelope shape end-to-end.

### Added (#598 Track 1 — PR #603, 1529b5f)

- `agent registry --json` endpoint. Structured registry inventory for tooling; replaces ad-hoc grep against roster files.

### Added (#598 Track 2 — PR #606, 50555b4)

- Orphan-agent-dir doctor detector. New doctor check flags `agents/<name>/` directories whose owning roster entry was removed, surfacing isolation-cleanup gaps that previously went unnoticed.

### Added (#598 Track 3 — PR #607, 717754f)

- `agent retire` primitive with quarantine + audit. Operator-grade retirement flow: agent is moved to a quarantine directory rather than deleted, and the operation appends to the audit log so retire/restore is reversible.

### Added (#598 Track 4 — PR #604, c73aaff)

- Test-fixture name validation. `agent create` now refuses test-artifact names without `--test-fixture`, preventing operator-facing rosters from accidentally ingesting names reserved for smoke fixtures.

### Added (#580 Track 1 — PR #584, f8a59ce)

- `agent delete` subcommand. First half of resolving issue #580 — gives operators a typed deletion path that pairs with the existing `agent create` / `agent retire` surface. The Track 2 successor (PR #621) lands the typed-flag completion + help + admin CRUD policy on top of this primitive; together they fully close #580.

### Added (#580 Track 2 successor — PR #621, 4ace573)

- Typed-flag completion + help + admin CRUD policy. Completes the typed `agent` CRUD surface (`create` / `update` / `delete` / `retire`) with consistent flag completion, help text, and the admin-only authorization policy. With Track 1's `agent delete` primitive, fully resolves #580.

### Fixed (#590 — PR #599, ac4ddc8)

- Daemon log SSOT. `BRIDGE_DAEMON_LOG` now defaults to `launchagent.log` on launchd installs so operators see a single canonical log instead of a per-invocation split. Closes the diagnostic-divergence path where daemon and launchd logs reported the same run differently.

### Fixed (#593 — PR #600, 6f32ecf)

- Class-aware `autoCompactWindow` defaults. Static agents resolve to 400k, dynamic agents to 1M, and the unknown/fallback case defaults to 1M (was previously inheriting the static cap). Closes the regression where dynamic Opus 4.7 `[1m]` agents inherited the static 400k window despite the v0.7.6 per-agent rendering work.

### Fixed (#589 — PR #605, 1463e35)

- Idle counter latch — hybrid send + poll + grace + spool re-delivery. Closes the silent-drop path where a daemon nudge fired between an agent's prompt-ready transition and the latch capture, leaving the nudge queued in `pending-attention.env` indefinitely. New hybrid model combines the existing send path with a bounded poll plus a grace window before declaring the agent unresponsive; spool re-delivery handles the prompt-ready transition mid-flight.

### Fixed (#612 — PR #612, e0fb01c)

- System-class Bash carve-out + idle-since marker self-heal. `class=system` agents (librarian, patch, similar ingestion roles) gain the targeted Bash carve-out required for their cross-agent read scope without re-opening the broader Bash gate. Idle-since marker now self-heals when the daemon detects a stale value.

### Fixed (#613 — PR #617, 5ad997d)

- Preserve per-agent user keys in `cmd_render_shared_settings` (parity with isolated renderer). The shared/managed renderer now mirrors the isolated renderer's preservation of `enabledPlugins`, `extraKnownMarketplaces`, and `skipDangerousModePermissionPrompt` user keys across rerender. Pre-fix, operator-set user keys on shared (non-isolated) agents were silently overwritten on every rerender.

### Fixed (#614 — PR #616, 791246e)

- Scheduler honors deferred-retry `nextRunAtMs` for daily/weekly cron. Cron jobs that recorded a deferred-retry timestamp via the existing failure path were ignored by the scheduler's daily/weekly cursor, causing the retry to fire at the next natural cadence boundary rather than at the requested deferral time. The scheduler now consults `nextRunAtMs` before the cadence cursor.

### Fixed (#602 — PR #602, 28a9167)

- `surface-reply-enforce` matches `plugin:<x>:<y>` source tags. Pre-fix, the hook's source-tag regex rejected the `plugin:<provider>:<channel>` shape that Discord/Telegram/Teams channels emit, so every channel-sourced reply silently passed enforcement for ~30 days. The match now accepts the two-segment form alongside the legacy one-segment form.

### Fixed (#620 — PR #623, 6753bf6)

- `bridge_linux_sudo_root` only invokes sudo on Linux. `agent delete --purge-home` now actually deletes on macOS instead of failing through a Linux-only sudo invocation. The helper short-circuits to a non-sudo path on Darwin while preserving the Linux sudo gating for isolated-UID-owned trees.

### Fixed (#608 — PR #608, 7588e76)

- Apply linux-user isolation umask `0007` regardless of layout. Pre-fix, the umask was scoped to the v2 layout path, leaving legacy ACL-backed isolation hosts open to POSIX ACL mask collapse when child processes inherited the controller's umask. The umask now applies whenever linux-user isolation is in effect.

### Fixed (#579 — PR #586, a70a1ba)

- Jitter memory-daily registration + default dispatch parallel to 1. Memory-daily cron registration now jitters its bootstrap window so simultaneous installs don't all register at the same minute boundary; dispatch parallelism defaults to 1 to keep cold-start cron load deterministic. Closes the thundering-herd path that surfaced when multiple newly-bootstrapped installs converged on the same memory-daily minute.

### Fixed (#581 — PR #587, ab4ced7)

- Cron-scheduler anchors sync cursor to minute boundary. Pre-fix, weekly cron firings could be skipped when the sync cursor drifted off a clean minute boundary; the scheduler now anchors the cursor on minute granularity so weekly jobs fire as scheduled.

### Fixed (#582 — PR #585, cc1ef90)

- Wiki-ingest enqueues PreCompact raw envelopes from `agents/<n>/raw/` in Lane B. Closes the gap where PreCompact-emitted raw envelopes weren't picked up by the Lane B ingest pass, leaving them stranded in `agents/<name>/raw/` instead of being routed through the wiki ingest pipeline.

### Fixed (#583 Track C — PR #595, 5bad752)

- Wiki-ingest explicit skip of isolated-private-root agents in Lane B. Lane B now explicitly skips agents whose isolated private root is unreadable from the controller, preventing spurious read errors against isolated-UID-owned trees during the daily ingest sweep.

### Fixed (#588 — PR #594, 633166e)

- Doctor skips cold-restart-suspect on clean `/exit`. Pre-fix, the doctor surfaced a cold-restart-suspect signal even after a clean operator-initiated `/exit`; doctor now treats clean `/exit` as a non-suspect terminal state.

### Fixed (#591 — PR #596, 1fca957)

- Watchdog refuses cross-home `BRIDGE_DAEMON_PID_FILE` configurations. The watchdog now hard-rejects pid-file paths that point outside the active `BRIDGE_HOME`, closing the misconfiguration path where a stray cross-home pid-file value could let the watchdog target the wrong daemon instance.

### Operator action

- **None for the common path.** All changes auto-apply on `agent-bridge upgrade --apply` to v0.7.8+.

## [0.7.7] — 2026-05-05

### Highlight — channel/queue resilience + isolation hardening + tool-policy boundary fixes

`v0.7.7` consolidates eight fixes across the channel, queue gateway, isolation, and tool-policy boundaries. Headline: a new opt-in Unix-socket transport for the queue gateway with peer-UID auth (#571), a security-boundary rebuild of per-agent isolated marketplace catalogs (#557), and a daemon-survival fix that closes a real production crash path (#576). Smaller correctness wins: ms365 channel readiness now matches its env-only token model (#573), Teams edits route through Claude channels with edit-aware dedupe (#569), and tool-policy no longer denies stderr-suppressed read commands on protected paths (#577, fixes #574). Two operator-facing defaults flip: managed agents get `autoCompactWindow=1_000_000` unconditionally (#575, fixes #570), and bootstrap migrates the legacy `[cron-dispatch]` cron payload form to canonical `bash $script` (#572).

All changes auto-apply on `agent-bridge upgrade --apply` to v0.7.7+. PR #571's socket transport is opt-in via `BRIDGE_GATEWAY_TRANSPORT=socket` on Linux + root installs; the default file-drop transport is unchanged.

### Added (#571 — PR #571)

- Unix domain `SOCK_SEQPACKET` queue gateway transport with peer-UID authorization via `SO_PEERCRED`. Linux-only fail-closed (refuses to start on non-Linux); root-installed system mode (tmpfiles.d, `root:root` runtime). Per-command argv strict parser rejects unknown long options as `unknown_option`; argparse `allow_abbrev=False` on the top-level parser plus 16 subparsers prevents abbreviation bypass. Server-side ownership re-check on `do_cancel` / `do_update` / `do_handoff` (defense-in-depth). Connect-probe (AF_UNIX SOCK_SEQPACKET, 1.0s timeout) replaces pid+file-existence liveness check; recycled-pid + leftover-socket false-positives now report not-running. Public reason-code allow-list (`_PUBLIC_REASON_MAP` frozenset) collapses task-existence / ownership leaks to `not_authorized`; detailed code stays in server log only. Body-file inlining uses `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` + `S_ISREG` check + bounded read (rejects FIFO / symlink / dir; FIFO no longer hangs). Client validates `reason_code` against the allow-list and coerces `exit_code` with fallback `1`. Daemon writes `BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT`, `BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS`, and `BRIDGE_GATEWAY_TRANSPORT` into isolated agent env files when the operator selects non-default values.

### Added (#572 — PR #572)

- Bootstrap legacy cron payload migration. `bootstrap-memory-system.sh` now detects five managed wiki/librarian crons whose payloads start with the literal `[cron-dispatch]` prefix and migrates them to the canonical `bash $installed_script` form during `--apply`. `cron_lookup` extended from 3 → 4 columns (added `payload_preview`). Three modes: `--check` records `drift-payload-pending`, `--dry-run` reports `would-migrate-payload`, `--apply` migrates via `agb cron update --payload`.

### Added (#557 — PR #557)

- Per-agent filtered `known_marketplaces.json` catalog instead of exposing the controller catalog wholesale (security boundary). GitHub URL alias parsing (`_github_repo_slug`) handles five URL forms (`https://github.com/<org>/<repo>(.git)?`, `git://`, `git@github.com:<org>/<repo>(.git)?`, bare `<org>/<repo>(.git)?`) and produces a consistent `<org>-<repo>` slug. Alias collision detection: pre-pass builds the map and fails loud listing every collider before any symlink is planted. Marketplace-id sanitization uses `re.fullmatch(^[A-Za-z0-9._-]+$)` (not `re.match($)` — catches the trailing-newline bypass), enforces length ≤ 200, blocks reserved names (CON/NUL/etc.) and leading-dot names except `.git`. `bridge_die` fail-loud on rejection (no silent skip). Validator wired into `bridge-dev-plugin-cache.py` production path-build sites and `bridge_write_isolated_installed_plugins_manifest`. Pre-creates read-only marketplace aliases (root-owned `0640` catalog; isolated UID can read but not write/unlink). 26-input cross-validator parity sweep ensures `bridge-dev-plugin-cache.py` and inline `lib/bridge-agents.sh` validators agree on accept/reject. v2 non-member group denial test capability-gated on `BRIDGE_TEST_PR_C_NONMEMBER_UID`. Whitespace-key e2e bypass-tokenizer helper covers space, tab, newline, CR, leading tab.

### Added (#576 — PR #576)

- `daemon_source_state_file` per-callsite required-vars check + pre-source unset prevents stale uppercase-var leak across six callsites (STALL_*, CONTEXT_PRESSURE_*, CRASH_*, AUTO_START_*, LAST_*). Empty/truncated env files now caught (not just permission/syntax). Default ACL inheritance for `runtime_state_dir`, `log_dir`, queue gateway dirs, and memory daily agent/shared dirs. New ACL inheritance smoke with positive + negative cases, capability-gated explicit-skip on macOS / no-`setfacl` hosts. Two-non-root-UID validation gate for v2 group denial (operator-side `BRIDGE_TEST_PR_C_NONMEMBER_UID`).

### Changed (#575 — PR #575) — closes #570

- Managed agent `autoCompactWindow` default raised to `1_000_000` unconditionally. `bridge-hooks.py:resolve_managed_autocompact_window` no longer attempts the legacy `[1m]` substring match against `launch_cmd` — `[1m]` is a model-id PRINT suffix and never appears in any agent's launch_cmd, so the heuristic was dead code on every install. Operators on Opus 4.7 with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45` now get a 450k effective compact window (was 180k due to the legacy 400k default). Four smoke files updated; eight-plus stale `[1m]` / launch_cmd references cleaned from CLI parser help, `OPERATIONS.md`, `UPGRADING.md`, `OPERATOR_ACTIONS_PENDING.md`, `lib/bridge-hooks.sh`, `lib/bridge-migration.sh`, `bridge-agent.sh`, `bridge-start.sh`, `bridge-upgrade.sh`, and `bridge-setup.sh`.

### Changed (#573 — PR #573)

- `plugin:ms365` channel readiness reports `n/a` for access status, matching the env-only token runtime contract. No longer requires `.ms365/access.json`. Other channel plugins (Discord, Telegram, Teams, Mattermost) still require `access.json` — no incorrect reclassification. The smoke detects a real missing `.env` case; diagnostic clarity is preserved.

### Changed (#569 — PR #569)

- Teams plugin delivers inbound via `notifications/claude/channel` directly; the queue-sender path (`agent-bridge urgent`) is removed. `ActivityTypes.MessageUpdate` (Teams edits) is routed alongside `Message`; `MessageDelete` is intentionally out of scope. Edit-aware dedupe key `chatId::messageId::revision` (revision = `activity.localTimestamp ?? activity.timestamp`) with backward-compat fallback for legacy `messages.jsonl` rows lacking `revision`. Catch block split: channel delivery rethrows on failure (Teams retries); log-append failure logs a warning and returns 2xx. Migration tradeoff: legacy rows without `revision` suppress edits-on-top during the migration window — preserves idempotency at the cost of a one-time edit loss for pre-existing messages. Supersedes #558.

### Fixed (#577 — PR #577) — closes #574

- `hooks/tool-policy.py::_is_read_intent_bash` correctly classifies `2>/dev/null`, `2>&1`, and `&>/dev/null` as read-intent on protected paths. Boundary-aware regex sanitization only strips when the suppression form is followed by EOS, whitespace, or an actual shell separator (`; & | ( ) < >`); rejects when followed by a path char (`/`), word char (`.`), variable expansion (`$`), or command substitution (backtick). Real writes still blocked even when adjacent to safe forms (`> bar`, `>> bar`, `2>err.log`, `> bar 2>&1`). Eleven codified regression assertions live in `tests/system-config-gating/smoke.sh` Scenario 8 (8a allow, 8b deny, 8c path-collision, 8d compound).

### Fixed (#576 — PR #576)

- macOS `/bin/bash` re-exec preserves script identity via `BASH_SOURCE` capture — `bridge-lib.sh` and `scripts/smoke/daemon.sh` now snapshot `BASH_SOURCE` before the exec re-launch (was failing because `$0=_` after exec on macOS).
- Empty/truncated daemon state env files no longer pass `bash -n` + `source` silently into the daemon under `set -e`.
- Stale uppercase-var leak across six daemon callsites after a failed source resolved via pre-source unset.

### Security (#557 — PR #557)

- Marketplace-id sanitization closes the path-traversal / control-char attack surface; collision detection fails loud naming every collider before any symlink is planted.

### Security (#576 — PR #576)

- Default ACL inheritance grants controller readability on isolated-UID-created files in runtime / log / memory state dirs (closes the daemon crash path observed at 2026-05-04T15:47:17Z; #538-class).

### Security (#571 — PR #571)

- Public reason-code allow-list prevents task-existence / ownership info leak across the isolation boundary; detailed codes stay in the server log only.
- argparse `allow_abbrev=False` plus strict per-subcommand value-flag tables prevent argv smuggling (`done --note-f 60 12 --agent forged` no longer authorizes 60 while executing 12).

### Operator action

- **None for the common path.** All changes auto-apply on `agent-bridge upgrade --apply` to v0.7.7+.
- (optional) Linux + root installs that want the new socket gateway transport set `BRIDGE_GATEWAY_TRANSPORT=socket` and run the daemon under root; default file-drop transport is unchanged.
- (optional) Run `bootstrap-memory-system.sh --check` then `--dry-run` to preview legacy `[cron-dispatch]` payload migrations before `--apply` rewrites them.

## [0.7.6] — 2026-05-04

### Highlight — linux-user isolated agents end-to-end + system agent class + per-agent settings architecture

`v0.7.6` makes linux-user-isolated agents (`agent-bridge agent create … --isolation linux-user`) actually usable by closing the four-piece gap that left them silently mis-configured (#544). Adds a first-class `system` agent class for ingestion/supervisory roles like `librarian`/`patch` (#539). Replaces the install-wide single shared `settings.effective.json` with per-agent rendered files so mixed-model installs (some Opus 4.7 `[1m]`, some pre-1M) no longer race on `autoCompactWindow` (#555/#547). Plus a small batch of correctness fixes that surfaced during the wave (#541, #542, #543, #545, plus a tmux Claude dim ghost-input fix in PR #566).

All changes auto-apply on the first `agent-bridge upgrade --apply` to v0.7.6+. Existing isolated agents pick up the new hooks/skills/settings on the next `agent-bridge isolate <agent> --reapply` (idempotent — only re-applies the ACL/sync contract; doesn't mutate ownership) followed by an agent restart.

### Added (#544 PR1 — PR #556)

- `bin/agb` curated shim for isolated agents. Sources `BRIDGE_AGENT_ENV_FILE` (when set) before exec'ing `${BRIDGE_HOME}/agb` so Bash subprocess invocations from the isolated UID see `BRIDGE_GATEWAY_PROXY=1` / `BRIDGE_HOME` / sentineled `BRIDGE_TASK_DB` even in fresh non-login subshells. Robust to symlinked invocation: bounded `readlink` walk (16-hop cycle guard) + `cd -P / pwd -P` canonicalization handles macOS `/var → /private/var` `TMPDIR` indirection.
- `lib/bridge-agents.sh:bridge_write_linux_agent_env_file` now prepends `${BRIDGE_HOME}/bin` to PATH for `linux-user` isolated agents alongside the existing engine CLI directory injection. Curated `bin/` stays the only directory exposed (option B chosen over the broader `${BRIDGE_HOME}` PATH); the broader `agent-bridge` subcommand surface remains explicit default-deny per PR4.
- `bridge_linux_grant_bin_dir_access` ACL helper grants the isolated UID r-x on `bin/` and `bin/agb` (best-effort; mirrors `bridge_linux_grant_engine_cli_access` pattern). Idempotent via `agent-bridge isolate <agent> --reapply`.
- New regression smoke `scripts/smoke/isolated-bin-agb.sh` (4 sub-tests: env-source ordering, exec delegation, BRIDGE_HOME fallback, **including symlinked invocation** with negative-assertion that the symlink path does not leak into the resolved BRIDGE_HOME).

### Added (#544 PR2 — PR #564)

- `bridge-hooks.py:cmd_render_isolated_home_settings` renders bridge-managed Claude hook entries into per-isolated-home `<isolated-home>/.claude/settings.effective.json` (controller/root-owned). `<isolated-home>/.claude/settings.json` is then atomically symlinked to it. Preserves operator's `enabledPlugins`, `extraKnownMarketplaces`, `skipDangerousModePermissionPrompt` user keys — symlink-aware: dereferences existing symlinked `settings.json` to read prior preserved keys from `settings.effective.json` on every re-run. Atomic install (tmp + `os.replace` for JSON; tmp + `mv -f` for symlink).
- `<isolated-home>/.claude/` parent dir is now controller-owned (`chown root:$os_user` + `chmod 0750`) so the isolated UID has group r-x but cannot unlink/replace root-owned children — preserves the integrity boundary the issue body explicitly requires.
- `agents/.claude/settings.json` (shared base) now carries the full 7-event Claude hook suite: Stop, UserPromptSubmit, SessionStart, PermissionDenied, **PreCompact, PreToolUse, PostToolUse** (the last three were missing pre-PR2; smoke asserts all 7 present in the rendered output).
- Both `--reapply` and first-isolate paths in `lib/bridge-migration.sh` resolve `bridge_agent_launch_cmd_raw` and forward it to the install helper, so isolated renders pick up the `[1m]` heuristic from PR #554.
- New regression smoke `scripts/smoke/isolated-settings-rendering.sh` (6 sub-tests including symlink-aware preservation regression).

### Added (#544 PR3 — PR #559)

- `lib/bridge-skills.sh:bridge_sync_isolated_home_claude_skills(agent)` syncs the 4 bridge-native skills (`agent-bridge-runtime`, `cron-manager`, `memory-wiki`, `patch-permission-approval`) into `<isolated-home>/.claude/skills/`. SKILL.md text is rendered with `~/.agent-bridge/` → canonical absolute `${BRIDGE_HOME}/` substitution at sync time (handles trailing slash + double slash + symlinked `BRIDGE_HOME` variants via `os.path.realpath(os.path.normpath(home))` before the trailing-slash strip). Atomic install (tmp + `mv -f` with `rm -f` cleanup on every failure path — both rendered text and binary copy paths). Source `.claude/skills/<skill>/SKILL.md` files unchanged (canonical for shared agents).
- `--reapply` integration runs the skill sync so existing isolated agents pick up bridge-native skills without unisolate→isolate.
- New regression smoke `scripts/smoke/isolated-skills-sync.sh` (6 sub-tests including 3 canonicalization variants).

### Added (#544 PR4 — PR #565)

- Isolated `agb` subcommand allowlist + audit. `bin/agb` shim now distinguishes isolated invocations (strict gate: `BRIDGE_GATEWAY_PROXY=1` AND non-empty `BRIDGE_CONTROLLER_UID` AND `$(id -u) != $BRIDGE_CONTROLLER_UID` — all three required; defends against operator-shell debugging false-positives) and applies an explicit allowlist (`inbox|show|claim|done|summary|create`). Anything else exits 64 with a clean message redirecting operators to queue task creation. Every invocation (allow + deny) appends a JSONL audit row to `${BRIDGE_HOME}/logs/agents/<agent>/audit.jsonl` with `subcommand` + `arg_count` (NOT arg values, for privacy) and a `_json_escape` helper for safe JSON serialization (RFC 8259 §7 escape ordering).
- `lib/bridge-agents.sh:bridge_write_linux_agent_env_file` emits `BRIDGE_CONTROLLER_UID` into the per-agent `agent-env.sh` so the shim's strict gate has the explicit hint it requires.
- New regression smoke `scripts/smoke/isolated-cli-policy.sh` (7 sub-tests: allowlist allow + deny exit 64 + non-isolated bypass + UID-matching bypass + arg redaction + proxy-without-controller bypass + JSONL escape round-trip).

### Added (#539 — PR #562)

- First-class `class=` field on agents (default `user`, opt-in `system`). Validated at roster load against the closed `{user, system}` set (unknown class is a hard error). New `BRIDGE_AGENT_CLASS` associative array + `bridge_agent_class()` getter; class is exported to per-agent env file (scalar alias `BRIDGE_AGENT_CLASS_FOR_HOOK`) so per-agent hooks running as the isolated UID can consult it.
- `hooks/tool-policy.py`: when `class=system`, cross-agent Read into `agents/<other>/memory/{projects,decisions,shared}/` AND `shared/*` (excluding `shared/private/`, `shared/secrets/`) is allowed; every such read emits `system_cross_agent_read` to `audit.jsonl` with `target_agent` distinguishing peer-agent reads (`target_agent="<other>"`) from shared-resource reads (`target_agent=""`). Bash/Edit/Write outside own home stays denied for system class — read-only by design.
- `agent-roster.local.example.sh`: documents the `class=` field. Public roster ships zero default `class=system` agents — operators add `class=system` to their librarian / patch / similar ingestion roles locally.
- New regression smoke `scripts/smoke/system-agent-class.sh` covering class roundtrip + unknown-class rejection + 4 peer-agent gate scenarios + 3 shared/* gate scenarios + audit count assertion.

### Added (#555 — PR #567)

- Per-agent `settings.effective.json`. Replaces the install-wide single `${BRIDGE_AGENT_HOME_ROOT}/.claude/settings.effective.json` with one rendered file per managed agent at `${BRIDGE_AGENT_HOME_ROOT}/<agent>/.claude/settings.effective.json`. Each managed agent's workdir symlink (`<workdir>/.claude/settings.json`) now points at its OWN per-agent file. Mixed-model installs (some `[1m]`, some pre-1M) no longer race on `autoCompactWindow` — agent-A `[1m]` resolves to 1_000_000, agent-B pre-1M resolves to 400_000, independent regardless of rerender order.
- `lib/bridge-hooks.sh`: new `bridge_hook_per_agent_settings_effective_file(agent)` helper; `bridge_link_claude_settings_to_shared(workdir, launch_cmd, [agent_id])` extended with optional 3rd arg switching to per-agent rendering target. Back-compat preserved: legacy callers without `agent_id` continue to render the install-wide file.
- All call sites plumb the agent_id through: `bridge-agent.sh:run_rerender_settings`, `bridge-agent.sh:run_create`, `bridge-init.sh`, `bridge-upgrade.sh`, `bridge-start.sh`, `bridge-setup.sh`. `bridge_agent_shared_settings_plan_json` updated to compare against the per-agent target so post-apply status doesn't stay needs-rerender.
- New regression smoke `scripts/smoke/per-agent-settings-rendering.sh` (6 sub-tests including mixed-model independence + setup-path launch_cmd preservation).
- `OPERATIONS.md`: replaced the mixed-model caveat (added in v0.7.5 PR #554 r2) with the new per-agent contract; auto-migration documented (next `agb upgrade --apply` per-agent loop creates per-agent files; orphan install-wide file becomes harmless).

### Fixed (#542 — PR #546)

- Plugin MCP liveness identity-mapping gap. `bridge_plugin_mcp_identity_for_item` only recognized 4 chat providers (`discord/telegram/teams/mattermost`); every other declared plugin (ms365, marketplace plugins, HTTP MCPs) fell through to identity=`""` and got flagged `missing` downstream, driving a 5-attempt restart loop on `agent-bridge agent restart` and the same false-positive in `bridge-daemon.sh:process_plugin_liveness`. Splits probeable / unprobeable: new `bridge_plugin_mcp_is_probeable_item` classifier; `bridge_agent_missing_plugin_mcp_channels_csv` skips unprobeable items so unknown/skipped plugins cannot drive restart triggers. New `BRIDGE_SKIP_RESTART_PLUGIN_LIVENESS=1` operator kill-switch for the restart-internal verifier (independent of the existing daemon-only `BRIDGE_SKIP_PLUGIN_LIVENESS`).

### Fixed (#543 — PR #549)

- `bridge-start.sh` restart path now mirrors the daemon's `bridge_linux_acl_repair_channel_env_files` preflight — calls it inside the existing `claude+!safe+linux-isolation` gate immediately after `bridge_linux_repair_claude_credentials_access` and before `bridge_agent_channel_status_reason`. Restart on isolated agents no longer aborts via `bridge_die` when a transient ACL drift leaves a channel `.env` unreadable to the controller. Soft-launch on `unreadable:` reasons remains an explicit follow-up (separate review thread).

### Fixed (#541 PR-A — PR #551)

- `agb cron migrate-payloads --jsonl-aware [--dry-run] [--json]` migration command for memory-daily cron job payloads. Closes the `#390` PR-3 commit-message promise that never landed (live runtime `cron/jobs.json` accumulated 22 memory-daily jobs whose payload bodies predate the `daily-note-reconcile.py` pipeline). Idempotent (already-jsonl-aware jobs are no-ops). Backup pattern `jobs.json.bak-<timestamp>` mirrors `cleanup-prune` exactly. Both list-shape and `{jobs:[...]}` object-shape `jobs.json` round-trip correctly.
- New canonical `MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE` constant in `bridge-cron.py`; `agb cron create --family memory-daily` now defaults to it when no explicit payload is supplied (operator override preserved). `bootstrap-memory-system.sh` + `docs/agent-runtime/memory-daily-harvest.md` synced to mirror the canonical body.
- New regression smoke `scripts/smoke/cron-migrate-payloads.sh` (dry-run / apply / idempotency / backup / non-memory-daily byte-identity / create-override / list-shape round-trip).

### Fixed (#541 PR-B — PR #550)

- Full Claude Stop hook suite now landed in the shared base `agents/.claude/settings.json`: `mark-idle.sh` (existing — idle wake) + `surface-reply-enforce.py` (timeout 5) + `session-stop.py` (timeout 35). Pre-PR-B the shared base carried only `mark-idle.sh`, so per-agent rerender propagated the (incomplete) base correctly and live always-on agents had no drain or transcript→daily-note reconcile firing on Stop. `bridge-hooks.py` ensure/status helpers extended to manage all three; existing per-agent `run_rerender_settings` + `bridge_link_claude_settings_to_shared` propagation fixes the inputs and now propagates correctly.
- New regression smoke `scripts/smoke/upgrade-shared-settings-propagate.sh` asserts all three Stop hooks land in the shared base after the ensure path runs.

### Fixed (#547 — PR #554)

- Model-aware `autoCompactWindow` default. Pre-PR #554 `bridge-hooks.py` shipped a static `BRIDGE_MANAGED_CLAUDE_SETTINGS_DEFAULTS["autoCompactWindow"] = 400000` that was correct on Opus 4.6 (400K native context) but actively capped Opus 4.7 `[1m]` (1M native context). Combined with how Claude Code computes `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (pct multiplied by the capped window, not model native capacity), operators setting `pct=45` on a 1M session were getting compact at 180K instead of the intended ~450K. Replaced the static constant with `resolve_managed_autocompact_window(launch_cmd)` — heuristic on `[1m]` substring → 1_000_000; everything else → 400_000 (preserved). New optional `--launch-cmd` flag on `bridge-hooks.py render-shared-settings` (back-compat: omitting → legacy default). Three call-site updates (`bridge-agent.sh`, `bridge-init.sh`, `bridge-upgrade.sh`) pass the resolved launch_cmd through. Operator escape hatch: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` in env (env wins over settings) for any 1M agent that wants the legacy cap.

### Fixed (tmux ghost text — PR #566)

- Claude Code composer ghost text (`SGR 2` dim ANSI auto-complete suggestions) no longer flips the bridge's pending-input detector to "busy". Pre-fix: plain tmux capture stripped the dim style, making the suggestion text look textually identical to real typed input → daemon nudges got silently spooled into `pending-attention.env`. Now: ANSI-preserving capture is requested for both `claude` and `codex` engines (was codex-only); new `bridge_tmux_claude_last_prompt_is_ghost_text` predicate scans for `❯`/`>` last line and rejects it if dim. Refactors the existing 4-pattern dim-style match into shared `bridge_tmux_line_has_sgr_dim` (codex's existing placeholder detector now delegates).

### Documentation (#545 — PR #548)

- `shared/TOOLS.md` (rendered by `bridge-docs.py:render_shared_tools_md()`) now documents Discord/Telegram MCP timestamp UTC handling. The MCP plugins return ISO 8601 UTC timestamps (`Z` suffix); without explicit guidance, bridge-managed agents quoted `ts` raw to operators (off by KST offset + occasional date-boundary flip on UTC ≥15:00). Section includes the conversion rule (`KST = UTC + 09:00`), the prompt-hook `now: ... KST` vs MCP UTC mismatch warning, and a worked failure example (2026-05-04 `syrs-sns` incident).

### Operator action

- **None for the common path.** All changes auto-apply on `agent-bridge upgrade --apply` to v0.7.6+.
- **Existing linux-user isolated agents**: run `agent-bridge isolate <agent> --reapply` (idempotent; re-installs ACL contract + syncs skills + renders isolated settings) → `agent-bridge agent restart <agent>` (regenerates `agent-env.sh` with new PATH; isolated UID picks up new hooks). Required so the agent actually starts seeing the new bridge hooks / skills / `agb` PATH that PR #544 wired up.
- (optional) Run `agb cron migrate-payloads --jsonl-aware --dry-run --json` first to preview, then drop `--dry-run` to apply. Migrates existing `memory-daily-*` cron job payloads to the canonical jsonl-aware body. Backup at `~/.agent-bridge/cron/jobs.json.bak-<timestamp>`.
- (optional) Local-install ingestion agents (`librarian`, `patch`, similar) can opt into `class=system` in `agent-roster.local.sh` to grant scoped read-only cross-agent access. The mechanism ships dormant — public roster gets nothing extra by default.
- (optional) Mixed-model installs that previously used `CLAUDE_CODE_AUTO_COMPACT_WINDOW=<value>` env override per-agent to work around the install-wide settings file can now drop the override — per-agent `settings.effective.json` rendering means each agent gets its own correct value.
- (optional) Existing installs may have an orphan install-wide `${BRIDGE_AGENT_HOME_ROOT}/.claude/settings.effective.json` after the per-agent migration. It's harmless (no symlink references it) but operators may delete it manually after verifying the per-agent rendering is correct.

## [0.7.5] — 2026-05-04

### Highlight — v0.7.3 multi-host upgrade backlog cleanup

`v0.7.5` bundles eight fixes that surfaced when operators upgraded multiple hosts to v0.7.3 (#394, #522, #523, #526, #528, #529, #533, #534). All auto-apply on `agent-bridge upgrade --apply`; no operator action required for the common path.

### Added (#528 — PR #531)

- `agent-bridge agent update <agent>` typed/audited subcommand. Admin agents can now mutate protected `agent-roster.local.sh` managed-role fields (`BRIDGE_AGENT_LAUNCH_CMD` env-prefix, `--dangerously-load-development-channels` set, `BRIDGE_AGENT_CHANNELS`) via typed flags rather than raw `Edit`/`Write` against the protected path. Caller validation requires admin (`BRIDGE_ADMIN_AGENT_ID`) AND operator-trusted source (TTY or `BRIDGE_CALLER_SOURCE`), mirroring `bridge-config.py:cmd_set` audit-chain semantics. Audit row mirrors the wrapper-apply detail keys (before/after sha256, kind, actor, actor_source, trigger, operation) plus 5 agent-update-specific fields. Reuses the existing managed-role block writer (`bridge-agent.sh:bridge_write_role_block`) so emission shape stays consistent. Typed flags include `--set-launch-cmd`, `--launch-cmd-add-env KEY=VALUE` (idempotent), `--launch-cmd-remove-env`, `--launch-cmd-{add,remove}-dev-channel`, `--channels-{set,add,remove}`. All values validated against shape regexes (`^[A-Za-z_][A-Za-z0-9_]*$` for env keys, `plugin:NAME@SPEC` for channels) before writing. New triggers: `agent-update-apply` / `agent-update-dry-run` / `agent-update-deny`.

### Added (#533 — PR #536)

- `agent-bridge cron cleanup --mode {one-shot,run-artifacts,all}` retention/GC for cron run artifacts. Closes the v0.7.x cron-followup pipeline gap where six artifact surfaces (`state/cron/runs/`, `state/cron/workers/`, `state/cron/dispatch/`, `shared/cron-{dispatch,result,followup}/`) grew unbounded with no built-in retention. Tier-A 7d (machine surfaces) / Tier-B 30d (human-facing) defaults; `--older-than-days N` overrides both. Always-preserve floor (latest 5 entries per cron-family per surface) protects quiet weekly jobs. Combined deletion gate: queue terminal (`done`/`cancelled`) AND `status.json` final_status terminal AND no live PID AND outside floor. Failed runs (`state="error"`) held to Tier-B 30d (operator triage window). Stale-PID matcher anchors on absolute path under `<target>/state/cron/...` or `<target>/shared/cron-...` AND run_id reference (PR #527 anti-foreign-install pattern). `--mode one-shot` aliases legacy `--mode expired-one-shot` byte-identical for backward compat. Worker-artifact entries (`task-<id>.pid|log`) look up the queue task row directly via `python3 bridge-queue.py show <id> --format shell` subprocess (queue-first contract; no direct SQLite). Symlink-safe via existing `_rmtree_safe`; audit row counts + sample paths only (no payload contents).

### Added (#523 — PR #527)

- `bridge-relay-cleanup.py` Gap A (rewrite `BRIDGE_AGENT_LAUNCH_CMD` lines to strip `--dangerously-load-development-channels plugin:telegram-relay@<spec>`, both whitespace and `=` forms; both `"..."` and `'...'` quoted assignment forms supported; quoting style preserved on rewrite; lines that don't parse cleanly recorded in `unparsed_launch_cmd_lines`). Gap B (versioned removal manifest deletes `lib/telegram-relay.py`, `bridge-telegram-relay.sh`, `plugins/telegram-relay/` from the live runtime — v0.7.0 deleted these from source but the upgrader is additive-only). Reorders cleanup to: rewrite launch commands → SIGTERM/SIGKILL stale relay processes (path-prefix-anchored matching only, no foreign-install collateral) → prune live files → existing state/token cleanup. Backed up via `backup-extend-live` when invoked from `bridge-upgrade.sh`, otherwise to `<target>/backups/relay-cleanup-<UTC-stamp>/`. Closes the v0.7.0–v0.7.3 residue causal loop where stale plugin tree kept recreating relay state every session.

### Added (#534 — PR #535)

- `bridge_channel_env_file_readiness <agent> <item> <file> <key>...` — new isolation-aware enum helper returning `present|missing|unreadable` for channel `.env` credential checks. Closes the silent diagnostic-collapse where EACCES (file unreadable to controller in linux-user isolation) was indistinguishable from "credentials missing" in `bridge_channel_credentials_status_for_item` and `bridge_agent_runtime_channel_status_reason`. Bounded ACL-repair retry (default 2 attempts via existing `bridge_linux_acl_repair_channel_env_files`) on linux-user-isolated agents. New `bridge_channel_env_file_acl_diagnostic` returns single-line structured blob (mode, owner, getfacl summary, repair attempt count). Migrates 3 callsites; `bridge_agent_runtime_channel_status_reason()` now distinguishes `unreadable: ACL repair failed N times; ...` from `credentials missing` reasons across discord/telegram/teams/mattermost/ms365 (ms365 branch newly added — was previously absent). Suppresses raw grep stderr leakage from the daemon log.

### Added (#394 — PR #538)

- `agent-bridge upgrade conflicts list|diff|adopt|discard|archive|reconcile` lifecycle subcommand for `.upgrade-conflict` files. Closes the gap where operators accumulated stale conflict files indefinitely (observed 11 stale files / 16 days on one host) with no built-in inventory or sweep tooling. `bridge-upgrade.py:apply_live` records each conflict-write into `state/upgrade-conflicts/<run-id>.json` with the live target's at-write `sha256` (captured pre-merge so operator-side changes are byte-accurately distinguishable from "untouched since conflict"). Start-of-run reconcile auto-archives conflict files whose live-target hash hasn't changed since the at-write capture (operator either explicitly kept the live or hadn't reviewed; either way the conflict is no longer informative); archive moves to `backups/upgrade-conflict-archive/<date>/<original-relpath>` (recoverable, not deleted). Mutation subcommands (`adopt`, `discard`, `archive`) require `--yes` OR TTY confirmation — same operator-trusted-source model as `bridge-config.py:cmd_set`. `bridge-status.py` adds `pending_upgrade_conflict_count` + dashboard `WARNING: N pending upgrade-conflict file(s)` line and JSON `pending_upgrade_conflicts` field; threshold default 1 via `BRIDGE_UPGRADE_CONFLICT_WARN_THRESHOLD` env or `--upgrade-conflict-warn-threshold` CLI override.

### Fixed (#522)

- `hooks/pre-compact.py` now emits the v1 envelope (`schema_version="1"`, agent, captured_at, session_type, trigger, source, custom_instructions_excerpt, suggested_entities, suggested_concepts, suggested_slug, suggested_title, excerpt, transcript_available, optional canonical_snapshot) alongside the canonical-snapshot sidecar via `bridge-memory capture --text-file`. Capture body format: `schema_version=1 | excerpt=...` head + blank line + JSON envelope. `scripts/librarian-process-ingest.py:load_envelope()` shape-1 branch unwraps a nested `envelope` field on `.json` captures so bridge-memory's wrapper shape (root capture metadata + nested envelope) reaches the librarian with all envelope-only fields (`excerpt`, `suggested_entities`, `suggested_concepts`) intact. `extract_managed_claude_block` / `refresh_managed_claude_block` generalized to take delimiter-pair args (legacy wrappers retained for back-compat).

### Fixed (#526 — PR #530)

- `agent-bridge agent create --help` no longer creates an agent literally named `--help`. Strengthened central `bridge_validate_agent_name` (`lib/bridge-core.sh`) with regex `^[A-Za-z0-9][A-Za-z0-9._-]*$` plus reserved-name list (`--help`, `-h`, `--version`, `--debug`, bare `help`/`version`). All three callsites inherit (`bridge-agent.sh:run_create`, `agent-bridge` dynamic spawn, `lib/bridge-wave.sh` worker dispatch). Help-first short-circuit in `agent create` so `--help`/`-h`/bare `help` print usage before positional binding. Sibling subcommands (show/start/stop/restart/attach/forget-session/compact/handoff) safely die via existing `bridge_require_agent` "not registered" branch.

### Fixed (#529 — PR #532)

- `BRIDGE_AGENT_CHANNELS` development-channel plugins (e.g., `plugin:foo@private-marketplace`) now actually reach `claude` argv. Closes the silent "diagnostic OK / actual launch missing" bug where `agent-bridge agent show X` reported `launch_allowlisted: yes` for every dev-channel while the real launched process loaded only operator-pasted tokens. `bridge_agent_launch_cmd()` (`lib/bridge-state.sh`) now calls `bridge_claude_launch_with_development_channels()` in every Claude branch (dynamic / resume / static / fallback); helper's existing dedup handles raw-paste operators. Diagnostic alignment: `channel_diagnostics` (`lib/bridge-agents.sh`) now feeds the simulation `bridge_agent_required_dev_channels_csv` (Claude-plugin-filtered) instead of `bridge_agent_dev_channels_csv` (raw), eliminating the simulate-vs-real drift.

### Operator action

- **None for the common path.** All eight fixes auto-apply on the first `agent-bridge upgrade --apply` to v0.7.5+.
- (optional) The new `agent-bridge agent update` typed updater is the only sound mutation surface for protected `agent-roster.local.sh` managed-role fields. Operators who previously hand-edited the file via `vim` should review whether to migrate to the typed flow — same audit-chain semantics, no protected-path bypass.
- (optional) Run `agent-bridge cron cleanup report --mode run-artifacts --older-than-days 7` on long-running hosts to preview the prune set before opting into periodic GC. Default behavior is unchanged (no automatic GC).
- (optional) Run `agent-bridge upgrade conflicts list` on hosts that have run multiple v0.5.x+ upgrades to inventory pending `.upgrade-conflict` files. The next `agent-bridge upgrade --apply` auto-archives any whose live-target hash hasn't changed since the conflict was written; remaining entries can be reviewed with `conflicts diff/adopt/discard/archive`.

## [0.7.4] — 2026-05-03

### Highlight — admin codex pair as a standard install asset (#517)

`v0.7.4` ships [#517](https://github.com/seanssoh/agent-bridge-public/issues/517) (operator approved 2026-05-03): every admin agent now gets a sibling `<admin>-dev` codex agent automatically, and the admin's CLAUDE.md gains a managed block codifying the pair-programming SOP — so the `AGENTS.md` "Multi-Agent Collaboration" workflow is a real install asset rather than relying on per-install custom edits or operator memory.

### Added (#517 — PR #521)

- `lib/bridge-admin-pair.sh` (new) — `bridge_admin_pair_name`, `bridge_ensure_admin_codex_pair`, `bridge_admin_pair_managed_block`. The pair is registered as `engine=codex`, `source=static`, `--always-on`, queue-only (no channels), workdir inherited from the admin. Idempotent: skips when the pair already exists. Tolerant on partial-create (rc!=0 with the roster mutated): reloads the roster and returns success if the pair is registered, so the SOP-block injection step still runs.
- `bridge-init.sh` — after admin agent create, ensures `<admin>-dev` exists and injects the managed pair-programming block into the admin's CLAUDE.md (via the new `bridge-upgrade.py inject-admin-pair-block` sub-command). Applies regardless of admin engine — the pair is always engine=codex; the SOP block is engine-neutral.
- `agent-bridge upgrade --apply` — backfills the pair on existing installs (idempotent) inside the existing `migrate-agents` branch, with the heredoc-scoped `SCRIPT_DIR` binding so the helper can locate `agent-bridge` under `set -u`.
- Admin CLAUDE.md gains a `<!-- BEGIN/END MANAGED:admin-pair-programming -->` block codifying the 6-step SOP (plan brief → plan-ok → implement → code-review brief → merge-on-implement-ok → off-hours autonomy). Operator overlay (any text outside the managed block) is preserved across `agent-bridge upgrade --apply`.
- `bridge-upgrade.py` — `extract_managed_claude_block` / `refresh_managed_claude_block` generalized to take delimiter-pair args (legacy wrappers retained for back-compat). `migrate_agent_home` refreshes the admin-pair block only when `session_type == "admin"`, so non-admin agents (including the new sibling codex pair) are never touched. New `inject-admin-pair-block` sub-command for the fresh-install path.
- `scripts/smoke/admin-codex-pair.sh` (new) — 7 contracts: pair name helper; bash↔python managed-block byte-identity (caller-renderer convergence guarantee between fresh-install and upgrade-install paths); first-inject writes block + preserves operator overlay + preserves the pre-existing AGENT BRIDGE DOC MIGRATION block; second-inject is a no-op (idempotent); dry-run reports change without mutating; missing admin home is skipped (not failed); engine=codex admin path through inject-admin-pair-block (engine-neutrality contract).
- `scripts/ci-select-smoke.sh` — `admin-codex-pair` added to `add_all_required_static`, plus path-trigger entries for `bridge-init.sh` / `lib/bridge-admin-pair.sh` and the existing `bridge-upgrade.{sh,py}` / `VERSION` group.

### Operator action

- **None for the common path.** Auto-applied on the first `agent-bridge upgrade --apply` to v0.7.4+. Operators with multiple admin agents per install will see one `<admin>-dev` codex agent created per admin on the next upgrade.

## [0.7.3] — 2026-05-03

### Highlight — issue #509 closed (compact recovery + skill discovery migration), `agb doctor` admin self-healing, `#516` settings gating

`v0.7.3` ships the full plan from [#509](https://github.com/seanssoh/agent-bridge-public/issues/509) (Sean's "stop SKILLS.md from re-emitting itself every session + don't drop SOUL/MEMORY on auto-compaction" candidate), the [#511](https://github.com/seanssoh/agent-bridge-public/issues/511) `agb doctor` read-only command for admin self-healing, and the [#516](https://github.com/seanssoh/agent-bridge-public/issues/516) static-only gate on shared `autoCompactWindow=400000` propagation. A small UX bundle bundled with #516 closes three smaller paper-cuts surfaced from the #509 wave handoff.

### Added (compact recovery — #509 P3 / C3+C4 — PR #510, deployment fix #512)

- `hooks/session_start.py`: on `matcher=compact`, prepend a `## Restored Context (post-compact)` block (SOUL.md, SESSION-TYPE.md, COMMON-INSTRUCTIONS.md, TOOLS.md, MEMORY.md) ahead of the queue protocol context. Resolves symlinks live; falls back to a pre-compact sidecar snapshot when the live file is missing.
- `hooks/pre-compact.py`: writes `state/agents/<agent>/compact-snapshot.json` before compaction, atomic, best-effort (never blocks `/compact`).
- `BRIDGE_COMPACT_RECOVERY={on,off}`, `BRIDGE_COMPACT_RECOVERY_FILES=...` (csv basenames), `BRIDGE_COMPACT_RECOVERY_MAX_BYTES=N` (UTF-8 byte cap, default **8192** — raised from 5120 in #515 to cover patch's 5607-byte SESSION-TYPE.md).
- `bridge_upgrade_propagate_claude_hooks` now registers PreCompact on every claude agent on every `agent-bridge upgrade --apply` (fixes the #510 deployment gap where existing agents had the new hook code but no `settings.json` wire — PR #512).

### Added (skill discovery migration — #509 C1/C2/C5 — PR #513, #514)

- `BRIDGE_SKILLS_DOC_MODE={legacy-catalog,plugin-routing,disabled}` (default `legacy-catalog` → strict superset of prior behaviour).
  - `plugin-routing` emits a compact `shared/skill-routing.md` (cross-agent installed-plugin index from `~/.claude/plugins/installed_plugins.json`) and stops emitting the legacy `SKILLS.md`.
  - `disabled` emits neither catalog file.
  - Mode flips clean up the *other* file via `state/doc-migration/backups/<stamp>/_shared/`.
- `agent-bridge skills list [--agent NAME] [--json]` — query CLI for "which agent has which plugin" (works in every mode). Filtered table view shows user-scope plugins as "also available to <agent>".
- `agents/_template/SKILLS.md` removed (was a stale catalog placeholder); `_template/CLAUDE.md` and `_template/SOUL.md` no longer hard-code the SKILLS.md boot dependency. `docs/agent-runtime/common-instructions.md` SSOT phrasing made mode-agnostic.

### Added (admin self-healing — #511 — PR #519)

- `agent-bridge doctor [--json] [--detectors KIND[,KIND...]]` — read-only CLI surfacing stuck-state cross-cutting signals so the admin agent (`patch`) can self-heal infra by calling existing primitives (`agent-bridge agent restart`, `agent-bridge update`). Detectors: `stale-stopped-with-queue`, `stale-blocked-task` (threshold via `BRIDGE_DOCTOR_BLOCKED_THRESHOLD_SECONDS`, default 86400), `cold-restart-suspect` (#167), `abnormal-session-pane` (opt-in placeholder). Action decisions stay with the admin agent LLM; daemon adds zero policy. SQLite is opened in `mode=ro` URI mode; the only subprocess is `agent-bridge agent list --json`. Each detector runs inside its own try/except so one failing detector emits a `kind: "detector-error"` row instead of crashing the CLI; `--detectors` is also an allow-list against error rows.

### Fixed (#509 follow-up tail — PR #515)

- `scripts/bulk-register-precompact.sh` enumerates dynamic claude agents via `agent-bridge agent list --json` instead of text-parsing the agent list and hardcoding `$BRIDGE_HOME/agents/<name>` (skipped 3 dynamic agents on the SYRS install before this fix).
- Stale `agents/_template/SKILLS.md` cleanup added to `bridge-docs.py:sync_shared_docs` so hosts that upgraded before PR #514 stop scaffolding new agents with the deleted placeholder.

### Fixed (#516 + handoff UX bundle — PR #518)

- **#516** — `bridge_claude_settings_mode` now gates the registered-workdir loop on `source=static`, and a registered-dynamic-agent exact-match short-circuit runs before the `BRIDGE_AGENT_HOME_ROOT` branch (added in r2). Dynamic claude agents whose workdir happens to live under the home root no longer inherit the static-only `autoCompactWindow=400000` shared default that inflated their context budget against operator intent.
- **SessionStart pending-task nudging** no longer counts `blocked` tasks. `pending = queued + claimed` only. Admin agents still see blocked-task counts via the existing `admin_blocked_self_cleanup_context` path so role-separation stays clean.
- **tool-policy hook false-positive on `.agents/` working dirs.** The substring fallback in `hooks/tool-policy.py:_bash_argv_references_system_config` (used when `shlex.split` rejects an unbalanced quote in a heredoc body) used to fire on short needles (`hooks/`, `state/cron/`) anywhere in prose. The new `_command_substring_hits_protected_needle` helper requires short needles to sit at a strict path-boundary character (`/`, `~`, `$`, `>`, `<`, `'`, `"`, `(`, `=`, `&`, `|`, `;`, `,`) or at start-of-string. Whitespace is deliberately excluded so heredoc prose mentions like `the chain at hooks/post.sh` keep passing. Project-level `.agents/` runtime working dirs are now writable via standard Edit/Write/heredoc-append tooling.
- **Dynamic-agent `NEXT-SESSION.md` handoff path.** `hooks/bridge_hook_common.py:agent_workdir` now falls through to a memoised `agent-bridge agent list --json` lookup when neither `BRIDGE_AGENT_WORKDIR` nor the static default home is available. Cron / external invocations of the SessionStart hook for a dynamic claude agent no longer drop `Handoff present:` emits. The runtime-side leg (manual-relaunch env propagation audit) is intentionally deferred — `bridge-run.sh` already exports `BRIDGE_AGENT_WORKDIR` on every supervisor restart, so the visible managed-agent regression is closed by the hook-side safety net.

### Operator action

- **None for the common path.** All migration steps auto-apply on the first `agent-bridge upgrade --apply` to v0.7.3+. `BRIDGE_SKILLS_DOC_MODE` defaults to `legacy-catalog` so a host that has not opted in sees no behaviour change. Hosts on dev channel between v0.7.0..v0.7.2 who manually ran `bulk-register-precompact.sh --canary` only (covering static agents) — the v0.7.3 upgrade auto-wire path reaches the dynamic agents on the next `--apply`. Verify with the snippet in `OPERATOR_ACTIONS_PENDING.md` v0.7.3 entry.

### Pair-review

- 9 codex review rounds across 5 #509-wave PRs (#510 r2, #512 r3, #513 r2, #514 r2, #515 r1) all closed in the wave. PR #519 (`agb doctor`) implement-ok r1. PR #518 (#516 + UX bundle) implement-ok r2 — r1 caught two bypass classes (D2 short-needle prefix-set too narrow, E unguarded HOME_ROOT branch for dynamic-under-root) which the r2 commits closed concretely with 5 new smoke cases.

## [0.7.2] — 2026-05-03

### Highlight — daily-backup death-spiral root-cause + auto-cleanup migration

`v0.7.2` fixes the chain of bugs documented in [#507](https://github.com/seanssoh/agent-bridge-public/issues/507) — orphaned `*.tgz.tmp.*` files filling host disks (~110 GB observed in a single overnight window across two hosts), no preflight free-space check, and a 30-day retention default that compounded the problem. The same release addresses two adjacent issues Sean surfaced during diagnosis: `state/tasks.db` was bundled raw into every daily tarball (uncompressible, ~30× multiplier under retention), and `backups/upgrade-*/` snapshots had no prune at all.

### Fixed (#507)

- **Stale `*.tgz.tmp.*` reaping.** `bridge-upgrade.py:create_daily_backup_archive` glob-deletes orphaned tmp files at the start of each attempt, age-gated by `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS` (default 180s = daemon timeout 120s + 60s grace) and serialized through an `flock`-backed lock file so a concurrent writer's tmp is never stolen. (Bug 1 in #507.)
- **Pre-flight free-space check.** `check_daily_backup_free_space` measures `shutil.disk_usage().free` against `max(prev_largest_archive × 1.5, 100 MiB)` and short-circuits to `outcome=skipped_disk_full` when insufficient. (Bug 2 in #507.)
- **`--retain-days` default 30 → 7.** Both `bridge-upgrade.py` argparse default and `BRIDGE_DAILY_BACKUP_RETAIN_DAYS` in `lib/bridge-state.sh` lowered. Existing operators who want the old 30-day window can set the env var explicitly. (Bug 3 in #507.)
- **Exclude list expanded.** `resolve_daily_backup_excluded_roots` now drops `worktrees/`, `runtime/{assets,media,extensions}/`, `.claude/worktrees/`, and the new `state/backup-snapshots/` walk root from the tar walk. `should_skip_daily_backup_relpath` now skips any path containing a `node_modules` part (mirrors the existing `__pycache__` skip). Operators can extend via `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS` (colon- or comma-separated relpaths). (Bug 4 in #507.)
- **`~/.claude.json` corruption recovery path.** Auto-cleanup (see Added) now runs `validate_claude_config` on every upgrade and surfaces `recovery_candidate` (latest `~/.claude/backups/<…>/.claude.json`) in the `[upgrade-complete]` task body when the file fails to parse. Documented in `KNOWN_ISSUES.md`. (Bug 5 in #507.)
- **`state/tasks.db` excluded from raw tar walk; replaced by online SQL snapshot.** `DAILY_BACKUP_RAW_SQLITE_EXCLUDES` drops `tasks.db` + `-wal`/`-shm`/`-journal` from the tar walk. `dump_sqlite_snapshot` opens `tasks.db` in `mode=ro`, runs `iterdump` through gzip into a process-private temp dir outside the tar walk, fsyncs, atomically moves into `state/backup-snapshots/tasks-YYYY-MM-DD.sql.gz`, and the tar walk explicitly adds today's dump as a single member. SQL dumps are ~10–20× smaller than raw .db, gzip well, and round-trip via `sqlite3 newdb < tasks-YYYY-MM-DD.sql`. `prune_sqlite_snapshots` mirrors `prune_daily_backup_archives` retention. (Adjacent bug, surfaced by Sean during diagnosis — not in #507's text.)
- **Daemon failure cooldown wired to outcomes.** `cmd_daily_backup_live` now emits a structured `outcome` field (`created`, `skipped_disk_full`, `skipped_concurrent`, `skipped_no_target_root`, `error_*`). `process_daily_backup` dispatches on `outcome` instead of inferring from `created`. `bridge_note_daily_backup_failure` writes `LAST_FAILURE_TS`/`REASON`/`DETAIL`/`WARN_TS` to `state.env`. `bridge_daily_backup_due` honors a `BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS` (default 3600s) cooldown after any failure, with one `daemon_warn` and one audit row per cooldown window (no log spam). `bridge_daily_backup_format_epoch` uses Python instead of GNU `date -d` for portability between macOS and Linux. State.env writes are atomic (tmp+rename).
- **Conservative `backups/upgrade-*/` prune.** `prune_upgrade_backups` keeps the in-progress `BACKUP_ROOT` plus the newest `BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT=5` snapshots, then deletes anything older than `BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS=14`. In `--no-backup` mode this step is skipped (operator hasn't signaled they're OK with destruction).

### Added

- **Auto-cleanup migration on every `agent-bridge upgrade --apply`.** New `lib/bridge-cleanup.sh::bridge_cleanup_daily_backup_residue` calls `bridge-upgrade.py cleanup-residue`, capturing a structured JSON payload (stale tmp removed, daily archives pruned, SQL snapshots pruned, upgrade-* prune outcome with preserved set, `~/.claude.json` status, `cleanup_failures` list, bytes freed). The summary plus an agent-safe verification block (`du`, `agent-bridge status`, `daily-backup state.env`, `verify-tasks-db`, `~/.claude.json` JSON parse, snapshot restore self-test on a temp DB — no raw `sqlite3` against live state) are appended to the `[upgrade-complete]` task body. `OPERATOR_ACTIONS_PENDING.md` v0.7.2 entry covers the manual fallback when `cleanup_failures > 0`.
- **`bridge-upgrade.py verify-tasks-db`** — read-only `PRAGMA quick_check` against `state/tasks.db` via `sqlite3.connect(file:?mode=ro)`, packaged so the bridge guard policy that flags raw `sqlite3` from agents doesn't fire.
- **`bridge-upgrade.py cleanup-residue`** — standalone CLI for the same residue cleanup the upgrade auto-runs. Useful for hosts that can't immediately upgrade or want to verify the new defaults without an upgrade cycle.
- **New env vars** (`lib/bridge-state.sh`): `BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS=3600`, `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS=180`, `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS=` (additive), `BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT=5`, `BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS=14`. Documented in `OPERATIONS.md`.
- **Test env override**: `BRIDGE_DAILY_BACKUP_FREE_BYTES_OVERRIDE` lets smoke tests inject a fake `disk_usage().free` value to exercise the `skipped_disk_full` branch deterministically.

### Operator action

- **None for the common path.** Auto-applied on the first `agent-bridge upgrade --apply` to v0.7.2+, then on every subsequent upgrade. Hosts where the auto step exited with `cleanup_failures > 0` should follow the manual fallback in `OPERATOR_ACTIONS_PENDING.md` v0.7.2 entry.

### Pair-review

- Codex (`agb-dev-codex`) plan-review r1 → `needs-more` (11 items: snapshot self-amplification, daemon cooldown wiring, concurrency safety, bug 6 scope, conservative upgrade-* prune, exclude list expansion, agent-safe verification). Plan-review r2 → `implement-ok` with 6 implementation guardrails (snapshot atomicity, missing-DB tolerance, `uuid4` not `uuid7`, GNU-only `date -d` portability, operator snippet path corrections, `agent-bridge status` not `agb status`, additional missing-tasks.db smoke case).
- Code-review r1 → `needs-more` (5 implementation gaps): (1) `dump_sqlite_snapshot` ran `iterdump` directly on the live DB without first calling `Connection.backup()` into a temp DB — risk of mixed dump if a writer commits between the schema and table SELECTs; (2) `_atomic_replace` staged `.partial` under `backup_dir.parent` but moved to `target_root/state/backup-snapshots`, raising `EXDEV` on cross-fs `BRIDGE_DAILY_BACKUP_DIR`; (3) `process_daily_backup` captured `$?` inside `if ! ...; then` (always 0 — masks timeout 124 and every non-zero rc); (4) `cmd_cleanup_residue` had no defaults for `backup_dir`/`upgrade_backups_dir`, so the operator-facing recovery command (`cleanup-residue --target-root <root>`) silently skipped stale-tmp / daily-prune / upgrade-prune; (5) `--json` output never included the cleanup payload despite the OPERATIONS.md contract. All five fixed in r2: `.backup()` into a temp DB before `iterdump`; partial moved to a sibling of the final inside `state/backup-snapshots/` (always same fs); `set +e`/`set -e` toggle to capture the real subprocess rc; `cmd_cleanup_residue` defaults `backup_dir = target_root/backups/daily`, `upgrade_backups_dir = target_root/backups`; `cleanup` field added to upgrade JSON payload.
- Code-review r2 → `needs-more` (1 blocker): `dump_sqlite_snapshot` failure for an *existing* `state/tasks.db` was being silently absorbed — the tarball shipped without raw .db (excluded) and without `.sql.gz` (failed), yet the daemon marked `outcome=created`, cleared failure state, and pruned older good backups. Reproduced with a corrupted `state/tasks.db` (Codex). Fixed in r3: `create_daily_backup_archive` now treats any `source_present=True` snapshot error as `outcome=error_sqlite_snapshot`, returns before tar write, surfaces `error_detail` + `snapshot_errors` to the daemon, and triggers the full failure path (cooldown + admin task). Missing source DB stays non-fatal. New smoke case `step_corrupted_tasks_db_blocks_archive` exercises the path.
- Operator-requested addition (r3): `bridge_note_daily_backup_failure` now files an **urgent admin task** (`[backup-failed:<reason>]`) on every recorded failure. `disk_full` gets a tailored body with `df`/`du`/`cleanup-residue` recovery commands; other reasons (`timeout`, `parse`, `subprocess_rc_*`, `error_*`) get a generic body with daemon log + state.env pointers. The task channel is best-effort (no-op if `BRIDGE_ADMIN_AGENT_ID` unset or CLI unreachable) and never raises into the daemon main loop. Cooldown gating in `bridge_daily_backup_due` already throttles to 1 task per cooldown window per failure reason — no spam.

## [0.7.1] — 2026-05-03

### Highlight — telegram-relay residue auto-cleanup at upgrade time

`v0.7.1` makes the v0.7.0 → v0.7.1 transition cleanup automatic. v0.7.0 removed the relay source surface (#501) but the live runtime cleanup was operator-driven via two manual prompts under `docs/proposals/`. v0.7.1 wires it into `agent-bridge upgrade --apply` so the common path requires no operator action.

### Added

- **Auto telegram-relay residue cleanup at upgrade time** (#505). `agent-bridge upgrade --apply` now runs `bridge-relay-cleanup.py` after the shared-settings rerender step, removing any leftover state from the v0.6.37+ relay daemon that v0.7.0 (#501) deleted the source for: `state/channels/telegram/{tokens.list,*.sock,<token-hash>/}`, per-agent `.telegram/relay-token` files, `BRIDGE_AGENT_CHANNELS["X"]` items containing `plugin:telegram-relay@*` (rewritten to `plugin:telegram@claude-plugins-official`, with unrelated channels preserved), and the `BRIDGE_TELEGRAM_RELAY_ENABLED` / `BRIDGE_TELEGRAM_USE_RELAY` scalar lines in `agent-roster.local.sh`. Stdlib-only Python helper, idempotent (no-op on a clean host or on re-run). Two-phase wiring: dry-run preview emits a `changed_paths` JSON list which is fed to `bridge-upgrade.py backup-extend-live` (so a later `upgrade rollback` can restore the touched files), then apply runs for real. Audit row `telegram_relay_residue_cleanup_applied` is emitted only when `any_changes` is true. Per-agent `.telegram/.env` and `.telegram/access.json` are preserved — the official plugin still reads them. The two operator-prompts under `docs/proposals/` (`v0.7.0-install-cleanup-verification-prompt.md` and `jjujju-migration-prompt.md`) are now fallbacks for hosts where the auto step couldn't run; `OPERATOR_ACTIONS_PENDING.md` v0.7.1 entry says "no operator action required" for the common path.

### Fixed (during PR #505 r1 review)

- **Roster mode preservation in atomic write.** `bridge-relay-cleanup.py:_atomic_write` now captures the existing file's permission bits + group ownership before write and re-applies them three times (fchmod on the tmp fd, chmod on the tmp path before replace, chmod on the final path after replace) so a `0600` `agent-roster.local.sh` survives the rewrite even under default `umask 022`. Tmp file is `tempfile.mkstemp`-allocated in the parent dir (no predictable `.cleanup-tmp` collision, no symlink-follow attack against a stale tmp).

### Operator action

- **None for the common path.** Auto-applied on the first `agent-bridge upgrade --apply` to v0.7.1+. Hosts that can't reach v0.7.1+ or where the auto step exited non-zero should fall back to the manual prompts named above.

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
  added Linux server admin patch E2E runbook (later removed in
  v0.14.5-beta6 repo cleanup, #1110).
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
