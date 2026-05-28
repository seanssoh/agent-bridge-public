#!/usr/bin/env python3
"""show-format-json.py — render the JSON envelope for
`bridge-agent.sh show <agent> --json` by combining the inputs gathered
by `run_show`.

Invocation contract (6 positional arguments — file paths):
    sys.argv[1] = records.json     (emit_agent_records_json show <tsv>)
    sys.argv[2] = diagnostics.json (bridge_agent_channel_diagnostics_json)
    sys.argv[3] = session-health.json (bridge_agent_session_health_json)
    sys.argv[4] = session-source.txt (bridge_agent_session_source_path)
    sys.argv[5] = alive.json       (bridge_agent_alive_signals_json)
    sys.argv[6] = iso-boundary-quickref.txt
                  Each line is one "key: value" row from
                  bridge_agent_iso_boundary_quickref_text. Empty file =
                  shared-mode agent (skip — payload becomes `null`).
                  Added in Issue #1357 (v0.15.0-beta5-2 Lane E).

Output: a single JSON document on stdout matching the historical
`agent show --json` schema, extended with `iso_boundary_quickref`
(null for shared-mode agents, list of rows for iso v2 effective agents).

Footgun #11 (refs queue task #4773): this body used to live as a
`bridge_agent_manage_python "$(emit_agent_records_json show ...)" "$(...)" ... <<'PY'`
heredoc-stdin inside run_show. The deeply-nested `$()` captures (three
of which were themselves `python3 - <<'PY'` heredoc-stdin consumers)
plus the parent heredoc reader wedged Bash 5.3.9 `read_comsub`. Moved
to a standalone file invoked as
`python3 show-format-json.py <records> <diag> <health> <session-source> <alive> <iso-quickref>`
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
    # Issue #1357: surface the same quickref text-mode emits. Empty file
    # marker (shared mode) maps to null; non-empty file becomes a list so
    # downstream consumers can render each row independently without
    # re-parsing a blob. Defensive: if argv[6] is missing (older
    # dispatchers) treat as null rather than raising IndexError so the
    # JSON contract stays backward-compatible during a partial upgrade.
    quickref_rows = None
    if len(sys.argv) > 6:
        raw_quickref = _read_text(sys.argv[6])
        rows = [line for line in raw_quickref.splitlines() if line.strip()]
        if rows:
            quickref_rows = rows
    payload["iso_boundary_quickref"] = quickref_rows
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
