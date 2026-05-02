# 쭈쭈(jjujju) 호스트 마이그레이션 프롬프트

> **v0.7.1 부터 자동화됨 — 이 프롬프트는 fallback / 수동 검증용**
>
> v0.7.1 의 `agent-bridge upgrade --apply` 가 `bridge-relay-cleanup.py` 를 자동으로 실행해서 채널 항목 / 환경변수 / state 파일 / 에이전트별 relay-token 을 한 번에 정리합니다. 일반적인 경우 이 프롬프트를 보낼 필요가 없습니다. 다음 두 경우에만 사용:
>
> 1. v0.7.1+ 으로 못 올라가는 호스트 (예: stuck on v0.7.0)
> 2. v0.7.1 upgrade 가 `[bridge-upgrade] WARN: telegram-relay residue cleanup helper exited non-zero` 를 남기고 끝난 경우 (rare — 보통 권한 문제)

**용도**: PR3(telegram-relay 폐기) 머지 후 쭈쭈 호스트에서 텔레그램 셋업을 공식 Claude Code 플러그인으로 되돌리기 위한 1회성 마이그레이션. Sean이 쭈쭈 admin/세션에 그대로 보내면 됩니다.

**전제 조건**: 쭈쭈 호스트에서 `agent-bridge upgrade --apply`를 먼저 실행해서 v0.7.0 이상으로 올라간 상태여야 합니다 (PR #501 머지 commit `c96860a` 포함). v0.7.1+ 이라면 이 프롬프트 대신 자동 cleanup 결과를 audit 로그에서 확인 (`telegram_relay_residue_cleanup_applied`).

---

## 쭈쭈에게 보낼 프롬프트 (이 아래부터 그대로 복붙해서 보내면 됨)

```
[운영자 지시] 텔레그램 마이그레이션 — 자체 릴레이 폐기, Claude Code 공식 플러그인으로 복귀

배경:
agent-bridge가 v0.6.37 이후로 자체 telegram-relay 데몬을 띄워서 텔레그램 long-polling을 가로채는 구조였는데, 설계가 잘못됐다는 결론으로 폐기됐어. 너(쭈쭈) 호스트도 이 데몬을 사용 중이었고, 이번 업그레이드(PR3) 이후로는 Claude Code 공식 텔레그램 채널 플러그인을 직접 사용해야 해.

작업 절차 (순서대로 실행하고 각 단계 결과를 보고해줘):

1. 업그레이드 확인
   $ agent-bridge --version
   v0.7.0 이상이어야 함. 아니면 멈추고 운영자(Sean)에게 보고.

2. 현재 텔레그램 등록 상태 확인 (정리 대상 인벤토리)
   $ agent-bridge status | grep -i telegram
   $ ls -la ~/.agent-bridge/state/channels/telegram/ 2>/dev/null
   $ ls -la ~/.agent-bridge/agents/jjujju/.telegram/ 2>/dev/null
   확인할 항목:
   - state/channels/telegram/tokens.list (있으면 4단계에서 삭제)
   - state/channels/telegram/<token-hash>.sock (있으면 4단계에서 삭제)
   - state/channels/telegram/<token-hash>/ 디렉토리 (있으면 4단계에서 삭제)
   - agents/jjujju/.telegram/relay-token (있으면 4단계에서 삭제)
   - agents/jjujju/.telegram/.env, access.json — 이건 보존 (공식 플러그인이 그대로 사용)

3. 텔레그램 셋업 재실행 (공식 플러그인 모드로)
   $ agent-bridge setup telegram jjujju
   - 기존 봇 토큰 그대로 사용할지 물어보면 yes
   - --use-relay/--no-relay 같은 플래그는 PR3에서 제거됐으므로 안 쓰면 됨
   - 셋업 끝나면 너의 ~/.agent-bridge/agents/jjujju/.claude/settings.local.json의 enabledPlugins에 plugin:telegram@claude-plugins-official이 들어있어야 함

4. 환경변수/로스터 + orphaned state 파일 정리
   (a) 환경변수
       $ grep -E 'BRIDGE_TELEGRAM_(RELAY|USE_RELAY)' ~/.agent-bridge/agent-roster.local.sh
       - 매치 있으면 해당 줄 삭제 (실제 v0.6.x 에서 쓰던 키는 BRIDGE_TELEGRAM_RELAY_ENABLED, BRIDGE_TELEGRAM_USE_RELAY 두 개)
       - agent-roster.local.sh 는 직접 편집 가능. 편집 후 다음 명령으로 검증:
         $ bash -n ~/.agent-bridge/agent-roster.local.sh

   (b) orphaned relay state (2단계에서 발견한 항목들)
       # tokens.list / socket / 디렉토리:
       $ rm -f ~/.agent-bridge/state/channels/telegram/tokens.list
       $ rm -f ~/.agent-bridge/state/channels/telegram/*.sock
       $ rm -rf ~/.agent-bridge/state/channels/telegram/*/
       # 에이전트별 relay 토큰 파일:
       $ rm -f ~/.agent-bridge/agents/jjujju/.telegram/relay-token
       삭제 후 확인:
       $ ls -la ~/.agent-bridge/state/channels/telegram/ 2>/dev/null
       $ ls -la ~/.agent-bridge/agents/jjujju/.telegram/
       기대 결과: state/channels/telegram/ 비어있거나 없음. .telegram/ 에는 .env / access.json 만 남음.

5. 데몬 재시작 + 상태 확인
   # bridge-daemon.sh 는 restart 서브커맨드가 없음 — stop --force 후 start 로 두 번 호출.
   $ bash ~/.agent-bridge-source/bridge-daemon.sh stop --force
   $ bash ~/.agent-bridge-source/bridge-daemon.sh start
     # 또는 시스템에 따라:
     # $ bash bridge-daemon.sh stop --force
     # $ bash bridge-daemon.sh start
   $ agent-bridge status
   - 텔레그램 라인이 "official plugin" 또는 비슷한 표시여야 함
   - "relay daemon" 같은 표현은 이제 안 보여야 정상

6. 본인이 너 자신한테 텔레그램으로 테스트 메시지 보내고 수신되는지 확인
   너의 일반 텔레그램 채널로 "마이그레이션 테스트" 보내고 정상 수신되는지 확인.
   안 되면 멈추고 보고.

7. 운영자에게 결과 보고
   각 단계의 출력 요약 + 마이그레이션 성공/실패 한 줄로 요약해서 운영자(Sean)에게 인박스 task로 회신.
   제목: [migration-done] jjujju telegram official plugin
   본문: 단계별 결과, 발견한 이상치(있으면), 현재 상태 (정상 송수신 가능 / 추가 조치 필요).

주의사항:
- 이 작업 중에는 어떤 cron 잡도 텔레그램으로 알림 보내려고 하면 안 됨 (하지만 PR1+PR2가 이미 머지된 시점이라 cron들은 이제 인박스로만 보고하므로 충돌 가능성 없음)
- (참고) v0.6.x 에서 relay 는 `bridge-daemon.sh` 의 자식 프로세스로 supervise 됐을 뿐, 별도의 systemd 유닛은 안 만들어졌어. v0.7.0 으로 업그레이드한 시점에 supervise 함수 자체가 코드에서 사라졌기 때문에 daemon 이 다시 띄우지 않음. 5단계 재시작은 주로 4(a) 의 로스터 변경을 반영하기 위한 것.
  혹시 본인이 직접 `bridge-telegram-relay` 이름으로 systemd unit 을 만들었던 기억이 있으면 정리:
  $ systemctl --user status bridge-telegram-relay 2>/dev/null
  - 활성이면 stop + disable
  - 없으면 무시 (대부분의 install 은 여기 해당)
- 마이그레이션 실패 시 롤백: 업그레이드 전 버전으로 돌리지 말고, 우선 운영자(Sean)에게 보고. 문제 진단 후 후속 결정.

질문 있으면 작업 멈추고 운영자한테 escalate.
```

---

## Sean이 직접 점검할 사항 (프롬프트 보내기 전)

- 쭈쭈 호스트에서 `agent-bridge --version`이 PR3 포함된 버전인지 확인
- 쭈쭈 봇 토큰이 환경변수든 어디든 살아있는지 확인 (안 그러면 step 3에서 막힘)
- 쭈쭈 세션이 실제로 살아있는지 (`agent-bridge status` 또는 `tmux ls`로) — stopped 상태라면 먼저 복구

## 구조

- Sean: 위 프롬프트를 쭈쭈 admin 세션에 보냄 (인박스 task 또는 직접 send)
- 쭈쭈: 단계별 실행, 각 단계 결과 자체 audit
- 쭈쭈: 끝나면 `[migration-done] jjujju telegram official plugin` 제목으로 인박스 회신
- Sean: 회신 확인하고 끝

문제 있으면 쭈쭈가 escalate, Sean이 직접 개입. 자동화 없음.
