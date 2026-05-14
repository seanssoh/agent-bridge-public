#!/usr/bin/env python3
"""Resolve the Claude resume session id for a workdir + candidate.

Extracted from `lib/bridge-state.sh::bridge_resolve_resume_session_id` as
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
    sys.argv[1] — workdir (passed through `os.path.realpath`)
    sys.argv[2] — candidate session id (may be empty)
    sys.argv[3] — max_age_hours (float string; default 48)
    sys.argv[4] — agent name (debug-only)
    sys.argv[5] — exclude_csv: comma-separated session ids that the caller
        wants filtered out (issue #820 / v0.11.0 Issue 2 quarantine). Stems
        in this set are skipped during fs-scan; a candidate that matches an
        entry is treated as quarantined and resolves to the freshest other
        eligible transcript (rc=2) instead of being accepted as-is.

Stdout: accepted session id, or empty when there is nothing to resume.
Exit code:
    0 = candidate accepted as-is (or empty candidate resolved to
        freshest eligible transcript)
    1 = no eligible transcript and no live-session match — caller MUST
        NOT issue --resume / --continue with the candidate id
    2 = candidate ineligible/stale but a fresher in-window transcript
        exists; that fresher id is on stdout

Issue #827 live-session shortcut (preserved here):
    If the candidate matches a live same-cwd
    `~/.claude/sessions/<pid>.json` record with an alive pid, accept it
    and exit 0 immediately — fresh Claude sessions create the session
    JSON before the transcript jsonl exists; rejecting that id would
    strand `AGENT_SESSION_ID` until the first transcript write. Dead-pid
    records fall through to the transcript freshness path below.
"""

import glob
import json
import os
import re
import sys
import time


def workdir_slug_candidates(path: str):
    slash_only = path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", path)
    candidates = [slash_only]
    if slash_and_dot != slash_only:
        candidates.append(slash_and_dot)
    return candidates


def ordered_slug_candidates(paths):
    candidates = []
    seen = set()
    for path in paths:
        for slug in workdir_slug_candidates(path):
            if slug not in seen:
                seen.add(slug)
                candidates.append(slug)
    return candidates


def pid_is_alive(pid):
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
    input_workdir = sys.argv[1]
    workdir = os.path.realpath(input_workdir)
    candidate = sys.argv[2] or ""
    try:
        max_age_hours = float(sys.argv[3])
    except ValueError:
        max_age_hours = 48.0
    agent = sys.argv[4] or ""
    exclude = {
        x
        for x in (sys.argv[5] if len(sys.argv) > 5 else "").split(",")
        if x
    }

    cutoff = time.time() - max_age_hours * 3600

    # Issue #827: when the candidate id matches a live same-cwd
    # `~/.claude/sessions/<pid>.json` with an alive pid, accept it
    # without requiring a transcript. Fresh Claude sessions create the
    # session JSON before the transcript jsonl exists; rejecting them
    # strands AGENT_SESSION_ID until the first transcript write. Dead-pid
    # records remain ineligible and fall through to the transcript-based
    # path below.
    if candidate:
        for session_path in glob.glob(
            os.path.expanduser("~/.claude/sessions/*.json")
        ):
            try:
                with open(session_path, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception:
                continue
            sid = data.get("sessionId")
            if sid != candidate:
                continue
            record_cwd = os.path.realpath(str(data.get("cwd") or ""))
            if record_cwd != workdir:
                continue
            pid = data.get("pid")
            if pid is None:
                try:
                    pid = int(
                        os.path.splitext(os.path.basename(session_path))[0]
                    )
                except (TypeError, ValueError):
                    pid = None
            if not pid_is_alive(pid):
                continue
            print(candidate, end="")
            return 0

    eligible = []
    seen_stems = set()
    for slug in ordered_slug_candidates([input_workdir, workdir]):
        base = os.path.expanduser(f"~/.claude/projects/{slug}")
        if not os.path.isdir(base):
            continue
        try:
            entries = os.listdir(base)
        except OSError:
            continue
        for entry in entries:
            if not entry.endswith(".jsonl"):
                continue
            stem = entry[: -len(".jsonl")]
            if not stem or stem in seen_stems or stem in exclude:
                continue
            full = os.path.join(base, entry)
            try:
                st = os.stat(full)
            except OSError:
                continue
            if not os.path.isfile(full) or st.st_size <= 0:
                continue
            if st.st_mtime < cutoff:
                continue
            seen_stems.add(stem)
            eligible.append((st.st_mtime, stem))

    if not eligible:
        sys.stderr.write(
            f"[debug] resume id rejected: no eligible transcript within "
            f"{max_age_hours}h for workdir={workdir} agent={agent}\n"
        )
        return 1

    eligible.sort(key=lambda t: t[0], reverse=True)
    freshest_stem = eligible[0][1]

    # Issue #820: a candidate explicitly in the quarantine set must not be
    # accepted even if it would otherwise be the freshest. Resolve to the
    # freshest non-quarantined stem (rc=2) so the caller knows to swap.
    if candidate and candidate in exclude:
        sys.stderr.write(
            f"[debug] resume id quarantined: candidate={candidate} "
            f"freshest={freshest_stem} workdir={workdir} agent={agent}\n"
        )
        print(freshest_stem, end="")
        return 2

    if candidate and candidate == freshest_stem:
        print(candidate, end="")
        return 0

    if candidate:
        sys.stderr.write(
            f"[debug] resume id replaced: candidate={candidate} "
            f"freshest={freshest_stem} workdir={workdir} agent={agent}\n"
        )
        print(freshest_stem, end="")
        return 2

    # Empty candidate: freshest eligible is just an acceptance, not a
    # replacement.
    print(freshest_stem, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
