# Upgrading Agent Bridge

이 문서는 모든 install 에서 동일하게 따라야 하는 표준 upgrade 절차를 정의한다. 각 host 의 설치 방식이 약간씩 달라도 (canonical `~/.agent-bridge` 만 있는 host vs source-checkout `~/.agent-bridge-source` 가 추가로 있는 admin host), upgrade 자체는 같은 명령으로 끝난다.

## TL;DR

```bash
~/.agent-bridge/agent-bridge upgrade --dry-run    # 미리보기
~/.agent-bridge/agent-bridge upgrade --apply      # 실제 적용
```

`--apply` 한 번에 다음이 자동으로 일어난다:

- daemon stop → 새 source 복사 → daemon restart → 영향받는 agent 재기동.
- shared Claude settings 재렌더 (`autoCompactWindow:400000` 등 managed default 가 모든 Claude agent 에 propagate).
- shared hooks 재등록 (Stop / SessionStart / UserPromptSubmit / PromptGuard / ToolPolicy 가 새 release 의 entry 로 갱신).
- `_template/CLAUDE.md` managed block 이 모든 agent 의 `CLAUDE.md` 에 sync.
- admin agent 한테 `[upgrade-complete]` queue task 자동 등록 (`OPERATOR_ACTIONS_PENDING.md` reference 포함).

`upgrade --apply` 자체가 atomic 명령이다. 어떤 문서나 메모가 "stop → upgrade → verify"를 분리된 단계로 보여줘도 그 sequence 를 만들지 말 것 (이슈 #314, #315).

## 사전 조건

- Bash 4 이상 (macOS 는 `brew install bash` 후 PATH 우선 설정).
- `tmux`, `python3`, `git`.
- network access to GitHub (default channel `stable` 또는 `dev` 가져옴).

## 표준 procedure (모든 host 공통)

### 1. 사전 점검

```bash
~/.agent-bridge/agent-bridge version --json
~/.agent-bridge/agent-bridge daemon status
~/.agent-bridge/agent-bridge status
```

- 현재 VERSION 기록.
- daemon 이 살아있고 모든 agent 가 정상 상태인지 확인. 비정상 agent 가 있으면 먼저 그쪽 정리 (또는 의도적으로 두고 진행).

### 2. dry-run

```bash
~/.agent-bridge/agent-bridge upgrade --dry-run
```

- 어떤 파일이 추가/갱신될지 (`added_files`, `updated_files`) 미리 보여줌.
- 충돌 (operator 가 직접 수정한 파일과 새 source 가 충돌) 이 있으면 stderr 로 경고. 해결 후 다시 진행.

### 3. apply

```bash
~/.agent-bridge/agent-bridge upgrade --apply
```

- 위의 자동 단계가 atomic 으로 실행됨.
- 출력의 마지막 부분에서 다음 필드 확인:
  - `from_version` → `to_version` (의도한 버전인지)
  - `migrated_files`, `agents_migrated` (count 가 합리적인지)
  - `agent_restart_skipped` 가 0 인지
  - `shared_settings_rerender: <count> target(s) (apply), failed=0`
  - `source_reclassify: <count> candidate(s) (apply)` (있으면)

### 4. 사후 점검

```bash
cat ~/.agent-bridge/VERSION                       # 새 버전 매치
~/.agent-bridge/agent-bridge daemon status        # daemon healthy
~/.agent-bridge/agent-bridge status --json        # plugin liveness, agent state
~/.agent-bridge/agb inbox <admin-agent>           # [upgrade-complete] task 확인
```

`[upgrade-complete]` task body 가 `OPERATOR_ACTIONS_PENDING.md` 의 처리 절차를 안내한다. 각 release section 의 `applies_when_upgrading_from` 범위가 직전 설치 버전을 포함하면 그 section 을 처리한다 (또는 "skip if" 조건과 일치하면 skip).

### 5. 변형 — admin 호스트 (source-checkout 보유)

`~/.agent-bridge-source/` 가 있는 admin 호스트는 같은 명령으로 동작한다. upgrader 가 source-checkout 위치를 자동 감지한다 (`AGENT_BRIDGE_SOURCE_DIR` 환경변수 또는 default `~/.agent-bridge-source`).

source-checkout 이 비표준 위치에 있으면:

```bash
AGENT_BRIDGE_SOURCE_DIR=/path/to/source ~/.agent-bridge/agent-bridge upgrade --apply
```

또는 `--source` 인자:

```bash
~/.agent-bridge/agent-bridge upgrade --apply --source /path/to/source
```

## Update guide for new operators

처음 install 한 host 도 위와 같은 명령으로 upgrade 한다. install 방식 차이 (homebrew 설치 vs git clone vs `bootstrap.sh` 사용) 와 무관하게 `~/.agent-bridge/agent-bridge upgrade --apply` 가 표준 진입점이다.

source 가져오는 채널 (`stable`/`dev`/`current`) 을 명시적으로 고를 수 있다:

```bash
~/.agent-bridge/agent-bridge upgrade --apply --channel stable
```

## Troubleshooting

### "stale `AGENT_SESSION_ID` cascade"

`upgrade --apply` 이전에 `bash bridge-daemon.sh stop` 또는 `agb daemon stop` 을 분리 실행하면 발생할 수 있다. 그렇게 하지 않는다 — `upgrade --apply` 가 daemon 을 내부적으로 stop/start 한다.

### `--apply` 실패

network, source-checkout drift, 중간 abort 등으로 실패하면 daemon 을 수동 stop 하지 말고 공유 외부 채널로 사람 operator 에게 보고한다. manual daemon-stop 은 표준 경로의 일부가 아니라 recovery action 이며, 실패를 본 operator 의 명시적 승인 후에만 사용한다.

### Rollback

```bash
~/.agent-bridge/agent-bridge upgrade rollback
```

직전 upgrade 의 backup 으로 되돌린다. backup 위치는 `~/.agent-bridge/state/upgrade-backups/<stamp>/`.

### Conflict files

`upgrade --apply` 이 operator 가 직접 수정한 파일을 만나면 `*.upgrade-conflict` sidecar 를 만들고 새 source 를 적용한다. operator 가 직접 수정한 내용을 보려면 conflict file 을 비교 후 필요한 변경을 main file 에 다시 적용한다 (또는 backup 에서 복원).

### Daemon 재기동 안 됨

`upgrade --apply` 후 daemon 이 안 떠있으면:

```bash
pgrep -af 'bridge-daemon\.sh run$'      # Linux
~/.agent-bridge/agent-bridge daemon status   # OS 무관
```

상태 확인 후 `~/.agent-bridge/agent-bridge daemon start` 또는 LaunchAgent / systemd unit 의 명시적 재기동.

## Release-specific actions

매 release 가 ship 하는 검증 후속 행동은 source root 의 [`OPERATOR_ACTIONS_PENDING.md`](OPERATOR_ACTIONS_PENDING.md) 에 모인다. `upgrade --apply` 가 자동 등록한 `[upgrade-complete]` task 의 body 가 이 파일을 reference 한다. 매 release section 마다:

- `applies_when_upgrading_from`: 직전 설치 버전이 이 범위에 들면 처리.
- `### Action`: 실제 명령 + 검증.
- `### Skip if`: skip 조건 (대부분 release 가 여기에 해당).

처리 결과는 `[upgrade-complete]` done note 의 `operator-actions: <summary>` 에 한 줄 요약.

## Reference

- [`OPERATIONS.md`](OPERATIONS.md) — 일상 운영 runbook.
- [`OPERATOR_ACTIONS_PENDING.md`](OPERATOR_ACTIONS_PENDING.md) — release-specific 후속 행동 catalog.
- [`docs/agent-runtime/admin-protocol.md`](docs/agent-runtime/admin-protocol.md) — admin agent 의 upgrade-time 책임 (Post-Upgrade Operator Actions Pending / Issue Triage / Workaround Reconciliation 섹션).
- `~/.agent-bridge/state/upgrade-backups/<stamp>/` — backup 위치.
- `~/.agent-bridge/state/bootstrap-memory/report-*.json` — 가장 최근 bootstrap 리포트.
