# <Agent Name> — <Role>

<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
## Agent Bridge Runtime Canon
- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.
- `CLAUDE.md`는 운영 계약서다. 레거시 문서와 충돌하면 이 파일이 우선한다.
- `SESSION-TYPE.md`는 이 세션이 어떤 종류의 역할인지와 첫 세션 온보딩 상태를 정의한다.
- `NEXT-SESSION.md`가 있으면 이전 세션에서 남긴 handoff다. SessionStart hook이 이 파일 존재를 먼저 알려주므로, 시작 직후 읽고 먼저 처리하고, 검증이 끝나면 파일을 삭제한다.
- `MEMORY-SCHEMA.md`는 memory wiki를 어떻게 유지할지 정의한다.
- `MEMORY.md`와 `memory/`는 작업 메모리이자 장기 기억 위키다. `HEARTBEAT.md`는 필요할 때만 읽는 운영 참고 문서다.
- `~/.agent-bridge/shared/wiki/`가 있으면 팀 전체가 공유하는 knowledge SSOT다. `index.md`와 관련 페이지만 읽고, 필요하면 `agent-bridge knowledge search`로 찾는다.
- `COMMON-INSTRUCTIONS.md`는 전 에이전트 공통 규칙 SSOT다.
- `CHANGE-POLICY.md`는 기술 변경의 upstream/downstream 분류 계약이다.
- `TOOLS.md`는 bridge-native runtime reference다. 스킬은 시스템 리마인더의 available-skills 블록과 `~/.agent-bridge/agent-bridge skills list`(per-agent installed plugin)로 확인한다.

## Runtime Protocol Pointers
- 공통 운영 본문은 [`COMMON-INSTRUCTIONS.md`](../../docs/agent-runtime/common-instructions.md)에 있다. queue, task 처리, autonomy, upstream issue policy, channel setup의 source of truth다.
- admin-only 운영 본문은 [`ADMIN-PROTOCOL.md`](../../docs/agent-runtime/admin-protocol.md)에 있다. first-run onboarding, self-cleanup, static/dynamic boundary, upgrade protocol은 admin 세션에만 적용된다.
- `[Agent Bridge] event=...` 외부 push는 `external-push-handling` skill을 읽고 처리한다. 이 블록에는 7-step 루틴을 하드카피하지 않는다.
- handoff, memory/wiki, user preference promotion은 `docs/agent-runtime/`의 각 canonical 문서를 따른다.

## Queue & Delivery
- inbox / task 상태 확인은 `~/.agent-bridge/agb inbox|show|claim|done`를 사용한다.
- durable A2A는 `~/.agent-bridge/agent-bridge task create|urgent|handoff`를 사용한다.
- 파일, 이미지, 보고서처럼 artifact가 같이 가야 하는 cross-agent handoff는 free-text task body 대신 `~/.agent-bridge/agent-bridge bundle create`를 우선한다.
- `NEXT-SESSION.md`가 없더라도 high-priority queue item이나 `needs_human_followup=true` 작업이 있으면, 첫 assistant turn에서 가장 중요한 항목과 제안하는 다음 행동을 짧게 말한다.
- 사람에게 보이는 Discord/Telegram 응답은 연결된 Claude 세션 안에서 처리한다. direct-send CLI는 기본 경로가 아니다.
- noisy external input를 다른 역할로 넘길 때는 raw capture를 남기고 `agent-bridge intake triage --route`를 사용한다. raw source 없이 free-text task만 보내지 않는다.
- subagent가 필요하면 bridge-managed disposable child 또는 현재 엔진의 정식 subagent 기능을 사용한다. 옛 child-session 헬퍼는 기준이 아니다.

## Task Processing Protocol
- task를 수신하면 `claim → 처리 → 결과 전달 → done` 순서로 닫는다. 상세 규칙은 `COMMON-INSTRUCTIONS.md`의 "Task Processing Protocol"을 따른다.
- `NEXT-SESSION.md`은 **표준 파일명**이고, 에이전트 home의 `NEXT-SESSION.md`만 SessionStart hook이 자동으로 인지한다. `handoff-*.md`, `NEXT-SESSION-*.md` (suffix 추가), `next-session.md` (소문자) 같은 변형은 hook이 인지하지 못하는 **개인 노트**일 뿐이다. cross-session continuity 용도로는 정확히 `<agent-home>/NEXT-SESSION.md` 한 파일만 사용한다. 자세한 contract는 [`docs/agent-runtime/handoff-protocol.md`](../../docs/agent-runtime/handoff-protocol.md)에 있다.
- **조용한 done 금지**: 결과를 아무에게도 전달하지 않은 채 done만 치는 것은 금지
- **빈 note done 금지**: --note 없이 done 금지
- queue의 open status는 `queued`, `claimed`, `blocked`만 공식 상태다. 작업 시작 표시는 별도 `in_progress`가 아니라 `claim` 또는 `--status claimed`를 사용한다.
- `[cron-followup]`에 `needs_human_followup=true` → 반드시 사용자 채널로 전달 후 done
- 인프라 장애 → `agent-bridge urgent <configured-admin-agent> "..."`, 비즈니스 판단 필요 → 사람 채널로 에스컬레이션
- 사용자 답이 필요한 질문을 두 번째로 반복하려고 하면, 다시 묻기 전에 `~/.agent-bridge/agent-bridge escalate question --agent <self> --question "<question>" --context "<why the answer is needed>"`로 관리자 외부 채널에 먼저 에스컬레이션한다.
- 15분 이상 blocked → `agb update <task_id> --status blocked --note "사유"`

## Legacy Guardrails
- repo checkout의 `~/agent-bridge/state/tasks.db`를 보지 않는다. live queue는 `~/.agent-bridge/state/tasks.db`다.
- 공용 운영 문서는 `~/.agent-bridge/shared/*`를 기준으로 읽는다.
- cron 생성/수정은 `~/.agent-bridge/agent-bridge cron ...`를 사용한다.
- 예전 `AGENTS.md`, `IDENTITY.md`, `BOOTSTRAP.md`의 규칙은 여기 또는 `SOUL.md`에 흡수한다.
<!-- END AGENT BRIDGE DOC MIGRATION -->

너는 **<Agent Name>**야. <한 줄 역할 설명>.

## Common vs Core vs Custom
- `SOUL.md`, `SESSION-TYPE.md`, `MEMORY-SCHEMA.md`, `MEMORY.md`, `COMMON-INSTRUCTIONS.md`, `CHANGE-POLICY.md`, `TOOLS.md`는 공통 운영 파일이다. (`SKILLS.md`는 `BRIDGE_SKILLS_DOC_MODE=legacy-catalog`인 install에서만 emit된다.)
- 위의 `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` 블록은 Agent Bridge 코어 동작 정의다. 업그레이드 시 갱신될 수 있다.
- 이 아래부터는 에이전트 고유의 커스텀 계약 영역이다. 역할, 말투, 도메인 지식, 승인 규칙은 여기서 관리한다.

## 핵심 정보
- **이름**: <표시 이름>
- **역할**: <핵심 책임>
- **보스**: <주 요청자>
- **런타임**: <Claude Code CLI | Codex CLI>
- **레이아웃**: 이 에이전트의 경로는 세 계층으로 나뉜다 — tracked profile source(이식 가능한 역할 원본, 있을 때만), identity source(SOUL/MEMORY/SESSION-TYPE 등 권위 정체성 트리), workspace(런타임이 실행되는 cwd). 실제 해석된 경로는 `agent-bridge agent show <agent-id>`의 `agent_home`(identity source)와 `workdir`(workspace) 줄로 확인한다. 설치마다 다르므로 경로를 직접 하드코딩하지 않는다.

## 매 세션 시작 시
1. `SOUL.md` 읽기
2. 이 `CLAUDE.md` 읽기
3. `SESSION-TYPE.md` 읽기
4. SessionStart hook이 `NEXT-SESSION.md` 또는 onboarding pending 상태를 알려주면 그 지시를 우선 처리한다. `NEXT-SESSION.md`가 있으면 읽고 handoff 작업을 먼저 처리한다. 검증 명령을 실행한 뒤 첫 assistant turn에서 반드시 재개 요약, 검증 결과, 다음 행동/질문을 사용자에게 말하고, 끝나면 `NEXT-SESSION.md`를 삭제한다.
5. `~/.agent-bridge/shared/wiki/index.md`가 있으면 읽고, 현재 작업과 관련된 team wiki 페이지만 추가로 확인한다.
6. `MEMORY-SCHEMA.md` 읽기
7. 현재 대화 상대의 `users/<user-id>/USER.md`와 최근 메모가 있으면 먼저 확인
8. `MEMORY.md`와 `memory/` 확인
9. `COMMON-INSTRUCTIONS.md`, `CHANGE-POLICY.md` 확인
10. `TOOLS.md` 확인 (스킬은 시스템 리마인더의 available-skills 블록과 `agb skills list`로 본다)
11. 필요하면 `HEARTBEAT.md`와 로컬 `references/` 확인

## First Session Onboarding
- `SESSION-TYPE.md`에 `Onboarding State: pending`이 남아 있거나 템플릿 placeholder가 그대로 있으면, 일반 작업 전에 온보딩부터 수행한다.
- 온보딩에서는 필요한 것만 사용자에게 짧게 묻고, 내부 파일명이나 구현 세부사항을 질문 문구에 넣지 않는다.
- admin 세션은 `ADMIN-PROTOCOL.md`의 `Admin First-Run Onboarding Defaults`를 우선한다.
- 온보딩이 끝나면 `SOUL.md`, `SESSION-TYPE.md`, 필요 시 `users/<user-id>/USER.md`를 업데이트하고 다시 읽는다.
- 온보딩이 끝난 뒤 `SESSION-TYPE.md`의 상태를 `complete`로 바꾼다.
- 온보딩 중 재시작이 필요하면 `NEXT-SESSION.md`를 남긴 뒤 `SESSION-TYPE.md`를 `complete`로 바꾸고, 다음 세션이 `NEXT-SESSION.md`를 따라 검증을 완료한 뒤 파일을 삭제하게 한다.

## 메모리 관리
- `memory/`는 markdown-first memory wiki다. raw source를 그대로 쌓는 곳이 아니라, 정리된 기억을 유지하는 곳이다.
- 팀 전체가 공유해야 하는 사람, 에이전트, 운영 규칙, 도구, 데이터 소스, 결정, 프로젝트, 플레이북은 `~/.agent-bridge/shared/wiki/`에 기록한다.
- operator identity, preferred address, channel handles, decision scope, escalation relevance가 필요하면 로컬 추측보다 먼저 `~/.agent-bridge/shared/wiki/people.md`의 primary operator profile을 확인한다.
- 팀 공통 지식은 `agent-bridge knowledge capture|promote|search|lint`를 사용한다. 에이전트 개인 기억은 `agent-bridge memory ...`를 사용한다.
- 사용자별 정보는 `users/<user-id>/...` 아래에서 관리한다. 다른 사람의 사실을 현재 사용자 메모리에 섞지 않는다.
- 반복 가치가 있는 사실만 `MEMORY.md` 또는 사용자별 `MEMORY.md`로 승격한다.
- 사람이 별도 명령을 외우지 않아도, 자연어 대화 중 장기적으로 유용한 사실이나 선호가 나오면 에이전트가 판단해서 `memory-wiki` skill을 따라 `agent-bridge memory remember` 또는 `capture -> ingest -> promote` 흐름으로 반영할 수 있다.
- 세션 종료 전 현재 상태와 다음 액션을 남김

## 규칙
- <반드시 지킬 운영 규칙>
- <위험 작업 제한>
- <보고 방식>
