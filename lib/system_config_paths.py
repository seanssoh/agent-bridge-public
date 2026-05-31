#!/usr/bin/env python3
"""Single source of truth for system-config protected paths (issue #341).

The PreToolUse hook (`hooks/tool-policy.py`) and the `agent-bridge config`
wrapper (`bridge-config.py`) both consult this module to decide whether a
given path is "system config" and therefore blocked for direct Edit/Write
mutation. New protected paths land here; both surfaces pick them up.

Path patterns are expressed as fnmatch globs anchored to BRIDGE_HOME.  We
intentionally do not collapse them into regexes: globs are easier to audit
when the operator extends the list, and the matcher already runs against
both literal and resolved forms so symlink games do not bypass the gate.

Hook-side denial vs wrapper-side denial differ in *what* they block:

- The hook always denies an Edit/Write tool call to a protected path,
  regardless of which agent is making the call. The denial points the
  agent at the wrapper. This is the line-of-defence the issue's drift
  case study (4 agents' access.json silently mutated) needs.
- The wrapper layers caller-agent + caller-source on top. Even an admin
  agent can only mutate when the call comes from operator-attached TUI
  or a trusted-id-match channel surface.

Tests under `tests/system-config-gating/` exercise both paths.
"""

from __future__ import annotations

import fnmatch
import os
from pathlib import Path


def _glob_matches(relative: str, pattern: str) -> bool:
    """Segment-aware glob match: a `*` matches within ONE path segment.

    `fnmatch.fnmatchcase` treats `*` as "any run of chars INCLUDING `/`", so
    a pattern like ``data/agents/*/workdir/.discord/access.json`` would also
    match a deeper path such as
    ``data/agents/<a>/nested/workdir/.discord/access.json`` — widening the
    protected set beyond the intended per-agent slot (issue #1442 codex r1).
    We match segment-by-segment instead so each `*` is bounded by `/`,
    exactly the "any direct child" semantics the glob list documents. A
    pattern and a path only match when they have the same number of
    segments and every segment pair matches under `fnmatch.fnmatchcase`.
    """
    rel_parts = relative.split("/")
    pat_parts = pattern.split("/")
    if len(rel_parts) != len(pat_parts):
        return False
    return all(
        fnmatch.fnmatchcase(rel_seg, pat_seg)
        for rel_seg, pat_seg in zip(rel_parts, pat_parts)
    )


# The canonical glob list. Each pattern is matched against the path made
# relative to BRIDGE_HOME. `agents/*/...` means "any direct child agent".
# This is the list called out in issue #341 §"Protected paths".
#
# Per-agent channel-access globs are listed for BOTH layouts (issue #1442):
#   - pre-v2  : `agents/<agent>/.discord/access.json`
#   - v2      : `data/agents/<agent>/workdir/.discord/access.json`
# On a v2 install the live per-agent `.discord/`/`.telegram/` trees the
# channel relays read/write live under `data/agents/<agent>/workdir/`
# (BRIDGE_AGENT_ROOT_V2 = $BRIDGE_DATA_ROOT/agents = $BRIDGE_HOME/data/agents;
# the workspace layer is `<agent>/workdir`, see lib/bridge-agent-layout.sh).
# The pre-v2 globs never matched that path, so the #341 operator-gated
# `config get/set` wrapper denied every per-agent access.json edit on v2.
# Both forms are kept so legacy and mixed installs continue to match.
PROTECTED_GLOBS: tuple[str, ...] = (
    "agents/*/.discord/access.json",
    "agents/*/.telegram/access.json",
    "data/agents/*/workdir/.discord/access.json",
    "data/agents/*/workdir/.telegram/access.json",
    "agent-roster.local.sh",
    "cron/jobs.json",
    "runtime/openclaw.json",
    "runtime/bridge-config.json",
    "state/cron/*.json",
    "hooks/*",
)


def bridge_home_dir() -> Path:
    """Mirror of bridge_hook_common.bridge_home_dir() for in-tree use.

    Duplicated here so this module has zero imports from `hooks/`; the
    wrapper (`bridge-config.py`) lives at the repo root and would otherwise
    have to set sys.path before importing.
    """
    explicit = os.environ.get("BRIDGE_HOME", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".agent-bridge"


def _candidate_relatives(path: Path, home: Path) -> list[str]:
    """Return BRIDGE_HOME-relative path strings to compare against globs.

    Includes both the literal path and `path.resolve()` so a symlink that
    points at a protected file is matched. `relative_to` failure on either
    leg is silently dropped — the caller treats no-match as "not protected".
    """
    candidates: list[Path] = [path, path.expanduser()]
    try:
        candidates.append(path.expanduser().resolve())
    except OSError:
        pass

    relatives: list[str] = []
    home_resolved: Path
    try:
        home_resolved = home.resolve()
    except OSError:
        home_resolved = home
    for candidate in candidates:
        for root in (home, home_resolved):
            try:
                rel = candidate.relative_to(root)
            except (ValueError, OSError):
                continue
            relatives.append(str(rel))
    return relatives


def is_protected_path(path: Path) -> bool:
    """Return True when *path* falls inside the protected system-config list.

    Used by both the PreToolUse hook and the wrapper; the wrapper wraps
    its own additional caller checks around this call.
    """
    home = bridge_home_dir()
    for relative in _candidate_relatives(path, home):
        for pattern in PROTECTED_GLOBS:
            if _glob_matches(relative, pattern):
                return True
    return False


def matched_pattern(path: Path) -> str | None:
    """Return the protected glob *path* matches, or None.

    Convenience helper for audit detail — the caller logs which glob fired
    so the operator can see whether the gate is over- or under-reaching.
    """
    home = bridge_home_dir()
    for relative in _candidate_relatives(path, home):
        for pattern in PROTECTED_GLOBS:
            if _glob_matches(relative, pattern):
                return pattern
    return None


def protected_literal_suffixes() -> tuple[str, ...]:
    """Return literal substrings derived from PROTECTED_GLOBS that uniquely
    identify a protected path inside a free-form command string.

    Used by `hooks/tool-policy.py` as its degraded substring-scan fallback
    when ``shlex.split`` rejects a command (unbalanced quotes etc.). For
    each glob we pick the longest literal segment between wildcards (or
    the whole pattern when there is no wildcard) and strip leading slashes
    so the needle matches whether the command quoted the absolute or
    relative form.

    Examples (matching ``PROTECTED_GLOBS`` at the top of this file):

    - ``agents/*/.discord/access.json`` → ``.discord/access.json``
    - ``state/cron/*.json``             → ``state/cron/``
    - ``hooks/*``                       → ``hooks/``
    - ``agent-roster.local.sh``         → ``agent-roster.local.sh``

    The returned tuple is the single source of truth for that fallback —
    do not maintain a parallel list anywhere else (codex r1 #341 CP1).
    """
    suffixes: list[str] = []
    seen: set[str] = set()
    for pattern in PROTECTED_GLOBS:
        if "*" in pattern:
            # Pick the longest literal segment between (or around) `*`s.
            segments = [seg for seg in pattern.split("*") if seg]
            if not segments:
                continue
            needle = max(segments, key=len)
        else:
            needle = pattern
        # Drop a leading slash so the needle matches both the absolute
        # form (`/a/b/c`) and the relative form (`a/b/c`) of the path.
        if needle.startswith("/"):
            needle = needle[1:]
        if needle and needle not in seen:
            seen.add(needle)
            suffixes.append(needle)
    return tuple(suffixes)
