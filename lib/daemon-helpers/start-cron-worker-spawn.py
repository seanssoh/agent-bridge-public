#!/usr/bin/env python3
"""start-cron-worker-spawn.py — fork-detach a `bridge-daemon.sh
run-cron-worker <task_id>` subprocess so the parent shell can return
immediately. Stdin is /dev/null; stdout/stderr append to the given log
file; the child runs in a new session.

Invocation contract:
    sys.argv[1] = path to bash binary (BRIDGE_BASH_BIN).
    sys.argv[2] = path to bridge-daemon.sh script.
    sys.argv[3] = task id.
    sys.argv[4] = path to worker log file (created/appended).

Exits 0 once the subprocess is started; non-zero only on Python-side
exceptions before fork.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" "$task_id"
"$log_file" <<'PY' >/dev/null` heredoc-stdin in start_cron_worker.
The cron-dispatch start path runs concurrently with daemon polling and
can wedge under Bash 5.3.9 `read_comsub` / `heredoc_write` pressure;
moved to a standalone file invoked as
`python3 start-cron-worker-spawn.py <bash> <script> <task_id> <log>`
to remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import os
import subprocess
import sys


def main() -> int:
    bash_bin, daemon_script, task_id, log_file = sys.argv[1:5]
    with open(os.devnull, "rb") as stdin_handle, open(log_file, "ab", buffering=0) as log_handle:
        subprocess.Popen(
            [bash_bin, daemon_script, "run-cron-worker", task_id],
            stdin=stdin_handle,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
            close_fds=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
