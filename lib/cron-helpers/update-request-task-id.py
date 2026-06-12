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
    # Force the controller-private 0600 mode on the TEMP file BEFORE the publish
    # (#1842 codex r2). On an iso v2 host `bridge_cron_run_dir_grant_isolation`
    # installs a `default:group::rw-` ACL on the 3770 run dir, so the temp file
    # created HERE inherits a group-writable owning-group mode. request.json is
    # contractually controller-private 0600 (the runner's `pin_request_file`
    # fstat gate + `shell_artifact_route` both reject a group/other-writable
    # request file as tamper). The chmod must run BEFORE `os.replace`, not after:
    # the queue task is created before this rewrite, so a fast worker could open
    # the just-published inode in the gap between replace and a post-replace
    # chmod and (correctly) reject a group-writable request.json as tampered.
    # chmod-then-replace publishes an inode that is never group-writable. chmod
    # clears the owning-group ACL/mode bits; there is no named-group entry to
    # strip.
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
