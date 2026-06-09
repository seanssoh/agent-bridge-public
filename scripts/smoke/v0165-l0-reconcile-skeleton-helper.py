#!/usr/bin/env python3
"""v0165-l0-reconcile-skeleton-helper.py — driver for the Lane-0 reconcile
control-loop framework smoke (#1716).

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Exercises the durable
backoff store + ordered idempotent reconcile sequence + adapter-stub fail-safe
+ status-snapshot shape against an ISOLATED BRIDGE_HOME (the caller .sh sets
BRIDGE_HOME to a tmpdir).

Subcommands:
  idempotent  <repo_root>   — run the daemon-side step sequence twice; assert
                              the second run is a no-op (no state churn beyond
                              timestamps); print the two step-status JSON blobs.
  backoff     <repo_root>   — a non-converged result writes a future
                              next_eligible_ts; a converged result resets it.
  snapshot    <repo_root>   — reconcile_status_snapshot returns the stable
                              shape with all 5 steps and NO secret fields.
  raises      <repo_root>   — inject a RAISING adapter into the daemon step
                              sequence; assert the tick still completes and the
                              step is recorded as `error` (fail-safe).
  escape      <repo_root>   — inject a RAISING store-WRITE (record_attempt) into
                              the daemon step sequence; assert no exception
                              escapes _run_reconcile_steps (fail-safe backstop
                              for durable-state I/O failures).

Every check prints a single `OK <subcommand> ...` line on success and exits 0;
on a contract violation it prints `FAIL ...` to stderr and exits 1.
"""

import importlib.util
import json
import os
import sys


def _load_reconcile(repo_root: str):
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_reconcile_common as reconcile  # noqa: E402 - path set above
    return reconcile


def _load_handoffd(repo_root: str):
    """Load bridge-handoffd.py (dash → importlib by path)."""
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    spec = importlib.util.spec_from_file_location(
        "bridge_handoffd", os.path.join(repo_root, "bridge-handoffd.py"))
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load bridge-handoffd.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["bridge_handoffd"] = mod
    spec.loader.exec_module(mod)
    return mod


class _FakeServer:
    """Minimal stand-in for HandoffServer for _run_reconcile_steps: it only
    reads .bound_address / .bound_port / .cfg (the step sequence never binds)."""

    def __init__(self, cfg):
        self.bound_address = "100.64.0.1"
        self.bound_port = 8787
        self.cfg = cfg


def _fixture_cfg():
    """A minimal valid-shaped cfg the step sequence can read transport_kind from
    (default tailscale; no secrets needed — the stubs no-op)."""
    return {"listen": {"address": "100.64.0.1", "port": 8787}, "peers": []}


def cmd_idempotent(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)
    handoffd = _load_handoffd(repo_root)
    cfg = _fixture_cfg()
    server = _FakeServer(cfg)

    # The Lane-0 contract this test pins is the FRAMEWORK idempotence (the loop
    # skeleton + durable store), NOT any staged lane's adapter. Once a lane
    # fills an adapter SEAM (e.g. Lane 2's tunnel_health, #1706) the adapter
    # probes the HOST substrate (real `tailscale status` / `warp-cli`), whose
    # liveness varies by CI host and would make this framework test flaky and
    # host-coupled. Neutralize every adapter SEAM back to a deterministic noop
    # for this test so the skeleton's idempotence is asserted in isolation; the
    # lane's OWN smoke covers the real adapter behavior.
    _orig_adapters = {
        "stable_local_addr": reconcile.stable_local_addr,
        "tunnel_health": reconcile.tunnel_health,
        "peer_reachability_step": reconcile.peer_reachability_step,
        "roster_epoch_reconcile": reconcile.roster_epoch_reconcile,
    }
    reconcile.stable_local_addr = lambda *a, **k: reconcile.step_noop("neutralized for L0 idempotence test")
    reconcile.tunnel_health = lambda *a, **k: reconcile.step_noop("neutralized for L0 idempotence test")
    reconcile.peer_reachability_step = lambda *a, **k: reconcile.step_noop("neutralized for L0 idempotence test")
    reconcile.roster_epoch_reconcile = lambda *a, **k: reconcile.step_noop("neutralized for L0 idempotence test")
    try:
        return _cmd_idempotent_body(reconcile, handoffd, cfg, server)
    finally:
        for name, fn in _orig_adapters.items():
            setattr(reconcile, name, fn)


def _cmd_idempotent_body(reconcile, handoffd, cfg, server) -> int:
    # First run.
    res1 = handoffd.ReconcileResult()
    handoffd._run_reconcile_steps(server, res1, cfg)
    conn = reconcile.open_reconcile_db()
    snap1 = reconcile.all_step_status(conn)
    conn.close()

    # All 5 steps must have been recorded.
    if set(res1.steps.keys()) != set(reconcile.RECONCILE_STEPS):
        sys.stderr.write(f"FAIL idempotent: step set {res1.steps}\n")
        return 1
    # Stubs are noop; bind-reprove on the fake (unchanged) is converged.
    for step, status in res1.steps.items():
        if step == reconcile.STEP_BIND_REPROVE:
            if status != reconcile.RESULT_CONVERGED:
                sys.stderr.write(f"FAIL idempotent: bind {status}\n")
                return 1
        elif status != reconcile.RESULT_NOOP:
            sys.stderr.write(f"FAIL idempotent: {step}={status} (want noop)\n")
            return 1

    # Second run — must be the SAME outcomes (idempotent: no new state beyond
    # the refreshed timestamps; attempt_count stays 0 for every step).
    res2 = handoffd.ReconcileResult()
    handoffd._run_reconcile_steps(server, res2, cfg)
    conn = reconcile.open_reconcile_db()
    snap2 = reconcile.all_step_status(conn)
    conn.close()

    if res1.steps != res2.steps:
        sys.stderr.write(f"FAIL idempotent: run1 {res1.steps} != run2 {res2.steps}\n")
        return 1
    for step in reconcile.RECONCILE_STEPS:
        if snap2[step]["attempt_count"] != 0:
            sys.stderr.write(
                f"FAIL idempotent: {step} attempt_count "
                f"{snap2[step]['attempt_count']} != 0 (state churn)\n")
            return 1
        if snap2[step]["status"] != snap1[step]["status"]:
            sys.stderr.write(
                f"FAIL idempotent: {step} status drift "
                f"{snap1[step]['status']} -> {snap2[step]['status']}\n")
            return 1

    print("OK idempotent " + json.dumps({
        "run1": {s: r for s, r in res1.steps.items()},
        "run2": {s: r for s, r in res2.steps.items()},
    }, sort_keys=True))
    return 0


def cmd_backoff(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)
    conn = reconcile.open_reconcile_db()
    step = reconcile.STEP_TUNNEL_HEALTH

    # Non-converged -> next_eligible_ts in the FUTURE (backoff).
    row = reconcile.record_attempt(
        conn, step, reconcile.RESULT_ERROR, now=1000.0,
        backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
    if not (row["next_eligible_ts"] > 1000.0):
        sys.stderr.write(f"FAIL backoff: not future {row}\n")
        return 1
    if reconcile.step_is_eligible(conn, step, now=1000.5):
        sys.stderr.write("FAIL backoff: eligible during cooldown\n")
        return 1

    # Second error -> strictly larger delay (exponential growth).
    row2 = reconcile.record_attempt(
        conn, step, reconcile.RESULT_ERROR, now=1001.0,
        backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
    if not ((row2["next_eligible_ts"] - 1001.0) > (row["next_eligible_ts"] - 1000.0)):
        sys.stderr.write(f"FAIL backoff: not exponential {row} {row2}\n")
        return 1

    # Cap honored after many failures (no jitter).
    for i in range(40):
        reconcile.record_attempt(
            conn, step, reconcile.RESULT_ERROR, now=2000.0 + i,
            backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
    st = reconcile.step_status(conn, step)
    delay = st["next_eligible_ts"] - st["last_attempt_ts"]
    if delay > 300.0 + 0.001:
        sys.stderr.write(f"FAIL backoff: cap exceeded {delay}\n")
        return 1

    # Cap is a HARD ceiling EVEN WITH jitter — jitter must never push the delay
    # above backoff_cap (regression guard: a pre-fix clamp-before-jitter would
    # let a 300s cap become up to 360s). Run many deeply-backed-off attempts
    # with the default jitter and assert NONE exceed the cap.
    step_j = reconcile.STEP_PEER_REACHABILITY
    for trial in range(200):
        row_j = reconcile.record_attempt(
            conn, step_j, reconcile.RESULT_ERROR, now=5000.0 + trial,
            backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.20)
        jdelay = row_j["next_eligible_ts"] - 5000.0 - trial
        if jdelay > 300.0 + 1e-6:
            sys.stderr.write(
                f"FAIL backoff: jitter pushed delay {jdelay} over cap 300\n")
            return 1
        if jdelay < 0.0:
            sys.stderr.write(f"FAIL backoff: jitter pushed delay negative {jdelay}\n")
            return 1

    # Converged RESETS attempt_count -> 0 and next_eligible -> now.
    row3 = reconcile.record_attempt(conn, step, reconcile.RESULT_CONVERGED, now=3000.0)
    if row3["attempt_count"] != 0 or row3["next_eligible_ts"] != 3000.0:
        sys.stderr.write(f"FAIL backoff: converged did not reset {row3}\n")
        return 1
    if not reconcile.step_is_eligible(conn, step, now=3000.0):
        sys.stderr.write("FAIL backoff: not eligible after reset\n")
        return 1
    conn.close()
    print(f"OK backoff cap_delay={delay:.2f}")
    return 0


def cmd_snapshot(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)

    # ★ NON-CREATING (#1708 read-only contract): a status call against a state
    # dir where reconcile.db does NOT yet exist must return the stable
    # all-unknown shape WITHOUT materializing the store or its WAL/SHM
    # sidecars — a viewer/status path must never mutate state
    # (observable-not-operable). Regression guard for the create-on-read the
    # PR #1717 Phase-4 review caught. Clear any ambient env override so the
    # fresh state_dir is authoritative.
    import tempfile
    from pathlib import Path as _P
    _saved = os.environ.pop("BRIDGE_A2A_RECONCILE_DB", None)  # noqa: iso-helper-boundary
    try:
        with tempfile.TemporaryDirectory() as _empty:
            fresh = _P(_empty) / "handoff"
            before = reconcile.reconcile_status_snapshot(state_dir=fresh, interval=45)
            db = reconcile.reconcile_db_path(fresh)
            for created in (db, _P(str(db) + "-wal"), _P(str(db) + "-shm")):
                if created.exists():
                    sys.stderr.write(
                        f"FAIL snapshot: read-only status created {created}\n")
                    return 1
            if set(before["steps"].keys()) != set(reconcile.RECONCILE_STEPS):
                sys.stderr.write(
                    f"FAIL snapshot: fresh-dir steps {sorted(before['steps'].keys())}\n")
                return 1
            for step, row in before["steps"].items():
                if row["status"] != "unknown":
                    sys.stderr.write(
                        f"FAIL snapshot: fresh-dir {step} not unknown ({row['status']})\n")
                    return 1
    finally:
        if _saved is not None:
            os.environ["BRIDGE_A2A_RECONCILE_DB"] = _saved  # noqa: iso-helper-boundary

    # Seed one step so the snapshot has a real updated_ts to surface.
    conn = reconcile.open_reconcile_db()
    reconcile.record_attempt(conn, reconcile.STEP_STABLE_ADDR,
                             reconcile.RESULT_CONVERGED, now=4242.0)
    conn.close()

    snap = reconcile.reconcile_status_snapshot(interval=45)
    if set(snap.keys()) != {"last_tick_ts", "interval", "steps"}:
        sys.stderr.write(f"FAIL snapshot: top keys {sorted(snap.keys())}\n")
        return 1
    if snap["interval"] != 45:
        sys.stderr.write(f"FAIL snapshot: interval {snap['interval']}\n")
        return 1
    if set(snap["steps"].keys()) != set(reconcile.RECONCILE_STEPS):
        sys.stderr.write(f"FAIL snapshot: steps {sorted(snap['steps'].keys())}\n")
        return 1
    # NO secret-shaped fields anywhere in the surface.
    blob = json.dumps(snap, default=str).lower()
    for bad in ("secret", "hmac", "token", "passwd", "password", "private_key"):
        if bad in blob:
            sys.stderr.write(f"FAIL snapshot: secret-shaped field '{bad}'\n")
            return 1
    # Each step row must carry only observable fields.
    allowed = {"step", "status", "last_result", "attempt_count",
               "last_attempt_ts", "next_eligible_ts", "updated_ts"}
    for step, row in snap["steps"].items():
        extra = set(row.keys()) - allowed
        if extra:
            sys.stderr.write(f"FAIL snapshot: {step} extra fields {extra}\n")
            return 1

    # DEGRADE-SAFE: an UNOPENABLE store (a state_dir whose parent is a file, so
    # mkdir raises OSError/NotADirectoryError) must STILL return the stable
    # shape with every step "unknown" — never raise (this is the net-status read
    # surface). Regression guard for the OSError-escape codex caught.
    from pathlib import Path as _Path
    bad_dir = _Path("/dev/null/nope/handoff")  # mkdir under /dev/null -> NotADirectoryError
    try:
        degraded = reconcile.reconcile_status_snapshot(state_dir=bad_dir, interval=45)
    except Exception as exc:  # noqa: BLE001 - the WHOLE point: it must not raise
        sys.stderr.write(f"FAIL snapshot: unopenable store raised {exc!r}\n")
        return 1
    if set(degraded["steps"].keys()) != set(reconcile.RECONCILE_STEPS):
        sys.stderr.write(f"FAIL snapshot: degraded steps {sorted(degraded['steps'].keys())}\n")
        return 1
    for step, row in degraded["steps"].items():
        if row["status"] != "unknown":
            sys.stderr.write(f"FAIL snapshot: degraded {step} not unknown ({row['status']})\n")
            return 1

    print("OK snapshot " + json.dumps(sorted(snap["steps"].keys())))
    return 0


def cmd_raises(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)
    handoffd = _load_handoffd(repo_root)
    cfg = _fixture_cfg()
    server = _FakeServer(cfg)

    # Inject a RAISING adapter for the tunnel-health stub. The daemon step
    # sequence must catch it, record `error`, and STILL complete every later
    # step (fail-safe — a raising step never crashes the tick).
    def _boom(transport, cfg_, conn=None):
        # Signature matches tunnel_health(transport, cfg, conn) — #1733 threaded
        # `conn` through the call site; accept it so the RAISE under test is the
        # injected RuntimeError, not an accidental arity TypeError.
        raise RuntimeError("injected adapter failure")

    original = reconcile.tunnel_health
    reconcile.tunnel_health = _boom
    try:
        res = handoffd.ReconcileResult()
        handoffd._run_reconcile_steps(server, res, cfg)
    finally:
        reconcile.tunnel_health = original

    # The tick completed (we got here) AND every step is present.
    if set(res.steps.keys()) != set(reconcile.RECONCILE_STEPS):
        sys.stderr.write(f"FAIL raises: incomplete sequence {res.steps}\n")
        return 1
    if res.steps[reconcile.STEP_TUNNEL_HEALTH] != reconcile.RESULT_ERROR:
        sys.stderr.write(
            f"FAIL raises: tunnel-health not error "
            f"({res.steps[reconcile.STEP_TUNNEL_HEALTH]})\n")
        return 1
    # The step AFTER the raising one still ran (sequence did not abort).
    if res.steps[reconcile.STEP_ROSTER_EPOCH] != reconcile.RESULT_NOOP:
        sys.stderr.write(
            f"FAIL raises: later step did not run "
            f"({res.steps[reconcile.STEP_ROSTER_EPOCH]})\n")
        return 1
    # And the error was persisted with a backoff (attempt_count == 1).
    conn = reconcile.open_reconcile_db()
    st = reconcile.step_status(conn, reconcile.STEP_TUNNEL_HEALTH)
    conn.close()
    if st["attempt_count"] != 1 or st["last_result"] != reconcile.RESULT_ERROR:
        sys.stderr.write(f"FAIL raises: not recorded {st}\n")
        return 1
    print("OK raises tunnel-health=error tick-completed")
    return 0


def cmd_escape(repo_root: str) -> int:
    """A store/write failure MID-SEQUENCE must NOT escape _run_reconcile_steps.

    run_step already catches a raising ADAPTER; this proves the daemon-side
    backstop: if a durable-state WRITE raises (corrupt/locked reconcile.db),
    _run_reconcile_steps catches it and returns — the tick never dies. We
    simulate it by monkeypatching reconcile.record_attempt to raise.
    """
    reconcile = _load_reconcile(repo_root)
    handoffd = _load_handoffd(repo_root)
    cfg = _fixture_cfg()
    server = _FakeServer(cfg)

    import sqlite3 as _sqlite3

    def _boom_write(*args, **kwargs):
        raise _sqlite3.OperationalError("database disk image is malformed")

    original = reconcile.record_attempt
    reconcile.record_attempt = _boom_write
    crashed = False
    try:
        res = handoffd.ReconcileResult()
        try:
            handoffd._run_reconcile_steps(server, res, cfg)
        except Exception as exc:  # noqa: BLE001 - the WHOLE point is to prove this never fires
            crashed = True
            sys.stderr.write(f"FAIL escape: exception escaped the tick: {exc!r}\n")
    finally:
        reconcile.record_attempt = original

    if crashed:
        return 1
    print("OK escape store-write-failure-contained")
    return 0


_COMMANDS = {
    "idempotent": cmd_idempotent,
    "backoff": cmd_backoff,
    "snapshot": cmd_snapshot,
    "raises": cmd_raises,
    "escape": cmd_escape,
}


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in _COMMANDS:
        sys.stderr.write(
            "usage: v0165-l0-reconcile-skeleton-helper.py "
            "<idempotent|backoff|snapshot|raises|escape> <repo_root>\n")
        return 2
    cmd, repo_root = sys.argv[1], sys.argv[2]
    return _COMMANDS[cmd](repo_root)


if __name__ == "__main__":
    sys.exit(main())
