#!/usr/bin/env python3
"""Issue #979 regression — exercise the excludes.conf union in
`resolve_daily_backup_excluded_roots`.

Standalone helper for `scripts/smoke/daily-backup.sh::step_excludes_conf_file`.
Extracted to its own file to keep the smoke script free of
heredoc-in-command-substitution patterns (Footgun #11 ratchet —
see `lib/upgrade-helpers/` and CLAUDE.md §"Recent critical patches").

Usage:
    python3 scripts/smoke/daily-backup-excludes-conf-test.py \\
        <bridge-upgrade.py> <bridge-home>

The caller is expected to have created
`<bridge-home>/state/daily-backup/excludes.conf` first. Exits 0 on PASS
(with `PASS (<N> checks)` to stdout), 1 on FAIL (with per-check
diagnostics to stdout).
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


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <bridge-upgrade.py> <bridge-home>", file=sys.stderr)
        return 2

    mod = _load_bridge_upgrade(argv[1])
    target_root = pathlib.Path(argv[2]).resolve()
    backup_dir = target_root / "backups" / "daily"

    failures: list[str] = []
    checks = 0

    def expect(parts: tuple[str, ...], present: bool, label: str, resolved) -> None:
        nonlocal checks
        checks += 1
        got = parts in resolved
        if got != present:
            failures.append(
                f"{label}: {'/'.join(parts)} expected_present={present} got={got}"
            )

    # Resolve with NO env var — the conf file is the only extra source.
    resolved_file_only = mod.resolve_daily_backup_excluded_roots(
        target_root, backup_dir, extra_excludes_env=""
    )
    # conf-file relpaths land in the excluded set
    expect(("agents", "patch", "home", ".claude", "plugins", "cache"),
           True, "conf relpath A present", resolved_file_only)
    expect(("state", "huge-regenerable"), True,
           "conf relpath B present", resolved_file_only)
    # comment / blank lines are ignored — the `#`-prefixed token must not leak
    for parts in resolved_file_only:
        if any(p.startswith("#") for p in parts):
            failures.append(f"comment line leaked into excludes: {parts}")
    # a path that only appears in a comment line must NOT be excluded
    expect(("commented", "out", "path"), False,
           "commented-out path absent", resolved_file_only)
    # hardcoded excludes still present alongside the file
    expect(("logs",), True, "hardcoded exclude survives", resolved_file_only)

    # Resolve WITH an env var — file + env must both contribute (union).
    resolved_union = mod.resolve_daily_backup_excluded_roots(
        target_root, backup_dir,
        extra_excludes_env="env/only/dir:another/env/dir",
    )
    expect(("env", "only", "dir"), True,
           "env exclude present alongside file", resolved_union)
    expect(("agents", "patch", "home", ".claude", "plugins", "cache"),
           True, "conf relpath still present with env set", resolved_union)
    expect(("logs",), True, "hardcoded still present in union", resolved_union)

    # No order-equivalent duplicates in the resolved list.
    if len(resolved_union) != len(set(resolved_union)):
        failures.append("resolved excluded list contains duplicate tuples")

    if failures:
        print("FAIL")
        for f in failures:
            print("  -", f)
        return 1
    print(f"PASS ({checks} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
