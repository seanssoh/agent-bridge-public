#!/usr/bin/env python3
"""Per-turn parallel-dispatch nudge for Claude Code (UserPromptSubmit).

Claude-engine only. Prints a hardcoded 1-2 line reminder that points at the
existing SSOT (COMMON-INSTRUCTIONS.md §"Background Subagent Delegation" /
§"Wave Orchestration") so the main session considers parallel Claude Agent
(run_in_background) dispatch for independent, non-conflicting work. It does
NOT duplicate the policy — it only reminds the session to consult it.

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
    "기준: COMMON-INSTRUCTIONS.md Background Subagent Delegation / Wave Orchestration."
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
