#!/usr/bin/env python3
"""Issue #974 / #1462 regression — exercise `should_skip_daily_backup_relpath`.

Standalone helper for `scripts/smoke/daily-backup.sh::step_path_part_excludes_multicomponent`.
Extracted to its own file to keep the smoke script free of
heredoc-in-command-substitution patterns (Footgun #11 ratchet —
see `lib/upgrade-helpers/` and CLAUDE.md §"Recent critical patches").

Usage:
    python3 scripts/smoke/daily-backup-path-part-test.py <bridge-upgrade.py>

Exits 0 on PASS (with `PASS (<N> cases)` to stdout), 1 on FAIL (with
per-case diagnostics to stdout).
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys


def _load_bridge_upgrade(path: str):
    spec = importlib.util.spec_from_file_location(
        "bridge_upgrade", str(pathlib.Path(path).resolve())
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load spec for {path!r}")
    mod = importlib.util.module_from_spec(spec)
    # Register in sys.modules BEFORE exec so dataclass+ClassVar field
    # resolution can introspect the module under Python 3.9 (the dataclass
    # machinery looks up cls.__module__ in sys.modules).
    sys.modules["bridge_upgrade"] = mod
    spec.loader.exec_module(mod)
    return mod


CASES: list[tuple[str, bool, str]] = [
    # (relpath, expected_excluded, label)
    ("agents/patch/home/.claude/plugins/cache/foo", True, "target case (excluded)"),
    ("agents/patch/home/.claude/plugins/cache", True, "no trailing slash (excluded)"),
    ("plugins/cache/foo", True, "top-level adjacency (excluded)"),
    ("foo/__pycache__/bar", True, "legacy single-component __pycache__"),
    ("node_modules/x", True, "legacy single-component node_modules"),
    ("plugins/elsewhere.json", False, "plugins alone, no cache adjacency (kept)"),
    ("agents/cache/home/x.txt", False, "cache alone, not after plugins (kept)"),
    ("state/cache/plugins/x.txt", False, "reversed order (kept)"),
    ("random/plugins/cache_other/x", False, "cache_other != cache (kept)"),
    ("plugins-archive/cache/x", False, "plugins-archive != plugins (kept)"),
    # Issue #1462 — regenerable per-agent trees, same any-depth path-part
    # mechanism as #974. Both are rebuilt/re-downloaded on demand, so the
    # daily backup must skip them regardless of the agent-name segment. TEETH:
    # if the two `DAILY_BACKUP_PATH_PART_EXCLUDES` entries are removed from
    # bridge-upgrade.py, these `True` cases flip to got=False and the smoke
    # fails.
    (
        "agents/patch/home/.claude/security/agent-sdk-venv/bin/python",
        True,
        "#1462 agent-sdk venv (excluded)",
    ),
    (
        "agents/worker-a/home/.claude/security/agent-sdk-venv",
        True,
        "#1462 agent-sdk venv, no trailing seg, other agent (excluded)",
    ),
    (
        "agents/patch/home/.local/share/claude/versions/1.2.3/cli",
        True,
        "#1462 claude CLI versions cache (excluded)",
    ),
    (
        "agents/worker-a/home/.local/share/claude/versions",
        True,
        "#1462 claude versions, no trailing seg, other agent (excluded)",
    ),
    # #1462 keep-cases: sibling/adjacent paths that must NOT be swept up.
    (
        "agents/patch/home/.claude/security/credentials.json",
        False,
        "#1462 security/ sibling, not agent-sdk-venv (kept)",
    ),
    (
        "agents/patch/home/.local/share/claude/settings.json",
        False,
        "#1462 claude/ data, not versions (kept)",
    ),
    (
        "agents/patch/home/.local/share/claude/versions-archive/x",
        False,
        "#1462 versions-archive != versions (kept)",
    ),
]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <bridge-upgrade.py>", file=sys.stderr)
        return 2

    mod = _load_bridge_upgrade(argv[1])

    failures: list[str] = []
    for relpath, expected, label in CASES:
        got = mod.should_skip_daily_backup_relpath(pathlib.Path(relpath), [])
        if got != expected:
            failures.append(
                f"{label}: relpath={relpath!r} expected={expected} got={got}"
            )

    if failures:
        print("FAIL")
        for f in failures:
            print("  -", f)
        return 1
    print(f"PASS ({len(CASES)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
