#!/usr/bin/env python3
"""Extract `--dangerously-load-development-channels` values from a launch command.

Extracted from
`lib/bridge-agents.sh::bridge_extract_development_channels_from_command`
as part of issue #835 (Wave A'). PR #845 (Wave A of #835) closed the
launch-cmd builders in `lib/bridge-state.sh`, but the reverse
direction — parsing an already-built launch_cmd back into a CSV of
dev-channel ids — still lived as an inline Python body read through
bash stdin redirection. On Homebrew Bash 5.3.9 that read can wedge in
`heredoc_write` when this wrapper is invoked inside a command
substitution from an absolute-path-sourced shell — the same class that
closed #800 / #815 / #827 / #840 for the daemon, CLI, status, and
session-id hot paths, and that Wave A flagged as upstream of the
`bridge_agent_launch_cmd patch` wedge on the launch-cmd hot path.
Living in a real script bypasses the bash read entirely. (Forbidden
pattern strings intentionally omitted from this comment so the
footgun #11 self-audit grep recipe does not flag a textual mention as
a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — launch command string (env prefix + `claude ...`)

Stdout: comma-separated, de-duplicated list of dev-channel ids parsed
from the command's `--dangerously-load-development-channels` tokens
(both whitespace and `=` forms; whitespace form absorbs subsequent
non-flag tokens). Empty string if the command does not shlex-parse or
declares no dev channels. Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    1. shlex.split() the command; on ValueError print empty + exit 0.
    2. Walk tokens left-to-right.
    3. On `--dangerously-load-development-channels`: consume the
       following non-`-`-prefixed tokens as comma-separated value
       chunks (whitespace form).
    4. On `--dangerously-load-development-channels=<csv>`: take the
       value as comma-separated chunks (= form).
    5. normalize() each chunk: split on comma, strip, drop empty and
       duplicates within the local chunk.
    6. Global de-dup across all parsed items, preserving first-seen
       order.
    7. Print the result joined by `,`.
"""

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
    command = sys.argv[1]

    try:
        tokens = shlex.split(command)
    except ValueError:
        print("")
        return 0

    items: list[str] = []
    seen: set[str] = set()
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "--dangerously-load-development-channels":
            i += 1
            while i < len(tokens) and not tokens[i].startswith("-"):
                for item in normalize(tokens[i]):
                    if item not in seen:
                        seen.add(item)
                        items.append(item)
                i += 1
            continue
        if token.startswith("--dangerously-load-development-channels="):
            for item in normalize(token.split("=", 1)[1]):
                if item not in seen:
                    seen.add(item)
                    items.append(item)
        i += 1

    print(",".join(items))
    return 0


if __name__ == "__main__":
    sys.exit(main())
