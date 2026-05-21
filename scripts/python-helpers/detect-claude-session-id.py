#!/usr/bin/env python3
"""Detect the live Claude session id for a workdir.

Extracted from `lib/bridge-state.sh::bridge_detect_claude_session_id` as
part of issue #827 fix. The bash wrapper previously inlined this body via
a Python heredoc-stdin (forbidden pattern string omitted to keep this
docstring out of the footgun #11 self-audit grep). On Bash 5.3.9 that
pattern can wedge in `heredoc_write` when the wrapper is called inside
a command substitution `$(...)` and the surrounding shell was sourced
from an absolute path — the same heredoc-write class issue #815 / #800
closed in the daemon and CLI hot paths. Moving the body into a real
script removes
the heredoc read entirely.

Args (positional, order-sensitive):
    sys.argv[1] — workdir (will be `os.path.realpath`-resolved)
    sys.argv[2] — since_ms (integer string; "0" = no time gate)
    sys.argv[3] — exclude_csv (comma-separated session ids to skip)
    sys.argv[4] — claude_config_dir (optional, issue #1015): the agent's
        Claude config directory (`CLAUDE_CONFIG_DIR`). Isolation-v2 launches
        Claude with a custom HOME/CLAUDE_CONFIG_DIR, so the live session
        JSON and transcripts live under `<agent-home>/.claude/`, not the
        daemon process's `~/.claude/`. When empty the helper falls back to
        the `CLAUDE_CONFIG_DIR` env var, then `<HOME>/.claude`, then
        `os.path.expanduser("~/.claude")` — keeping the non-isolated path
        and existing call sites byte-for-byte unchanged.

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


def claude_config_root(explicit: str = "") -> str:
    """Resolve the Claude config root for the agent being detected.

    Priority (issue #1015): an explicit argument the bash shim passes >
    the `CLAUDE_CONFIG_DIR` env var > `<HOME>/.claude` > the ambient
    `~/.claude`. The last two preserve the pre-#1015 daemon-HOME behaviour
    for non-isolated agents and call sites that supply nothing.
    """
    if explicit:
        return explicit
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        return env_dir
    home = os.environ.get("HOME")
    if home:
        return os.path.join(home, ".claude")
    return os.path.expanduser("~/.claude")


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
    config_root = claude_config_root(
        sys.argv[4] if len(sys.argv) > 4 else ""
    )
    best = None

    # Primary: live sessions/<pid>.json records.
    for path in glob.glob(os.path.join(config_root, "sessions", "*.json")):
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
            candidate = os.path.join(
                config_root, "projects", slug, f"{sid}.jsonl"
            )
            if os.path.isfile(candidate):
                transcript = candidate
                break
        if transcript is None:
            for candidate in glob.glob(
                os.path.join(config_root, "projects", "**", f"{sid}.jsonl"),
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
                    os.path.join(config_root, "projects", slug, "*.jsonl")
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
