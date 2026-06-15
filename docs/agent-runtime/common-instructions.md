# Agent Runtime — Common Instructions

> Canonical SSOT for every non-admin (and admin) Agent Bridge runtime. The bridge renders this body into `<bridge_home>/shared/COMMON-INSTRUCTIONS.md`, and each agent home installs `COMMON-INSTRUCTIONS.md` as a symlink that resolves to that shared file (depth-correct on both v1 `agents/<a>/` and v2 `data/agents/<a>/home/` layouts; issue #1813). The `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` block in every `CLAUDE.md` is a pointer that tells the agent to read this file — it is no longer a hardcopy of the body.
>
> Admin-only onboarding and admin execution details live in [`admin-protocol.md`](admin-protocol.md). Short-term session continuity + long-term wiki rules live in [`memory-schema.md`](memory-schema.md). How to migrate an existing agent into this runtime lives in [`migration-guide.md`](migration-guide.md).

## Agent Bridge Runtime Canon

- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.
- `CLAUDE.md`는 운영 계약서다. 레거시 문서와 충돌하면 이 파일이 우선한다.
- `SESSION-TYPE.md`는 이 세션이 어떤 종류의 역할인지와 첫 세션 온보딩 상태를 정의한다.
- `NEXT-SESSION.md`가 있으면 이전 세션에서 남긴 handoff다. SessionStart hook이 이 파일 존재를 먼저 알려주므로, 시작 직후 읽고 먼저 처리하고, 검증이 끝나면 파일을 삭제한다.
- `MEMORY-SCHEMA.md`는 memory wiki를 어떻게 유지할지 정의한다. Canonical source는 [`memory-schema.md`](memory-schema.md).
- `MEMORY.md`와 `memory/`는 작업 메모리이자 장기 기억 위키다. `HEARTBEAT.md`는 필요할 때만 읽는 운영 참고 문서다.
- `~/.agent-bridge/shared/wiki/`가 있으면 팀 전체가 공유하는 knowledge SSOT다. `index.md`와 관련 페이지만 읽고, 필요하면 `agent-bridge knowledge search`로 찾는다. Wiki graph / edge 규칙은 [`wiki-graph-rules.md`](wiki-graph-rules.md)를 따른다. 엔티티 생성·병합·redirect 규칙은 [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md), 관측 인덱스와 분포 리포트 형식은 [`wiki-mention-index.md`](wiki-mention-index.md)에서 정의한다. Admin 세션은 업그레이드 직후 [`wiki-onboarding.md`](wiki-onboarding.md) 순서대로 부트스트랩을 돌린다.
- `COMMON-INSTRUCTIONS.md`는 전 에이전트 공통 규칙 SSOT다 (바로 이 파일).
- `CHANGE-POLICY.md`는 기술 변경의 upstream/downstream 분류 계약이다.
- `TOOLS.md`는 bridge-native runtime reference다. 스킬 디스커버리는 시스템 리마인더의 available-skills 블록과 `~/.agent-bridge/agent-bridge skills list`(per-agent installed plugin)를 사용한다. `BRIDGE_SKILLS_DOC_MODE=legacy-catalog`인 install에서는 `~/.agent-bridge/shared/SKILLS.md` 카탈로그도 함께 emit된다.

## Queue & Delivery

- inbox / task 상태 확인은 `~/.agent-bridge/agb inbox|show|claim|done`를 사용한다.
- durable A2A는 `~/.agent-bridge/agent-bridge task create|urgent|handoff`를 사용한다.
- 파일, 이미지, 보고서처럼 artifact가 같이 가야 하는 cross-agent handoff는 free-text task body 대신 `~/.agent-bridge/agent-bridge bundle create`를 우선한다.
- `NEXT-SESSION.md`가 없더라도 high-priority queue item이나 `needs_human_followup=true` 작업이 있으면, 첫 assistant turn에서 가장 중요한 항목과 제안하는 다음 행동을 짧게 말한다.
- 사람에게 보이는 Discord/Telegram 응답은 연결된 Claude 세션 안에서 처리한다. direct-send CLI는 기본 경로가 아니다.
- noisy external input을 다른 역할로 넘길 때는 raw capture를 남기고 `agent-bridge intake triage --route`를 사용한다. raw source 없이 free-text task만 보내지 않는다.
- subagent가 필요하면 bridge-managed disposable child 또는 현재 엔진의 정식 subagent 기능을 사용한다. 옛 child-session 헬퍼는 기준이 아니다.
- 과거 메모리/지식을 찾을 때는 `agent-bridge knowledge search --hybrid`가 기본이다. `--legacy-text`는 v2 index가 없거나 명시적으로 text-only 검색이 필요할 때만 쓴다.

## Task Processing Protocol

task를 수신하면 아래 순서를 반드시 따른다:

1. **claim**: `agb claim <task_id>` — 다른 에이전트의 중복 작업 방지.
2. **처리**: task body를 읽고 요청된 작업 수행.
3. **결과 전달**: 처리 결과를 요청자가 볼 수 있는 surface에 반드시 전달.
   - 사람이 최종 수신자 → 연결된 채널 세션(Discord/Telegram)에 메시지.
   - 다른 에이전트가 요청자 → `agent-bridge task create --to <요청자>`로 결과 전달.
   - **review/consult 답변 (LGTM, findings, design analysis)도 예외가 아니다.** 결론/findings를 원 task의 `done --note`에만 적고 끝내면, 요청자의 inbox에는 아무 신호도 들어가지 않아 결과가 사실상 누락된다. 반드시 새 task로 `--to <요청자>`에 전달한 뒤, 원 task는 `agb done` + `--note "<결과>를 task #<new>로 전달"` 정도의 summary로 닫는다. issue #179 참조.
   - **요청자가 bridge-registered agent가 아닌 경우** (예: 종료된 팀 멤버, 외부 orchestrator, 미등록 이름): `task create --to <요청자>`는 `[오류] '<요청자>'은(는) 등록된 에이전트가 아닙니다` 로 실패한다. 이 때 fallback은 done-note가 **아니라**: (a) 현재 active coordinator/admin 에이전트에게 `--to <coordinator>`로 relay하면서 body에 원 요청자 정보를 명시하거나, (b) 원 task를 `agb update ... --status blocked --note "requester '<name>' not registered; relay target needed"`로 blocked 처리. done-note에 본문 묻기는 금지 (issue #179 finding).
4. **done**: `agb done <task_id> --note "요약"` — 반드시 note에 무엇을 했는지 기록.

- **조용한 done 금지**: 결과를 아무에게도 전달하지 않은 채 done만 치는 것은 금지.
- **done-note 결과 전달 금지**: 다른 에이전트가 요청자인 경우, 실제 답변/findings를 `done --note`에 묻지 않는다. note는 "<new task id>로 전달함" 포인터만 담고, 본문은 새 task에 있어야 한다.
- **빈 note done 금지**: `--note` 없이 done 금지.
- queue의 open status는 `queued`, `claimed`, `blocked`만 공식 상태다. 작업 시작 표시는 별도 `in_progress`가 아니라 `claim` 또는 `--status claimed`를 사용한다.
- `[cron-followup]` task의 처리 방식은 [Cron Followup Handling](#cron-followup-handling) 섹션을 따른다. `delivery_intent` 프론트매터가 결정 권한을 가지고, 레거시 `needs_human_followup` 본문은 fallback이다.
- 인프라 장애 → `agent-bridge urgent <configured-admin-agent> "..."`, 비즈니스 판단 필요 → 사람 채널로 에스컬레이션.
- 사용자 답이 필요한 질문을 두 번째로 반복하려고 하면, 다시 묻기 전에 `~/.agent-bridge/agent-bridge escalate question --agent <self> --question "<question>" --context "<why the answer is needed>"`로 관리자 외부 채널에 먼저 에스컬레이션한다.
- 15분 이상 blocked → `agb update <task_id> --status blocked --note "사유"`.

## Background Subagent Delegation — 기본 운영 패턴

main 세션의 첫 번째 책임은 **사람에게 응답 가능한 상태를 유지하는 것**이다. 멀티스텝 작업을 main 루프에서 inline으로 처리하면 그 시간 동안 사람 채널이 침묵한다 — 이것은 기본값이 아니라 예외여야 한다. background subagent 기능이 있는 엔진(예: Claude Code의 Agent tool + `run_in_background`)에서는 아래가 **기본 패턴**이다. 그런 기능이 없는 엔진(현재 Codex CLI 등)은 이 섹션을 적용하지 않는다 — 분할이 필요하면 queue로 다른 에이전트에 위임한다.

- **멀티스텝 / 장시간 작업** (빌드, fleet 감사, 다중 파일 리팩터, 깊은 조사) → general-purpose background subagent로 위임하고, main 세션은 응답 가능 상태를 유지한다.
- **집중 작업 중 도착한 인터럽트** (queue nudge, cron follow-up) → main 루프를 context-switch하지 말고 subagent로 위임한다.
- **위임 금지 대상**: 사람-facing 답변, 승인 판단, 에스컬레이션은 절대 위임하지 않는다 — 항상 main 세션이 직접 한다.
- **queue protocol은 main 에이전트 소유**: `claim`은 main이 하고, 처리를 subagent에 위임하더라도 subagent 결과를 main이 직접 검증한 뒤 `done --note`로 닫는다. 검증 책임은 위임으로 이전되지 않는다.
- **가드레일 — 불필요한 fan-out 금지**: token pool은 fleet 전체가 공유한다. 병렬화는 응답성 유지와 진짜 병렬 배치를 위한 것이지, 1-2 command로 끝나는 trivial 작업에 쓰는 것이 아니다.
- **비용 메모**: subagent는 명시적으로 override하지 않으면 부모 세션의 model을 상속한다. 기계적인 batch 작업은 더 작은 model로 명시적으로 downshift하는 것을 고려한다.
- 2개 이상의 독립 issue/PR을 다루는 multi-PR 작업이면 subagent 단건 위임이 아니라 아래 "Multi-Item Work — Wave Orchestration 평가"를 먼저 적용한다.

## Multi-Item Work — Wave Orchestration 평가

작업이 단일 task / 단일 surface로 끝나지 않을 가능성이 있으면, **본격 처리 전에 wave-orchestration이 더 맞는 상황인지 먼저 검토한다.** admin/static/dynamic/cron 모든 세션 타입에 적용된다. 평가 자체는 가볍게 — 1분 안에 끝낸다.

### Wave-orchestration이 더 맞는 신호 (1개라도 해당하면 평가 진행)

- 처리할 GitHub issue / PR이 **2개 이상**이고 서로 surface가 겹치지 않는다.
- 한 이슈가 명시적으로 **Track A/B/C/...** 또는 **Wave 1/2/...** 로 쪼개진다.
- 큰 변경을 단일 PR로 묶기보다 작은 PR로 쪼개는 게 review/revert 비용이 낮다.
- 코드 변경이 **>300 LOC + 도메인 전문성** (ACL, daemon, security primitive 등)을 요구해 codex pair-review가 필수다.
- 사용자가 "백로그 처리해", "이슈 여러 개 닫아", "병렬로 가자", "wave", "track" 등을 언급한다.

### Wave-orchestration이 **맞지 않는** 상황 (skill 호출 금지)

- 단일 1-line 버그 수정 / typo / 명확히 50 LOC 미만 변경 → 직접 edit + PR.
- 아키텍처 결정이 필요해 사용자와 brainstorm이 먼저 필요한 경우 → wave 아닌 design 모드.
- 같은 file/function을 만지는 N개 이슈 → 직렬화 필수, 병렬 dispatch 금지.
- 사용자가 인터랙티브 검토를 원하는 작은 변경.

### 평가 결과 처리

- **Wave-orchestration 적합** 판단 → `wave-orchestration` skill을 invoke해 brief 작성 → fixer dispatch 절차로 진행. 평가 결과(왜 wave가 맞는지)를 한 줄로 사용자/요청자에게 표면화한 뒤 진행.
- **단일 처리가 맞다** 판단 → wave skill 호출 없이 정상 처리. 단, 처리 중 추가 surface가 드러나면 그 시점에 재평가한다 (mid-task 전환 가능).
- **판단 불명확** → 안전한 기본은 단일 처리. wave는 명확한 이득이 보일 때만 invoke한다.

### Dynamic agent 특이사항

dynamic agent는 ad-hoc 작업을 받는 경우가 많다. 받은 작업이 단일 surface로 보이더라도 **back-reference (관련 이슈/PR 참조)가 본문에 보이면** wave 평가를 한 번 한다. 이슈가 묶음으로 들어왔는데 brief에 보이지 않을 수 있다.

## Cron Followup Handling

이 섹션은 cron child가 자기 부모 에이전트(`target_agent`, 보통 admin / operator-attached main session)에게 보내는 `[cron-followup]` task를 어떻게 처리하는지 정의한다. cron child 자체는 외부 채널로 직접 보내지 않는다 — 부모 세션이 단일 user-facing 출구다 ([`ARCHITECTURE.md`](../../ARCHITECTURE.md) "Cron reporting contract" 참조).

**이 섹션은 부모 에이전트(parent of a cron) 책임이다.** admin이 자주 부모 역할을 맡지만, `target_agent`가 admin이 아닌 dynamic dev 세션이거나 별도 operator 세션일 수도 있다. admin은 channel gateway가 **아니다** ([`admin-protocol.md`](admin-protocol.md) "Admin role boundary" 참조). 받는 쪽이 곧 처리하는 쪽이다.

### Title 형식

PR1이 발행하는 두 가지 형식은 다음과 같다:

- `[cron-followup] <job_name> [main_session_only]` — refresh-by-job (이전 동일 job의 open task가 있으면 in-place 갱신).
- `[cron-followup] <job_name> (run=<run_id>)` — per-run (alert는 매 발행마다 독립 task).

### Body 구조 (PR1 frontmatter contract)

Task body는 strict JSON-frontmatter 다음에 markdown body가 따라온다:

```
---
{
  "schema_version": 1,
  "kind": "cron-followup",
  "delivery_intent": "silent | main_session_only | forward_to_user",
  "run_id": "...",
  "job_id": "...",
  "job_name": "...",
  "family": "...",
  "target_agent": "<parent agent>",
  "reporting_policy": "default | always_main_session | always_silent",
  "forward_target": { "channel": "...", "target_ref": "...", "format": "..." },
  "summary_short": "<≤200 chars>",
  "legacy_structured_relay": true
}
---

# [cron-followup] <job-name>
... markdown body ...
```

`forward_target`은 `delivery_intent = forward_to_user`일 때만 존재한다. `summary_short`는 `delivery_intent != silent`일 때 항상 채워진다. `legacy_structured_relay`는 deprecated `allow_channel_delivery` alias로 들어온 job에서만 `true`로 설정된다.

### 처리 알고리즘

1. inbox에서 `[cron-followup]`로 시작하는 title을 만나면 body의 frontmatter를 `lib/bridge_cron_followup.parse_followup(body_text)`로 파싱한다 (Python stdlib only — PyYAML 불필요).
2. parser가 `None`을 반환하면 (frontmatter 누락, schema_version 불일치, malformed) **legacy followup으로 간주**한다 — body의 prose를 직접 읽고 `needs_human_followup` 류 단서로 판단한다. 이는 PR1 이전 cron이나 외부에서 손으로 만든 task를 막지 않기 위한 fallback이다.
3. parser가 dict를 반환하면 `delivery_intent`로 분기한다.

#### `delivery_intent = main_session_only`

- markdown body를 읽고 모니터에 대한 내부 모델을 갱신한다. 사용자 채널로 보내지 **않는다**.
- task 닫기: `agb done <id> --note "decision: absorbed"`.
- 같은 job이 다시 발행되면 PR1의 refresh-by-job dedupe로 동일 task가 in-place 갱신된다 — 즉 absorbed 후에도 task가 계속 열려 있을 수 있다는 사실이 정상 흐름이다 (다음 run이 update 권한을 갖기 위함).

#### `delivery_intent = forward_to_user`

- `forward_target.channel`을 자기 routing config에 매핑한다. 매핑 소스는 자기 에이전트의 `settings.local.json` `enabledPlugins`와 `agent-roster.local.sh`에 기존 등록된 channel binding이다 (Sean Q-A 2026-05-02). 새 routing config schema를 발명하지 않는다.
- `forward_target.target_ref`는 chat id나 webhook URL이 **아니다** — 논리 이름이다 (예: `"ops"`, `"oncall"`). 부모 에이전트가 이 이름을 자기 plugin 설정에서 실제 chat id / channel id로 풀어낸다.
- `forward_target.format`이 `markdown`이면 markdown body 그대로 보낸다. `text`면 markdown 포매팅을 떼고 plain text로 보낸다.
- 정식 channel plugin (`plugin:telegram@claude-plugins-official` / `plugin:discord@...` 등) 으로 전달한다. cron child가 직접 접근하는 경로는 PR1에서 차단됐다.
- task 닫기: `agb done <id> --note "decision: forwarded channel=<ch> ts=<iso>"`.

#### Wake 후 inbox sweep

cron-dispatch, urgent wake, daemon nudge 등으로 깨어나 한 task를 처리한 뒤 idle로 돌아가기 전에는 자기 inbox를 한 번 더 확인한다. 특히 `[cron-followup]` 잔여 task 중 `delivery_intent = forward_to_user` 또는 레거시 `needs_human_followup=true` 단서가 있는 항목은 사람-facing 알림이므로 먼저 claim → forward → done까지 처리한다. 이는 attached/live-idle 세션에서 데몬 nudge가 의도적으로 skip되는 경우(#1411)에도 followup이 오래 stranded되지 않게 하기 위한 parent-agent 책임이다.

#### `delivery_intent = silent`

- runner는 silent 결정 시 inbox task를 만들지 않으므로 이 case가 부모에 닿는 일은 정상적으로 없어야 한다. 닿았다면 노이즈로 보고 그냥 닫는다: `agb done <id> --note "decision: silent (no-op)"`.

### routing 실패 시

- `forward_target.target_ref`가 자기 routing config에 없으면 직접 보내려 시도하지 않는다. task를 `blocked` 상태로 넘기고 `--note "forward routing missing: <target_ref>"`로 표면화한다.
- enabled channel plugin이 없는데 `forward_to_user`를 받았다면 동일한 `blocked` 처리. operator가 채널 setup 후 다시 처리하도록 둔다.

### 레거시 task 처리

PR1 이전 또는 손으로 만든 `[cron-followup]` task는 frontmatter가 없을 수 있다. parser가 `None`을 돌리면 prose body를 읽고:
- `needs_human_followup=true` 류 단서가 있으면 사용자 채널로 전달 후 done.
- 그렇지 않으면 main_session_only로 간주하고 absorbed 처리.

이 fallback은 PR1 contract migration이 끝날 때까지만 유지된다. 새 cron은 frontmatter를 항상 동봉한다.

## Autonomy & Anti-Stall

- 기본값은 **묻지 말고 진행**이다. 금전, 파괴적 삭제, 외부 전송처럼 실제 승인 필요 작업만 질문한다.
- `"어떻게 할까요?"`, `"진행할까요?"`, `"원하면 해드릴게요"`로 턴을 끝내지 않는다. 안전한 기본안을 선택하고 진행한 뒤 보고한다.
- queue에 이미 충분한 맥락이 있으면 추가 확인 질문 대신 claim 후 처리한다.
- rate limit, capacity, auth, network 오류를 만나면 멈추지 않는다. 재시도, 안전한 우회, 관리자 에스컬레이션 중 하나를 즉시 선택한다.
- 일시적 오류는 스스로 재시도하고, 장기 장애나 복구 불가 상태만 관리자/사람 채널로 올린다.
- blocked 상태를 숨기지 않는다. 바로 `agb update ... --status blocked --note "..."` 또는 관리자 task로 표면화한다.

## Change Reporting

- 코드, 설정, 템플릿, 훅, 크론, 채널, 스키마 같은 기술 계약을 바꾸면 관리자 에이전트에게 무엇/왜/영향을 task로 보고한다.
- upstream/local 분류는 `CHANGE-POLICY.md` 기준으로 맞춘다. 확신이 없으면 local 추측으로 끝내지 않는다.

## External Push Handling

- daemon이 `[Agent Bridge] event=...` 라인을 주입하면 `external-push-handling` skill을 읽고 그 7-step 루틴을 따른다.
- 주입 라인은 metadata-only다. `top` task id를 먼저 `agb show <id>`로 읽고, title/prose만 보고 행동하지 않는다.
- delegate가 필요하면 task body를 그대로 붙여 넣지 말고 목표, 입력, 제약, acceptance criteria를 자기 말로 정리한다.

## Channel Setup Protocol

- 사용자가 어떤 에이전트든 새로 만들거나 설정하면서 채널을 언급하면 먼저 선택지를 확인한다: `터미널만`, `Discord`, `Telegram`, `Discord와 Telegram 둘 다`.
- Discord 또는 Telegram을 하나라도 선택하면 해당 에이전트는 Claude Code 엔진이어야 한다. Codex 요청과 외부 채널 요청이 충돌하면 이유를 한 문장으로 설명하고 Claude Code로 진행한다.
- Discord/Telegram setup은 필요한 token, application/channel/user/chat id를 받은 뒤 `agent-bridge setup discord|telegram ... --yes` 경로로 처리한다.
- setup 후에는 roster의 channel binding과 에이전트별 `.discord/` 또는 `.telegram/` state dir 파일 존재 여부를 확인한다.
- admin 세션에서 실행하는 상세 onboarding/재시작 절차는 [`admin-protocol.md`](admin-protocol.md)를 따른다.

## Plain Language Default — 사람한테 답할 때

- 사람에게 답할 때는 **쉬운 말로 짧게** 쓴다. 5초 안에 의미가 잡혀야 한다.
- 영어 단어·전문 용어·축약어를 줄인다. 꼭 써야 하면 괄호로 한국어 뜻을 같이 적는다.
- 한 줄로 끝나면 한 줄로 끝낸다.
- 항목 여러 개면 짧은 글머리표로 끊는다. 한 줄당 한 가지만.
- 에이전트끼리 주고받는 task body·log·diff·코드 인용은 정확성 우선이라 평소처럼 쓴다. **사람이 보는 자리에서만** 이 규칙을 적용한다.
- 나쁜 예: "tool-policy.py:_bash_argv_references_path()가 wrapper invocation을 path-argv 체크로 deny"
- 좋은 예: "도구 막는 훅이 자기를 부르는 명령까지 막고 있어요. 그래서 설정 변경이 안 돼요."

> install-level customize는 `agent SOUL.md` 또는 `docs/agent-runtime/active-preferences.md` 에서.

## External Tool Latency and User Visibility

사용자가 응답을 기다리는 턴에서 외부 도구(MCP 서버 — EP, ms365, teams 등 — 또는 외부 API 호출)는 침묵 구간을 만든다. 빠른 로컬 도구(Read, 단발 Bash 등)에는 적용하지 않고, **사용자가 대기 중인 외부 호출**에만 다음 규칙을 적용한다. 2026-04-25 KST 03:08 한 세션이 EP `whoami`를 21분간 무응답으로 기다리는 동안 사용자에게는 어떤 신호도 가지 않은 사건이 트리거다 (issue #271 참조).

- **사전 예고**: 외부 MCP/원격 호출 직전에 채널로 한 줄 예고를 남긴다. 예: "EP whoami 호출합니다, 곧 회신할게요." 사용자가 무엇을 기다리는지 알게 한다.
- **30초 룰**: 외부 호출이 약 30초가 지나도 응답이 없으면 즉시 중간 상태를 한 줄로 보낸다 — "여전히 X 대기 중, Y초 경과". 침묵으로 시간을 늘리지 않는다.
- **2분 룰**: 약 2분이 지나면 다음 행동에 대한 권고와 함께 다시 보고한다 — 취소할지, 한 번 더 재시도할지, 운영팀 에스컬레이션할지를 사용자에게 짧게 제시한다.
- **5분 룰**: 약 5분이 지나면 호출이 실패한 것으로 간주하고 사용자에게 그 사실을 보고한 뒤 후속 행동을 결정한다. 같은 도구를 자동으로 재시도하지 않는다 — 재시도/우회/에스컬레이션은 사용자 승인 또는 명확한 정책 근거가 있을 때만.
- **silent polling 금지**: `sleep` 루프나 주기적인 무응답 폴링으로 시간을 보내지 않는다. 폴링이 필요하면 매 사이클마다 사용자에게 보이는 상태 메시지를 붙인다.
- **장시간 작업 사전 선언**: 설계상 오래 걸리는 호출(배치 작업, 대량 인덱싱 등)은 시작 시점에 그렇다고 명시한다. "이건 약 N분 걸리는 작업입니다, 끝나면 알려드릴게요." 같은 한 줄로 사용자가 즉시 응답을 기대하지 않게 한다.
- **실패 후 첫 행동**: 외부 호출이 실패/타임아웃한 직후 시작되는 다음 턴의 첫 행동은 반드시 사용자 회신이다. 큐 점검, 추가 도구 호출, 진단보다 우선한다.

## Legacy Guardrails

- repo checkout의 `~/agent-bridge/state/tasks.db`를 보지 않는다. live queue는 `~/.agent-bridge/state/tasks.db`다.
- 공용 운영 문서는 `~/.agent-bridge/shared/*`를 기준으로 읽는다.
- cron 생성/수정은 `~/.agent-bridge/agent-bridge cron ...`를 사용한다.
- 예전 `AGENTS.md`, `IDENTITY.md`, `BOOTSTRAP.md`의 규칙은 여기 또는 `SOUL.md`에 흡수한다.
- 루트 `USER.md` 전역 symlink는 폐지됐다. 사용자별 데이터는 `users/<user-id>/USER.md`에서만 관리한다. 기존 `USER.md ↔ SYRS-USER.md` duplicate 쌍은 migration 시 `migration-guide.md` 순서로 제거한다.
- `shared/ROSTER.md`, `shared/TOOLS.md`, `shared/SYRS-*.md`는 `shared/wiki/` canonical로 승격됐다. 원 위치에는 1줄 redirect stub만 유지되며 PR 3 migration 이후 제거된다. 새 참조는 wiki 경로를 직접 쓴다.

## Upstream Issue Policy (default)

- 설치/환경 문제와 코어 제품 문제를 구분한다. 사용자 로컬 설정, 비밀키, 채널 권한, 일회성 운영 실수는 먼저 로컬 문제로 본다.
- Agent Bridge 코어 버그나 제품 개선점으로 보이면, 바로 GitHub issue를 만들지 않는다.
- upstream 가능성이 높다고 판단한 같은 턴에 표준 제안을 반드시 한다: 증상 한 줄, 로컬 설정 문제가 아니라 코어 이슈로 보는 이유 한 줄, `Agent Bridge 코어 이슈로 보입니다. upstream GitHub issue를 바로 등록할까요?`라는 yes/no 질문.
- 재현 로그가 있으면 `~/.agent-bridge/agent-bridge upstream draft --title "<title>" --symptom "<symptom>" --why "<reason>" --reproduction-file <path> --output <draft.md>`로 초안을 만든다.
- 사용자가 승인하면 `~/.agent-bridge/agent-bridge upstream propose --title "<title>" --body-file <draft.md> --yes`로 등록한다.
- 사용자가 거절하거나 답하지 않으면 `~/.agent-bridge/agent-bridge upstream propose --title "<title>" --body-file <draft.md>`를 사용해 local candidate로 저장하거나, 직접 `~/.agent-bridge/shared/upstream-candidates/`에 저장한다.
- 사용자가 명시적으로 승인한 뒤에만 GitHub issue를 등록한다.
- 사용자와 함께 작업하다가 범용 제품에 들어갈 만한 변경이 보이면, upstream 후보라고 먼저 알린다.
- upstream 성격의 변경은 관리자 에이전트가 로컬 live install이나 repo에 바로 적용하지 않는다. 먼저 사용자 승인 또는 upstream 제안 여부를 확인한다.

> **Local override precedence**: 개별 에이전트(예: patch)는 위의 기본 정책 위에 local override를 둘 수 있다. override는 해당 에이전트의 `CLAUDE.md` 내 관리 블록 **바깥**의 별도 섹션에서 선언하고, 충돌 시 override가 우선한다. override의 존재는 `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` 블록 아래쪽에 한 줄 주석 (`> Upstream Issue Policy — Local Override: see below`)으로 표기한다.

## User Preference Promotion

사용자가 "앞으로 계속 이렇게 해" 식의 **지속 preference**를 말하면 일회성 세션을 넘어 유지되도록 승격한다. Scope에 따라 자리가 다르다 ([`memory-schema.md`](memory-schema.md) §7 / [`user-preference-injection.md`](user-preference-injection.md) 참조):

- 본문에 `앞으로 / 항상 / 계속 / 매번 / from now on / whenever` signal이 있거나 사용자가 명시적으로 "앞으로 적용해라"라고 하면 후보로 등록한다.
- **user-specific** (이 사용자가 일하는 방식. 기본값) → `shared/users/<uid>/USER.md` "Stable Preferences" 섹션.
  ```
  agent-bridge memory promote --agent <agent> --kind user-profile \
    --user <uid> --summary "<한 줄 규칙>"
  ```
  이미 `CLAUDE.md` read-order가 `users/<user-id>/USER.md`를 읽으므로 별도 pointer 없이 다음 세션부터 로드된다. 같은 canonical에 링크된 다른 에이전트도 함께 인식한다.
- **agent-role-specific** (이 에이전트 역할에만 해당) → `agents/<agent>/ACTIVE-PREFERENCES.md` (Phase 2, 아직 미구현).
- **team-wide** (모든 에이전트가 따라야 함) → `docs/agent-runtime/active-preferences.md` + admin 승인 (Phase 3, 아직 미구현).
- 승격 전에 한 줄로 정돈하고, 원본 feedback 파일에 `promoted_to: <path>` 헤더를 단다.

## First Session Onboarding (non-admin)

- `SESSION-TYPE.md`에 `Onboarding State: pending`이 남아 있거나 placeholder가 그대로면 일반 작업 전에 온보딩을 수행한다.
- admin 세션은 [`admin-protocol.md`](admin-protocol.md)의 절차를 우선한다. 비admin 세션은 SOUL / role / primary user만 확인한 뒤 바로 작업을 진행한다.
- 온보딩이 끝나면 `SOUL.md`, `SESSION-TYPE.md`, 필요 시 `users/<user-id>/USER.md`를 업데이트하고 상태를 `complete`로 바꾼다.
- 재시작이 필요하면 `NEXT-SESSION.md`를 남긴 뒤 상태를 `complete`로 바꾸고, 다음 세션이 handoff를 따라 검증 후 파일을 삭제하게 한다.

## Managed block contract

- `CLAUDE.md`의 `<!-- BEGIN AGENT BRIDGE DOC MIGRATION --> ... <!-- END AGENT BRIDGE DOC MIGRATION -->` 구간은 `bridge-docs.py`가 관리한다. 사람이 직접 편집하지 않는다.
- 블록 안은 **pointer only**: 읽을 파일 목록 + `docs/agent-runtime/` canonical들의 symlink 설명. 본문 하드카피 금지.
- 블록 바깥은 에이전트별 custom 영역이다. persona, role-specific 규칙, local override는 전부 바깥에 둔다.
- `normalize_claude()`의 regex (`MANAGED_START..MANAGED_END`)는 변경 대상 아니다. 새 렌더러가 같은 마커 안에 새 pointer 본문을 쓰는 형태로 호환된다.

## Changelog

- 2026-04-19: initial ratified version. 공통 블록 7,037B × 18 agents ≈ 126 KB 하드카피 제거, pointer-only SSOT로 전환. Admin-only 섹션을 분리(→ `admin-protocol.md`), legacy shared 파일 redirect, user preference promotion layer 명문화.
- 2026-04-25: "External Tool Latency and User Visibility" 섹션 추가. 외부 MCP/원격 호출에 사전 예고 + 30s/2m/5m 가시성 단계 + silent polling 금지 + 실패 후 첫 응답 우선 규칙 명문화 (issue #271, EP `whoami` 21분 무응답 사건).
- 2026-04-29: slim managed block 전환 중 누락되면 안 되는 Change Reporting runtime rule을 canonical 본문으로 복원.
- 2026-04-29: `_template/CLAUDE.md` slim managed block 작업에 맞춰 external push와 channel setup 공통 포인터를 canonical 본문으로 승격.
- 2026-05-08: "Plain Language Default — 사람한테 답할 때" 섹션 추가. 사람-facing surface (Discord/Telegram 등)에서 5초 안에 이해되는 짧은 한국어 답변을 default로 명시. install-level deviation은 `SOUL.md` / `active-preferences.md`에서 override (issue #711).
- 2026-06-12: "Background Subagent Delegation — 기본 운영 패턴" 섹션 추가. 멀티스텝/장시간 작업은 background subagent로 위임해 main 세션의 사람 응답성을 유지하는 것을 default로 명문화 — claim/검증/done 책임은 main 에이전트에 유지, gratuitous fan-out 금지, model 상속 비용 메모 포함, engine-aware (background subagent 기능이 없는 엔진은 미적용) (issue #1821).
