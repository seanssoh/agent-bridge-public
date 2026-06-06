# Developer Handover

이 문서는 Agent Bridge를 처음 맡는 개발 에이전트가 빠르게 맥락을 잡고,
실수를 줄이면서 바로 개발에 참여할 수 있도록 만든 인수인계 문서다.

목표는 "이 프로젝트가 무엇인지"보다 "어디를 건드려야 하고 무엇을
건드리면 안 되는지"를 빠르게 이해시키는 것이다.

## 1. 먼저 이해해야 할 핵심

Agent Bridge는 Claude Code와 Codex 자체를 에이전트 런타임으로 사용하고,
그 위에 `tmux` + SQLite queue + daemon을 덧붙여 여러 에이전트를 협업시키는
얇은 로컬 orchestration layer다.

중요한 전제:

- 자체 모델 런타임을 만드는 프로젝트가 아니다.
- 업스트림 Claude/Codex 기능을 대체하기보다 연결하고 보완하는 프로젝트다.
- "queue-first", "daemon-safe", "runtime-preserving"이 설계 우선순위다.
- public repo는 특정 사설 팀의 private workflow를 그대로 담으면 안 된다.

## 2. 가장 먼저 읽을 문서 순서

새로 투입되면 아래 순서대로 읽는 것이 가장 빠르다.

1. [`README.md`](../README.md)
2. [`ARCHITECTURE.md`](../ARCHITECTURE.md)
3. 이 문서
4. [`OPERATIONS.md`](../OPERATIONS.md)
5. [`KNOWN_ISSUES.md`](../KNOWN_ISSUES.md)
6. [`AGENTS.md`](../AGENTS.md)

문서 역할 구분:

- `README.md`: 제품 개요, 설치, 운영자 관점의 사용법
- `ARCHITECTURE.md`: 엔트리포인트와 모듈 구조
- `OPERATIONS.md`: live install 운영과 업그레이드 절차
- `KNOWN_ISSUES.md`: 이미 알려진 함정
- `AGENTS.md`: 이 저장소에서 작업할 때의 개발 규칙

## 3. 절대 헷갈리면 안 되는 것

### Source checkout과 live runtime은 다르다

권장 레이아웃:

- source checkout: `~/.agent-bridge-source`
- live runtime: `~/.agent-bridge`

source checkout은 git으로 pull/push하는 개발 트리다.
live runtime은 실제 운영 상태가 쌓이는 설치본이다.

live runtime에는 아래가 섞여 있다.

- `state/`
- `logs/`
- `shared/`
- `agent-roster.local.sh`
- 실제 agent home
- queue DB와 daemon 상태

이 값들은 사용자/머신별 상태이므로, source repo처럼 다루면 안 된다.

### queue-first가 기본 계약이다

정상적인 에이전트 협업은 direct message가 아니라 queue를 통해 흘러야 한다.

기본 규칙:

- 일반 업무 전달: `task create`
- 진짜 인터럽트: `urgent` 또는 `bridge-send.sh --urgent`
- 에이전트 간 durable handoff 우선
- tmux 직접 입력은 예외 경로로 취급

queue semantics를 건드리는 변경은 항상 high-risk 변경이다.

### tracked source와 machine-local config를 섞지 않는다

tracked source에 두면 안 되는 것:

- 개인 머신 경로
- 채널 토큰
- Discord/Telegram/Teams ID
- private roster override
- 사설 팀 전용 프롬프트/규칙/사람 정보

machine-local 값은 `agent-roster.local.sh` 같은 local runtime 쪽에 둔다. 한 설치에만 적용할 공통 운영 규칙은 `shared/COMMON-INSTRUCTIONS.local.md`에 두면 `bridge-docs.py`가 생성된 `COMMON-INSTRUCTIONS.md` 끝에 명시적 마커와 함께 덧붙이고, `agb upgrade`는 이 override 파일을 보존한다 (파일이 없거나 비어 있으면 출력은 종전과 byte-identical).

### generated/runtime artifact를 source처럼 수정하지 않는다

개발 중 직접 수정하면 안 되는 대상:

- `state/`
- `logs/`
- live runtime의 `shared/`
- 운영 중 생성된 `agents/<name>` runtime home

이 프로젝트에서 수정해야 하는 대상은 대체로 tracked script, tracked docs,
tracked templates다.

### 3.1 Working with isolated agents (iso v2)

Linux 호스트에서 linux-user 격리(v0.8.0+ iso v2 스택)가 켜진 에이전트는
전용 OS user `agent-bridge-<a>` + primary group `ab-agent-<a>`로 동작한다.
컨트롤러(운영자 shell)는 의도적으로 그 그룹의 member가 아니다 — 그 경계가
agent 간 자격증명/runtime 분리를 보장한다. 대신 "shared-mode 에이전트처럼
다뤘다가 permission denied"하는 함정이 몇 가지 있다. iso 에이전트와 작업할
때는 다음 규칙을 기억하라.

- **iso UID 내부에서 read 불가한 경로.** 격리 에이전트는 컨트롤러의
  `~/.agent-bridge/state/active-roster.md`, `HEARTBEAT.md`, 다른 에이전트의
  home, 다른 iso UID의 runtime 파일을 직접 read 못 한다. CLAUDE.md/handover의
  "active-roster.md를 참조해서…" 가이드는 bridge CLI verb(`agb agent list`,
  `agb status`)를 통해야 한다.
- **shared 파일의 권한 dance.** Cross-class state 파일(per-agent metadata,
  shared marketplaces)은 controller-published 패턴이다: 컨트롤러가 root로
  쓰고 `chgrp -h ab-agent-<a>`, mode 2770 dir / 0660 file로 publish.
  Controller→iso 경계의 read/write는 `bridge_iso_run` /
  `agent-bridge iso-run` helper 한 곳을 거쳐야 한다(KNOWN_ISSUES.md
  §"iso v2 boundary"). 컨트롤러 코드가 iso UID 소유 path를 직접
  touch하지 말 것.
- **Body file도 같은 경계를 통과한다.** iso UID가 mode 0660 + owner
  `agent-bridge-<a>`로 쓴 body file은 컨트롤러 UID가 `ab-agent-<a>`의
  member가 아닌 한 직접 read 못 한다. v0.15.0-beta4 부터
  `bridge-task.sh create --body-file <path>`와 `agb a2a send --body-file <path>`
  는 `PermissionError` 시 `sudo -n -u <owner> cat <path>`로 자동
  fallback한다(Issue #1280). fallback도 실패하면 운영자가
  `sudo chmod 0644 <path>` 후 재시도.
- **iso 에이전트의 권장 흐름.** Agent 간 작업은 queue(`agb task create`)를,
  cross-bridge handoff는 `agb a2a`를 사용한다. iso UID 내부에서
  다른 agent의 branch에 `git checkout`하지 말 것, 다른 agent의 home의
  파일을 편집하지 말 것, sudo를 가정하지 말 것(default로 sudoers entry 없음).
- **알려진 제약 요약.**
  - 컨트롤러 HOME state 파일 직접 read 불가(active-roster.md, HEARTBEAT.md).
  - 다른 agent의 home / workdir에 직접 write 불가.
  - 운영자의 primary checkout에서 `git checkout <other-branch>` 금지.
  - iso UID에서 sudo 호출 금지(운영자가 명시적으로 sudoers grant한 경우 제외).

설계 의도에 대한 자세한 내용은 [CLAUDE.md](../CLAUDE.md) §"Working with isolated
agents (iso v2)"와 [OPERATIONS.md](../OPERATIONS.md) §"Iso v2 agent
troubleshooting"을 참조.

## 4. 저장소 구조를 이렇게 보면 된다

### 루트 엔트리포인트

주요 루트 스크립트:

- [`agent-bridge`](../agent-bridge): operator-facing 메인 CLI
- [`agb`](../agb): 짧은 wrapper
- [`bridge-start.sh`](../bridge-start.sh): static role 시작
- [`bridge-run.sh`](../bridge-run.sh): tmux 세션 내부 루프/런처
- [`bridge-task.sh`](../bridge-task.sh): queue wrapper
- [`bridge-send.sh`](../bridge-send.sh): urgent direct send
- [`bridge-action.sh`](../bridge-action.sh): predefined action send
- [`bridge-daemon.sh`](../bridge-daemon.sh): background orchestration loop
- [`bridge-sync.sh`](../bridge-sync.sh): live roster/state sync
- [`bridge-status.sh`](../bridge-status.sh): dashboard 출력
- [`bridge-upgrade.sh`](../bridge-upgrade.sh): live install 업그레이드
- [`bridge-handoff-daemon.sh`](../bridge-handoff-daemon.sh): A2A cross-bridge handoff lifecycle (수신 데몬 + 송신 delivery-runner)

### `lib/` 모듈

공통 shell 구현은 [`lib/`](../lib)에 분리되어 있다.

- `bridge-core.sh`: 공통 helper, path/hash/util
- `bridge-agents.sh`: roster accessor, agent lookup, worktree helper
- `bridge-tmux.sh`: tmux 세션 조작과 prompt/submit 처리
- `bridge-state.sh`: roster load, dynamic/static state persistence
- `bridge-cron.sh`: cron inventory, enqueue manifest helper
- `bridge-skills.sh`: project skill bootstrap/sync
- `bridge-hooks.sh`: Claude hook 관련 helper
- `bridge-a2a.sh`: A2A 수신 데몬 + delivery-runner lifecycle helper (`bridge-handoff-daemon.sh`가 source)

새 로직을 추가할 때는 루트 스크립트에 큰 함수를 쌓기보다 `lib/`로 내리는 편이
맞다.

### Python 보조 스크립트

Python은 보조 역할이다. 대표적으로:

- [`bridge-queue.py`](../bridge-queue.py): SQLite queue backend
- [`bridge-cron.py`](../bridge-cron.py): cron inventory/metadata
- [`bridge-handoffd.py`](../bridge-handoffd.py): A2A 수신 데몬 — tailnet-bound HTTP listener, HMAC 검증 후 `bridge-task.sh create` 경유 enqueue
- [`bridge-a2a.py`](../bridge-a2a.py): A2A CLI (`send`/`outbox`/`inbox-dedupe`/`peers`/`deliver`) — `agb a2a ...`로 호출
- [`bridge_a2a_common.py`](../bridge_a2a_common.py): A2A 공통 모듈 — wire protocol, HMAC 서명, data-only JSON config loader, outbox/inbox SQLite 스키마
- `bridge-*.py` 일부: docs, release, audit, guard, intake, dashboard 등

핵심 orchestration은 Bash 중심이지만, structured state 처리나 JSON/SQLite 작업은
Python으로 빠지는 패턴이 많다.

## 5. 신규 개발자가 자주 건드리게 되는 영역

### 1. queue / daemon / status

가장 중요한 흐름은 이 세 축이다.

- queue에 task 생성
- daemon이 live 상태를 보고 nudge/restart/health 판단
- status/dashboard가 이를 요약

이 셋은 서로 강하게 연결되어 있으므로, 하나를 바꾸면 나머지 관찰면도 같이
확인해야 한다.

**Daemon supervision contract (#1563, v0.16.0-rc1).** daemon은 이제 **crash-only /
self-supervising**이다 — in-place self-heal 대신, 진행이 막히면 *abort*하고 OS init이
fresh daemon을 띄운다. 코드 위치와 불변식:

- **T1 (runner-process self-abort)** — `lib/bridge-daemon-control.sh`의
  `bridge_daemon_run_tick_supervised`. 각 tick을 자기 process group의 child로 돌리고,
  in-tick progress heartbeat(`bridge_daemon_tick_progress_touch`)가 `(max-step-budget
  + grace)`(= `bridge_daemon_tick_deadline_seconds`) 동안 갱신되지 않으면 wedge로 보고
  child의 process group을 kill → `daemon_tick_deadline_exceeded` audit + rc 99로 exit.
  **healthy long step은 절대 abort되지 않는다** — deadline은 *가장 긴 bounded step*에서
  파생되므로(`bridge_with_timeout` ceiling을 올리면 deadline도 자동으로 넓어진다) 고정값/
  nudge-latency 숫자로 되돌리지 말 것. flapping-monitor irony가 이 설계의 #1 리스크다.
- **T0 (OS init restart)** — launchd `KeepAlive` / systemd `Restart=always`
  (`scripts/install-daemon-{launchagent,systemd}.sh`), `--watchdog`로 `Type=notify` +
  `WatchdogSec` outer ring(T1 deadline보다 크게 sizing).
- **singleton** — `bridge_daemon_ensure_singleton`. 정확히 하나의 holder + owner record;
  loser는 clean exit하고 live holder를 **절대 evict하지 않는다**. recycled pid(같은 번호,
  다른 `ps -o lstart=`)는 signal 없이 reclaim — start-time proof를 약화시키지 말 것.
- **escalate, don't self-heal** — `bridge-daemon.sh`의
  `bridge_daemon_admin_liveness_class` / `process_daemon_admin_liveness_escalation` /
  `bridge_daemon_mcp_giveup_escalate_admin`. admin이 down이면 admin을 재시작하지 않고
  codex pair로 durable task를 escalate. busy/long-turn admin은 절대 down으로 분류하지 말 것.
- **A2A receiver supervision** — `process_a2a_receiver_supervise_tick` +
  `lib/bridge-a2a.sh`(backoff/breaker decision) + `lib/daemon-helpers/a2a-receiver-exit-cause.py`
  (transient vs auth_config 분류). transient bind blip은 exponential backoff + circuit
  breaker, auth/config 에러는 즉시 hold. fail-closed bind/HMAC 경계는 **건드리지 말 것** —
  이건 supervision-policy 레이어일 뿐이다.

통합 false-positive 회귀는 `scripts/smoke/1563-pr5-fp-control-matrix.sh`(7-row 매트릭스 +
teeth)가, 각 메커니즘은 `1563-daemon-singleton` / `1563-pr2`(T1) / `1563-pr3`(escalation) /
`1563-pr4`(A2A) smoke가 핀으로 박는다. OPERATIONS.md §"Daemon supervision (#1563)"에 운영자용
env 노브 표가 있다.

**Stop/turn-end inbox auto-drain (#9780).** turn 종료 시 `hooks/inbox-auto-drain.py`
(Stop hook)가 idle 대신 genuinely-claimable queued task를 하나 drain한다. id+status marker +
atomic-persist-before-block의 fail-open 무한루프 가드가 있고, #1199 queued-vs-claimed 분리를
보존한다 — 이 가드를 약화시키면 turn-end 루프가 생긴다.

### 2. tmux I/O

`bridge-tmux.sh`는 deceptively simple해 보여도 실패 시 영향이 크다.

주의할 점:

- Claude와 Codex는 submit 방식이 다르다
- urgent send는 prompt state에 민감하다
- trust prompt, blocker state, copy-mode 같은 예외 상태가 있다
- tmux option 변경은 operator 체감 품질에 바로 반영된다
- `NEXT-SESSION.md` handoff는 SessionStart hook(`hooks/bridge_hook_common.py`의
  `bootstrap_artifact_context`)으로만 전달된다. `bridge-run.sh`에서 tmux
  send-keys로 동일 메시지를 재주입하던 경로(`bridge_run_schedule_next_session_prompt`)는
  제거됐다 — 재도입하지 말 것
- daemon이 tmux로 밀어넣는 외부 푸시는 **metadata-only**다 (`[Agent Bridge] event=... count=... top=... title=... from=...`). 실행 동사를 인젝션에 포함시키는 옛 포맷을 되살리지 말 것. 수신 에이전트가 해석·디스패치·검증하는 계약은 `docs/agent-runtime/common-instructions.md`의 "External Push Handling" 섹션과 `runtime-templates/skills/external-push-handling/SKILL.md`에 있다.

### 3. upgrade / deploy

업그레이드는 단순 덮어쓰기가 아니다.

지켜야 할 것:

- live runtime의 local data를 보존해야 한다
- tracked source만 복사해야 한다
- `state/`, `logs/`, `shared/`, local roster, live agent homes는 보존 대상이다
- source checkout 경로가 달라도 upgrade가 source를 찾을 수 있어야 한다

최근처럼 source checkout이 `~/agent-bridge-public`에서
`~/Projects/agent-bridge-public`로 바뀌는 경우도 고려해야 한다.

### 4. worktree isolation

동일 git repo를 여러 에이전트가 동시에 수정하는 흐름은 중요한 기능이다.

관련 포인트:

- `agent-bridge --prefer new`
- managed worktree metadata는 `state/worktrees/`
- 실제 worktree는 `~/.agent-bridge/worktrees/<repo-slug>/<agent>`

여기서 잘못 건드리면 공유 repo를 오염시키거나, 잘못된 branch/workdir로 실행될 수
있다.

### 5. Claude hook / tool policy / prompt guard

보안이나 containment 레이어를 건드릴 때는 특히 주의해야 한다.

- hook 설정은 Claude settings/shared settings와 연결된다
- tool policy는 다른 agent home, `agent-roster.local.sh`, `state/tasks.db` 접근을 제한한다
- prompt guard는 optional이며 완전한 sandbox가 아니다

이 레이어는 "보안 제품"이 아니라 shared-user runtime의 containment/audit layer다.

**Identity materialization invariant (#10370).** v2 layout에서 authored identity와
runtime workdir copy는 의도적으로 분리되어 있다. create/start 경로는 HOME/source의
identity 파일을 workdir read-target으로 **copy-on-materialize** 하며, reader를 HOME으로
뒤집지 않는다. `bridge-upgrade.py migrate-agents`가 CLAUDE/AGENTS managed block 같은
canon을 갱신한 뒤에는 `lib/upgrade-helpers/rematerialize-agent-identity.sh`가 같은
fileset을 workdir에 다시 materialize한다. 이 upgrade-time 경로는 maintenance event라
sync-on-start의 mtime guard를 쓰지 않는다. 대신 dry-run JSON에 planned workdir paths를
내보내 backup planner가 apply 전에 기존 workdir copy를 잡게 하고, shared-cwd pair에서는
target identity가 다른 agent 소유이면 `shared_workspace`로 skip한다. iso v2 workdir write는
항상 `bridge_isolation_write_file_as_agent_user_via_bash` + per-file `0660` normalize를
통한다.

**Settings single-tree invariant (#1455).** effective settings 파일은 에이전트당
**정확히 한 곳**(`home/.claude/settings.effective.json`)에만 실재해야 하고, 나머지
(특히 `workdir/.claude/settings.json`)는 그 파일을 가리키는 **상대 symlink**여야 한다 —
두 개의 real copy는 조용히 drift하고, `enabledPlugins`가 preserved-user key라 stale
값이 재시작에도 살아남는다(이게 #1453의 root cause다). 새 settings tree를 만들 때는
직접 copy하지 말고 `link-shared-settings`(`bridge-hooks.py`) +
`bridge_ensure_claude_shared_settings_for_managed_workdir`(`lib/bridge-hooks.sh`)를
재사용한다. `bridge-doctor.py`의 `settings-two-tree-drift` /
`settings-multi-tree` detector가 위반을 read-only로 surface한다.
앞으로 만들 **dynamic → static promotion**(home tree를 처음 materialize하는 시점,
follow-up #1555)은 이 invariant를 day-one부터 지켜야 한다. 전체 계약은
[`settings-single-tree-invariant.md`](./settings-single-tree-invariant.md) 참고.

### 6. cron with reporting

cron은 disposable child가 부모 에이전트(target_agent)에게 inbox-only로 보고하는 contract다. PR1+PR2가 정의한 인터페이스의 핵심:

- 모든 cron child의 result는 `delivery_intent ∈ {silent, main_session_only, forward_to_user}`을 declare해야 한다 — `bridge-cron-runner.RESULT_SCHEMA`가 schema 강제.
- 부모는 `lib/bridge_cron_followup.parse_followup(body_text)`로 inbox task body의 frontmatter를 파싱하고, 결과 dict의 `delivery_intent`로 absorb / forward / no-op을 결정한다. 자세한 알고리즘은 [`docs/agent-runtime/common-instructions.md` §"Cron Followup Handling"](agent-runtime/common-instructions.md#cron-followup-handling).

새 cron을 추가할 때 reporting을 어떻게 다룰지 결정하는 경로:

기본 동작 — 결정은 child LLM이 매 run마다 결정 (default-silent on no signal):

```bash
agb cron create --agent <target> --schedule "0 9 * * *" --title "monitor-X" \
  --payload "<몸통은 cron-runner의 PR1 prompt preamble이 자동 주입>"
```

per-job override (`metadata.cronReportingPolicy` / `metadata.cronUrgency`)는 PR2 시점에 `agb cron create` CLI flag로 노출되어 있지 않다. 두 가지 supported path:

**(a) 직접 jobs.json 편집** — 가장 직관적. `agb cron create`로 job을 만든 다음, `~/.agent-bridge/cron/jobs.json` (= `$BRIDGE_NATIVE_CRON_JOBS_FILE`, 기본값 `$BRIDGE_HOME/cron/jobs.json`) 을 열어 해당 job의 `metadata` 객체에 키를 추가:

```json
{
  "id": "heartbeat-rss-abcd",
  "name": "heartbeat-rss",
  "agentId": "agb-dev-claude",
  "schedule": {"kind": "cron", "expr": "*/15 * * * *", "tz": "UTC"},
  "payload": {"kind": "text", "text": "..."},
  "metadata": {
    "cronReportingPolicy": "always_main_session",
    "cronUrgency": "urgent"
  },
  "state": { ... }
}
```

다음 cron tick부터 자동 적용된다. daemon restart 불필요.

**(b) source jobs file로 import** — 여러 job을 한 번에 metadata 포함해서 등록할 때:

```bash
cat > /tmp/jobs.json <<'EOF'
{"format":"agent-bridge-cron-v1","jobs":[
  {"id":"hb","name":"heartbeat-rss","agentId":"<target>","enabled":true,
   "schedule":{"kind":"cron","expr":"*/15 * * * *","tz":"UTC"},
   "payload":{"kind":"text","text":"check feed"},
   "metadata":{"cronReportingPolicy":"always_main_session","cronUrgency":"urgent"}}
]}
EOF
agb cron import --source-jobs-file /tmp/jobs.json --dry-run   # 먼저 dry-run으로 결과 확인
agb cron import --source-jobs-file /tmp/jobs.json
```

허용 값:

- `cronReportingPolicy`: `default | always_main_session | always_silent` (Sean Q-B 2026-05-02). 다른 값은 runner에서 `default`로 fallback.
- `cronUrgency`: `normal | high | urgent`. default `normal`.

(`agb cron create --metadata key=value` flag는 후속 follow-up PR으로 검토 중. PR2는 doc + helper만 다루고 CLI surface는 확장하지 않음.)

운영 중 디버깅 — `agb cron show <job>`이 직접 마지막 run의 trio를 보여준다:

```bash
agb cron show <job>
# ...
# last_status: success
# last_reporting_decision: reported     # silent | reported | invalid
# last_delivery_intent: main_session_only
# last_inbox_task_id: 12345             # parent의 inbox에서 이 id로 찾을 수 있음
```

`--format json` / `--format shell` 출력에도 같은 trio가 들어간다 (`CRON_JOB_LAST_REPORTING_DECISION`, `CRON_JOB_LAST_DELIVERY_INTENT`, `CRON_JOB_LAST_INBOX_TASK_ID`). 자세한 schema와 dedupe semantics, daemon gate 동작은 [`ARCHITECTURE.md` "Cron reporting contract"](../ARCHITECTURE.md#cron-reporting-contract).

PR1+PR2 분리에서 자주 헷갈리는 지점:

- runner는 silent 또는 schema-required-fail (`reporting_decision = invalid`) 시 inbox task를 **만들지 않는다**. 따라서 부모가 `[cron-followup]`을 받았다는 것 자체가 "non-silent intent로 결정됐고 schema가 통과했다"는 뜻이다.
- 부모는 frontmatter parser가 `None`을 돌려도 죽지 않고 legacy prose handling으로 fallback한다 — PR1 이전 cron이나 손으로 만든 task를 위함이다.
- daemon은 `reporting_decision`이 `silent` 또는 `reported`면 자기 followup 경로를 **suppress**하고, `invalid` 또는 빈 값이면 기존 failure-followup 경로를 그대로 돌린다. 즉 schema-required-fail은 반드시 사람에게 surface된다.

### 7. footgun #11 — heredoc-stdin in a capture wedges bash 5.3.9

Bash 5.3.9 contains a `read_comsub` / `heredoc_write` deadlock chain: any
heredoc-fed subprocess whose stdout is being captured by a parent (via
`$()`, backticks, or a pipe feeding `$()`) can wedge for hours. The same
syntactic shape caused outages in v0.13.7, v0.13.8, v0.13.9, PR #940,
PR #943, and queue task #4807.

The anti-pattern, in any of these surfaces, is dangerous:

```bash
# C1 — heredoc-fed interpreter inside a capture wrapper:
out="$(python3 - "$arg" <<'PY'
... body ...
PY
)"

# C2 — cat <<EOF inside a capture wrapper:
content="$(cat <<EOF
... body ...
EOF
)"

# C4 — bash -s heredoc, no capture but same deadlock class:
bash -s -- "$arg" <<'EOF'
... body ...
EOF
```

The recommended replacement is **file-as-argv**: spool the body to a tempfile
or extract it to a standalone helper script invoked with `sys.argv`.

```bash
# Helper extracted to lib/upgrade-helpers/foo.py — called with argv only:
out="$(python3 "$REPO_ROOT/lib/upgrade-helpers/foo.py" "$arg")"

# Or in-line: spool the body to a tempfile, then exec the interpreter:
tmpscript="$(mktemp)"
cat >"$tmpscript" <<'PY'
... body ...
PY
out="$(python3 "$tmpscript" "$arg")"
rm -f "$tmpscript"
```

Two artifacts guard against regression:

- `scripts/audit-footgun-11.sh` enumerates every heredoc-stdin site in
  tracked shell sources, categorizes it (C1/C2/C3/C4/H3/SAFE), and emits
  TSV or JSON for grep-friendly review.
- `scripts/lint-heredoc-ban.sh --baseline-check` ratchets against
  `.lint-heredoc-baseline.tsv` and fails CI on any new site whose snippet
  hash is not in the baseline. Adding an intentional exception requires
  running `--baseline-update` and hand-filling the `reason / owner /
  expires_or_phase` columns in the same PR — silent acceptance is
  prohibited.

The `lint-heredoc-ban` GitHub Actions job is required on `pull_request`.
The existing per-file ceiling lint (`scripts/lint-heredoc-ban.sh` legacy
mode, invoked from `scripts/oss-preflight.sh`) is preserved for
back-compat and remains the floor for `bridge-upgrade.sh` and
`bridge-agent.sh` specifically.

### 8. controller→iso boundary — `bridge_iso_run` (v0.14.5-beta23+)

Every controller→isolated-agent boundary read, write, mkdir, stat, and
root-publish operation now goes through the unified `bridge_iso_run`
facade in `lib/bridge-isolation-helpers.sh`. Two execution classes
share the same entrypoint:

1. **agent op** — drops to the isolated UID via existing passwordless
   sudoers; used for read/stat/mkdir/atomic-write/state-marker/
   scan-profile of agent-owned runtime files.
2. **root-publish op** — controller-published writes for root-owned
   per-agent metadata (`installed_plugins.json`,
   `known_marketplaces.json`). Strict path allowlist + final
   owner/group/mode enforcement. The iso UID must NOT be able to
   rewrite its own plugin allowlist (security boundary).

Shell signature:

```
bridge_iso_run --agent <agent> --op <op> [op-args]
```

Op catalog: `stat`, `read-file`, `read-json`, `env-has-any-key`,
`read-env-key`, `mkdir-p`, `atomic-write`, `rename`,
`state-marker-write`, `scan-profile`, `publish-root-file`,
`publish-root-symlink`. Full header in
`lib/bridge-isolation-helpers.sh`.

Structured return codes:

- `0` success
- `10` agent not linux-user isolated (caller used `--legacy-ok`)
- `20` sudo unavailable / passwordless sudoers missing
- `30` path absent
- `31` semantic missing key (`env-has-any-key`)
- `32` unreadable even to the isolated UID
- `40` unsafe path (not under allowlisted per-agent root)

Python callers use the thin adapter
`lib/bridge_iso_paths.py:iso_run(agent, op, ...)` which shells out to
`agent-bridge iso-run` and inherits the same op catalog + rc band.

**Path allowlist** (lexical prefix, supports not-yet-created paths):

- `bridge_agent_workdir <agent>`
- `bridge_agent_default_home <agent>`
- `bridge_agent_linux_user_home <os_user-for-agent>` (when isolated)
- `bridge_agent_idle_marker_dir <agent>`
- `BRIDGE_ISO_RUN_ALLOWLIST_EXTRA` (colon-separated; smoke tests and
  rare overrides only — never set in production)

Unknown roots → `rc 40`.

**Footgun #11 compliance**: the helper body uses pipe-only stdin to
the `sudo -n -u <os_user> bash -c '<inline-script>'` chain. NO
heredoc-stdin, NO `<<<` here-string, NO `done < <(...)` capture in
any op script. Callers that stream payloads (`atomic-write`,
`state-marker-write`, `publish-root-file`) must use a producer
pipeline (`printf '%s\n' "$body" | bridge_iso_run --stdin ...`).

**Ratchet**: `scripts/iso-helper-ratchet.sh` scans tracked source for
boundary callsites and enforces baseline-by-count regression gate.
Baseline at `scripts/baselines/iso-helper-baseline.txt`; whole-file
allowlist at `scripts/baselines/iso-helper-allowlist.txt`. Sister to
`scripts/lint-raw-pathlib-on-isolated.sh` and
`scripts/lint-heredoc-ban.sh`. To intentionally migrate a site:
update the code, run `--update-baseline`, commit the reduced
baseline in the same PR.

**Smoke**: `scripts/iso-helper-smoke.sh` exercises 20 unit checks
against the non-isolated direct codepath. The isolated path requires
a real provisioned `agent-bridge-<slug>` linux-user + sudoers entry
and is covered by the live-install acceptance matrix.

The compatibility wrappers
`bridge_isolation_run_as_agent_user_via_bash` and
`bridge_isolation_write_file_as_agent_user_via_bash` remain in
`lib/bridge-isolation-helpers.sh` and are internally consumed by
`bridge_iso_run`; legacy callers may still call them directly.

The pre-existing root-publish writers
(`bridge_write_isolated_known_marketplaces_catalog`,
`bridge_write_isolated_installed_plugins_manifest`) ARE the
compatibility wrappers for the `--op publish-root-file` boundary
(security-critical chown/chgrp/chmod/mv chain); they implement the
same contract internally and remain in place because their
catalog-filtering work is non-trivial. New callsites that need a
root-published per-agent manifest write should call `bridge_iso_run`.

### 9. template-sync — reference 에이전트에서 새 에이전트 시드 (issue #1427)

`agb setup template-sync`는 한 reference 에이전트(보통 `patch`)의 roster
필드를 가져와 이후 생성되는 새 에이전트(그리고 명시적으로 backfill 하는
기존 에이전트)의 model/effort/permission_mode/plugins/skills/channels를
시드한다. 설계 전문은 [`docs/template-sync-design.md`](./template-sync-design.md)
에 있다 — 새 에이전트가 fresh Claude Code처럼 Sonnet/low-effort/no-plugin으로
올라오는 문제를 opt-in 위저드로 해결한다.

이 영역을 만질 때 반드시 기억할 두 가지 함정:

- **Sync 대상은 ROSTER이지 `settings.json`이 아니다.** model/effort/
  permission_mode는 `bridge_build_static_launch_cmd`
  (lib/bridge-state.sh:53-75)가 roster에서 읽어 launch argv로 넘기는
  값이다. `settings.json`에 model을 써도 launch flag가 이기므로 no-op이다.
  동기화는 항상 `agent-roster.local.sh`의 명시적 per-agent 필드를 쓴다.
- **Materialize-not-fallback.** `setup template-sync`가 쓰는
  defaults-profile 블록은 create/backfill 시점에만 소비되어 명시적 필드를
  **물질화(materialize)** 한다. 접근자(`bridge_agent_model/effort/...`)가
  global default를 반환하도록 바꾸면 안 된다 — 그렇게 하면 필드 미설정
  상태로 legacy-launch 계약에 있던 모든 기존 roster가 조용히 새 launch
  shape로 뒤집힌다. 우선순위: 명시적 per-agent 필드 > 물질화된 defaults
  (= create/backfill 후의 명시적 필드) > 빌트인 inline launch default
  (`claude-opus-4-8` / xhigh / auto, new-shape 행 한정, 최후 수단).

보안 불변식 (설계 doc §"Hard security invariants"):

- secret은 절대 복사하지 않는다 — MCP/plugin secret, `.mcp.json` env,
  `.teams`/`.ms365`/`.env`/`access.json`, refresh token, app password,
  client secret. **이름/스키마만** 동기화하고 운영자가 per-channel `setup`
  위저드로 재투입한다. channels는 선언(`plugin:teams@mkt`)만 운반한다.
- `permission_mode=legacy`는 절대 자동 전파하지 않는다.
- silent model upgrade 없음 — dry-run / before-after diff + 운영자 확인.
  기존 에이전트는 명시적 backfill 전까지 건드리지 않는다.
- reference 읽기는 **roster-only**. patch의 live `$HOME/.claude`, 설치된
  plugin 캐시, settings, env, MCP 런타임을 introspect 하지 않는다
  (isolation으로도 막혀 있다).

defaults-profile 블록의 정확한 포맷(Contract I)은 설계 doc
§"Shared contracts (I)"가 pin이며, 같은 포맷의 copy-pasteable 예시가
`agent-roster.local.example.sh` 주석에 있다 (excluded 차원은 빈 var가 아니라
아예 생략된다). 빌트인 last-resort
launch default는 이 작업과 함께 `claude-opus-4-7`에서 `claude-opus-4-8`로
갱신됐다(lib/bridge-state.sh:68); 기존 명시적 roster 항목은 건드리지 않는
adjacent 변경이며 dry-run에 노출된다.

## 6. 개발할 때의 기본 작업 흐름

### 상태 파악

먼저 할 것:

```bash
git status --short
./agent-bridge status
./agent-bridge list
```

live runtime에서 작업 중이라면:

```bash
bash bridge-daemon.sh status
cat state/active-roster.md
```

### 정적 역할 확인

정적 role 관련 수정이면:

```bash
bash bridge-start.sh --list
bash bridge-start.sh tester --dry-run
```

### 동적 에이전트 흐름 확인

동적 agent 관련 수정이면:

```bash
./agent-bridge --codex --name smoke --workdir /tmp/demo --no-attach
./agent-bridge worktree list
```

### queue 동작 확인

```bash
bash bridge-task.sh create --to tester --title "retest" --body "check"
./agent-bridge inbox tester
./agent-bridge claim 1 --agent tester
./agent-bridge done 1 --agent tester --note "ok"
```

### daemon 관련 확인

```bash
bash bridge-daemon.sh sync
bash bridge-daemon.sh status
```

## 7. 테스트 기대치

이 프로젝트에는 전통적인 unit test suite보다 smoke/manual 검증 비중이 높다.

최소 기대치:

```bash
bash -n *.sh agent-bridge agb lib/*.sh scripts/*.sh
shellcheck *.sh agent-bridge agb lib/*.sh scripts/*.sh agent-roster.local.example.sh
./scripts/smoke-test.sh
```

여기에 추가로 권장되는 것:

- 수정한 스크립트의 `--dry-run` 경로 1개 이상 확인
- `bash bridge-daemon.sh sync` 1회 확인
- heartbeat/tmux 관련 변경이면 isolated `BRIDGE_HOME`에서 직접 확인

### smoke test의 한계

`scripts/smoke-test.sh`는 중요하지만 완전하지 않다.

검증하는 것:

- shell syntax
- isolated daemon startup
- static role launch
- queue create/claim/done
- status/list/summary/sync의 대표 경로

검증하지 못하는 것:

- 실제 Claude CLI의 모든 상호작용
- 실제 Codex CLI의 모든 상호작용
- 실제 model-side resume semantics

즉, tmux submit/path, hook, prompt state 변경은 live-like 수동 검증이 필요하다.

## 8. 새 개발자가 가장 많이 실수하는 지점

### 1. 운영 런타임을 source tree처럼 다룸

`~/.agent-bridge`는 배포 대상이지, git source checkout이 아니다.
live runtime에 들어 있는 상태를 보고 repo에 그대로 복붙하면 오염될 가능성이 높다.

### 2. private 운영 습관을 public template에 집어넣음

이 repo는 public snapshot이다.

피해야 할 것:

- 특정 회사/팀의 private naming
- private workflow를 SSOT처럼 박아 넣기
- 공개하기 어려운 사람/도구/데이터 구조를 일반 기능처럼 넣기

### 3. queue 대신 direct send를 중심 흐름으로 바꿈

direct send는 빠르지만 durable하지 않다.
대부분의 협업은 queue가 기준이어야 한다.

### 4. upgrade를 단순 복사 문제로 오해함

upgrade는 "tracked source를 live install에 안전하게 반영"하는 문제다.
runtime 보존이 핵심이므로, 파일 복사 최적화보다 보존 규칙이 우선이다.

### 5. macOS 기본 Bash를 가정함

macOS 기본 Bash는 3.2다.
이 프로젝트는 associative array를 쓰므로 Bash 4+가 필요하다.

### 6. shell integration이 한 번 설치되면 영원히 안전하다고 생각함

source checkout을 직접 source하는 방식으로 shell integration을 설치한 경우,
repo 경로가 바뀌면 rc 파일의 managed block도 갱신되어야 한다.

현재는 `scripts/install-shell-integration.sh --apply`가 기존 managed block을
업데이트하도록 되어 있다.

## 9. 경로와 환경변수 관련 메모

중요한 환경변수:

- `BRIDGE_HOME`
- `BRIDGE_ROSTER_FILE`
- `BRIDGE_ROSTER_LOCAL_FILE`
- `BRIDGE_STATE_DIR`
- `BRIDGE_TASK_DB`
- `BRIDGE_WORKTREE_ROOT`
- `BRIDGE_CRON_STATE_DIR`
- `AGENT_BRIDGE_SOURCE_DIR`

특히 `AGENT_BRIDGE_SOURCE_DIR`는 source checkout이 표준 위치
`~/.agent-bridge-source`가 아닐 때 중요하다.

예:

- source checkout을 `~/Projects/agent-bridge-public`에 둔 경우
- live runtime에서 `agent-bridge upgrade`가 source를 자동 추론해야 하는 경우

## 10. 문서/코드 수정 시 권장 원칙

- 작은 변경으로 끝낼 수 있으면 큰 리팩터링을 하지 않는다
- root script보다 `lib/bridge-*.sh` helper 추가를 우선 검토한다
- queue semantics, roster loading, session resume, worktree handling 변경은 별도 검증 메모를 남긴다
- live runtime 보존 규칙을 깨는 변경은 매우 신중하게 다룬다
- README 설치 절차는 Claude installer flow와 연결되어 있으므로 함부로 바꾸지 않는다
- 문서와 실제 동작이 어긋나면 코드만 고치지 말고 문서도 함께 고친다

## 11. 작업 시작 전 체크리스트

1. `git status`로 현재 변경 상태 확인
2. 어떤 레이어를 만지는지 결정
3. live runtime 보존/queue-first 원칙에 영향이 있는지 판단
4. 변경할 파일과 검증 계획을 먼저 잡기
5. 관련 문서와 smoke/manual 검증 범위를 정하기

## 12. 작업 종료 전 체크리스트

1. syntax check
2. smoke test 또는 최소 검증 실행
3. 변경이 queue/daemon/tmux/upgrade/worktree에 미치는 영향 요약
4. 문서 업데이트 필요 여부 확인
5. operator나 다음 개발자가 바로 이어받을 수 있게 검증 결과 정리

## 13. 한 문장으로 요약

이 프로젝트에서 가장 중요한 것은 "에이전트 실행 자체"가 아니라, 여러
Claude/Codex 세션이 로컬에서 durable하고 예측 가능하게 협업하도록 만드는
얇은 glue layer를 안전하게 유지하는 것이다.
