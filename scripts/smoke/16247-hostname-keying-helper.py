#!/usr/bin/env python3
"""Helper for scripts/smoke/16247-hostname-keying.sh.

Drives the #16247 DNS-`hostname` peer-keying resolver in bridge_a2a_common
directly, with `socket.getaddrinfo` monkeypatched to a controllable fake so
the real DNS is NEVER touched (macOS-runnable, pure python3). Runs a set of
self-contained scenarios — several are STATEFUL (the hostname cache is
process-global: TTL serve-on-blip, negative cache, timeout) so they live
in-process here rather than as one-shot CLI calls. Each scenario prints
`PASS:<name>` or `FAIL:<name> <detail>`; the bash smoke asserts the full set
plus a non-vacuous mutation.
"""
from __future__ import annotations

import importlib.util
import socket
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _load_a2a():
    spec = importlib.util.spec_from_file_location(
        "bridge_a2a_common", str(REPO_ROOT / "bridge_a2a_common.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["bridge_a2a_common"] = mod
    spec.loader.exec_module(mod)
    return mod


a2a = _load_a2a()

# --- controllable fake DNS ------------------------------------------------
# name -> list[ip]  (resolves), "FAIL" (getaddrinfo raises), "HANG" (sleeps
# past the lookup timeout so the bounded resolver abandons it).
_DNS: dict[str, object] = {}


def _fake_getaddrinfo(host, *args, **kwargs):
    val = _DNS.get(host)
    if val == "FAIL" or val is None:
        raise socket.gaierror(socket.EAI_NONAME, "Name or service not known")
    if val == "HANG":
        time.sleep(2.0)
        raise socket.gaierror(socket.EAI_NONAME, "late")
    # Mimic getaddrinfo's 5-tuple; sockaddr is index 4, addr is sockaddr[0].
    out = []
    for ip in val:  # type: ignore[union-attr]
        fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
        sockaddr = (ip, 0, 0, 0) if fam == socket.AF_INET6 else (ip, 0)
        out.append((fam, socket.SOCK_STREAM, 6, "", sockaddr))
    return out


socket.getaddrinfo = _fake_getaddrinfo  # type: ignore[assignment]
# Tighten the bounded-lookup timeout so the HANG scenario is fast.
a2a.HOSTNAME_LOOKUP_TIMEOUT = 0.3
a2a.HOSTNAME_NEG_CACHE_TTL = 0.5

# MUTATION hook (non-vacuity): BRIDGE_SMOKE_MUTATE=single_ip emulates the
# pre-#16247 single-string source-check by collapsing the receiver's set to
# the first IP — the multi-A-nonfirst scenario MUST then FAIL, proving the
# membership check is what accepts a non-first A-record.
import os as _os  # noqa: E402
if _os.environ.get("BRIDGE_SMOKE_MUTATE") == "single_ip":
    _orig_psa = a2a.peer_source_addresses

    def _mutated_psa(kind, entry):
        s = _orig_psa(kind, entry)
        return {sorted(s)[0]} if s else s
    a2a.peer_source_addresses = _mutated_psa  # type: ignore[assignment]


def _reset(dns: dict | None = None):
    a2a._HOSTNAME_CACHE.clear()
    _DNS.clear()
    if dns:
        _DNS.update(dns)


RESULTS: list[str] = []


def ok(name: str, cond: bool, detail: str = ""):
    RESULTS.append(f"PASS:{name}" if cond else f"FAIL:{name} {detail}")


def recv_accepts(kind: str, client_ip: str, peer: dict) -> bool:
    """Mirror the bridge-handoffd source-check: membership of the normalized
    client_ip in the peer's CURRENT resolved set (raises propagate)."""
    addrs = a2a.peer_source_addresses(kind, peer)
    return bool(addrs) and a2a.normalize_ip(client_ip) in addrs


def main() -> int:
    # 1. precedence: node_id shadows hostname (no DNS consulted).
    _reset({"h.example": ["10.0.0.9"]})
    try:
        a2a.resolve_peer_address({"node_id": "X", "hostname": "h.example"})
        ok("precedence_node_id_shadows", False, "expected resolve error")
    except a2a.A2AError as e:
        ok("precedence_node_id_shadows",
           e.code != "resolve_hostname_failed" and not a2a._HOSTNAME_CACHE,
           f"code={e.code} cache={dict(a2a._HOSTNAME_CACHE)}")

    # 2. sender single deterministic IP (lowest sorted).
    _reset({"multi.example": ["10.0.0.6", "10.0.0.5"]})
    ok("sender_first_ip",
       a2a.resolve_peer_address({"hostname": "multi.example"}) == "10.0.0.5")

    # 3. ★receiver multi-A membership: accepts a NON-first A-record.
    #    (This is the non-vacuous heart — a single-string compare would reject.)
    _reset({"multi.example": ["10.0.0.5", "10.0.0.6"]})
    ok("recv_multi_a_first", recv_accepts("trusted-routed", "10.0.0.5",
                                          {"hostname": "multi.example"}))
    _reset({"multi.example": ["10.0.0.5", "10.0.0.6"]})
    ok("recv_multi_a_nonfirst", recv_accepts("trusted-routed", "10.0.0.6",
                                             {"hostname": "multi.example"}))
    _reset({"multi.example": ["10.0.0.5", "10.0.0.6"]})
    ok("recv_off_set_rejected",
       not recv_accepts("trusted-routed", "10.0.0.99",
                        {"hostname": "multi.example"}))

    # 4. IPv4-mapped IPv6 normalization (AAAA ::ffff:v4 == v4 client).
    _reset({"mapped.example": ["::ffff:10.0.0.9"]})
    ok("ipv4_mapped_norm", recv_accepts("trusted-routed", "10.0.0.9",
                                        {"hostname": "mapped.example"}))

    # 5. malformed hostname (non-string) rejects (no address fallback).
    _reset()
    try:
        a2a.resolve_peer_address({"hostname": 123, "address": "10.0.0.1"})
        ok("malformed_hostname", False, "expected reject")
    except a2a.A2AError as e:
        ok("malformed_hostname", e.code == "resolve_shape", f"code={e.code}")

    # 5b. ★dot-only hostname is a MALFORMED selected key — it must FAIL CLOSED,
    #     NOT silently fall back to the literal `address` (#16247 patch-dev
    #     review finding). Sender AND receiver.
    _reset()
    for dotonly in (".", "..", " . "):
        try:
            a2a.resolve_peer_address({"hostname": dotonly, "address": "10.0.0.1"})
            ok("dotonly_sender_failclosed", False, f"{dotonly!r} fell back")
            break
        except a2a.A2AError as e:
            if e.code != "resolve_hostname_blank":
                ok("dotonly_sender_failclosed", False, f"{dotonly!r} code={e.code}")
                break
    else:
        ok("dotonly_sender_failclosed", True)
    _reset()
    try:
        a2a.peer_source_addresses("trusted-routed",
                                  {"hostname": ".", "address": "10.0.0.1"})
        ok("dotonly_recv_failclosed", False, "receiver produced a set")
    except a2a.A2AError as e:
        ok("dotonly_recv_failclosed", e.code == "resolve_hostname_blank", e.code)

    # 5c. a truly BLANK/absent hostname key stays absent (back-compat) — the
    #     legacy literal `address` still applies (patch-dev preserved boundary).
    _reset()
    ok("blank_hostname_uses_address",
       a2a.resolve_peer_address({"hostname": "", "address": "10.0.0.1"})
       == "10.0.0.1")
    _reset()
    ok("whitespace_hostname_uses_address",
       a2a.resolve_peer_address({"hostname": "   ", "address": "10.0.0.2"})
       == "10.0.0.2")

    # 6. routed transport rejects a tailscale key even alongside hostname.
    _reset({"h.example": ["10.0.0.9"]})
    try:
        a2a.resolve_peer_address_for_transport(
            "trusted-routed", {"node_id": "X", "hostname": "h.example"})
        ok("routed_rejects_tskey", False, "expected reject")
    except a2a.A2AError as e:
        ok("routed_rejects_tskey", e.code == "warp_identity_misconfig",
           f"code={e.code}")

    # 7. fail-closed on unresolvable + short NEGATIVE cache (no re-resolve).
    _reset({"fail.example": "FAIL"})
    calls = {"n": 0}
    real = _fake_getaddrinfo

    def counting(host, *a, **k):
        calls["n"] += 1
        return real(host, *a, **k)
    socket.getaddrinfo = counting  # type: ignore[assignment]
    try:
        a2a.resolve_hostname_ips("fail.example")
        ok("failclosed_first", False, "expected error")
    except a2a.A2AError as e:
        ok("failclosed_first", e.code == "resolve_hostname_failed", e.code)
    try:
        a2a.resolve_hostname_ips("fail.example")
        ok("neg_cache_second", False, "expected error")
    except a2a.A2AError as e:
        ok("neg_cache_second",
           e.code == "resolve_hostname_neg_cache" and calls["n"] == 1,
           f"code={e.code} dns_calls={calls['n']}")
    socket.getaddrinfo = _fake_getaddrinfo  # type: ignore[assignment]

    # 8. ★serve a still-valid cached set on a transient DNS blip (no 403).
    _reset({"blip.example": ["10.0.0.7"]})
    a2a.resolve_hostname_ips("blip.example")        # prime the positive cache
    _DNS["blip.example"] = "FAIL"                   # DNS now blips
    try:
        served = a2a.resolve_hostname_ips("blip.example")
        ok("cache_serves_on_blip", served == frozenset({"10.0.0.7"}),
           f"served={sorted(served)}")
    except a2a.A2AError as e:
        ok("cache_serves_on_blip", False, f"unexpected reject {e.code}")

    # 9. fail-closed once the positive entry EXPIRES and DNS still fails.
    _reset({"exp.example": ["10.0.0.8"]})
    a2a.HOSTNAME_CACHE_TTL = 0.2
    a2a.resolve_hostname_ips("exp.example")
    _DNS["exp.example"] = "FAIL"
    time.sleep(0.3)                                 # let the positive TTL lapse
    try:
        a2a.resolve_hostname_ips("exp.example")
        ok("failclosed_after_expiry", False, "expected reject post-expiry")
    except a2a.A2AError as e:
        ok("failclosed_after_expiry",
           e.code in ("resolve_hostname_failed", "resolve_hostname_neg_cache"),
           e.code)
    a2a.HOSTNAME_CACHE_TTL = 45.0

    # 10. bounded lookup abandons a HANGing resolver (timeout -> A2AError).
    _reset({"hang.example": "HANG"})
    t0 = time.monotonic()
    try:
        a2a.resolve_hostname_ips("hang.example")
        ok("bounded_timeout", False, "expected timeout reject")
    except a2a.A2AError as e:
        dt = time.monotonic() - t0
        ok("bounded_timeout",
           e.code == "resolve_hostname_timeout" and dt < 1.5,
           f"code={e.code} dt={dt:.2f}")

    # 11. back-compat: a raw-IP peer is byte-unchanged (single-elem set).
    _reset()
    ok("backcompat_raw_single",
       a2a.resolve_peer_address({"address": "192.168.1.10"}) == "192.168.1.10")
    ok("backcompat_raw_set",
       a2a.peer_source_addresses("trusted-routed", {"address": "192.168.1.10"})
       == {"192.168.1.10"})

    # 12. trailing-dot + case fold to the same cache key (one resolve).
    _reset({"fqdn.example": ["10.0.0.11"]})
    calls2 = {"n": 0}

    def counting2(host, *a, **k):
        calls2["n"] += 1
        return _fake_getaddrinfo(host, *a, **k)
    socket.getaddrinfo = counting2  # type: ignore[assignment]
    a2a.resolve_peer_address({"hostname": "FQDN.example."})
    a2a.resolve_peer_address({"hostname": "fqdn.example"})
    ok("hostname_norm_cache_key", calls2["n"] == 1, f"dns_calls={calls2['n']}")
    socket.getaddrinfo = _fake_getaddrinfo  # type: ignore[assignment]

    for line in RESULTS:
        print(line)
    return 0 if all(r.startswith("PASS:") for r in RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
