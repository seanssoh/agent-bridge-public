#!/usr/bin/env python3
"""Inject required Codex feature flags into a Codex launch command.

Extracted from `lib/bridge-state.sh::bridge_codex_launch_with_hooks` as
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
    sys.argv[1] — original launch_cmd string (env prefix + `codex …`)

Stdout: the rewritten launch_cmd with `codex_hooks` and `fast_mode`
features pinned via `-c features.<name>=true`. Idempotent: an
already-pinned flag (via `--enable <name>` or any `-c features.<name>=…`
form) is left alone. Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    v0.8.6 hotfix: this helper ensures BOTH `codex_hooks` and
    `fast_mode` are pinned on every codex launch — admin-pair backfill,
    isolated agent create, v0.7→v0.8 migration, and resume paths all
    converge through here. Pre-hotfix it only injected `codex_hooks`,
    so an existing roster with the legacy default launch_cmd (no
    fast_mode) silently fell off the fast inference path on every wake.
"""

import re
import shlex
import sys


REQUIRED_FEATURES = ("codex_hooks", "fast_mode")
ARG_TAKING_FLAGS = {
    "-c", "--enable", "--disable", "--profile", "-p",
    "--model", "-m", "--cd", "-C",
}


def has_feature(rest: list[str], feature: str) -> bool:
    pattern = f"features.{feature}=true"
    i = 0
    while i < len(rest):
        token = rest[i]
        next_value = rest[i + 1] if i + 1 < len(rest) else None
        if token == "--enable" and next_value == feature:
            return True
        if token == "-c" and next_value is not None and pattern in next_value:
            return True
        i += 2 if token in ARG_TAKING_FLAGS and next_value is not None else 1
    return False


def main() -> int:
    original = sys.argv[1]
    match = re.match(r"^(?P<prefix>.*?)(?P<command>codex(?:\s|$).*)$", original)
    if not match:
        print(original)
        return 0

    env_prefix = match.group("prefix")
    args = shlex.split(match.group("command"))
    if not args or args[0] != "codex":
        print(original)
        return 0

    rest = args[1:]
    prefix_pairs: list[str] = []
    for feature in REQUIRED_FEATURES:
        if not has_feature(rest, feature):
            prefix_pairs.extend(["-c", f"features.{feature}=true"])

    if prefix_pairs:
        rest = [*prefix_pairs, *rest]

    quoted = " ".join(shlex.quote(token) for token in [args[0], *rest])
    print(f"{env_prefix}{quoted}" if env_prefix else quoted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
