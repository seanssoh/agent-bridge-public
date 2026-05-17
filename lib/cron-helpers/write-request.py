#!/usr/bin/env python3
"""write-request.py — serialize the cron dispatch request.json consumed
by the cron worker.

Invocation contract (44 positional argv, all strings):
    1  request_file (output path).
    2  run_id.
    3  job_id.
    4  job_name.
    5  family.
    6  source_agent.
    7  target.
    8  slot.
    9  task_id (integer string).
    10 created_at.
    11 body_file.
    12 payload_file.
    13 result_file.
    14 status_file.
    15 stdout_log.
    16 stderr_log.
    17 source_file.
    18 payload_kind.
    19 target_engine.
    20 target_workdir.
    21 target_channels.
    22 target_discord_state_dir.
    23 target_telegram_state_dir.
    24 job_delivery_mode.
    25 job_delivery_channel.
    26 job_delivery_target.
    27 allow_channel_delivery ("1" or "0").
    28 routing_mode.
    29 disposable_needs_channels ("1" or "0").
    30 disable_mcp ("1" or "0").
    31 cron_reporting_policy.
    32 cron_urgency.
    33 shell_script.
    34 shell_args_json.
    35 shell_env_json.
    36 shell_run_as_agent.
    37 shell_os_user.
    38 shell_uid.
    39 shell_gid.
    40 shell_home.
    41 shell_agent_env_file.
    42 shell_env_snapshot_json.
    43 shell_timeout_seconds.
    44 shell_output_cap_bytes.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - <44 argv> <<'PY'` heredoc-stdin in bridge_cron_write_request.
The deeply parameterized argv plus large heredoc body was a textbook
trip site for Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock —
operator host cron-workers hung 13h on the same task id. Moved to a
standalone file invoked with file-as-argv to remove the heredoc-stdin
path — same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def _decode_json(value: str, fallback):
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        return fallback
    return decoded


def main() -> int:
    (
        request_file,
        run_id,
        job_id,
        job_name,
        family,
        source_agent,
        target,
        slot,
        task_id,
        created_at,
        body_file,
        payload_file,
        result_file,
        status_file,
        stdout_log,
        stderr_log,
        source_file,
        payload_kind,
        target_engine,
        target_workdir,
        target_channels,
        target_discord_state_dir,
        target_telegram_state_dir,
        job_delivery_mode,
        job_delivery_channel,
        job_delivery_target,
        allow_channel_delivery,
        routing_mode,
        disposable_needs_channels,
        disable_mcp,
        cron_reporting_policy,
        cron_urgency,
        shell_script,
        shell_args_json,
        shell_env_json,
        shell_run_as_agent,
        shell_os_user,
        shell_uid,
        shell_gid,
        shell_home,
        shell_agent_env_file,
        shell_env_snapshot_json,
        shell_timeout_seconds,
        shell_output_cap_bytes,
    ) = sys.argv[1:45]

    payload = {
        "run_id": run_id,
        "job_id": job_id,
        "job_name": job_name,
        "family": family,
        "source_agent": source_agent,
        "target_agent": target,
        "target_engine": target_engine,
        "target_workdir": target_workdir,
        "target_channels": target_channels,
        "target_discord_state_dir": target_discord_state_dir,
        "target_telegram_state_dir": target_telegram_state_dir,
        "routing_mode": routing_mode,
        "job_delivery_mode": job_delivery_mode,
        "job_delivery_channel": job_delivery_channel,
        "job_delivery_target": job_delivery_target,
        # PR1.4 — wire both keys; cron-runner reads `allow_structured_relay`
        # first and falls back to the legacy name.
        "allow_channel_delivery": allow_channel_delivery == "1",
        "allow_structured_relay": allow_channel_delivery == "1",
        "disposable_needs_channels": disposable_needs_channels == "1",
        "disable_mcp": disable_mcp == "1",
        "cron_reporting_policy": cron_reporting_policy,
        "cron_urgency": cron_urgency,
        "slot": slot,
        "dispatch_task_id": int(task_id),
        "created_at": created_at,
        "dispatch_body_file": body_file,
        "payload_file": payload_file,
        "payload_kind": payload_kind,
        "result_file": result_file,
        "status_file": status_file,
        "stdout_log": stdout_log,
        "stderr_log": stderr_log,
        "source_file": source_file,
    }
    if payload_kind == "shell":
        shell_payload = {
            "kind": "shell",
            "script": shell_script,
            "args": _decode_json(shell_args_json, []),
            "env": _decode_json(shell_env_json, {}),
            "timeoutSeconds": int(shell_timeout_seconds or 900),
            "outputCapBytes": int(shell_output_cap_bytes or 65536),
        }
        payload["payload"] = shell_payload
        payload["execution"] = {
            "run_as_agent": shell_run_as_agent,
            "os_user": shell_os_user,
            "uid": int(shell_uid),
            "gid": int(shell_gid),
            "home": shell_home,
            "agent_env_file": shell_agent_env_file,
            "env_snapshot": _decode_json(shell_env_snapshot_json, {}),
        }

    Path(request_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
