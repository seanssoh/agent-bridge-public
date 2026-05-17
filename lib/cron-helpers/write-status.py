#!/usr/bin/env python3
"""write-status.py — serialize the cron run status.json that the
daemon and operator surfaces consume to render the current run state.

Invocation contract (8 positional argv):
    1 status_file (output path).
    2 run_id.
    3 state.
    4 engine.
    5 request_file.
    6 result_file.
    7 updated_at.
    8 error_message (may be empty).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - <8 argv> <<'PY'` heredoc-stdin in bridge_cron_write_status.
The status writer is touched on every cron state transition; moved to
a standalone file invoked with file-as-argv to remove the heredoc-stdin
path — same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    (
        status_file,
        run_id,
        state,
        engine,
        request_file,
        result_file,
        updated_at,
        error_message,
    ) = sys.argv[1:9]

    payload = {
        "run_id": run_id,
        "state": state,
        "engine": engine,
        "updated_at": updated_at,
        "request_file": request_file,
        "result_file": result_file,
    }
    if error_message:
        payload["error"] = error_message

    Path(status_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
