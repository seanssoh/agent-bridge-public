#!/usr/bin/env python3
"""default-slot-now.py — emit the default cron slot timestamp for
families other than `monthly-highlights` and `memory-daily`.

Invocation contract:
    No arguments. Stdout is the current local-time ISO-8601 stamp
    truncated to minutes (matches the legacy heredoc body in
    bridge_cron_default_slot).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - <<'PY'` heredoc-stdin in bridge_cron_default_slot. The
default-slot path runs on every cron tick, so the deadlock surface is
hot; moved to a standalone file invoked as
`python3 default-slot-now.py` to remove the heredoc-stdin path entirely
— same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

from datetime import datetime, timezone


def main() -> int:
    print(datetime.now(timezone.utc).astimezone().replace(second=0, microsecond=0).isoformat(timespec="minutes"))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
