---
name: agent-bridge-operating-manual
description: >-
  Agent Bridge 운영의 단일 진입점(목차/체크리스트). admin·static·dynamic·cron
  세션이 "이 상황엔 어느 절차/문서를 따르나"를 한 곳에서 찾도록 한다. 본문은
  복사하지 않고 각 canon(SSOT)을 가리킨다. 세션 시작 직후, 그리고 태스크 처리·
  업그레이드·릴리즈·handoff·메모리·에스컬레이션을 시작하기 전에 참조한다.
---

# Agent Bridge 운영 매뉴얼 (인덱스)

이 스킬은 **목차 + 강제 체크리스트**다. 실제 규칙 본문은 각 canon 문서가 SSOT이고,
여기서는 "어느 상황에 무엇을 보는지"만 가리킨다. 충돌 시 우선순위는
`SOUL.md` → 에이전트 `CLAUDE.md` → 공통 canon(아래) 순이다.

## 1. 상황별 라우팅 — "언제 무엇을 본다"

| 상황 | 따라야 할 SSOT |
|---|---|
| 세션 시작 | 에이전트 `CLAUDE.md`의 "매 세션 시작 시" 순서 (SOUL→CLAUDE→SESSION-TYPE→NEXT-SESSION→wiki→MEMORY-SCHEMA→USER.md→MEMORY→COMMON-INSTRUCTIONS/CHANGE-POLICY→TOOLS) |
| 태스크 수신·처리 | `COMMON-INSTRUCTIONS.md` "Task Processing Protocol" (claim→처리→결과 전달→done) |
| 큐 조작 | `agb inbox\|show\|claim\|done`, durable A2A는 `agent-bridge task create\|urgent\|handoff`, artifact 동반이면 `bundle create` |
| 2+ 이슈/PR/트랙 동시 | `wave-orchestration` 스킬 평가(disjoint면 병렬 fan-out, 동일파일 충돌은 직렬) |
| 코드 변경·PR | 페어 프로그래밍 루프: `<admin>-dev`(codex)에 plan→plan-ok→implement→review→implement-ok→merge. 다른 에이전트 브랜치 미접촉 |
| 릴리즈 | **운영자 명시 go 필수.** release PR=VERSION+CHANGELOG only, tag 후 README/docs 동기화 별도 PR (admin 전용) |
| handoff / 세션 인계 | `~/.agent-bridge/docs/agent-runtime/handoff-protocol.md`. 표준 파일명 `<agent-home>/NEXT-SESSION.md` 하나만 hook이 인지 |
| 메모리 | `MEMORY-SCHEMA.md`. 팀 공유=`agent-bridge knowledge`, 개인=`agent-bridge memory`, 사용자별=`users/<id>/` |
| 외부 push (`[Agent Bridge] event=…`) | `external-push-handling` 스킬 |
| cron 생성·수정 | `agent-bridge cron …` (직접 crontab 금지) |
| 변경 분류(upstream/downstream) | `CHANGE-POLICY.md` |
| upstream issue/PR | 운영자 승인 없이 생성·`propose --yes` 금지 |
| 인프라 장애 | `agent-bridge urgent <admin>` |
| 비즈니스/`human-decision-required` | 사람 채널로 escalate (페어 dev 범위 아님) |
| 같은 질문 2회째 | 다시 묻기 전 `agent-bridge escalate question --agent <self> …` |
| 15분+ blocked | `agb update <id> --status blocked --note "사유"` |
| iso v2 권한 거부 | 직접 fs 대신 `agb` verb. `agb agent show <a>`의 iso_boundary_quickref |

## 2. 절대 규칙 (매번 자기점검)

- [ ] **조용한 done 금지** — 결과를 요청자 채널/큐에 전달하지 않고 done 치지 않는다
- [ ] **빈 note done 금지** — `--note` 없이 done 치지 않는다
- [ ] 큐의 open status는 `queued`/`claimed`/`blocked`만. 시작 표시는 `claim`
- [ ] **릴리즈는 운영자 명시 go** — "알아서 해" 류 standing autonomy는 릴리즈 ship을 포함하지 않는다 (admin)
- [ ] upstream issue/PR 자동 생성·`--yes` 금지, 운영자 승인 먼저
- [ ] 운영자 primary checkout에서 `git checkout/commit/amend/reset/worktree prune` 금지
- [ ] tracked 파일에 팀명·채널 토큰·머신 경로 금지 (public snapshot)
- [ ] 크리티컬 변경 전 dry-run 또는 상태 확인 먼저
- [ ] 라이브 큐 DB 직접 sqlite 금지 — `agb`/`agent-bridge` CLI 우선
- [ ] `[cron-followup]` `needs_human_followup=true` → 사람 채널 전달 후 done

## 3. SSOT 문서 지도

운영 본문은 전부 아래에 있고, 이 스킬은 그 사본이 아니다. 업그레이드 때 이 문서들이
`shared/` 렌더 + 에이전트 심링크 + CLAUDE.md managed-block으로 전 에이전트에 동기화된다.

공유 canon은 `~/.agent-bridge/shared/` 경로로 적는다(iso 홈 렌더러가 BRIDGE_HOME으로 재작성).
일부 설치에서는 `ADMIN-PROTOCOL.md`가 workdir에 심링크되지 않으므로 bare 파일명으로 가리키지 않는다.
에이전트별 `MEMORY-SCHEMA.md`는 home/workdir에 실파일로 보장되므로 bare 파일명을 유지한다.

- `~/.agent-bridge/shared/COMMON-INSTRUCTIONS.md` — 전 에이전트 공통 운영 SSOT (queue, task, autonomy, channel)
- `~/.agent-bridge/shared/ADMIN-PROTOCOL.md` — admin 전용 (first-run, upgrade, static/dynamic 경계, release)
- `~/.agent-bridge/shared/CHANGE-POLICY.md` — 변경 upstream/downstream 분류
- `~/.agent-bridge/shared/TOOLS.md` — bridge-native 런타임 레퍼런스
- `MEMORY-SCHEMA.md` — 메모리 위키 유지 규칙
- `~/.agent-bridge/docs/agent-runtime/handoff-protocol.md` — handoff/NEXT-SESSION 계약
- `~/.agent-bridge/docs/agent-runtime/` — 심화 문서 (role-architecture, wiki-*, user-preference-injection 등)
- `~/.agent-bridge/shared/wiki/index.md` — 팀 공유 지식
