#!/usr/bin/env python3
"""Probe for scripts/smoke/1569-askuserquestion-bound.sh case (f).

Loads hooks/tool-policy.py by path, forces the escalation helper handle to
``None`` (the defensive-import outcome on a broken/partial install), and runs
``handle_pretool`` with an AskUserQuestion payload. Prints the hook's stdout
(the PreToolUse decision JSON) so the smoke can assert the call is STILL bounded
(deny + proceed-with-note) rather than falling through to the raw, unbounded
interactive picker (codex #1569 r1 finding 1).

Extracted to a standalone file so the smoke can invoke it file-as-argv instead
of a heredoc-in-command-substitution, which is the Bash 5.3.9 ``read_comsub``
deadlock class (footgun #11 / lint-heredoc-ban C1).

Usage: 1569-missing-helper-probe.py <repo_root>
Reads BRIDGE_AGENT_ID from the environment (the smoke exports it).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: 1569-missing-helper-probe.py <repo_root>\n")
        return 2
    repo = argv[1]
    sys.path.insert(0, os.path.join(repo, "hooks"))
    spec = importlib.util.spec_from_file_location(
        "tool_policy_under_test", os.path.join(repo, "hooks", "tool-policy.py")
    )
    if spec is None or spec.loader is None:
        sys.stderr.write("could not load hooks/tool-policy.py\n")
        return 2
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # Simulate the broken/partial install: escalation helper unavailable.
    mod._auq_escalate = None
    payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "AskUserQuestion",
        "tool_input": {
            "question": "Which color theme?",
            "options": ["dark", "light"],
        },
        "tool_use_id": "smoke-1569-f",
        "session_id": "smoke-session",
    }
    agent = os.environ.get("BRIDGE_AGENT_ID", "")  # noqa: iso-helper-boundary — smoke fixture env read (.environ false-matches .env); not an isolated runtime artifact
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        mod.handle_pretool(payload, agent)
    sys.stdout.write(buf.getvalue())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
