#!/usr/bin/env python3
"""Detect the live Claude session id for a workdir.

Extracted from `lib/bridge-state.sh::bridge_detect_claude_session_id` as
part of issue #827 fix. The bash wrapper previously inlined this body via
`python3 - <<'PY' ... PY` (heredoc-stdin). On Bash 5.3.9 that pattern can
wedge in `heredoc_write` when the wrapper is called inside a command
substitution `$(...)` and the surrounding shell was sourced from an
absolute path — the same heredoc-write class issue #815 / #800 closed in
the daemon and CLI hot paths. Moving the body into a real script removes
the heredoc read entirely.

Args (positional, order-sensitive):
    sys.argv[1] — workdir (will be `os.path.realpath`-resolved)
    sys.argv[2] — since_ms (integer string; "0" = no time gate)
    sys.argv[3] — exclude_csv (comma-separated session ids to skip)

Stdout: the detected session id, or empty string if none. Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    1. Walk `~/.claude/sessions/*.json`. For each record whose cwd matches
       the workdir realpath and whose sessionId is not in the exclude
       set, attempt to find a transcript file at:
         a. `~/.claude/projects/<workdir-slug>/<sid>.jsonl` (slash-only
            and slash+dot slugs both tried).
         b. Recursive `~/.claude/projects/**/<sid>.jsonl`.
       If no transcript file is found, apply the #827 live-pid fallback:
       accept the session id when `pid_is_alive(record.pid)` returns true
       (using the JSON's `pid` field, falling back to the filename stem).
       Dead-pid records with no transcript stay rejected.
    2. If no live-session match accepted, fall back to the freshest
       `~/.claude/projects/<workdir-slug>/*.jsonl` transcript (covers
       `continue=1` resume after a crash where sessions/<pid>.json was
       cleaned but the transcript remains).
"""

import glob
import json
import os
import re
import sys


def read_transcript_session_id(path: str):
    try:
        if os.path.getsize(path) <= 0:
            return None
        with open(path, "r", encoding="utf-8") as fh:
            seen = 0
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                seen += 1
                try:
                    obj = json.loads(line)
                except Exception:
                    if seen >= 10:
                        break
                    continue
                if isinstance(obj, dict):
                    found = obj.get("sessionId")
                    if found:
                        return found
                if seen >= 10:
                    break
    except Exception:
        return None
    return None


def workdir_slug_candidates(path: str):
    # Claude encodes the project dir by replacing "/" (always) and "."
    # (most versions) with "-". Accept both variants so older transcripts
    # still match.
    slash_only = path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", path)
    candidates = [slash_only]
    if slash_and_dot != slash_only:
        candidates.append(slash_and_dot)
    return candidates


def pid_is_alive(pid):
    # Issue #827: live-session acceptance hinges on this. Accept any pid
    # that responds to kill -0 without ESRCH. EPERM means the process
    # exists but is owned by another user — still alive.
    try:
        pid_int = int(pid)
    except (TypeError, ValueError):
        return False
    if pid_int <= 0:
        return False
    try:
        os.kill(pid_int, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def main() -> int:
    workdir = os.path.realpath(sys.argv[1])
    since_ms = int(sys.argv[2] or "0")
    if 0 < since_ms < 10**11:
        since_ms *= 1000
    exclude = {x for x in sys.argv[3].split(",") if x}
    best = None

    # Primary: live sessions/<pid>.json records.
    for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            continue
        sid = data.get("sessionId")
        cwd = os.path.realpath(str(data.get("cwd") or ""))
        started = int(data.get("startedAt") or 0)
        if cwd != workdir or not sid or sid in exclude:
            continue
        if since_ms and started < max(0, since_ms - 300000):
            continue
        transcript = None
        for slug in workdir_slug_candidates(workdir):
            candidate = os.path.expanduser(
                f"~/.claude/projects/{slug}/{sid}.jsonl"
            )
            if os.path.isfile(candidate):
                transcript = candidate
                break
        if transcript is None:
            for candidate in glob.glob(
                os.path.expanduser(f"~/.claude/projects/**/{sid}.jsonl"),
                recursive=True,
            ):
                if os.path.isfile(candidate):
                    transcript = candidate
                    break
        if transcript is None:
            # Issue #827: fresh Claude sessions create sessions/<pid>.json
            # before the transcript jsonl materializes. If the process is
            # still alive and the cwd matches, treat the session id as
            # live and accept it without waiting for transcript creation.
            # Dead-pid records remain rejected so stale session JSON files
            # cannot mask a missing transcript on a previously crashed
            # agent.
            pid = data.get("pid")
            if pid is None:
                try:
                    pid = int(
                        os.path.splitext(os.path.basename(path))[0]
                    )
                except (TypeError, ValueError):
                    pid = None
            if not pid_is_alive(pid):
                continue
        if best is None or started > best[0]:
            best = (started, sid)

    # Fallback: dead processes left behind a transcript but
    # sessions/<pid>.json has already been cleaned up. Pick the most
    # recent transcript in the agent's project dir so `continue=1` agents
    # can resume after a restart.
    if best is None:
        transcripts = []
        for slug in workdir_slug_candidates(workdir):
            transcripts.extend(
                glob.glob(
                    os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl")
                )
            )
        for transcript in transcripts:
            stem = os.path.splitext(os.path.basename(transcript))[0]
            if not stem or stem in exclude:
                continue
            try:
                mtime_ms = int(os.path.getmtime(transcript) * 1000)
            except Exception:
                continue
            if since_ms and mtime_ms < max(0, since_ms - 300000):
                continue
            # Filename is what `claude --resume` takes; trust it even if
            # the first-line sessionId disagrees (legacy transcripts may
            # lack it).
            read_transcript_session_id(transcript)
            if best is None or mtime_ms > best[0]:
                best = (mtime_ms, stem)

    print(best[1] if best else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
