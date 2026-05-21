#!/usr/bin/env python3
# scripts/smoke/isolated-agent-delete-reap.py — direct callee for
# scripts/smoke/isolated-agent-delete-reap.sh. Kept as a standalone file
# (not inlined as heredoc-stdin to python3) so the smoke is immune to
# footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock) even
# if a future caller wraps it in `$()` capture.
#
# Composes the generated isolated-agent OS-account name EXACTLY the way
# `agent create` does via bridge_agent_default_os_user
# (lib/bridge-agents.sh:990-1007) — including the Linux 32-char account
# truncation. The reaper's exact-match safety gate depends on this exact
# composition; the smoke re-uses it both to construct correctly-truncated
# probe arguments and (inside the probe) to stand in for the helper that
# lives in the too-heavy-to-source-standalone lib/bridge-agents.sh.

import re
import sys


def default_os_user(agent: str) -> str:
    agent = agent.strip().lower()
    slug = re.sub(r"[^a-z0-9_-]+", "-", agent).strip("-")
    slug = slug or "agent"
    prefix = "agent-bridge-"
    max_len = 32
    keep = max_len - len(prefix)
    if keep < 1:
        keep = 1
    return prefix + slug[:keep]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: isolated-agent-delete-reap.py <agent-name>", file=sys.stderr)
        return 2
    print(default_os_user(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
