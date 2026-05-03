#!/usr/bin/env python3
"""Shared Agent Bridge SessionStart hook.

Matcher handling (Track 2):
- Claude Code fires this hook with a `matcher` field when settings.json
  uses matcher-based entries. Known values: `startup`, `resume`, `clear`,
  `compact`.
- The hook reads the matcher from `--matcher` first, then a JSON payload
  on stdin (Claude Code hands `{"matcher": "compact", ...}` in via stdin).
- For `clear`, the hook auto-clears the agent's persisted AGENT_SESSION_ID
  so the next `bridge-run.sh <agent> --continue` does not resume the stale
  pre-clear session id (issue #314 Layer 1).
- For `compact`, the hook appends a short note telling the session that
  it just came out of a compaction, pointing at the raw capture store.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from bridge_hook_common import (
    bridge_state_dir,
    compact_recovery_context,
    remember_session_start,
    session_start_context,
)


_KNOWN_MATCHERS = {"startup", "resume", "clear", "compact"}
# Compaction typically fires the SessionStart hook once, but upstream may
# redeliver (retries, nested session-resumes). Suppress duplicate compact
# notes that arrive within this window so the note is emitted at most once
# per logical compact event.
_COMPACT_NOTE_DEDUP_SECONDS = 300


def _matcher_from_stdin() -> str:
    """Read the matcher value from a JSON payload on stdin (if present)."""
    if sys.stdin.isatty():
        return ""
    raw = sys.stdin.read() or ""
    if not raw.strip():
        return ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    return str(data.get("matcher") or data.get("source") or "").strip().lower()


def _compact_note() -> str:
    return (
        "\n\n---\n"
        "This session resumed from a compaction. Prior conversation content has been\n"
        "summarized automatically; recent capture notes may be available via\n"
        "`bridge-memory search --scope raw --query <keyword>`.\n"
    )


def _compact_note_marker(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "compact-note-last-ts"


def _compact_note_should_emit(agent: str, now_epoch: int | None = None) -> bool:
    """Return True iff we should emit the compact note for this invocation.

    The marker stores the epoch of the last emission. If the previous
    emission is within the dedup window we suppress; otherwise we update
    the marker and emit. This stops duplicate compact notes when the
    SessionStart hook is redelivered for the same underlying compact.
    """
    now_epoch = now_epoch or int(time.time())
    marker = _compact_note_marker(agent)
    try:
        previous = int(marker.read_text(encoding="utf-8").strip() or "0")
    except (OSError, ValueError):
        previous = 0
    if previous and now_epoch - previous < _COMPACT_NOTE_DEDUP_SECONDS:
        return False
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        tmp = marker.with_suffix(".tmp")
        tmp.write_text(f"{now_epoch}\n", encoding="utf-8")
        tmp.replace(marker)
    except OSError:
        # Failing to write the marker must not block the hook from
        # serving the session; worst case the dedup is a no-op.
        return True
    return True


def _forget_session_on_clear(agent: str) -> None:
    """Auto-forget the persisted resume id when /clear forks the session.

    Issue #314 Layer 1: when an operator runs /clear in a Claude session,
    the persisted AGENT_SESSION_ID still points at the pre-clear id. A
    later restart picks up the stale id and `claude --resume <stale>`
    lands on the context-saturated old session instead of the live forked
    one. Calling forget-session here keeps the persisted id in sync with
    what the operator actually has live.

    The CLI wrapper does the auditing and the lock dance; we just invoke
    it. Best-effort — the SessionStart hook has a 3s timeout and must
    never block the session, so we suppress all errors and fall back to
    the manual `agb agent forget-session <agent>` recovery path.
    """
    bridge_home = os.environ.get("BRIDGE_HOME") or os.path.expanduser("~/.agent-bridge")
    cli = os.path.join(bridge_home, "agent-bridge")
    if not os.path.isfile(cli):
        return
    try:
        subprocess.run(
            [cli, "agent", "forget-session", agent],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        # Best-effort: if forget-session fails for any reason, the manual
        # `agb agent forget-session <agent>` recovery path (PR #268) still
        # works.
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "codex"), default="text")
    parser.add_argument(
        "--matcher",
        default="",
        help="Claude Code matcher (startup|resume|clear|compact); overrides stdin payload",
    )
    args = parser.parse_args(argv)

    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent:
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    matcher = (args.matcher or _matcher_from_stdin()).lower()
    if matcher and matcher not in _KNOWN_MATCHERS:
        matcher = ""

    remember_session_start(agent)
    if matcher == "clear":
        _forget_session_on_clear(agent)
    context = session_start_context(agent)
    if matcher == "compact" and _compact_note_should_emit(agent):
        # #509 P3 (C3): re-inject canonical identity files BEFORE the queue
        # context so the model reads SOUL/MEMORY/etc before acting on any
        # post-compact queue prompt. The trailing `_compact_note()` is kept
        # as a debug marker pointing at the raw capture store.
        restored = compact_recovery_context(agent)
        parts: list[str] = []
        if restored:
            parts.append(restored)
        parts.append(context)
        parts.append(_compact_note().strip())
        context = "\n\n".join(parts)

    if args.format == "codex":
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "matcher": matcher or "startup",
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
