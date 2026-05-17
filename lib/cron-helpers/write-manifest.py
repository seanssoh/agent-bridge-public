#!/usr/bin/env python3
"""write-manifest.py — serialize the cron dispatch manifest JSON.

Invocation contract (26 positional argv, all strings):
    sys.argv[1]  = manifest_file (output path).
    sys.argv[2]  = job_id.
    sys.argv[3]  = job_name.
    sys.argv[4]  = family.
    sys.argv[5]  = source_agent.
    sys.argv[6]  = target.
    sys.argv[7]  = slot.
    sys.argv[8]  = task_id (integer string).
    sys.argv[9]  = created_at.
    sys.argv[10] = body_file.
    sys.argv[11] = source_file.
    sys.argv[12] = run_id.
    sys.argv[13] = request_file.
    sys.argv[14] = payload_file.
    sys.argv[15] = result_file.
    sys.argv[16] = status_file.
    sys.argv[17] = stdout_log.
    sys.argv[18] = stderr_log.
    sys.argv[19] = job_delivery_mode.
    sys.argv[20] = job_delivery_channel.
    sys.argv[21] = job_delivery_target.
    sys.argv[22] = allow_channel_delivery ("1" or "0").
    sys.argv[23] = routing_mode.
    sys.argv[24] = disposable_needs_channels ("1" or "0").
    sys.argv[25] = cron_reporting_policy.
    sys.argv[26] = cron_urgency.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - <25 argv> <<'PY'` heredoc-stdin in bridge_cron_write_manifest.
The manifest writer runs on every cron dispatch; moved to a standalone
file invoked with file-as-argv to remove the heredoc-stdin path —
same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    (
        manifest_file,
        job_id,
        job_name,
        family,
        source_agent,
        target,
        slot,
        task_id,
        created_at,
        body_file,
        source_file,
        run_id,
        request_file,
        payload_file,
        result_file,
        status_file,
        stdout_log,
        stderr_log,
        job_delivery_mode,
        job_delivery_channel,
        job_delivery_target,
        allow_channel_delivery,
        routing_mode,
        disposable_needs_channels,
        cron_reporting_policy,
        cron_urgency,
    ) = sys.argv[1:27]

    payload = {
        "job_id": job_id,
        "job_name": job_name,
        "family": family,
        "source_agent": source_agent,
        "target_agent": target,
        "routing_mode": routing_mode,
        "job_delivery_mode": job_delivery_mode,
        "job_delivery_channel": job_delivery_channel,
        "job_delivery_target": job_delivery_target,
        # PR1.4 — `allow_channel_delivery` is the legacy key name. Wire the
        # new `allow_structured_relay` alongside it so the cron-runner can
        # read the new name preferentially while existing operator surfaces
        # (manifest readers, audit consumers) keep seeing the old key.
        "allow_channel_delivery": allow_channel_delivery == "1",
        "allow_structured_relay": allow_channel_delivery == "1",
        "disposable_needs_channels": disposable_needs_channels == "1",
        "cron_reporting_policy": cron_reporting_policy,
        "cron_urgency": cron_urgency,
        "slot": slot,
        "task_id": int(task_id),
        "created_at": created_at,
        "run_id": run_id,
        "body_file": body_file,
        "request_file": request_file,
        "payload_file": payload_file,
        "result_file": result_file,
        "status_file": status_file,
        "stdout_log": stdout_log,
        "stderr_log": stderr_log,
        "source_file": source_file,
    }

    Path(manifest_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
