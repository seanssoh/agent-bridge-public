#!/usr/bin/env python3
"""unclaimed-task-filter.py — filter a `find-open --all --format json`
result down to TSV rows for queued tasks whose age exceeds the
threshold.

Invocation contract:
    sys.argv (none — all input via env)

Environment:
    BRIDGE_QUE_AGE_THRESHOLD — age threshold in seconds (default 1800).
    BRIDGE_QUE_NOW_TS        — current epoch seconds (default 0).
    BRIDGE_QUE_INPUT_JSON    — raw JSON list output of
                               `bridge_queue_cli find-open --all --format json`.

Output (stdout): TSV with one row per qualifying task, columns:
    task_id<TAB>age_seconds<TAB>title<TAB>created_by<TAB>priority

Notes:
  - Title and created_by have any embedded tab/newline collapsed to a
    single space so the bash side can `read -r` with IFS=$'\\t' without
    field corruption.
  - Malformed JSON produces an empty list (and exit 0). The caller
    treats an empty output as "no expired tasks this tick".

Exit 0 on success. The caller's heredoc-stdin failure-handling already
wrapped the python invocation in `|| { ... ; continue; }`, so any
non-zero exit is tolerated.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - <<'PY' >"$expired_tmp"` heredoc-stdin inside
process_unclaimed_queue_escalation. Same migration precedent as
mcp-miss-queue-enqueue.py.
"""

import json
import os
import sys


def main() -> int:
    try:
        threshold = int(os.environ.get("BRIDGE_QUE_AGE_THRESHOLD", "1800"))
    except ValueError:
        threshold = 1800
    try:
        now_ts = int(os.environ.get("BRIDGE_QUE_NOW_TS", "0"))
    except ValueError:
        now_ts = 0
    raw = os.environ.get("BRIDGE_QUE_INPUT_JSON", "[]")
    try:
        rows = json.loads(raw)
    except Exception:
        rows = []
    # Issue #2067: the daemon's blocked-aging REMINDER task
    # ("[blocked-aging] task #<id> needs status refresh", created_by=daemon,
    # assigned to the OWNING agent — bridge-queue.py process_blocked_task_aging
    # + BLOCKED_REMINDER_TITLE_PREFIX) is informational re-surfacing of the
    # agent's OWN blocked work, not new work a third party expects it to claim.
    # When the owning agent is busy those reminders age unclaimed and the
    # watchdog escalated EACH to admin — N blocked tasks -> N reminders -> N
    # admin tasks, pure noise. Skip that class here so it never admin-escalates
    # (it still re-surfaces on its own blocked-aging cadence to the owning
    # agent and stays claimable). The match is PRECISE — it requires BOTH the
    # reserved daemon title prefix AND created_by=='daemon' — so a genuine
    # work task that merely starts with that literal prefix (any other creator)
    # STILL escalates. NOT skipped: "[blocked-escalation] task #" — that row is
    # deliberately admin-assigned/admin-actionable, and an admin-assigned
    # unclaimed row is already audit-only via the daemon's admin-self-target
    # guard, so it generates no storm.
    BLOCKED_REMINDER_TITLE_PREFIX = "[blocked-aging] task #"

    for r in rows:
        if not isinstance(r, dict):
            continue
        if (r.get("status") or "") != "queued":
            continue
        if (r.get("created_by") or "") == "daemon" and str(
            r.get("title") or ""
        ).startswith(BLOCKED_REMINDER_TITLE_PREFIX):
            continue
        try:
            created_ts = int(r.get("created_ts", 0) or 0)
        except (TypeError, ValueError):
            created_ts = 0
        # Issue #1970: age the queued task from the most recent of created_ts
        # and updated_ts. A task that was just requeued (daemon stale-reclaim /
        # lease-expiry) or `agb update`-touched carries a fresh updated_ts; if
        # we aged only from created_ts, a long-lived task that cycled
        # claim→requeue would escalate the instant it re-queued even though it
        # is freshly available again. Grace it from the requeue/update point so
        # a genuinely-unclaimed task still escalates `threshold`s later, and the
        # caller's once-latch still emits at most one admin task. updated_ts is
        # exported by `find-open --all`; default to created_ts when absent
        # (bash↔python upgrade window) so behavior is unchanged for old rows.
        try:
            updated_ts = int(r.get("updated_ts", 0) or 0)
        except (TypeError, ValueError):
            updated_ts = 0
        freshness_ts = max(created_ts, updated_ts)
        age = now_ts - freshness_ts
        if age < threshold:
            continue
        task_id = r.get("id")
        title = (r.get("title") or "").replace("\t", " ").replace("\n", " ")
        created_by = (r.get("created_by") or "").replace("\t", " ")
        priority = (r.get("priority") or "normal").replace("\t", " ")
        sys.stdout.write(f"{task_id}\t{age}\t{title}\t{created_by}\t{priority}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
