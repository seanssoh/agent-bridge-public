#!/usr/bin/env python3
"""v0166-la-tunnel-bounce-gate-helper.py — driver for the Lane-A #1733 WARP
tunnel-health bounce-GATING smoke.

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Exercises the gated WARP
auto-bounce in `tunnel_health(transport, cfg, conn)` against an ISOLATED
BRIDGE_HOME (the caller .sh sets BRIDGE_HOME to a tmpdir and points
BRIDGE_A2A_WARP_CLI at a MOCK warp-cli so a stale handshake can be simulated
with no real WARP install; the bounce + soft-refresh are asserted via injected
spies WITHOUT touching a real host's tunnel).

#1733: the #1706 adapter bounced the WHOLE WARP tunnel on handshake-idle ALONE,
even when every peer was UP — severing the very mesh that rides the tunnel. The
gate (codex design-consensus #11698): the full disconnect/connect bounce fires
ONLY on stale handshake AND >=N consecutive stale ticks AND >=1 FRESH peer
suspect/down AND a soft-refresh was tried first. All-peers-fresh-up or
unknown/stale peer state HARD-suppresses the bounce.

Subcommands (each takes <repo_root>):
  all-up        — stale handshake + ALL peers FRESH-up -> NO bounce (the #1733
                  regression guard) + bounce_suppressed_reason=all_peers_fresh_up.
  loss-bounces  — stale + >=1 FRESH peer down + N consecutive stale ticks +
                  soft-refresh-first -> the bounce DOES fire (exactly once) and
                  the soft-refresh ran BEFORE it.
  single-stale  — a single stale tick (streak N=1) with a fresh peer down ->
                  NO bounce (awaiting the N-streak confirmation).
  unknown-stale — stale handshake but peer state unknown/stale -> NO bounce +
                  bounce_suppressed_reason=peer_state_unknown_or_stale.
  soft-first    — the soft-refresh is attempted BEFORE any full bounce (ordering).
  soft-no-disc  — the DEFAULT soft-refresh primitive nudges via `warp-cli
                  connect` and NEVER calls `warp-cli disconnect`.

Each check prints a single `OK <subcommand> ...` line on success and exits 0;
on a contract violation it prints `FAIL ...` to stderr and exits 1.
"""

import importlib.util  # noqa: F401 - kept for parity with sibling helpers
import json  # noqa: F401 - kept for parity with sibling helpers
import os
import sys
import time


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


def _warp_cfg():
    return {"transport": {"kind": "cloudflare-warp-mesh"},
            "listen": {"address": "10.128.0.25", "port": 8787},
            "peers": [{"id": "seunghyun"}, {"id": "choi"}, {"id": "hyerin"}]}


def _isolate_reconcile_db(cmd: str) -> None:
    """Point reconcile.db at a per-subcommand path so the persisted stale-streak
    + gate state from one check never bleeds into the next (each helper run is a
    fresh process, but they share BRIDGE_HOME — and the streak is DURABLE, which
    is the production-correct behavior we explicitly want isolated per test)."""
    base = os.environ.get("BRIDGE_STATE_DIR") or os.environ.get(  # noqa: iso-helper-boundary
        "BRIDGE_HOME", "/tmp")  # noqa: iso-helper-boundary
    db_dir = os.path.join(base, "handoff")
    os.makedirs(db_dir, exist_ok=True)
    os.environ["BRIDGE_A2A_RECONCILE_DB"] = os.path.join(  # noqa: iso-helper-boundary
        db_dir, f"reconcile-{cmd}.db")


class _Spy:
    """A hook spy: records every invocation, never touches real WARP."""

    def __init__(self, ret: bool = True):
        self.calls = 0
        self.ret = ret

    def __call__(self) -> bool:
        self.calls += 1
        return self.ret


class _OrderSpy:
    """Records the ORDER of calls into a shared list so the smoke can assert
    the soft-refresh ran BEFORE the full bounce."""

    def __init__(self, label: str, log: list, ret: bool = True):
        self.label = label
        self.log = log
        self.calls = 0
        self.ret = ret

    def __call__(self) -> bool:
        self.calls += 1
        self.log.append(self.label)
        return self.ret


def _seed_peers(reconcile, conn, states, now):
    """Seed each peer's FSM row FRESH (updated_ts=now) with the given state."""
    reconcile._ensure_peer_reachability_schema(conn)
    for pid, state in states.items():
        fail = 0 if state == reconcile.PEER_STATE_UP else 3
        reconcile._write_peer_state(conn, pid, state, fail, now,
                                    state_changed=True)


def cmd_all_up(repo_root: str) -> int:
    """Stale handshake + ALL peers FRESH-up -> NO bounce (the #1733 core)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    # The live #1733 second-fire age: 275s idle, well over the 120s threshold.
    a2a.warp_tunnel_handshake_age = lambda: 275
    conn = reconcile.open_reconcile_db()
    try:
        now = time.time()
        _seed_peers(reconcile, conn, {
            "seunghyun": reconcile.PEER_STATE_UP,
            "choi": reconcile.PEER_STATE_UP,
            "hyerin": reconcile.PEER_STATE_UP}, now)
        # Even across MANY ticks an all-up mesh must NEVER bounce.
        last = None
        for _ in range(3):
            last = reconcile.tunnel_health(transport, _warp_cfg(), conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 0:
        sys.stderr.write(
            f"FAIL all-up: BOUNCED {bounce.calls}x with all peers FRESH-up "
            "(the #1733 self-severance regression)\n")
        return 1
    if soft.calls != 0:
        sys.stderr.write(
            f"FAIL all-up: soft-refresh ran {soft.calls}x on an all-up mesh "
            "(no recovery action belongs here)\n")
        return 1
    if last.fields.get("bounce_suppressed_reason") != \
            reconcile.BOUNCE_SUPPRESSED_ALL_PEERS_FRESH_UP:
        sys.stderr.write(
            f"FAIL all-up: wrong suppressed reason {last.fields}\n")
        return 1
    print(f"OK all-up bounces={bounce.calls} soft={soft.calls} "
          f"reason={last.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_loss_bounces(repo_root: str) -> int:
    """Stale + >=1 FRESH peer down + N consecutive stale + soft-refresh-first
    -> the bounce DOES fire (exactly once at the N-th tick), soft-refresh ran
    before it."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    order: list = []
    bounce = _OrderSpy("bounce", order)
    soft = _OrderSpy("soft", order)
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        now = time.time()
        _seed_peers(reconcile, conn, {
            "seunghyun": reconcile.PEER_STATE_UP,
            "choi": reconcile.PEER_STATE_DOWN,   # one FRESH peer down
            "hyerin": reconcile.PEER_STATE_UP}, now)
        # Drive N consecutive stale ticks. The bounce must fire on the N-th
        # (the streak must reach the threshold first).
        results = []
        for _ in range(n):
            # Re-seed FRESH each tick (peer-reachability would refresh updated_ts
            # every tick in production; the streak is what accumulates).
            _seed_peers(reconcile, conn, {
                "seunghyun": reconcile.PEER_STATE_UP,
                "choi": reconcile.PEER_STATE_DOWN,
                "hyerin": reconcile.PEER_STATE_UP}, time.time())
            results.append(reconcile.tunnel_health(transport, _warp_cfg(), conn))
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 1:
        sys.stderr.write(
            f"FAIL loss-bounces: bounce fired {bounce.calls}x over {n} stale "
            "ticks (want exactly 1, on the N-th)\n")
        return 1
    if soft.calls != 1:
        sys.stderr.write(
            f"FAIL loss-bounces: soft-refresh ran {soft.calls}x (want exactly "
            "1, paired with the single bounce)\n")
        return 1
    if order != ["soft", "bounce"]:
        sys.stderr.write(
            f"FAIL loss-bounces: call order {order} (want soft BEFORE bounce)\n")
        return 1
    final = results[-1]
    if final.fields.get("bounced") is not True:
        sys.stderr.write(f"FAIL loss-bounces: bounced field {final.fields}\n")
        return 1
    if final.fields.get("soft_refresh_attempted") is not True:
        sys.stderr.write(
            f"FAIL loss-bounces: soft_refresh_attempted {final.fields}\n")
        return 1
    print(f"OK loss-bounces N={n} bounces={bounce.calls} soft={soft.calls} "
          f"order={order}")
    return 0


def cmd_single_stale(repo_root: str) -> int:
    """A single stale tick (streak=1, below N) WITH a fresh peer down -> NO
    bounce (await the N-streak confirmation)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        now = time.time()
        _seed_peers(reconcile, conn, {
            "seunghyun": reconcile.PEER_STATE_UP,
            "choi": reconcile.PEER_STATE_DOWN,
            "hyerin": reconcile.PEER_STATE_UP}, now)
        res = reconcile.tunnel_health(transport, _warp_cfg(), conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if n < 2:
        sys.stderr.write(
            f"FAIL single-stale: streak threshold {n} < 2 (default must give "
            "hysteresis room)\n")
        return 1
    if bounce.calls != 0:
        sys.stderr.write(
            f"FAIL single-stale: bounced {bounce.calls}x on a single stale "
            f"tick (streak 1 < {n})\n")
        return 1
    if res.fields.get("bounce_suppressed_reason") != \
            reconcile.BOUNCE_SUPPRESSED_STALE_STREAK_BELOW_N:
        sys.stderr.write(
            f"FAIL single-stale: wrong suppressed reason {res.fields}\n")
        return 1
    if res.fields.get("stale_streak") != 1:
        sys.stderr.write(f"FAIL single-stale: streak {res.fields}\n")
        return 1
    print(f"OK single-stale streak={res.fields.get('stale_streak')} N={n} "
          f"bounces={bounce.calls} "
          f"reason={res.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_unknown_stale(repo_root: str) -> int:
    """Stale handshake but peer state UNKNOWN (never probed) -> NO bounce +
    bounce_suppressed_reason=peer_state_unknown_or_stale."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    try:
        # No peer rows seeded at all -> every peer is unknown (never probed).
        reconcile._ensure_peer_reachability_schema(conn)
        res_never = reconcile.tunnel_health(transport, _warp_cfg(), conn)

        # Now seed STALE rows (updated_ts far in the past, beyond the freshness
        # window) -> still unknown, never a loss even with a DOWN label.
        old = time.time() - 100000.0
        for pid, st in (("seunghyun", reconcile.PEER_STATE_UP),
                        ("choi", reconcile.PEER_STATE_DOWN),
                        ("hyerin", reconcile.PEER_STATE_UP)):
            fail = 0 if st == reconcile.PEER_STATE_UP else 3
            reconcile._write_peer_state(conn, pid, st, fail, old,
                                        state_changed=True)
        res_stale = reconcile.tunnel_health(transport, _warp_cfg(), conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    for label, res in (("never-probed", res_never), ("stale-rows", res_stale)):
        if bounce.calls != 0:
            sys.stderr.write(
                f"FAIL unknown-stale[{label}]: bounced {bounce.calls}x on "
                "unknown/stale peer state (must defer to peer-reachability)\n")
            return 1
        if res.fields.get("bounce_suppressed_reason") != \
                reconcile.BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN:
            sys.stderr.write(
                f"FAIL unknown-stale[{label}]: wrong reason {res.fields}\n")
            return 1
    if soft.calls != 0:
        sys.stderr.write(
            f"FAIL unknown-stale: soft-refresh ran {soft.calls}x on unknown "
            "peer state (no recovery action until reachability is known)\n")
        return 1
    print(f"OK unknown-stale bounces={bounce.calls} soft={soft.calls} "
          f"reason={res_stale.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_soft_first(repo_root: str) -> int:
    """The soft-refresh is attempted BEFORE any full bounce (ordering invariant,
    isolated to one tick at the gate boundary)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    order: list = []
    bounce = _OrderSpy("bounce", order)
    soft = _OrderSpy("soft", order)
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        # Pre-load the streak to N-1 so the NEXT stale tick reaches the gate.
        reconcile._ensure_tunnel_health_state_schema(conn)
        reconcile._write_tunnel_health_state(
            conn, transport, n - 1, None, False, time.time())
        _seed_peers(reconcile, conn, {
            "seunghyun": reconcile.PEER_STATE_UP,
            "choi": reconcile.PEER_STATE_DOWN,
            "hyerin": reconcile.PEER_STATE_UP}, time.time())
        reconcile.tunnel_health(transport, _warp_cfg(), conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if order[:1] != ["soft"]:
        sys.stderr.write(
            f"FAIL soft-first: first recovery action was {order[:1]} "
            "(soft-refresh MUST precede any full bounce)\n")
        return 1
    if "bounce" in order and order.index("soft") > order.index("bounce"):
        sys.stderr.write(
            f"FAIL soft-first: soft-refresh ran AFTER the bounce {order}\n")
        return 1
    print(f"OK soft-first order={order}")
    return 0


def cmd_soft_no_disc(repo_root: str) -> int:
    """The DEFAULT soft-refresh primitive nudges via `warp-cli connect` and
    NEVER calls `warp-cli disconnect` (the #1733 self-severance it avoids). The
    mock warp-cli logs every invocation to $WARP_CALL_LOG; we run the REAL
    `_default_warp_soft_refresh` and assert the log has a `connect` and NO
    `disconnect`."""
    reconcile = _load_reconcile(repo_root)
    log_path = os.environ.get("WARP_CALL_LOG")  # noqa: iso-helper-boundary
    if not log_path:
        sys.stderr.write("FAIL soft-no-disc: WARP_CALL_LOG not set by caller\n")
        return 1
    # Truncate the log so we only see THIS invocation's calls.
    with open(log_path, "w", encoding="utf-8") as fh:
        fh.write("")

    ran = reconcile._default_warp_soft_refresh()

    try:
        with open(log_path, "r", encoding="utf-8") as fh:
            calls = [line.strip() for line in fh if line.strip()]
    except OSError as exc:
        sys.stderr.write(f"FAIL soft-no-disc: cannot read call log: {exc}\n")
        return 1

    if any(c == "disconnect" for c in calls):
        sys.stderr.write(
            f"FAIL soft-no-disc: soft-refresh invoked `warp-cli disconnect` "
            f"(self-severance!) calls={calls}\n")
        return 1
    if not any(c == "connect" for c in calls):
        sys.stderr.write(
            f"FAIL soft-no-disc: soft-refresh never invoked `warp-cli connect` "
            f"calls={calls}\n")
        return 1
    if ran is not True:
        sys.stderr.write(
            f"FAIL soft-no-disc: soft-refresh returned {ran!r} (want True on a "
            "successful connect)\n")
        return 1
    print(f"OK soft-no-disc calls={calls} ran={ran}")
    return 0


def cmd_mixed_loss_stale(repo_root: str) -> int:
    """Mixed peer state: a FRESH suspect/down peer AND a STALE/unknown peer ->
    NO bounce, even once the N-streak is satisfied. A WARP bounce severs the
    mesh's own substrate, so a single fresh loss is NOT proof of a real outage
    while another configured peer's reachability is unknown (it might be up).
    Pre-fix, fresh-loss short-circuited to loss=True and ignored stale peers, so
    the gate bounced; this pins the codex P1 #11705 bypass closed."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    res = None
    try:
        reconcile._ensure_peer_reachability_schema(conn)
        # seunghyun is permanently STALE-down (updated_ts far in the past, beyond
        # the freshness window) — its reachability is UNKNOWN, not a proven loss.
        old = time.time() - 100000.0
        reconcile._write_peer_state(conn, "seunghyun",
                                    reconcile.PEER_STATE_DOWN, 3, old,
                                    state_changed=True)
        # Run past the N-streak; re-seed the FRESH peers each tick so the stale
        # streak grows and choi is a genuine FRESH-down loss every tick.
        for _ in range(n + 1):
            now = time.time()
            reconcile._write_peer_state(conn, "choi",
                                        reconcile.PEER_STATE_DOWN, 3, now,
                                        state_changed=True)
            reconcile._write_peer_state(conn, "hyerin",
                                        reconcile.PEER_STATE_UP, 0, now,
                                        state_changed=True)
            res = reconcile.tunnel_health(transport, _warp_cfg(), conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 0:
        sys.stderr.write(
            f"FAIL mixed-loss-stale: BOUNCED {bounce.calls}x with a FRESH-down "
            f"peer while another peer is STALE/unknown — an incomplete picture "
            f"must suppress the disruptive bounce (the #11705 P1 bypass)\n")
        return 1
    if res.fields.get("bounce_suppressed_reason") != \
            reconcile.BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN:
        sys.stderr.write(
            f"FAIL mixed-loss-stale: wrong suppressed reason {res.fields}\n")
        return 1
    print(f"OK mixed-loss-stale bounces={bounce.calls} "
          f"peer_counts={res.fields.get('peer_counts')} "
          f"reason={res.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_transient_only(repo_root: str) -> int:
    """#1732 × #1733 cross-lane: a TRANSIENT-only mesh whose sole peer is fresh-
    DOWN must NEVER bounce — a transient (expected-disconnect) peer is not
    bounce-relevant, so there is no proof of substrate loss (codex integration
    review)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH
    cfg = {"transport": {"kind": "cloudflare-warp-mesh"},
           "listen": {"address": "10.128.0.25", "port": 8787},
           "peers": [{"id": "laptop", "class": "transient"}]}

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        last = None
        for _ in range(n + 1):
            _seed_peers(reconcile, conn,
                        {"laptop": reconcile.PEER_STATE_DOWN}, time.time())
            last = reconcile.tunnel_health(transport, cfg, conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 0 or soft.calls != 0:
        sys.stderr.write(
            f"FAIL transient-only: bounce={bounce.calls} soft={soft.calls} on a "
            "transient-only DOWN mesh (a transient peer is not bounce-relevant)\n")
        return 1
    if last.fields.get("bounce_suppressed_reason") != \
            reconcile.BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN:
        sys.stderr.write(
            f"FAIL transient-only: wrong suppressed reason {last.fields}\n")
        return 1
    print(f"OK transient-only bounces={bounce.calls} "
          f"peer_counts={last.fields.get('peer_counts')} "
          f"reason={last.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_persistent_up_transient_down(repo_root: str) -> int:
    """#1732 × #1733: persistent peer fresh-UP + transient peer fresh-DOWN must
    NOT bounce — the only bounce-relevant peer is up (codex integration review)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH
    cfg = {"transport": {"kind": "cloudflare-warp-mesh"},
           "listen": {"address": "10.128.0.25", "port": 8787},
           "peers": [{"id": "server"}, {"id": "laptop", "class": "transient"}]}

    bounce = _Spy()
    soft = _Spy()
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        last = None
        for _ in range(n + 1):
            _seed_peers(reconcile, conn, {
                "server": reconcile.PEER_STATE_UP,
                "laptop": reconcile.PEER_STATE_DOWN}, time.time())
            last = reconcile.tunnel_health(transport, cfg, conn)
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 0 or soft.calls != 0:
        sys.stderr.write(
            f"FAIL persistent-up-transient-down: bounce={bounce.calls} "
            f"soft={soft.calls} (the bounce-relevant peer is UP — no bounce)\n")
        return 1
    if last.fields.get("bounce_suppressed_reason") != \
            reconcile.BOUNCE_SUPPRESSED_ALL_PEERS_FRESH_UP:
        sys.stderr.write(
            f"FAIL persistent-up-transient-down: wrong reason {last.fields}\n")
        return 1
    print(f"OK persistent-up-transient-down bounces={bounce.calls} "
          f"peer_counts={last.fields.get('peer_counts')} "
          f"reason={last.fields.get('bounce_suppressed_reason')}")
    return 0


def cmd_persistent_down_transient_up(repo_root: str) -> int:
    """#1732 × #1733: persistent peer fresh-DOWN + transient peer fresh-UP DOES
    bounce after the N-streak — a transient peer must not DILUTE a real
    persistent loss (codex integration review)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH
    cfg = {"transport": {"kind": "cloudflare-warp-mesh"},
           "listen": {"address": "10.128.0.25", "port": 8787},
           "peers": [{"id": "server"}, {"id": "laptop", "class": "transient"}]}

    order: list = []
    bounce = _OrderSpy("bounce", order)
    soft = _OrderSpy("soft", order)
    orig_b = reconcile._WARP_TUNNEL_BOUNCE
    orig_s = reconcile._WARP_TUNNEL_SOFT_REFRESH
    orig_age = a2a.warp_tunnel_handshake_age
    reconcile._WARP_TUNNEL_BOUNCE = bounce
    reconcile._WARP_TUNNEL_SOFT_REFRESH = soft
    a2a.warp_tunnel_handshake_age = lambda: 5106
    conn = reconcile.open_reconcile_db()
    n = reconcile.warp_stale_streak_threshold()
    try:
        results = []
        for _ in range(n):
            _seed_peers(reconcile, conn, {
                "server": reconcile.PEER_STATE_DOWN,
                "laptop": reconcile.PEER_STATE_UP}, time.time())
            results.append(reconcile.tunnel_health(transport, cfg, conn))
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = orig_b
        reconcile._WARP_TUNNEL_SOFT_REFRESH = orig_s
        a2a.warp_tunnel_handshake_age = orig_age
        conn.close()

    if bounce.calls != 1:
        sys.stderr.write(
            f"FAIL persistent-down-transient-up: bounce fired {bounce.calls}x "
            f"over {n} ticks (want exactly 1 — a real persistent loss bounces "
            "despite the transient peer being up)\n")
        return 1
    if order != ["soft", "bounce"]:
        sys.stderr.write(
            f"FAIL persistent-down-transient-up: order {order} "
            "(soft must precede bounce)\n")
        return 1
    print(f"OK persistent-down-transient-up N={n} bounces={bounce.calls} "
          f"order={order} "
          f"peer_counts={results[-1].fields.get('peer_counts')}")
    return 0


_COMMANDS = {
    "all-up": cmd_all_up,
    "loss-bounces": cmd_loss_bounces,
    "single-stale": cmd_single_stale,
    "unknown-stale": cmd_unknown_stale,
    "mixed-loss-stale": cmd_mixed_loss_stale,
    "soft-first": cmd_soft_first,
    "soft-no-disc": cmd_soft_no_disc,
    "transient-only": cmd_transient_only,
    "persistent-up-transient-down": cmd_persistent_up_transient_down,
    "persistent-down-transient-up": cmd_persistent_down_transient_up,
}


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in _COMMANDS:
        sys.stderr.write(
            "usage: v0166-la-tunnel-bounce-gate-helper.py "
            "<all-up|loss-bounces|single-stale|unknown-stale|mixed-loss-stale|"
            "soft-first|soft-no-disc|transient-only|persistent-up-transient-down|"
            "persistent-down-transient-up> <repo_root>\n")
        return 2
    cmd, repo_root = sys.argv[1], sys.argv[2]
    _isolate_reconcile_db(cmd)
    return _COMMANDS[cmd](repo_root)


if __name__ == "__main__":
    sys.exit(main())
