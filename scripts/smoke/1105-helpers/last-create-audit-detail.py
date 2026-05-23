#!/usr/bin/env python3
"""1105 smoke helper — lift the last `system_config_mutation` audit row
whose detail.trigger == "agent-create-apply" out of the smoke's audit
log, and print the detail object as one JSON line on stdout.

Invocation contract (positional):
    sys.argv[1] = path to the audit log (jsonl).

The detail field on each audit envelope may be either a JSON-encoded
string or a dict — handle both shapes so the helper stays robust
against future audit-log shape tweaks.

Footgun #11 (KNOWN_ISSUES.md §26): the body originally lived inside
`python3 - "$BRIDGE_AUDIT_LOG" <<'PY' … PY` inside the smoke script.
Bash 5.3.9's heredoc-stdin deadlocks the moment a parent capture
chains through the heredoc, so this body is now a standalone helper
invoked file-as-argv. Same precedent as
lib/agent-cli-helpers/audit-detail-json.py.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: last-create-audit-detail.py <audit-log-path>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    last = None
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        print("no agent-create-apply row in audit log", file=sys.stderr)
        return 1
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("action") != "system_config_mutation":
                continue
            detail = row.get("detail")
            if isinstance(detail, str):
                try:
                    detail = json.loads(detail)
                except ValueError:
                    continue
            if not isinstance(detail, dict):
                continue
            if detail.get("trigger") != "agent-create-apply":
                continue
            last = detail
    if last is None:
        print("no agent-create-apply row in audit log", file=sys.stderr)
        return 1
    print(json.dumps(last, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
