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
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from bridge_hook_common import (
    bridge_state_dir,
    compact_recovery_context,
    remember_session_start,
    session_start_context,
    under_isolated_uid,
    write_audit,
)

# Issue #597 Track B: schema for the completed-marker the daemon observer
# pairs with the started marker emitted by hooks/pre-compact.py. Bumped
# only when the layout changes in a way the observer needs to branch on.
_COMPLETED_MARKER_SCHEMA_VERSION = "1"


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


def _write_compact_completed_marker(agent: str, matcher: str) -> None:
    """Write a best-effort completion marker for the daemon observer.

    Issue #597 Track B. The daemon's `process_precompact_events` pairs this
    completion marker with the `started` marker that `hooks/pre-compact.py`
    wrote when compaction began so it can (a) send the operator a
    "back online" follow-up message and (b) update the per-agent EMA of
    compaction duration used to render the "I'll be back in ~Ns" notice.

    The hook stays exit-0 / non-blocking — every error is swallowed and the
    SessionStart contract is preserved.
    """
    try:
        completed_ts = int(time.time())
        completed_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
        hook_pid = os.getpid()
        # Marker filename uses <completed_ts>-<pid>.json so the observer can
        # process completions in chronological order without parsing JSON;
        # pid breaks ties on the unlikely same-second double-fire.
        target_dir = bridge_state_dir() / "precompact-events" / agent / "completed"
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
            marker_name = f"{completed_ts}-{hook_pid}.json"
            target = target_dir / marker_name
            marker = {
                "schema_version": _COMPLETED_MARKER_SCHEMA_VERSION,
                "agent": agent,
                "completed_ts": completed_ts,
                "completed_iso": completed_iso,
                "hook_pid": hook_pid,
                "matcher": matcher,
            }
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=str(target_dir),
                prefix=f".{marker_name}.",
                suffix=".tmp",
                delete=False,
            ) as fh:
                json.dump(marker, fh, ensure_ascii=False)
                fh.write("\n")
                fh.flush()
                try:
                    os.fsync(fh.fileno())
                except OSError:
                    pass
                tmp_path = fh.name
            os.replace(tmp_path, target)
        except (PermissionError, OSError) as exc:
            # Issue #1217 (beta27 Track E): under iso v2, the precompact
            # completed-marker dir lives under a controller-owned state
            # tree the isolated UID cannot mkdir into. Surface an audit
            # event so operators have telemetry on which marker writer
            # fell open; then return without dumping a traceback. Outside
            # iso, raise so the existing outer generic except keeps the
            # previous exit-0 contract (no observable behavior change for
            # the controller-side path).
            if under_isolated_uid():
                try:
                    write_audit(
                        "hook_permission_fail_open.session_start.completed_marker",
                        str(target_dir),
                        {
                            "operation": "mkdir_or_replace",
                            "error_class": type(exc).__name__,
                        },
                    )
                except Exception:  # noqa: BLE001 — best-effort audit
                    pass
                return
            raise
    except Exception:
        # Hook stays exit-0; missing marker just means no follow-up gets sent.
        pass


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
        # Issue #597 Track B: leave a completion marker for the daemon
        # observer BEFORE doing the (synchronous) canonical recovery work
        # below. The marker write is best-effort — if the state dir is not
        # writable, the daemon simply won't send a follow-up and compaction
        # behavior is unchanged.
        _write_compact_completed_marker(agent, matcher)

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
        # Codex 0.133.0's SessionStartHookSpecificOutputWire is
        # `deny_unknown_fields` / `additionalProperties: false` and accepts
        # only `hookEventName` + `additionalContext`. Emitting `matcher`
        # made `parse_session_start` reject the object, failing the
        # SessionStart hook on every codex agent (issue #1055). `matcher`
        # is still read from stdin above for internal behavior; it just
        # must not be echoed in the Codex output object.
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
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
