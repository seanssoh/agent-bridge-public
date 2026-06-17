#!/usr/bin/env python3
# scripts/smoke/1970-idle-reclaim-lease-aware-helpers/emit-queued-row.py
#
# Standalone helper for the issue #1970 idle-reclaim-lease-aware smoke.
# Emits a one-element `find-open --all --format json`-shaped payload for a
# single queued task so the smoke can drive lib/daemon-helpers/
# unclaimed-task-filter.py directly at the max(created_ts, updated_ts)
# boundary without standing up the full daemon escalation function.
#
# Extracted as a file-as-argv helper (NOT a heredoc-stdin `python3 -`
# subprocess) so the smoke stays clear of the footgun #11 heredoc-stdin
# deadlock class — see scripts/lint-heredoc-ban.sh.
#
# Usage:
#   emit-queued-row.py <created-ts> <updated-ts>
#   emit-queued-row.py <created-ts> --no-updated
#
# `--no-updated` omits the updated_ts field entirely (the bash↔python
# upgrade-window / legacy row shape) so the helper's created_ts fallback is
# exercised. Output (stdout): a JSON list with one queued task.

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(
            "usage: emit-queued-row.py <created-ts> (<updated-ts>|--no-updated)",
            file=sys.stderr,
        )
        return 2
    try:
        created_ts = int(argv[0])
    except ValueError:
        print(f"invalid created-ts: {argv[0]!r}", file=sys.stderr)
        return 2

    row = {
        "id": 4242,
        "title": "post-requeue queued task",
        "status": "queued",
        "assigned_to": "worker-a",
        "created_by": "requester",
        "priority": "normal",
        "claimed_by": "",
        "body_path": "",
        "created_ts": created_ts,
    }
    if argv[1] != "--no-updated":
        try:
            row["updated_ts"] = int(argv[1])
        except ValueError:
            print(f"invalid updated-ts: {argv[1]!r}", file=sys.stderr)
            return 2

    print(json.dumps([row], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
