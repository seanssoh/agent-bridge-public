#!/usr/bin/env python3
"""load-run-shell.py — emit shell `KEY=value` assignments for the
cron-followup environment.

Invocation contract:
    sys.argv[1] = request.json path.
    sys.argv[2] = result.json path.
    sys.argv[3] = status.json path.

Output: one `KEY=shell-quoted-value` per line on stdout. Missing
files are treated as empty dicts so the caller still gets the legacy
fields (mirrors the prior heredoc semantics).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$request_file" "$result_file" "$status_file" <<'PY'`
heredoc-stdin in bridge_cron_load_run_shell. The followup-builder
path runs on every cron completion (account-managed agents + admin
followups); moved to a standalone file invoked as
`python3 load-run-shell.py <request> <result> <status>` to remove
the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import shlex
import sys
from pathlib import Path


def _load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    request_file = Path(sys.argv[1])
    result_file = Path(sys.argv[2])
    status_file = Path(sys.argv[3])

    request = _load(request_file)
    result = _load(result_file)
    status = _load(status_file)

    fields = {
        "CRON_RUN_ID": request.get("run_id", request_file.parent.name),
        "CRON_JOB_ID": request.get("job_id", ""),
        "CRON_JOB_NAME": request.get("job_name", ""),
        "CRON_FAMILY": request.get("family", ""),
        "CRON_SLOT": request.get("slot", ""),
        "CRON_TARGET_AGENT": request.get("target_agent", ""),
        "CRON_TARGET_ENGINE": request.get("target_engine", ""),
        "CRON_RESULT_STATUS": result.get("status", ""),
        "CRON_RESULT_SUMMARY": result.get("summary", ""),
        "CRON_RUN_STATE": status.get("state", ""),
        # Issue #393: surface deferred_reason so the daemon can suppress
        # cron-followup tasks for memory_pressure deferrals. Empty string
        # for non-deferred runs (legacy callers see the same value).
        "CRON_DEFERRED_REASON": str(status.get("deferred_reason") or "").strip(),
        "CRON_RESULT_FILE": str(result_file),
        "CRON_STATUS_FILE": str(status_file),
        "CRON_STDOUT_LOG": request.get("stdout_log", ""),
        "CRON_STDERR_LOG": request.get("stderr_log", ""),
        "CRON_PROMPT_FILE": str(request_file.parent / "prompt.txt"),
        "CRON_NEEDS_HUMAN_FOLLOWUP": "1" if result.get("needs_human_followup") else "0",
        # Issue #345 Track B (instance #4): cron failures split into
        # admin-resolvable (close/refresh/retry) and human-config (config drift,
        # binding mismatch, retired-agent cleanup). Subagents may set
        # `failure_class` in result.json; jobs may carry a static
        # `failure_class` in request.json. Default `admin-resolvable` keeps
        # the legacy admin-queue path for unclassified failures.
        "CRON_FAILURE_CLASS": str(
            result.get("failure_class")
            or request.get("failure_class")
            or "admin-resolvable"
        ).strip().lower() or "admin-resolvable",
        # PR1.8 — surface the cron-runner reporting decision so the daemon can
        # gate its own followup-task path. Empty string when the cron-runner
        # didn't populate the field (legacy / pre-PR1 result.json).
        "CRON_REPORTING_DECISION": str(result.get("reporting_decision") or status.get("reporting_decision") or "").strip(),
        "CRON_DELIVERY_INTENT": str(result.get("delivery_intent") or status.get("delivery_intent") or "").strip(),
        "CRON_INBOX_TASK_ID": str(result.get("inbox_task_id") if result.get("inbox_task_id") is not None else (status.get("inbox_task_id") if status.get("inbox_task_id") is not None else "")),
    }

    for key, value in fields.items():
        print(f"{key}={shlex.quote(str(value))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
