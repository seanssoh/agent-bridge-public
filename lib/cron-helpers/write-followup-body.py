#!/usr/bin/env python3
"""write-followup-body.py — render the cron-followup task body for the
parent agent that receives the dispatch result.

Invocation contract (5 positional argv):
    sys.argv[1] = run_id.
    sys.argv[2] = body_file (output markdown path).
    sys.argv[3] = request.json path.
    sys.argv[4] = result.json path.
    sys.argv[5] = status.json path.

Exits 0 once the body file is written. Missing input files are
treated as empty dicts (matches the legacy heredoc semantics).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$run_id" "$body_file" "$request_file" "$result_file"
"$status_file" <<'PY'` heredoc-stdin in bridge_cron_write_followup_body.
The followup body is written on every cron completion routed back to
a parent agent; moved to a standalone file invoked as
`python3 write-followup-body.py <run_id> <body> <req> <res> <stat>`
to remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def _load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    run_id, body_file, request_file, result_file, status_file = sys.argv[1:6]
    request_path = Path(request_file)
    result_path = Path(result_file)
    status_path = Path(status_file)
    body_path = Path(body_file)

    request = _load(request_path)
    result = _load(result_path)
    status = _load(status_path)

    job_name = request.get("job_name", run_id)
    title = f"# [cron-followup] {job_name}"
    lines = [
        title,
        "",
        f"- run_id: {run_id}",
        f"- slot: {request.get('slot', '')}",
        f"- family: {request.get('family', '')}",
        f"- target_agent: {request.get('target_agent', '')}",
        f"- engine: {request.get('target_engine', '')}",
        f"- run_state: {status.get('state', '')}",
        f"- child_status: {result.get('status', '')}",
        f"- request_file: {request_file}",
        f"- result_file: {result_file}",
        f"- status_file: {status_file}",
    ]

    stdout_log = request.get("stdout_log")
    stderr_log = request.get("stderr_log")
    if stdout_log:
        lines.append(f"- stdout_log: {stdout_log}")
    if stderr_log:
        lines.append(f"- stderr_log: {stderr_log}")

    summary = str(result.get("summary", "")).strip()
    if summary:
        lines.extend(["", "## Summary", "", summary])

    channel_relay = result.get("channel_relay") if isinstance(result.get("channel_relay"), dict) else None
    if channel_relay:
        lines.extend(["", "## Channel Relay", ""])
        for key in ("transport", "target", "urgency", "subject"):
            value = str(channel_relay.get(key, "")).strip()
            if value:
                lines.append(f"- {key}: {value}")
        lines.extend(["", "### Relay Body", "", str(channel_relay.get("body", "")).rstrip(), ""])

    for section, key in (
        ("Findings", "findings"),
        ("Actions Taken", "actions_taken"),
        ("Recommended Next Steps", "recommended_next_steps"),
        ("Artifacts", "artifacts"),
    ):
        values = result.get(key) or []
        if not values:
            continue
        lines.extend(["", f"## {section}", ""])
        for item in values:
            lines.append(f"- {item}")

    runner_error = str(result.get("runner_error", "")).strip()
    if runner_error:
        lines.extend(["", "## Runner Error", "", runner_error])

    if channel_relay:
        lines.extend([
            "## Action Required",
            "",
            "You are the parent agent receiving this cron result. You MUST:",
            "1. Review the summary, findings, and typed Channel Relay payload above",
            "2. Send the relay body from your own parent session using your human-facing channel tool",
            "3. Treat transport/target as routing hints unless request metadata or parent policy overrides them",
            "4. Mark this task done with delivery evidence or the concrete blocker",
            "",
            "Do NOT delegate the final send back to a disposable child. The parent session must own the outbound message.",
        ])
    else:
        lines.extend([
            "",
            "## Action Required",
            "",
            "You are the parent agent receiving this cron result. You MUST:",
            "1. Review the summary and findings above",
            "2. Post a concise report to your Discord or Telegram channel",
            "3. If recommended_next_steps includes DM or notification targets, execute them",
            "4. Mark this task done with a note summarizing what you reported",
            "",
            "Do NOT just acknowledge this task silently. Your channel subscribers expect reports.",
        ])

    body_path.parent.mkdir(parents=True, exist_ok=True)
    body_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
