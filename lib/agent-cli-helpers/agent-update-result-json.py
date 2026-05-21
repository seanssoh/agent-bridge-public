#!/usr/bin/env python3
"""agent-update-result-json.py — pretty-print the `agent update` result
envelope for `agent-bridge agent update --json`.

Invocation contract (positional, all required, all may be empty
strings):
    sys.argv[1]  = agent
    sys.argv[2]  = changed ("1" / "0")
    sys.argv[3]  = dry_run ("1" / "0")
    sys.argv[4]  = before_launch_cmd
    sys.argv[5]  = after_launch_cmd
    sys.argv[6]  = before_channels
    sys.argv[7]  = after_channels
    sys.argv[8]  = before_sha
    sys.argv[9]  = after_sha
    sys.argv[10] = actions_json (JSON array literal; empty/invalid -> [])

Output: a single pretty-printed JSON object on stdout.

Refs:
    - Footgun #11 / KNOWN_ISSUES.md §26: the body used to live as
      `python3 - … <<'PY' … PY` inside bridge_agent_update_emit_json.
      Extracted to a standalone file invoked file-as-argv so the
      heredoc-stdin path is gone (same precedent as PR #940 / #815).
    - Issue #1023: launch commands routinely carry credential-bearing
      env values. The `--json` envelope is pasted into terminals, logs,
      and task reports, so before/after launch_cmd and the recorded
      add-env actions are routed through the shared launch-cmd-redact
      module. Redaction is value-only — env key names stay visible.
"""

import importlib
import json
import os
import sys

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "scripts",
        "python-helpers",
    ),
)
_redact = importlib.import_module("launch-cmd-redact")


def main() -> int:
    # 10 payload args + script name == 11.
    if len(sys.argv) != 11:
        print(
            "usage: agent-update-result-json.py "
            "<agent> <changed> <dry_run> <before_launch_cmd> "
            "<after_launch_cmd> <before_channels> <after_channels> "
            "<before_sha> <after_sha> <actions_json>",
            file=sys.stderr,
        )
        return 2

    (
        agent,
        changed,
        dry_run,
        before_launch_cmd,
        after_launch_cmd,
        before_channels,
        after_channels,
        before_sha,
        after_sha,
        actions_json,
    ) = sys.argv[1:]

    try:
        actions = json.loads(actions_json) if actions_json else []
    except (TypeError, ValueError):
        actions = []

    payload = {
        "agent": agent,
        "changed": changed == "1",
        "dry_run": dry_run == "1",
        "before": {
            "launch_cmd": _redact.redact_launch_cmd(before_launch_cmd),
            "channels": before_channels,
        },
        "after": {
            "launch_cmd": _redact.redact_launch_cmd(after_launch_cmd),
            "channels": after_channels,
        },
        "before_sha": before_sha,
        "after_sha": after_sha,
        "actions": _redact.redact_actions(actions),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
