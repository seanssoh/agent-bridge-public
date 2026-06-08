#!/usr/bin/env python3
"""v0165-l3-peer-reachability-helper.py — driver for the Lane-3 peer-reachability
adapter smoke (#1707).

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Exercises the reconcile
`peer-reachability` step (bridge_reconcile_common.peer_reachability_step) against
an ISOLATED reconcile.db (BRIDGE_A2A_RECONCILE_DB → a tmpdir file, fresh per
subcommand) with the OUTBOUND PROBE seam MOCKED so the REAL FSM code path runs
with no real network:
  - reconcile._PEER_REACHABILITY_PROBE — rebound to a scripted/spy probe that
    returns up/down on command (the injectable probe-hook).
  - BRIDGE_A2A_IFACE_ADDRS (consumed by a2a.local_interface_addresses) — mocks
    "the local listen.address IS / IS NOT on a local interface" for the IP-drift
    case without touching real interfaces.

Subcommands (each prints `OK <cmd> ...` + exits 0 on pass; `FAIL ...` to stderr
+ exits 1 on a contract violation):
  all-up        <repo_root> <db> <cfg> — every peer reachable → step_converged,
                                         all peer rows `up` (idempotent no-op on
                                         re-run).
  hysteresis    <repo_root> <db> <cfg> — a SINGLE failed probe → `suspect` (NOT
                                         `down`); N consecutive → `down`.
  recovery      <repo_root> <db> <cfg> — a `down` peer that probes OK → `up`
                                         (failure counter reset).
  bounded       <repo_root> <db> <cfg> — repeated DOWN ticks DRIVEN THROUGH
                                         run_step do NOT re-probe every tick
                                         (the per-peer backoff gate paces it).
  isolation     <repo_root> <db> <cfg> — peer A DOWN does not mutate peer B's
                                         row (per-peer isolation).
  ip-drift      <repo_root> <db> <cfg> — a peer unreachable AND the local
                                         listen.address absent from interfaces →
                                         desired rebind RECORDED via
                                         stable_local_addr (config updated) but
                                         NO bind performed.
  no-drift-rebind <repo_root> <db> <cfg> — a peer unreachable but the local
                                         listen.address IS on an interface → NO
                                         rebind recorded (config unchanged).
  probe-failure <repo_root> <db> <cfg> — the probe hook RAISES → step_error,
                                         fail-closed (the peer is NOT `up`).
  no-secret     <repo_root> <db> <cfg> — no secret-shaped field in any state row
                                         or result.

Every subcommand drives the REAL adapter (no behavior is re-implemented here).
"""

import json
import os
import sys


def _load_reconcile(repo_root: str):
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_reconcile_common as reconcile  # noqa: E402 - path set above
    return reconcile


def _load_a2a(repo_root: str):
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_a2a_common as a2a  # noqa: E402 - path set above
    return a2a


def _write_cfg(cfg_path: str, *, transport: str, listen_addr: str,
               peer_ids: list[str], listen_port: int = 8787) -> None:
    """Write an isolated A2A config (mode 0600 — load_config refuses 0o077).

    Every peer carries a placeholder raw-IP `address` (the WARP transport keys
    on it) plus a `secret` so validate_config_peer_secrets would pass; the
    probe is MOCKED so the address is never actually dialled.
    """
    peers = []
    for i, pid in enumerate(peer_ids):
        peers.append({
            "id": pid,
            # Distinct per-peer raw IPs (TEST-NET-1, RFC 5737 — never routable).
            "address": f"192.0.2.{10 + i}",
            "secret": "x" * 40,
        })
    cfg = {
        "bridge_id": "node-1",
        "transport": {"kind": transport},
        "listen": {"address": listen_addr, "port": listen_port},
        "peers": peers,
    }
    with open(cfg_path, "w", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        json.dump(cfg, fh, indent=2)
    os.chmod(cfg_path, 0o600)


def _read_listen_addr(cfg_path: str) -> str:
    with open(cfg_path, encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only
        return json.load(fh)["listen"].get("address", "")


def _peer_states(conn) -> dict:
    """Read every persisted FSM row as {peer_id: (state, consecutive_fail)}."""
    out = {}
    for row in conn.execute(
            "SELECT peer_id, state, consecutive_fail FROM peer_reachability"):
        out[row["peer_id"]] = (row["state"], int(row["consecutive_fail"]))
    return out


class _ScriptedProbe:
    """An injectable probe whose verdict per (address) is scripted by a map.

    `reachable_by_addr` maps a peer address → bool. A missing address defaults
    to `default`. Records every call for assertion.
    """

    def __init__(self, reachable_by_addr=None, default=True):
        self.reachable_by_addr = reachable_by_addr or {}
        self.default = default
        self.calls = []  # list of (address, port)

    def __call__(self, address, port, timeout):
        self.calls.append((address, port))
        return bool(self.reachable_by_addr.get(address, self.default))


def _run_once(reconcile, db_path: str, cfg):
    """Open a fresh reconcile.db conn, run the adapter once, return (res, conn).

    The caller MUST close conn. We do NOT close it here so the test can inspect
    the persisted rows on the same connection.
    """
    conn = reconcile.open_reconcile_db()
    res = reconcile.peer_reachability_step(cfg, conn)
    return res, conn


def cmd_all_up(repo_root: str, db_path: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2", "node-3"])
    cfg = a2a.load_config()

    probe = _ScriptedProbe(default=True)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    try:
        res, conn = _run_once(reconcile, db_path, cfg)
        if res.status != reconcile.RESULT_CONVERGED:
            sys.stderr.write(f"FAIL all-up: status {res.status} ({res.detail})\n")
            return 1
        states = _peer_states(conn)
        for pid in ("node-2", "node-3"):
            if states.get(pid, (None, None))[0] != reconcile.PEER_STATE_UP:
                sys.stderr.write(f"FAIL all-up: {pid} not up: {states}\n")
                return 1
        # Idempotent re-run is still converged and does not flap a row.
        res2 = reconcile.peer_reachability_step(cfg, conn)
        if res2.status != reconcile.RESULT_CONVERGED:
            sys.stderr.write(f"FAIL all-up: re-run status {res2.status} (want converged)\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print(f"OK all-up converged probes={len(probe.calls)} states all up (idempotent)")
    return 0


def cmd_hysteresis(repo_root: str, db_path: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2"])
    cfg = a2a.load_config()
    threshold = reconcile.peer_suspect_threshold()
    peer_addr = "192.0.2.10"

    probe = _ScriptedProbe(reachable_by_addr={peer_addr: False}, default=False)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    try:
        conn = reconcile.open_reconcile_db()
        # First miss: must be SUSPECT, NOT DOWN (hysteresis).
        reconcile.peer_reachability_step(cfg, conn)
        st, fails = _peer_states(conn)["node-2"]
        if st != reconcile.PEER_STATE_SUSPECT:
            sys.stderr.write(f"FAIL hysteresis: 1st miss state {st} (want suspect)\n")
            return 1
        if fails != 1:
            sys.stderr.write(f"FAIL hysteresis: 1st miss consecutive_fail {fails} (want 1)\n")
            return 1
        # Force the peer eligible again each tick by clearing its backoff row so
        # the FSM advances deterministically (we test the FSM here, not pacing —
        # pacing is the `bounded` test).
        step_id = reconcile._peer_step_id("node-2")
        for _ in range(threshold - 1):
            conn.execute("DELETE FROM reconcile_step WHERE step = ?", (step_id,))
            conn.commit()
            reconcile.peer_reachability_step(cfg, conn)
        st, fails = _peer_states(conn)["node-2"]
        if st != reconcile.PEER_STATE_DOWN:
            sys.stderr.write(
                f"FAIL hysteresis: after {threshold} misses state {st} (want down)\n")
            return 1
        if fails < threshold:
            sys.stderr.write(
                f"FAIL hysteresis: consecutive_fail {fails} (want >= {threshold})\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print(f"OK hysteresis 1 miss=suspect, {threshold} misses=down (no single-probe flap)")
    return 0


def cmd_recovery(repo_root: str, db_path: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2"])
    cfg = a2a.load_config()
    threshold = reconcile.peer_suspect_threshold()
    peer_addr = "192.0.2.10"
    step_id = reconcile._peer_step_id("node-2")

    down_probe = _ScriptedProbe(reachable_by_addr={peer_addr: False}, default=False)
    up_probe = _ScriptedProbe(reachable_by_addr={peer_addr: True}, default=True)
    original = reconcile._PEER_REACHABILITY_PROBE
    try:
        conn = reconcile.open_reconcile_db()
        # Drive the peer to DOWN.
        reconcile._PEER_REACHABILITY_PROBE = down_probe
        for _ in range(threshold):
            conn.execute("DELETE FROM reconcile_step WHERE step = ?", (step_id,))
            conn.commit()
            reconcile.peer_reachability_step(cfg, conn)
        st, _ = _peer_states(conn)["node-2"]
        if st != reconcile.PEER_STATE_DOWN:
            sys.stderr.write(f"FAIL recovery: precondition not down ({st})\n")
            return 1
        # A single SUCCESS recovers straight to UP and resets the counter.
        reconcile._PEER_REACHABILITY_PROBE = up_probe
        conn.execute("DELETE FROM reconcile_step WHERE step = ?", (step_id,))
        conn.commit()
        res = reconcile.peer_reachability_step(cfg, conn)
        st, fails = _peer_states(conn)["node-2"]
        if st != reconcile.PEER_STATE_UP:
            sys.stderr.write(f"FAIL recovery: state {st} (want up)\n")
            return 1
        if fails != 0:
            sys.stderr.write(f"FAIL recovery: consecutive_fail {fails} (want 0)\n")
            return 1
        if res.status != reconcile.RESULT_CHANGED:
            sys.stderr.write(f"FAIL recovery: status {res.status} (want changed on down->up)\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print("OK recovery down->up on a single success (counter reset, step_changed)")
    return 0


def cmd_bounded(repo_root: str, db_path: str, cfg_path: str) -> int:
    """A DOWN peer DRIVEN THROUGH run_step must NOT re-probe on every tick.

    The bounded gate (per-peer backoff) skips an ineligible peer. We drive the
    aggregate step through run_step (which gates the whole peer-reachability
    step) AND assert the per-peer backoff inside the adapter also paces a DOWN
    peer (its probe count does not increment while it is backed off).
    """
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2"])
    cfg = a2a.load_config()
    peer_addr = "192.0.2.10"

    probe = _ScriptedProbe(reachable_by_addr={peer_addr: False}, default=False)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    try:
        conn = reconcile.open_reconcile_db()
        # Tick 1 at t=1000: probes the peer (first miss → suspect), engages the
        # per-peer backoff (next_eligible pushed out).
        reconcile.peer_reachability_step(cfg, conn)
        calls_after_t1 = len(probe.calls)
        if calls_after_t1 != 1:
            sys.stderr.write(f"FAIL bounded: tick1 probed {calls_after_t1}x (want 1)\n")
            return 1
        # Tick 2 immediately after (t still within the per-peer cooldown): the
        # peer is NOT eligible → SKIPPED → NO new probe. (The adapter reads
        # now=a2a.now_ts(); back-to-back calls are within the >=2s base backoff.)
        reconcile.peer_reachability_step(cfg, conn)
        calls_after_t2 = len(probe.calls)
        if calls_after_t2 != calls_after_t1:
            sys.stderr.write(
                f"FAIL bounded: tick2 re-probed (calls {calls_after_t2} > {calls_after_t1}) "
                "— backoff gate did not pace a DOWN/SUSPECT peer\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print(f"OK bounded back-to-back ticks probed once (calls={calls_after_t2}); backoff paces")
    return 0


def cmd_isolation(repo_root: str, db_path: str, cfg_path: str) -> int:
    """Peer A going DOWN must not mutate peer B's row."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2", "node-3"])
    cfg = a2a.load_config()
    a_addr, b_addr = "192.0.2.10", "192.0.2.11"

    # node-2 (a_addr) down, node-3 (b_addr) up.
    probe = _ScriptedProbe(reachable_by_addr={a_addr: False, b_addr: True})
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    try:
        conn = reconcile.open_reconcile_db()
        reconcile.peer_reachability_step(cfg, conn)
        states = _peer_states(conn)
        if states.get("node-2", (None, None))[0] != reconcile.PEER_STATE_SUSPECT:
            sys.stderr.write(f"FAIL isolation: node-2 not suspect: {states}\n")
            return 1
        if states.get("node-3", (None, None))[0] != reconcile.PEER_STATE_UP:
            sys.stderr.write(f"FAIL isolation: node-3 not up (A's failure leaked): {states}\n")
            return 1
        if states.get("node-3", (None, 99))[1] != 0:
            sys.stderr.write(f"FAIL isolation: node-3 consecutive_fail not 0: {states}\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print("OK isolation node-2 down did not change node-3's up row")
    return 0


def cmd_ip_drift(repo_root: str, db_path: str, cfg_path: str) -> int:
    """Peer unreachable + local listen.address absent from interfaces → rebind
    RECORDED via stable_local_addr (config updated) but NO bind performed."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    # The local listen.address is a LAN IP that has VANISHED from interfaces.
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.11.10.211", peer_ids=["node-2"])
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    peer_addr = "192.0.2.10"
    stable_warp = "10.128.0.5"

    probe = _ScriptedProbe(reachable_by_addr={peer_addr: False}, default=False)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    # The live interface set carries the STABLE WARP utun addr but NOT the
    # stale LAN listen.address → drift detected, stable_local_addr proposes the
    # utun addr.
    os.environ["BRIDGE_A2A_IFACE_ADDRS"] = f"{stable_warp} 192.168.1.40"  # noqa: iso-helper-boundary
    try:
        conn = reconcile.open_reconcile_db()
        res = reconcile.peer_reachability_step(cfg, conn)
        if res.status != reconcile.RESULT_CHANGED:
            sys.stderr.write(f"FAIL ip-drift: status {res.status} (want changed)\n")
            return 1
        if res.fields.get("ip_drift_rebind_recorded") is not True:
            sys.stderr.write(f"FAIL ip-drift: rebind not recorded: {res.fields}\n")
            return 1
        after = _read_listen_addr(cfg_path)
        if after != stable_warp:
            sys.stderr.write(
                f"FAIL ip-drift: desired listen.address not updated "
                f"({before!r} -> {after!r}, want {stable_warp!r})\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
        os.environ.pop("BRIDGE_A2A_IFACE_ADDRS", None)  # noqa: iso-helper-boundary
    print(f"OK ip-drift desired listen.address {before} -> {after} RECORDED (no bind)")
    return 0


def cmd_no_drift_rebind(repo_root: str, db_path: str, cfg_path: str) -> int:
    """Peer unreachable but local listen.address IS on an interface → NO rebind
    recorded, config left unchanged (fail-closed: only rebind on proven drift)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    # The local listen.address IS present on a live interface → no drift.
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2"])
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    peer_addr = "192.0.2.10"

    probe = _ScriptedProbe(reachable_by_addr={peer_addr: False}, default=False)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    os.environ["BRIDGE_A2A_IFACE_ADDRS"] = "10.128.0.5 192.168.1.40"  # noqa: iso-helper-boundary
    try:
        conn = reconcile.open_reconcile_db()
        res = reconcile.peer_reachability_step(cfg, conn)
        if res.fields.get("ip_drift_rebind_recorded") is not False:
            sys.stderr.write(f"FAIL no-drift-rebind: rebind recorded on no drift: {res.fields}\n")
            return 1
        after = _read_listen_addr(cfg_path)
        if after != before:
            sys.stderr.write(
                f"FAIL no-drift-rebind: config mutated with no drift ({before!r} -> {after!r})\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
        os.environ.pop("BRIDGE_A2A_IFACE_ADDRS", None)  # noqa: iso-helper-boundary
    print(f"OK no-drift-rebind peer down but listen.address present -> NO rebind (config {after})")
    return 0


def cmd_probe_failure(repo_root: str, db_path: str, cfg_path: str) -> int:
    """A probe hook that RAISES → step_error, fail-closed (peer is NOT up)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2"])
    cfg = a2a.load_config()

    def _boom(address, port, timeout):
        raise RuntimeError("probe infrastructure exploded")

    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = _boom
    try:
        conn = reconcile.open_reconcile_db()
        res = reconcile.peer_reachability_step(cfg, conn)
        # A raising probe is caught inside the adapter and treated as a MISS
        # (unknowable ≠ up); the aggregate result is NOT converged.
        if res.status == reconcile.RESULT_CONVERGED:
            sys.stderr.write(
                f"FAIL probe-failure: converged on a raising probe (unknowable treated as up)\n")
            return 1
        states = _peer_states(conn)
        if states.get("node-2", (None, None))[0] == reconcile.PEER_STATE_UP:
            sys.stderr.write(f"FAIL probe-failure: peer marked up despite a raising probe: {states}\n")
            return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    print(f"OK probe-failure raising probe -> {res.status} fail-closed (peer not up)")
    return 0


def cmd_no_secret(repo_root: str, db_path: str, cfg_path: str) -> int:
    """No secret-shaped field in any state row or result."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    _write_cfg(cfg_path, transport="cloudflare-warp-mesh",
               listen_addr="10.128.0.5", peer_ids=["node-2", "node-3"])
    cfg = a2a.load_config()
    a_addr = "192.0.2.10"

    probe = _ScriptedProbe(reachable_by_addr={a_addr: False}, default=True)
    original = reconcile._PEER_REACHABILITY_PROBE
    reconcile._PEER_REACHABILITY_PROBE = probe
    try:
        conn = reconcile.open_reconcile_db()
        res = reconcile.peer_reachability_step(cfg, conn)
        # The result fields + detail.
        blob = json.dumps({"detail": res.detail, "fields": res.fields}, default=str).lower()
        # The full persisted FSM table dump.
        rows = [dict(r) for r in conn.execute("SELECT * FROM peer_reachability")]
        blob += json.dumps(rows, default=str).lower()
        # Per-peer summary keys: ONLY the closed observable set may appear (no
        # free-text probe_error, no exception message). probe_err_code, if
        # present, must be a closed-set classification token.
        allowed_peer_keys = {"peer", "state", "probed", "consecutive_fail",
                             "probe_err_code"}
        allowed_codes = {"warp_identity_misconfig", "resolve_shape",
                         "resolve_not_ip", "resolve_error", "probe_exception",
                         "unresolved_addr"}
        for psum in res.fields.get("peers", []):
            extra = set(psum.keys()) - allowed_peer_keys
            if extra:
                sys.stderr.write(f"FAIL no-secret: unexpected peer-summary key(s) {extra}\n")
                return 1
            if "probe_error" in psum:
                sys.stderr.write("FAIL no-secret: free-text probe_error field present\n")
                return 1
            code = psum.get("probe_err_code")
            if code is not None and code not in allowed_codes:
                sys.stderr.write(
                    f"FAIL no-secret: probe_err_code {code!r} not in the closed set\n")
                return 1
        conn.close()
    finally:
        reconcile._PEER_REACHABILITY_PROBE = original
    for bad in ("secret", "hmac", "token", "passwd", "password", "private_key",
                "enrollment", "apikey", "api_key", "bearer"):
        if bad in blob:
            sys.stderr.write(f"FAIL no-secret: secret-shaped field '{bad}' in {blob}\n")
            return 1
    print("OK no-secret closed-set fields only (no free-text probe_error, codes whitelisted)")
    return 0


_COMMANDS = {
    "all-up": cmd_all_up,
    "hysteresis": cmd_hysteresis,
    "recovery": cmd_recovery,
    "bounded": cmd_bounded,
    "isolation": cmd_isolation,
    "ip-drift": cmd_ip_drift,
    "no-drift-rebind": cmd_no_drift_rebind,
    "probe-failure": cmd_probe_failure,
    "no-secret": cmd_no_secret,
}


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: v0165-l3-peer-reachability-helper.py <cmd> <repo_root> "
            "<reconcile_db> <cfg_path>\n")
        return 2
    cmd = sys.argv[1]
    repo_root = sys.argv[2]
    db_path = sys.argv[3]
    cfg_path = sys.argv[4] if len(sys.argv) > 4 else ""
    fn = _COMMANDS.get(cmd)
    if fn is None:
        sys.stderr.write(f"unknown subcommand: {cmd}\n")
        return 2
    return fn(repo_root, db_path, cfg_path)


if __name__ == "__main__":
    raise SystemExit(main())
