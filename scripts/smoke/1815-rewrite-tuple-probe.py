#!/usr/bin/env python3
"""Issue #1815 probe: report membership of AGENT_RUNTIME_REWRITE_FILES.

Prints one `NAME=present|absent` line per name of interest so the bash smoke can
assert that HEARTBEAT.md and CHECKLIST.md were dropped while SOUL.md remains.

File-as-argv invocation; no heredoc-stdin (footgun #11).
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def main() -> int:
    spec = importlib.util.spec_from_file_location(
        "bridge_docs_mod", REPO_ROOT / "bridge-docs.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["bridge_docs_mod"] = module
    spec.loader.exec_module(module)

    tuple_members = set(module.AGENT_RUNTIME_REWRITE_FILES)
    for name in ("SOUL.md", "HEARTBEAT.md", "CHECKLIST.md"):
        state = "present" if name in tuple_members else "absent"
        sys.stdout.write("%s=%s\n" % (name, state))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
