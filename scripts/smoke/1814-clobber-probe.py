#!/usr/bin/env python3
"""Issue #1814 clobber-guard probe (mutation-proof helper for the smoke).

Usage:
    1814-clobber-probe.py <bridge_home> <agent_dir> guarded
    1814-clobber-probe.py <bridge_home> <agent_dir> unguarded

`guarded`   — calls the REAL `sync_memory_schema_from_template`, which must
              refuse to write through a symlinked MEMORY-SCHEMA.md (the canon
              survives).
`unguarded` — reproduces the OLD vulnerable line (`target.write_bytes(
              template_bytes)`) inline, which follows the symlink and clobbers
              whatever it resolves to. This makes the smoke NON-VACUOUS: if the
              unguarded write no longer destroys the canon, the precondition is
              wrong and the guard assertion would be meaningless.

File-as-argv invocation; no heredoc-stdin (footgun #11).
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _load_bridge_docs():
    spec = importlib.util.spec_from_file_location(
        "bridge_docs_mod", REPO_ROOT / "bridge-docs.py"
    )
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclass module lookups resolve.
    sys.modules["bridge_docs_mod"] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: 1814-clobber-probe.py <bridge_home> <agent_dir> guarded|unguarded\n")
        return 2
    bridge_home = Path(sys.argv[1])
    agent_dir = Path(sys.argv[2])
    mode = sys.argv[3]

    bd = _load_bridge_docs()
    backup_root = bridge_home / "state" / "doc-migration" / "backups" / "probe"
    target = agent_dir / "MEMORY-SCHEMA.md"
    template = bridge_home / "agents" / "_template" / "MEMORY-SCHEMA.md"

    if mode == "guarded":
        changed = bd.sync_memory_schema_from_template(agent_dir, bridge_home, False, backup_root)
        sys.stdout.write("guarded changed=%r\n" % (changed,))
        return 0

    if mode == "unguarded":
        # The pre-fix vulnerable line, reproduced verbatim: write_bytes follows
        # the symlink and overwrites the link's target (the canon).
        target.write_bytes(template.read_bytes())
        sys.stdout.write("unguarded wrote through symlink\n")
        return 0

    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
