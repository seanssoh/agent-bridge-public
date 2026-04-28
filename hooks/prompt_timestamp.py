#!/usr/bin/env python3
"""Inject per-turn timestamp context for Claude Code and Codex."""

from __future__ import annotations

import argparse
import json
import os
import sys

from bridge_hook_common import (
    agent_timestamp_enabled,
    next_session_required_prompt_context,
    prompt_timestamp_context,
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "codex"), default="text")
    args = parser.parse_args(argv)

    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent or not agent_timestamp_enabled(agent):
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    handoff_context = next_session_required_prompt_context(agent)
    timestamp_context = prompt_timestamp_context(agent)
    context = f"{handoff_context}\n{timestamp_context}" if handoff_context else timestamp_context
    if args.format == "codex":
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": context,
                }
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(context)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
