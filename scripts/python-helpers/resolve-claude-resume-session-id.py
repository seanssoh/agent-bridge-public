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
    sys.argv[6] — claude_config_dir (optional, issue #1015): the agent's
        Claude config directory (`CLAUDE_CONFIG_DIR`). Isolation-v2 launches
        Claude with a custom HOME/CLAUDE_CONFIG_DIR, so the session JSON and
        transcripts live under `<agent-home>/.claude/`, not the daemon
        process's `~/.claude/`. When this argument is empty the resolver
        falls back to the `CLAUDE_CONFIG_DIR` env var, then `<HOME>/.claude`,
        then `os.path.expanduser("~/.claude")` — keeping the non-isolated
        path and existing call sites byte-for-byte unchanged.
    sys.argv[7] — trusted_id (optional, issue #1769): a session id the bash
        wrapper has vouched for via the short-TTL trusted-resume marker that
        `run_restart` writes after validating the live session it killed.
        When this equals the candidate, the live-session shortcut accepts the
        candidate even though its pid is now dead — repairing the #981
        re-inject for a freshly-started / idle session that had no eligible
        transcript yet. The marker is TTL-bounded and consumed bash-side, so
        this is additive (one id, one restart cycle) and never relaxes the
        freshness/quarantine gate for any other id. Empty = no trusted id,
        i.e. every pre-#1769 call site behaves byte-for-byte as before.

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
    records fall through to the transcript freshness path below — EXCEPT
    when the candidate equals the issue #1769 trusted_id (argv[7]), in
    which case the dead-pid record is accepted once (run_restart vouched
    for it pre-kill via the short-TTL trusted-resume marker).
"""

import glob
import json
import os
import re
import sys
import time


def workdir_slug_candidates(path: str):
    # Claude Code names its per-project transcript dir
    # (~/.claude/projects/<slug>/) by replacing characters in the cwd path
    # with "-". The exact set is version-dependent, so we emit several
    # candidates and let the caller pick whichever dir actually exists on
    # disk:
    #   slash_only    — "/" only (oldest behavior).
    #   slash_and_dot — "/" and "." (the documented design; preserves "_",
    #                   matching Claude Code versions after the #30828 fix).
    #   slash_dot_us  — "/", ".", and "_" (issue #1807): some shipped Claude
    #                   Code versions also map "_" → "-" (the #30828 bug,
    #                   confirmed live on cm-prod across a v0.16.9 restart:
    #                   ".../agents/test_clean/workdir" lands on disk as
    #                   "...-agents-test-clean-workdir"). Without this
    #                   candidate, any agent whose workdir contains "_" never
    #                   matched its real project dir → 0 transcripts → rc=1 →
    #                   fresh launch instead of --resume.
    # We deliberately do NOT add a greedy "all non-[a-zA-Z0-9-]" candidate:
    # agent workdir paths are bridge-controlled and only ever contain
    # alnum / "/" / "." / "_" / "-", and a broader slug risks colliding with
    # a different agent's project dir (candidates are tried in order, first
    # existing dir wins). De-dupe so identical slugs are not scanned twice.
    slash_only = path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", path)
    slash_dot_us = re.sub(r"[/._]", "-", path)
    candidates = []
    for slug in (slash_only, slash_and_dot, slash_dot_us):
        if slug not in candidates:
            candidates.append(slug)
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


def claude_config_root(explicit: str = "") -> str:
    """Resolve the Claude config root for the agent being resumed.

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


def eligible_transcripts(input_workdir, workdir, config_root, cutoff, exclude):
    """Return [(mtime, stem)] for every in-window transcript under the agent's
    project dir(s). A transcript is in-window iff its `.jsonl` exists, is a
    non-empty file, and its mtime is at/after `cutoff`. Stems already in
    `exclude` are skipped. Shared by the resolve path (which picks the freshest)
    and the `--list-resumable` enumeration (issue #1968) so both honour the
    identical slug + eligibility logic with no drift."""
    eligible = []
    seen_stems = set()
    for slug in ordered_slug_candidates([input_workdir, workdir]):
        base = os.path.join(config_root, "projects", slug)
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
    return eligible


def list_resumable(argv) -> int:
    """`--list-resumable` mode (issue #1968): print EVERY in-window transcript
    stem (session id) under the agent's project dir, one per line, newest
    first. No candidate / live-session / quarantine-swap logic — this is the
    enumeration `agb agent forget-session` uses to quarantine the agent's OWN
    transcripts so the resolver's most-recent-.jsonl fallback has nothing stale
    left to resume. Stdout: zero or more stems (newline-separated). Always rc 0
    (an empty workdir / missing project dir is "nothing to list", not an error).

    Args (after the `--list-resumable` flag):
        argv[0] — workdir
        argv[1] — max_age_hours (default 48)
        argv[2] — claude_config_dir (optional; same resolution as resolve mode)
    """
    if not argv:
        return 0
    input_workdir = argv[0]
    workdir = os.path.realpath(input_workdir)
    try:
        max_age_hours = float(argv[1]) if len(argv) > 1 else 48.0
    except ValueError:
        max_age_hours = 48.0
    config_root = claude_config_root(argv[2] if len(argv) > 2 else "")
    cutoff = time.time() - max_age_hours * 3600
    eligible = eligible_transcripts(
        input_workdir, workdir, config_root, cutoff, set()
    )
    eligible.sort(key=lambda t: t[0], reverse=True)
    for _mtime, stem in eligible:
        print(stem)
    return 0


def main() -> int:
    # Issue #1968: enumeration mode for forget-session. Kept as an explicit
    # leading flag so the positional resolve contract below is byte-for-byte
    # unchanged for every existing caller.
    if len(sys.argv) > 1 and sys.argv[1] == "--list-resumable":
        return list_resumable(sys.argv[2:])

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
    config_root = claude_config_root(
        sys.argv[6] if len(sys.argv) > 6 else ""
    )
    # Issue #1769: a session id the bash wrapper vouched for via the
    # short-TTL trusted-resume marker run_restart writes pre-kill. Only
    # honored when it equals the candidate (see live-session shortcut).
    trusted_id = (sys.argv[7] if len(sys.argv) > 7 else "") or ""

    cutoff = time.time() - max_age_hours * 3600

    # Issue #1769: when the candidate equals the trusted id the bash
    # wrapper supplied, accept it once even though its pid is now dead.
    # run_restart validated this exact id while the session was still
    # live and re-injected it across the kill; without this the post-kill
    # re-validation rejects a freshly-started / idle session (live-session
    # JSON only, no eligible transcript yet) and the agent launches fresh,
    # silently defeating #981. The marker is TTL-bounded and consumed
    # bash-side after the wrapper observes this rc=0, so the bypass is
    # one id / one restart cycle, not a standing relaxation of the gate.
    #
    # The trusted path relaxes ONLY the dead-pid / freshness rejection — it
    # never bypasses the #820 resume-quarantine set. A candidate the runner
    # quarantined (because `claude --resume` rejected it as "No conversation
    # found") must stay rejected even with a marker, so it falls through to
    # the normal logic below (rc=2 swap to a fresher non-quarantined id, or
    # rc=1). This is the accept-site half of the #1769 codex-r1 defense in
    # depth; the write-site (run_restart) independently refuses to vouch for
    # an id that is not the validated live session.
    if (
        candidate
        and trusted_id
        and candidate == trusted_id
        and candidate not in exclude
    ):
        print(candidate, end="")
        return 0

    # Issue #827: when the candidate id matches a live same-cwd
    # `~/.claude/sessions/<pid>.json` with an alive pid, accept it
    # without requiring a transcript. Fresh Claude sessions create the
    # session JSON before the transcript jsonl exists; rejecting them
    # strands AGENT_SESSION_ID until the first transcript write. Dead-pid
    # records remain ineligible and fall through to the transcript-based
    # path below.
    #
    # Issue #1769 (codex-r2): the shortcut is quarantine-aware. A
    # quarantined candidate must never resolve — live or not — because the
    # quarantine set exists precisely to stop resuming that id (the runner
    # added it after `claude --resume <id>` reported "No conversation
    # found"). Without this guard a quarantined-but-still-live session would
    # be accepted here (and, via the pre-kill `_write_if_live` validation,
    # would get a trusted-resume marker). Skipping the shortcut lets the
    # candidate fall through to the #820 quarantine branch below, which
    # resolves to the freshest non-quarantined transcript (rc=2) or rc=1.
    if candidate and candidate not in exclude:
        for session_path in glob.glob(
            os.path.join(config_root, "sessions", "*.json")
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

    eligible = eligible_transcripts(
        input_workdir, workdir, config_root, cutoff, exclude
    )

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
