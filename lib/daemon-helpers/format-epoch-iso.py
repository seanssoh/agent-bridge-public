#!/usr/bin/env python3
"""format-epoch-iso.py — convert a Unix epoch (passed as argv[1]) to an
ISO-8601 string with seconds precision. macOS /bin/date does not support
`-d @TS`, so bridge-daemon.sh routes through Python.

Invocation contract:
    sys.argv[1] = epoch seconds (string).

Output: ISO-8601 timestamp on stdout. Exits 0 on malformed input
(prints nothing) so the caller can fall back to the raw epoch.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$epoch" <<'PY'` heredoc-stdin in
bridge_daily_backup_format_epoch. The Bash 5.3.9 `read_comsub` /
`heredoc_write` deadlock chain triggered on operator hosts under
periodic dispatch pressure; moved to a standalone file invoked as
`python3 format-epoch-iso.py <epoch>` to remove the heredoc-stdin path
entirely — same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import datetime
import sys


def main() -> int:
    try:
        ts = int(sys.argv[1])
    except (IndexError, ValueError):
        return 0
    print(datetime.datetime.fromtimestamp(ts).isoformat(timespec="seconds"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
