#!/usr/bin/env python3
"""auth-backfill-settings-json.py — render the aggregate JSON document for
`bridge_auth_backfill_settings_agents` (#1855 keychain-free settings backfill).

Invocation contract (file-as-argv, three `argv` buckets joined by sentinels):
    backfilled... "--" unchanged... "---" failed...

    - backfilled : agents whose settings.json was created/repaired (write
                   mode) or reported drift (--check mode).
    - unchanged  : agents already coherent with the managed apiKeyHelper.
    - failed     : agents the per-agent bridge-auth.py run could not process.

Output: a single JSON document on stdout, matching the prior inline shape:
    {"status", "backfilled", "unchanged", "failed", "non_clean"}

  - status = "ok"      when no failures
           = "failed"  when there were failures and nothing succeeded
           = "partial" otherwise
  - non_clean = backfilled OR failed (the caller's "needs attention" signal).

Footgun #11 (KNOWN_ISSUES §26): this body used to live as a
`python3 - "${backfilled[@]}" -- ... <<'PY' … PY` interpreter heredoc-stdin
inside bridge_auth_backfill_settings_agents. Moved to a standalone file to
remove the heredoc-stdin-to-subprocess path that wedges Bash 5.3.9
(read_comsub / heredoc_write deadlock). Invoked with file-as-argv per the
established lib/upgrade-helpers/ anti-heredoc pattern.
"""
import json
import sys


def main() -> int:
    items = sys.argv[1:]
    a = items.index("--") if "--" in items else len(items)
    backfilled = items[:a]
    rest = items[a + 1 :]
    b = rest.index("---") if "---" in rest else len(rest)
    unchanged = rest[:b]
    failed = rest[b + 1 :]
    status = "ok" if not failed else ("failed" if not (backfilled or unchanged) else "partial")
    print(json.dumps({
        "status": status,
        "backfilled": backfilled,
        "unchanged": unchanged,
        "failed": failed,
        "non_clean": bool(backfilled or failed),
    }, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
