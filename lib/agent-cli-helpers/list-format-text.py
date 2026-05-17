#!/usr/bin/env python3
"""list-format-text.py — render the human-readable `agent list` table from
the JSON envelope emitted by `emit_agent_records_json list`.

Invocation contract:
    sys.argv[1] = path to JSON file containing a list of agent records
                  (output of `emit_agent_records_json list "$tsv"`).

Output: the same multi-line table previously generated inline by the
`run_list` heredoc body in bridge-agent.sh.

Footgun #11 (refs queue task #4773): this body used to live as a
`bridge_agent_manage_python "$(emit_agent_records_json list "$output")" <<'PY'`
heredoc-stdin inside run_list. The double-nested pattern (outer parent
heredoc reader + inner `$()` capture of another heredoc consumer) wedged
Bash 5.3.9 `read_comsub`, producing 7-17 hour hangs on the operator host.
Moved to a standalone file invoked as `python3 list-format-text.py <path>`
to remove the heredoc-stdin path entirely — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1]:
        return 0
    with open(sys.argv[1], encoding="utf-8") as fh:
        items = json.load(fh)

    print("agent | eng | src | active | state | iso | q/c/b | wake | notify | chan | session | workdir")
    for item in items:
        suffix = " [admin]" if item.get("admin") else ""
        isolation = item.get("isolation", {}) or {}
        mode = isolation.get("mode") or "shared"
        os_user = isolation.get("os_user") or ""
        iso_text = f"{mode}:{os_user}" if os_user else mode
        # v0.8.0 T5: when the runtime hatch is on, override the iso column
        # so a glance at `agent-bridge agent list` makes it obvious the
        # boundary is off across the whole controller. The configured
        # isolation_mode stays available in the JSON form and in `agent
        # show` for operators who want both fields.
        runtime_state = isolation.get("runtime_state") or ""
        if runtime_state == "disabled-by-env":
            iso_text = "disabled-by-env"
        queue = item.get("queue", {}) or {}
        notify = item.get("notify", {}) or {}
        channels = item.get("channels", {}) or {}
        print(
            f"{item.get('agent','')}{suffix} | "
            f"{item.get('engine','')} | "
            f"{item.get('source','')} | "
            f"{'yes' if item.get('active') else 'no'} | "
            f"{item.get('activity_state','')} | "
            f"{iso_text} | "
            f"{queue.get('queued',0)}/{queue.get('claimed',0)}/{queue.get('blocked',0)} | "
            f"{item.get('wake_status','')} | "
            f"{notify.get('status','')} | "
            f"{channels.get('status','')} | "
            f"{item.get('session','')} | "
            f"{item.get('workdir','')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
