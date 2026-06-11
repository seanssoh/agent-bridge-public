#!/usr/bin/env python3
"""T8 (#1801 review r3): _is_home_scale_workdir must treat a mount ROOT as
HOME-scale (degrade → scan_skipped), while a SUBDIRECTORY of a mount is still
deep-walked. The pre-r3 guard only caught ``/`` (parent==self) and missed real
mount points (/dev, /System/Volumes/*, /Users/<op>/OrbStack, external volumes).

Usage: assert-mount-skip.py <path-to-bridge-watchdog.py>
Exits 0 on pass, 1 on failure.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path


def _load(watchdog_path: str):
    spec = importlib.util.spec_from_file_location("bw_under_test", watchdog_path)
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so dataclasses can resolve cls.__module__.
    sys.modules["bw_under_test"] = mod
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: assert-mount-skip.py <bridge-watchdog.py>", file=sys.stderr)
        return 2
    bw = _load(sys.argv[1])

    mount_root = os.path.realpath("/tmp/.agb-1801-fake-mount")
    real_ismount = os.path.ismount

    def fake_ismount(p):
        # Only the mount root itself is a mount point; subdirs are not.
        return os.path.realpath(str(p)) == mount_root

    os.path.ismount = fake_ismount
    try:
        at_root = bw._is_home_scale_workdir(Path(mount_root))
        at_sub = bw._is_home_scale_workdir(Path(mount_root) / "agents" / "x" / "workdir")
    finally:
        os.path.ismount = real_ismount

    if at_root is not True:
        print(f"FAIL: mount root not treated as HOME-scale (got {at_root!r})", file=sys.stderr)
        return 1
    if at_sub is not False:
        print(f"FAIL: subdirectory of a mount wrongly skipped (got {at_sub!r})", file=sys.stderr)
        return 1
    print("T8 OK: mount root → scan_skipped, mount subdir → walked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
