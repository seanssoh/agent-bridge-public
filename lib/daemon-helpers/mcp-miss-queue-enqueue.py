#!/usr/bin/env python3
"""mcp-miss-queue-enqueue.py — append a single miss-log entry to the
per-agent JSONL file at $BRIDGE_STATE_DIR/mcp-miss-queue/<agent>.jsonl.

Invocation contract:
    sys.argv[1] = agent
    sys.argv[2] = title
    sys.argv[3] = body
    sys.argv[4] = priority
    sys.argv[5] = task_id   (may be empty)
    sys.argv[6] = ts        (epoch seconds, integer string)
    sys.argv[7] = dedup_key (sha1 hex)
    sys.argv[8] = path      (absolute path to the per-agent jsonl)

Environment:
    BRIDGE_MCP_MISS_QUEUE_HARD_CAP — hard cap on rows kept (default 500).
        When the existing file already has more entries than the cap, the
        OLDEST rows are dropped so the file converges to cap-size after
        each enqueue.

Output: nothing on success. Exits 0 on success, 1 on write failure (the
caller in bridge_daemon_mcp_miss_queue_enqueue treats any error as
best-effort and continues).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$agent" ... <<'PY'` heredoc-stdin inside
bridge_daemon_mcp_miss_queue_enqueue. The Bash 5.3.9 `read_comsub` /
`heredoc_write` deadlock chain triggers on the same shape that
v0.13.7-v0.13.9 already migrated for the upgrader; moved to a standalone
file invoked file-as-argv via bridge_daemon_helper_python — same
precedent as the other lib/daemon-helpers/ extractions.
"""

import json
import os
import sys
import tempfile


def main() -> int:
    if len(sys.argv) < 9:
        return 1
    agent, title, body, priority, task_id, ts, dedup_key, path = sys.argv[1:9]
    row = {
        "ts": int(ts) if ts.isdigit() else 0,
        "agent": agent,
        "title": title,
        "body": body,
        "priority": priority,
        "task_id": task_id,
        "dedup_key": dedup_key,
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Hard-cap defense: if file > $cap lines, trim oldest before appending.
    try:
        hard_cap = int(os.environ.get("BRIDGE_MCP_MISS_QUEUE_HARD_CAP", "500"))
    except ValueError:
        hard_cap = 500
    existing = []
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                existing = f.readlines()
        except OSError:
            existing = []
    existing.append(json.dumps(row, ensure_ascii=False) + "\n")
    if hard_cap > 0 and len(existing) > hard_cap:
        existing = existing[-hard_cap:]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(existing)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
