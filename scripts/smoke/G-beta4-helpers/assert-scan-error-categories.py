#!/usr/bin/env python3
"""G-beta4 T6 — scan_error rows are categorized into
controller-cache-stale (controller can stat the workdir; inner read
fails) vs iso-uid-side (controller cannot even stat the workdir).

Usage:
  assert-scan-error-categories.py <watchdog-json> <iso-blocked-agent> <cache-stale-agent>

Assertions:
  * Both agents appear in the payload.
  * The blocked agent (workdir parent mode 0000) has
    status=scan_error, error_kind=permission_denied,
    error_category=iso-uid-side.
  * The cache-stale agent (workdir present, inner file mode 0000) has
    status=scan_error AND error_category=controller-cache-stale.

The category split is the heart of #1254: pre-fix the operator saw
identical drift task bodies for both shapes, even though one is
operator-actionable (controller sg refresh) and the other is admin-
actionable (real iso-UID-side filesystem failure).
"""
import json
import sys
from pathlib import Path

path, blocked_agent, cache_stale_agent = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.loads(Path(path).read_text(encoding="utf-8"))
rows = {row["agent"]: row for row in payload["agents"]}

for agent in (blocked_agent, cache_stale_agent):
    assert agent in rows, (
        f"FAIL: agent '{agent}' missing. Rows: {list(rows)}"
    )

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

stale = rows[cache_stale_agent]
assert stale.get("status") == "scan_error", (
    f"FAIL: cache-stale agent status={stale.get('status')!r}; "
    f"expected scan_error. row={stale}"
)
assert stale.get("error_category") == "controller-cache-stale", (
    f"FAIL: cache-stale agent (workdir statable, inner file unreadable) "
    f"should be controller-cache-stale, got {stale.get('error_category')!r}. "
    f"row={stale}"
)

print("T6 PASS")
