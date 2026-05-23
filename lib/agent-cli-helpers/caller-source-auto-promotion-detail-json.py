#!/usr/bin/env python3
"""caller-source-auto-promotion-detail-json.py — issue #1122.

Emit the `detail` JSON for the `caller_source_auto_promotion` audit
row that `bridge_agent_update_caller_source` writes when an admin
Claude Code session implicitly upgrades its caller source from
`agent-direct` to `operator-trusted-id`.

Invocation contract (positional, both required):
    sys.argv[1] = actor       (the caller agent id, normally matches
                               BRIDGE_AGENT_ID==BRIDGE_ADMIN_AGENT_ID)
    sys.argv[2] = derived_from (signal name; currently always
                                "admin-agent-signal")

Output: a single JSON object on stdout.

Refs:
    - Footgun #11 / KNOWN_ISSUES.md §26: extracted to file-as-argv so
      the body never lives inside a `python3 - <<'PY' ... PY` heredoc
      block captured by `$()`. Same precedent as PR #940 (registry/
      list/show) and PR #4773 (audit-detail-json).
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: caller-source-auto-promotion-detail-json.py <actor> <derived_from>",
            file=sys.stderr,
        )
        return 2
    actor, derived_from = sys.argv[1], sys.argv[2]
    detail = {
        "kind": "caller_source_auto_promotion",
        "actor": actor,
        "caller_source_auto": True,
        "promoted_to": "operator-trusted-id",
        "derived_from": derived_from,
    }
    print(json.dumps(detail, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
