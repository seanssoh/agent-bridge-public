#!/usr/bin/env python3
"""Per-turn operating reminders for Claude Code (UserPromptSubmit).

Consolidated prompt operating-reminders hook (Claude-engine only). Prints short
hardcoded reminders that POINT at the COMMON-INSTRUCTIONS.md SSOT rather than
duplicating policy: (1) parallel-dispatch of independent, non-conflicting work
via Claude Agent(run_in_background) (§"Background Subagent Delegation" /
§"Wave Orchestration"), and (2) an early "starting" signal for a long-running
request so a channel-connected user is not left in silence (§"Long-running
작업"). The hook only reminds the session to make the judgment — it cannot
detect a task's duration up front, so this is a behavioral prompt, not a
guarantee.

Registered as a UserPromptSubmit `additionalContext` hook. No per-turn IO
beyond printing. Fail-open + idempotent + tiny: the body is wrapped in a broad
try/except that still exits 0, so it can never break a prompt.
"""

from __future__ import annotations

import sys

NUDGE = (
    "[병렬 점검] 독립 작업이 2개 이상이고 파일/상태 충돌이 없으면 "
    "Claude Agent(run_in_background)로 한 번에 병렬 위임을 검토한다. "
    "단일·순차·같은 파일/권한/승인 판단·1-2 command trivial 작업은 직접 처리한다. "
    "토큰 풀 공유, 불필요한 fan-out 금지. "
    "기준: COMMON-INSTRUCTIONS.md Background Subagent Delegation / Wave Orchestration.\n"
    "[응답 지연 방지] 오래 걸릴 요청(멀티스텝·서브에이전트·긴 빌드/리뷰, ~30초+)이고 "
    "사용자가 \"먼저 실행/무응답\"을 지시하지 않았다면 본작업 전 현재 사용자 채널에 "
    "한 줄 착수 신호를 보낸다. 즉답·trivial·정확한 선실행 지시는 바로 처리한다. "
    "기준: COMMON-INSTRUCTIONS.md Long-running 작업."
)


def main() -> int:
    try:
        sys.stdout.write(NUDGE)
        sys.stdout.write("\n")
    except Exception:
        # Fail-open: never break a prompt on a nudge-hook error.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
