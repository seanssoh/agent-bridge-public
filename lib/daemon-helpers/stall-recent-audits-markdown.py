#!/usr/bin/env python3
"""stall-recent-audits-markdown.py — print up to two most-recent audit
log lines for a given agent as a markdown bullet list.

Invocation contract:
    sys.argv[1] = path to BRIDGE_AUDIT_LOG (jsonl).
    sys.argv[2] = agent identifier to filter on.

Output: markdown bullet list on stdout. Prints `- none` when no rows
match (mirrors the legacy heredoc body).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$BRIDGE_AUDIT_LOG" "$agent" <<'PY'` heredoc-stdin in
bridge_stall_recent_audits_markdown. The audit log is read often by
the watchdog path so the deadlock surface is frequently exercised;
moved to a standalone file invoked as
`python3 stall-recent-audits-markdown.py <audit_log> <agent>` to remove
the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    path = Path(sys.argv[1])
    agent = sys.argv[2]
    rows = []
    if path.is_file():
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                item = json.loads(raw)
            except Exception:
                continue
            detail = item.get("detail") or {}
            target = str(item.get("target") or "")
            if target == agent or str(detail.get("agent") or "") == agent:
                rows.append(item)
    rows = rows[-2:]
    if not rows:
        print("- none")
    else:
        for item in rows:
            ts = str(item.get("ts") or "")
            action = str(item.get("action") or "unknown")
            print(f"- {action} @ {ts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
