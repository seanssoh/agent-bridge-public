#!/usr/bin/env python3
"""Inject per-plugin STATE_DIR env assignments into a Claude launch command.

Extracted from
`lib/bridge-state.sh::bridge_claude_launch_with_channel_state_dirs` as
part of issue #835 (Wave A). The previous in-line Python body was read
through bash stdin redirection; on Homebrew Bash 5.3.9 that read can
wedge in `heredoc_write` when the wrapper is invoked inside a command
substitution from an absolute-path-sourced shell — the same class that
closed #800 / #815 / #827 / #840 for the daemon, CLI, status, and
session-id hot paths. Living in a real script bypasses the bash read
entirely. (Forbidden pattern strings intentionally omitted from this
comment so the footgun #11 self-audit grep recipe does not flag a
textual mention as a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — original launch_cmd string (env prefix + `claude …`)
    sys.argv[2] — required_csv (comma-separated channel ids that
                  declare which STATE_DIR assignments are needed)
    sys.argv[3] — discord_dir
    sys.argv[4] — telegram_dir
    sys.argv[5] — teams_dir
    sys.argv[6] — ms365_dir
    sys.argv[7] — claude_home_dir
    sys.argv[8] — claude_config_dir

Stdout: launch_cmd with `<PLUGIN>_STATE_DIR=<dir>` env assignments
prepended (or replacing existing stale values in place, byte-preserving
for unrelated tokens). Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    Issue #771 v0.9.6 — the regen path correctly re-invokes this helper,
    but a frozen-roster LAUNCH_CMD with a stale `<NAME>=…` assignment
    would never be replaced because the legacy loop SKIPPED any name
    already present (regardless of value). Legacy v0.7→v0.8 isolated
    agents stayed broken indefinitely. v0.9.5 only exercised the fresh
    case in orbstack.

    Fix: regex-match each existing assignment by name and REPLACE its
    value with the canonical (live-computed) one. Idempotent in the
    fresh case (no match → append) and correct in the stale case
    (in-place replace). Quote-aware walker treats single-quoted,
    double-quoted, backslash-escaped, `$(…)`, backtick `…`, and `${…}`
    spans as opaque so whitespace inside any of these does NOT split
    the enclosing token (r2-r6 codex review on PR #776 / PR #790).
    Duplicate matching tokens collapse to one canonical assignment
    (r2 codex catch on PR #790); ONE leading whitespace char is
    stripped from the gap before each dropped duplicate so the
    dedupe artifact does not leave a multi-space run (r3 codex catch
    on PR #790, replacing a global multi-space collapse that would
    have mangled quoted values elsewhere).
"""

import re
import shlex
import sys


def _skip_dquote(s: str, i: int, n: int) -> int:
    # i points just AFTER opening `"`. Walks to closing `"` while
    # honoring backslash escapes and nested expansions (`$(…)`, `${…}`,
    # backticks). Returns index just AFTER the closing `"`.
    while i < n and s[i] != '"':
        c = s[i]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        else:
            i += 1
    if i < n:
        i += 1
    return i


def _skip_paren_subst(s: str, i: int, n: int) -> int:
    # i points just AFTER opening `$(`. Tracks nested `(` / `)` and
    # quote-state until depth returns to 0. Returns index just AFTER
    # the closing `)`. Whitespace and `=` inside a $(…) substitution
    # MUST NOT split the enclosing token, so the caller treats this
    # span as opaque. (codex r4 review on PR #776 — Probe 14.)
    #
    # r6 codex catch — also honor inner ${…} and `…` so a `)` that
    # belongs to a nested brace-default like `${UNSET:-) NAME=…}` or
    # to a backtick-substitution does NOT prematurely close our
    # paren depth.
    depth = 1
    while i < n and depth > 0:
        c = s[i]
        if c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and s[i] != "'":
                i += 1
            if i < n:
                i += 1
        elif c == '"':
            i = _skip_dquote(s, i + 1, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        elif c == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    return i


def _skip_backtick(s: str, i: int, n: int) -> int:
    # i points just AFTER opening backtick. Walks to next backtick;
    # legacy backticks don't nest natively (POSIX requires escape-pair
    # nesting), so honor backslash escapes only. Inner ${…} and $(…)
    # are NOT treated as nesting boundaries here — the next bare
    # backtick (or escaped pair) closes the span — but the quote-state
    # inside still suppresses any `=` matching at the outer walker
    # level (we never re-enter the walker until we return past the
    # closing backtick). (r6 — kept POSIX-conformant.)
    while i < n and s[i] != "`":
        if s[i] == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    if i < n:
        i += 1
    return i


def _skip_brace_subst(s: str, i: int, n: int) -> int:
    # i points just AFTER `${`. Walks to matching `}` honoring nested
    # braces, quotes, and inner $(…) / `…` substitutions. Param-
    # expansion defaults can contain whitespace and arbitrary inner
    # constructs (e.g. `${VAR:-$(echo NAME=fake)}` or
    # `${VAR:-some `echo X` default}`), so we must not let an inner
    # space, `}`, or `)` from a nested context split the enclosing
    # token. (r6 codex catch — symmetry with _skip_paren_subst.)
    depth = 1
    while i < n and depth > 0:
        c = s[i]
        if c == "{":
            depth += 1
            i += 1
        elif c == "}":
            depth -= 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and s[i] != "'":
                i += 1
            if i < n:
                i += 1
        elif c == '"':
            i = _skip_dquote(s, i + 1, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        elif c == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    return i


def _walk_top_level_tokens(s: str):
    # Yield (start, end) byte spans of each whitespace-delimited token
    # in `s`, treating single-quoted, double-quoted, backslash-escaped,
    # `$(…)`, backtick `…`, and `${…}` spans as opaque (so whitespace
    # inside any of these does NOT split the enclosing token).
    # Returning byte spans (not the token string) lets us preserve the
    # original bytes verbatim — critical for keeping bash expansions
    # like `$HOME`, `$(date)`, `${VAR:-x}` unquoted in unrelated
    # env-prefix assignments. (See codex r2/r3/r4 review on PR #776.)
    i, n = 0, len(s)
    while i < n:
        while i < n and s[i] in (" ", "\t"):
            i += 1
        if i >= n:
            return
        start = i
        while i < n and s[i] not in (" ", "\t"):
            c = s[i]
            if c == "'":
                i += 1
                while i < n and s[i] != "'":
                    i += 1
                if i < n:
                    i += 1
            elif c == '"':
                i = _skip_dquote(s, i + 1, n)
            elif c == "$" and i + 1 < n and s[i + 1] == "(":
                i = _skip_paren_subst(s, i + 2, n)
            elif c == "$" and i + 1 < n and s[i + 1] == "{":
                i = _skip_brace_subst(s, i + 2, n)
            elif c == "`":
                i = _skip_backtick(s, i + 1, n)
            elif c == "\\" and i + 1 < n:
                i += 2
            else:
                i += 1
        yield (start, i)


def normalize(raw: str) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values


def main() -> int:
    (
        original,
        required_csv,
        discord_dir,
        telegram_dir,
        teams_dir,
        ms365_dir,
        claude_home_dir,
        claude_config_dir,
    ) = sys.argv[1:9]

    required = normalize(required_csv)
    if not required:
        print(original)
        return 0

    match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
    if not match:
        print(original)
        return 0

    env_prefix = match.group("prefix")
    command = match.group("command")
    assignments: list[tuple[str, str]] = []

    if claude_home_dir:
        assignments.append(("HOME", claude_home_dir))
    if claude_config_dir:
        assignments.append(("CLAUDE_CONFIG_DIR", claude_config_dir))

    if any(
        item == "plugin:discord"
        or item.startswith("plugin:discord@")
        or item == "server:discord"
        for item in required
    ):
        assignments.append(("DISCORD_STATE_DIR", discord_dir))
    if any(
        item == "plugin:telegram"
        or item.startswith("plugin:telegram@")
        or item == "server:telegram"
        for item in required
    ):
        assignments.append(("TELEGRAM_STATE_DIR", telegram_dir))
    if any(
        item == "plugin:teams"
        or item.startswith("plugin:teams@")
        or item == "server:teams"
        for item in required
    ):
        assignments.append(("TEAMS_STATE_DIR", teams_dir))
    if any(
        item == "plugin:ms365"
        or item.startswith("plugin:ms365@")
        or item == "server:ms365"
        for item in required
    ):
        assignments.append(("MS365_STATE_DIR", ms365_dir))

    for name, value in assignments:
        # r4 codex review of #776 — preserve original byte form for tokens
        # we are NOT replacing. The r3 shlex.split + shlex.quote round-trip
        # destroyed unquoted shell expansions: `OTHER=$HOME` round-tripped
        # to `OTHER='$HOME'`, which bash then sees as the literal four-char
        # string `$HOME` instead of expanding. Walk the original env_prefix
        # in place, identify only the top-level tokens whose raw byte
        # prefix is `NAME=`, and substitute their span with the canonical
        # `NAME=<shlex.quote(value)>`. All other bytes (whitespace runs,
        # other assignments, their original quoting) pass through verbatim.
        #
        # r2 Probe 8 retained: ALL matching occurrences are replaced. Shell
        # eval is last-definition-wins, so a surviving duplicate after the
        # first replacement would re-overwrite the canonical value. Falling
        # through to append fires only when ZERO top-level matches found
        # (true fresh-setup case).
        #
        # r3 Probe 9 retained: quote-aware walker treats whitespace inside
        # `OTHER="x NAME=/fake"` as belonging to the OTHER token, so the
        # nested `NAME=/fake` substring is never matched at top level.
        quoted_value = shlex.quote(value)
        prefix_form = f"{name}="
        spans = [
            (s_, e_)
            for (s_, e_) in _walk_top_level_tokens(env_prefix)
            if env_prefix[s_:e_].startswith(prefix_form)
        ]
        if spans:
            # r2 codex catch on PR #790: replace the FIRST matching span
            # with canonical, drop all subsequent spans entirely. Otherwise
            # `NAME=/old1 NAME=/old2` produces two canonical entries
            # (`NAME=/new NAME=/new`) instead of collapsing to a single
            # final assignment. Even though shell eval is last-wins (so the
            # value would still be correct), duplicate exported assignments
            # are a code smell and surface in audit/logs as if multiple
            # stale values survived.
            #
            # r3 codex catch on PR #790: a global multi-space collapse
            # post-pass would also collapse multi-space runs INSIDE quoted
            # values elsewhere in env_prefix (e.g. `OTHER="a  b"` would be
            # mangled to `OTHER="a b"`). Instead, when dropping a duplicate
            # span, strip ONE leading whitespace character from the gap
            # between the previous token and the dropped span — this
            # collapses the dedupe artifact locally without touching any
            # other whitespace in env_prefix.
            pieces: list[str] = []
            last = 0
            first = True
            for s_, e_ in spans:
                if first:
                    # Keep the full gap before the first matching span,
                    # then emit the canonical assignment.
                    pieces.append(env_prefix[last:s_])
                    pieces.append(f"{name}={quoted_value}")
                    first = False
                else:
                    # Dropping this duplicate span: also drop ONE leading
                    # whitespace separator (space or tab) from the gap so
                    # the surrounding tokens collapse from "…  …" to "… …".
                    # Local to the drop site — does NOT touch spaces inside
                    # quoted values elsewhere in env_prefix.
                    gap = env_prefix[last:s_]
                    if gap and gap[0] in (" ", "\t"):
                        gap = gap[1:]
                    pieces.append(gap)
                last = e_
            pieces.append(env_prefix[last:])
            env_prefix = "".join(pieces)
            if env_prefix and not env_prefix.endswith((" ", "\t")):
                env_prefix += " "
        else:
            if env_prefix and not env_prefix.endswith((" ", "\t")):
                env_prefix += " "
            env_prefix += f"{name}={quoted_value} "

    print(f"{env_prefix}{command}" if env_prefix else command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
