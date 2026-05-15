#!/usr/bin/env python3
"""agent-restart-json.py — convert the tab-separated agent-restart report
into the JSON structure embedded by `bridge_upgrade_agent_restart_json`.

Invocation contract:
    sys.argv[1] = enabled ("1" / anything else)
    sys.argv[2] = dry_run ("1" / anything else)
    sys.argv[3] = report (multi-line tab-separated string, see
                          `bridge_upgrade_collect_agent_restart_report`
                          for the 7-column tuple format)

Output: a single JSON document on stdout.

JSON key contract (post-#257): dry-run reports *eligibility*, not success;
apply reports the `bridge-agent.sh restart` exit-0 count, not agent health.
  - restart_eligible / restart_eligible_agents: dry-run candidates. This
    is what we would attempt; it does NOT predict whether the agent will
    stay stably up after launch (plugin resolution, settings corruption,
    dependency outages can still surface at apply).
  - restart_attempted_ok / restart_attempted_ok_agents: apply tally of
    `bridge-agent.sh restart` commands that returned exit 0. Does NOT
    prove the agent survived the first few seconds after launch; that
    requires post-restart health reconciliation (tracked in #256).
The prior keys `would_restart`/`restarted` over-promised at both layers
and caused the #253→#254 misdiagnosis. Renamed here per issue #257.

Footgun #11 (task #4538): this body used to live as a `python3 - <<'PY' … PY`
heredoc-stdin inside bridge_upgrade_agent_restart_json. Moved to a standalone
file to remove the heredoc-stdin path that wedges Bash 5.3.9.
"""

import base64
import json
import sys

enabled = sys.argv[1] == "1"
dry_run = sys.argv[2] == "1"
report = sys.argv[3]
payload = {
    "enabled": enabled,
    "dry_run": dry_run,
    "considered": 0,
    "eligible": 0,
    "restart_eligible": 0,
    "restart_attempted_ok": 0,
    "recovered_by_daemon": 0,
    "failed": 0,
    "skipped": 0,
    "restart_attempted_ok_agents": [],
    "restart_eligible_agents": [],
    "recovered_by_daemon_agents": [],
    "failed_agents": [],
    "failed_details": [],
    "recovered_by_daemon_details": [],
    "skipped_reasons": {},
}


def _decode_log_tail(raw_b64):
    """Return the decoded log-tail string or None when absent/corrupt.

    Deliberately plain-Python (no PEP 604 annotation) because the
    reference install's system python is 3.9.6 — `str | None` would
    raise `TypeError` at function-definition time before the summary
    ever ran. See PR #261 round-1 review.
    """
    if not raw_b64:
        return None
    try:
        decoded = base64.b64decode(raw_b64, validate=False)
    except Exception:  # noqa: BLE001 — b64 is operator-captured log; failing open with None is fine
        return None
    return decoded.decode("utf-8", errors="replace")


for raw in report.splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    # Tuple format (see bridge_upgrade_collect_agent_restart_report): 7 cols.
    # Older builds may emit 5 cols (pre-#256); tolerate that shape so a
    # half-upgraded host doesn't crash the aggregator.
    parts = (raw.split("\t", 6) + ["", "", "", "", "", "", ""])[:7]
    agent, status, reason, _attached, _session, exit_code, log_tail_b64 = parts
    payload["considered"] += 1
    if reason == "eligible":
        payload["eligible"] += 1
    if status == "would-restart":
        payload["restart_eligible"] += 1
        payload["restart_eligible_agents"].append(agent)
    elif status == "restarted":
        payload["restart_attempted_ok"] += 1
        payload["restart_attempted_ok_agents"].append(agent)
    elif status == "failed":
        payload["failed"] += 1
        payload["failed_agents"].append(agent)
        detail = {"agent": agent, "reason": reason}
        try:
            detail["exit_code"] = int(exit_code) if exit_code else None
        except ValueError:
            detail["exit_code"] = None
        detail["last_log_tail"] = _decode_log_tail(log_tail_b64)
        payload["failed_details"].append(detail)
    elif status == "recovered_by_daemon":
        # Issue 4 (v0.11.0): daemon launched the agent after our initial
        # restart attempt failed/timed-out. Counted separately so the
        # operator-facing summary stops over-reporting "failed" when the
        # daemon cycle absorbed the transient. Preserves the original
        # reason (encoded as `daemon-recovered:was=<original>`) plus the
        # exit_code + log_tail so the underlying issue is still
        # diagnosable from the JSON.
        payload["recovered_by_daemon"] += 1
        payload["recovered_by_daemon_agents"].append(agent)
        detail = {"agent": agent, "was_reason": reason.split("was=", 1)[-1] if "was=" in reason else reason}
        try:
            detail["exit_code"] = int(exit_code) if exit_code else None
        except ValueError:
            detail["exit_code"] = None
        detail["last_log_tail"] = _decode_log_tail(log_tail_b64)
        payload["recovered_by_daemon_details"].append(detail)
    else:
        payload["skipped"] += 1
        payload["skipped_reasons"][reason] = payload["skipped_reasons"].get(reason, 0) + 1

print(json.dumps(payload, ensure_ascii=False))
