#!/usr/bin/env python3
"""write-completion-note.py — render the cron dispatch completion note
into a markdown file consumed by the cron-followup post-handler.

Invocation contract (6 positional argv):
    sys.argv[1] = run_id.
    sys.argv[2] = note_file (output markdown path).
    sys.argv[3] = followup_task_id (may be empty).
    sys.argv[4] = request.json path.
    sys.argv[5] = result.json path.
    sys.argv[6] = status.json path.

Exits 0 once the note file is written. Missing input files are
treated as empty dicts (matches the legacy heredoc semantics).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$run_id" "$note_file" "$followup_task_id" "$request_file"
"$result_file" "$status_file" <<'PY'` heredoc-stdin in
bridge_cron_write_completion_note. Cron completion notes are written
on every dispatch; moved to a standalone file invoked as
`python3 write-completion-note.py <run_id> <note> <followup> <req>
<res> <stat>` to remove the heredoc-stdin path — same precedent as
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
    run_id, note_file, followup_task_id, request_file, result_file, status_file = sys.argv[1:7]
    request_path = Path(request_file)
    result_path = Path(result_file)
    status_path = Path(status_file)
    note_path = Path(note_file)

    request = _load(request_path)
    result = _load(result_path)
    status = _load(status_path)

    job_name = request.get("job_name", "")
    slot = request.get("slot", "")
    state = status.get("state", result.get("status", "unknown"))

    lines = [
        "# Cron Dispatch Result",
        "",
        f"- run_id: {run_id}",
        f"- job: {job_name}",
        f"- family: {request.get('family', '')}",
        f"- slot: {slot}",
        f"- target_agent: {request.get('target_agent', '')}",
        f"- engine: {request.get('target_engine', '')}",
        f"- state: {state}",
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
    if followup_task_id:
        lines.append(f"- followup_task_id: {followup_task_id}")

    summary = str(result.get("summary", "")).strip()
    if summary:
        lines.extend(["", "## Summary", "", summary])

    recommended = result.get("recommended_next_steps") or []
    if recommended:
        lines.extend(["", "## Recommended Next Steps", ""])
        for item in recommended:
            lines.append(f"- {item}")

    runner_error = str(result.get("runner_error", "")).strip()
    if runner_error:
        lines.extend(["", "## Runner Error", "", runner_error])

    note_path.parent.mkdir(parents=True, exist_ok=True)
    note_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
