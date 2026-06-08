#!/usr/bin/env python3
"""Issue #1670 smoke probe: bridge-upgrade.py rematerialize identity guard.

File-as-argv helper (footgun #11 / lint-heredoc-ban): the probe body lives here
and is invoked as `python3 <this> <repo_root>` from the smoke, NOT as a
`python3 - <<'PY'` heredoc-stdin subprocess.

Exits 0 + prints an OK line when the Python-side guard in
`rematerialize_agent_identity()` re-keys blank/mismatched agent payloads to a
structured error (keyed on the asked-for agent) and passes a correct payload
through unchanged. Exits 1 + prints FAIL lines otherwise.
"""

import importlib.util
import json as _json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("FAIL: usage: 1670-rematerialize-dryrun-agent-preserved-helper.py <repo_root>")
        return 1
    repo_root = Path(sys.argv[1])

    spec = importlib.util.spec_from_file_location(
        "bridge_upgrade", repo_root / "bridge-upgrade.py"
    )
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so the @dataclass field-type resolution (the module
    # uses `from __future__ import annotations`) can find the module in
    # sys.modules.
    sys.modules["bridge_upgrade"] = mod
    spec.loader.exec_module(mod)

    # Build the smallest AgentMigrationResult the guard touches (agent + engine).
    result = mod.AgentMigrationResult(
        agent="boundary",
        added_files=[],
        created_dirs=[],
        updated_files=[],
        session_type="static-claude",
        engine="claude",
    )

    # Stand in for the helper subprocess: emit a payload with a BLANK agent +
    # usage error (the historical #1670 shape) and a separate MISMATCHED-agent
    # payload.
    class _Proc:
        def __init__(self, stdout):
            self.stdout = stdout
            self.stderr = ""
            self.returncode = 0

    cases = {
        "blank-agent": _json.dumps({
            "agent": "",
            "status": "error",
            "source_dir": "",
            "target_dir": "",
            "errors": ["usage: rematerialize-agent-identity.sh ..."],
        }),
        "mismatched-agent": _json.dumps({
            "agent": "CLAUDE.md",
            "status": "applied",
            "source_dir": ".claude/commands/wrap-up.md",
            "target_dir": "",
        }),
        "correct-agent": _json.dumps({
            "agent": "boundary",
            "status": "planned",
            "source_dir": "/x/agents/boundary",
            "target_dir": "/x/agents/boundary/workdir",
            "updated_paths": [],
        }),
    }

    orig_run = mod.subprocess.run
    helper_path = repo_root / "lib" / "upgrade-helpers" / "rematerialize-agent-identity.sh"
    if not helper_path.exists():
        print("FAIL: helper path missing for guard test")
        return 1

    failures = []
    for label, stdout in cases.items():
        def _fake_run(*_a, _stdout=stdout, **_kw):
            return _Proc(_stdout)
        mod.subprocess.run = _fake_run
        try:
            payload = mod.rematerialize_agent_identity(repo_root, Path("/x"), result, True)
        finally:
            mod.subprocess.run = orig_run

        if label == "correct-agent":
            if payload.get("agent") != "boundary" or payload.get("status") != "planned":
                failures.append(f"{label}: correct payload was not passed through ({payload!r})")
        else:
            if payload.get("agent") != "boundary":
                failures.append(f"{label}: guard did not re-key the error to the asked-for agent ({payload!r})")
            if payload.get("status") != "error":
                failures.append(f"{label}: guard did not produce a structured error ({payload!r})")
            errs = payload.get("errors") or []
            if not any("mismatched agent identity" in str(e) for e in errs):
                failures.append(f"{label}: guard error message missing the mismatch detail ({errs!r})")

    if failures:
        for f in failures:
            print("FAIL: " + f)
        return 1
    print("OK: python-side guard re-keys blank/mismatched agent payloads and passes correct ones through")
    return 0


if __name__ == "__main__":
    sys.exit(main())
