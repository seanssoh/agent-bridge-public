#!/usr/bin/env python3
"""Build the safe-mode Claude launch command (channels + dev-channels stripped).

Extracted from
`lib/bridge-state.sh::bridge_build_safe_claude_launch_cmd` as part of
issue #835 (Wave A). The previous in-line Python body was read through
bash stdin redirection; on Homebrew Bash 5.3.9 that read can wedge in
`heredoc_write` when the wrapper is invoked inside a command
substitution from an absolute-path-sourced shell — the same class that
closed #800 / #815 / #827 / #840 for the daemon, CLI, status, and
session-id hot paths. Living in a real script bypasses the bash read
entirely. (Forbidden pattern strings intentionally omitted from this
comment so the footgun #11 self-audit grep recipe does not flag a
textual mention as a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — agent name (becomes `--name <agent>`)
    sys.argv[2] — continue_mode ("1" or "0")
    sys.argv[3] — session_id (may be empty)
    sys.argv[4] — original (the LAUNCH_CMD fallback)

Stdout: rewritten launch_cmd with `--dangerously-skip-permissions`,
`--name <agent>`, and resume mode pinned. Channel and dev-channel
tokens (whitespace and `=` forms, including multi-value whitespace
form) are stripped — safe mode launches without any plugin channels
attached. Always exits 0.

Includes the same `false` → `claude` repair as the static builder.
"""

import re
import shlex
import sys


def repair_false_command(value: str) -> str:
    try:
        tokens = shlex.split(value)
    except ValueError:
        return value
    if not tokens:
        return value
    idx = 0
    while idx < len(tokens):
        key = tokens[idx].split("=", 1)[0]
        if "=" not in tokens[idx] or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) or tokens[idx].startswith("-"):
            break
        idx += 1
    if idx < len(tokens) and tokens[idx] == "false":
        tokens[idx] = "claude"
        return " ".join(shlex.quote(token) for token in tokens)
    return value


def main() -> int:
    agent, continue_mode, session_id, original = sys.argv[1:5]

    original = repair_false_command(original)
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
    extras: list[str] = []
    i = 0
    while i < len(rest):
        token = rest[i]
        if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
            i += 1
            continue
        if token in {"--resume", "--name", "--channels"}:
            i += 2 if i + 1 < len(rest) else 1
            continue
        if token.startswith("--channels="):
            i += 1
            continue
        if token == "--dangerously-load-development-channels":
            i += 1
            while i < len(rest) and not rest[i].startswith("-"):
                i += 1
            continue
        if token.startswith("--dangerously-load-development-channels="):
            i += 1
            continue
        extras.append(token)
        if token.startswith("--") and i + 1 < len(rest) and not rest[i + 1].startswith("-"):
            extras.append(rest[i + 1])
            i += 2
            continue
        i += 1

    base = ["claude"]
    if continue_mode == "1" and session_id:
        base.extend(["--resume", session_id])
    elif continue_mode == "1":
        base.append("--continue")
    base.extend(["--dangerously-skip-permissions", "--name", agent])
    base.extend(extras)

    quoted = " ".join(shlex.quote(token) for token in base)
    if env_prefix:
        print(f"{env_prefix}{quoted}")
    else:
        print(quoted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
