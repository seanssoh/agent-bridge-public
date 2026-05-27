#!/usr/bin/env python3
"""G-beta4 T7 — bridge_init_write_onboarding_marker schema regression.

Usage:
  assert-onboarding-marker.py <marker-file> <expected-admin>

Assertions:
  * The marker file exists.
  * The marker file is mode 0600.
  * The body contains an ``agent=<admin>`` line.
  * The body contains a ``written=<unix-ts>`` line with an integer
    value that parses to a positive number.
  * The body contains a ``reason=fresh-install`` line.
"""
import os
import re
import sys
from pathlib import Path

marker_path = Path(sys.argv[1])
expected_admin = sys.argv[2]

assert marker_path.is_file(), f"FAIL: marker file missing: {marker_path}"

mode = os.stat(marker_path).st_mode & 0o7777
assert mode == 0o600, (
    f"FAIL: marker file mode={oct(mode)}; expected 0o600 "
    f"(operator-private fresh-install signal)"
)

text = marker_path.read_text(encoding="utf-8")
fields = {}
for line in text.splitlines():
    if "=" in line:
        k, _, v = line.partition("=")
        fields[k.strip()] = v.strip()

assert fields.get("agent") == expected_admin, (
    f"FAIL: marker agent field={fields.get('agent')!r}; "
    f"expected {expected_admin!r}. Body:\n{text}"
)
assert fields.get("reason") == "fresh-install", (
    f"FAIL: marker reason field={fields.get('reason')!r}; "
    f"expected 'fresh-install'. Body:\n{text}"
)

written = fields.get("written", "")
assert re.fullmatch(r"\d+", written) and int(written) > 0, (
    f"FAIL: marker written field={written!r}; expected positive integer "
    f"(unix timestamp). Body:\n{text}"
)

print("T7 PASS")
