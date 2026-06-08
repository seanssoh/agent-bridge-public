#!/usr/bin/env python3
"""v0165-l2-tunnel-health-helper.py — driver for the Lane-2 tunnel_health
adapter smoke (#1706).

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Exercises the
per-transport tunnel_health() adapter + the injectable WARP auto-bounce hook
against an ISOLATED BRIDGE_HOME (the caller .sh sets BRIDGE_HOME to a tmpdir
and points BRIDGE_A2A_WARP_CLI / BRIDGE_A2A_TAILSCALE_CLI at MOCK CLIs so a
fresh/stale tunnel can be simulated with no real WARP/Tailscale install and the
bounce is asserted WITHOUT bouncing a real host).

Subcommands (each takes <repo_root>):
  healthy     — WARP handshake age < threshold -> converged, NO bounce.
  stale       — WARP handshake age > threshold -> transport_degraded + error +
                the injected bounce hook WAS invoked.
  bounded     — repeated stale ticks DRIVEN THROUGH run_step do NOT bounce on
                every call: the reconcile.db backoff gate paces the bounce
                (first tick bounces, the backed-off tick skips the adapter
                entirely -> no second bounce).
  active-only — the tailscale path never shells warp-cli and vice-versa (the
                other transport's mock CLI is rigged to FAIL if invoked).
  parse-fail  — a warp-cli that returns no parseable handshake line -> error
                WITHOUT a bounce (unknowable age is not a proven stale).
  no-secret   — the degraded result carries no secret-shaped field.

Each check prints a single `OK <subcommand> ...` line on success and exits 0;
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


def _load_a2a(repo_root: str):
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    import bridge_a2a_common as a2a  # noqa: E402 - path set above
    return a2a


def _warp_cfg():
    return {"transport": {"kind": "cloudflare-warp-mesh"},
            "listen": {"address": "100.96.0.5", "port": 8787}, "peers": []}


def _tailscale_cfg():
    return {"listen": {"address": "100.64.0.1", "port": 8787}, "peers": []}


class _BounceSpy:
    """A bounce hook spy: records every invocation, never touches real WARP."""

    def __init__(self, ret: bool = True):
        self.calls = 0
        self.ret = ret

    def __call__(self) -> bool:
        self.calls += 1
        return self.ret


def cmd_healthy(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        # Mock warp-cli reports a FRESH handshake (well under the 120s default).
        os.environ["WARP_HANDSHAKE_AGE"] = "12"
        res = reconcile.tunnel_health(transport, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    if res.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL healthy: status {res.status} (want converged)\n")
        return 1
    if res.fields.get("transport_degraded") is not False:
        sys.stderr.write(f"FAIL healthy: transport_degraded {res.fields}\n")
        return 1
    if spy.calls != 0:
        sys.stderr.write(f"FAIL healthy: bounce invoked {spy.calls}x on a fresh tunnel\n")
        return 1
    print(f"OK healthy age={res.fields.get('handshake_age_seconds')} bounces={spy.calls}")
    return 0


def cmd_stale(repo_root: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        # Mock warp-cli reports a STALE handshake (the live 3153s failure mode).
        os.environ["WARP_HANDSHAKE_AGE"] = "3153"
        res = reconcile.tunnel_health(transport, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(f"FAIL stale: status {res.status} (want error)\n")
        return 1
    if res.fields.get("transport_degraded") is not True:
        sys.stderr.write(f"FAIL stale: transport_degraded {res.fields}\n")
        return 1
    if spy.calls != 1:
        sys.stderr.write(f"FAIL stale: bounce invoked {spy.calls}x (want exactly 1)\n")
        return 1
    if res.fields.get("bounced") is not True:
        sys.stderr.write(f"FAIL stale: bounced field {res.fields}\n")
        return 1
    print(f"OK stale age={res.fields.get('handshake_age_seconds')} bounces={spy.calls}")
    return 0


def cmd_bounded(repo_root: str) -> int:
    """Repeated stale ticks DRIVEN THROUGH run_step must NOT bounce on every
    call — the reconcile.db backoff gate paces the bounce."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    conn = reconcile.open_reconcile_db()
    step = reconcile.STEP_TUNNEL_HEALTH
    try:
        os.environ["WARP_HANDSHAKE_AGE"] = "3153"
        adapter = lambda: reconcile.tunnel_health(transport, _warp_cfg())

        # Tick 1 at t=1000: eligible (never attempted) -> adapter runs -> stale
        # -> bounce #1 -> error result engages backoff (next_eligible in future).
        r1 = reconcile.run_step(conn, step, adapter, now=1000.0,
                                backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
        if r1.status != reconcile.RESULT_ERROR:
            sys.stderr.write(f"FAIL bounded: tick1 status {r1.status}\n")
            return 1
        if spy.calls != 1:
            sys.stderr.write(f"FAIL bounded: tick1 bounces {spy.calls} (want 1)\n")
            return 1

        # Tick 2 at t=1000.5: STILL within the backoff cooldown -> run_step SKIPS
        # the adapter entirely (noop) -> NO second bounce. This is the bounded
        # invariant: a flapping stale tunnel cannot bounce-storm.
        r2 = reconcile.run_step(conn, step, adapter, now=1000.5,
                                backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
        if r2.status != reconcile.RESULT_NOOP:
            sys.stderr.write(f"FAIL bounded: tick2 not skipped ({r2.status})\n")
            return 1
        if spy.calls != 1:
            sys.stderr.write(
                f"FAIL bounded: tick2 bounced again (calls={spy.calls}, want 1)\n")
            return 1

        # Tick 3 far in the FUTURE (past the cooldown) -> eligible again ->
        # adapter runs -> bounce #2. The bounce is PACED, not suppressed forever.
        r3 = reconcile.run_step(conn, step, adapter, now=5000.0,
                                backoff_base=2.0, backoff_cap=300.0, jitter_frac=0.0)
        if r3.status != reconcile.RESULT_ERROR:
            sys.stderr.write(f"FAIL bounded: tick3 status {r3.status}\n")
            return 1
        if spy.calls != 2:
            sys.stderr.write(
                f"FAIL bounded: tick3 bounces {spy.calls} (want 2 — paced, not every tick)\n")
            return 1
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        conn.close()
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    print(f"OK bounded bounces={spy.calls} (paced by backoff: tick1+tick3, tick2 skipped)")
    return 0


def cmd_active_only(repo_root: str) -> int:
    """The tailscale path never shells warp-cli and vice-versa. The OTHER
    transport's mock CLI is rigged to FAIL if invoked (env BOOM_*), so an
    accidental cross-shell would be caught as a degraded/raise."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)

    # --- tailscale transport must NOT touch warp-cli ---
    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        # Tailscale mock reports a healthy tailnet; warp-cli mock is set to a
        # mode that would FAIL the warp probe if (wrongly) invoked.
        os.environ["TS_MOCK_MODE"] = "up"
        os.environ["WARP_HANDSHAKE_AGE"] = "3153"  # would bounce IF warp probed
        res_ts = reconcile.tunnel_health(a2a.TRANSPORT_TAILSCALE, _tailscale_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("TS_MOCK_MODE", None)
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    if res_ts.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL active-only: tailscale status {res_ts.status}\n")
        return 1
    if res_ts.fields.get("transport") != "tailscale":
        sys.stderr.write(f"FAIL active-only: tailscale fields {res_ts.fields}\n")
        return 1
    if spy.calls != 0:
        sys.stderr.write(
            f"FAIL active-only: tailscale path invoked the WARP bounce {spy.calls}x\n")
        return 1

    # --- warp transport must NOT touch the tailscale CLI ---
    # The tailscale mock is rigged to EXIT NON-ZERO; if the warp path wrongly
    # shelled it the probe would still ignore it (warp reads warp-cli). We point
    # BRIDGE_A2A_TAILSCALE_CLI at a binary that fails, and assert the warp probe
    # converges on a FRESH handshake regardless (it never consults tailscale).
    spy2 = _BounceSpy()
    reconcile._WARP_TUNNEL_BOUNCE = spy2
    try:
        os.environ["WARP_HANDSHAKE_AGE"] = "10"   # fresh
        os.environ["TS_MOCK_MODE"] = "boom"        # tailscale mock would fail
        res_warp = reconcile.tunnel_health(
            a2a.TRANSPORT_CLOUDFLARE_WARP_MESH, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)
        os.environ.pop("TS_MOCK_MODE", None)

    if res_warp.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL active-only: warp status {res_warp.status}\n")
        return 1
    if res_warp.fields.get("transport") != "cloudflare-warp-mesh":
        sys.stderr.write(f"FAIL active-only: warp fields {res_warp.fields}\n")
        return 1
    if spy2.calls != 0:
        sys.stderr.write(f"FAIL active-only: warp fresh tunnel bounced {spy2.calls}x\n")
        return 1
    print("OK active-only tailscale->no-warp-cli warp->no-tailscale")
    return 0


def cmd_parse_fail(repo_root: str) -> int:
    """A warp-cli that returns NO parseable handshake line -> error WITHOUT a
    bounce (an unknowable age is not a PROVEN stale handshake)."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        os.environ["WARP_HANDSHAKE_AGE"] = "garbage"  # mock prints no age line
        res = reconcile.tunnel_health(transport, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(f"FAIL parse-fail: status {res.status} (want error)\n")
        return 1
    if res.fields.get("transport_degraded") is not True:
        sys.stderr.write(f"FAIL parse-fail: transport_degraded {res.fields}\n")
        return 1
    if res.fields.get("handshake_age_known") is not False:
        sys.stderr.write(f"FAIL parse-fail: handshake_age_known {res.fields}\n")
        return 1
    if spy.calls != 0:
        sys.stderr.write(
            f"FAIL parse-fail: bounced {spy.calls}x on an unknowable age "
            "(only a PROVEN stale handshake may bounce)\n")
        return 1
    print(f"OK parse-fail bounces={spy.calls} (no bounce on unknowable age)")
    return 0


def cmd_nonzero_stale(repo_root: str) -> int:
    """A FAILED `warp-cli tunnel stats` (non-zero exit) that still printed a
    stale-looking handshake line -> error WITHOUT a bounce. The age is
    UNKNOWABLE on a failed probe; only a PROVEN stale handshake from a
    SUCCESSFUL probe may bounce (the #1595 rc-gate lesson). Regression guard
    for the codex r1 finding."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        # Stale-looking line but the mock exits NON-ZERO (failed query).
        os.environ["WARP_HANDSHAKE_AGE"] = "3153"
        os.environ["WARP_TUNNEL_RC"] = "7"
        res = reconcile.tunnel_health(transport, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)
        os.environ.pop("WARP_TUNNEL_RC", None)

    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(f"FAIL nonzero-stale: status {res.status} (want error)\n")
        return 1
    if res.fields.get("transport_degraded") is not True:
        sys.stderr.write(f"FAIL nonzero-stale: transport_degraded {res.fields}\n")
        return 1
    if res.fields.get("handshake_age_known") is not False:
        sys.stderr.write(
            f"FAIL nonzero-stale: a failed probe must be UNKNOWABLE, not proven "
            f"({res.fields})\n")
        return 1
    if spy.calls != 0:
        sys.stderr.write(
            f"FAIL nonzero-stale: bounced {spy.calls}x on a FAILED probe "
            "(non-zero rc + stale-looking line must NOT prove stale)\n")
        return 1
    print(f"OK nonzero-stale bounces={spy.calls} (failed probe = unknowable, no bounce)")
    return 0


def cmd_no_secret(repo_root: str) -> int:
    """The degraded result carries NO secret-shaped field."""
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    spy = _BounceSpy()
    original = reconcile._WARP_TUNNEL_BOUNCE
    reconcile._WARP_TUNNEL_BOUNCE = spy
    try:
        os.environ["WARP_HANDSHAKE_AGE"] = "3153"
        res = reconcile.tunnel_health(transport, _warp_cfg())
    finally:
        reconcile._WARP_TUNNEL_BOUNCE = original
        os.environ.pop("WARP_HANDSHAKE_AGE", None)

    blob = json.dumps({"detail": res.detail, "fields": res.fields}, default=str).lower()
    for bad in ("secret", "hmac", "token", "passwd", "password", "private_key",
                "enrollment", "apikey", "api_key", "bearer"):
        if bad in blob:
            sys.stderr.write(f"FAIL no-secret: secret-shaped field '{bad}' in {blob}\n")
            return 1
    # Only observable, non-secret keys may appear.
    allowed = {"transport", "transport_degraded", "handshake_age_seconds",
               "stale_threshold_seconds", "handshake_age_known", "bounced",
               "backend_state", "self_online"}
    extra = set(res.fields.keys()) - allowed
    if extra:
        sys.stderr.write(f"FAIL no-secret: unexpected field keys {extra}\n")
        return 1
    print("OK no-secret " + json.dumps(sorted(res.fields.keys())))
    return 0


_COMMANDS = {
    "healthy": cmd_healthy,
    "stale": cmd_stale,
    "bounded": cmd_bounded,
    "active-only": cmd_active_only,
    "parse-fail": cmd_parse_fail,
    "nonzero-stale": cmd_nonzero_stale,
    "no-secret": cmd_no_secret,
}


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in _COMMANDS:
        sys.stderr.write(
            "usage: v0165-l2-tunnel-health-helper.py "
            "<healthy|stale|bounded|active-only|parse-fail|nonzero-stale|"
            "no-secret> <repo_root>\n")
        return 2
    cmd, repo_root = sys.argv[1], sys.argv[2]
    return _COMMANDS[cmd](repo_root)


if __name__ == "__main__":
    sys.exit(main())
