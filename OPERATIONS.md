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

## Upgrade

표준 upgrade 절차는 [`UPGRADING.md`](UPGRADING.md) 에 정리되어 있다. 모든 install 에서 동일한 명령으로 진행한다:

```bash
agb upgrade --dry-run
agb upgrade --apply
```

`--apply` 는 atomic — daemon stop/start, agent restart, shared settings rerender (`autoCompactWindow:400000` 등 managed default propagate), shared hooks 재등록, `_template/CLAUDE.md` sync, `[upgrade-complete]` admin task 등록 모두 포함.

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
| `BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS` | `180` | `*.tgz.tmp.*` reaper 가 무시할 최소 나이 (= daemon timeout 120s + grace 60s). |
| `BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS` | (empty) | tar walk 추가 exclude (콜론 또는 콤마 구분 relpath). hardcoded 기본 제외: `logs/`, `worktrees/`, `runtime/{assets,media,extensions}/`, `.claude/worktrees/`, `state/backup-snapshots/`, plus any-depth `__pycache__` / `node_modules`. |
| `BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT` | `5` | upgrade-* snapshot 최소 보존 개수 (현재 BACKUP_ROOT 는 항상 추가 보존). |
| `BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS` | `14` | retain count 를 넘긴 upgrade-* 중 이 일수보다 오래된 것만 prune. |

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

## Status And Debugging

Use these first:

```bash
agb status
agb status --watch
agb summary
agb list
agb cron inventory --limit 20
agb cron inventory --mode one-shot --limit 20
agb cron list --agent <agent>
agb cron errors report --limit 20
agb cron cleanup report
```

`agb status` includes columns for source kind, loop mode, queue load, wake
status, activity age, and stale-session health. Stale health is based on local
tmux activity and recorded bridge state, not on model calls.

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

### v2 ACL contract (PR-E)

PR-E removes named-user POSIX ACLs from v2 mode in favor of POSIX group
ownership + setgid. Scope and exceptions:

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
  - **bridge-run.sh launches**: `umask 007` is applied via
    `bridge_run_apply_v2_umask_if_needed` after `bridge_require_agent`,
    so files created by the agent process tree land at 0660 with
    correct group ownership.

- **Transitional exception (Claude credentials).** The v2 layout does
  not include the operator's `~/.claude/.credentials.json`, so
  `bridge_linux_grant_claude_credentials_access` retains named-user
  ACL access in v2 mode for that single file plus the traversal chain
  up to the operator's home. This is the **only** v2 surface that uses
  ACLs. PR-F or a future PR is expected to replace this with per-agent
  `claude login` (operator workflow change). The helper itself fails
  loud (`bridge_die`) when `setfacl` is unavailable, so silent breakage
  is impossible.

- **Engine CLI prerequisite (v2).** v2 mode requires the engine CLI to
  resolve to a base-readable path (`other::r-x` along the entire
  ancestor chain). `bridge_linux_grant_engine_cli_access` validates
  both `cli_path` and its `readlink -f` target; controller-home paths
  are rejected with `bridge_die`. Install Claude/Codex in
  `/usr/local/bin` (or another path with no controller-home ancestor)
  before activating v2.

- **`acl` package.** v2 + non-Claude engines do not require the `acl`
  package. v2 + Claude does, because the credential exception above
  uses `setfacl`. `bridge_linux_prepare_agent_isolation` gates
  `bridge_linux_require_setfacl` accordingly.

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
