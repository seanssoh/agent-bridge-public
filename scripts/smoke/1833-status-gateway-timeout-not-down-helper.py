#!/usr/bin/env python3
"""Sidecar for scripts/smoke/1833-status-gateway-timeout-not-down.sh.

Drives the bridge-status.py dashboard resolver directly (file-as-argv, NO
heredoc-stdin — footgun #11) to pin the #1833 codex-review P1: a BLOCKED
daemon.pid read (iso v2 boundary shape) must resolve to the tri-state
`unknown`, not a false `stopped`, and the legacy boolean shim must map
`unknown` to not-running (False) so pre-tri-state consumers stay
conservative.

Usage:
  1833-...-helper.py dashboard-unknown <repo_root> <pid_file> <bridge_home>

The pid_file is expected to exist with mode 0000 (the caller arranges it and
skips under root). Prints `ok-dashboard-unknown` on success; any other
output is a failure diagnostic.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load_status_module(repo_root: str):
    script = Path(repo_root) / "bridge-status.py"
    spec = importlib.util.spec_from_file_location("bridge_status_1833", script)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load module spec for {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["bridge_status_1833"] = module
    spec.loader.exec_module(module)
    return module


def cmd_dashboard_unknown(repo_root: str, pid_file: str, bridge_home: str) -> int:
    mod = _load_status_module(repo_root)

    state, pid = mod.daemon_status_tri(pid_file, bridge_home=bridge_home)
    if (state, pid) != ("unknown", "-"):
        print(f"expected daemon_status_tri -> ('unknown', '-'), got ({state!r}, {pid!r})")
        return 1

    running, pid = mod.daemon_status(pid_file, bridge_home=bridge_home)
    if running is not False or pid != "-":
        print(
            "expected legacy daemon_status shim -> (False, '-') for unknown, "
            f"got ({running!r}, {pid!r})"
        )
        return 1

    print("ok-dashboard-unknown")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 5 or argv[1] != "dashboard-unknown":
        print(f"usage: {argv[0]} dashboard-unknown <repo_root> <pid_file> <bridge_home>")
        return 2
    return cmd_dashboard_unknown(argv[2], argv[3], argv[4])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
