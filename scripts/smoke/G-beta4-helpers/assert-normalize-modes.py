#!/usr/bin/env python3
"""G-beta4 T3 / T4 / T3-teeth — verify the mode of every file in a
test workdir after invoking
``bridge_isolation_v2_normalize_workdir_profile_group``.

Usage:
  assert-normalize-modes.py <workdir> <expected-mode-octal>

The expected mode is octal as a 4-digit string (e.g. "0660", "0600").
Only the file mode bits are checked; ownership/group is exercised via
the smoke's `chgrp` path and is not stat-checkable here without
running as root.

Reports the first file with a mismatched mode along with a list of all
checked files. A missing workdir / no files = explicit FAIL (avoids
false-pass when the upstream helper was not invoked correctly).
"""
import os
import sys
from pathlib import Path

workdir, expected_octal = Path(sys.argv[1]), sys.argv[2]
expected_mode = int(expected_octal, 8)

assert workdir.is_dir(), f"FAIL: workdir does not exist: {workdir}"

files = sorted(p for p in workdir.iterdir() if p.is_file())
assert files, f"FAIL: no files in workdir {workdir}; smoke fixture broken"

mismatches: list[tuple[str, str]] = []
for f in files:
    actual = os.stat(f).st_mode & 0o7777
    if actual != expected_mode:
        mismatches.append((f.name, oct(actual)))

assert not mismatches, (
    f"FAIL: mode mismatch (expected {oct(expected_mode)}): {mismatches}. "
    f"Checked files: {[f.name for f in files]}"
)

print(f"PASS — {len(files)} files at mode {oct(expected_mode)}")
