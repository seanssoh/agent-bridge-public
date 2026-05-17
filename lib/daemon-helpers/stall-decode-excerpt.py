#!/usr/bin/env python3
"""stall-decode-excerpt.py — base64-decode a stall-report excerpt for
the daemon. Empty input prints nothing and exits 0.

Invocation contract:
    sys.argv[1] = base64-encoded payload (may be empty).

Output: utf-8 decoded text on stdout (no trailing newline).

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$encoded" <<'PY'` heredoc-stdin in bridge_stall_decode_excerpt.
The Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock chain triggers
on the stall-report path under heavy watchdog scanning; moved to a
standalone file invoked as `python3 stall-decode-excerpt.py <encoded>`
to remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import base64
import sys


def main() -> int:
    payload = sys.argv[1] if len(sys.argv) > 1 else ""
    if not payload:
        return 0
    print(base64.b64decode(payload.encode("ascii")).decode("utf-8", errors="ignore"), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
