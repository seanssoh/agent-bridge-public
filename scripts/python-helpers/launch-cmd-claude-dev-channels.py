#!/usr/bin/env python3
"""Merge required development channel ids into a Claude launch command.

Extracted from
`lib/bridge-state.sh::bridge_claude_launch_with_development_channels` as
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
    sys.argv[2] — required_csv (comma-separated dev-channel specs to
                  ensure)

Stdout: rewritten launch_cmd with each required dev-channel passed as a
distinct `--dangerously-load-development-channels <spec>` pair.
Existing whitespace-form and `=`-form tokens (including multi-value
whitespace form, e.g. `--dangerously-load-development-channels a b c`)
are absorbed and re-emitted in canonical, de-duplicated order. Always
exits 0.
"""

import re
import shlex
import sys


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
    original, required_csv = sys.argv[1], sys.argv[2]

    required = normalize(required_csv)
    if not required:
        print(original)
        return 0

    match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
    if not match:
        print(original)
        return 0

    env_prefix = match.group("prefix")
    args = shlex.split(match.group("command"))
    if not args or args[0] != "claude":
        print(original)
        return 0

    rest = args[1:]
    existing: list[str] = []
    filtered: list[str] = []
    i = 0
    while i < len(rest):
        token = rest[i]
        if token == "--dangerously-load-development-channels":
            i += 1
            while i < len(rest) and not rest[i].startswith("-"):
                existing.extend(normalize(rest[i]))
                i += 1
            continue
        if token.startswith("--dangerously-load-development-channels="):
            existing.extend(normalize(token.split("=", 1)[1]))
            i += 1
            continue
        filtered.append(token)
        i += 1

    merged: list[str] = []
    seen: set[str] = set()
    for item in [*existing, *required]:
        if item in seen:
            continue
        seen.add(item)
        merged.append(item)

    rebuilt = ["claude", *filtered]
    for item in merged:
        rebuilt.extend(["--dangerously-load-development-channels", item])

    quoted = " ".join(shlex.quote(token) for token in rebuilt)
    print(f"{env_prefix}{quoted}" if env_prefix else quoted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
