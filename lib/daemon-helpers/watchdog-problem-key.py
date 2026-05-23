#!/usr/bin/env python3
"""watchdog-problem-key.py — compute a stable SHA-256 hash over the
watchdog report's agent list, with the per-scan `heartbeat_age_seconds`
field excluded so unchanged drift dedupes correctly.

Invocation contract:
    sys.argv[1] = report_json (raw JSON string).

Output: hex SHA-256 digest on stdout. Empty input prints "".
Malformed JSON falls back to hashing the raw payload so the daemon
still has a stable key to dedupe against.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$report_json" <<'PY'` heredoc-stdin in
bridge_watchdog_problem_key. With a multi-KB report payload, the
Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock wedges the
watchdog tick; moved to a standalone file invoked as
`python3 watchdog-problem-key.py <report>` to remove the heredoc-stdin
path — same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import hashlib
import json
import sys


def main() -> int:
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.loads(raw)
    except Exception:
        print(hashlib.sha256(raw.encode("utf-8")).hexdigest() if raw else "")
        return 0

    agents = []
    for item in payload.get("agents", []):
        if isinstance(item, dict):
            stable = dict(item)
            # Age advances every scan; keep heartbeat_present, but exclude the
            # volatile age value so unchanged drift dedupes correctly.
            stable.pop("heartbeat_age_seconds", None)
            # #1119 r2: drop empty error_kind/error_path on healthy rows so
            # dedup hashes pre/post-#1119 match for unchanged problems. The
            # fields stay in the watchdog JSON output (so consumers can read
            # them when populated); only the dedup signature ignores them
            # when empty.
            for empty_field in ("error_kind", "error_path"):
                if stable.get(empty_field, "") == "":
                    stable.pop(empty_field, None)
            agents.append(stable)
        else:
            agents.append(item)
    canonical = json.dumps(agents, sort_keys=True, separators=(",", ":"))
    print(hashlib.sha256(canonical.encode("utf-8")).hexdigest() if canonical else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
