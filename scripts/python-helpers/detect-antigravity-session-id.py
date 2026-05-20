#!/usr/bin/env python3
"""Detect the most recent Antigravity (`agy`) conversation id for a workdir.

Backs `lib/bridge-state.sh::bridge_detect_antigravity_session_id` (Track A1
of the Antigravity engine wave). The bash wrapper invokes this body
file-as-argv rather than via a Python heredoc-stdin: on Bash 5.3.9 the
heredoc-stdin pattern can wedge in `heredoc_write` when the wrapper is
called inside a command substitution `$(...)` from a shell sourced via an
absolute path (the footgun #11 deadlock class — issues #815 / #800 /
#827). `bridge_detect_codex_session_id` still inlines its body that way;
this helper deliberately follows the safer file-as-argv shape of
`detect-claude-session-id.py` instead.

Args (positional, order-sensitive):
    sys.argv[1] — workdir (the agent workdir; `os.path.realpath`-resolved)
    sys.argv[2] — since_hint (epoch string; "0" = no time gate. Seconds or
                  milliseconds are both accepted — values > 10**11 are
                  treated as ms and divided down, mirroring
                  `bridge_detect_codex_session_id`.)
    sys.argv[3] — exclude_csv (comma-separated conversation ids to skip)
    sys.argv[4] — history_file (path to agy `history.jsonl`)
    sys.argv[5] — conversation_state_dir (path to agy `conversations/`)

Stdout: the detected conversation id, or empty string if none. Exits 0.

Behavior:
    agy records one JSON object per line in `history.jsonl`. Relevant
    fields (confirmed against a real ~/.gemini/antigravity-cli/history.jsonl
    on the host, 2026-05-21):
        display        — the prompt text (ignored here)
        timestamp      — int, epoch MILLISECONDS
        workspace      — absolute workdir the conversation ran in
        conversationId — UUID; present ONLY on entries that started a
                         persisted conversation (some entries lack it)
    Each conversationId maps to a `<id>.pb` protobuf file under
    `conversations/`. This helper:
      1. Walks every history entry whose `workspace` realpath matches the
         requested workdir, that carries a non-empty `conversationId` not
         in the exclude set, and (when since_hint is set) whose timestamp
         is within the time gate.
      2. Requires the conversation's `<id>.pb` to still exist on disk —
         a history row whose state file was deleted is not resumable.
      3. Returns the id with the freshest history timestamp.
"""

import json
import os
import sys


def to_epoch_seconds(raw: str) -> float:
    try:
        value = float(raw or "0")
    except ValueError:
        return 0.0
    # agy history timestamps are epoch ms; callers may also pass a seconds
    # hint. Anything above ~Mar-2001-in-ms is treated as ms (mirrors
    # bridge_detect_codex_session_id's `since_epoch > 10**11` guard).
    if value > 10**11:
        value /= 1000.0
    return value


def main() -> int:
    workdir = os.path.realpath(sys.argv[1])
    since_epoch = to_epoch_seconds(sys.argv[2] if len(sys.argv) > 2 else "0")
    exclude = {
        x for x in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if x
    }
    history_file = sys.argv[4] if len(sys.argv) > 4 else ""
    conversation_state_dir = sys.argv[5] if len(sys.argv) > 5 else ""

    best = None  # (timestamp_seconds, conversation_id)

    try:
        with open(history_file, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        print("")
        return 0

    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        cid = obj.get("conversationId")
        if not cid or cid in exclude:
            continue
        ws = obj.get("workspace")
        if not ws or os.path.realpath(str(ws)) != workdir:
            continue
        # history timestamp is epoch ms.
        ts = to_epoch_seconds(str(obj.get("timestamp") or "0"))
        # Time gate mirrors bridge_detect_codex_session_id: a 5-minute
        # grace window absorbs clock skew between the launch hint and the
        # conversation's recorded start.
        if since_epoch and ts < max(0.0, since_epoch - 300.0):
            continue
        # The conversation must still have its on-disk state file — a row
        # whose `<id>.pb` was pruned is not resumable.
        pb_path = os.path.join(conversation_state_dir, f"{cid}.pb")
        if not os.path.isfile(pb_path):
            continue
        if best is None or ts > best[0]:
            best = (ts, cid)

    print(best[1] if best else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
