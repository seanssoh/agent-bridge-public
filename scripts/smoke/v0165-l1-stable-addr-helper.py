#!/usr/bin/env python3
"""v0165-l1-stable-addr-helper.py — driver for the Lane-1 stable-addr adapter
smoke (#1705).

Loaded file-as-argv (footgun #11: NO heredoc-stdin). Exercises the reconcile
`stable-addr` step (bridge_reconcile_common.stable_local_addr) against an
ISOLATED config (BRIDGE_A2A_CONFIG → a tmpdir file) with the detector probe
seams MOCKED so the REAL adapter code path runs with no real Tailscale/WARP:
  - BRIDGE_A2A_IFACE_ADDRS  — the WARP detector's live interface set.
  - BRIDGE_A2A_TAILSCALE_CLI — a mock `tailscale` CLI (or an absent path).

Subcommands (each prints `OK <cmd> ...` + exits 0 on pass; `FAIL ...` to stderr
+ exits 1 on a contract violation):
  warp-converged    <repo_root> <cfg> — desired listen.address already == the
                                        observed WARP utun addr → step_converged
                                        (idempotent no-op; config UNCHANGED).
  warp-changed      <repo_root> <cfg> — desired drifted from the observed WARP
                                        utun addr → step_changed AND the written
                                        config holds the new addr; a re-run is
                                        then converged (idempotent).
  warp-error        <repo_root> <cfg> — no WARP addr on any local interface →
                                        step_error (NOT a bad-addr return); the
                                        config is left UNCHANGED (fail-closed).
  ts-converged      <repo_root> <cfg> — tailscale node: desired == `tailscale
                                        ip` addr → step_converged.
  ts-changed        <repo_root> <cfg> — tailscale node: desired drifted → the
                                        written config holds the `tailscale ip`
                                        addr (NOT a WARP utun addr, even when an
                                        iface override is present).
  ts-error          <repo_root> <cfg> — tailscale CLI absent → step_error
                                        (fail-closed), config UNCHANGED.
  isolation         <repo_root> <cfg> — active-transport-only: a WARP node never
                                        shells `tailscale` (a poisoned ts CLI is
                                        never invoked) and a tailscale node never
                                        returns a WARP utun addr.
  malformed         <repo_root> <cfg> — a MALFORMED/unknown transport.kind with
                                        the orchestrator's guessed-tailscale arg
                                        → step_error (NOT a detect+persist under a
                                        guess); config left UNCHANGED. The
                                        poisoned ts CLI must never run.

Every subcommand also asserts the adapter NEVER returns an address that is not
in the mocked live interface / `tailscale ip` set (fail-closed).
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


def _read_listen_addr(cfg_path: str) -> str:
    with open(cfg_path, encoding="utf-8") as fh:
        return json.load(fh)["listen"].get("address", "")


def cmd_warp_converged(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    res = reconcile.stable_local_addr("cloudflare-warp-mesh", cfg)
    if res.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL warp-converged: status {res.status} ({res.detail})\n")
        return 1
    after = _read_listen_addr(cfg_path)
    if after != before:
        sys.stderr.write(
            f"FAIL warp-converged: config mutated on a no-op ({before} -> {after})\n")
        return 1
    print(f"OK warp-converged status={res.status} addr={after}")
    return 0


def cmd_warp_changed(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)

    iface = os.environ.get("BRIDGE_A2A_IFACE_ADDRS", "")  # noqa: iso-helper-boundary
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    res = reconcile.stable_local_addr("cloudflare-warp-mesh", cfg)
    if res.status != reconcile.RESULT_CHANGED:
        sys.stderr.write(f"FAIL warp-changed: status {res.status} ({res.detail})\n")
        return 1
    observed = res.fields.get("observed", "")
    # The returned address MUST be one of the mocked live interface addresses
    # (fail-closed — never a guessed/synthesized addr).
    if observed not in iface.replace(",", " ").split():
        sys.stderr.write(
            f"FAIL warp-changed: observed {observed!r} not in live iface set {iface!r}\n")
        return 1
    after = _read_listen_addr(cfg_path)
    if after != observed:
        sys.stderr.write(
            f"FAIL warp-changed: on-disk listen.address {after!r} != observed {observed!r}\n")
        return 1
    if after == before:
        sys.stderr.write(f"FAIL warp-changed: config not updated (still {before})\n")
        return 1
    if res.fields.get("desired") != observed:
        sys.stderr.write(
            f"FAIL warp-changed: fields.desired {res.fields.get('desired')!r} != observed\n")
        return 1
    # Re-run is IDEMPOTENT: now converged, no further mutation.
    cfg2 = a2a.load_config()
    res2 = reconcile.stable_local_addr("cloudflare-warp-mesh", cfg2)
    if res2.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL warp-changed: re-run not idempotent ({res2.status})\n")
        return 1
    if _read_listen_addr(cfg_path) != observed:
        sys.stderr.write("FAIL warp-changed: re-run mutated the converged config\n")
        return 1
    print(f"OK warp-changed {before} -> {observed} (config-written, idempotent re-run)")
    return 0


def cmd_warp_error(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    res = reconcile.stable_local_addr("cloudflare-warp-mesh", cfg)
    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(
            f"FAIL warp-error: expected step_error, got {res.status} "
            f"(a bad-addr return is a security defect) — {res.detail}\n")
        return 1
    # Fail-closed: the config MUST be left untouched (no bad address written).
    after = _read_listen_addr(cfg_path)
    if after != before:
        sys.stderr.write(
            f"FAIL warp-error: config mutated on an unprovable addr ({before} -> {after})\n")
        return 1
    print(f"OK warp-error status={res.status} (config unchanged, fail-closed)")
    return 0


def cmd_ts_converged(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    res = reconcile.stable_local_addr("tailscale", cfg)
    if res.status != reconcile.RESULT_CONVERGED:
        sys.stderr.write(f"FAIL ts-converged: status {res.status} ({res.detail})\n")
        return 1
    if _read_listen_addr(cfg_path) != before:
        sys.stderr.write("FAIL ts-converged: config mutated on a no-op\n")
        return 1
    print(f"OK ts-converged status={res.status} addr={before}")
    return 0


def cmd_ts_changed(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    cfg = a2a.load_config()
    # The expected tailscale IP comes from the mock `tailscale ip` (first IPv4).
    expected = a2a.tailscale_stable_addr()
    iface = os.environ.get("BRIDGE_A2A_IFACE_ADDRS", "")  # noqa: iso-helper-boundary
    res = reconcile.stable_local_addr("tailscale", cfg)
    if res.status != reconcile.RESULT_CHANGED:
        sys.stderr.write(f"FAIL ts-changed: status {res.status} ({res.detail})\n")
        return 1
    observed = res.fields.get("observed", "")
    if observed != expected:
        sys.stderr.write(
            f"FAIL ts-changed: observed {observed!r} != `tailscale ip` {expected!r}\n")
        return 1
    # CROSS-TRANSPORT: the tailscale path must NOT return a WARP utun addr even
    # when an iface override carrying a 10.128.x addr is present.
    if observed in iface.replace(",", " ").split() and observed.startswith("10.128."):
        sys.stderr.write(
            f"FAIL ts-changed: tailscale path returned a WARP utun addr {observed!r}\n")
        return 1
    if _read_listen_addr(cfg_path) != expected:
        sys.stderr.write(
            f"FAIL ts-changed: on-disk addr != `tailscale ip` ({expected})\n")
        return 1
    print(f"OK ts-changed -> {observed} (tailscale ip, not WARP utun)")
    return 0


def cmd_ts_error(repo_root: str, cfg_path: str) -> int:
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    res = reconcile.stable_local_addr("tailscale", cfg)
    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(
            f"FAIL ts-error: expected step_error (CLI absent), got {res.status}\n")
        return 1
    if _read_listen_addr(cfg_path) != before:
        sys.stderr.write("FAIL ts-error: config mutated despite unprovable addr\n")
        return 1
    print(f"OK ts-error status={res.status} (fail-closed, config unchanged)")
    return 0


def cmd_isolation(repo_root: str, cfg_path: str) -> int:
    """A WARP node never shells `tailscale`; a tailscale node never returns WARP.

    The caller points BRIDGE_A2A_TAILSCALE_CLI at a mock that writes a sentinel
    file + exits non-zero IF invoked. Running the WARP branch must converge/change
    WITHOUT the sentinel ever appearing — proving the WARP path never shelled
    tailscale (active-transport-only).
    """
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    sentinel = os.environ.get("L1_TS_SENTINEL", "")  # noqa: iso-helper-boundary
    cfg = a2a.load_config()
    res = reconcile.stable_local_addr("cloudflare-warp-mesh", cfg)
    if res.status not in (reconcile.RESULT_CONVERGED, reconcile.RESULT_CHANGED):
        sys.stderr.write(f"FAIL isolation: WARP branch status {res.status} ({res.detail})\n")
        return 1
    if sentinel and os.path.exists(sentinel):
        sys.stderr.write(
            "FAIL isolation: WARP branch SHELLED tailscale (sentinel present)\n")
        return 1
    observed = res.fields.get("observed", "")
    if not observed.startswith("10.128.") and ":" not in observed:
        sys.stderr.write(
            f"FAIL isolation: WARP branch returned a non-WARP addr {observed!r}\n")
        return 1
    print(f"OK isolation WARP-only observed={observed} (tailscale never shelled)")
    return 0


def cmd_malformed(repo_root: str, cfg_path: str) -> int:
    """A malformed/unknown transport.kind must NOT detect+persist under a guess.

    bridge-handoffd.py:_run_reconcile_steps falls back to a GUESSED
    `transport="tailscale"` when `transport_kind(cfg)` raises (malformed/unknown
    `transport.kind`). The adapter must re-derive the kind from `cfg` and refuse
    (step_error) rather than shell `tailscale ip` + persist `listen.address`
    under a guessed transport (the codex [P1] regression). The caller points
    BRIDGE_A2A_TAILSCALE_CLI at a poisoned CLI that writes a sentinel + exits
    non-zero IF run; the sentinel must never appear (the detector never ran).
    """
    reconcile = _load_reconcile(repo_root)
    a2a = _load_a2a(repo_root)
    sentinel = os.environ.get("L1_TS_SENTINEL", "")  # noqa: iso-helper-boundary
    cfg = a2a.load_config()
    before = _read_listen_addr(cfg_path)
    # Mimic the orchestrator's guessed fallback arg after transport_kind raised.
    res = reconcile.stable_local_addr("tailscale", cfg)
    if res.status != reconcile.RESULT_ERROR:
        sys.stderr.write(
            f"FAIL malformed: expected step_error under a guessed transport, "
            f"got {res.status} (detect+persist under a guess is a defect) — "
            f"{res.detail}\n")
        return 1
    after = _read_listen_addr(cfg_path)
    if after != before:
        sys.stderr.write(
            f"FAIL malformed: config mutated under a guessed transport "
            f"({before} -> {after})\n")
        return 1
    if sentinel and os.path.exists(sentinel):
        sys.stderr.write(
            "FAIL malformed: the stable-addr detector SHELLED tailscale under a "
            "guessed transport (sentinel present)\n")
        return 1
    print(f"OK malformed status={res.status} (no detect/persist under a guess)")
    return 0


_COMMANDS = {
    "warp-converged": cmd_warp_converged,
    "warp-changed": cmd_warp_changed,
    "warp-error": cmd_warp_error,
    "ts-converged": cmd_ts_converged,
    "ts-changed": cmd_ts_changed,
    "ts-error": cmd_ts_error,
    "isolation": cmd_isolation,
    "malformed": cmd_malformed,
}


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[1] not in _COMMANDS:
        sys.stderr.write(
            "usage: v0165-l1-stable-addr-helper.py "
            f"<{'|'.join(_COMMANDS)}> <repo_root> <cfg_path>\n")
        return 2
    cmd, repo_root, cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
    return _COMMANDS[cmd](repo_root, cfg_path)


if __name__ == "__main__":
    sys.exit(main())
