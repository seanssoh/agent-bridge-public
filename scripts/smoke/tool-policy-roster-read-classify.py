#!/usr/bin/env python3
# scripts/smoke/tool-policy-roster-read-classify.py — regression for
# issue #1014 sub-bug C (2026-05-22, surfaced bringing up an antigravity
# agent).
#
# hooks/tool-policy.py already has read-intent bypasses for the protected
# agent-roster.local.sh path (the path branch and the Bash argv branch).
# But `_is_read_intent_bash` required EVERY pipeline stage's leading
# command to be a known read tool, so a routine diagnostic prelude —
#   cd ~/.agent-bridge && grep BRIDGE agent-roster.local.sh
#   test -f agent-roster.local.sh && grep BRIDGE agent-roster.local.sh
#   echo "checking"; grep BRIDGE agent-roster.local.sh
# was mis-classified as a WRITE because `cd` / `test` / `echo` are not in
# `_READ_INTENT_BASH_COMMANDS`. The grep read of the roster then drew a
# write-oriented protected-roster mutation deny.
#
# Fix: a small set of provably non-mutating prelude builtins (cd / pwd /
# test / [ / echo / printf / true / false / :) no longer disqualify a
# read pipeline. Output redirection anywhere still flips the
# classification, so the write surface is NOT broadened.
#
# This test pins:
#   1. The exact #1014 command shapes classify as read-intent.
#   2. Genuine write shapes (redirection, sed -i, source, rm, tee) still
#      classify as write-intent.

import importlib.util
import pathlib
import sys


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    policy_path = repo_root / "hooks" / "tool-policy.py"
    spec = importlib.util.spec_from_file_location(
        "tool_policy_roster_read", policy_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {policy_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    is_read = module._is_read_intent_bash

    # (command, expected — True if it should classify as read-intent)
    cases: list[tuple[str, bool]] = [
        # ---- #1014 shapes — must classify as read-intent ----
        ("cd ~/.agent-bridge && grep BRIDGE agent-roster.local.sh", True),
        ("test -f agent-roster.local.sh && grep BRIDGE agent-roster.local.sh", True),
        ("[ -f agent-roster.local.sh ] && cat agent-roster.local.sh", True),
        ("echo done; grep BRIDGE agent-roster.local.sh", True),
        ("pushd ~/.agent-bridge && grep CHAN agent-roster.local.sh", True),
        ("cd /tmp; pwd", True),
        ("true && grep BRIDGE agent-roster.local.sh", True),
        # plain read shapes that already worked — regression guard
        ("grep -n channel agent-roster.local.sh", True),
        ("cat agent-roster.local.sh | grep BRIDGE", True),
        # ---- write shapes — must still classify as write-intent ----
        ("grep BRIDGE agent-roster.local.sh > /tmp/out", False),
        ("cd ~/.agent-bridge && echo x > agent-roster.local.sh", False),
        ("echo x >> agent-roster.local.sh", False),
        ("cd ~/.agent-bridge && sed -i s/a/b/ agent-roster.local.sh", False),
        ("source agent-roster.local.sh", False),
        ("rm agent-roster.local.sh", False),
        ("cd /tmp && tee agent-roster.local.sh", False),
        ("echo x 1>/tmp/leak", False),
    ]

    failures: list[str] = []
    for cmd, want in cases:
        got = bool(is_read(cmd))
        if got != want:
            tag = "read-mis-as-write" if want else "write-mis-as-read"
            failures.append(
                f"  FAIL  [{tag}] _is_read_intent_bash({cmd!r}) = {got}, want {want}"
            )
        else:
            print(f"  PASS  _is_read_intent_bash({cmd!r}) = {got}")

    if failures:
        print(f"\n{len(failures)} failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print(
        f"\n[smoke:tool-policy-roster-read-classify] all {len(cases)} cases passed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
