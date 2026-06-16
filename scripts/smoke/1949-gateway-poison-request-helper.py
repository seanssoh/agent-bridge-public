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


def _write_raw_working(req_dir: Path, req_id: str, raw: str) -> None:
    (req_dir / f"{req_id}.working.json").write_text(raw, encoding="utf-8")


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
    # Poison B — a malformed working file already promoted into the drain; the
    # OLD serve-once would re-crash on it every tick. Tests the per-request
    # try/except dead-letter (it must be retired out of the drain).
    _write_raw_working(req, "poison-malformed", "{ this is not valid json ")
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
    # 1) The healthy request was drained: a response exists with exit 0.
    healthy_resp = resp / "healthy.json"
    if not healthy_resp.exists():
        print("FAIL: healthy request was NOT processed (no response) — the batch did not survive the poison")
        return 1
    data = json.loads(healthy_resp.read_text(encoding="utf-8"))
    if int(data.get("exit_code", -1)) != 0:
        print(f"FAIL: healthy response exit_code={data.get('exit_code')} != 0")
        return 1
    # 2) The poison-cwd request was drained too (cwd fell back, did not crash):
    #    its request/working files are gone from the drain.
    if list(req.glob("poison-cwd.*.json")) and not list(req.glob("poison-cwd.*.poison")):
        leftover = [p.name for p in req.glob("poison-cwd.*")]
        # A still-pending poison-cwd request means it neither processed nor
        # dead-lettered — the fix failed.
        if any(n.endswith(".request.json") or n.endswith(".working.json") for n in leftover):
            print(f"FAIL: poison-cwd still pending in drain: {leftover}")
            return 1
    # 3) The malformed poison was retired out of the drain (dead-lettered),
    #    NOT left as a re-draining .working.json.
    malformed_pending = [p.name for p in req.glob("poison-malformed.working.json")]
    if malformed_pending:
        print(f"FAIL: malformed poison left in drain (would re-crash every tick): {malformed_pending}")
        return 1
    print("ok-assert: batch survived poison-cwd + malformed; healthy drained; poisons retired")
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
