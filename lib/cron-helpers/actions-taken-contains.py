#!/usr/bin/env python3
"""actions-taken-contains.py — exit-code predicate: is `action` in the
`actions_taken` list of the given result.json?

Invocation contract:
    sys.argv[1] = path to result.json.
    sys.argv[2] = action string to search for.

Exit codes:
    0 — action found.
    1 — missing file, malformed JSON, non-list actions, or not present.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$result_file" "$action" <<'PY'` heredoc-stdin in
bridge_cron_actions_taken_contains. Moved to a standalone file invoked
with file-as-argv to remove the heredoc-stdin path — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys


def main() -> int:
    result_file = sys.argv[1]
    action = sys.argv[2]

    try:
        with open(result_file, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return 1

    actions = data.get("actions_taken") or []
    if not isinstance(actions, list):
        return 1

    return 0 if action in actions else 1


if __name__ == "__main__":
    sys.exit(main())
