#!/usr/bin/env python3
"""channel-guard-json.py — convert the tab-separated channel-guard report
into the JSON structure embedded by `bridge_upgrade_channel_guard_json`.

Invocation contract:
    sys.argv[1] = report (multi-line tab-separated string;
                          each row: "<agent>\\t<active>\\t<required>\\t<reason>")

Output: a single JSON document on stdout.

Footgun #11 (task #4538): this body used to live as a `python3 - <<'PY' … PY`
heredoc-stdin inside bridge_upgrade_channel_guard_json. Moved to a standalone
file to remove the heredoc-stdin path that wedges Bash 5.3.9.
"""

import json
import sys

items = []
active_count = 0
for raw in sys.argv[1].splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    agent, active, required, reason = (raw.split("\t", 3) + ["", "", "", ""])[:4]
    is_active = active == "yes"
    if is_active:
        active_count += 1
    items.append(
        {
            "agent": agent,
            "active": is_active,
            "required_channels": required,
            "reason": reason,
        }
    )

print(
    json.dumps(
        {"count": len(items), "active_count": active_count, "agents": items},
        ensure_ascii=False,
    )
)
