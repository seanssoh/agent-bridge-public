# 쭈쭈(jjujju) 호스트 마이그레이션 프롬프트

**용도**: PR3(telegram-relay 폐기) 머지 후 쭈쭈 호스트에서 텔레그램 셋업을 공식 Claude Code 플러그인으로 되돌리기 위한 1회성 마이그레이션. Sean이 쭈쭈 admin/세션에 그대로 보내면 됩니다.

**전제 조건**: 쭈쭈 호스트에서 `agent-bridge upgrade --apply`를 먼저 실행해서 PR3가 포함된 버전(예상: v0.7.0+)으로 올라간 상태여야 합니다.

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

2. 현재 텔레그램 등록 상태 확인
   $ agent-bridge status | grep -i telegram
   $ ls ~/.agent-bridge/state/channels/telegram/ 2>/dev/null
   기존 relay 관련 socket/state 파일이 남아있는지 확인. 있으면 그대로 두고 다음 단계 진행 (4단계에서 정리됨).

3. 텔레그램 셋업 재실행 (공식 플러그인 모드로)
   $ agent-bridge setup telegram jjujju
   - 기존 봇 토큰 그대로 사용할지 물어보면 yes
   - --use-relay/--no-relay 같은 플래그는 PR3에서 제거됐으므로 안 쓰면 됨
   - 셋업 끝나면 너의 ~/.agent-bridge/agents/jjujju/.claude/settings.local.json의 enabledPlugins에 plugin:telegram@claude-plugins-official이 들어있어야 함

4. 환경변수/로스터 정리
   $ grep BRIDGE_TELEGRAM_RELAY ~/.agent-bridge/agent-roster.local.sh
   - 매치 있으면 해당 줄 삭제 (BRIDGE_TELEGRAM_RELAY_ENABLED, BRIDGE_TELEGRAM_RELAY_TOKEN 등 전부)
   - agent-roster.local.sh는 직접 편집 가능. 편집 후 다음 명령으로 검증:
     $ bash -n ~/.agent-bridge/agent-roster.local.sh

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
- 이전에 사용하던 systemd 유닛(있다면) 멈추기:
  $ systemctl --user status bridge-telegram-relay 2>/dev/null
  - 활성이면 stop + disable
  - 없으면 무시
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
