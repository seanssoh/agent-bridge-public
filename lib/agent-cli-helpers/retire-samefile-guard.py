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
`os.path.samefile` (inode-aware, not a case-sensitive string compare).

Invocation contract:
    sys.argv[1] = candidate directory (the path retire would mv)
    sys.argv[2] = path to a TSV file: one `id<TAB>home<TAB>workdir` row per
                  registered agent (home/workdir may be empty)

Output — a THREE-STATE verdict on stdout, first line, so an UNPROVABLE
comparison is never confused with a clean "not a registered agent" (codex r3,
the #1774/#1771 fail-closed pattern):
    `match\t<agent_id>` — the candidate IS that registered agent's dir;
                          retire MUST refuse.
    `indeterminate`     — a `samefile()`/realpath probe raised (stat failure
                          on the candidate or a registered dir) and no match
                          was proven; identity could NOT be established, so
                          retire MUST refuse and tell the operator to verify.
    `no-match`          — every registered dir resolved cleanly and none is
                          the same file; retire may proceed.
Always exits 0 (the verdict is on stdout). An unreadable rows file or missing
args yields `indeterminate` — we cannot prove the candidate is unregistered,
so the safe default is "refuse + ask the operator", never "allow".
"""

import os
import sys


def _emit(verdict: str) -> int:
    print(verdict)
    return 0


def _lexists(path: str) -> bool:
    """Return True if `path` exists (incl. a broken symlink), False ONLY when
    it is provably absent. A permission/other OSError errs toward True
    (present/unknown) so the caller fails SAFE (indeterminate) rather than
    treating an unreadable path as a clean no-match.
    """
    try:
        os.lstat(path)
        return True
    except FileNotFoundError:
        return False
    except NotADirectoryError:
        # A path component is a file — the leaf provably cannot exist.
        return False
    except OSError:
        # Permission or other error: cannot prove absence → treat as present.
        return True


def main() -> int:
    if len(sys.argv) < 3 or not sys.argv[1]:
        return _emit("indeterminate")
    candidate = sys.argv[1]
    rows_file = sys.argv[2]
    try:
        with open(rows_file, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return _emit("indeterminate")

    # Fail-safe rule (codex r3): a `samefile()` that RAISES must not silently
    # become "no-match". But registered `home`/`workdir` paths legitimately may
    # NOT EXIST yet (a v2 agent's `home` resolves to data/agents/<a>/home,
    # which is often not on disk; a registry-only agent has no scaffolded tree)
    # — and a samefile against a NON-EXISTENT registered dir is a CLEAN
    # no-match for that pair (an existing candidate cannot be a path that does
    # not exist). So `indeterminate` fires only when the probe could be MASKING
    # a real match: (a) the CANDIDATE itself is unstatable, or (b) a registered
    # dir EXISTS yet samefile still raised. A proven match always wins.
    indeterminate = False
    cand_exists = _lexists(candidate)
    if not cand_exists:
        # Cannot prove the candidate is NOT a live agent's dir if we cannot
        # even stat it. (run_retire only calls this for an existing home_dir,
        # but guard against a race/unreadable candidate anyway.)
        indeterminate = True
    try:
        cand_real = os.path.realpath(candidate)
    except OSError:
        cand_real = None

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
            if cand_real is not None:
                try:
                    base_real = os.path.realpath(base)
                except OSError:
                    base_real = None
                if base_real is not None and cand_real == base_real:
                    return _emit(f"match\t{agent_id}")
            try:
                if os.path.samefile(candidate, base):
                    return _emit(f"match\t{agent_id}")
            except OSError:
                # samefile raised. Clean no-match for this pair ONLY when the
                # registered dir provably does not exist; otherwise the raised
                # probe could be masking the case-variant collision → fail safe
                # to indeterminate (but only if the candidate is statable —
                # an unstatable candidate is already indeterminate above).
                if cand_exists and _lexists(base):
                    indeterminate = True
                continue
    if indeterminate:
        return _emit("indeterminate")
    return _emit("no-match")


if __name__ == "__main__":
    sys.exit(main())
