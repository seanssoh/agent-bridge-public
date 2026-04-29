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

machine-local 값은 `agent-roster.local.sh` 같은 local runtime 쪽에 둔다.

### generated/runtime artifact를 source처럼 수정하지 않는다

개발 중 직접 수정하면 안 되는 대상:

- `state/`
- `logs/`
- live runtime의 `shared/`
- 운영 중 생성된 `agents/<name>` runtime home

이 프로젝트에서 수정해야 하는 대상은 대체로 tracked script, tracked docs,
tracked templates다.

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

### `lib/` 모듈

공통 shell 구현은 [`lib/`](../lib)에 분리되어 있다.

- `bridge-core.sh`: 공통 helper, path/hash/util
- `bridge-agents.sh`: roster accessor, agent lookup, worktree helper
- `bridge-tmux.sh`: tmux 세션 조작과 prompt/submit 처리
- `bridge-state.sh`: roster load, dynamic/static state persistence
- `bridge-cron.sh`: cron inventory, enqueue manifest helper
- `bridge-skills.sh`: project skill bootstrap/sync
- `bridge-hooks.sh`: Claude hook 관련 helper

새 로직을 추가할 때는 루트 스크립트에 큰 함수를 쌓기보다 `lib/`로 내리는 편이
맞다.

### Python 보조 스크립트

Python은 보조 역할이다. 대표적으로:

- [`bridge-queue.py`](../bridge-queue.py): SQLite queue backend
- [`bridge-cron.py`](../bridge-cron.py): cron inventory/metadata
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
