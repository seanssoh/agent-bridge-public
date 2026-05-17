#!/usr/bin/env python3
"""slot-from-datetime.py — normalize an ISO-8601 datetime to a cron slot
string (minute-precision ISO timestamp).

Invocation contract:
    sys.argv[1] = ISO-8601 datetime (may end with "Z").

Output: minute-precision ISO-8601 timestamp on stdout.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$value" <<'PY'` heredoc-stdin in
bridge_cron_slot_from_datetime. The slot derivation runs on every
one-shot dispatch path; moved to a standalone file invoked as
`python3 slot-from-datetime.py <iso>` to remove the heredoc-stdin path
— same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import sys
from datetime import datetime


def main() -> int:
    text = sys.argv[1]
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    print(dt.replace(second=0, microsecond=0).isoformat(timespec="minutes"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
