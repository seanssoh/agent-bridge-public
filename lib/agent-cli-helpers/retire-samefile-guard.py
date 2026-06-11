#!/usr/bin/env python3
"""retire-samefile-guard.py — Issue #1787 filesystem-aware retire preflight.

`agent retire <name>` resolves an unregistered name to a directory under the
agent home root and plans an `mv` of it. On a case-insensitive volume (macOS
APFS default) `agents/CRM-TEST-BSH` and the registry's `agents/crm-test-bsh`
are the SAME directory, so a case-variant spelling of a LIVE agent's name is
classified as "unregistered" and retire would quarantine the live agent's
settings tree (dangling its workdir `settings.json` symlink — the #1766
"Settings Error" picker class). This guard runs BEFORE the mv: it checks the
candidate dir against every registered agent's home + workdir with
`os.path.samefile` (inode-aware, not a case-sensitive string compare) and, on
a match, prints the registered agent id so the caller can refuse with a
pointer to the real name.

Invocation contract:
    sys.argv[1] = candidate directory (the path retire would mv)
    sys.argv[2] = path to a TSV file: one `id<TAB>home<TAB>workdir` row per
                  registered agent (home/workdir may be empty)

Output: the matching registered agent id on stdout (one line) when the
candidate IS a registered agent's dir; nothing (empty stdout) when it is not.
Always exits 0 — an indeterminate or unreadable comparison prints nothing
(the caller's default-allow path keeps retire working for genuine orphans);
the SAFE direction is enforced positively (only a proven samefile match
refuses), mirroring the doctor's orphan detector which conversely fails safe
toward "registered". Here a false "registered" would block a legitimate
orphan retire, so retire only refuses on a PROVEN match.
"""

import os
import sys


def _realpath(path: str) -> str:
    try:
        return os.path.realpath(path)
    except OSError:
        return path


def main() -> int:
    if len(sys.argv) < 3 or not sys.argv[1]:
        return 0
    candidate = sys.argv[1]
    rows_file = sys.argv[2]
    try:
        with open(rows_file, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return 0

    cand_real = _realpath(candidate)
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        agent_id = parts[0].strip() if parts else ""
        if not agent_id:
            continue
        for base in parts[1:3]:
            base = base.strip()
            if not base:
                continue
            base = os.path.expanduser(base)
            if cand_real == _realpath(base):
                print(agent_id)
                return 0
            try:
                if os.path.samefile(candidate, base):
                    print(agent_id)
                    return 0
            except OSError:
                # Either side unstatable (a registered dir scaffolded lazily,
                # or the candidate is absent). The exact-realpath compare
                # above already ruled out a string match, so a stat failure
                # here is a genuine "different or missing path", not the
                # case-variant collision we guard against. Try the next dir.
                continue
    return 0


if __name__ == "__main__":
    sys.exit(main())
