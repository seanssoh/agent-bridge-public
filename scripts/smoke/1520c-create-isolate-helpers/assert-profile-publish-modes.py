#!/usr/bin/env python3
"""#1520c — per-FILE metadata assertion for
``bridge_isolation_v2_publish_workdir_profile_files``.

A dir-level assertion FALSE-PASSES the create-time publish gap (the bug
was: workdir DIR correct at 2770, the FILES wrong at 0600). This helper
stats EACH expected profile file by name and asserts the published mode,
AND asserts the negative-control files were NOT touched.

Usage:
  assert-profile-publish-modes.py <workdir> <published-octal> \
      --published SOUL.md,CLAUDE.md,... \
      --owner-only HEARTBEAT.md,.teams/.env \
      [--symlink CHANGE-POLICY.md]

  <published-octal>      expected mode for every --published file (e.g. 0660)
  --published <csv>      basenames that MUST be at <published-octal> AND
                         group-readable
  --owner-only <csv>     paths (workdir-relative) that MUST stay 0600
                         (owner-only; group read bit CLEAR) — negative
                         controls (HEARTBEAT.md, v3 channel .env)
  --symlink <csv>        workdir-relative paths that MUST remain symlinks
                         (publish must never have followed/replaced them)

Each missing expected file is a FAIL (avoids a false-pass when the
upstream helper was never invoked). Reports the first mismatch with the
full checked set for debuggability.
"""
import argparse
import os
import stat
import sys
from pathlib import Path


def _csv(val: str) -> list[str]:
    return [x.strip() for x in val.split(",") if x.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("workdir")
    ap.add_argument("published_octal")
    ap.add_argument("--published", default="")
    ap.add_argument("--owner-only", default="")
    ap.add_argument("--symlink", default="")
    args = ap.parse_args()

    workdir = Path(args.workdir)
    published_mode = int(args.published_octal, 8)
    published = _csv(args.published)
    owner_only = _csv(args.owner_only)
    symlinks = _csv(args.symlink)

    if not workdir.is_dir():
        print(f"FAIL: workdir does not exist: {workdir}")
        return 1

    failures: list[str] = []

    # Published files: exact mode. When the EXPECTED mode is group-
    # readable (e.g. 0660), additionally assert the group-read bit is set
    # — that is the load-bearing property the publish must establish.
    # When the expected mode is owner-only (e.g. 0600, the enforce-OFF
    # no-op case), the group-read bit MUST stay clear instead.
    expect_group_read = bool(published_mode & stat.S_IRGRP)
    for name in published:
        p = workdir / name
        if not p.is_file():
            failures.append(f"published file missing: {name}")
            continue
        m = os.stat(p).st_mode & 0o7777
        if m != published_mode:
            failures.append(
                f"{name}: mode {oct(m)} != expected {oct(published_mode)}"
            )
        has_group_read = bool(m & stat.S_IRGRP)
        if expect_group_read and not has_group_read:
            failures.append(f"{name}: group-read bit CLEAR (mode {oct(m)})")
        if not expect_group_read and has_group_read:
            failures.append(f"{name}: group-read bit SET (mode {oct(m)})")

    # Owner-only negative controls: group-read bit MUST be clear.
    for rel in owner_only:
        p = workdir / rel
        if not p.exists():
            # An absent negative control is acceptable (e.g. HEARTBEAT.md
            # not yet written on a fresh tree) — only assert when present.
            continue
        m = os.stat(p).st_mode & 0o7777
        if m & stat.S_IRGRP:
            failures.append(
                f"{rel}: group-read bit SET (mode {oct(m)}) — should stay "
                f"owner-only 0600 (publish must NOT touch it)"
            )

    # Symlinks: must remain symlinks (publish refused to follow them).
    for rel in symlinks:
        p = workdir / rel
        if not p.exists() and not p.is_symlink():
            continue
        if not p.is_symlink():
            failures.append(
                f"{rel}: no longer a symlink — publish followed/replaced it"
            )

    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(
        f"PASS — {len(published)} published @ {oct(published_mode)} "
        f"(group-readable), {len(owner_only)} owner-only preserved, "
        f"{len(symlinks)} symlink(s) preserved"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
