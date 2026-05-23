#!/usr/bin/env python3
"""1105 smoke helper — count `system_config_mutation` audit rows in
the smoke's audit log, ignoring trigger. Missing file is treated as
zero rows (the rollback variant deletes the audit log between runs).

Invocation contract (positional):
    sys.argv[1] = path to the audit log (jsonl).

Footgun #11 (KNOWN_ISSUES.md §26): standalone helper invoked
file-as-argv to keep heredoc-stdin off the Bash 5.3.9 deadlock
surface. See last-create-audit-detail.py for the same rationale.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: audit-row-count.py <audit-log-path>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    count = 0
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        print(0)
        return 0
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("action") == "system_config_mutation":
                count += 1
    print(count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
