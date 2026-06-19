#!/usr/bin/env python3
"""File-as-argv sidecar for scripts/smoke/1973a-gateway-drain-containment.sh.

Footgun #11 / C1: the smoke shell drives every Python step through THIS helper
(file-as-argv) — never `python3 - <<'PY'` heredoc-stdin to a subprocess.

#1973 Track A — queue-gateway drain containment + degraded claim/done. These
steps exercise the three acceptance teeth against the REAL gateway code:

  * A1: a HUNG queue child cannot block a later claim/done beyond the bounded
        per-request timeout. A serve-once batch whose FIRST request runs a child
        that sleeps far past the request ceiling must still drain a LATER control
        request, and the whole batch must finish in roughly the (single) request
        timeout — not the sum of all children's runtimes.
  * A2: a timed-out claim/done NEVER returns success and prints actionable retry
        guidance. The gateway server returns EX_TEMPFAIL (75) on a killed child,
        and bridge-queue.py's proxy preserves that nonzero rc + adds the
        safe-next-command hint for claim/done.
  * A3: a stale `.working.json` is retired with an error response AND retained
        evidence (renamed to `.timeout`, out of the drain) — not re-run forever.

Each subcommand prints a single `ok-*` token on stdout for the shell to assert,
or a `FAIL: …` line + nonzero exit.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATEWAY_PY = REPO_ROOT / "bridge-queue-gateway.py"
QUEUE_PY = REPO_ROOT / "bridge-queue.py"


def _load(mod_name: str, path: Path):
    spec = importlib.util.spec_from_file_location(mod_name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Live-runtime BRIDGE_* vars that MUST be scrubbed so this smoke never touches
# the operator's ~/.agent-bridge (the #1860 live-install guard). The test runs
# inside a bridge-managed session that inherits BRIDGE_LAYOUT=v2 +
# BRIDGE_AGENT_ROOT_V2/BRIDGE_TASK_DB pointing at the LIVE runtime; get_queue_-
# gateway_root() honours those first, so without scrubbing the proxy would drain
# against the live gateway/DB. Every subprocess below starts from this clean base.
_SCRUB_VARS = (
    "BRIDGE_LAYOUT",
    "BRIDGE_AGENT_ROOT_V2",
    "BRIDGE_AGENT_ROOT",
    "BRIDGE_STATE_DIR",
    "BRIDGE_TASK_DB",
    "BRIDGE_GATEWAY_PROXY",
    "BRIDGE_AGENT_ID",
    "BRIDGE_QUEUE_GATEWAY_SERVER",
    "BRIDGE_QUEUE_GATEWAY_ROOT",
    "BRIDGE_HOME",
    "BRIDGE_CRON_RUN_ID",
)


def _clean_env(**overrides: str) -> dict[str, str]:
    env = dict(os.environ)
    for var in _SCRUB_VARS:
        env.pop(var, None)
    env.update(overrides)
    return env


def _req_dir(root: Path, agent: str) -> Path:
    d = root / agent / "requests"
    d.mkdir(parents=True, exist_ok=True)
    (root / agent / "responses").mkdir(parents=True, exist_ok=True)
    return d


def _write_request(req_dir: Path, req_id: str, payload: dict) -> None:
    (req_dir / f"{req_id}.request.json").write_text(json.dumps(payload), encoding="utf-8")


def _resp(root: Path, agent: str, req_id: str) -> dict | None:
    p = root / agent / "responses" / f"{req_id}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def _hang_queue_stub(root: Path) -> Path:
    """A queue child that SLEEPS far longer than the request ceiling — simulates
    a wedged SQLite lock. The per-request timeout must KILL it; without the
    timeout this child pins the whole serve-once batch."""
    stub = root / "hang-queue.py"
    stub.write_text("import time\ntime.sleep(60)\n", encoding="utf-8")
    return stub


def _fast_queue_stub(root: Path) -> Path:
    stub = root / "fast-queue.py"
    stub.write_text("import sys\nprint('fast-ok')\nsys.exit(0)\n", encoding="utf-8")
    return stub


# --------------------------------------------------------------------------- #
# A1 — a hung request cannot block a later control request beyond the bound
# --------------------------------------------------------------------------- #

def cmd_a1(root: Path) -> int:
    """Containment teeth — the per-request bound, isolated from the priority
    sort. Two SAME-CLASS requests (both non-control `create`s, so drain order is
    pure mtime) share ONE serve-once batch behind a queue child that always
    hangs. The hung one is OLDER, so it is reached FIRST. Without the per-request
    bound it pins the batch (one daemon tick) for 60s and the second `create` is
    NEVER reached — the #1973 stall shape. With the bound each child is KILLED on
    the ceiling, so:
      * the whole batch finishes in roughly N ceilings, NOT 60s+ (bounded), and
      * the LATER `create` IS still reached and gets an authoritative (tempfail)
        response instead of being blocked behind the hung one forever.
    Both requests run the hang stub, so both time out to tempfail (75) — the
    point under test is the BOUND, not a real success (that is A2/A3's job)."""
    agent = "iso-a1"
    req = _req_dir(root, agent)
    hang = _hang_queue_stub(root)

    _write_request(req, "hung", {
        "id": "hung", "agent": agent, "argv": ["create", "--to", "x", "--title", "first"],
        "cwd": str(root),
    })
    older = time.time() - 50
    os.utime(req / "hung.request.json", (older, older))
    _write_request(req, "later", {
        "id": "later", "agent": agent, "argv": ["create", "--to", "x", "--title", "second"],
        "cwd": str(root),
    })

    env = _clean_env(BRIDGE_QUEUE_GATEWAY_REQUEST_TIMEOUT_SECONDS="1")
    started = time.monotonic()
    proc = subprocess.run(
        [sys.executable, str(GATEWAY_PY), "serve-once",
         "--root", str(root), "--queue-script", str(hang), "--max-requests", "100"],
        capture_output=True, text=True, check=False, env=env,
    )
    elapsed = time.monotonic() - started

    if proc.returncode != 0:
        print(f"FAIL: serve-once did not exit 0 under a hung batch: rc={proc.returncode} {proc.stderr.strip()}")
        return 1
    # The bound is the teeth: two 1s-ceiling children must finish well under the
    # 60s the hung child would otherwise take. Generous ceiling (10s) for slow CI.
    if elapsed > 10.0:
        print(f"FAIL: hung child was NOT bounded — batch took {elapsed:.1f}s (ceiling per-request 1s)")
        return 1
    # The later (newer) request was still reached behind the OLDER hung one and
    # got an authoritative (tempfail) response — it was not blocked forever.
    ctl = _resp(root, agent, "later")
    if ctl is None:
        print("FAIL: the later request was never reached behind the hung request")
        return 1
    gw = _load("bridge_queue_gateway_a1", GATEWAY_PY)
    if int(ctl.get("exit_code", -1)) != gw.GATEWAY_TEMPFAIL_EXIT_CODE:
        print(f"FAIL: the later bounded request did not return tempfail: {ctl}")
        return 1
    if "outcome unknown" not in str(ctl.get("stderr", "")):
        print(f"FAIL: bounded request response missing the outcome-unknown text: {ctl.get('stderr')!r}")
        return 1
    print(f"ok-a1 elapsed={elapsed:.1f}s both-bounded")
    return 0


# --------------------------------------------------------------------------- #
# A2 — degraded claim/done never fakes success + prints retry guidance
# --------------------------------------------------------------------------- #

def cmd_a2(root: Path) -> int:
    """Drive the REAL bridge-queue.py proxy as an iso UID whose gateway child
    times out, and assert it (a) returns the nonzero tempfail rc — never a
    fabricated 0 — and (b) prints the safe-next-command guidance for claim/done.

    We point the proxy at a gateway root whose queue script hangs; the gateway
    server kills the child (tempfail 75) and the proxy surfaces it. The iso shape
    is reproduced via BRIDGE_GATEWAY_PROXY=1 + BRIDGE_TASK_DB=/dev/null so the
    proxy path is actually taken and no DB read can mask the outcome."""
    agent = "iso-a2"
    hang = _hang_queue_stub(root)
    # The proxy resolves the gateway root as <BRIDGE_STATE_DIR>/queue-gateway, so
    # build that exact layout and point the drainer's serve-once at it too.
    state_dir = root / "state"
    gw_root = state_dir / "queue-gateway"
    _req_dir(gw_root, agent)

    env = _clean_env(
        BRIDGE_GATEWAY_PROXY="1",
        BRIDGE_AGENT_ID=agent,
        BRIDGE_TASK_DB="/dev/null",
        BRIDGE_GATEWAY_TRANSPORT="file",
        BRIDGE_STATE_DIR=str(state_dir),
        BRIDGE_QUEUE_GATEWAY_REQUEST_TIMEOUT_SECONDS="1",
        # Keep the CLIENT read window generous enough to read the daemon's
        # (tempfail) response rather than itself timing out — we are testing the
        # tempfail propagation, not the client read timeout.
        BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS="20",
        BRIDGE_QUEUE_GATEWAY_POLL_SECONDS="0.1",
    )

    # The proxy's gateway client only ENQUEUES the request; a real daemon drains
    # it. Here there is no daemon, so we drain it ourselves in the background by
    # running serve-once in a loop while the client polls for the response.
    drainer = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "drain-loop", str(gw_root), str(hang)],
        env=env,
    )
    try:
        for op, args in (
            ("claim", ["claim", "7", "--agent", agent]),
            ("done", ["done", "7", "--agent", agent]),
        ):
            proc = subprocess.run(
                [sys.executable, str(QUEUE_PY), *args],
                capture_output=True, text=True, check=False, env=env,
            )
            if proc.returncode == 0:
                print(f"FAIL: degraded `{op}` returned SUCCESS (0) on a stalled drain — fabricated success: {proc.stdout!r}")
                return 1
            combined = proc.stdout + proc.stderr
            if "outcome UNKNOWN" not in combined:
                print(f"FAIL: degraded `{op}` missing the outcome-UNKNOWN guidance: rc={proc.returncode} {combined!r}")
                return 1
            if "agb show" not in combined or "agb inbox" not in combined:
                print(f"FAIL: degraded `{op}` missing the safe-next-command hint: {combined!r}")
                return 1
            if f"agb {op}" not in combined:
                print(f"FAIL: degraded `{op}` did not name the re-run command: {combined!r}")
                return 1
    finally:
        drainer.terminate()
        try:
            drainer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            drainer.kill()
    print("ok-a2 claim+done never-faked-success guidance-printed")
    return 0


def cmd_drain_loop(root_arg: str, queue_arg: str) -> int:
    """Background helper for A2: repeatedly run the REAL serve-once so the
    proxy's enqueued request gets a tempfail response (the daemon's job)."""
    root = Path(root_arg)
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        subprocess.run(
            [sys.executable, str(GATEWAY_PY), "serve-once",
             "--root", str(root), "--queue-script", str(queue_arg), "--max-requests", "100"],
            capture_output=True, text=True, check=False,
        )
        time.sleep(0.1)
    return 0


# --------------------------------------------------------------------------- #
# A3 — a stale `.working.json` is retired with evidence
# --------------------------------------------------------------------------- #

def cmd_a3(root: Path) -> int:
    """A `.working.json` older than the stale threshold (the residue of a prior
    serve-once the daemon killed mid-drain) must be RETIRED — a tempfail response
    written for the waiting client AND the file renamed to `.timeout` (out of the
    drain, evidence retained) — not re-run forever."""
    agent = "iso-a3"
    req = _req_dir(root, agent)
    fast = _fast_queue_stub(root)

    # Pre-stage a `.working.json` directly (the residue shape) and age it past
    # the threshold via utime.
    working = req / "stale-inflight.working.json"
    working.write_text(json.dumps({
        "id": "stale-inflight", "agent": agent, "argv": ["done", "1"], "cwd": str(root),
    }), encoding="utf-8")
    old = time.time() - 9999
    os.utime(working, (old, old))

    env = _clean_env(BRIDGE_QUEUE_GATEWAY_WORKING_STALE_SECONDS="5")
    proc = subprocess.run(
        [sys.executable, str(GATEWAY_PY), "serve-once",
         "--root", str(root), "--queue-script", str(fast), "--max-requests", "100"],
        capture_output=True, text=True, check=False, env=env,
    )
    if proc.returncode != 0:
        print(f"FAIL: serve-once exited {proc.returncode} on a stale working file: {proc.stderr.strip()}")
        return 1

    # The stale working file must be RETIRED to `.timeout` (out of the drain),
    # NOT left as `.working.json` (which iter_requests would re-glob every tick).
    if working.exists():
        print("FAIL: stale `.working.json` was NOT retired (would re-run every tick)")
        return 1
    if not (req / "stale-inflight.working.json.timeout").exists():
        leftover = [p.name for p in req.glob("stale-inflight*")]
        print(f"FAIL: stale working file not retired to `.timeout` (evidence not retained): {leftover}")
        return 1

    # An authoritative tempfail response was written for the waiting client.
    r = _resp(root, agent, "stale-inflight")
    gw = _load("bridge_queue_gateway_a3", GATEWAY_PY)
    if r is None or int(r.get("exit_code", -1)) != gw.GATEWAY_TEMPFAIL_EXIT_CODE:
        print(f"FAIL: stale-working retirement did not write a tempfail response: {r}")
        return 1
    if "outcome unknown" not in str(r.get("stderr", "")):
        print(f"FAIL: stale-working response missing the outcome-unknown text: {r.get('stderr')!r}")
        return 1
    print("ok-a3 stale-working retired-with-evidence tempfail-response")
    return 0


# --------------------------------------------------------------------------- #
# mutation guard — prove the suite is non-vacuous
# --------------------------------------------------------------------------- #

def cmd_priority_sort(root: Path) -> int:
    """Non-vacuous proof for the control-priority class: a control `claim` queued
    AFTER (newer than) a non-control `create` must sort FIRST. If the priority
    sort regressed to pure mtime, the create would lead. Exercises iter_requests
    directly so the assertion is the sort order, not a side effect."""
    agent = "iso-pr"
    req = _req_dir(root, agent)
    # create is OLDER, claim is NEWER — pure mtime would put create first.
    _write_request(req, "old-create", {
        "id": "old-create", "agent": agent, "argv": ["create", "--to", "x"], "cwd": str(root),
    })
    older = time.time() - 100
    os.utime(req / "old-create.request.json", (older, older))
    _write_request(req, "new-claim", {
        "id": "new-claim", "agent": agent, "argv": ["claim", "9"], "cwd": str(root),
    })

    gw = _load("bridge_queue_gateway_pr", GATEWAY_PY)
    ordered = gw.iter_requests(Path(root))
    names = [p.name.split(".", 1)[0] for p in ordered if p.parent.parent.name == agent]
    if names[:2] != ["new-claim", "old-create"]:
        print(f"FAIL: control op did not drain ahead of an older create — priority sort wrong: {names}")
        return 1
    print(f"ok-priority-sort control-first order={names}")
    return 0


def _admitted_split(gw, root: Path, cap: int) -> tuple[list[str], list[str]]:
    """Run _fair_drain_order at `cap` and return (control_ids, create_ids)."""
    chosen = gw._fair_drain_order(gw.iter_requests(Path(root)), cap)
    chosen_names = [p.name.split(".", 1)[0] for p in chosen]
    ctl = [n for n in chosen_names if n.startswith("ctl-")]
    cre = [n for n in chosen_names if n.startswith("create-")]
    return ctl, cre


def _seed_fair_root(sub: Path, agent: str, n_control: int, n_create: int) -> None:
    req = _req_dir(sub, agent)
    for i in range(n_control):
        _write_request(req, f"ctl-{i}", {
            "id": f"ctl-{i}", "agent": agent, "argv": ["done", str(i)], "cwd": str(sub),
        })
    for i in range(n_create):
        _write_request(req, f"create-{i}", {
            "id": f"create-{i}", "agent": agent, "argv": ["create", "--to", "x"], "cwd": str(sub),
        })


def cmd_fairness(root: Path) -> int:
    """BLOCKING-fix proof (#1973 codex review r2): the control-priority class must
    NOT starve non-control creates, and the reserve split must be EXACT — a weak
    inequality would pass a broken parity (2/2) or an over-admission, and an
    off-by-one in _fair_drain_order would go undetected. Two ISOLATED sub-roots,
    each asserting the exact admitted counts:
      * full backlog (8 control + 4 creates, cap=4): reserve = max(1, int(4*
        0.25)) = 1, so EXACTLY 3 control + 1 create. A pure control-first cut
        admits 0 creates; a parity/over-rotation admits != 1.
      * small non-control backlog (8 control + 1 create, cap=4): the clamp
        `min(reserve, len(non_control))` must keep that SINGLE create admitted —
        still EXACTLY 3 control + 1 create, the lone create is not lost."""
    gw = _load("bridge_queue_gateway_fair", GATEWAY_PY)

    # Case 1 — full backlog, exact 3/1 split at cap=4.
    full = root / "full"
    _seed_fair_root(full, "iso-fair", n_control=8, n_create=4)
    ctl, cre = _admitted_split(gw, full, 4)
    if (len(ctl), len(cre)) != (3, 1):
        print(f"FAIL: cap=4 full-backlog split not exactly 3 control + 1 create: control={ctl} creates={cre}")
        return 1

    # Case 2 — only ONE create pending (M=1 < the would-be control budget). The
    # clamp keeps the single create admitted; still exactly 3 control + 1 create.
    one = root / "one-create"
    _seed_fair_root(one, "iso-fair2", n_control=8, n_create=1)
    ctl2, cre2 = _admitted_split(gw, one, 4)
    if (len(ctl2), len(cre2)) != (3, 1):
        print(f"FAIL: cap=4 single-create case not exactly 3 control + 1 create (clamp lost it?): control={ctl2} creates={cre2}")
        return 1

    print("ok-fairness exact-split=3control/1create cap=4 (full + single-create backlogs)")
    return 0


DISPATCH = {
    "a1": cmd_a1,
    "a2": cmd_a2,
    "a3": cmd_a3,
    "priority-sort": cmd_priority_sort,
    "fairness": cmd_fairness,
}


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "drain-loop":
        return cmd_drain_loop(sys.argv[2], sys.argv[3])
    if len(sys.argv) < 3 or sys.argv[1] not in DISPATCH:
        print(f"FAIL: usage: helper.py <{'|'.join(DISPATCH)}> <root>")
        return 2
    return DISPATCH[sys.argv[1]](Path(sys.argv[2]))


if __name__ == "__main__":
    sys.exit(main())
