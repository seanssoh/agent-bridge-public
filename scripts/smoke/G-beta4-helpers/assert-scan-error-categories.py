#!/usr/bin/env python3
"""G-beta4 T6 / T6b — scan_error rows are categorized into
iso-uid-side vs controller-cache-stale based on:
  * Whether the controller can stat the workdir at all.
  * (When statable) whether the iso UID can read the failing path.

Usage:
  assert-scan-error-categories.py <watchdog-json> \
      <blocked-agent> <iso-broken-agent> <iso-cache-agent>

Assertions:
  * blocked-agent (workdir parent mode 0000) → iso-uid-side.
  * iso-broken-agent (statable workdir + file mode 0000 + iso UID also
    cannot read, mocked via test seam) → iso-uid-side. This is the
    r2 codex r1 BLOCKING #2 fix: pre-r2 a statable workdir +
    permission_denied always classified as controller-cache-stale,
    even when the failure was real iso-side filesystem corruption.
  * iso-cache-agent (statable workdir + file mode 0000 + iso UID can
    read, mocked via test seam) → controller-cache-stale. The classic
    #1246 supp-group cache miss shape.

The split is the heart of #1254: pre-fix the operator saw identical
drift task bodies for both shapes, even though one is operator-
actionable (controller sg refresh) and the other is admin-actionable
(real iso-UID-side filesystem failure).
"""
import json
import sys
from pathlib import Path

if len(sys.argv) != 5:
    print(
        "usage: assert-scan-error-categories.py <json> "
        "<blocked> <iso-broken> <iso-cache>",
        file=sys.stderr,
    )
    sys.exit(2)

path = sys.argv[1]
blocked_agent = sys.argv[2]
iso_broken_agent = sys.argv[3]
iso_cache_agent = sys.argv[4]

payload = json.loads(Path(path).read_text(encoding="utf-8"))
rows = {row["agent"]: row for row in payload["agents"]}

for agent in (blocked_agent, iso_broken_agent, iso_cache_agent):
    assert agent in rows, (
        f"FAIL: agent '{agent}' missing. Rows: {list(rows)}"
    )

# T6: parent mode 0000 → workdir not statable → iso-uid-side.
blocked = rows[blocked_agent]
assert blocked.get("status") == "scan_error", (
    f"FAIL: blocked agent status={blocked.get('status')!r}; expected scan_error. "
    f"row={blocked}"
)
assert blocked.get("error_kind") == "permission_denied", (
    f"FAIL: blocked agent error_kind={blocked.get('error_kind')!r}; "
    f"expected permission_denied. row={blocked}"
)
assert blocked.get("error_category") == "iso-uid-side", (
    f"FAIL: blocked agent (workdir parent mode 0000) should be "
    f"iso-uid-side, got {blocked.get('error_category')!r}. row={blocked}"
)

# T6 r2: workdir statable + file mode 0000 + iso UID also can't read
# (mocked via test seam) → iso-uid-side. This is the codex r1
# BLOCKING #2 fix: real iso-side corruption is now distinct from a
# supp-group cache miss.
iso_broken = rows[iso_broken_agent]
assert iso_broken.get("status") == "scan_error", (
    f"FAIL: iso-broken agent status={iso_broken.get('status')!r}; "
    f"expected scan_error. row={iso_broken}"
)
assert iso_broken.get("error_category") == "iso-uid-side", (
    f"FAIL: iso-broken agent (statable workdir, file mode 0000, iso "
    f"UID also can't read via test seam) should be iso-uid-side, "
    f"got {iso_broken.get('error_category')!r}. row={iso_broken}"
)

# T6b: workdir statable + iso UID readable (mocked via test seam) →
# controller-cache-stale. The supp-group cache miss shape.
iso_cache = rows[iso_cache_agent]
assert iso_cache.get("status") == "scan_error", (
    f"FAIL: iso-cache agent status={iso_cache.get('status')!r}; "
    f"expected scan_error. row={iso_cache}"
)
assert iso_cache.get("error_category") == "controller-cache-stale", (
    f"FAIL: iso-cache agent (statable workdir, iso UID readable via "
    f"test seam) should be controller-cache-stale, "
    f"got {iso_cache.get('error_category')!r}. row={iso_cache}"
)

print("T6 + T6b PASS")
