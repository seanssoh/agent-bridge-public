#!/usr/bin/env python3
"""PreToolUse hard-ban for AskUserQuestion (#1923).

Tiny, standalone, dependency-free deny hook. It exists so that **dynamic
vanilla** Claude agents — which inherit the operator-global `~/.claude` and
receive only the bridge comms hooks in `<workdir>/.claude/settings.local.json`
(#1890), NOT the `tool-policy.py` governance hook — still have a guaranteed
mechanism that blocks the blocking `AskUserQuestion` picker.

Why a dedicated hook and not `tool-policy.py` / `askuserquestion_escalate.py`:
- vanilla agents are "comms hooks only"; pulling in the full tool-policy
  governance surface would break the #1890 contract, and the #1569 channel-
  escalation wait path is heavier than the hard ban the operator asked for.
- a **PreToolUse hook returning `permissionDecision: "deny"`** is the only
  mechanism that survives `--dangerously-skip-permissions` (bypassPermissions):
  Claude Code runs PreToolUse hooks *before* the permission-prompt system, so
  the deny still fires when permission prompts are disabled (#1923 root cause).

Contract (matches `tool-policy.py` `pretool_block_response`):
- read the PreToolUse JSON payload from stdin;
- if `tool_name` is not `AskUserQuestion`, exit 0 with no output;
- if it IS, print the structured deny JSON and exit 0. We do NOT use exit 2 —
  Claude Code ignores JSON output when a hook exits 2, and the structured
  `permissionDecision: deny` shape is what carries the "ask in plain text"
  guidance back to the agent.

No imports beyond the stdlib; never raises out (a hook crash must not wedge a
session) — on any unexpected error it exits 0 silently (fail-open), exactly
like the bound-AskUserQuestion fallback in tool-policy.py never hangs.
"""

import json
import sys

_BAN_REASON = (
    "AskUserQuestion is disabled for Agent Bridge agents. Ask the question in "
    "plain text in your normal reply or queue/task note; do not call "
    "AskUserQuestion."
)


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (ValueError, TypeError):
        # Malformed payload — we cannot positively identify the tool, so do
        # NOT block (fail-open). tool-policy.py / the scoped deny remain in
        # play for hook-managed agents.
        return 0

    if not isinstance(payload, dict):
        return 0

    if str(payload.get("tool_name") or "") != "AskUserQuestion":
        return 0

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": _BAN_REASON,
                "additionalContext": _BAN_REASON,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — a hook crash must never wedge a session; fail-open.
        sys.exit(0)
