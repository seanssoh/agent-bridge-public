#!/usr/bin/env python3
"""registry-format-json.py — render the JSON inventory emitted by
`bridge-agent.sh registry` from the tab-separated rows produced by
`run_registry`.

Invocation contract:
    sys.argv[1] = path to TSV file with the run_registry row format
                  (10 tab-separated columns, see run_registry comment for
                  the schema).

Output: a single JSON document on stdout — sorted by `id` for stable
diffs.

Footgun #11 (refs queue task #4773): this body used to live as a
`bridge_agent_manage_python "$rows" <<'PY'` heredoc-stdin inside
run_registry. The function-wrapper + heredoc-stdin combination wedged
Bash 5.3.9 `read_comsub` on the operator host, producing 7-17 hour hangs
on every `bridge-agent.sh registry` invocation. Moved to a standalone
file invoked as `python3 registry-format-json.py <path>` — same
precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1]:
        raw = ""
    else:
        with open(sys.argv[1], encoding="utf-8") as fh:
            raw = fh.read()

    records = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 10:
            continue
        (id_, cls, agent_source, privilege_class, home, workdir,
         engine, session, is_alive, source) = parts[:10]
        records.append({
            "id": id_,
            "class": cls,
            "agent_source": agent_source,
            "privilege_class": privilege_class,
            "home": home,
            "workdir": workdir,
            "engine": engine,
            "session": session,
            "is_alive": is_alive == "1",
            "source": source,
        })

    records.sort(key=lambda r: r["id"])
    print(json.dumps(records, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
