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


def rewrite(engine_bin: str, original: str) -> str:
    if not engine_bin or not original:
        return original
    # Refuse non-absolute or empty engine_bin defensively — caller is
    # supposed to have validated, but the file may have been swapped on
    # disk between resolution and exec.
    if not engine_bin.startswith("/"):
        return original
    try:
        tokens = shlex.split(original)
    except ValueError:
        return original
    if not tokens:
        return original
    idx = 0
    while idx < len(tokens) and _is_env_assignment(tokens[idx]):
        idx += 1
    if idx >= len(tokens):
        return original
    if tokens[idx] not in _ENGINE_TOKENS:
        # Already absolute, or some non-standard engine override —
        # leave it alone.
        return original
    tokens[idx] = engine_bin
    # Re-emit. Env-assignment tokens (KEY=VALUE) must NOT be wrapped in
    # outer single-quotes — bash interprets `'KEY=VALUE'` as a command
    # name, not an env-assignment word. Codex r1 (task #5719) caught
    # this against `PATH=/tmp/custom:$PATH claude ...` fixtures used in
    # scripts/smoke-test.sh:4656 / :7026. Emit `KEY=<shlex.quote(VALUE)>`
    # for assignment tokens so the value-side stays safely quoted while
    # the assignment shape survives.
    parts: list[str] = []
    for i, token in enumerate(tokens):
        if i < idx and _is_env_assignment(token):
            key, _, value = token.partition("=")
            parts.append(f"{key}={shlex.quote(value)}")
        else:
            parts.append(shlex.quote(token))
    return " ".join(parts)


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
