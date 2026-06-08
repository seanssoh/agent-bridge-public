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

**Current target**: upgrade to **`v0.16.3`** (stable — current head of the v0.16
LTS line). It supersedes the `v0.16.2` / `v0.16.1` / `v0.16.0` / `v0.15.x` stable
line and all the `v0.16.0-rc1..rc3` / `v0.15.0-rc1` / `v0.15.0-betaN` /
`v0.14.5-betaN` prereleases, so the latest stable tag is the current target. A
single `agent-bridge upgrade --apply` lands there from any v0.7.x+ source; the
v0.13.7-v0.13.9 heredoc-chain fixes (extracted to `lib/upgrade-helpers/`) keep
the leap-path safe on Bash 5.3.9 hosts:

```bash
cd <source-checkout>
git fetch origin --tags
# Pin to the latest STABLE tag (vX.Y.Z, no -beta/-rc suffix) — currently v0.16.3.
git checkout "$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
./agent-bridge upgrade --apply
```

To stay on the v0.16 LTS line across future minors instead of auto-following the
global latest, pin the channel once with `agb upgrade --channel lts` (see
*`lts` upgrade channel — pin an install to the LTS line* below).

**A2A peers on a pre-v0.16.1 source (leap-path note, #1685):** if this host runs
the A2A cross-bridge receiver and you are upgrading from a **pre-v0.16.1** source
(v0.15.x, v0.16.0/rc), the *first* upgrade is run by the old upgrader, which does
not restart the receiver — it would otherwise keep running stale receiver code
(e.g. the pre-#1623 backpressure that silently 429s inbound peers). The
destination daemon now self-heals this on its next tick (one guarded,
preflight-gated restart). On a host whose always-on daemon is **not** running,
do it once by hand right after the upgrade:

```bash
bash <BRIDGE_HOME>/bridge-handoff-daemon.sh restart
agb a2a daemon healthz       # expect: healthy
```

Automatic from **v0.16.1+ → v0.16.x** onward. See *A2A receiver staleness
self-heal* under the daemon supervision section below for the full mechanism.

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

**Current recommendation**: upgrade to the current target (`v0.16.3` stable — see the top of the Upgrade section). This section is preserved as historical context for the leap-path blockers that v0.13.7-v0.13.10 resolved.

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

#### `lts` upgrade channel — pin an install to the LTS line (#1687)

v0.16.3+ 부터 `agb upgrade --channel lts` 는 install 을 **LTS 라인에 고정**한다. 보통
`upgrade --apply` 는 글로벌 최신 stable 태그를 따라가지만, `--channel lts` 를 한 번
지정하면 그 install 은 **LTS 시리즈 안에서만** 최신 non-prerelease 태그로 올라간다 —
즉 더 높은 minor 가 다른 곳에 떠도 LTS 라인을 벗어나 자동 점프하지 않는다. LTS 시리즈는
source root 의 `LTS_SERIES` pointer 로 정의된다 (현재 `0.16`); resolver 는 full-match
(prefix 아님) 이고 prerelease 는 건너뛴다.

선택은 **sticky** 하다 — `state/upgrade/channel` 에 기록되므로, 이후 plain
`agb upgrade --apply` 도 계속 LTS 라인에 머무른다:

```bash
agb upgrade --channel lts --apply   # LTS 라인에 고정 (sticky)
agb upgrade --apply                 # 이후 bare upgrade 는 LTS 라인 유지
agb upgrade --channel stable --apply # 글로벌 latest stable 로 복귀 (sticky 재기록)
```

채널 우선순위: 명시적 CLI `--channel`/`--version`/`--ref` > 내부 special-case >
기록된 sticky > legacy `stable`. **one-shot vs transient vs sticky**:

- `--version <tag>` / `--ref <ref>` 는 **one-shot** — 그 한 번만 해당 타깃으로 가고,
  기록된 sticky 채널을 덮어쓰지 않는다.
- `AGENT_BRIDGE_UPGRADE_CHANNEL` 환경변수는 **transient** — 그 호출에만 적용되고
  sticky 에 기록되지 않는다.
- `--channel <name>` 만 sticky 를 갱신한다.

resolver 는 **fail-closed** 다: `LTS_SERIES` 가 없거나 malformed 이거나 sticky write 를
검증할 수 없으면, 조용히 `stable` 로 떨어져 install 을 LTS 라인에서 미끄러뜨리는 대신
**명확한 remediation 메시지와 non-zero rc 로 거부**한다. `lts` 가 아닌 install 의
기본 동작은 그대로다.

#### upgrade/rollback singleton lock — concurrent runs refuse fast (#1661)

v0.16.2+ 부터 `agb upgrade --apply` 와 non-dry-run `agb rollback` 은 install 당 하나만
돌도록 **singleton lock** 을 잡는다 (`state/locks/upgrade.lock`, `lib/bridge-lock.sh`
shared helper — flock 우선, flock 없는 host 는 `mkdir` fallback). 같은 `BRIDGE_HOME`
에 대해 두 번째 mutating 호출이 동시에 들어오면 **즉시 거부(refuse-fast)** 한다:

```
agb upgrade --apply
# → upgrade/rollback already running (pid 12345, started 2026-06-08T...) — refusing
#    (use --wait [secs] to block); non-zero exit
```

- **운영/자동화 기대값.** upgrade 는 한 세션에서만(single-session) 돌린다. cron / watchdog
  / 동시 admin 세션이 같은 host 에 두 번째 `upgrade --apply` 를 쏘면 두 번째가 빠르게
  non-zero rc 로 떨어진다 — daemon + agent restart 가 서로 레이스하던 예전의 multi-process
  thrash (실제 host 에서 5-process thrash 관측) 를 막는다.
- **`--wait [secs]`.** 거부 대신 기존 run 이 끝날 때까지 **bounded wait** 하고 싶으면
  `agb upgrade --apply --wait 300` (초 단위) 으로 opt-in 한다. 기본값은 refuse-fast.
- **dry-run 은 lock 을 잡지 않는다.** `agb upgrade --dry-run` 은 mutating 경로가 아니라
  병렬 실행이 자유롭다. lock 은 `--apply` 와 non-dry-run `rollback` 에만 걸린다.
- **lock 자동 해제.** lock release 는 upgrade exit-handler 에 통합되어 있고, daemon /
  receiver / agent restart 같은 child spawn 은 상속받은 lock fd 를 떨어뜨린다 — upgrade 가
  죽거나 끝나면 lock 은 풀린다.

(Linux/flock host 노트: v0.16.2 는 이 lock 을 모든 flock host 에서 무력화하던 두 버그도
같이 고쳤다 — `flock -w 0` 이 실제 `flock(1)` 에 거부되던 것을 `flock -n` 으로, 그리고
`exec {fd}>>file 2>/dev/null` 가 shell stderr 를 영구히 묵음 처리하던 것을.)

#### migrate-agents: default-on, roster-restricted, no-downtime (#1611)

`upgrade --apply` 는 migrate-agents 를 **켠 채로** 두는 것이 권장 경로다.
`--no-migrate-agents` 로 끌 필요가 없다. migrate-agents 는 active/roster agent 의 canon
(CLAUDE/AGENTS managed block, skills, session-type template 등)을 최신으로 유지한다.

- **Roster-restricted by default.** v0.16.1+ 부터 migrate-agents 는 `agents/` 아래 모든
  디렉터리가 아니라 **roster 에 있는 agent 만** migrate 한다. roster set 은
  `state/agents-aggregate.tsv`(active+stopped 전체) + `state/active-roster.tsv` +
  `agent-roster.sh` / `agent-roster.local.sh` + admin agent 의 합집합이다. roster 에 없는
  orphan/test-agent home 은 skip 되고, JSON 의 `skipped_orphans` / `skipped_orphans_count`
  와 `[bridge-upgrade] migrate-agents: skipped N non-roster dir(s): …` stderr line 으로
  보인다. (예전에는 orphan home 이 쌓인 host 에서 전부 migrate 돼서 노이즈가 컸고, 그게
  운영자가 `--no-migrate-agents` 를 쓰던 이유였다 — 이제 그 이유가 없어진다.)
- **Safe fallback.** roster source 를 하나도 못 읽으면(또는 set 이 비면)
  `roster_filtering=unavailable` 로 떨어지며 **모든 dir 을 migrate** 한다. 진짜 agent 를
  놓치는 것보다 orphan 하나 더 migrate 하는 게 안전하기 때문이다.
- **Force-include orphans.** orphan 까지 포함해서 예전처럼 전부 migrate 하려면
  `agb upgrade --apply --migrate-all-agents` 를 쓴다(`roster_filtering=disabled`).
- **No-downtime for active sessions.** default-on 이 실행 중인 세션에 안전한 이유: #1598
  re-materialize 가 migrate 직후 workdir identity copy 를 즉시 갱신하고, active 세션은 다음
  auto-compact 에서 `CLAUDE.md` 를 다시 읽으며 self-heal 한다. 강제 재시작이 필요 없다.

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
| `BRIDGE_AGENT_MODEL` | `claude-opus-4-8` | `--model` |
| `BRIDGE_AGENT_EFFORT` | `xhigh` | `--effort` |
| `BRIDGE_AGENT_PERMISSION_MODE` | `auto` | `--permission-mode` |

Leaving all three unset preserves the historical
`claude --dangerously-skip-permissions --name <agent>` shape byte-for-byte,
so rosters that predate these fields keep launching unchanged. Setting any
one field opts the agent into the new shape; remaining fields fall back to
the defaults above. Set `BRIDGE_AGENT_PERMISSION_MODE["agent"]="legacy"`
to explicitly pin the historical blanket-bypass shape (e.g. for sandboxed
offline roles).

### Seeding new agents from a reference agent (template-sync, issue #1427)

On a fresh install, a newly-created non-admin agent comes up like a brand-new
Claude Code — Sonnet, low effort, no plugins/skills — because its config tree
is disjoint from the operator's `~/.claude` and from the admin agent. The
`template-sync` wizard is the opt-in way to seed new (and selected existing)
agents from a reference agent's roster fields:

```bash
agb setup template-sync [--from patch] [--exclude <csv>] [--dry-run] [--targets <csv>] [--yes]
```

(The wizard is interactive by default; the flags below are the non-interactive
shortcuts. The exact flag set is finalized by the wizard implementation — run
`agb setup template-sync --help` for the authoritative list on your install.)

- `--from <agent>` — the reference agent to read defaults from (default: the
  admin agent). The read is **roster-only**: model, effort, permission_mode,
  plugins, skills, channels. No live `~/.claude`, settings, env, or MCP runtime
  is introspected.
- `--exclude <csv>` — dimensions to drop (`model,effort,permission_mode,plugins,skills,channels`).
  The wizard is opt-out: it accepts every dimension by default and lets you
  exclude per-dimension / per-item.
- `--dry-run` — show the before/after diff (including the adjacent built-in
  launch-default refresh `claude-opus-4-7` → `claude-opus-4-8`) and write
  nothing.
- `--targets <csv>` — existing agents to backfill (defaults to none — new
  agents only). Existing agents are never touched until you name them here and
  confirm.
- `--yes` — skip the interactive confirm and accept the computed candidate
  (still subject to the dimension excludes and the legacy/secret refusals).

What the wizard writes is a controller-managed **defaults profile** block in
`agent-roster.local.sh` (do not hand-edit it — re-run the wizard). `agent
create <new>` then materializes those defaults as explicit per-agent roster
rows on the new role. Two operator-facing caveats:

- **Channels carry declarations only.** A synced channel such as
  `plugin:teams@mkt` copies the *declaration*, never the credentials. Re-run
  the per-channel setup wizard (`agb setup teams <agent>`, `agb setup ms365
  <agent>`, etc.) to populate tokens for the new agent. No secrets, `.env`,
  `access.json`, or refresh tokens are ever copied.
- **Restart to apply.** Roster fields are read at agent startup with no live
  reload, so launch/plugin/skill/channel changes from a backfill take effect
  only after `agb agent restart <agent>`. The wizard reports
  `restart_required=true` for runtime-affecting fields.

`permission_mode=legacy` is never inherited (the wizard refuses/omits it and
warns). Full design and security invariants:
[`docs/template-sync-design.md`](./docs/template-sync-design.md).

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

## A2A Rooms (beta)

A2A **Rooms** (v0.16.0-beta1) is a room / leader(방장) / join-on-approval
membership model that unifies internal-team and cross-bridge agent messaging,
plus an opt-in internal-queue ACL (`rooms_acl`, default **off**) that restricts
inter-agent queue creates to shared-room members — OS-enforced under linux-user
isolation (iso v2). The control plane (`agb room create|join|approve|list|show|
kick|leave|invite|rotate-invite|adopt-all|acl`) and its `rooms.db` live under
`state/handoff/` (preserved across `agb upgrade`).

As of **v0.16.0-rc1**, cross-node rooms (P4) are **wired and multi-node-verified**
on a live 2- and 3-node Tailscale mesh: a room spans nodes, the leader's roster
is broadcast over the node-link, and join-on-approval works across nodes (`agb
room create/join/approve/show`, the `agbroom://` invite, per-room epoch bumps,
and the P4.2 roster-broadcast were all confirmed cross-node). The Cloudflare Zero
Trust transport and whole-room `agb a2a send` fan-out remain the maturing edges
(the Tailscale transport is the verified one).

Full operator usage — lifecycle, the `adopt-all` → `enforce` migration, the
acting-identity (`--as`) regimes, and the honest security model — is in
[`docs/a2a-rooms.md`](./docs/a2a-rooms.md). Design rationale + schema:
[`docs/design/a2a-rooms-design.md`](./docs/design/a2a-rooms-design.md).

## Plugin channel `requires` (auto-provision dependency channels)

(v0.16.0-beta3+, #1528) A plugin can declare the other channels it needs at
runtime, so an operator no longer has to remember to hand-list every dependency
when creating an agent (forgetting one used to yield a half-provisioned agent
that looks created but can't authenticate or call its API).

**Declare** — in the plugin's `.claude-plugin/plugin.json`, an optional
top-level `"requires"` array:

```json
{
  "name": "my-crm",
  "version": "1.0.0",
  "requires": ["plugin:ms365@agent-bridge", "plugin:my-approval@my-marketplace"]
}
```

Each entry is a canonical channel spec `plugin:<name>@<marketplace>` (the same
form `--channels` takes; the `@marketplace` suffix is required for non-built-in
plugins).

**Resolve** — on `agent create`, after the `--channels` list is parsed and
before the dry-run gate, the create path transitively expands each plugin's
`requires` into the resolved channel set:

```bash
agent-bridge agent create alice --channels plugin:my-crm@my-marketplace
# [info] plugin:my-crm@my-marketplace requires plugin:ms365@agent-bridge, plugin:my-approval@my-marketplace — adding
# → alice is provisioned with all three channels
```

- **Dedupe**: a channel listed explicitly *and* pulled in as a `requires`
  appears once.
- **Transitive**: a `requires` chain is followed (BFS), with a depth cap
  (`BRIDGE_REQUIRES_MAX_DEPTH`, default 8) and cycle detection (`A→B→A` is a
  clear error, never a hang).
- **Never blocks create**: a `requires` pointing at a plugin not installed
  locally (e.g. a marketplace plugin not yet seeded) emits a `bridge_warn` and
  proceeds with the un-expanded set — the agent is still created.
- **`--dry-run`** shows the expanded set without creating, so you can preview
  what a channel pulls in.
- **Backward compatible**: a plugin with no `requires` behaves exactly as
  before (the resolved set is byte-identical). Core reads only what the manifest
  declares — there is no domain-specific dependency knowledge in the bridge.

The manifest `requires` lives with the plugin (in its marketplace/registry), so
a fleet-wide capability is declared once and every install that pulls the
marketplace gets the auto-provisioning. Caveat: a wholesale marketplace version
sync that overwrites the plugin's `plugin.json` will drop a `requires` added
out-of-band — declare it in the plugin's source so syncs preserve it.

## Daemon supervision (#1563)

(v0.16.0-rc1) The daemon is **crash-only and self-supervising**: when it detects
that it cannot make progress it *aborts* and lets the OS init layer restart a
fresh process, rather than trying to self-heal in place. There are two rings:

- **T1 — runner-process self-abort (in the daemon).** Each scheduler tick runs
  as a child in its own process group. The supervisor watches an in-tick
  *progress heartbeat*; if no progress is stamped for `(max-step-budget + grace)`
  the tick is **wedged** — the supervisor kills the child's process group (so a
  hung grandchild can't orphan), emits a `daemon_tick_deadline_exceeded` audit
  row, and exits non-zero. A **healthy long step that keeps stamping progress is
  never aborted** — the deadline is derived from the *longest configured bounded
  step* (so raising any `bridge_with_timeout` ceiling automatically widens it),
  never a fixed/nudge-latency number. This is the flapping-monitor guard.
- **T0 — OS init restart (outside the daemon).** launchd `KeepAlive` (macOS) /
  systemd `Restart=always` (Linux) turn the T1 non-zero exit into a fresh
  daemon. Install the systemd unit with `--watchdog` for an additional
  `Type=notify` + `WatchdogSec` outer ring (sized **above** the T1 deadline so it
  never fires before the daemon's own self-abort).

A hardened **singleton** guarantees exactly one daemon owns the lock + the
active-generation owner record; a loser exits cleanly and **never** evicts the
live holder, and a stale predecessor is evicted only after a positive
start-time proof (a *recycled* pid — same number, different `ps -o lstart=` — is
reclaimed without ever being signalled).

**Escalate, don't self-heal.** When the daemon's mechanical liveness check finds
the **admin agent itself** down (no live tmux session AND the daemon heartbeat
stale past the threshold), it does **not** restart the admin — it enqueues a
durable `created_by=daemon` task to the admin's codex pair (e.g. `patch-dev`). A
*busy* or long-turn admin (any live session) is **never** classified down. An
MCP-liveness give-up for the admin's own channel routes to the codex pair too
(audit-only when no pair is provisioned). A failed escalation task-create is
audited (`daemon_escalation_task_create_failed`) and **retried** on the next tick
— never silently swallowed.

**A2A receiver supervision.** A transient tailnet/bind-availability failure
(config + secret proven valid) **backs off** exponentially and, after enough
consecutive failures for the same `(config-fingerprint, error_class)` key, **opens
a circuit breaker** (stop respawning + escalate once per cooldown) instead of a
~9-minute hot crash-loop. A real **auth/config** error (bad/missing secret,
malformed config) is **held immediately** — retrying can't fix it. A successful
bind resets the breaker. The fail-closed tailnet bind proof / HMAC / allowlist
are **unchanged** — this is a supervision-policy layer only.

Env knobs (all optional; defaults are sized for production):

| Var | Default | Effect |
|---|---|---|
| `BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS` | `600` | Floor for the T1 max-step budget (raised by any larger bounded step). |
| `BRIDGE_DAEMON_TICK_GRACE_SECONDS` | `120` | Grace added on top of the max step before a tick is called wedged. |
| `BRIDGE_DAEMON_ADMIN_DOWN_STALE_SECS` | `900` | Heartbeat staleness before the admin is classified `down`. |
| `BRIDGE_DAEMON_ADMIN_DOWN_COOLDOWN_SECS` | `1800` | Re-escalation cooldown for the admin-down task. |
| `BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS` | `30` | First transient-failure backoff (doubles each consecutive failure). |
| `BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS` | `900` | Backoff ceiling. |
| `BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD` | `5` | Consecutive transient failures before the circuit opens. |

**A2A receiver staleness self-heal (upgrade bootstrap gap, #1685).** The A2A
receiver (`bridge-handoffd.py`) is a long-lived process with **no hot-reload**, so
an upgrade that changes receiver-side code only takes effect after the receiver
is restarted. From **v0.16.1+** the upgrader restarts it automatically — but the
restart block lives in the *destination* upgrader, while an upgrade is *run by
the source (old) upgrader*. So the **first** upgrade from a **pre-v0.16.1**
source (v0.15.x, v0.16.0/rc) runs an old upgrader with no restart block and
leaves the receiver on stale code (e.g. the pre-#1623 backpressure that silently
returns HTTP 429 *peer task quota reached* to inbound peers). The destination
daemon now closes this gap **source-version-independently**: on each tick it
compares the running receiver's boot time (a receiver-owned boot marker,
`state/handoff/receiver-boot.json`) against the "new code installed" cutoff
(`state/upgrade/last-upgrade.json` `updated_at`). A receiver that booted **before**
the cutoff (or carries **no** marker, i.e. it was started by a build that predates
the marker) is recycled **exactly once** per upgrade identity. The recycle is
**preflight-gated**: the config + secret + fail-closed bind proof are re-proven
**before** any stop, so a stale-but-*working* receiver is never turned into an
outage — a failing preflight leaves the receiver running and files an admin task
instead. A **systemd**-managed receiver (`agb-handoffd.service`) is restarted via
`systemctl --user restart`, never a shell stop/start. The one-shot is persisted
in `state/handoff/receiver-staleness.json`, so it **never loops**; normal receiver
supervision (above) owns any subsequent death/crash-loop.

| Var | Default | Effect |
|---|---|---|
| `BRIDGE_A2A_RECEIVER_STALENESS_INTERVAL_SECONDS` | `60` | Staleness-detector tick cadence (`0` disables it; e.g. a host that prefers manual restart). |

Surfaces:

```bash
agb a2a daemon status     # shows boot_marker / staleness (last self-heal result)
```

Observe it via the audit trail:

```bash
agb audit follow --action daemon_tick_deadline_exceeded     # T1 self-abort fired
agb audit follow --action daemon_admin_down_escalated       # admin-down escalation
agb audit follow --action a2a_receiver_circuit_open         # A2A breaker opened
agb audit follow --action a2a_receiver_stale_code_detected  # stale receiver caught (#1685)
agb audit follow --action a2a_receiver_stale_code_restarted # one-shot recycle succeeded
agb audit follow --action a2a_receiver_stale_code_restart_failed  # held (preflight/lifecycle)
```

**One-time manual step for pre-v0.16.1 sources.** If you upgrade to v0.16.x from
a **pre-v0.16.1** source and the always-on daemon is **not** running (so the
detector never ticks), restart the receiver once by hand after the upgrade so it
picks up the upgraded code:

```bash
bash <BRIDGE_HOME>/bridge-handoff-daemon.sh restart
agb a2a daemon healthz       # expect: healthy
```

This is automatic from **v0.16.1+ → v0.16.x** onward (the #1612 upgrader block),
and on any host whose daemon is running (the #1685 detector).

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

### cron-dispatch worker-pool size (`BRIDGE_CRON_DISPATCH_MAX_PARALLEL`, issue #1461)

When a single cron slot fans out several jobs at the same minute, the daemon
drains them through a bounded worker pool. The pool size is
`BRIDGE_CRON_DISPATCH_MAX_PARALLEL`, resolved with this precedence (highest
wins):

1. **`BRIDGE_CRON_DISPATCH_MAX_PARALLEL` environment variable** — the explicit
   override (e.g. the daemon LaunchAgent/systemd unit env). Wins outright when
   set to a positive integer.
2. **`cron_dispatch_max_parallel` in the runtime `bridge-config.json`** — the
   sanctioned, audit-chained, upgrade-safe path. This is the recommended way to
   tune it, because it survives daemon-unit regeneration and is written through
   the operator-gated config wrapper rather than by hand-editing
   `agent-roster.local.sh` (which `agb config set` cannot touch — the roster is
   a shell file):

   ```bash
   agb config set --path runtime/bridge-config.json \
     --change cron_dispatch_max_parallel=4
   bash bridge-daemon.sh restart   # re-source bridge-lib.sh so the daemon picks it up
   ```

3. **Host-profile-scaled default** — `host_profile=server` hosts (the
   cron-heavy case) default to `3`; `dev` / small-RAM / unknown hosts keep the
   conservative serial `1` baseline (issue #579). The host profile is recorded
   in `state/install/host-profile.json` (chosen at install time, or re-asked
   with `bridge-init.sh --reconfigure [--profile server|dev]`).

A malformed or absent config / profile file never raises — resolution falls
through to the serial `1` floor, so a corrupt tunable can never wedge the
daemon. Higher values raise throughput on cron-heavy installs but increase
peak RAM (each worker spawns a disposable engine child); the per-tick memory
guard above still gates each individual spawn.

Inspect runtime state directly when needed:

```bash
cat ~/.agent-bridge/state/active-roster.md
sqlite3 ~/.agent-bridge/state/tasks.db '.tables'
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/logs/bridge-$(date +%Y%m%d).log
```

### Codex `codex_apps` / MCP `token_invalidated` warning is not an Agent Bridge path

A Codex session may print a startup warning like
`MCP client for codex_apps failed to start … token_invalidated … 401`.
This is a **global `~/.codex` MCP configuration** issue — an MCP server that the
operator (or a prior `codex` install) registered in `~/.codex/config.toml` has a
stale/invalid auth token. **Agent Bridge injects no MCP config into Codex**: the
only `[features]` flags it pins are `features.hooks=true` and
`features.fast_mode=true` (see `lib/bridge-state.sh` / the
`scripts/python-helpers/launch-cmd-codex-hooks.py` re-materialization helper), so
no agent-bridge code path can be the source of this 401.

Resolve it globally in Codex, independent of Agent Bridge:

- Re-authenticate the MCP server: `codex mcp login` (or the server-specific
  login flow), or
- Remove the unused MCP entry from `~/.codex/config.toml` if it is no longer
  needed.

(Distinct from the renamed hooks feature flag: codex-cli 0.135.0 renamed the
`[features]` flag `codex_hooks` → `hooks`. Agent Bridge pins the new `hooks`
name; if you still see `[features].codex_hooks is deprecated`, an old roster
launch_cmd has not yet re-materialized — it converges to the warning-free name
on the agent's next wake.)

### Scheduled shell scripts without iso v2 (macOS / non-iso installs)

`agb cron create --kind shell --run-as-agent <agent>` runs a script under a
**dedicated isolated OS UID**. That UID only exists on Linux hosts with
linux-user isolation (iso v2) active, so **`--kind shell` is unavailable on
macOS and on any non-iso install** — create refuses with a message pointing
back here. There is no unguarded "run as the controller user" mode: executing
an operator script with the controller's full privileges on a schedule is a
different security posture than the iso-UID sandbox `--kind shell` promises,
so it is intentionally not offered as a silent fallback.

To run a script on a schedule without iso v2, pick one of:

1. **OS crontab (recommended).** The OS scheduler invokes the script as a plain
   bash process, completely bypassing claude/codex and the bridge daemon. This
   is the simplest path for health checks and other plain-shell tasks:

   ```cron
   0 */3 * * * /full/path/to/health-check.sh >> /full/path/.agent-bridge/logs/health-check.log 2>&1
   ```

   (The crontab entry must be one physical line — `crontab(5)` does not honor
   backslash continuation. If the inline form is unwieldy, crontab a small
   wrapper script instead; see the picker-sweep §A example below.)

2. **Bridge-native `--kind text` cron against a non-Claude (codex) agent.** A
   text-kind cron wraps its payload in `claude -p` / `codex exec`, so the
   payload can `bash` your script. Target a Codex agent so the turn is not
   itself blocked on a Claude picker:

   ```bash
   agb cron create \
       --agent <codex-agent> \
       --schedule '0 */3 * * *' \
       --title health-check \
       --payload 'bash $BRIDGE_HOME/scripts/health-check.sh'
   ```

   This keeps the schedule and the run history inside the bridge cron
   inventory (`agb cron inventory`, `agb cron errors report`) while still
   executing your shell script.

**`pgrep -c` portability.** Health-check scripts frequently count processes
with `pgrep -c <pattern>`, but `-c` is a Linux extension — macOS `pgrep` does
not support it and the script will error. Use a portable count instead:

```bash
count="$(pgrep -f '<pattern>' | wc -l)"
# or, when pgrep itself is unavailable:
count="$(ps aux | grep -c '[<]pattern>')"
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
  [#68](https://github.com/seanssoh/agent-bridge-public/issues/68) and
  [#85](https://github.com/seanssoh/agent-bridge-public/issues/85).

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
[#294](https://github.com/seanssoh/agent-bridge-public/issues/294).

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

Bridge-native Claude skills (`agent-bridge-runtime`,
`agent-bridge-operating-manual`, `cron-manager`, `memory-wiki`,
`patch-permission-approval`) are synced into
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
that are launched with `--dangerously-skip-permissions`. When keychain-free
auth is explicitly enabled, sync also renders an `apiKeyHelper` path into the
same settings file.

```bash
claude setup-token
agent-bridge auth claude-token add --id claude-a --stdin --activate --sync
# Paste the setup token on stdin, then press Enter and Ctrl-D.

claude setup-token
agent-bridge auth claude-token add --id claude-b --stdin --sync
```

**Sealed-paste entry (#1367, v0.16.0-rc1).** When you want the operator — not an
agent — to enter a token at a terminal, use the `receive` verb. It reads the
token **echo-off directly from `/dev/tty`** (never argv / env / stdin / a queued
body), so the secret is never captured into an agent transcript, the shell
history, the queue, or the audit log. It **fails closed** when there is no
controlling tty (e.g. inside a non-interactive agent session):

```bash
# Operator at a real terminal:
agent-bridge auth claude-token receive --id claude-a --activate
# Prompts on /dev/tty with echo OFF; paste the setup token, press Enter.
```

An admin agent can *request* a token without ever touching it: `receive
--request --id <id>` queues a token-free request that the operator later fulfills
with `receive --id <id> --fulfill <request-id>` (the echo-off read happens in the
operator's terminal, never the agent's).

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
On headless macOS hosts that must avoid Claude Code's native login-Keychain
fallback, enable the default-off helper path in runtime config:

```json
{
  "claude_keychain_free_auth": true,
  "claude_api_key_helper_ttl_ms": 60000
}
```

After changing the flag, run `agent-bridge auth claude-token sync --agents ...`
so each selected agent's `settings.json` includes the managed `apiKeyHelper`
path. The helper (`scripts/claude-oat-api-key-helper.sh`) reads the locked
OAT registry and prints only the active token to stdout for Claude Code; no
OAuth token is placed in `launch-secrets.env` or `CLAUDE_CODE_OAUTH_TOKEN`.
`CLAUDE_CODE_API_KEY_HELPER_TTL_MS` is exported as non-secret launch metadata
and defaults to 60000 ms so active-id rotation is picked up promptly.

On Darwin, `bridge-run.sh` and `bridge-cron-runner.py` fail closed before
launching `claude` when `claude_keychain_free_auth` is enabled but the helper,
settings entry, or active registry OAT is unavailable. This avoids falling
through to the operator user's default Keychain on headless rotation hosts.
The helper remains a same-UID oracle by design: any process running as the
agent UID can execute it, but the token is no longer readable from a file that
normal Bash/tool subprocesses inherit by default.

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

#### Native usage probe — proactive rotation on headless hosts (#1437)

Auto-rotation needs a Claude `used_percent` signal. The original source was
claude-hud's `.usage-cache.json`, written by a Claude Code **statusLine**
process via `scripts/hud-usage-tap.py`. On a **headless cron host** there is
no statusLine, so the cache is never written, the usage monitor sees no
Claude window, and the OAuth token is never rotated **before** the account
hard-limits — the operator only finds out when a 429 lands.

The native usage probe (`bridge-usage-probe.py`) gives Agent Bridge its own
percentage-driven source, **decoupled from claude-hud**. It performs a direct
`GET https://api.anthropic.com/api/oauth/usage` with the **currently-active
OAT** (read from the rotation registry; falling back to
`CLAUDE_CODE_OAUTH_TOKEN` or `~/.claude/.credentials.json`), maps the
response's `five_hour.utilization` / `seven_day.utilization` (a 0–100 scale)
into the **same** `.usage-cache.json` shape the monitor already consumes
(`data.fiveHour` / `sevenDay` / `fiveHourResetAt` / `sevenDayResetAt`), and
atomically writes the controller cache. The rotation/threshold logic is
**unchanged** — this is a new *source* that writes the cache the daemon
already reads. claude-hud is no longer required for proactive rotation; where
a live statusLine is present it remains an optional source.

```bash
# Manual one-shot (refreshes the controller .usage-cache.json):
bash bridge-usage.sh probe --json
```

The daemon runs the probe automatically inside its usage-monitor tick
(`bridge-usage.sh monitor`). To keep the daemon honest:

- **Feature flag** `BRIDGE_USAGE_PROBE_ENABLED` (default `1`) — set to `0` to
  disable the native probe entirely (e.g. if you rely solely on a live
  claude-hud statusLine).
- **Cache ≥5 min** `BRIDGE_USAGE_PROBE_MAX_AGE` (default `300` s) — the probe
  serves the existing native cache within this window instead of re-hitting
  the endpoint, so it does **not** make a network call on every tick.
- **Cooldown after failure** `BRIDGE_USAGE_PROBE_COOLDOWN` (default `60` s) —
  after any failed probe it serves the stale cache and skips re-probing until
  the cooldown elapses. A `429` `Retry-After` is honored once (capped at ~5 s),
  then it serves stale.
- **HTTP timeout** `BRIDGE_USAGE_PROBE_HTTP_TIMEOUT` (default `10` s).

> **Undocumented / internal endpoint.** `api/oauth/usage` is **not a public,
> documented Anthropic API** (`anthropics/claude-code#31021` was closed
> "not planned"). It requires the `anthropic-beta: oauth-2025-04-20` header
> and a `User-Agent: claude-code/<version>` header (omitting the User-Agent
> triggers aggressive `429`s — Agent Bridge always sends it, detecting the
> version via `claude --version` with a built-in fallback). The shape and
> availability may change without notice; the probe is **best-effort and
> fail-open** — any failure leaves the existing cache untouched and never
> blocks or crashes the daemon's usage pass.

> **`user:profile` scope required.** The active OAT must carry the
> `user:profile` scope for the endpoint to return usage windows. When the
> token lacks it the endpoint returns empty/null windows; the probe detects
> this (it does **not** fabricate a `0%` cache that could mask a real
> rotation trigger), logs a one-line hint, and degrades. Re-issue the token
> with the usage scope to enable native proactive rotation.

> **Credential handling.** The OAT is read into memory and used **only** in
> the `Authorization` header. It is never logged, never written to any file
> by the probe, and never exported into a subprocess env (the probe makes the
> request in-process via `urllib`, so there is no subprocess env-leak
> surface). This is the same containment posture as the rest of the
> token-rotation path.

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

### Iso v2 agent troubleshooting

Most "permission denied" / "file not found" reports against an iso v2
agent fit into a handful of categories. Walk this checklist before
escalating:

1. **Iso UID can't read controller HOME state** (Issue #1281). The
   controller's `~/.agent-bridge/state/active-roster.md` and
   `HEARTBEAT.md` are root-owned mode 0640 under the v2 contract;
   iso UIDs cannot read them by design. CLAUDE.md guides that
   reference these paths apply to the controller, not iso agents.
   Iso agents should use bridge CLI verbs (`agb agent list`,
   `agb status`) instead of direct fs reads.

2. **Body file at mode 0660 owned by iso UID** (Issue #1280).
   `agent-bridge a2a send --body-file <path>` and
   `bridge-task.sh create --body-file <path>` automatically try
   `sudo -n -u <owner> cat <path>` when the direct read raises
   `PermissionError`. If that fallback also fails (no sudoers
   entry for the controller→iso UID drop, or the iso UID does not
   own the file), the workaround is
   `sudo chmod 0644 <path>` before retrying. The fallback is
   logged in `state/audit.jsonl` so you can confirm whether the
   sudo step ran.

3. **Stale controller supplementary group membership**
   (Issue #1207). When a new iso agent is created, the controller
   needs to be added to `ab-agent-<a>` to read group-published
   credentials. If `id <controller>` does not show the new group,
   re-login (`exec sg ab-agent-<a> bash`) or wait for the next
   login session.

4. **Controller→iso boundary missed `bridge_iso_run`.** If a
   custom script direct-touches an iso-owned path
   (e.g. `cat /home/agent-bridge-<a>/.foo`) instead of going
   through `agent-bridge iso-run --agent <a> --op read-file`,
   the read will fail. The helper exists exactly to abstract
   the sudo drop; bypass surfaces as the same "permission
   denied" the operator reports.

5. **Audit trail when in doubt.** Every controller→iso boundary
   hop emits a structured row to `state/audit.jsonl`. Grep for
   `release_notification_downgrade_skip` (Issue #1267),
   `body_file_sudo_fallback` (Issue #1280), and the standard
   `bridge_iso_run` ops to confirm what actually happened versus
   what the operator thinks happened.

   The `body_file_sudo_fallback` row (emitted from both
   `bridge-queue.stabilize_body_file` and `bridge-a2a.cmd_send`)
   carries the following `detail` fields (v0.15.0-beta4 Lane J r3
   canonical schema):

   - `file_path` — absolute path of the body file
   - `iso_uid` — the per-agent OS user that owns the file
     (e.g. `agent-bridge-patch`)
   - `fallback_method` — always `"sudo-read"` for this audit action
   - `success` — `true` when sudo cat returned 0, `false` otherwise
   - `rc` — the sudo exit code on success/non-zero exit, or `""`
     when the subprocess itself raised (`OSError`, `TimeoutExpired`)
   - `call_site` — the producer code path
     (`bridge-queue.stabilize_body_file` or `bridge-a2a.cmd_send`)
   - `exception` (exception branch only) — `str(exc)`
   - `exception_type` (exception branch only) — `type(exc).__name__`
     (e.g. `TimeoutExpired`, `OSError`)

   Sample success row (`grep body_file_sudo_fallback state/audit.jsonl`):

   ```
   ..."detail":{"call_site":"bridge-queue.stabilize_body_file","fallback_method":"sudo-read","file_path":"/path/to/body.md","iso_uid":"agent-bridge-patch","rc":0,"success":true}
   ```

   Sample exception row (sudo wedged on a 10-second timeout):

   ```
   ..."detail":{"call_site":"bridge-a2a.cmd_send","exception":"Command '[...]' timed out after 10 seconds","exception_type":"TimeoutExpired","fallback_method":"sudo-read","file_path":"/path/to/body.md","iso_uid":"agent-bridge-patch","rc":"","success":false}
   ```

6. **dev-plugin-cache upgrade-conflict sidecar no longer cascade-fails
   launches** (Issue #1663, v0.16.2+). If an upgrade left a
   `*.upgrade-conflict` backup (mode 0600, owner-only) inside a
   dev-plugin source directory, the iso plugin-cache build used to hit a
   `PermissionError` reading it and abort the **entire** cache — taking
   down every iso agent that depends on that plugin (a real cm-prod iso
   v2 outage). The cache overlay now **pattern-skips** upgrade/VCS
   sidecars (`*.upgrade-conflict`, `*.orig`, `*.rej`, merge-tool
   sidecars, `.git`/`.hg`/`.svn`) and **per-entry guards** any other
   unreadable/unknown file — it is skipped with a warning instead of
   aborting the whole cache. The one exception is **required
   plugin-contract material** (`plugin.json`, `server.ts`/`server.js`,
   `package.json`, `mcp.json`): if one of those is unreadable the build
   now **fails loud** (`install-failed`) rather than silently shipping a
   broken plugin. Operator action: a leftover `*.upgrade-conflict` in a
   plugin dir is no longer launch-blocking, but it is still a stale
   backup — resolve it (`agb upgrade conflicts adopt`/manual) at leisure;
   a hard `install-failed` on a required contract file means that file
   really is unreadable and needs a permission/ownership fix.

For the developer-side rationale, see [CLAUDE.md](./CLAUDE.md) §
"Working with isolated agents (iso v2)" and
[docs/developer-handover.md](./docs/developer-handover.md) §3.1.

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

   **Shared-tree relocation + `.v2-shared-mirror.sentinel`.** Before any
   skip branch returns, apply real-copy mirrors the *active* shared tree
   (`$BRIDGE_HOME/shared` — wiki, cron artifacts, users, docs: everything
   `BRIDGE_SHARED_DIR` points at) into `<data_root>/shared` and drops a
   `<data_root>/.v2-shared-mirror.sentinel`. This runs on every path,
   including the macOS skip branches (marker-only-no-isolated-roster and
   macos-shared-agent) that otherwise relocate no data — without it the v2
   marker flips while the real shared tree stays stranded at the legacy path
   (the v2 wiki indexer then scans an empty `data/shared/wiki`). The legacy
   tree is **preserved** (`delete_eligible=0`); the resolver flip — not
   deletion — cuts `BRIDGE_SHARED_DIR` over to `<data_root>/shared`, and
   that flip is gated on the sentinel, so a marker-flipped-but-data-not-yet-
   mirrored install keeps reading the legacy content until the mirror
   completes. The step is idempotent (sentinel present → no-op) and
   self-repairing: re-running apply on an already-marker-flipped install
   that lacks the sentinel backfills the stranded tree. A mirror failure is
   warn-and-continue — the sentinel stays absent, the resolver stays on the
   legacy path, and the install keeps working.

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
treats the supplementary group set as a process credential established
at login / `setgroups` / `newgrp` and inherited across fork+exec — a
later `usermod -aG` does NOT propagate to already-running processes,
and a plain `exec $SHELL` inside the same shell preserves the stale
credential. Only a fresh login (or `newgrp` for a single group) builds
a new group set.

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

- **Operator-shell-managed daemon (the common case).** A full relogin
  (log out of the controller session and back in) builds a fresh
  supplementary group set including every `ab-agent-*` group the
  operator now belongs to. Alternatives that work from inside an open
  ssh/terminal session: reconnect the ssh session, or `newgrp
  ab-agent-<agent>` (one group per invocation — only refreshes that
  one group). A plain `exec $SHELL -l` from inside the stale shell does
  NOT refresh — the new shell inherits the parent's credential set.
  After the operator side has a fresh group set, restart the daemon
  so it inherits the new set too:

  ```bash
  # Pick one of these to refresh the operator shell:
  #   - log out + log back in (recommended on first install)
  #   - reconnect the ssh session
  #   - newgrp ab-agent-<agent>     # one group at a time
  # Then:
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
