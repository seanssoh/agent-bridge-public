#!/usr/bin/env python3
"""Rewrite the leading engine token in a launch_cmd to an absolute path.

Issue #1118: v2 linux-user-isolated agents run their launch_cmd under
`sudo -n -u <service_user> -H -- bash -lc "<launch_cmd>"`. The
service user is auto-provisioned and inherits sudo's default PATH,
which does NOT include the controller's per-user `~/.local/bin`.
A bare `claude` / `codex` token at the head of LAUNCH_CMD therefore
fails with `command not found` and the daemon reports the opaque
`start-command-failed`.

This helper takes the engine binary's absolute path (resolved on the
controller via `command -v` in `bridge_resolve_engine_binary`) and
rewrites the leading bare engine token in LAUNCH_CMD to that path.
KEY=VALUE env-prefix tokens at the head of the command are preserved
verbatim — matching the parsing rules in
`launch-cmd-static-claude-build.py` / `launch-cmd-safe-claude-build.py`
so the three builders agree on what "the engine token" is.

Conservatism intentionally baked in:

  - Only rewrites if the first non-assignment token equals the bare
    string `claude` or `codex`. An operator override that already
    points at an absolute binary path (e.g. `/opt/claude/bin/claude`)
    is left untouched.
  - On any parse error (unbalanced quotes, etc.) returns the original
    launch_cmd unchanged so we never make a working command worse.
  - Always exits 0 so a callsite that wraps this in `$(...)` cannot
    take down the launch path on a malformed input — the bare token
    will fail at exec time with the legacy `command not found`
    message, which is no worse than today's behavior.

Args (positional, order-sensitive):
    sys.argv[1] — engine_bin (absolute path on the controller)
    sys.argv[2] — original launch_cmd

Stdout: rewritten launch_cmd. Always exits 0.
"""

from __future__ import annotations

import re
import shlex
import sys

_ENGINE_TOKENS = {"claude", "codex"}
_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _is_env_assignment(token: str) -> bool:
    if token.startswith("-"):
        return False
    if "=" not in token:
        return False
    key = token.split("=", 1)[0]
    return bool(_ENV_KEY_RE.match(key))


_ENV_PREFIX_RE = re.compile(
    r"""
    ^\s*
    (?P<prefix>
      (?:
        [A-Za-z_][A-Za-z0-9_]*=
        (?:"[^"]*"|'[^']*'|[^\s'"]*)
        \s+
      )*
    )
    (?P<rest>.*)$
    """,
    re.VERBOSE,
)


def rewrite(engine_bin: str, original: str) -> str:
    if not engine_bin or not original:
        return original
    # Refuse non-absolute or empty engine_bin defensively — caller is
    # supposed to have validated, but the file may have been swapped on
    # disk between resolution and exec.
    if not engine_bin.startswith("/"):
        return original
    # r3 (codex task #5732 BLOCKING #2): preserve the env-assignment
    # prefix VERBATIM from the original input so `KEY=$VAR` /
    # `PATH=$DIR:$PATH` keep their delayed-expansion semantics. r1 used
    # shlex.quote on the whole token (broke env-assignment shape); r2
    # used shlex.quote on the value side (preserved shape but converted
    # `$VAR` into a literal string). The fixtures at
    # scripts/smoke-test.sh:4656 / :7026 rely on shell expansion of
    # `$MCP_RESTART_BIN_DIR` / `$CIRCUIT_CLAUDE_BIN_DIR` at exec time.
    # Regex-split the env-assignment prefix, shlex only the rest, and
    # concatenate.
    match = _ENV_PREFIX_RE.match(original)
    if not match:
        return original
    env_prefix = match.group("prefix")
    rest = match.group("rest")
    try:
        tokens = shlex.split(rest)
    except ValueError:
        return original
    if not tokens:
        return original
    if tokens[0] not in _ENGINE_TOKENS:
        # Already absolute, or some non-standard engine override —
        # leave it alone.
        return original
    tokens[0] = engine_bin
    rewritten_rest = " ".join(shlex.quote(t) for t in tokens)
    return env_prefix + rewritten_rest


def main() -> int:
    if len(sys.argv) < 3:
        # No-op: print whatever we were given (or empty).
        if len(sys.argv) == 2:
            print(sys.argv[1])
        return 0
    engine_bin = sys.argv[1]
    original = sys.argv[2]
    print(rewrite(engine_bin, original))
    return 0


if __name__ == "__main__":
    sys.exit(main())
