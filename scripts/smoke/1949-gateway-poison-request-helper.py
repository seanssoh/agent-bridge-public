#!/usr/bin/env python3
"""File-as-argv sidecar for scripts/smoke/1949-gateway-poison-request.sh.

Footgun #11 / C1: the smoke shell drives every Python step through THIS helper
(file-as-argv) — never `python3 - <<'PY'` heredoc-stdin to a subprocess.

F8 (#1949): a single poison request (an inaccessible / nonexistent recorded cwd,
or a malformed payload) must NOT abort the `serve-once` batch and must NOT loop
forever as a re-drained `.working.json`. These steps build a gateway root with a
poison request + a healthy sibling, run the REAL `serve-once`, and assert the
batch survived: it exits 0, drains BOTH requests, writes a response for the
healthy one, and retires (dead-letters) the malformed poison out of the drain.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATEWAY_PY = REPO_ROOT / "bridge-queue-gateway.py"


def _req_dir(root: Path, agent: str) -> Path:
    d = root / agent / "requests"
    d.mkdir(parents=True, exist_ok=True)
    (root / agent / "responses").mkdir(parents=True, exist_ok=True)
    return d


def _write_request(req_dir: Path, req_id: str, payload: dict) -> None:
    (req_dir / f"{req_id}.request.json").write_text(json.dumps(payload), encoding="utf-8")


def _stub_queue(root: Path) -> Path:
    # A trivial queue child that always succeeds — the test exercises the
    # gateway's batch resilience, not real queue semantics.
    stub = root / "stub-queue.py"
    stub.write_text("import sys\nprint('stub-ok')\nsys.exit(0)\n", encoding="utf-8")
    return stub


def cmd_setup(root: Path) -> int:
    agent = "t1"
    req = _req_dir(root, agent)
    _stub_queue(root)
    # Poison A — recorded cwd points at a path that does not exist; the OLD
    # serve-once did subprocess.run(cwd=<missing>) → FileNotFoundError → whole
    # batch abort. (Mirrors the cm-prod 0700-iso-attachment cwd case, portably.)
    _write_request(req, "poison-cwd", {
        "id": "poison-cwd", "agent": agent, "argv": ["noop"],
        "cwd": str(root / "does-not-exist-cwd"),
    })
    # Poison B — a VALID request (valid agent + str argv + accessible cwd) whose
    # argv carries an embedded NUL byte. `subprocess.run` rejects a NUL byte in a
    # process argument with ValueError, which handle_request does NOT catch
    # internally (its only internal guard wraps the JSON parse) and which the cwd
    # fallback does not touch — so it propagates into cmd_serve_once's
    # per-request try/except. This is the ONLY fixture that actually exercises
    # the dead-letter wrapper: an invalid-JSON payload would be caught by
    # handle_request internally, and a bad CWD is now absorbed by the cwd
    # fallback (os.path.isdir returns False for an inaccessible / NUL-byte path).
    # responses/ stays writable so the dead-letter response is observable.
    _write_request(req, "poison-nullargv", {
        "id": "poison-nullargv", "agent": agent, "argv": ["noop\x00bad"],
        "cwd": str(root),
    })
    # Healthy sibling — must still be drained despite the two poisons.
    _write_request(req, "healthy", {
        "id": "healthy", "agent": agent, "argv": ["noop"], "cwd": str(root),
    })
    print("ok-setup")
    return 0


def cmd_run(root: Path) -> int:
    stub = root / "stub-queue.py"
    proc = subprocess.run(
        [sys.executable, str(GATEWAY_PY), "serve-once",
         "--root", str(root), "--queue-script", str(stub), "--max-requests", "100"],
        capture_output=True, text=True, check=False,
    )
    # The batch must NOT abort: exit 0 (old code exited 1 on the first poison).
    if proc.returncode != 0:
        print(f"FAIL: serve-once exited {proc.returncode} (batch aborted on a poison): {proc.stderr.strip()}")
        return 1
    print(f"ok-run rc=0 stdout={proc.stdout.strip()!r}")
    return 0


def cmd_assert(root: Path) -> int:
    agent = "t1"
    req = root / agent / "requests"
    resp = root / agent / "responses"

    def _resp(req_id: str) -> dict | None:
        p = resp / f"{req_id}.json"
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

    # Batch survival: the healthy sibling was drained despite both poisons.
    h = _resp("healthy")
    if h is None or int(h.get("exit_code", -1)) != 0:
        print(f"FAIL: healthy request not drained cleanly (batch did not survive): {h}")
        return 1

    # Fix A (cwd fallback): the inaccessible-cwd request was PROCESSED (success
    # response, stub exit 0) and NOT dead-lettered — proving run_queue fell back
    # to a safe cwd instead of raising. Without fix A this request would instead
    # be caught by fix B and dead-lettered (a `.poison` file + exit_code 1), so
    # asserting a clean success here genuinely gates fix A.
    a = _resp("poison-cwd")
    if a is None or int(a.get("exit_code", -1)) != 0:
        print(f"FAIL: poison-cwd was NOT processed via the cwd fallback (fix A): {a}")
        return 1
    if list(req.glob("poison-cwd.*.poison")):
        print("FAIL: poison-cwd was dead-lettered — fix A did not handle it (fix B caught it instead)")
        return 1

    # Fix B (per-request dead-letter): the NUL-byte-argv request raised in
    # subprocess.run (ValueError), past handle_request's internal guards, and was
    # dead-lettered — a structured error response (exit_code 1 + dead-letter
    # stderr) AND the promoted working file retired to `<id>.working.json.poison`
    # (out of the drain, no re-crash).
    b = _resp("poison-nullargv")
    if b is None or int(b.get("exit_code", -1)) != 1:
        print(f"FAIL: poison-nullargv has no dead-letter response — fix B not exercised: {b}")
        return 1
    if "dead-lettered" not in str(b.get("stderr", "")):
        print(f"FAIL: poison-nullargv response missing the dead-letter stderr: {b.get('stderr')!r}")
        return 1
    if not (req / "poison-nullargv.working.json.poison").exists():
        leftover = [p.name for p in req.glob("poison-nullargv*")]
        print(f"FAIL: poison-nullargv not retired to .poison (would re-crash every tick): {leftover}")
        return 1

    print("ok-assert: fix A processed the inaccessible-cwd request; fix B dead-lettered the NUL-argv poison; healthy drained")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print("FAIL: usage: helper.py <setup|run|assert> <root>")
        return 2
    sub, root = sys.argv[1], Path(sys.argv[2])
    if sub == "setup":
        return cmd_setup(root)
    if sub == "run":
        return cmd_run(root)
    if sub == "assert":
        return cmd_assert(root)
    print(f"FAIL: unknown subcommand {sub}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
