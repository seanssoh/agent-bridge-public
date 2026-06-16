#!/usr/bin/env python3
"""Scan one agent's Claude settings file for a MISSING hook script file (#1934).

Invoked by the daemon reconcile self-heal (`bridge_daemon_reheal_missing_hook_
files`, bridge-daemon.sh). The #1934 incident bricked a farm when a render run
with a transient BRIDGE_HOME persisted `/tmp/.../hooks/<hook>` command paths into
live agent settings; once /tmp was reaped the hook FILES vanished and every
agent went fail-closed-deaf (UserPromptSubmit) + tool-deadlocked (PreToolUse
`*`). Facet 1 prevents the bad write going forward; this scan lets the daemon
DETECT an already-stale/bricked settings file (hook command points at a script
file that no longer exists) so it can force a canonical re-render without a human.

argv[1] = path to the agent's settings file (settings.json or
settings.effective.json). We parse the `hooks` record, pull every
`type=command` entry's command string, extract the *last token that looks like a
bridge hook script* (an absolute path ending in `hooks/<name>.{py,sh}`), and
report whether any such referenced script file is MISSING.

Output (stdout, exactly one line):
    missing\t<first-missing-path>   — at least one referenced hook script is gone
    ok                              — every referenced hook script exists (or none
                                      were parseable / the file is unreadable)

Fail-SAFE bias: an unreadable / malformed settings file, or a command whose
script path we cannot confidently resolve, yields `ok` (no re-render) — the scan
must never trigger a spurious re-render storm. Only a CONFIDENTLY-resolved,
CONFIRMED-absent bridge hook script reports `missing`.

File-as-argv only (footgun #11 / lint-heredoc-ban): the path comes in on argv,
never stdin.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

# The EXACT set of bridge-owned hook script basenames the `*_hook_command()`
# builders in bridge-hooks.py emit. Restricting to this allowlist (rather than
# any `.../hooks/*.{py,sh}` shape) means a FOREIGN project/user hook that
# happens to live under some `hooks/` dir can never trigger a spurious self-heal
# re-render storm — the daemon only acts on a missing BRIDGE hook (#1934 codex
# r1). Keep this in sync with the builders if a new bridge hook is added.
_BRIDGE_HOOK_BASENAMES = frozenset(
    {
        "askuserquestion-ban.py",
        "check-inbox.py",
        "clear-idle.sh",
        "codex-permission-request.py",
        "codex-post-compact.py",
        "codex-pre-compact.py",
        "codex-review-output-shape.py",
        "codex-subagent-start.py",
        "codex-subagent-stop.py",
        "codex-task-mode-policy.py",
        "inbox-auto-drain.py",
        "mark-idle.sh",
        "pre-compact.py",
        "prompt-guard.py",
        "prompt_timestamp.py",
        "session-start.py",
        "session-stop.py",
        "surface-reply-enforce.py",
        "tool-policy.py",
    }
)

# An absolute path whose parent dir is named `hooks` and whose basename is one
# of the bridge-owned hook scripts above.
_HOOK_SCRIPT_RE = re.compile(r"^/.*/hooks/(?P<name>[^/\s]+\.(?:py|sh))$")


def _hook_script_path(command: str) -> str | None:
    """Extract a bridge-owned hook script path from a command string, or None."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    # The script is whichever token matches the bridge hook-script shape AND
    # carries a bridge-owned basename. Scan all tokens (the interpreter is
    # token[0]; the script is usually token[1], but flags/wrappers can shift it).
    for token in tokens:
        match = _HOOK_SCRIPT_RE.match(token)
        if match is not None and match.group("name") in _BRIDGE_HOOK_BASENAMES:
            return token
    return None


def _iter_commands(hooks: object):
    if not isinstance(hooks, dict):
        return
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            entries = group.get("hooks")
            if not isinstance(entries, list):
                continue
            for hook in entries:
                if not isinstance(hook, dict):
                    continue
                if hook.get("type") != "command":
                    continue
                command = hook.get("command")
                if isinstance(command, str) and command:
                    yield command


def main() -> int:
    if len(sys.argv) < 2:
        print("ok")
        return 0
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        # Unreadable / malformed → fail-safe ok (never spurious re-render).
        print("ok")
        return 0
    if not isinstance(data, dict):
        print("ok")
        return 0
    for command in _iter_commands(data.get("hooks")):
        script = _hook_script_path(command)
        if script is None:
            continue
        try:
            exists = os.path.exists(script)
        except OSError:
            # Cannot resolve confidently → treat as present (fail-safe).
            continue
        if not exists:
            # Tab-separate so the shell can read the offending path for the audit.
            sys.stdout.write("missing\t" + script.replace("\t", "").replace("\n", "") + "\n")
            return 0
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
