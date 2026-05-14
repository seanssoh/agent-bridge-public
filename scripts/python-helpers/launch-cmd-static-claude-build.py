#!/usr/bin/env python3
"""Build the canonical static-Claude launch command for an agent.

Extracted from
`lib/bridge-state.sh::bridge_build_static_claude_launch_cmd` as part of
issue #835 (Wave A). This is the function that wedged in `heredoc_write`
for the static admin agent `patch` on macOS Bash 5.3.9 during the
2026-05-14 incident: `bridge_agent_launch_cmd patch` never returned, so
the tmux pane existed (`bridge-run.sh patch --continue`) but no
`claude` child was ever spawned. Living in a real script bypasses the
bash read entirely. (Forbidden pattern strings intentionally omitted
from this comment so the footgun #11 self-audit grep recipe does not
flag a textual mention as a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — agent name (becomes `--name <agent>`)
    sys.argv[2] — continue_mode ("1" or "0")
    sys.argv[3] — session_id (may be empty)
    sys.argv[4] — continue_fallback ("1" or "0"; falls back to bare
                  `--continue` when continue_mode=1 and no session_id
                  but the workdir has a resumable transcript)
    sys.argv[5] — original (the roster-provided LAUNCH_CMD fallback)

Stdout: rewritten launch_cmd with `--dangerously-skip-permissions`,
`--name <agent>`, and the appropriate resume mode pinned. Existing
`-c`, `--continue`, `--dangerously-skip-permissions`, `--resume`,
and `--name` tokens are stripped to avoid double-emit. Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    Includes the `false` → `claude` repair (handles a stale-roster
    artifact where the engine token was rewritten to `false` by a prior
    bug; if the leading env-prefix tokens are well-formed assignments
    and the first non-env token is the literal `false`, swap it to
    `claude` before further processing).
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
    agent, continue_mode, session_id, continue_fallback, original = sys.argv[1:6]

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
    j = 0
    while j < len(rest):
        token = rest[j]
        if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
            j += 1
            continue
        if token in {"--resume", "--name"}:
            j += 2 if j + 1 < len(rest) else 1
            continue
        extras.append(token)
        if token.startswith("--") and j + 1 < len(rest) and not rest[j + 1].startswith("-"):
            extras.append(rest[j + 1])
            j += 2
            continue
        j += 1

    base = ["claude"]
    if continue_mode == "1" and session_id:
        base.extend(["--resume", session_id])
    elif continue_mode == "1" and continue_fallback == "1":
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
