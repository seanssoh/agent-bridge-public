# Operations

This is the operator runbook for a normal Agent Bridge install.

The recommended layout is:

- Source checkout: `~/.agent-bridge-source`
- Live runtime: `~/.agent-bridge`

The source checkout is safe to pull from GitHub. The live runtime contains local
state, logs, queues, agent homes, and machine-specific configuration. Do not
replace it with a raw `cp -R` or `git clone`.

## Daily Startup

Verify prerequisites:

```bash
git --version
python3 --version
tmux -V
claude --version
```

On macOS, use Homebrew Bash when available because the system Bash is too old
for associative arrays:

```bash
/opt/homebrew/bin/bash --version
```

Start or verify the daemon:

```bash
~/.agent-bridge/agent-bridge daemon ensure
~/.agent-bridge/agent-bridge daemon status
```

If the shell integration is installed, the shorthand is:

```bash
agb daemon ensure
agb daemon status
```

On macOS, keep the daemon under `launchd` so crashes auto-restart:

```bash
cd ~/.agent-bridge
./scripts/install-daemon-launchagent.sh --apply --load
launchctl print gui/$UID/ai.agent-bridge.daemon
```

`agb bootstrap` also installs a sibling LaunchAgent / systemd timer
(`ai.agent-bridge.daemon-liveness` on macOS,
`agent-bridge-daemon-liveness.timer` on Linux) that watches
`state/daemon.heartbeat`. KeepAlive only catches process death; the
liveness watcher catches the silent-hang case (issue #265) where the
daemon process is alive but its main loop has frozen. It restarts the
daemon when the heartbeat mtime exceeds
`BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS` (default 600s) and honours
`BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS` (default 600s) to avoid
restart loops on a broken daemon. Pass `--skip-liveness` to `bootstrap`
to opt out, or invoke the installer directly:

```bash
./scripts/install-daemon-liveness-launchagent.sh --apply --load    # macOS
./scripts/install-daemon-liveness-systemd.sh --apply --enable      # Linux
```

`BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS` (default 60s, issue #767) is the
minimum interval between identical-fingerprint inbox nudges to the same
agent. The daemon hashes the agent's queued task IDs each sync cycle; if the
fingerprint has not changed and the previous nudge fired within this window,
the redundant nudge is suppressed and an `session_nudge_deduped` audit row
is emitted instead. This prevents `[Agent Bridge]: ACTION REQUIRED` payloads
from piling up in an agent's transcript while it is mid-tool-call. Per-agent
state lives in `state/daemon-nudge-state/<agent>.env`. Raise the value on
chronically-slow hosts; set to `0` to disable dedup entirely.

Check overall status:

```bash
agb status
agb list
```

If the daemon misbehaves, inspect live runtime logs:

```bash
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/state/daemon-crash.log
tail -n 80 ~/.agent-bridge/state/launchagent.log
tail -n 80 ~/.agent-bridge/state/launchagent-liveness.log     # macOS liveness watcher
tail -n 80 ~/.agent-bridge/state/systemd-daemon-liveness.log  # Linux liveness watcher
```

On launchd-managed macOS installs the daemon writes its stdout/stderr to
`state/launchagent.log` (the `StandardOut/ErrorPath` redirect target of the
`ai.agent-bridge.daemon` plist), so `state/daemon.log` freezes at the moment
launchd takes over. On installs where `state/launchagent.config` exists
(written by `scripts/install-daemon-launchagent.sh --apply` from this
version forward), `BRIDGE_DAEMON_LOG` defaults to the configured launchagent
log path recorded in that marker — including custom `--label`/`--plist`/
`--log-path` installs. Operators on Linux (systemd/nohup) installs, and on
pre-marker macOS installs that have not yet rerun `--apply`, keep
`state/daemon.log` as the SSOT. Setting `BRIDGE_DAEMON_LOG` in env always
wins. Operators on pre-v0.7.X installs can either rerun `--apply` once or
set `BRIDGE_DAEMON_LOG` in their environment.
`agb daemon status` prints both `log=` and `launchagent_log=` lines when
the operator's `BRIDGE_DAEMON_LOG` resolves to a file other than the
configured launchagent log, so you can confirm where output is landing
without guessing.

## Upgrade

표준 upgrade 절차는 [`UPGRADING.md`](UPGRADING.md) 에 정리되어 있다. 모든 install 에서 동일한 명령으로 진행한다:

**Current target**: upgrade to the latest **`v0.14.5-betaN`** release. The
v0.14.5 line is an ongoing prerelease series with no separate stable tag, so
the latest `v0.14.5-betaN` tag is the current target. A single
`agent-bridge upgrade --apply` lands there from any v0.7.x+ source; the
v0.13.7-v0.13.9 heredoc-chain fixes (extracted to `lib/upgrade-helpers/`) keep
the leap-path safe on Bash 5.3.9 hosts:

```bash
cd <source-checkout>
git fetch origin
git checkout "$(git tag -l 'v0.14.5-beta*' | sort -V | tail -1)"
./agent-bridge upgrade --apply
```

The per-release subsections below are operator follow-up notes (newest first),
kept as historical context — they are **not** separate upgrade hops.

### v0.14.1 completeness pass (2026-05-16) — operator follow-up

Patch release after the v0.14.0 E2E test on a fresh Ubuntu 24.04 VM. 8 fixes batched (6 clean-install regressions + 2 audit-A backlog).

**Upgrade path** (v0.14.1-era operator follow-up — for the current target see *Current target* at the top of this section):

```bash
cd <source-checkout>
git fetch origin
git checkout v0.14.1
./agent-bridge upgrade --apply
```

Single atomic step works from any v0.7.x / v0.8.x / v0.9.x / v0.10.x / v0.11.x / v0.12.x / v0.13.x source. The v0.13.7-v0.13.9 heredoc-chain fixes (extracted to `lib/upgrade-helpers/`) make the leap-path safe on Bash 5.3.9 hosts.

**Operator-visible changes since v0.14.0**:

- Linux `ensure_matrix_path failed` warning silenced on fresh installs (no `ab-shared` group yet). The platform discriminator now checks v2 primitives readiness via `getent ab-shared` before engaging.
- Hosts without `claude` / `codex` CLI: daemon no longer spams `[경고] always-on auto-start failed` — engine-CLI preflight skips the spawn with a single `daemon_info` line.
- Fresh-install admin onboarding auto-triggers — `agb admin` greets and asks 2 questions without the operator typing first.
- macOS `bridge-rerender-plan.XXXXXX.py` BSD `mktemp` literal-path bug fixed — settings rerender no longer blocks on stale file.
- `bridge-bootstrap.sh` on hosts without codex CLI: skips `<admin>-dev` pair creation + picker-sweep cron registration (was crash-looping). Operator can install codex + re-run bootstrap to backfill.

**Linux operators on v0.13.x or earlier with errors**: the symptoms below were closed by v0.14.1 and remain closed on the current target. Symptoms like:
- Hard-die at `current_layout=markerless(existing-install)` on clean install,
- Stop-hook spam `ensure_matrix_path failed`,
- Always-on auto-start retry loop on missing engine CLI,

...are all closed as of v0.14.1. A single `agent-bridge upgrade --apply` from your current version lands at the current target (see top of section) cleanly.

**Runtime stop-gap removal**: operators who hand-patched `~/.agent-bridge/lib/bridge-isolation-v2.sh` (Darwin gate workaround for pre-v0.14.0) — the upgrade overwrites the stop-gap with the proper discriminator-based fix. No manual cleanup needed.

For per-stage detail, see `CHANGELOG.md` `[0.14.1]`.

### v0.14.0 stabilization milestone (2026-05-16) — operator follow-up

v0.14.0 batches S0-S3 + S5 Track A1/A2 of the v0.14.x stabilization plan. (Historical operator follow-up — for the current target see the top of the Upgrade section.)

**Upgrade path** (v0.14.0-era):

```bash
cd <source-checkout>
git fetch origin
git checkout v0.14.0
./agent-bridge upgrade --apply
```

`upgrade --apply` is a source-to-runtime copy. The new `lib/bridge-isolation-discriminator.sh` module + updated `lib/bridge-isolation-v2.sh` / `bridge-isolation-v2-migrate.sh` / `bridge-isolation-v2-reapply.sh` / `bridge-layout-resolver.sh` lands in `~/.agent-bridge/lib/` automatically. No special migration script is required for v0.13.10 → v0.14.0.

**Operator-visible changes**:
- `ensure_matrix_path failed` stop-hook spam on macOS is silenced (S2 + S3 fix).
- `BRIDGE_LAYOUT=legacy` env-leak no longer hard-dies when a valid v2 marker exists; emits a one-line warning and prefers the marker (S2 fix).
- New env knob `BRIDGE_ISOLATION_REQUIRED=auto|yes|no` (default `auto`: Linux→enforce, else→no-op). Explicit `yes`/`no` override is for self-test scenarios.

**If your install has a runtime stop-gap patch** (manual edit to `~/.agent-bridge/lib/bridge-isolation-v2.sh` to silence the stop-hook noise before v0.14.0): the upgrade overwrites it with the proper discriminator-based fix. No manual cleanup needed.

**Linux operators**: default behavior unchanged. `BRIDGE_ISOLATION_REQUIRED=auto` resolves to `yes` on Linux — every Bucket 2 gate keeps the existing chgrp/setgid/setfacl enforcement path.

**macOS operators**: the platform-discriminator gates make isolation-v2 enforcement an explicit no-op. The stop-hook noise that prompted the S2 fix is gone after upgrade.

For per-stage detail, see `CHANGELOG.md` `[0.14.0]`. For the stabilization roadmap, see `docs/stabilization-plan-2026-05-15.md` + `docs/audit-2026-05-15.md`.

### v0.13.x hotfix wave (2026-05-15) — historical context

**Current recommendation**: upgrade to the current target (the latest `v0.14.5-betaN` — see the top of the Upgrade section). This section is preserved as historical context for the leap-path blockers that v0.13.7-v0.13.10 resolved.

The v0.13.7-v0.13.10 cycle fixed a four-stage `agent-bridge upgrade --apply` blocker that affected the v0.7.x → v0.13.x leap on Bash 5.3.9 hosts (matched by recent Linux distros). Operators on macOS were similarly affected by a markerless-existing-install layout reject. The v0.14.x line carries those fixes forward — operators can leap directly from v0.7.x/v0.8.x/v0.9.x/v0.10.x/v0.11.x/v0.12.x to the current target in a single `agent-bridge upgrade --apply` step.

**Minimum-safe fallback upgrade path** (only if pinning below v0.14.0):

```bash
cd <source-checkout>
git fetch origin
git checkout v0.13.10
./agent-bridge upgrade --apply
```

Expected behavior (post-v0.13.10, also covered by v0.14.0):
- No hang on any of the four heredoc-class wedge points (read_comsub / heredoc_write variants resolved)
- Markerless-existing-install case: marker-only fast-path fires automatically when the roster has no isolated agents in the linux-user sense. No sudo required. Works on macOS, Linux, BSD.
- `isolation-v2 migrate result`: should show `"reason":"marker-only-no-isolated-roster"` for typical v0.7.x → v0.13.10 paths.
- `apply-live` completes within ~10 minutes; daemon, queue, agents accessible after restart.

**If your shell session predates v0.13.10**: the parent process may carry `BRIDGE_LAYOUT=legacy` env from the old install. Symptom on v0.13.10 and earlier: `agb` commands fail with `current_layout=legacy`. Workaround for v0.13.10: `unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT` in the affected shell, or restart Claude Code / tmux server. Marker on disk is correct; only the inherited env is stale. **Fixed in v0.14.0**: the resolver now demotes the hard-die to a warning when a valid v2 marker exists and prefers the marker.

**If your install has isolated agents in the roster** (linux-user mode, Linux only): the fast-path does NOT fire; the full migration runs and needs sudo for `groupadd` / `usermod`. Run with sudo available or follow the documented migration recipe.

**On macOS**: the marker-only fast-path covers the typical case (shared-mode agents). Avoid `agent-bridge agent add --isolated` on macOS — `dseditgroup` requires sudo and the isolation contract does not apply on macOS (POSIX setgid is Linux-only). Stay on shared mode. **v0.14.0 update**: the platform discriminator (`BRIDGE_ISOLATION_REQUIRED=auto` default) makes the no-op explicit — Bucket 2 enforcement primitives silently skip on macOS instead of emitting `ensure_matrix_path failed` warnings. Operators who need to self-test enforcement on macOS can set `BRIDGE_ISOLATION_REQUIRED=yes` to force engagement.

For per-release detail, see `CHANGELOG.md` v0.13.7 through v0.13.10. For stabilization roadmap, see `docs/stabilization-plan-2026-05-15.md` + `docs/audit-2026-05-15.md`.



```bash
agb upgrade --dry-run
agb upgrade --apply
```

`--apply` 는 atomic — daemon stop/start, agent restart, shared settings rerender (managed default `autoCompactWindow=1_000_000` propagate; 자세한 내용은 [autoCompactWindow default](#autocompactwindow-default-v076-issue-570) 참고), shared hooks 재등록, `_template/CLAUDE.md` sync, `[upgrade-complete]` admin task 등록 모두 포함.

The upgrader preserves local runtime data by default:

- `agent-roster.local.sh`
- `state/`
- `logs/`
- `shared/`
- `agents/*` runtime homes
- local backups and generated files

매 release 의 후속 행동 (operator action) 은 [`OPERATOR_ACTIONS_PENDING.md`](OPERATOR_ACTIONS_PENDING.md) 의 release section 으로 surface 된다. `upgrade --apply` 가 admin agent 한테 자동 등록한 `[upgrade-complete]` task 에서 reference 됨. troubleshooting + rollback + admin host source-checkout 변형은 `UPGRADING.md` 참조.

### Daily-backup tuning (v0.7.2+)

`agent-bridge upgrade --apply` 는 매 호출마다 `bridge-upgrade.py cleanup-residue` 를 자동 실행한다 (stale `*.tgz.tmp.*` 정리 + daily archive prune + `state/backup-snapshots/` SQL snapshot prune + `backups/upgrade-*/` 보수적 prune + `~/.claude.json` 검증). cleanup 결과는 upgrade JSON 출력과 `[upgrade-complete]` task body 의 "Backup residue cleanup" 섹션에 같이 실린다.

수동으로 동일 cleanup 실행:

```bash
TARGET_ROOT="$HOME/.agent-bridge"
python3 "$TARGET_ROOT/bridge-upgrade.py" cleanup-residue --target-root "$TARGET_ROOT"
```

Backup 동작 조정 환경변수 (모두 `agent-roster.local.sh` 또는 systemd unit env 에 export 가능):

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BRIDGE_DAILY_BACKUP_ENABLED` | `1` | `0` 으로 daemon-side daily backup 자체를 비활성화. cleanup 자체는 upgrade 시 여전히 동작. |
| `BRIDGE_DAILY_BACKUP_HOUR` | `4` | 시도 시작 시각 (0–23). |
| `BRIDGE_DAILY_BACKUP_RETAIN_DAYS` | `7` | tarball + SQL snapshot 보관 일수. v0.7.2 에서 30 → 7 로 축소 (#507). |
| `BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS` | `3600` | 실패 후 다음 시도 억제 시간. cooldown window 당 `daemon_warn` + audit row 1회. |
| `BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS` | `600` | daemon-side daily-backup walk+tar+gzip 의 `bridge_with_timeout` 상한 (#745 에서 hardcoded 120s → env-driven 300s, #975 에서 300s → 600s 로 multi-agent install 의 fresh-default timeout 여유 확보). 큰 install 은 더 올려서 사용 (예: 900). 비숫자/0/음수는 기본값 600 으로 폴백. |
| `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS` | `660` | `*.tgz.tmp.*` reaper 가 무시할 최소 나이 (= daemon timeout 600s + grace 60s). #745 에서 180 → 360 으로, #975 에서 360 → 660 으로 갱신; 직접 `BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS` 를 올리면 이 값도 비례해서 함께 올리는 것을 권장. |
| `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS` | (empty) | tar walk 추가 exclude (콜론 또는 콤마 구분 relpath). hardcoded 기본 제외: `logs/`, `worktrees/`, `runtime/{assets,media,extensions}/`, `.claude/worktrees/`, `state/backup-snapshots/`, plus any-depth `__pycache__` / `node_modules` / `plugins/cache` (#974 — Claude plugin cache, fully regenerable). |
| `BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT` | `5` | upgrade-* snapshot 최소 보존 개수 (현재 BACKUP_ROOT 는 항상 추가 보존). |
| `BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS` | `14` | retain count 를 넘긴 upgrade-* 중 이 일수보다 오래된 것만 prune. |

추가 exclude 를 영구 설정하려면 (#979) env var 대신 `state/daily-backup/excludes.conf` 파일을 쓰는 것이 권장 방법이다 — 한 줄에 relpath 하나, `#` 로 시작하는 줄과 빈 줄은 무시한다. shell eval 이 없어 일반 에디터로 바로 편집할 수 있고 upgrade 후에도 유지된다. 파일이 없으면 무시되며, 최종 exclude 집합은 hardcoded ∪ `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS` ∪ 이 파일의 합집합이다. 예시:

```
# example: an operator-chosen path to skip — one relpath per line
data/agents/<agent>/output
```

Health check (post-upgrade):

```bash
TARGET_ROOT="$HOME/.agent-bridge"
agent-bridge status | head -20
cat "$TARGET_ROOT/state/daily-backup/state.env"   # last success / failure / cooldown
python3 "$TARGET_ROOT/bridge-upgrade.py" verify-tasks-db --target-root "$TARGET_ROOT"
du -sh "$TARGET_ROOT/backups/daily" "$TARGET_ROOT/backups"/upgrade-*
```

For a source checkout to live runtime deploy during development:

```bash
cd ~/.agent-bridge-source
./scripts/deploy-live-install.sh --dry-run --target ~/.agent-bridge
./scripts/deploy-live-install.sh --target ~/.agent-bridge --restart-daemon
```

### autoCompactWindow default (v0.7.6+, issue #570)

`bridge-hooks.py render-shared-settings` writes a managed
`autoCompactWindow` default of `1_000_000` for every managed Claude agent,
regardless of model variant. The previous `[1m]` launch_cmd substring
heuristic (issue #547) never fired in practice — `[1m]` is a model-id
suffix the runtime *prints* (`claude-opus-4-7[1m]`), not a CLI argument
the launcher passes — so agents always landed on the legacy `400_000`
cap and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45` compacted at ~180K instead
of the intended ~450K. The unconditional 1M setting is a no-regret upper
bound: any model with a smaller native context window will compact
earlier on its own.

Operator overlays (`~/.agent-bridge/.claude/settings.local.json` and
per-agent base `settings.json`) still win over the managed default.
Operators who want to cap a particular install at the legacy 400K
window can set:

```sh
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
```

in `agent-roster.local.sh` (env wins over settings per Claude Code's
resolution order, so this overrides the managed default and survives
`agent-bridge upgrade --apply`).

**Per-agent settings.effective.json (issue #555).** As of v0.7.x+, every
managed agent has its own `settings.effective.json` rendered at
`$BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/settings.effective.json` and the
agent's workdir `settings.json` symlinks to it. Per-agent values are
independent: each managed agent renders its own file, so per-agent base
or overlay overrides are no longer clobbered by whichever sibling ran
the last `agb upgrade --apply` / restart-rerender.

The shared base (`$BRIDGE_AGENT_HOME_ROOT/.claude/settings.json`) and
overlay (`settings.local.json`) remain install-wide and are still
authoritative for hook wiring and operator overrides; only the *effective*
output (managed defaults + base + overlay) is split per agent.

Existing installs migrate automatically on the next `agb upgrade --apply`:
the per-agent loop renders each agent's per-agent effective file and
re-points its workdir symlink. The old install-wide
`$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json` becomes
orphaned but harmless after migration (no symlink references it);
operators may delete it manually after verifying the per-agent files
exist and contain the expected `autoCompactWindow` value.

### promptSuggestionEnabled default (v0.7.x+, issue #630)

`bridge-hooks.py render-shared-settings` writes a managed
`promptSuggestionEnabled: false` default for every managed Claude
agent, alongside `autoCompactWindow`. This disables Claude Code's
inline composer ghost text — the dimmed "Try asking …" suggestion
that appears in the input box after a turn completes.

Why this is a managed default: the daemon's pending-input detector
(`bridge_tmux_session_inject_busy` →
`bridge_tmux_line_has_sgr_dim`, `lib/bridge-tmux.sh:1322`) reads the
ghost text as real typed input and defers the first send of every
queued task until the nudge fallback fires (~30s–1min latency). PR
\#566 added an SGR-2 (dim) detector to filter the dim form, but
newer Claude Code builds render the suggestion with other ANSI
shapes (24-bit gray, 256-color faint, `\x1b[90m`) the narrow
detector misses (#630). Disabling the feature at the settings layer
is the stable fix — bridge-managed agents are operated through the
queue, not by a human typing in the composer, so the suggestion has
no value here.

Operator opt-out (re-enable for an agent you attach to interactively):
add `"promptSuggestionEnabled": true` to the per-agent overlay
(`settings.local.json`) or to the install-wide overlay
(`$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json`). Overlay wins
over managed defaults via the renderer's
`managed defaults < base < overlay < preserved user keys` order.

### PreCompact channel auto-notify (issue #597, in-flight)

Agent Bridge can post a one-line notice to the channel that most
recently messaged a static Claude agent when the agent enters auto
compaction, and a follow-up when compaction completes. The feature is
**default OFF** and lands in tracks: Track A (route primitive) and
Track D (Discord relay activity-index writer + smoke fixture) are
shipped; Track B (daemon observer + send primitive + EMA stats) and
Track C (Teams/Mattermost TS plugin writers) follow.

Operator surface, once all tracks land:

- Per-agent opt-in (in `agent-roster.local.sh`):
  `BRIDGE_AGENT_PRECOMPACT_NOTIFY["<agent>"]="1"`. The agent must be
  static, Claude-engine, channel-bound, and have received a recent user
  inbound (default 30 min) on at least one bound plugin channel.
- Global kill switch (no redeploy): `BRIDGE_PRECOMPACT_NOTIFY_DISABLED=1`
  in the daemon's environment, then restart or HUP the daemon.
- Recency window override:
  `BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS=<seconds>` (default `1800`).
- Dry-run for CI / smoke verification:
  `BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1` skips real network sends.

Activity index files live at
`$BRIDGE_STATE_DIR/channels/<plugin>/<agent>.json` and are populated by
the Discord wake relay (`bridge-discord-relay.py`) and, once Track C
ships, by the Teams and Mattermost MCP plugins. The route primitive
(`bridge-channels.py route-precompact-target`) is consumer-only and
returns exit 1 with empty stdout when no eligible recent inbound
exists, so a missing or empty index is a silent skip — never a hard
failure.

## Recommended Collaboration Pattern

1. Start agents
2. Create tasks through the queue
3. Let each agent claim work
4. Use urgent sends only for real interrupts

Typical operator flow:

```bash
agb --codex --name dev
agb --claude --name tester
agb task create --to tester --title "retest" --body-file ~/.agent-bridge/shared/report.md
agb inbox tester
agb claim 1 --agent tester
agb done 1 --agent tester --note "verified"
```

## Static Roles

Fresh installs have no static roles. This is intentional.

If you want machine-local static roles:

```bash
cp ~/.agent-bridge/agent-roster.local.example.sh ~/.agent-bridge/agent-roster.local.sh
```

Put machine-specific workdirs, channel IDs, tokens, and launch commands in
`agent-roster.local.sh`, not in tracked source.

Tracked prompt/profile templates live under `agents/`. Private production
prompt stacks should stay out of the public repository unless they are generic
enough for all users.

If the live CLI home differs from the bridge workdir, declare
`BRIDGE_AGENT_PROFILE_HOME["agent"]="..."` in `agent-roster.local.sh` and use:

```bash
agb profile status
agb profile diff <agent>
agb profile deploy <agent>
```

### Claude launch-flag overrides

For dynamic Claude agents (and static Claude agents that rely on the
bridge-built launch command), three optional roster fields control the
generated `claude` invocation:

| field | default when opted in | flag |
|---|---|---|
| `BRIDGE_AGENT_MODEL` | `claude-opus-4-7` | `--model` |
| `BRIDGE_AGENT_EFFORT` | `xhigh` | `--effort` |
| `BRIDGE_AGENT_PERMISSION_MODE` | `auto` | `--permission-mode` |

Leaving all three unset preserves the historical
`claude --dangerously-skip-permissions --name <agent>` shape byte-for-byte,
so rosters that predate these fields keep launching unchanged. Setting any
one field opts the agent into the new shape; remaining fields fall back to
the defaults above. Set `BRIDGE_AGENT_PERMISSION_MODE["agent"]="legacy"`
to explicitly pin the historical blanket-bypass shape (e.g. for sandboxed
offline roles).

### Admin agent CRUD policy

Admin operates exclusively through typed `agent <verb>` subcommands. Direct
edits to protected-roster files (`$BRIDGE_ROSTER_LOCAL_FILE`, by default
`~/.agent-bridge/agent-roster.local.sh`) are intentionally blocked because
the audit chain depends on the typed-write path. Any out-of-band edits will
be reverted by the daemon's reconciliation pass on next sync — bring
changes through `agent update` (or `agent-bridge config set` for global
settings) instead.

Typed verbs available today (run `agent-bridge agent --help` for the full
listing):

- `create` — scaffold a new static role (agent home + roster block).
- `update` — typed audited mutation of protected managed-role fields
  (`--desc`, `--engine`, `--workdir`, `--loop on|off|yes|no`,
  `--continue on|off`, `--class user|system`,
  `--idle-timeout <seconds>` (integer ≥0; `0` = always on, issue #1093),
  `--always-on yes` (sugar for `--idle-timeout 0`; v1 does not accept
  `--always-on no`), `--set-launch-cmd`,
  `--launch-cmd-add-env`/`--launch-cmd-remove-env`,
  `--launch-cmd-add-dev-channel`/`--launch-cmd-remove-dev-channel`,
  `--channels-set`/`--channels-add`/`--channels-remove`).
- `delete` — remove a static role (with optional `--purge-home` /
  `--purge-crons`).
- `retire` — retire a static role with quarantine + audit trail.
- `list` — inventory of registered agents.
- `registry` — read-only JSON inventory.
- `show` — roster + runtime state for one agent.
- `reclassify` — promote a runtime-detected admin to a static role.
- `rerender-settings` — re-render per-agent `settings.effective.json`.

Caller validation matches `config set`: caller must be the admin agent
(`BRIDGE_ADMIN_AGENT_ID`) and the source must be operator-trusted
(`operator-tui` / `operator-trusted-id`). Mutations that fail this gate
are denied with an audit row and never touch the roster file.

## Worktree Workers

When multiple agents may edit the same git repository, prefer isolated managed
worktrees:

```bash
agb --codex --name reviewer-a --prefer new
agb worktree list
```

Managed worktrees live under:

```text
~/.agent-bridge/worktrees/<repo-slug>/<agent>
```

Stale fixer worktrees accumulated under `<repo>/.claude/worktrees/agent-*` (or
`ab-*`) can be reaped safely with `agb worktree doctor`. The doctor classifies
each fixer-style worktree as REMOVE (branch merged into `main`), STALE
(unmerged but >14 days old), SKIP (stash entries present — refs/stash is shared
across worktrees, so we never remove when a stash is in flight), or KEEP.
Default is `--dry-run`; pass `--apply` to actually run `git worktree remove
-f`. See `agb worktree doctor --help` for `--target-branch`, `--max-age-days`,
`--include-stale`, and `--prune-branches`.

## A2A Cross-Bridge Handoff

A2A lets an agent on one Agent Bridge install enqueue a task directly into
another install's inbox queue over a Tailscale tailnet — no human relay. Each
install runs an HMAC-authenticated receiver daemon plus a durable sender
outbox. Full protocol + security model:
[`docs/a2a-cross-bridge.md`](./docs/a2a-cross-bridge.md).

**Setup.** Copy [`handoff.local.example.json`](./handoff.local.example.json) to
`$BRIDGE_HOME/handoff.local.json`, fill in this bridge's `bridge_id`, the
tailnet `listen` IP, and each `peers[]` entry (peer id, tailnet address,
ordered-pair HMAC `secret`, `inbound_allowlist`), then `chmod 0600` it. The
file carries peer secrets, is git-ignored, and the loader refuses it if any
group/world permission bit is set — `0600` is the recommended mode.

```bash
agb a2a daemon start|stop|restart|status|tick   # receiver daemon lifecycle
agb a2a send --peer <peer> --to <agent> --title <t> --body <text>
agb a2a deliver                                 # drain the sender outbox once
agb a2a outbox list|retry <id>|drop <id>|gc
agb a2a peers list|test <peer>
```

The receiver binds to the configured tailnet IP **only** and fails closed at
startup if the bind address is a wildcard / loopback / not in this node's
`tailscale ip` set, or if the `tailscale` CLI cannot be located. The CLI is
resolved on `PATH` first, then well-known locations (`/opt/homebrew/bin`,
`/usr/local/bin`, the macOS app bundle, `/usr/bin`); `BRIDGE_A2A_TAILSCALE_CLI`
overrides discovery for a non-standard install.

`handoff.local.json` and `state/handoff/` (durable outbox/inbox DBs + staged
bodies) are live-only operator-owned state — preserved across `agb upgrade`
like `state/`, `logs/`, and the local roster.

## Status And Debugging

Use these first:

```bash
agb status
agb status --watch
agb summary
agb list
agb doctor [--json]                # surface stuck-state signals (read-only) for admin self-healing recipes (#511)
agb cron inventory --limit 20
agb cron inventory --mode one-shot --limit 20
agb cron list --agent <agent>
agb cron errors report --limit 20
agb cron cleanup report
```

`agb status` includes columns for source kind, loop mode, queue load, wake
status, activity age, and stale-session health. Stale health is based on local
tmux activity and recorded bridge state, not on model calls.

For tooling that needs the full agent enumeration plus provenance and
privilege-class together (cleanup detectors, retirement scripts,
third-party housekeeping helpers), use `agb agent registry --json`. It
returns one JSON record per agent id known on this host (static +
dynamic + system) with `class` (`system|dynamic|static` — system wins
over the static/dynamic split for cleanup callers), `agent_source`
(raw `static|dynamic`), `privilege_class` (raw `user|system`), `home`,
`workdir`, `engine`, `session`, `is_alive` (tmux session present), and
`source` (which loader path made the id known: `static-roster`,
`dynamic-active-env`, `dynamic-history-live-session`,
`dynamic-tmux-recovered`). Output is sorted by id for stable diffs.
This is the recommended endpoint for any cleanup tool that needs to
subtract the live dynamic-agent set before flagging directories as
orphan — `agb agent list` does not surface dynamic agents, which is
why naive cleanup rules historically false-positived live `--prefer
new` workers.

When changing cron behavior, inspect jobs before modifying them:

```bash
agb cron show <job-id>
agb cron sync --dry-run
```

One-shot jobs should be tested with dry-run first:

```bash
agb cron enqueue <job-id> --slot 2026-04-05 --dry-run
```

Automatic recurring scheduling is **on by default** — once the daemon is
running, every registered job is considered for enqueue on each sync tick.
To opt out (for example, on a machine that should not actively enqueue
recurring work), set the flag explicitly to `0`:

```bash
BRIDGE_CRON_SYNC_ENABLED=0
```

Legacy variables `BRIDGE_LEGACY_CRON_SYNC_ENABLED` and
`BRIDGE_OPENCLAW_CRON_SYNC_ENABLED` are still honored for backwards
compatibility; any of the three explicitly set to `0` disables automatic
enqueue.

A pre-flight memory guard (#263 Track B) probes host memory before spawning
the cron disposable child. On Darwin the probe rejects dispatch when swap
usage meets or exceeds `BRIDGE_CRON_SWAP_PCT_LIMIT` (default `80`). On Linux
it rejects when `MemAvailable` drops below `BRIDGE_CRON_MIN_AVAIL_MB`
megabytes (default `512`). A deferred run writes `state=deferred` to the run's
`status.json`, emits a `cron_dispatch_deferred` audit row, and pings the
admin agent; the next scheduler tick re-fires the slot.

Inspect runtime state directly when needed:

```bash
cat ~/.agent-bridge/state/active-roster.md
sqlite3 ~/.agent-bridge/state/tasks.db '.tables'
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/logs/bridge-$(date +%Y%m%d).log
```

## Safe Cleanup

Kill active bridge sessions:

```bash
agb kill all
```

Stop the daemon:

```bash
agb daemon stop
```

**Active-agent guard** (issues #314 / #315): `bridge-daemon.sh stop` refuses
to stop the daemon when active bridge agents are running on the host, and
prints a banner pointing at the sanctioned upgrade entrypoint. To stop the
daemon during a recovery scenario, pass `--force`:

```bash
bash ~/.agent-bridge/bridge-daemon.sh stop --force
```

For a routine upgrade, prefer `agent-bridge upgrade --apply` — it handles
daemon stop + restart + agent re-launch internally and does not need
`--force`.

Remove only runtime artifacts if you need a clean local reset:

```bash
rm -rf ~/.agent-bridge/state ~/.agent-bridge/logs
mkdir -p ~/.agent-bridge/state ~/.agent-bridge/logs ~/.agent-bridge/shared
```

Do not delete `agent-roster.local.sh` unless you intentionally want to remove
local static roles.

### Test-artifact name policy (issue #598 Track 4)

Agent names matching test-artifact patterns are refused at create time and
on dynamic spawn unless the operator explicitly opts in with
`--test-fixture`. The blocked patterns are:

- prefix `smoke-`
- prefix `test-`
- prefix `bootstrap-`
- prefix `created-agent-`
- prefix `pref-`
- suffix `-repro-<N>` (digits)

```bash
# refused (no flag, looks like a leftover smoke fixture)
agent-bridge agent create smoke-foo

# accepted (explicit opt-in; cleanup tooling may reap this agent)
agent-bridge agent create smoke-foo --test-fixture

# same policy on dynamic spawn
agent-bridge --codex --name smoke-x --test-fixture
```

When `--test-fixture` is used, an `agent_test_fixture_created` audit row
records the opt-in so cleanup tooling can identify which agents were
created intentionally as test fixtures. Existing agents already in the
roster are grandfathered — the policy only fires at the create / new-spawn
entry point.

## picker-sweep utility (auto-unstick stuck Claude Code pickers)

Claude Code occasionally stops on an interactive picker (rate-limit options,
resume-from-summary, etc.) waiting for a human keypress. For long-running
tmux-managed agents nobody is watching, this freezes the session indefinitely.
`scripts/picker-sweep.sh` scans every tmux session, detects a picker that
matches a closed pattern allow-list, and presses Enter on the default option.

The utility is **auto-registered on every fresh install** (server and dev,
as of #833): `bridge-init.sh` registers a `*/10 * * * *` bridge-native cron
whose payload sets `BRIDGE_PICKER_SWEEP_ENABLED=1`, so the sweep runs out of
the box. Manual invocations (operator running `scripts/picker-sweep.sh` by
hand, outside the cron payload) still respect the host_profile=dev
default-skip — set `BRIDGE_PICKER_SWEEP_ENABLED=1` in the calling environment
to override that path. To disable the cron on a given install, run
`agb cron update picker-sweep --disable` after init.

### Required environment

| Variable | Purpose |
| --- | --- |
| `BRIDGE_PICKER_SWEEP_ENABLED` | Tri-state runtime gate. Unset on `host_profile=dev`: manual runs default-skip (hint emitted on stderr). Unset on any other profile (or no host-profile file): runs by default. Set to `1`: always runs regardless of profile. Set to `0`: always skips. The cron payload registered by `bridge-init.sh` and by the upgrade backfill always sets `=1`, so cron-fired runs are not subject to this default-skip — only ad-hoc manual invocations are. |
| `BRIDGE_PICKER_SWEEP_SELF` | Agent name to skip when scanning. Set this to the agent that *runs* the sweep so its own pane (which often contains picker text in PR bodies, docs, or logs) is not auto-Entered. Empty = no self-skip. |
| `BRIDGE_PICKER_SWEEP_NOTIFY` | Admin agent ID. When non-empty, picker-sweep enqueues a queue task summarising auto-unstick events. Empty = log-only. |

There is no fallback to `BRIDGE_ADMIN_AGENT_ID` — both knobs must be set
explicitly so a misconfigured operator does not silently lose the self-skip
defence.

### Registration paths

Three options, ordered by safety. Pick one.

#### A. OS crontab (recommended)

The OS scheduler invokes the script as a plain bash process, completely
bypassing claude/codex. There is no possibility of self-recursion if the
admin's own session ever stalls on a picker.

The crontab entry **must be one physical line** — `crontab(5)` does not
honor shell backslash continuation:

```cron
*/10 * * * * BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=admin BRIDGE_PICKER_SWEEP_NOTIFY=admin bash /full/path/.agent-bridge/scripts/picker-sweep.sh >> /full/path/.agent-bridge/logs/picker-sweep.log 2>&1
```

Replace `admin` with the actual admin agent's ID and `/full/path/` with the
absolute path to your `~/.agent-bridge` directory.

If the long inline form is hard to maintain, drop the env vars + path into
a small wrapper script and crontab the wrapper instead — only the crontab
entry has the one-line restriction:

```bash
# /full/path/.agent-bridge/scripts/picker-sweep-wrapper.sh
#!/usr/bin/env bash
export BRIDGE_PICKER_SWEEP_ENABLED=1
export BRIDGE_PICKER_SWEEP_SELF=admin
export BRIDGE_PICKER_SWEEP_NOTIFY=admin
exec bash "$(dirname "$0")/picker-sweep.sh"
```

Make the wrapper executable, then crontab it:

```bash
chmod +x /full/path/.agent-bridge/scripts/picker-sweep-wrapper.sh
```

```cron
*/10 * * * * /full/path/.agent-bridge/scripts/picker-sweep-wrapper.sh >> /full/path/.agent-bridge/logs/picker-sweep.log 2>&1
```

#### B. Bridge-native cron with a Codex target

The bridge cron runner currently wraps every payload in `claude -p` (or
`codex exec`), so the cron registration must target an agent whose engine is
not blocked by the very picker the sweep is meant to clear. Pick a Codex
agent (or any non-Claude target) for `--agent`:

```bash
agent-bridge cron create \
    --agent <codex-admin> \
    --schedule '*/10 * * * *' \
    --title picker-sweep \
    --payload 'BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=<admin> BRIDGE_PICKER_SWEEP_NOTIFY=<admin> bash $BRIDGE_HOME/scripts/picker-sweep.sh'
```

#### C. Bridge-native cron with a `payload_kind=shell` (future)

Once the upstream `payload_kind=shell` mode lands (tracked in the cron-runner
shell-payload bypass issue), the bridge-native registration becomes safe with
any agent target because the runner will execute the payload directly:

```bash
agent-bridge cron create \
    --agent <admin> \
    --schedule '*/10 * * * *' \
    --title picker-sweep \
    --payload-kind shell \
    --payload 'BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=<admin> BRIDGE_PICKER_SWEEP_NOTIFY=<admin> bash $BRIDGE_HOME/scripts/picker-sweep.sh'
```

Until that lands, prefer A.

### Limits and known gotchas

- The picker pattern allow-list is hardcoded. If Anthropic ships new picker
  shapes or rewords the existing options, update
  `_PICKER_OPTION_LINE_RE` in `scripts/picker-sweep.sh` and add a smoke case.
- The sweep presses Enter for the **default** option. For the rate-limit
  picker the default is "Stop and wait for limit to reset" (safe). For the
  resume-from-summary picker the default is "Resume from summary
  (recommended)". Both are conservative.
- If the same agent shows up across multiple sweeps in a row, the picker is
  not the root cause — it is a symptom of a deeper plan-level issue (rate
  limit window saturated, broken summary, etc). Investigate manually.

### Verifying

```bash
bash scripts/smoke/picker-sweep.sh
```

The smoke runs in an isolated `BRIDGE_HOME` with mock tmux + mock queue
seams; it does not touch a live tmux server or live queue state.

## Platform Scope

Agent Bridge runs on both macOS and Linux, but the two hosts have
different support targets for multi-tenant isolation:

- **macOS** is a developer and single-operator target. Static agents
  run in `shared` mode (the default); per-UID isolation is not
  implemented. Hardening is limited to the hook layer (tool policy,
  prompt guard) and operator vigilance.
- **Linux** is the production target for multi-principal deployments.
  `BRIDGE_AGENT_ISOLATION_MODE=linux-user` enforces per-agent UID
  separation and is required when agents hold delegated credentials or
  handle untrusted external input. See issues
  [#68](https://github.com/SYRS-AI/agent-bridge-public/issues/68) and
  [#85](https://github.com/SYRS-AI/agent-bridge-public/issues/85).

On macOS the `linux-user` mode falls back to shared silently (see
`bridge_agent_linux_user_isolation_effective` in
[`lib/bridge-agents.sh`](./lib/bridge-agents.sh)), and the migration
helper `agent-bridge isolate <agent>` (#85) exits with an explanatory
error. Full matrix and rationale in
[docs/platform-support.md](./docs/platform-support.md).

For the step-by-step operator walkthrough for transitioning an existing
Linux fleet from shared mode to per-UID isolation one agent at a time,
see [docs/isolation-migration-guide.md](./docs/isolation-migration-guide.md).

Isolated agents reach peer agents through the queue gateway, not the
SQLite DB directly. The per-agent scoped env file
(`<state>/agents/<agent>/agent-env.sh`) carries every static peer's id and
non-secret metadata (description, engine, session, workdir, isolation
mode, prompt-guard policy) so client-side validation
(`bridge_require_agent`, prompt-guard) passes for any registered peer.
Peer `BRIDGE_AGENT_LAUNCH_CMD` is **never** emitted into the scoped env —
the array entry is present-but-empty so callers fall through to the
controller-side path. Direct sqlite access from the isolated UID stays
blocked by the `BRIDGE_TASK_DB` ACL strip; gateway routing is selected
explicitly via the `BRIDGE_GATEWAY_PROXY=1` flag the scoped env writer
emits when `BRIDGE_AGENT_ISOLATION_MODE=linux-user`. See issue
[#294](https://github.com/SYRS-AI/agent-bridge-public/issues/294).

> **Upgrading from <0.6.13:** the gateway-proxy gate now requires
> `BRIDGE_GATEWAY_PROXY=1` in the scoped env. Restart isolated agents
> (`agent-bridge agent stop <agent>` then `agent-bridge agent start
> <agent> --no-attach`) so the env file is rewritten with the new flag.
> Sessions started under the old code keep working until restart, but
> A2A queue tasks from those sessions stop routing through the gateway
> until they pick up the new env.

### Picking up the curated `bin/` after upgrade

After v0.7.6+, isolated agents can call `agb` bare from their Bash tool
because the launcher prepends `${BRIDGE_HOME}/bin` to the agent's PATH
and the curated `bin/agb` shim auto-sources `BRIDGE_AGENT_ENV_FILE`
before delegating to the underlying `${BRIDGE_HOME}/agb`. Existing
isolated agents pick this up by re-running:

```bash
agent-bridge isolate <agent> --reapply
```

(idempotent; only re-installs the ACL contract, doesn't mutate
ownership) followed by an agent restart so `bridge-start.sh`
regenerates the agent's `agent-env.sh` with the new PATH.

### Isolated `agb` subcommand allowlist + audit

When `bin/agb` is invoked from an isolated UID context (env carries
`BRIDGE_GATEWAY_PROXY=1` AND the running UID differs from
`BRIDGE_CONTROLLER_UID`, both emitted by
`bridge_write_linux_agent_env_file`), the shim enforces a curated
allowlist:

- Allowed: `inbox`, `show`, `claim`, `done`, `summary`, `create`.
- Anything else (including `admin`, `upgrade`, `daemon`, `urgent`,
  `kill`, `attach`, `agent start|stop|restart|create|update`,
  `cron *`, `config set`, `setup`, `isolate`, `unisolate`, `worktree`,
  `audit`, `wave dispatch`) returns exit `64` with a clean message
  pointing the operator at the queue route
  (`agb create --to admin --title "..."`).

Every isolated invocation (allow or deny) appends a JSONL row to
`${BRIDGE_HOME}/logs/agents/<agent>/audit.jsonl` carrying
`{ts, agent, uid, subcommand, arg_count, decision, reason}`. Argument
**values** are intentionally not captured — task IDs and note text may
be sensitive — so audit reviewers see the call shape, not the
operator's text. Operators who need to invoke administrative
subcommands run `agb` from the controller shell, not from inside an
isolated agent's tmux pane. Existing isolated agents pick up the
controller-UID env-file emission by re-running the same
`agent-bridge isolate <agent> --reapply` + restart sequence from the
PR1 section above.

### Bridge-native skills under the isolated HOME

Bridge-native Claude skills (`agent-bridge-runtime`, `cron-manager`,
`memory-wiki`, `patch-permission-approval`) are synced into
`<isolated-home>/.claude/skills/<skill>/` on agent isolate, restart,
`agent-bridge isolate <agent> --reapply`, and `agb upgrade`. Claude Code
running under the isolated UID reads `~/.claude/skills/` from that home,
so the workdir-side symlinks used by shared agents are not visible
there — the bridge installs a parallel rendered copy into the isolated
home instead. Skill body text is normalized at sync time so every
`~/.agent-bridge/agb` and `~/.agent-bridge/agent-bridge` reference
becomes the absolute `${BRIDGE_HOME}/agb` (resp. `${BRIDGE_HOME}/agent-bridge`)
path. This decouples skill commands from `~` resolution under the
isolated UID and from the per-home `~/.agent-bridge` symlink, so they
work even on installs where that symlink is missing or the operator-home
parent path differs from `BRIDGE_HOME`.

### Bridge hooks under the isolated HOME (settings.json rendering)

Claude Code under the isolated UID reads `~/.claude/settings.json` from
the isolated UID's HOME, not from the workdir — so the workdir-side
shared-settings symlink installed for non-isolated agents is invisible
there. The bridge installs hook entries (Stop, UserPromptSubmit,
SessionStart, PermissionDenied, PreToolUse/PostToolUse) into the
isolated HOME by rendering a controller-owned
`<isolated-home>/.claude/settings.effective.json` and pointing
`<isolated-home>/.claude/settings.json` at it via a symlink.

Integrity contract: the effective file is owned by `root:root` mode
`0644`; the symlink is owned by the isolated UID but the underlying
target is not. The isolated UID can read the hook contract but cannot
mutate it from inside its own session. Pre-existing user keys
(`enabledPlugins`, `extraKnownMarketplaces`,
`skipDangerousModePermissionPrompt`) from any prior regular
`settings.json` are preserved across the transition.

The render runs on agent isolate, restart,
`agent-bridge isolate <agent> --reapply`, and `agb agent
rerender-settings --apply`. Operators on existing installs pick up the
synced skills and hook entries by re-running:

```bash
agent-bridge isolate <agent> --reapply
```

then restarting the agent so the next session loads the synced skills
and reads the rendered settings.

## Isolation v2 canonical state and migration

Agent Bridge v0.8 cut over to layout v2 (per-agent Linux user + private
group, group-based access, no named-user POSIX ACLs in the v2 layout
itself). Operators upgrading from v0.7.x or earlier may end up with an
install whose runtime tree drifted from the v2 contract — the most
common failure mode is leftover transitional ACLs from the v0.7 helper
`bridge_linux_grant_claude_credentials_access` (deleted in v0.8.0) that
were never stripped because the v2 cut-over did not migrate per-agent
home trees.

This section is the canonical v2 state spec and the recovery runbook.
The deeper reference (drift signatures, diagnostics, manual recovery
commands) lives at
[`docs/agent-runtime/v2-isolation-migration.md`](./docs/agent-runtime/v2-isolation-migration.md).

The contract itself is documented in source at
`lib/bridge-isolation-v2.sh:38-62`.

### Canonical state table

> Path prefix `$BRIDGE_DATA_ROOT` is the install environment variable
> (see `lib/bridge-isolation-v2.sh:36-62`). Default value is
> `~/.agent-bridge`; if the operator overrides it explicitly, the
> override path applies.

| Path | Owner | Group | Mode | Notes |
|---|---|---|---|---|
| `$BRIDGE_DATA_ROOT/shared/` | controller | `ab-shared` | `2750` | read-only public assets (controller writes) |
| `$BRIDGE_DATA_ROOT/state/` | controller | `ab-controller` | `2750` | controller-only state |
| `$BRIDGE_DATA_ROOT/agents/<agent>/` | **root** | `ab-agent-<agent>` | `2750` | per-agent private root, root-owned |
| `$BRIDGE_DATA_ROOT/agents/<agent>/{home,workdir,runtime,logs,requests,responses}/` | `agent-bridge-<agent>` | `ab-agent-<agent>` | `2770` | agent owns; controller reads via group |
| `$BRIDGE_DATA_ROOT/agents/<agent>/credentials/` | controller | `ab-agent-<agent>` | `2750` | controller writes, agent reads via group |
| `$BRIDGE_DATA_ROOT/agents/<agent>/credentials/launch-secrets.env` | controller | `ab-agent-<agent>` | `0640` | |
| `$BRIDGE_DATA_ROOT/agents/<agent>/agent-env.sh` | controller | `ab-agent-<agent>` | `0640` | |
| `$BRIDGE_DATA_ROOT/agents/<agent>/workdir/.<provider>/.env`, `access.json`, `state.json` | `agent-bridge-<agent>` | `ab-agent-<agent>` | `0600` | isolated-UID owned; controller reads via passwordless sudo (BRIDGE_AGENT_SUDOERS) |
| `/home/agent-bridge-<agent>/` (the agent's actual Linux home) | `agent-bridge-<agent>` | `agent-bridge-<agent>` | `0700` | **agent owns. No ACL of any kind.** |
| `/home/agent-bridge-<agent>/.claude/`, sub-tree | `agent-bridge-<agent>` | `agent-bridge-<agent>` | `0700` | same — agent-only, no ACL |

### POSIX ACL role

The v2 layout itself contains **no named-user POSIX ACLs at all**. PR-E
moved the v2 layout off named-user ACLs in favor of group ownership +
setgid, and PR #641 (v0.8.0, T2) hard-cut the remaining v0.7
`bridge_linux_grant_claude_credentials_access` helper that previously
granted the agent UID an `r--` ACL on the operator's
`~/.claude/.credentials.json` plus `--x` traverse up the ancestor chain.
There is no retained ACL surface on either the v2 tree or the operator's
home; v2 reaches Claude credentials via per-agent `claude login` (or a
pre-populated `launch-secrets.env`) — see
[`KNOWN_ISSUES.md` §16](./KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080).

If you find any named-user ACL inside the v2 tree
(`~/.agent-bridge/agents/<agent>/...`) or on `/home/agent-bridge-<agent>/`,
it is drift — the migration runbook below strips it.

### Claude setup-token registry and rotation

For Claude subscription accounts, the preferred shared-credential path is
not the controller's `~/.claude/.credentials.json`. Generate one or more
Claude Code setup tokens and let Agent Bridge render the active token into
each selected Claude agent's own `.claude/.credentials.json` file. Sync also
seeds the sibling `.claude/.claude.json` bootstrap file when missing, because
interactive Claude Code sessions require both files to skip first-run login
prompts. It also preserves `settings.json` while adding Claude's
`skipDangerousModePermissionPrompt` user setting for bridge-managed agents
that are launched with `--dangerously-skip-permissions`.

```bash
claude setup-token
agent-bridge auth claude-token add --id claude-a --stdin --activate --sync
# Paste the setup token on stdin, then press Enter and Ctrl-D.

claude setup-token
agent-bridge auth claude-token add --id claude-b --stdin --sync
```

The registry lives at
`$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json` (mode `0600`), and
`list` output shows only token ids and fingerprints:

```bash
agent-bridge auth claude-token list
agent-bridge auth claude-token activate claude-b --sync
```

To enable automatic rotation, register at least two enabled tokens and set
the threshold. The daemon reuses the existing Claude usage monitor signal
from `bridge-usage.py`; when a Claude usage window reaches the rotation
threshold once per reset cycle, it runs `rotate --if-auto-enabled --sync`.
Sync keeps only a non-secret `CLAUDE_CONFIG_DIR=` pointer in the legacy
`credentials/launch-secrets.env` file and removes any stale
`CLAUDE_CODE_OAUTH_TOKEN=` entry, so the active OAuth token is not inherited
by Bash/tool subprocesses.

The credential write path is hardened against two specific failure
modes (see PR #799 r2-of-Path-A):

- **Symlink attack on `.claude/`.** The agent owns its own home, so a
  pre-planted `.claude` symlink could redirect a privileged write
  outside the isolated home. The sync path rejects any non-real
  `.claude` directory and verifies the resolved real path stays
  inside the isolated user home before any `mkdir` / `chown` / write.
- **Atomic chown.** The credential / config / settings tempfiles are
  chowned to the isolated UID before `os.replace`, so the file is
  never root-owned at its final path. There is no window where Claude
  cannot read its own credential because the post-sync repair has not
  run yet.

Same-UID FS readability of the credential file is documented as a
defense-in-depth residual in [`KNOWN_ISSUES.md` §25](./KNOWN_ISSUES.md#25-claude-oauth-credential--same-uid-fs-readability-residual-799-r2-of-path-a).
A credential-helper enhancement is planned to close that gap in a
follow-up PR.

#### claude.ai OAuth fallback (#1075)

Setup tokens are the preferred provisioning path, but the operator may already
be logged in via `claude.ai` OAuth (Max subscription) on the controller and
not want to register a separate setup-token. In that case
`agent-bridge auth claude-token sync` falls back to seeding each per-agent
`CLAUDE_CONFIG_DIR/.credentials.json` from the controller's
`~/.claude/.credentials.json` — preserving the full payload
(`refreshToken`, scopes, etc.). Without this fallback a fresh non-admin
Claude agent reaches the REPL with `Not logged in` and any channel is
reported as `not currently available`.

The fallback uses the same per-agent ownership contract as the token-based
path: shared-mode agents get mode `0600` owned by the controller (same UID
as the agent); linux-user-isolated agents get the file chowned to the
isolated UID before `os.replace` and the symlink-rejection / `--allowed-root`
realpath check applies on both the per-agent destination and the controller
source. If neither a registered setup-token nor a readable controller
`.credentials.json` is present, sync fails per-agent with a clear
`controller credentials not found: …` error.

```bash
agent-bridge auth claude-token auto-rotate enable --threshold 99
```

If a stored token hits a Claude quota limit during a health check, Agent
Bridge records the reset estimate returned by Claude (for example
`resets May 13, 3am (UTC)`) as `disabled_until` / `next_check_at` and
keeps that token out of rotation while it is unavailable. The main daemon
then runs `claude-token recover-due` on its normal loop; once the reset
time has passed, it probes the token directly through the Claude CLI and
re-enables it when the probe succeeds. This recovery path is pure
script/daemon code and does not create agent tasks or expose token values
to queue payloads.

Manual health check:

```bash
agent-bridge auth claude-token check claude-b --disable-on-quota --enable-on-ok
agent-bridge auth claude-token recover-due
```

Manual fallback:

```bash
agent-bridge auth claude-token rotate --reason manual --sync
```

### v0.7 → v0.8 migration runbook

For an isolated agent that drifted across the v0.7 → v0.8 cut:

1. Upgrade and restart the daemon:

   ```bash
   agent-bridge upgrade --apply --restart-daemon
   ```

2. Inspect drift (planned for v0.9.0; until then run the manual
   recovery in `KNOWN_ISSUES.md` §16):

   ```bash
   agent-bridge migrate isolation v2 --check        # v0.9.0+
   ```

3. Apply the fix:

   ```bash
   agent-bridge migrate isolation v2 --apply        # v0.9.0+
   ```

   The migration covers `~/.agent-bridge/agents/<agent>/...` *and*
   `/home/agent-bridge-<agent>/...`, and strips all named-user POSIX
   ACLs across both subtrees. ACL preservation count: **0** — PR #641
   (v0.8.0, T2) deleted every v2-layer ACL-grant helper, so the
   migration is a strip-only pass with no surface to step around.

4. Re-launch the agent and verify the fix:

   ```bash
   agent-bridge agent start <agent>
   ```

If `agent-bridge migrate isolation v2` is not available (older install),
follow the manual recovery in `KNOWN_ISSUES.md` §16.

## Migrating to layout v2

The v2 layout (PR-A/B/C, shipped in v0.6.19) replaces named-ACL access on
per-agent runtime data with group-based ownership under a single
`$BRIDGE_DATA_ROOT`. PR-D adds the operator tool to migrate an existing
legacy install onto v2.

Activation criteria: marker file at `$BRIDGE_HOME/state/layout-marker.sh`
present, owner root or controller, mode 0640, content limited to an
allowlist of `BRIDGE_LAYOUT=v2` / `BRIDGE_DATA_ROOT=<absolute path>` / a
small set of group overrides. Anything else is rejected at load time and
the install falls back to legacy.

**Phases** (run from an out-of-band controller shell, NOT from inside an
Agent Bridge agent session — the migration tool's self-stop guard refuses
otherwise):

1. **dry-run** — print the legacy → v2 mirror plan and the
   profile_home preflight. No mutation. Use `--data-root` to choose the
   target (e.g. `/srv/agent-bridge`).

   ```bash
   agent-bridge migrate isolation-v2 dry-run --data-root /srv/agent-bridge
   ```

2. **apply** — stop active agents one by one, stop the daemon
   (active=0 path, no `--force`), ensure the v2 groups exist (sudo),
   real-copy mirror legacy → v2 (rsync, no hardlinks), write the marker
   atomically, restart daemon and the agents from the snapshot, post-flight
   probe each agent UID's groups via fresh `sudo -u <user> id -nG`.

   ```bash
   agent-bridge migrate isolation-v2 apply --data-root /srv/agent-bridge --yes
   ```

   Apply refuses if any agent's roster has an explicit
   `BRIDGE_AGENT_PROFILE_HOME` that is not `<data_root>/agents/<agent>/workdir`.
   Edit `agent-roster.local.sh` (via `agent-bridge config set`) to align
   the override and re-run, or unset it and re-run.

3. **soak** — operate on v2 for as long as you want to be sure things
   work. Rollback is cheap (legacy tree is intact until commit).

   ```bash
   agent-bridge migrate isolation-v2 status
   agent-bridge migrate isolation-v2 rollback --yes   # if needed
   ```

4. **commit** — tar-zst backup + delete the legacy paths recorded in the
   manifest as `verify_status=ok && delete_eligible=1`. Profile/skill/memory
   files (delete_eligible=0, see below) are NOT deleted.

   ```bash
   agent-bridge migrate isolation-v2 commit --yes
   ```

### Rollback hatch — `BRIDGE_DISABLE_ISOLATION=1`

If v2 isolation hits an unforeseen issue post-deploy, set
`BRIDGE_DISABLE_ISOLATION=1` in the controller environment (the daemon
unit, the operator's shell, or both — anywhere the bridge entry points
read the env), and restart the daemon plus any affected agents.

What it does:

- Skips the v2 secret-env exec wrap and the `umask 007` wrap in
  `bridge-run.sh`. The agent runs under the controller UID with the
  default 0077 umask.
- Skips the v2 group/sudo prep in `bridge-start.sh`. SUDO_WRAP stays
  inactive, no per-agent `agent-env.sh` is written, no Claude
  credential repair is attempted.
- Surfaces `isolation: disabled-by-env` in `agent-bridge agent show
  <agent>` and replaces the iso column in `agent-bridge agent list`
  with `disabled-by-env`. The configured `isolation_mode` is left in
  place so the JSON form still carries both fields.

What it does NOT do:

- Does NOT re-enable v1 ACL helpers — they are deleted in v0.8.0.
- Does NOT mutate the layout marker or any per-agent `isolation_mode`.
  v2 resumes the moment the env is unset and the daemon + agents
  restart.
- Does NOT call `agent-bridge migrate isolation-v2 commit`. Legacy
  paths (if any remain) are preserved.

This is a debugging escape, not a permanent operating mode. Operators
who set this should report the underlying issue upstream so v2 can be
fixed; long-term operation without isolation is unsupported in v0.8.0.

```bash
# Inline env on a single command line is NOT inherited by the spawned daemon.
# Export it in the shell that owns the daemon process, OR set it on the
# launchd / systemd unit, then restart.

# Operator-shell-managed daemon:
export BRIDGE_DISABLE_ISOLATION=1
./agent-bridge daemon restart

# systemd-managed daemon (Linux):
# Edit the unit file and add: Environment=BRIDGE_DISABLE_ISOLATION=1
# systemctl daemon-reload
# systemctl restart agent-bridge

# launchd-managed daemon (macOS):
# Edit the plist and add an EnvironmentVariables key:
#   <key>EnvironmentVariables</key>
#   <dict><key>BRIDGE_DISABLE_ISOLATION</key><string>1</string></dict>
# launchctl unload <plist> && launchctl load <plist>
```

### Editing profile / skills / memory after activation

After v2 activation, runtime resolvers (`bridge-skills.sh`,
`bridge-setup.sh`, `bridge-agent.sh`, `bridge-upgrade.sh`,
`bootstrap-memory-system.sh`, the wiki cron suite) read from the v2
workdir (`$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`). PR-D additionally
fixes `bridge_agent_default_profile_home` so that `agent-bridge profile
deploy` writes to the v2 workdir as well — closing a gap left by PR-A/B/C
where the profile alias still pointed at v2 `home/`.

These files are mirrored to the v2 workdir with `delete_eligible=0`,
meaning the install-root copy is **retained as a frozen snapshot** through
`--commit`:

- `agents/<agent>/CLAUDE.md`, `MEMORY.md`, `SKILLS.md`, `SOUL.md`,
  `HEARTBEAT.md`, `MEMORY-SCHEMA.md`, `COMMON-INSTRUCTIONS.md`,
  `CHANGE-POLICY.md`, `TOOLS.md`
- `agents/<agent>/SESSION-TYPE.md`, `NEXT-SESSION.md` (dual-read)
- `agents/<agent>/.agents/`, `memory/`, `users/`, `references/`, `skills/`

**Edit at the v2 workdir.** The runtime resolver reads the v2 path first;
the install-root copy is left in place so existing admin tooling and a
clean rollback remain possible. A future PR (PR-G) is expected to either
unify the two locations or mark the install-root copy read-only.

### v2 ACL contract (PR-E + PR #641 hard-cut)

PR-E removed named-user POSIX ACLs from v2 mode in favor of POSIX group
ownership + setgid. PR #641 (v0.8.0, T2) then hard-cut the remaining v0.7
`bridge_linux_grant_claude_credentials_access` exception, leaving the v2
layout with zero named-user ACL surface. Scope:

- **Scope.** When `bridge_isolation_v2_active`, every named-user ACL
  primitive (`bridge_linux_acl_add`, `bridge_linux_acl_add_recursive`,
  `bridge_linux_acl_add_default_dirs_recursive`,
  `bridge_linux_acl_remove_recursive`) and the v2-noopable wrappers
  (`bridge_linux_grant_traverse_chain`,
  `bridge_linux_revoke_traverse_chain`,
  `bridge_linux_revoke_plugin_channel_grants`,
  `bridge_linux_acl_repair_channel_env_files`) short-circuit to a
  no-op. Their replacements in v2 are group ownership + setgid:
  - **agent-env.sh**: chgrp `ab-agent-<name>`, chmod 0640
    (controller owner; isolated UID reads via group bit).
  - **per-UID `installed_plugins.json`**: chgrp `ab-agent-<name>`,
    chmod 0640 (root owner; isolated UID reads via group bit).
  - **`$user_home/.claude/plugins`** + `marketplaces`: chown
    `root:ab-agent-<name>`, chmod 2750 (setgid; new children inherit
    `ab-agent-<name>`).
  - **channel symlink target dir**: chown `<isolated_user>`, chgrp
    `ab-agent-<name>`, chmod 2770 (setgid; new files inside inherit
    group + group rw).
  - **channel dotenv/state files** (`.env`, `access.json`, `state.json`,
    `mcp.json` under `workdir/.<provider>/`): chown `<isolated_user>`,
    chmod 0600 — **no group read** (v3 contract, #998 PR B). Controller
    reads via passwordless sudo (`BRIDGE_AGENT_SUDOERS`), not the group
    bit. Run `agent-bridge migrate isolation v3 --check` to verify.
  - **bridge-run.sh launches**: `umask 007` is applied via
    `bridge_run_apply_v2_umask_if_needed` after `bridge_require_agent`,
    so most files created by the agent process tree land at 0660 with
    correct group ownership (channel dotenv/state files are excepted —
    see above).

- **No transitional exception (PR #641, v0.8.0 T2).** v0.7.x carried a
  single transitional exception for `~/.claude/.credentials.json` via
  `bridge_linux_grant_claude_credentials_access`. PR #641 deleted that
  helper as part of the v1 ACL hard-cut. The v2 layout now has zero
  named-user ACL surface — neither inside the v2 tree nor on the
  operator's home. v2 reaches Claude credentials via per-agent
  `claude login` (which writes
  `$BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude/.credentials.json` owned
  by the per-agent UID) or a pre-populated
  `$BRIDGE_AGENT_ROOT_V2/<agent>/credentials/launch-secrets.env`. See
  [`KNOWN_ISSUES.md` §16](./KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080).

- **Engine CLI prerequisite (v2).** v2 mode requires the engine CLI to
  resolve to a base-readable path (`other::r-x` along the entire
  ancestor chain). `bridge_linux_grant_engine_cli_access` validates
  both `cli_path` and its `readlink -f` target; controller-home paths
  are rejected with `bridge_die`. Install Claude/Codex in
  `/usr/local/bin` (or another path with no controller-home ancestor)
  before activating v2.

- **`acl` package.** v2 (with or without Claude) does not require the
  `acl` package — the v2 layout has no named-user ACL surface to grant
  or revoke (PR #641, v0.8.0 T2). `bridge_linux_prepare_agent_isolation`
  no longer gates on `bridge_linux_require_setfacl` for v2 mode.

- **`BRIDGE_SHARED_GROUP` membership.** v2 prep ensures the isolated
  UID is a member of `ab-shared` (default) so it can read the shared
  plugin cache. Controller failure to update its own membership is a
  warn unless the controller can no longer read
  `bridge_isolation_v2_shared_plugins_root`, in which case it
  escalates to die (the operator must re-login after the manual
  `usermod` for new group membership to take effect).

### PR-E smoke (operator-runnable)

```bash
# Always-on rootless cases (17, run on every PR review).
tests/isolation-v2-pr-e/smoke.sh

# Opt-in root-required cases (4, run against a live install with at
# least two ab-agent groups). Requires sudo -n -u <isolated-user>.
BRIDGE_TEST_V2_PRE_ROOT=1 tests/isolation-v2-pr-e/smoke.sh
```

The opt-in cases verify kernel-level cross-agent EACCES, self-agent
read access, engine CLI exec via the isolated UID, and the
`setgid + umask 007` composition for files created inside a v2
channel target dir. These cannot be substituted by rootless
fake-group assertions.

### Supplementary group refresh after first v2 isolated agent

When the first v2-isolated agent is created (or any time the controller
account is newly added to an `ab-agent-<agent>` group via
`usermod -aG` / `agent-bridge agent add --isolated`), already-running
controller processes — the daemon, every existing shell session, the
tmux server, hook subprocesses spawned from those parents — still hold
the **pre-add supplementary group set** until they restart. Linux
captures the supplementary group set at process exec time and does not
refresh it on later `usermod -aG`.

Until the controller side re-reads its group set, the new
`ab-agent-<agent>` group bit cannot be used to traverse into the
isolated tree even though the filesystem ownership is already correct.
Operators reproducing #1145-class issues from a fresh install (with no
controller restart in between) will see worse behavior than operators
who have already relogged after the most recent isolated-agent add.

Symptoms of skipping the refresh:

- Controller-side helpers cannot read into `$BRIDGE_DATA_ROOT/agents/<agent>/`
  even though `getent group ab-agent-<agent>` shows the controller as a
  member.
- `agent-bridge agent add --isolated` / `agent create` flow reports
  `Permission denied` on scaffold writes (`mkdir`, `mv`, `chown`) that
  vanish after a relog/restart.
- `agent start` exits before the Claude REPL is reached on the first
  v2-isolated agent of a fresh install.
- `agent-bridge watchdog scan` reports `scan_error/permission_denied`
  for the new isolated agent.

**Workarounds** (pick whichever matches the operator's daemon model):

- **Operator-shell-managed daemon (the common case).** Log out of the
  controller shell and log back in, OR start a fresh login shell via
  `newgrp ab-agent-<agent>` (one group per session — only refreshes
  that one group), THEN restart the daemon so it inherits the new
  group set:

  ```bash
  # Fresh login picks up every ab-agent-* group at once.
  exec $SHELL -l                 # or: log out and back in
  agent-bridge daemon restart
  agent-bridge agent start <agent>
  ```

- **systemd-managed daemon (Linux).** Group membership changes are
  picked up on the next service start; the operator's interactive
  shell still needs `newgrp` / relogin separately.

  ```bash
  sudo systemctl restart agent-bridge
  newgrp ab-agent-<agent>        # in the operator's own shell, if needed
  ```

- **launchd-managed daemon (macOS).** v2 isolation is not supported on
  macOS (see `KNOWN_ISSUES.md` §27 "Isolated-agent group setup on
  macOS"); this section is Linux-only.

This is a kernel-level behavior — not an Agent Bridge bug — but every
fresh install and every `agent add --isolated` adds the controller to a
new group, so it is the single most common source of "v2 isolation
broke after I added a new agent" reports. See
[`KNOWN_ISSUES.md` §28](./KNOWN_ISSUES.md#28-supplementary-group-refresh-required-after-first-v2-isolated-agent)
for the issue entry.

## Release Checklist

Before pushing bridge changes:

```bash
bash -n *.sh agent-bridge agb lib/*.sh scripts/*.sh
shellcheck *.sh agent-bridge agb lib/*.sh scripts/*.sh agent-roster.local.example.sh
bash ./scripts/oss-preflight.sh
./scripts/smoke-test.sh
```

If a change affects queue semantics, roster loading, session resume, worktree
handling, cron behavior, or upgrade behavior, include manual verification notes.

## Resume Checklist For Another Agent

If you just opened this repository and need to continue work:

1. Read `README.md`
2. Read `ARCHITECTURE.md`
3. Read `KNOWN_ISSUES.md`
4. Run `./scripts/smoke-test.sh`
5. Check `git status`
6. Check `agb status` if working in a live environment
