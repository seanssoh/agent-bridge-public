#!/usr/bin/env python3
"""update-request-task-id.py — atomic rewrite of request.json with the
real queue task id after the queue task is created (dispatch ordering
defers queue create to the end so the worker cannot claim before
request/status/manifest/ACL are ready).

Invocation contract:
    sys.argv[1] = path to request.json (must exist).
    sys.argv[2] = task_id (integer string).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$request_file" "$task_id" <<'PY'` heredoc-stdin in
bridge_cron_update_request_task_id. Moved to a standalone file invoked
with file-as-argv to remove the heredoc-stdin path — same precedent
as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import os
import sys


def main() -> int:
    path = sys.argv[1]
    task_id = int(sys.argv[2])

    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    data["dispatch_task_id"] = task_id

    tmp = path + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=True, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
