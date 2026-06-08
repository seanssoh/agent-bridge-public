#!/usr/bin/env python3
"""Helper for scripts/smoke/a2a-tailscale-identity-resolve.sh.

Drives the P0 Tailscale-identity resolver (`resolve_peer_address` in
bridge_a2a_common) and the receiver bind proof (`resolve_bind` in
bridge-handoffd) directly, against a MOCK `tailscale` CLI selected via
BRIDGE_A2A_TAILSCALE_CLI. Each subcommand prints a single deterministic
result token (or `ERR:<code>`) that the bash smoke asserts on. The real
tailnet is never touched.

Subcommands:
  resolve <json-entry>      print the resolved address, or ERR:<code>
  bind <json-cfg>           print "<ip>:<port>", or ERR:<code> (runs the
                            FULL fail-closed bind proof — this is what
                            proves resolution did not weaken the proof)
  recv-auth <client_ip> <json-peer>
                            drive the receiver's do_POST() inbound
                            source-address gate against the configured
                            SENDER peer: resolve the peer's CURRENT
                            Tailscale IP and compare it to the request's
                            source IP. Prints "ACCEPT" when the resolved
                            address equals client_ip, "REJECT:addr_mismatch"
                            when it does not, or "REJECT:<code>" when the
                            resolver fails (fail-closed). This mirrors the
                            exact resolve + compare + fail-closed logic in
                            bridge-handoffd.do_POST so the inbound stale-IP
                            rejection is covered, not just the resolver.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# Put the repo root on sys.path so a by-path load of bridge-handoffd.py can
# resolve its sibling top-level imports (bridge_a2a_common, and as of v0.16.5
# Lane 0, bridge_reconcile_common). Without this the importlib exec_module
# below raises ModuleNotFoundError for any new sibling module bridge-handoffd
# imports — matches the sys.path.insert pattern the other by-path smokes use.
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def _load(mod_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(
        mod_name, str(REPO_ROOT / filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str]) -> int:
    a2a = _load("bridge_a2a_common", "bridge_a2a_common.py")

    if not argv:
        print("usage: helper resolve|bind <json>", file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "resolve":
        entry = json.loads(argv[1])
        try:
            print(a2a.resolve_peer_address(entry))
        except a2a.A2AError as exc:
            print(f"ERR:{exc.code}")
        return 0

    if cmd == "bind":
        # Import the receiver daemon so its aliased resolver + the
        # unchanged fail-closed proof both run. The module filename has a
        # dash, so load it by path.
        hd = _load("bridge_handoffd", "bridge-handoffd.py")
        cfg = json.loads(argv[1])
        try:
            bind, port = hd.resolve_bind(cfg)
            print(f"{bind}:{port}")
        except a2a.A2AError as exc:
            print(f"ERR:{exc.code}")
        return 0

    if cmd == "recv-auth":
        # Exercise the receiver's inbound source-address gate exactly as
        # bridge-handoffd.do_POST does: resolve the authenticated SENDER
        # peer to its CURRENT Tailscale IP (NOT a stored/stale literal
        # `address`) and compare to the request's source IP. FAIL CLOSED on
        # any resolver error — never fall through to ACCEPT. This is the
        # same three lines do_POST runs before reading the body; keeping it
        # in lock-step here is what gives the smoke teeth on the inbound
        # stale-IP class (resolve_peer_address resolving to X must accept a
        # request from X and reject one from the stale literal Y).
        client_ip = argv[1]
        peer = json.loads(argv[2])
        try:
            peer_addr = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            # fail-closed: resolver/Tailscale error -> reject the request
            print(f"REJECT:{exc.code}")
            return 0
        if not peer_addr or client_ip != peer_addr:
            print("REJECT:addr_mismatch")
            return 0
        print("ACCEPT")
        return 0

    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
