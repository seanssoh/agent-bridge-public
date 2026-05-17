#!/usr/bin/env python3
"""show-format-json.py — render the JSON envelope for
`bridge-agent.sh show <agent> --json` by combining the inputs gathered
by `run_show`.

Invocation contract (5 positional arguments — file paths):
    sys.argv[1] = records.json     (emit_agent_records_json show <tsv>)
    sys.argv[2] = diagnostics.json (bridge_agent_channel_diagnostics_json)
    sys.argv[3] = session-health.json (bridge_agent_session_health_json)
    sys.argv[4] = session-source.txt (bridge_agent_session_source_path)
    sys.argv[5] = alive.json       (bridge_agent_alive_signals_json)

Output: a single JSON document on stdout matching the historical
`agent show --json` schema.

Footgun #11 (refs queue task #4773): this body used to live as a
`bridge_agent_manage_python "$(emit_agent_records_json show ...)" "$(...)" ... <<'PY'`
heredoc-stdin inside run_show. The deeply-nested `$()` captures (three
of which were themselves `python3 - <<'PY'` heredoc-stdin consumers)
plus the parent heredoc reader wedged Bash 5.3.9 `read_comsub`. Moved
to a standalone file invoked as
`python3 show-format-json.py <records> <diag> <health> <session-source> <alive>`
to remove all heredoc-stdin paths — same precedent as
lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys


def _read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    payload = _read_json(sys.argv[1])
    payload.setdefault("channels", {})["diagnostics"] = _read_json(sys.argv[2])
    payload["session_health"] = _read_json(sys.argv[3])
    session_source = _read_text(sys.argv[4]).strip()
    payload["session_source"] = session_source if session_source else None
    raw_alive = _read_text(sys.argv[5]).strip()
    alive_blob = json.loads(raw_alive) if raw_alive else {}
    payload["alive"] = bool(alive_blob.get("alive", False))
    payload["alive_signals"] = alive_blob.get("signals", {})
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
