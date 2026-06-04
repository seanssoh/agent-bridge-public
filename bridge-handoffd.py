#!/usr/bin/env python3
"""bridge-handoffd.py — Agent Bridge A2A receiver daemon.

Listens on the Tailscale tailnet interface ONLY for `POST /enqueue`
cross-bridge task handoffs. Every request is HMAC-verified against the
ordered-pair peer secret, source-address-checked against the configured
peer, allowlist-checked against `(peer, target_agent)`, and durably
deduped on `message_id`. Accepted handoffs are staged to disk and enqueued
through the EXISTING `bridge-task.sh create` boundary (never the queue
backend directly) so local validation / prompt-guard / notification all
run unchanged.

Fail-closed contract: the server REFUSES to start if the configured bind
address is `0.0.0.0` / `::` / a loopback address / or not present in the
local Tailscale address set.

Usage:
  bridge-handoffd.py serve   --config <path>   [--once]
                             [--detach --pidfile <path>]
  bridge-handoffd.py preflight --config <path>   # validate bind, exit
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

import bridge_a2a_common as a2a

try:
    # A2A rooms (design §6, §14 R2/R6): the room-scoped receiver-check seam
    # consults the rooms membership model. Imported best-effort so a node
    # that has never defined a room (no rooms.db) still starts — the seam
    # then sees rooms_acl=off and no membership and passes non-room traffic
    # unchanged.
    import bridge_rooms_common as rooms
except ImportError:  # pragma: no cover - the module ships beside this file
    rooms = None  # type: ignore[assignment]

# Hard cap on a request body the server will read off the socket before
# any parsing. Larger than the per-peer cap so an oversized body is
# rejected with a clean 413 rather than truncated.
ABSOLUTE_MAX_REQUEST_BYTES = 4 * 1024 * 1024

# P-self-heal phase 1 (#1403): how often the running receiver re-resolves
# its own bind + re-reads the config so a local-IP drift (after a tailnet
# re-login) or a config edit (added/removed peer, allowlist/caps change)
# is applied with NO manual `bridge-handoff-daemon.sh restart`. Overridable
# via BRIDGE_A2A_RECONCILE_INTERVAL (seconds); 0 disables the periodic timer
# (a SIGHUP-triggered reconcile still works). Default 45s — the middle of
# the 30-60s band.
DEFAULT_RECONCILE_INTERVAL_SECONDS = 45


def _reconcile_interval() -> int:
    """Resolve the reconcile cadence (seconds). 0 disables the timer."""
    raw = os.environ.get("BRIDGE_A2A_RECONCILE_INTERVAL", "")
    if raw == "":
        return DEFAULT_RECONCILE_INTERVAL_SECONDS
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_RECONCILE_INTERVAL_SECONDS
    return max(0, val)


def log(msg: str) -> None:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[handoffd] {stamp} {msg}", file=sys.stderr, flush=True)


def audit(event: str, **fields: Any) -> None:
    """Append a structured audit line — never logs secrets or full bodies."""
    record = {"ts": int(time.time()), "component": "a2a-handoffd", "event": event}
    record.update(fields)
    log_dir = Path(os.environ.get("BRIDGE_LOG_DIR", str(a2a.bridge_home() / "logs")))
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "a2a-handoff.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass
    log(f"{event} " + " ".join(f"{k}={v}" for k, v in fields.items()))


# --------------------------------------------------------------------------
# Tailscale address discovery + bind validation (fail-closed)
# --------------------------------------------------------------------------

# The Tailscale-CLI locate logic + the TailscaleUnavailable error live in
# the shared module (bridge_a2a_common) so the sender's identity resolver
# and the receiver's bind proof never diverge on where the CLI is or what
# "unavailable" means. We alias them here so existing references in this
# file (and the `from bridge_handoffd import TailscaleUnavailable`-style
# call sites in the smokes) keep working unchanged.
TailscaleUnavailable = a2a.TailscaleUnavailable
resolve_tailscale_cli = a2a.resolve_tailscale_cli
_TAILSCALE_FALLBACK_PATHS = a2a._TAILSCALE_FALLBACK_PATHS


def tailscale_addresses() -> list[str]:
    """Return the local node's Tailscale IPs.

    Raises TailscaleUnavailable if the `tailscale` CLI cannot be located
    or the query fails — the caller must fail closed in that case rather
    than guessing from a CIDR shape. An *empty* list (CLI ran fine but
    the node has no Tailscale address) is returned as `[]`.
    """
    cli = resolve_tailscale_cli()
    if cli is None:
        raise TailscaleUnavailable(
            "the 'tailscale' CLI was not found on PATH or in any standard "
            "install location (/opt/homebrew/bin, /usr/local/bin, "
            "/Applications/Tailscale.app/Contents/MacOS, /usr/bin) — cannot "
            "prove the bind address is a real local Tailscale interface. "
            "Install Tailscale, set BRIDGE_A2A_TAILSCALE_CLI to its path, "
            "or set BRIDGE_A2A_ALLOW_TEST_BIND=1 for a loopback test bind."
        )
    try:
        out = subprocess.run(
            [cli, "ip"],
            capture_output=True, text=True, timeout=5,
        )
    except FileNotFoundError as exc:
        raise TailscaleUnavailable(
            f"the 'tailscale' CLI path {cli!r} does not exist or is not "
            "executable — cannot prove the bind address is a real local "
            "Tailscale interface."
        ) from exc
    except (subprocess.SubprocessError, OSError) as exc:
        raise TailscaleUnavailable(
            f"'tailscale ip' failed to run: {exc}"
        ) from exc
    if out.returncode != 0:
        raise TailscaleUnavailable(
            f"'tailscale ip' exited {out.returncode}: "
            f"{(out.stderr or '').strip()[:200]}"
        )
    addrs: list[str] = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line:
            addrs.append(line)
    return addrs


def is_tailnet_address(addr: str, allowed: list[str]) -> bool:
    """True only if `addr` is in THIS node's actual Tailscale address set.

    `allowed` is the exact output of `tailscale ip`. There is deliberately
    NO CIDR-shape fallback: a host can have a non-Tailscale interface
    inside 100.64.0.0/10, so "tailnet-shaped" does not prove "this node's
    Tailscale interface". When the local address set cannot be determined
    the caller raises TailscaleUnavailable and fails closed.
    """
    return addr in allowed


def resolve_bind(cfg: dict[str, Any]) -> tuple[str, int]:
    """Resolve + fail-closed-validate the receiver bind address.

    Raises A2AError if the bind is missing, loopback, wildcard, or not a
    tailnet address.
    """
    listen = cfg.get("listen", {})
    if not isinstance(listen, dict):
        raise a2a.A2AError("config 'listen' must be an object", code="bind_config")
    port = int(listen.get("port", 8787))

    # P0: if `listen` carries a Tailscale identity (`node_id` /
    # `tailscale_name`), resolve it to the node's CURRENT TailscaleIP via
    # `tailscale status --json`. Resolution ONLY produces a candidate IP —
    # the fail-closed proof below (candidate ∈ `tailscale ip` set) is
    # unchanged and still independently proves the candidate is a real local
    # Tailscale interface. When `listen` has only a raw `address` (legacy),
    # resolve_peer_address returns it verbatim and behavior is exactly as
    # before. A resolution failure (identity given but not resolvable, or
    # Tailscale unavailable) propagates as an A2AError / TailscaleUnavailable
    # and the daemon fails closed — it never silently binds a stale address.
    bind = a2a.resolve_peer_address(listen).strip()

    if not bind:
        # Auto-select fails closed: tailscale_addresses() raises
        # TailscaleUnavailable when the local address set is unknowable.
        tailnet = tailscale_addresses()
        if not tailnet:
            raise a2a.A2AError(
                "no listen.address configured and 'tailscale ip' returned "
                "no addresses. Set listen.address to this node's tailnet IP "
                "in handoff.local.json.",
                code="bind_unresolved",
            )
        bind = tailnet[0]
        log(f"listen.address not set; auto-selected tailnet IP {bind}")

    lowered = bind.lower()
    if lowered in ("0.0.0.0", "::", "*"):
        raise a2a.A2AError(
            f"refusing to bind to wildcard address {bind!r} — the A2A "
            "receiver MUST bind to a tailnet IP only.",
            code="bind_wildcard",
        )

    # Test-only escape hatch for the smoke harness: bind to a loopback
    # address when BRIDGE_A2A_ALLOW_TEST_BIND=1. This is NEVER honored for
    # wildcard addresses (the check above already rejected those) and is
    # not surfaced anywhere in the operator-facing config or CLI. Smoke
    # tests cannot exercise a real tailnet, so this lets the loopback
    # end-to-end smoke run without weakening the production fail-closed
    # contract for any unset/normal environment.
    if os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1":
        try:
            test_ip = ipaddress.ip_address(bind)
        except ValueError as exc:
            raise a2a.A2AError(f"listen.address {bind!r} is not an IP: {exc}",
                               code="bind_not_ip") from exc
        if test_ip.is_loopback:
            log(f"BRIDGE_A2A_ALLOW_TEST_BIND=1 — binding loopback {bind} (test mode)")
            return bind, port
    try:
        ip = ipaddress.ip_address(bind)
    except ValueError as exc:
        raise a2a.A2AError(f"listen.address {bind!r} is not an IP: {exc}",
                           code="bind_not_ip") from exc
    if ip.is_loopback:
        raise a2a.A2AError(
            f"refusing to bind to loopback {bind!r} — A2A must be reachable "
            "by tailnet peers.",
            code="bind_loopback",
        )

    # Fail closed: the bind address MUST be proven to be in this node's
    # actual local Tailscale address set. tailscale_addresses() raises
    # TailscaleUnavailable (a subclass of A2AError) if the local set
    # cannot be determined — that propagates and the daemon refuses to
    # serve. There is no CIDR-shape fallback.
    allowed = tailscale_addresses()
    if not is_tailnet_address(bind, allowed):
        raise a2a.A2AError(
            f"listen.address {bind!r} is not in this node's Tailscale "
            f"address set ({allowed or 'empty'}). Refusing to start "
            "(fail-closed).",
            code="bind_not_tailnet",
        )
    return bind, port


# --------------------------------------------------------------------------
# Self-heal reconcile (P-self-heal phase 1, #1403)
# --------------------------------------------------------------------------
#
# A running receiver caches its config + binds its socket at startup. Two
# things then go stale until a manual restart:
#   1. The LOCAL node's Tailscale IP changes (after a tailnet re-login) →
#      the socket is stranded on the dead IP. This is the 2026-05-30 incident
#      (100.76.208.4 → 100.83.90.26): inbound from the peer kept getting
#      rejected until a manual `bridge-handoff-daemon.sh restart`.
#   2. A config edit (added/removed peer, allowlist/caps change, identity
#      migration) is not seen by the daemon, which cached the config at boot.
#
# The reconcile closes both, FAIL-CLOSED:
#   - Re-load + validate the config; on ANY error keep the last-good config
#     (never drop the allowlist / peer table to a half-parsed value).
#   - Re-resolve + RE-PROVE the bind through the UNCHANGED resolve_bind()
#     proof (candidate ∈ `tailscale ip` set; refuse wildcard/loopback;
#     refuse if Tailscale unavailable). If the proven bind changed, signal a
#     rebind; the serve loop tears down the old socket and re-creates the
#     listener on the NEW (already-proven) address. A rebind that fails to
#     bind keeps the current (proven) listener.
#
# The rebind goes through the SAME fail-closed proof as startup — there is
# no path here that binds an address not proven in `tailscale ip`'s set, and
# a reconcile failure always falls back to "keep serving on the current
# proven bind", never to an unproven one.


class ReconcileResult:
    """Outcome of one reconcile pass — for logging + the manual CLI."""

    def __init__(self) -> None:
        self.config_reloaded = False
        self.config_error: str = ""
        self.want_rebind = False
        self.old_bind: str = ""
        self.old_port: int = 0
        self.new_bind: str = ""
        self.new_port: int = 0
        self.bind_error: str = ""

    def summary(self) -> str:
        parts: list[str] = []
        if self.config_reloaded:
            parts.append("config=reloaded")
        elif self.config_error:
            parts.append(f"config=kept-last-good({self.config_error})")
        else:
            parts.append("config=unchanged")
        if self.want_rebind:
            parts.append(
                f"rebind old={self.old_bind}:{self.old_port} "
                f"new={self.new_bind}:{self.new_port}")
        elif self.bind_error:
            parts.append(
                f"bind=kept-current({self.bind_error}) "
                f"current={self.old_bind}:{self.old_port}")
        else:
            parts.append(f"bind=unchanged({self.old_bind}:{self.old_port})")
        return " ".join(parts)

    def changed(self) -> bool:
        return self.config_reloaded or self.want_rebind


def reconcile_once(server: "HandoffServer",
                   config_path: Optional[Path]) -> ReconcileResult:
    """Run one self-heal reconcile decision against a live `server`.

    This is a PURE decision step — it does NOT itself swap the socket (that
    must happen in the serve loop, which owns serve_forever). It:
      1. Re-loads + validates the config; on success the validated config is
         published to the handlers via server.swap_cfg (hot-reload). On any
         failure the last-good config is kept (fail-closed) and the error is
         recorded + audited.
      2. Re-resolves + RE-PROVES the bind via resolve_bind(); if the proven
         bind differs from the live socket's address, sets want_rebind +
         new_bind/new_port. On any proof failure (Tailscale unavailable,
         candidate not in the tailnet set, …) it keeps the current bind and
         records the error — NEVER an unproven address.

    Never raises for an operational failure; the daemon keeps serving.
    """
    result = ReconcileResult()
    result.old_bind = server.bound_address
    result.old_port = server.bound_port

    # --- 1. config hot-reload (fail-closed) ---
    new_cfg: Optional[dict[str, Any]] = None
    try:
        candidate = a2a.load_config(config_path)
        # Re-run the SAME startup secret gate: a reload that introduces an
        # unprovisioned peer must NOT silently disarm HMAC. Keep last-good.
        a2a.validate_config_peer_secrets(candidate, side="receiver")
        new_cfg = candidate
    except a2a.A2AError as exc:
        result.config_error = exc.code
        audit("reconcile_config_kept", code=exc.code, detail=str(exc)[:200],
              security=True)

    # --- 2. re-resolve + RE-PROVE the bind (fail-closed) ---
    # Use the freshly-validated config when available, else the live one (so a
    # bad config reload never blocks the bind self-heal from re-proving the
    # bind against the last-good config).
    proof_cfg = new_cfg if new_cfg is not None else server.cfg
    try:
        proven_bind, proven_port = resolve_bind(proof_cfg)
        result.new_bind = proven_bind
        result.new_port = proven_port
        if proven_bind != server.bound_address or proven_port != server.bound_port:
            result.want_rebind = True
    except a2a.A2AError as exc:
        # Bind could not be re-proven (Tailscale unavailable, resolved
        # candidate not in `tailscale ip`, …) → KEEP the current already-proven
        # bind. We never bind to an address that did not pass the proof.
        result.bind_error = exc.code
        result.new_bind = server.bound_address
        result.new_port = server.bound_port
        audit("reconcile_bind_kept", code=exc.code, detail=str(exc)[:200],
              current_bind=server.bound_address, security=True)

    # --- 3. publish the validated config LAST ---
    # Done after the bind decision so both used a consistent snapshot. Only
    # swap when the reload succeeded; a malformed reload keeps last-good.
    if new_cfg is not None:
        server.swap_cfg(new_cfg)
        result.config_reloaded = True

    return result


# --------------------------------------------------------------------------
# peer-identity-update apply (P-self-heal-3, design §9.6)
# --------------------------------------------------------------------------
#
# THE most security-sensitive A2A surface: it MUTATES the receiver's stored
# peer identity/address in handoff.local.json in response to UNTRUSTED
# remote traffic. The hard rule is: NEVER trust the wire-asserted IP /
# identity. The control message only PROMPTS a re-resolution the receiver
# independently verifies against its OWN `tailscale status --json` view.
#
# By the time these helpers run, do_POST has ALREADY enforced, in order:
#   a. tailnet-only bind (guaranteed at startup),
#   b. remote_addr == the authenticated sender peer's CURRENT resolved
#      Tailscale IP (resolve_peer_address on the configured peer), BEFORE
#      the body was read,
#   c. HMAC signature verify against that peer's secret(s) (401 on bad sig),
#   d. message_id durable dedupe (replay-safe),
#   e. clock-skew window,
#   f. peer is ALREADY PAIRED (find_peer succeeded; unknown -> 403),
#      with a matching secret.
# The remaining job here is the CRITICAL corroboration (g) + the scoped,
# idempotent, 0600-atomic apply (h) that touches ONLY this peer's identity.


class CorroborationResult:
    """Outcome of corroborating an identity-update claim against the receiver's
    OWN `tailscale status --json` view (never the wire-asserted values)."""

    def __init__(self) -> None:
        self.ok = False
        self.code = ""
        # The receiver-VERIFIED identity to record (from the receiver's own
        # status doc — NOT copied from the wire). node_id is the StableID,
        # name the MagicDNS/HostName, ip the live TailscaleIP.
        self.node_id = ""
        self.name = ""
        self.ip = ""


def _identity_update_corroborate(
    claim: dict[str, Any], peer: dict[str, Any],
) -> CorroborationResult:
    """Corroborate the sender's identity claim against THIS receiver's own
    Tailscale view. Returns CorroborationResult(ok=True, ...) only when the
    receiver's own `tailscale status --json` independently agrees the sender
    peer's node now has the claimed identity; otherwise ok=False + a code.

    NEVER trusts the wire. The wire claim only selects WHICH node to look up
    in the receiver's own status doc (by StableID first, then MagicDNS /
    HostName). The recorded node_id / name / ip are read from the receiver's
    OWN status node, not copied from the message.

    Additional anchor: the resolved node MUST be the SAME node the receiver
    already has paired for this peer (when the peer is already identity-keyed,
    the resolved StableID must equal the stored node_id; when the peer still
    carries a raw `address`, the resolved node must own that stored address).
    This stops a valid-signature peer from re-pointing its OWN entry at a
    DIFFERENT tailnet node it does not control. A peer with neither a stored
    identity nor a resolvable stored address (pure id-only, never migrated)
    is corroborated on the receiver's status match alone — it is already
    paired (find_peer + secret), and the receiver's own view is the anchor.
    """
    result = CorroborationResult()

    claimed_node_id = str(claim.get("node_id", "")).strip()
    claimed_name = str(claim.get("tailscale_name", "")).strip()

    # Read the receiver's OWN tailnet view. Fail closed on any query error.
    try:
        status = a2a.tailscale_status_json()
    except a2a.A2AError as exc:
        result.code = getattr(exc, "code", "tailscale_unavailable")
        return result

    nodes = a2a._status_nodes(status)

    # Locate the node the CLAIM refers to, but only inside the receiver's own
    # status doc — the claim is just a selector, never the source of truth.
    matched: Optional[dict[str, Any]] = None
    if claimed_node_id:
        for node in nodes:
            if str(node.get("ID", "")).strip() == claimed_node_id:
                matched = node
                break
    if matched is None and claimed_name:
        for node in nodes:
            if a2a._name_matches(node, claimed_name):
                matched = node
                break
    if matched is None:
        # The receiver's own view does NOT corroborate the claimed identity.
        result.code = "claim_not_in_status"
        return result

    verified_node_id = str(matched.get("ID", "")).strip()
    verified_name = a2a.node_name(matched)
    verified_ip = a2a._node_first_ip(matched) or ""
    if not verified_ip:
        result.code = "no_ip_for_node"
        return result

    # Same-node anchor: the corroborated node must be the SAME peer node the
    # receiver already has paired — a signed peer may only move its OWN
    # entry, never re-point it at a different node.
    stored_node_id = str(peer.get("node_id", "")).strip()
    stored_name = str(peer.get("tailscale_name", "")).strip()
    stored_address = str(peer.get("address", "")).strip()
    if stored_node_id:
        if verified_node_id != stored_node_id:
            result.code = "node_id_anchor_mismatch"
            return result
    elif stored_name:
        if not a2a._name_matches(matched, stored_name):
            result.code = "name_anchor_mismatch"
            return result
    elif stored_address:
        # Raw-IP peer not yet migrated: the corroborated node must currently
        # OWN the stored address (i.e. the IP has NOT moved to a different
        # node). If the stored IP no longer belongs to this node, refuse —
        # we will not blindly re-key an entry whose anchor we cannot verify.
        if not a2a._node_owns_ip(matched, stored_address):
            result.code = "address_anchor_mismatch"
            return result
    # else: pure id-only peer (no stored identity/address). It is already
    # paired (find_peer + secret); the receiver's own status match is the
    # anchor. Recording the receiver-verified identity strengthens it.

    result.ok = True
    result.node_id = verified_node_id
    result.name = verified_name
    result.ip = verified_ip
    return result


def _identity_update_apply(
    cfg_path: Optional[Path], peer_id: str, corr: CorroborationResult,
) -> tuple[bool, str]:
    """Update ONLY `peer_id`'s identity in handoff.local.json to the
    receiver-VERIFIED values, atomically at 0600. Idempotent (no-op write is
    skipped). Returns (changed, code). NEVER touches secret / secret_next /
    secrets / inbound_allowlist / caps / port / other peers / listen.

    Re-loads the on-disk config (not the live cached one) so the write is a
    minimal, race-narrow read-modify-write against the canonical file; the
    daemon's reconcile/hot-reload then picks up the change. Fail-closed: any
    load/validate/write error returns (False, code) and changes nothing.
    """
    try:
        disk_cfg = a2a.load_config(cfg_path)
    except a2a.A2AError as exc:
        return False, getattr(exc, "code", "config_load_failed")

    peers = disk_cfg.get("peers")
    if not isinstance(peers, list):
        return False, "config_shape"

    target: Optional[dict[str, Any]] = None
    for p in peers:
        if isinstance(p, dict) and p.get("id") == peer_id:
            target = p
            break
    if target is None:
        # The peer vanished from disk between the live lookup and now — do
        # NOT create it (this is not a discovery channel). No-op.
        return False, "peer_absent_on_disk"

    # Compute the desired identity fields from the receiver-verified values.
    new_node_id = corr.node_id
    new_name = corr.name
    cur_node_id = str(target.get("node_id", "")).strip()
    cur_name = str(target.get("tailscale_name", "")).strip()

    changed = False
    if new_node_id and cur_node_id != new_node_id:
        target["node_id"] = new_node_id
        changed = True
    if new_name and cur_name != new_name:
        target["tailscale_name"] = new_name
        changed = True
    # We do NOT write the resolved IP into a stored `address` — the whole
    # point of identity keying is that the IP is resolved live. We leave any
    # existing legacy `address` untouched (it stays a fallback). Idempotent:
    # if the entry is already identity-keyed to the verified node, no write.

    if not changed:
        return False, "noop"

    # Re-validate the secret gate on the about-to-be-written config so a
    # concurrent edit that dropped a secret cannot ride out on our write.
    try:
        a2a.validate_config_peer_secrets(disk_cfg, side="receiver")
    except a2a.A2AError as exc:
        return False, getattr(exc, "code", "secret_gate")

    cfg_file = cfg_path or a2a.config_path()
    try:
        orig_mode = cfg_file.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only
    except OSError:
        orig_mode = 0o600
    try:
        a2a.write_config_atomic(cfg_file, disk_cfg, orig_mode)
    except OSError as exc:
        return False, f"write_failed:{exc}"[:64]
    return True, "applied"


# --------------------------------------------------------------------------
# Room-scoped receiver check seam (A2A rooms — design §14 R2/R6)
# --------------------------------------------------------------------------
#
# This is the FROZEN fail-closed contract the cross-node room enforcement
# (P4) fills in. The signature `(env, cfg) -> (ok, reason)` is the binding
# seam — P2/P3/P4 add behavior WITHOUT changing it.
#
# P1a semantics (single-node + additive):
#   - NON-room-scoped message (no room_id) -> (True, "not_room_scoped"). This
#     is the unconditional no-op pass that keeps the existing enqueue path
#     byte-for-byte unchanged. The seam NEVER weakens the already-applied
#     HMAC / source-addr / allowlist / dedupe auth — it runs AFTER them and
#     can only ADD a deny for a room-scoped message.
#   - ROOM-scoped message -> the fail-closed membership decision against the
#     local rooms.db: the enqueue is allowed ONLY if BOTH the sender
#     (sender_agent@sender_node) AND the target (target_agent@<this_node>)
#     are current members of the room. Any of {rooms module unavailable,
#     rooms.db absent/unreadable, room unknown, either party not a member}
#     -> FAIL CLOSED (deny). Because P1a is single-node and the receiver only
#     ever handles cross-node traffic, no production message is room-scoped
#     yet — so this branch is wired + unit-tested but off the hot path. P4
#     replaces the raw membership read with a leader-MAC'd roster verify +
#     freshness (roster_max_age / epoch refresh) WITHOUT touching this
#     signature or the fail-closed default.

def room_scoped_check(env: dict[str, Any],
                      cfg: dict[str, Any]) -> tuple[bool, str]:
    """Frozen fail-closed room-membership seam. Returns (ok, reason).

    See the section header for the full contract. `cfg` is the loaded A2A
    config (carries this node's `bridge_id`); it is the authenticated peer
    config the caller already validated — the seam does NOT re-derive trust
    from it, it only reads the local node id.
    """
    if not a2a.envelope_is_room_scoped(env):
        return True, "not_room_scoped"

    room_id = str(env.get("room_id") or "")
    sender = env.get("sender", {})
    sender_agent = str(sender.get("agent") or "") if isinstance(sender, dict) else ""
    sender_node = str(sender.get("bridge") or "") if isinstance(sender, dict) else ""
    target_agent = str(env.get("target_agent") or "")
    this_node = str(cfg.get("bridge_id") or "")

    if rooms is None:
        return False, "rooms_module_unavailable"

    try:
        conn = rooms.open_rooms_readonly()
    except rooms.RoomsError:
        # Present-but-unreadable db is a real fault, not "no rooms" -> deny.
        return False, "rooms_db_unreadable"
    if conn is None:
        # No rooms.db at all: a room-scoped message cannot be validated -> deny.
        return False, "no_rooms_db"

    try:
        room = rooms.get_room(conn, room_id)
        if room is None:
            return False, "room_unknown"
        if not rooms.is_member(conn, room_id, sender_agent, sender_node):
            return False, "sender_not_member"
        if not rooms.is_member(conn, room_id, target_agent, this_node):
            return False, "target_not_member"
    finally:
        conn.close()
    return True, "members_ok"


# --------------------------------------------------------------------------
# Enqueue boundary — call the EXISTING bridge-task.sh create
# --------------------------------------------------------------------------

def enqueue_via_bridge_task(
    *,
    target: str,
    sender_bridge: str,
    sender_agent: str,
    priority: str,
    title: str,
    body_file: Path,
) -> tuple[bool, str, str]:
    """Invoke `bridge-task.sh create` as an argv array (never a shell string).

    Returns (ok, task_id, detail). On failure `detail` carries the stderr
    tail and `task_id` is empty.
    """
    script = Path(__file__).resolve().parent / "bridge-task.sh"
    bash = os.environ.get("BRIDGE_BASH_BIN", "bash")
    argv = [
        bash, str(script), "create",
        "--to", target,
        "--from", f"a2a:{sender_bridge}:{sender_agent}",
        "--priority", priority,
        "--title", title,
        "--body-file", str(body_file),
        # Issue #1398: durably queue inbound cross-bridge mail even when the
        # local target agent is momentarily stopped. An inbound A2A handoff is
        # durable mail — a transiently-stopped local target is a NORMAL state,
        # unlike an interactive operator send — so it must land in the queue
        # for when the agent restarts, not 422 under the #1318 stopped-target
        # reader guard. --force bypasses ONLY that liveness guard; it does NOT
        # relax companion validation, the allowlist, dedupe, or any auth check.
        "--force",
    ]
    # NOTE: --skip-companion-validate is deliberately NOT passed — remote
    # peers must not bypass companion-review validation. --force (above)
    # is the stopped-target liveness override ONLY; the auth/allowlist/dedupe
    # gates upstream of this enqueue stay fully enforced.
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=120,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        return False, "", f"bridge-task.sh invocation failed: {exc}"

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[-400:]
        return False, "", detail or f"bridge-task.sh exited {proc.returncode}"

    # Parse `created task #<id> for <agent> ...`.
    task_id = ""
    for token in (proc.stdout or "").split():
        if token.startswith("#") and token[1:].isdigit():
            task_id = token[1:]
            break
    return True, task_id, (proc.stdout or "").strip()


def staged_body_text(env: dict[str, Any]) -> str:
    """Build the local task body with a provenance block prepended."""
    sender = env.get("sender", {})
    reply = env.get("reply_to", {})
    header = [
        "<!-- A2A cross-bridge handoff — provenance -->",
        f"remote peer  : {sender.get('bridge', '?')}",
        f"remote agent : {sender.get('agent', '?')}",
        f"message id   : {env.get('message_id', '?')}",
        "",
        "Reply with:",
        f"  agent-bridge a2a send --peer {reply.get('peer', '?')} "
        f"--to {reply.get('agent', '?')} --title \"<re: ...>\" --body \"...\"",
        "",
        "---",
        "",
    ]
    return "\n".join(header) + env.get("body", "")


# --------------------------------------------------------------------------
# Request handling
# --------------------------------------------------------------------------

class HandoffServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, cfg: dict[str, Any]) -> None:
        super().__init__(addr, handler)
        # `cfg` is read per request by do_POST via `self.server.cfg`. The
        # reconcile path swaps it atomically (a single attribute rebind is
        # atomic under CPython, so an in-flight do_POST always sees either the
        # whole old config or the whole new one — never a half-applied table).
        # `_cfg_lock` guards only the validate-then-swap so a malformed reload
        # can never replace the live allowlist / caps with a half-parsed dict.
        self.cfg = cfg
        self._cfg_lock = threading.Lock()
        # The address/port this socket is actually bound to. The reconcile
        # compares the freshly-resolved+proven bind against this to detect a
        # local-IP drift; set from the real bound address by cmd_serve.
        self.bound_address: str = addr[0]
        self.bound_port: int = addr[1]
        # The config file path the peer-identity-update apply re-loads +
        # rewrites (None = the default resolution). Set by cmd_serve so the
        # control-message handler mutates the SAME file the daemon loaded.
        self.config_path: Optional[Path] = None

    def swap_cfg(self, new_cfg: dict[str, Any]) -> None:
        """Publish an ALREADY-VALIDATED config to the request handlers.

        The caller (reconcile_once) only reaches here after load_config +
        validate_config_peer_secrets succeed, so the live allowlist / caps /
        peer table is never replaced by a half-parsed or unprovisioned
        config. The swap itself is a single atomic attribute rebind.
        """
        with self._cfg_lock:
            self.cfg = new_cfg


class HandoffHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AgentBridgeHandoffd/1"

    # Silence the default stderr access log; we audit explicitly.
    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        return

    def _reply(self, status: int, payload: dict[str, Any],
               extra_headers: Optional[dict[str, str]] = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, val in (extra_headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else ""

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path == "/healthz":
            self._reply(200, {"ok": True, "service": "a2a-handoffd"})
            return
        self._reply(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        cfg: dict[str, Any] = self.server.cfg  # type: ignore[attr-defined]
        enqueue_path = cfg.get("listen", {}).get("enqueue_path", "/enqueue")
        # P-self-heal-3 (design §9.6): the signed peer-identity-update control
        # message is routed to a SEPARATE handler so it never reaches the
        # enqueue/allowlist/queue boundary. Both handlers share the same
        # fail-closed auth preamble (remote_addr -> HMAC -> dedupe -> skew),
        # but the control message's terminal action is a scoped config update,
        # not a queue insert.
        identity_update_path = cfg.get("listen", {}).get(
            "identity_update_path", a2a.IDENTITY_UPDATE_PATH)
        if self.path == identity_update_path:
            self._handle_identity_update(cfg)
            return
        # A2A Rooms P4.1 (design §11 / §14 R3): the signed cross-node
        # room-join-request is ALSO routed to a SEPARATE handler with the same
        # fail-closed auth preamble (remote_addr -> HMAC -> skew -> dedupe). Its
        # terminal action is a token-verified PENDING join row — it NEVER reaches
        # the enqueue/allowlist/queue boundary, creates no leader task, and
        # admits nothing (approve is P4.2).
        room_join_path = cfg.get("listen", {}).get(
            "room_join_path", a2a.ROOM_JOIN_PATH)
        if self.path == room_join_path:
            self._handle_room_join_request(cfg)
            return
        # A2A Rooms P4.2 (design §6 / §14 R2): the leader-signed roster broadcast
        # is ALSO routed to a SEPARATE handler with the SAME fail-closed auth
        # preamble (remote_addr -> HMAC -> skew -> dedupe). Its terminal action
        # is a member-local room_roster_cache write — it NEVER reaches the
        # enqueue/allowlist/queue boundary, creates no task, and admits nothing.
        room_roster_path = cfg.get("listen", {}).get(
            "room_roster_path", a2a.ROOM_ROSTER_PATH)
        if self.path == room_roster_path:
            self._handle_room_roster_broadcast(cfg)
            return
        if self.path != enqueue_path:
            self._reply(404, {"ok": False, "error": "not found"})
            return

        client_ip = self._client_ip()
        peer_id = self.headers.get("X-AGB-Peer", "")
        message_id = self.headers.get("X-AGB-Message-Id", "")
        timestamp = self.headers.get("X-AGB-Timestamp", "")
        body_hash_hdr = self.headers.get("X-AGB-Body-SHA256", "")
        signature = self.headers.get("X-AGB-Signature", "")
        protocol = self.headers.get("X-AGB-Protocol", "")

        if protocol != a2a.PROTOCOL_VERSION:
            audit("reject_protocol", peer=peer_id, client=client_ip, got=protocol)
            self._reply(400, {"ok": False, "error": "unsupported protocol"})
            return

        # --- peer must be configured ---
        try:
            peer = a2a.find_peer(cfg, peer_id)
        except a2a.A2AError:
            audit("reject_unknown_peer", peer=peer_id, client=client_ip)
            self._reply(403, {"ok": False, "error": "unknown peer"})
            return

        # --- remote_addr == authenticated peer's CURRENT address (before body) ---
        # Resolve the configured SENDER peer (the authenticated X-AGB-Peer we
        # just looked up) to its live Tailscale IP rather than trusting a
        # literal/stale `address`. A peer keyed on `node_id`/`tailscale_name`
        # would otherwise be rejected here as a source-address mismatch even
        # though the sender delivered correctly — and, worse, a stale stored
        # `address` would remain the inbound auth anchor (the very class P0
        # exists to close). FAIL CLOSED: any resolver / TailscaleUnavailable
        # error rejects the request (we never fall through to accept) and the
        # check stays BEFORE the body is read off the socket.
        try:
            peer_addr = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            audit("reject_addr_unresolved", peer=peer_id, client=client_ip,
                  reason=getattr(exc, "code", "resolve_error"), security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return
        if not peer_addr or client_ip != peer_addr:
            audit("reject_addr_mismatch", peer=peer_id, client=client_ip,
                  expected=peer_addr, security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return

        # --- size guard before reading the body ---
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = -1
        if content_length < 0:
            self._reply(411, {"ok": False, "error": "length required"})
            return
        max_body = int(a2a.peer_cap(peer, "max_body_bytes", a2a.DEFAULT_MAX_BODY_BYTES))
        if content_length > min(ABSOLUTE_MAX_REQUEST_BYTES, max_body):
            audit("reject_oversize", peer=peer_id, client=client_ip,
                  declared=content_length, cap=max_body)
            self._reply(413, {"ok": False, "error": "body too large"})
            return

        raw = self.rfile.read(content_length) if content_length else b""

        # --- HMAC + timestamp before parsing ---
        secrets = a2a.peer_secrets(peer)
        if not secrets:
            audit("reject_no_secret", peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "peer not provisioned"})
            return

        computed_hash = a2a.body_sha256(raw)
        if body_hash_hdr != computed_hash:
            audit("reject_body_hash", peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "body hash mismatch"})
            return

        # #1346 (PR r2): HMAC verification is the auth boundary and MUST run
        # BEFORE any timestamp-band classification. Verifying timestamp first
        # leaks an unauthenticated "transient vs permanent" 503/401 split to
        # any caller — an attacker who supplies a bad signature with a
        # drift-band timestamp would receive 503 (retryable) instead of the
        # 401 their unauthenticated request deserves. That is auth fail-open:
        # the receiver classifies forged traffic as "retry later" instead of
        # rejecting it outright. By verifying the HMAC first we collapse all
        # unauthenticated responses to 401 regardless of timestamp value, and
        # only authenticated requests reach the drift / replay-window
        # classification below. `verify_signature` uses `hmac.compare_digest`
        # internally so this remains a constant-time comparison even with
        # the new placement (Sean directive: don't leak signature validity
        # via early-return timing).
        canonical = a2a.canonical_string(
            "POST", self.path, peer_id, message_id, timestamp, computed_hash)
        if not a2a.verify_signature(secrets, canonical, signature):
            audit("reject_bad_signature", peer=peer_id, client=client_ip,
                  message_id=message_id, security=True)
            self._reply(401, {"ok": False, "error": "signature verification failed"})
            return

        # Signature is authentic past this point. Now classify the
        # timestamp delta — drift band returns 503 (sender retries after
        # clock-sync), beyond grace returns 401 (replay defense).
        skew = int(cfg.get("timestamp_skew_seconds", a2a.DEFAULT_TIMESTAMP_SKEW_SECONDS))
        # #1326: timestamps inside (skew, grace_skew] are treated as
        # transient clock drift (503 + Retry-After). Beyond grace_skew the
        # request is too old to be drift and is rejected as a permanent
        # 401 (likely replay of a stale captured payload). The grace
        # ceiling is configurable; the default is a conservative 1 hour
        # which is wide enough to absorb DST / NTP step-corrections without
        # accepting indefinitely-stale captures.
        grace_skew = int(cfg.get(
            "timestamp_skew_grace_seconds",
            a2a.DEFAULT_TIMESTAMP_SKEW_GRACE_SECONDS,
        ))
        # Enforce a sane floor: grace cannot be less than skew (otherwise
        # the transient band would be empty).
        if grace_skew < skew:
            grace_skew = skew
        receiver_now = a2a.now_ts()
        try:
            req_ts = int(timestamp)
        except (TypeError, ValueError):
            # A signed-but-unparseable timestamp is a protocol violation by
            # the sender. Permanent 401 — clients should not retry blindly.
            audit("reject_bad_timestamp", peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "bad timestamp"})
            return
        ts_delta = abs(receiver_now - req_ts)
        if ts_delta > grace_skew:
            # Too old to be clock drift — keep edge-case 1 closed: a
            # malicious replay of a long-stale capture still maps to 401
            # (permanent, dead-letter on sender). The audit row records
            # the security=True flag for SIEM filters.
            audit("reject_clock_skew_permanent",
                  peer=peer_id, client=client_ip,
                  request_ts=req_ts, receiver_ts=receiver_now,
                  skew_limit=skew, grace_skew=grace_skew,
                  delta_seconds=ts_delta, security=True)
            self._reply(401, {"ok": False,
                              "error": ("timestamp far outside skew window — "
                                        "rejected as permanent (possible "
                                        "stale capture / replay)"),
                              "receiver_ts": receiver_now,
                              "skew_limit_seconds": skew,
                              "grace_skew_seconds": grace_skew})
            return
        if ts_delta > skew:
            # Narrow drift band: 503 transient so the sender retries
            # after clock-sync rather than dead-lettering.
            audit("reject_clock_skew_transient",
                  peer=peer_id, client=client_ip,
                  request_ts=req_ts, receiver_ts=receiver_now,
                  skew_limit=skew, grace_skew=grace_skew,
                  delta_seconds=ts_delta)
            self._reply(
                503,
                {"ok": False,
                 "error": ("timestamp outside skew window — retry after "
                           "clock-sync (receiver_ts gives current server "
                           "time)"),
                 "receiver_ts": receiver_now,
                 "skew_limit_seconds": skew,
                 "grace_skew_seconds": grace_skew},
                # Retry-After matches the configured skew so the sender
                # waits at least that long before the next attempt — by
                # then the operator has either NTP-synced or the drift
                # has stayed put and the next attempt will still 503.
                extra_headers={"Retry-After": str(max(1, skew))},
            )
            return

        # --- parse envelope ---
        try:
            env = a2a.parse_envelope(raw)
        except a2a.A2AError as exc:
            audit("reject_envelope", peer=peer_id, client=client_ip,
                  code=exc.code, message_id=message_id)
            self._reply(422, {"ok": False, "error": str(exc)})
            return

        if env.get("message_id") != message_id:
            audit("reject_id_mismatch", peer=peer_id, client=client_ip,
                  header_id=message_id, envelope_id=env.get("message_id"),
                  security=True)
            self._reply(422, {"ok": False, "error": "message id header/body mismatch"})
            return

        # The envelope's declared sender bridge must match the
        # authenticated peer identity (the signed X-AGB-Peer header).
        # Without this an otherwise valid signed request could carry a
        # spoofed `sender.bridge` in the provenance block.
        env_sender_bridge = env.get("sender", {}).get("bridge", "")
        if env_sender_bridge != peer_id:
            audit("reject_sender_mismatch", peer=peer_id, client=client_ip,
                  envelope_sender=env_sender_bridge, message_id=message_id,
                  security=True)
            self._reply(422, {"ok": False,
                              "error": "envelope sender bridge does not match "
                                       "authenticated peer"})
            return

        target = env["target_agent"]
        title = env["title"]
        priority = env.get("priority", "normal")

        # --- allowlist: exact (peer, target) match, no wildcard default ---
        allowlist = peer.get("inbound_allowlist", [])
        if not isinstance(allowlist, list) or target not in allowlist:
            audit("reject_allowlist", peer=peer_id, client=client_ip,
                  target=target, message_id=message_id, security=True)
            self._reply(403, {"ok": False,
                              "error": f"target '{target}' not in allowlist for peer"})
            return

        # NOTE: the room-scoped membership check (A2A rooms, design §14 R2)
        # runs INSIDE _handle_dedupe_and_enqueue, AFTER the durable dedupe
        # duplicate/hash-conflict handling and BEFORE staging/enqueue — so a
        # room-scoped idempotent retry still resolves to its original task id
        # and a hash-conflict is still recorded as the 409 security event,
        # rather than being masked by a membership 403. It only gates a NEW
        # room-scoped enqueue. See _handle_dedupe_and_enqueue.

        # --- title size cap ---
        max_title = int(a2a.peer_cap(peer, "max_title_bytes", a2a.DEFAULT_MAX_TITLE_BYTES))
        if len(title.encode("utf-8")) > max_title:
            audit("reject_title_size", peer=peer_id, client=client_ip,
                  message_id=message_id)
            self._reply(413, {"ok": False, "error": "title too large"})
            return

        # --- durable dedupe ---
        try:
            self._handle_dedupe_and_enqueue(cfg, peer, env, computed_hash, client_ip)
        except Exception as exc:  # noqa: BLE001 - last-resort guard
            audit("error_internal", peer=peer_id, client=client_ip,
                  message_id=message_id, detail=str(exc)[:300])
            self._reply(500, {"ok": False, "error": "internal error"})

    def _handle_dedupe_and_enqueue(
        self, cfg: dict[str, Any], peer: dict[str, Any],
        env: dict[str, Any], body_hash: str, client_ip: str,
    ) -> None:
        message_id = env["message_id"]
        peer_id = peer.get("id", "")
        a2a.ensure_handoff_dirs()
        conn = a2a.open_inbox()
        try:
            existing = conn.execute(
                "SELECT body_sha256, created_task_id FROM inbox_dedupe "
                "WHERE message_id=?", (message_id,)
            ).fetchone()
            if existing is not None:
                if existing["body_sha256"] == body_hash:
                    # Same id + same body → idempotent success.
                    conn.execute(
                        "UPDATE inbox_dedupe SET last_seen_ts=?, "
                        "delivery_count=delivery_count+1 WHERE message_id=?",
                        (a2a.now_ts(), message_id),
                    )
                    conn.commit()
                    audit("accept_duplicate", peer=peer_id, client=client_ip,
                          message_id=message_id,
                          task_id=existing["created_task_id"])
                    self._reply(200, {"ok": True, "duplicate": True,
                                      "task_id": existing["created_task_id"]})
                    return
                # Same id + different body → security event, conflict.
                conn.execute(
                    "UPDATE inbox_dedupe SET last_seen_ts=?, "
                    "delivery_count=delivery_count+1 WHERE message_id=?",
                    (a2a.now_ts(), message_id),
                )
                conn.commit()
                audit("reject_hash_conflict", peer=peer_id, client=client_ip,
                      message_id=message_id, security=True)
                self._reply(409, {"ok": False,
                                  "error": "message id reused with different body"})
                return

            # --- room-scoped membership (A2A rooms, design §14 R2 — FAIL CLOSED) ---
            # Runs AFTER the existing HMAC/source-addr/allowlist auth AND after
            # the durable dedupe duplicate/hash-conflict handling above (so an
            # idempotent room-scoped retry already returned its original task
            # id, and a hash-conflict already 409'd) — it gates ONLY a NEW
            # room-scoped enqueue, and can only ADD a denial, never relax a
            # non-room message. P1a is single-node so production traffic is not
            # room-scoped yet; this is the frozen seam P4 activates on the
            # cross-node path with the leader-MAC'd roster verify.
            room_ok, room_reason = room_scoped_check(env, cfg)
            if not room_ok:
                audit("reject_room_membership", peer=peer_id, client=client_ip,
                      target=env.get("target_agent"), room_id=env.get("room_id"),
                      reason=room_reason, message_id=message_id, security=True)
                self._reply(403, {"ok": False,
                                  "error": f"room-scoped enqueue denied: {room_reason}"})
                return

            # --- backpressure: max open remote tasks per peer/target ---
            max_open = a2a.peer_cap(peer, "max_open_tasks", None)
            if max_open is not None:
                open_count = conn.execute(
                    "SELECT COUNT(*) AS n FROM inbox_dedupe WHERE peer=? "
                    "AND created_task_id IS NOT NULL", (peer_id,)
                ).fetchone()["n"]
                if int(open_count) >= int(max_open):
                    audit("reject_backpressure", peer=peer_id, client=client_ip,
                          message_id=message_id, open=open_count)
                    self._reply(429, {"ok": False, "error": "peer task quota reached"},
                                extra_headers={"Retry-After": "120"})
                    return

            # --- stage body + enqueue via bridge-task.sh ---
            staged = a2a.incoming_dir() / f"{message_id.replace(':', '_').replace('/', '_')}.md"
            staged.write_text(staged_body_text(env), encoding="utf-8")
            try:
                os.chmod(staged, 0o600)
            except OSError:
                pass

            sender = env.get("sender", {})
            ok, task_id, detail = enqueue_via_bridge_task(
                target=env["target_agent"],
                sender_bridge=sender.get("bridge", "unknown"),
                sender_agent=sender.get("agent", "unknown"),
                priority=env.get("priority", "normal"),
                title=env["title"],
                body_file=staged,
            )
            if not ok:
                # Distinguish a transient lock failure (retryable 503) from
                # a permanent validation/guard/allowlist rejection (422).
                lowered = detail.lower()
                transient = any(s in lowered for s in
                                ("locked", "database is locked", "timeout",
                                 "temporarily"))
                if transient:
                    audit("enqueue_transient_fail", peer=peer_id,
                          message_id=message_id, detail=detail[:200])
                    self._reply(503, {"ok": False, "error": "queue busy, retry"},
                                extra_headers={"Retry-After": "30"})
                else:
                    audit("enqueue_permanent_fail", peer=peer_id,
                          message_id=message_id, detail=detail[:200])
                    self._reply(422, {"ok": False,
                                      "error": f"enqueue rejected: {detail[:200]}"})
                return

            now = a2a.now_ts()
            conn.execute(
                "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
                "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
                "VALUES (?, ?, ?, ?, ?, ?, 1)",
                (message_id, peer_id, body_hash, task_id, now, now),
            )
            conn.commit()
            audit("accept", peer=peer_id, client=client_ip,
                  message_id=message_id, target=env["target_agent"],
                  task_id=task_id)
            self._reply(200, {"ok": True, "duplicate": False, "task_id": task_id})
        finally:
            conn.close()

    def _handle_identity_update(self, cfg: dict[str, Any]) -> None:
        """Receiver branch for the signed peer-identity-update control message
        (P-self-heal-3, design §9.6).

        Fail-closed validation ORDER (mirrors do_POST; security=True audit on
        every reject; NO mutation until ALL pass):
          a. tailnet-only bind — guaranteed at startup (resolve_bind).
          b. remote_addr == the authenticated sender peer's CURRENT resolved
             Tailscale IP — checked BEFORE the body is read off the socket.
          c. HMAC signature verify against that peer's secret(s) — 401 on
             mismatch (body hash + signature, constant-time).
          d. message_id durable dedupe — replay-safe (idempotent re-apply).
          e. clock-skew window — transient drift 503, far-stale 401.
          f. peer ALREADY PAIRED — find_peer succeeded above; an unknown /
             unpaired peer was already 403'd. NOT a discovery channel.
          g. CRITICAL corroboration — the claimed (StableID / MagicDNS / IP)
             MUST match what THIS receiver sees in its OWN
             `tailscale status --json` for that peer's node, AND must resolve
             to the SAME node the receiver already has paired. NEVER trust the
             wire-asserted IP/identity; if the receiver's own status does not
             corroborate -> REJECT (fail-closed), no mutation.
          h. apply — update ONLY this peer's identity/address in
             handoff.local.json via the 0600-atomic write; NEVER touch
             secret/allowlist/caps/other peers; idempotent; then hot-reload
             (swap_cfg) so it takes effect with no restart.
        """
        client_ip = self._client_ip()
        peer_id = self.headers.get("X-AGB-Peer", "")
        message_id = self.headers.get("X-AGB-Message-Id", "")
        timestamp = self.headers.get("X-AGB-Timestamp", "")
        body_hash_hdr = self.headers.get("X-AGB-Body-SHA256", "")
        signature = self.headers.get("X-AGB-Signature", "")
        protocol = self.headers.get("X-AGB-Protocol", "")

        if protocol != a2a.IDENTITY_UPDATE_PROTOCOL_VERSION:
            audit("identity_update_reject", reason="bad_protocol",
                  peer=peer_id, client=client_ip, got=protocol)
            self._reply(400, {"ok": False, "error": "unsupported protocol"})
            return

        # --- message_id REQUIRED (non-empty) for this endpoint ---
        # A non-empty message_id is mandatory: it anchors durable dedupe (d)
        # AND is part of the signed canonical string. An empty id would skip
        # dedupe entirely and previously let the bridge_id corroboration be
        # bypassed (#1406 codex r1 SECURITY). Reject BEFORE any body read or
        # mutation; fail-closed.
        if not message_id:
            audit("identity_update_reject", reason="missing_message_id",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(400, {"ok": False, "error": "message id required"})
            return

        # --- f. peer must be ALREADY PAIRED (not a discovery channel) ---
        try:
            peer = a2a.find_peer(cfg, peer_id)
        except a2a.A2AError:
            audit("identity_update_reject", reason="unknown_peer",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "unknown peer"})
            return

        # --- b. remote_addr == authenticated peer's CURRENT address (before body) ---
        # Resolve the SENDER peer to its live Tailscale IP rather than trusting
        # a stale stored `address`. FAIL CLOSED: any resolver / Tailscale error
        # rejects BEFORE the body is read. (Identical anchor to do_POST.)
        try:
            peer_addr = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            audit("identity_update_reject", reason=getattr(exc, "code",
                  "resolve_error"), peer=peer_id, client=client_ip,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return
        if not peer_addr or client_ip != peer_addr:
            audit("identity_update_reject", reason="addr_mismatch",
                  peer=peer_id, client=client_ip, expected=peer_addr,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return

        # --- size guard before reading the body ---
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = -1
        if content_length < 0:
            self._reply(411, {"ok": False, "error": "length required"})
            return
        # The control body is tiny; cap it tightly (independent of the
        # per-peer enqueue body cap) so an oversized payload is refused early.
        max_body = 8 * 1024
        if content_length > max_body:
            audit("identity_update_reject", reason="oversize",
                  peer=peer_id, client=client_ip, declared=content_length)
            self._reply(413, {"ok": False, "error": "body too large"})
            return
        raw = self.rfile.read(content_length) if content_length else b""

        # --- c. HMAC: secret present, body hash, signature (auth boundary) ---
        secrets = a2a.peer_secrets(peer)
        if not secrets:
            audit("identity_update_reject", reason="no_secret",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "peer not provisioned"})
            return
        computed_hash = a2a.body_sha256(raw)
        if body_hash_hdr != computed_hash:
            audit("identity_update_reject", reason="body_hash",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "body hash mismatch"})
            return
        # HMAC FIRST (before any timestamp-band classification) so an
        # unauthenticated request never receives a transient/permanent split
        # that leaks signature validity (same ordering rationale as do_POST,
        # #1346). The path is part of the canonical string, so an enqueue
        # signature cannot be replayed against this control endpoint.
        canonical = a2a.canonical_string(
            "POST", self.path, peer_id, message_id, timestamp, computed_hash)
        if not a2a.verify_signature(secrets, canonical, signature):
            audit("identity_update_reject", reason="bad_signature",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(401, {"ok": False, "error": "signature verification failed"})
            return

        # --- e. clock-skew window (authenticated past this point) ---
        skew = int(cfg.get("timestamp_skew_seconds",
                           a2a.DEFAULT_TIMESTAMP_SKEW_SECONDS))
        grace_skew = int(cfg.get("timestamp_skew_grace_seconds",
                                 a2a.DEFAULT_TIMESTAMP_SKEW_GRACE_SECONDS))
        if grace_skew < skew:
            grace_skew = skew
        receiver_now = a2a.now_ts()
        try:
            req_ts = int(timestamp)
        except (TypeError, ValueError):
            audit("identity_update_reject", reason="bad_timestamp",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "bad timestamp"})
            return
        ts_delta = abs(receiver_now - req_ts)
        if ts_delta > grace_skew:
            audit("identity_update_reject", reason="clock_skew_permanent",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta,
                  security=True)
            self._reply(401, {"ok": False,
                              "error": "timestamp far outside skew window",
                              "receiver_ts": receiver_now})
            return
        if ts_delta > skew:
            audit("identity_update_reject", reason="clock_skew_transient",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta)
            self._reply(503, {"ok": False,
                              "error": "timestamp outside skew window — retry",
                              "receiver_ts": receiver_now},
                        extra_headers={"Retry-After": str(max(1, skew))})
            return

        # --- parse the control body (shape only; never trusts identity) ---
        try:
            claim = a2a.parse_identity_update(raw)
        except a2a.A2AError as exc:
            audit("identity_update_reject", reason=getattr(exc, "code",
                  "bad_identity_update"), peer=peer_id, client=client_ip,
                  message_id=message_id)
            self._reply(422, {"ok": False, "error": str(exc)})
            return
        if claim.get("bridge_id") != peer_id:
            # The claimed bridge_id must match the authenticated peer (the
            # signed X-AGB-Peer). A peer may only announce about ITSELF.
            # UNCONDITIONAL: message_id is guaranteed non-empty above, but this
            # corroboration check must NEVER be skipped regardless (#1406 codex
            # r1 SECURITY — empty-id no longer reaches here, and the body
            # bridge_id can never bypass the authenticated-peer match).
            audit("identity_update_reject", reason="bridge_id_mismatch",
                  peer=peer_id, client=client_ip,
                  claimed=claim.get("bridge_id"), security=True)
            self._reply(422, {"ok": False,
                              "error": "bridge_id does not match authenticated peer"})
            return

        # --- d. durable dedupe (replay-safe; idempotent re-apply) ---
        # Reuse the same inbox_dedupe ledger as the enqueue path. The body
        # hash anchors idempotency: same id + same body -> idempotent 200;
        # same id + different body -> 409 security event (id reuse).
        try:
            dup = self._identity_update_dedupe_gate(
                peer_id, message_id, computed_hash, client_ip)
        except Exception as exc:  # noqa: BLE001 - last-resort guard
            audit("identity_update_error", reason="dedupe_error",
                  peer=peer_id, client=client_ip, detail=str(exc)[:200])
            self._reply(500, {"ok": False, "error": "internal error"})
            return
        if dup == "duplicate":
            audit("identity_update_accept", reason="duplicate",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(200, {"ok": True, "duplicate": True})
            return
        if dup == "conflict":
            audit("identity_update_reject", reason="hash_conflict",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(409, {"ok": False,
                              "error": "message id reused with different body"})
            return

        # --- g. CRITICAL: corroborate against the receiver's OWN tailnet view ---
        corr = _identity_update_corroborate(claim, peer)
        if not corr.ok:
            # The receiver's own `tailscale status --json` does NOT
            # independently agree — REJECT, fail-closed, NO mutation. This is
            # the anti-spoof gate: a valid-signature peer cannot move its
            # entry to an IP/node the receiver's own view does not confirm.
            audit("identity_update_reject", reason=corr.code or "corroboration_failed",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(409, {"ok": False,
                              "error": ("identity not corroborated by this "
                                        "receiver's own tailscale status")})
            return

        # --- h. scoped, idempotent, 0600-atomic apply + hot-reload ---
        config_path = self.server.config_path  # type: ignore[attr-defined]
        changed, code = _identity_update_apply(config_path, peer_id, corr)
        if code.startswith("write_failed") or code in (
                "config_load_failed", "config_shape", "secret_gate"):
            audit("identity_update_error", reason=code, peer=peer_id,
                  client=client_ip, message_id=message_id, security=True)
            self._reply(500, {"ok": False, "error": "apply failed"})
            return

        # Hot-reload the live config so the new identity takes effect with no
        # restart (mirrors the reconcile config swap). Re-validate before the
        # swap so a concurrent bad edit can never disarm the live allowlist.
        if changed:
            try:
                fresh = a2a.load_config(config_path)
                a2a.validate_config_peer_secrets(fresh, side="receiver")
                self.server.swap_cfg(fresh)  # type: ignore[attr-defined]
            except a2a.A2AError as exc:
                # The write succeeded but the reload failed validation — keep
                # the live (last-good) config; the periodic reconcile will
                # retry the hot-reload. Do NOT fail the request (the durable
                # apply landed).
                audit("identity_update_reload_kept",
                      reason=getattr(exc, "code", "reload_failed"),
                      peer=peer_id, client=client_ip, security=True)

        audit("identity_update_accept",
              reason="applied" if changed else "noop",
              peer=peer_id, client=client_ip, message_id=message_id,
              node_id=corr.node_id, resolved_ip=corr.ip)
        self._reply(200, {"ok": True, "applied": changed,
                          "node_id": corr.node_id})

    def _identity_update_dedupe_gate(
        self, peer_id: str, message_id: str, body_hash: str, client_ip: str,
    ) -> str:
        """Durable dedupe for the identity-update control message, sharing the
        inbox_dedupe ledger. Returns "new" | "duplicate" | "conflict".

        A "new" id is INSERTED here (created_task_id stays NULL — there is no
        local task for a control message) so a replay of the SAME signed
        message is idempotent even across daemon restarts. The body hash
        anchors idempotency: same id + same body -> duplicate; same id +
        different body -> conflict (security event).
        """
        a2a.ensure_handoff_dirs()
        conn = a2a.open_inbox()
        try:
            existing = conn.execute(
                "SELECT body_sha256 FROM inbox_dedupe WHERE message_id=?",
                (message_id,),
            ).fetchone()
            if existing is not None:
                if existing["body_sha256"] == body_hash:
                    conn.execute(
                        "UPDATE inbox_dedupe SET last_seen_ts=?, "
                        "delivery_count=delivery_count+1 WHERE message_id=?",
                        (a2a.now_ts(), message_id),
                    )
                    conn.commit()
                    return "duplicate"
                conn.execute(
                    "UPDATE inbox_dedupe SET last_seen_ts=?, "
                    "delivery_count=delivery_count+1 WHERE message_id=?",
                    (a2a.now_ts(), message_id),
                )
                conn.commit()
                return "conflict"
            now = a2a.now_ts()
            conn.execute(
                "INSERT INTO inbox_dedupe (message_id, peer, body_sha256, "
                "created_task_id, first_seen_ts, last_seen_ts, delivery_count) "
                "VALUES (?, ?, ?, NULL, ?, ?, 1)",
                (message_id, peer_id, body_hash, now, now),
            )
            conn.commit()
            return "new"
        finally:
            conn.close()

    def _handle_room_join_request(self, cfg: dict[str, Any]) -> None:
        """Receiver branch for the signed cross-node room-join-request
        (A2A Rooms P4.1, design §11 / §14 R3).

        HIGH-RISK: this is the only NEW remote-traffic surface in P4.1. It runs
        the SAME fail-closed auth preamble as do_POST / _handle_identity_update
        (NO step weakened), then performs the room-specific verification and
        persists a PENDING join row. Validation ORDER (security=True audit on
        every reject; NO persistence until ALL pass):
          a. tailnet-only bind — guaranteed at startup (resolve_bind).
          b. protocol tag == ROOM_JOIN_PROTOCOL_VERSION.
          c. message_id REQUIRED (anchors dedupe + is in the signed canonical).
          d. peer ALREADY PAIRED (find_peer; unknown -> 403). NOT discovery.
          e. remote_addr == the peer's CURRENT resolved Tailscale IP (before
             the body is read off the socket).
          f. HMAC: secret present, body hash, signature (constant-time). The
             request PATH is in the canonical string, so an enqueue/identity
             signature cannot be replayed against this endpoint.
          g. clock-skew window — transient drift 503, far-stale 401.
          h. durable dedupe (replay-safe) on message_id.
          i. parse the control body (shape only — never trusts the joiner id
             beyond the node-link auth already enforced).
          j. room is on THIS node (leader_node == this node) — else 404; a node
             that does not lead the room has no authority to admit/queue it.
          k. token verify: hash compare + TTL + revocation (verify_invite_token_
             outcome). expired/revoked/mismatch -> 403, NO pending row.
          l. rate-limit per (token-hash, SOURCE NODE) — a leaked reusable token
             cannot mint unbounded pending rows from one node.
          m. persist a VERIFIED pending row anchored to `joiner_agent` (the
             OS-actor attestation made by node B) @ the HMAC-AUTHENTICATED
             sender bridge as the node (NEVER a wire-asserted node). NO
             membership add, NO leader task, NO token/hash in the row/audit.
        """
        client_ip = self._client_ip()
        peer_id = self.headers.get("X-AGB-Peer", "")
        message_id = self.headers.get("X-AGB-Message-Id", "")
        timestamp = self.headers.get("X-AGB-Timestamp", "")
        body_hash_hdr = self.headers.get("X-AGB-Body-SHA256", "")
        signature = self.headers.get("X-AGB-Signature", "")
        protocol = self.headers.get("X-AGB-Protocol", "")

        # --- b. protocol tag ---
        if protocol != a2a.ROOM_JOIN_PROTOCOL_VERSION:
            audit("room_join_reject", reason="bad_protocol",
                  peer=peer_id, client=client_ip, got=protocol)
            self._reply(400, {"ok": False, "error": "unsupported protocol"})
            return

        # --- c. message_id REQUIRED (non-empty) ---
        if not message_id:
            audit("room_join_reject", reason="missing_message_id",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(400, {"ok": False, "error": "message id required"})
            return

        # --- d. peer must be ALREADY PAIRED (not a discovery channel) ---
        try:
            peer = a2a.find_peer(cfg, peer_id)
        except a2a.A2AError:
            audit("room_join_reject", reason="unknown_peer",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "unknown peer"})
            return

        # --- e. remote_addr == authenticated peer's CURRENT address (before body) ---
        try:
            peer_addr = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            audit("room_join_reject", reason=getattr(exc, "code",
                  "resolve_error"), peer=peer_id, client=client_ip,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return
        if not peer_addr or client_ip != peer_addr:
            audit("room_join_reject", reason="addr_mismatch",
                  peer=peer_id, client=client_ip, expected=peer_addr,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return

        # --- size guard before reading the body (tiny control body) ---
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = -1
        if content_length < 0:
            self._reply(411, {"ok": False, "error": "length required"})
            return
        max_body = 8 * 1024
        if content_length > max_body:
            audit("room_join_reject", reason="oversize",
                  peer=peer_id, client=client_ip, declared=content_length)
            self._reply(413, {"ok": False, "error": "body too large"})
            return
        raw = self.rfile.read(content_length) if content_length else b""

        # --- f. HMAC: secret present, body hash, signature (auth boundary) ---
        secrets = a2a.peer_secrets(peer)
        if not secrets:
            audit("room_join_reject", reason="no_secret",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "peer not provisioned"})
            return
        computed_hash = a2a.body_sha256(raw)
        if body_hash_hdr != computed_hash:
            audit("room_join_reject", reason="body_hash",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "body hash mismatch"})
            return
        # HMAC FIRST (before timestamp-band classification) so an
        # unauthenticated request never receives a transient/permanent split
        # that leaks signature validity (same ordering as do_POST, #1346). The
        # path is part of the canonical string, so an enqueue signature cannot
        # be replayed against this control endpoint.
        canonical = a2a.canonical_string(
            "POST", self.path, peer_id, message_id, timestamp, computed_hash)
        if not a2a.verify_signature(secrets, canonical, signature):
            audit("room_join_reject", reason="bad_signature",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(401, {"ok": False, "error": "signature verification failed"})
            return

        # --- g. clock-skew window (authenticated past this point) ---
        skew = int(cfg.get("timestamp_skew_seconds",
                           a2a.DEFAULT_TIMESTAMP_SKEW_SECONDS))
        grace_skew = int(cfg.get("timestamp_skew_grace_seconds",
                                 a2a.DEFAULT_TIMESTAMP_SKEW_GRACE_SECONDS))
        if grace_skew < skew:
            grace_skew = skew
        receiver_now = a2a.now_ts()
        try:
            req_ts = int(timestamp)
        except (TypeError, ValueError):
            audit("room_join_reject", reason="bad_timestamp",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "bad timestamp"})
            return
        ts_delta = abs(receiver_now - req_ts)
        if ts_delta > grace_skew:
            audit("room_join_reject", reason="clock_skew_permanent",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta,
                  security=True)
            self._reply(401, {"ok": False,
                              "error": "timestamp far outside skew window",
                              "receiver_ts": receiver_now})
            return
        if ts_delta > skew:
            audit("room_join_reject", reason="clock_skew_transient",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta)
            self._reply(503, {"ok": False,
                              "error": "timestamp outside skew window — retry",
                              "receiver_ts": receiver_now},
                        extra_headers={"Retry-After": str(max(1, skew))})
            return

        # --- h. durable dedupe — READ-ONLY replay check (codex P4.1 r1/r2) ---
        # CRITICAL: only a PREVIOUSLY-ACCEPTED request may replay as an
        # idempotent 200. The dedupe ledger lives in rooms.db (NOT inbox.db) so
        # the reservation commits ATOMICALLY with the pending row on the accept
        # path (step m); a dedupe row therefore exists IFF a pending row exists.
        # This read-only lookup gives the fast idempotent/conflict answer for an
        # ALREADY-ACCEPTED id; a rejected request leaves NO dedupe row, so a
        # replay re-runs verification and re-rejects (T3/T5 hold on replay). If
        # rooms.db is absent (this is not the leader node), the lookup is "new"
        # and the leader-node check (step j) will 404 anyway.
        if rooms is None:
            audit("room_join_error", reason="rooms_module_unavailable",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(500, {"ok": False, "error": "rooms unavailable"})
            return
        try:
            ro = rooms.open_rooms_readonly()
            if ro is not None:
                try:
                    dup = rooms.room_join_dedupe_lookup(
                        ro, peer_id, message_id, computed_hash)
                finally:
                    ro.close()
            else:
                dup = "new"
        except Exception as exc:  # noqa: BLE001 - last-resort guard
            audit("room_join_error", reason="dedupe_error",
                  peer=peer_id, client=client_ip, detail=str(exc)[:200])
            self._reply(500, {"ok": False, "error": "internal error"})
            return
        if dup == rooms.JOIN_DEDUPE_DUPLICATE:
            audit("room_join_accept", reason="duplicate",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(200, {"ok": True, "duplicate": True})
            return
        if dup == rooms.JOIN_DEDUPE_CONFLICT:
            audit("room_join_reject", reason="hash_conflict",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(409, {"ok": False,
                              "error": "message id reused with different body"})
            return

        # --- i. parse the control body (shape only) ---
        try:
            claim = a2a.parse_room_join_request(raw)
        except a2a.A2AError as exc:
            audit("room_join_reject", reason=getattr(exc, "code",
                  "bad_room_join"), peer=peer_id, client=client_ip,
                  message_id=message_id)
            self._reply(422, {"ok": False, "error": str(exc)})
            return

        # (rooms-module availability was already asserted at step h.)
        room_id = str(claim["room_id"])
        token_hash = str(claim["join_token_sha256"])
        joiner_agent = str(claim["joiner_agent"])
        # The joiner's NODE is the HMAC-authenticated sender bridge — NEVER a
        # wire-asserted field (contract 2). `peer_id` is the signed X-AGB-Peer
        # the auth preamble already bound to this connection.
        joiner_node = peer_id
        this_node = str(cfg.get("bridge_id") or "")

        # Open the rooms db to verify + persist. A leader-node receiver MUST have
        # the controller-owned rooms.db; we open it read-write (the verified
        # pending-row write needs it). open_rooms() creates it if absent, but a
        # genuine leader node always has it — and a non-leader node fails the
        # leader-node check below anyway, persisting nothing.
        try:
            conn = rooms.open_rooms()
        except rooms.RoomsError as exc:
            audit("room_join_error", reason=getattr(exc, "code", "rooms_db"),
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(500, {"ok": False, "error": "rooms db error"})
            return
        try:
            room = rooms.get_room(conn, room_id)
            if room is None:
                audit("room_join_reject", reason="room_unknown",
                      peer=peer_id, client=client_ip, room_id=room_id,
                      message_id=message_id, security=True)
                self._reply(404, {"ok": False, "error": "room not found"})
                return

            # --- j. room must be LED BY this node (else we have no authority) ---
            leader_node = str(room["leader_node"] or "")
            if leader_node != this_node:
                audit("room_join_reject", reason="not_leader_node",
                      peer=peer_id, client=client_ip, room_id=room_id,
                      message_id=message_id, security=True)
                self._reply(404, {"ok": False,
                                  "error": "room not led by this node"})
                return

            # --- k. token verify: hash + TTL + revocation (NEVER log the hash) ---
            # The wire carried sha256(token); compare it to the stored hash with
            # the SAME TTL/revocation semantics verify_invite_token_outcome
            # applies to a raw token, by hashing through a thin shim. We do NOT
            # reconstruct the raw token (we never have it) — instead we compare
            # the presented hash to the stored hash directly with TTL on top.
            outcome = _room_join_verify_hash(room, token_hash)
            if outcome != rooms.TOKEN_OK:
                # outcome is one of mismatch/revoked/expired — a stable,
                # token-free code, safe to audit.
                audit("room_join_reject", reason=f"token_{outcome}",
                      peer=peer_id, client=client_ip, room_id=room_id,
                      message_id=message_id, security=True)
                self._reply(403, {"ok": False,
                                  "error": f"invite token {outcome}"})
                return

            # --- l. rate-limit per (token-hash, SOURCE NODE) ---
            # Keyed on the source NODE (the authenticated peer), so a leaked
            # reusable token cannot mint unbounded pending rows from one node.
            # record_join_attempt keys its counter on the token HASH internally;
            # we pass the already-hashed token via the hash-preserving shim so
            # the raw token is never needed.
            try:
                _room_join_rate_check(conn, token_hash, source=joiner_node)
            except rooms.RoomsError as exc:
                audit("room_join_reject", reason="rate_limited",
                      peer=peer_id, client=client_ip, room_id=room_id,
                      message_id=message_id, security=True)
                self._reply(429, {"ok": False, "error": str(exc)},
                            extra_headers={"Retry-After": "120"})
                return

            # --- m. ACCEPT: reserve the dedupe row + persist the pending row
            # ATOMICALLY in ONE rooms.db transaction (codex P4.1 r2). Because
            # both writes commit together (or roll back together), "a dedupe row
            # exists" is equivalent to "a pending row exists" — there is no window
            # where a surviving reservation could let a replay return a bogus
            # idempotent 200 with no pending row. The re-check inside the call
            # closes the concurrent-replay-reserved-first race, resolving it to
            # the same idempotent/conflict outcome the read-only lookup would have.
            ttl_expiry = 0
            try:
                ttl = int(room["invite_token_ttl"])
                if ttl > 0:
                    ttl_expiry = int(room["invite_token_ts"]) + ttl
            except (KeyError, IndexError, TypeError, ValueError):
                ttl_expiry = 0
            try:
                outcome = rooms.record_verified_cross_node_join_request_atomic(
                    conn, message_id=message_id, body_sha256=computed_hash,
                    peer=peer_id, room_id=room_id, agent=joiner_agent,
                    node=joiner_node, via_node=joiner_node,
                    ttl_expiry=ttl_expiry,
                )
            except Exception as exc:  # noqa: BLE001 - last-resort guard
                # The atomic helper rolled BOTH writes back on failure, so no
                # orphan dedupe row survives → a replay re-runs verification.
                audit("room_join_error", reason="persist_error",
                      peer=peer_id, client=client_ip, message_id=message_id,
                      detail=str(exc)[:200])
                self._reply(500, {"ok": False, "error": "internal error"})
                return
        finally:
            conn.close()

        if outcome == rooms.JOIN_DEDUPE_DUPLICATE:
            audit("room_join_accept", reason="duplicate",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(200, {"ok": True, "duplicate": True})
            return
        if outcome == rooms.JOIN_DEDUPE_CONFLICT:
            audit("room_join_reject", reason="hash_conflict",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(409, {"ok": False,
                              "error": "message id reused with different body"})
            return

        # Audit carries ONLY verified metadata — room id, joiner agent@node,
        # message id — NEVER the token or its hash (contract 5).
        audit("room_join_accept", reason="pending",
              peer=peer_id, client=client_ip, room_id=room_id,
              joiner=f"{joiner_agent}@{joiner_node}", message_id=message_id)
        self._reply(200, {"ok": True, "status": rooms.JOIN_PENDING,
                          "room_id": room_id,
                          "joiner": f"{joiner_agent}@{joiner_node}"})

    def _handle_room_roster_broadcast(self, cfg: dict[str, Any]) -> None:
        """Receiver branch for the leader-signed cross-node roster broadcast
        (A2A Rooms P4.2, design §6 / §14 R2).

        HIGH-RISK: a NEW remote-traffic surface. It runs the SAME fail-closed
        auth preamble as do_POST / _handle_room_join_request (NO step weakened),
        then applies the member-side roster-acceptance contracts and writes the
        member-local room_roster_cache. Validation ORDER (security=True audit on
        every reject; NO persistence until ALL pass):
          a. tailnet-only bind — guaranteed at startup (resolve_bind).
          b. protocol tag == ROOM_ROSTER_PROTOCOL_VERSION.
          c. message_id REQUIRED (anchors dedupe).
          d. peer ALREADY PAIRED (find_peer; unknown -> 403). NOT discovery.
          e. remote_addr == the peer's CURRENT resolved Tailscale IP (before
             the body is read off the socket).
          f. HMAC: secret present, body hash, signature (constant-time). The
             X-AGB-Signature IS the leader-node↔member-node PAIRWISE signature
             (§14 R2) — a member that lacks the leader↔Z secret cannot forge a
             roster node Z would accept. The PATH is in the canonical string, so
             an enqueue/join/identity signature cannot be replayed here.
          g. clock-skew window — transient drift 503, far-stale 401.
          h. durable dedupe (replay-safe) on (peer, message_id). A byte-identical
             re-broadcast is an idempotent 200; an id-reuse-with-different-body is
             a 409. The dedupe ledger lives in rooms.db (the member's own db).
          i. parse the control body (shape only).
          j. ACCEPT per the member-side contracts (anti-rogue-leader binding +
             monotonic epoch + atomic cache write) — see
             rooms.accept_roster_broadcast. The authenticated `peer_id` is the
             ONLY trusted leader identity (it MUST equal the body's leader_node);
             a roster from a non-leader peer persists NOTHING.
        """
        client_ip = self._client_ip()
        peer_id = self.headers.get("X-AGB-Peer", "")
        message_id = self.headers.get("X-AGB-Message-Id", "")
        timestamp = self.headers.get("X-AGB-Timestamp", "")
        body_hash_hdr = self.headers.get("X-AGB-Body-SHA256", "")
        signature = self.headers.get("X-AGB-Signature", "")
        protocol = self.headers.get("X-AGB-Protocol", "")

        # --- b. protocol tag ---
        if protocol != a2a.ROOM_ROSTER_PROTOCOL_VERSION:
            audit("room_roster_reject", reason="bad_protocol",
                  peer=peer_id, client=client_ip, got=protocol)
            self._reply(400, {"ok": False, "error": "unsupported protocol"})
            return

        # --- c. message_id REQUIRED (non-empty) ---
        if not message_id:
            audit("room_roster_reject", reason="missing_message_id",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(400, {"ok": False, "error": "message id required"})
            return

        # --- d. peer must be ALREADY PAIRED (not a discovery channel) ---
        try:
            peer = a2a.find_peer(cfg, peer_id)
        except a2a.A2AError:
            audit("room_roster_reject", reason="unknown_peer",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "unknown peer"})
            return

        # --- e. remote_addr == authenticated peer's CURRENT address (before body) ---
        try:
            peer_addr = a2a.resolve_peer_address(peer)
        except a2a.A2AError as exc:
            audit("room_roster_reject", reason=getattr(exc, "code",
                  "resolve_error"), peer=peer_id, client=client_ip,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return
        if not peer_addr or client_ip != peer_addr:
            audit("room_roster_reject", reason="addr_mismatch",
                  peer=peer_id, client=client_ip, expected=peer_addr,
                  security=True)
            self._reply(403, {"ok": False, "error": "source address mismatch"})
            return

        # --- size guard before reading the body (roster bodies are small) ---
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = -1
        if content_length < 0:
            self._reply(411, {"ok": False, "error": "length required"})
            return
        max_body = 256 * 1024  # a roster of many members, still bounded
        if content_length > max_body:
            audit("room_roster_reject", reason="oversize",
                  peer=peer_id, client=client_ip, declared=content_length)
            self._reply(413, {"ok": False, "error": "body too large"})
            return
        raw = self.rfile.read(content_length) if content_length else b""

        # --- f. HMAC: secret present, body hash, signature (auth boundary) ---
        secrets = a2a.peer_secrets(peer)
        if not secrets:
            audit("room_roster_reject", reason="no_secret",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(403, {"ok": False, "error": "peer not provisioned"})
            return
        computed_hash = a2a.body_sha256(raw)
        if body_hash_hdr != computed_hash:
            audit("room_roster_reject", reason="body_hash",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "body hash mismatch"})
            return
        # HMAC FIRST (before timestamp-band classification) so an
        # unauthenticated request never receives a transient/permanent split
        # that leaks signature validity (same ordering as do_POST, #1346). The
        # path is part of the canonical string, so a signature minted for the
        # enqueue/join/identity endpoint cannot be replayed against this one.
        canonical = a2a.canonical_string(
            "POST", self.path, peer_id, message_id, timestamp, computed_hash)
        if not a2a.verify_signature(secrets, canonical, signature):
            audit("room_roster_reject", reason="bad_signature",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(401, {"ok": False, "error": "signature verification failed"})
            return

        # --- g. clock-skew window (authenticated past this point) ---
        skew = int(cfg.get("timestamp_skew_seconds",
                           a2a.DEFAULT_TIMESTAMP_SKEW_SECONDS))
        grace_skew = int(cfg.get("timestamp_skew_grace_seconds",
                                 a2a.DEFAULT_TIMESTAMP_SKEW_GRACE_SECONDS))
        if grace_skew < skew:
            grace_skew = skew
        receiver_now = a2a.now_ts()
        try:
            req_ts = int(timestamp)
        except (TypeError, ValueError):
            audit("room_roster_reject", reason="bad_timestamp",
                  peer=peer_id, client=client_ip, security=True)
            self._reply(401, {"ok": False, "error": "bad timestamp"})
            return
        ts_delta = abs(receiver_now - req_ts)
        if ts_delta > grace_skew:
            audit("room_roster_reject", reason="clock_skew_permanent",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta,
                  security=True)
            self._reply(401, {"ok": False,
                              "error": "timestamp far outside skew window",
                              "receiver_ts": receiver_now})
            return
        if ts_delta > skew:
            audit("room_roster_reject", reason="clock_skew_transient",
                  peer=peer_id, client=client_ip, delta_seconds=ts_delta)
            self._reply(503, {"ok": False,
                              "error": "timestamp outside skew window — retry",
                              "receiver_ts": receiver_now},
                        extra_headers={"Retry-After": str(max(1, skew))})
            return

        # --- h. durable dedupe — READ-ONLY replay check (peer-scoped) ---
        # A byte-identical re-broadcast (same peer+id+body) is an idempotent 200;
        # an id-reuse with a DIFFERENT body is a 409. The dedupe ledger reuses
        # the room_join_dedupe table in the MEMBER's rooms.db (the member's own
        # db). A rejected/no-op acceptance leaves NO dedupe row, so a replay
        # re-runs acceptance (the stale-epoch / not-leader teeth hold on replay).
        if rooms is None:
            audit("room_roster_error", reason="rooms_module_unavailable",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(500, {"ok": False, "error": "rooms unavailable"})
            return
        try:
            ro = rooms.open_rooms_readonly()
            if ro is not None:
                try:
                    dup = rooms.room_join_dedupe_lookup(
                        ro, peer_id, message_id, computed_hash)
                finally:
                    ro.close()
            else:
                dup = "new"
        except Exception as exc:  # noqa: BLE001 - last-resort guard
            audit("room_roster_error", reason="dedupe_error",
                  peer=peer_id, client=client_ip, detail=str(exc)[:200])
            self._reply(500, {"ok": False, "error": "internal error"})
            return
        if dup == rooms.JOIN_DEDUPE_DUPLICATE:
            audit("room_roster_accept", reason="duplicate",
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(200, {"ok": True, "duplicate": True})
            return
        if dup == rooms.JOIN_DEDUPE_CONFLICT:
            audit("room_roster_reject", reason="hash_conflict",
                  peer=peer_id, client=client_ip, message_id=message_id,
                  security=True)
            self._reply(409, {"ok": False,
                              "error": "message id reused with different body"})
            return

        # --- i. parse the control body (shape only) ---
        try:
            roster = a2a.parse_room_roster_broadcast(raw)
        except a2a.A2AError as exc:
            audit("room_roster_reject", reason=getattr(exc, "code",
                  "bad_room_roster"), peer=peer_id, client=client_ip,
                  message_id=message_id)
            self._reply(422, {"ok": False, "error": str(exc)})
            return

        room_id = str(roster["room_id"])
        leader_node = str(roster["leader_node"])
        room_epoch = int(roster["room_epoch"])
        members = list(roster["members"])

        # --- j. ACCEPT per the member-side contracts WITH atomic dedupe (codex
        # P4.2 r3 BLOCKING — close the TOCTOU race). accept_roster_broadcast
        # enforces leader-authority (peer==leader_node), the leader pin, the
        # first-roster binding, the monotonic epoch, AND folds the peer-scoped
        # dedupe RESERVATION into the SAME transaction as the cache write. So a
        # same-(peer,message_id)/DIFFERENT-body roster is caught as a CONFLICT
        # BEFORE any cache mutation (409, nothing written), and a contract REJECT
        # (not_leader / leader_mismatch / no_binding / stale) reserves NO dedupe
        # row so a replay re-evaluates. The earlier read-only dedupe pre-check
        # (step h) is a fast-path early answer for an ALREADY-RESERVED id; the
        # authoritative serialization is here.
        try:
            conn = rooms.open_rooms()
        except rooms.RoomsError as exc:
            audit("room_roster_error", reason=getattr(exc, "code", "rooms_db"),
                  peer=peer_id, client=client_ip, message_id=message_id)
            self._reply(500, {"ok": False, "error": "rooms db error"})
            return
        try:
            try:
                outcome = rooms.accept_roster_broadcast(
                    conn, room_id=room_id, room_epoch=room_epoch,
                    members=members, leader_node=leader_node, peer_id=peer_id,
                    message_id=message_id, body_sha256=computed_hash,
                    mac=signature,
                )
            except rooms.RoomsError as exc:
                audit("room_roster_error", reason=getattr(exc, "code",
                      "accept_error"), peer=peer_id, client=client_ip,
                      message_id=message_id, room_id=room_id)
                self._reply(500, {"ok": False, "error": "internal error"})
                return
        finally:
            conn.close()

        if outcome == rooms.ROSTER_NOT_LEADER:
            audit("room_roster_reject", reason="not_leader",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  leader_node=leader_node, message_id=message_id,
                  security=True)
            self._reply(403, {"ok": False,
                              "error": "roster sender is not the room leader"})
            return
        if outcome == rooms.ROSTER_LEADER_MISMATCH:
            # A configured peer self-claiming leadership of a room already led by
            # a DIFFERENT node — a takeover attempt. Reject, persist nothing
            # (codex P4.2 r1 BLOCKING).
            audit("room_roster_reject", reason="leader_mismatch",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  leader_node=leader_node, message_id=message_id,
                  security=True)
            self._reply(403, {"ok": False,
                              "error": "roster sender is not the established "
                              "room leader (takeover refused)"})
            return
        if outcome == rooms.ROSTER_NO_LOCAL_BINDING:
            audit("room_roster_reject", reason="no_local_binding",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  message_id=message_id, security=True)
            self._reply(403, {"ok": False,
                              "error": "no local join state for this room — "
                              "refusing to mint a roster cache from an "
                              "inbound broadcast"})
            return
        if outcome == rooms.ROSTER_DEDUPE_CONFLICT:
            # Same (peer, message_id) reused with a DIFFERENT body — caught at the
            # atomic dedupe reservation BEFORE any cache write (codex P4.2 r3).
            audit("room_roster_reject", reason="hash_conflict",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  message_id=message_id, security=True)
            self._reply(409, {"ok": False,
                              "error": "message id reused with different body"})
            return
        if outcome == rooms.ROSTER_STALE_EPOCH:
            # Not an error (a legitimate lower/same-epoch non-duplicate is simply
            # ignored), but we still return 200 with applied=False so the leader
            # does not retry forever. No dedupe row reserved.
            audit("room_roster_ignore", reason="stale_epoch",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  epoch=room_epoch, message_id=message_id)
            self._reply(200, {"ok": True, "applied": False,
                              "reason": "stale_epoch"})
            return

        if outcome == rooms.ROSTER_DUPLICATE:
            audit("room_roster_accept", reason="duplicate",
                  peer=peer_id, client=client_ip, room_id=room_id,
                  message_id=message_id)
            self._reply(200, {"ok": True, "duplicate": True,
                              "room_id": room_id, "epoch": room_epoch})
            return

        # ACCEPTED — the member-local roster cache now reflects this epoch.
        audit("room_roster_accept", reason="applied",
              peer=peer_id, client=client_ip, room_id=room_id,
              epoch=room_epoch, members=len(members), message_id=message_id)
        self._reply(200, {"ok": True, "applied": True,
                          "room_id": room_id, "epoch": room_epoch,
                          "members": len(members)})


# --------------------------------------------------------------------------
# Room-join hash-only verification + rate-limit shims (P4.1)
# --------------------------------------------------------------------------
#
# The wire carries sha256(token), NOT the raw token, so the leader-node receiver
# never possesses the raw token. The rooms_common verify/rate helpers were
# written for the single-node path that DOES hold the raw token (it hashes
# internally). These shims let the receiver apply the SAME TTL/revocation +
# rate-limit semantics to an already-hashed token without reconstructing the
# raw value (which is impossible) and without duplicating the rooms_common
# logic. They live here (the receiver), not in rooms_common, because they are a
# cross-node-receiver-specific adaptation of the existing primitives.


def _room_join_verify_hash(room: Any, token_hash: str) -> str:
    """Verify a presented token HASH against the room (hash + TTL + revocation).

    Mirrors rooms.verify_invite_token_outcome but takes the hash directly (the
    receiver never has the raw token). Returns a rooms.TOKEN_* code. The order
    matches the raw-token path: revocation -> constant-time hash compare ->
    TTL — so the receiver path can never be MORE permissive than the local path.
    """
    import hmac as _hmac

    stored = room["invite_token_sha256"]
    if not stored:
        return rooms.TOKEN_REVOKED
    if not _hmac.compare_digest(str(stored), token_hash):
        return rooms.TOKEN_MISMATCH
    try:
        ttl = int(room["invite_token_ttl"])
    except (KeyError, IndexError, TypeError, ValueError):
        ttl = 0
    if ttl > 0:
        try:
            issued = int(room["invite_token_ts"])
        except (KeyError, IndexError, TypeError, ValueError):
            issued = 0
        if issued + ttl < a2a.now_ts():
            return rooms.TOKEN_EXPIRED
    return rooms.TOKEN_OK


def _room_join_rate_check(conn: Any, token_hash: str, *, source: str) -> None:
    """Per-(token-hash, source-node) rate limit using the room_join_rate table.

    Mirrors rooms.record_join_attempt's counter logic but keys directly on the
    already-known token HASH (the receiver does not have the raw token to hash).
    Raises rooms.RoomsError(code='rate_limited') past the ceiling. Kept in lock-
    step with rooms.record_join_attempt's DEFAULT ceiling + schema.
    """
    limit = rooms.DEFAULT_JOIN_RATE_LIMIT_PER_TOKEN
    ts = rooms.now_ts()
    row = conn.execute(
        "SELECT attempts FROM room_join_rate WHERE token_sha256=? AND source=?",
        (token_hash, source),
    ).fetchone()
    attempts = (int(row["attempts"]) if row else 0) + 1
    if row:
        conn.execute(
            "UPDATE room_join_rate SET attempts=?, last_ts=? "
            "WHERE token_sha256=? AND source=?",
            (attempts, ts, token_hash, source),
        )
    else:
        conn.execute(
            "INSERT INTO room_join_rate (token_sha256, source, attempts, "
            "first_ts, last_ts) VALUES (?, ?, ?, ?, ?)",
            (token_hash, source, attempts, ts, ts),
        )
    conn.commit()
    if attempts > limit:
        raise rooms.RoomsError(
            "join rate limit exceeded for this invite token "
            f"(source node, {attempts} attempts > {limit})",
            code="rate_limited",
        )


# --------------------------------------------------------------------------
# entry points
# --------------------------------------------------------------------------

def cmd_preflight(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config(Path(args.config) if args.config else None)
        # #1331: refuse to certify a config carrying an unprovisioned peer.
        # Audited so the operator sees the bypass when test-mode is on.
        try:
            a2a.validate_config_peer_secrets(cfg, side="receiver")
        except a2a.A2AError as exc:
            audit("startup_fail", code=exc.code, detail=str(exc)[:300])
            raise
        if a2a._allow_insecure_no_secret():
            audit("insecure_secret_bypass", side="receiver", phase="preflight",
                  security=True)
        bind, port = resolve_bind(cfg)
    except a2a.A2AError as exc:
        print(f"[handoffd][preflight] FAIL: {exc} ({exc.code})", file=sys.stderr)
        return 1
    print(f"[handoffd][preflight] OK: would bind {bind}:{port}, "
          f"{len(cfg.get('peers', []))} peer(s) configured")
    return 0


def cmd_reconcile(args: argparse.Namespace) -> int:
    """Preview one reconcile pass without touching a running daemon.

    Loads + validates the config (fail-closed report) and re-resolves +
    RE-PROVES the bind via the same resolve_bind() proof the running daemon
    uses. Prints what a live reconcile WOULD do — useful for the setup wizard
    + operators to confirm the current Tailscale identity resolves to an
    in-set bind before/after an IP change. The running daemon self-heals on
    its own timer (and on SIGHUP); this is the visibility surface.
    """
    config_path = Path(args.config) if args.config else None
    # --- config validity (fail-closed report) ---
    try:
        cfg = a2a.load_config(config_path)
        a2a.validate_config_peer_secrets(cfg, side="receiver")
        peers = len(cfg.get("peers", []))
        print(f"[handoffd][reconcile] config OK: {peers} peer(s) configured")
    except a2a.A2AError as exc:
        print(f"[handoffd][reconcile] config FAIL: {exc} ({exc.code}) — a "
              "running daemon would keep its last-good config", file=sys.stderr)
        return 1
    # --- bind re-prove (same proof as the running daemon) ---
    try:
        bind, port = resolve_bind(cfg)
        print(f"[handoffd][reconcile] bind proven: would serve on {bind}:{port}")
    except a2a.A2AError as exc:
        print(f"[handoffd][reconcile] bind FAIL: {exc} ({exc.code}) — a "
              "running daemon would keep its current proven bind", file=sys.stderr)
        return 1
    return 0


def cmd_healthz(args: argparse.Namespace) -> int:
    """Probe a RUNNING receiver's serve liveness via GET /healthz.

    Read-only liveness check for the daemon supervisor (#1405). Resolves the
    configured bind address/port through the SAME `resolve_bind` proof the
    daemon uses (so the probe targets the exact tailnet socket the receiver
    serves on), then issues a single unauthenticated `GET /healthz` — the
    receiver's existing read-only health endpoint (do_GET, line ~722). Healthy
    iff HTTP 200 AND the JSON body's `service` field is `a2a-handoffd`.

    This subcommand NEVER binds or serves and carries no POST-path auth
    surface: it only resolves+connects+reads. resolve_bind itself stays
    fail-closed (refuses wildcard/loopback/non-tailnet); a resolve failure
    here means the bind is unprovable, which the supervisor treats distinctly
    from a wedged-but-bound serve loop.

    Exit 0 + `healthy` on stdout when the serve loop is accepting; non-zero
    with a single reason WORD on stdout otherwise:
      - `bind_unresolved` : resolve_bind could not prove the bind (Tailscale
                            down / address not in `tailscale ip`). The process
                            gate already ran in the supervisor; this is the
                            socket-side proof.
      - `healthz_timeout` : connect/read timed out OR the socket refused — the
                            pid is alive but the serve loop is not accepting
                            (the wedged / deadlocked case this probe exists to
                            catch).
      - `healthz_status:<code>` : reachable but returned a non-200 status.
      - `healthz_badbody` : 200 but the body was not the a2a-handoffd health
                            envelope (something else is on the port).
    """
    try:
        cfg = a2a.load_config(Path(args.config) if args.config else None)
        bind, port = resolve_bind(cfg)
    except a2a.A2AError as exc:
        print("bind_unresolved")
        log(f"healthz: bind unresolved ({exc.code})")
        return 2

    timeout = float(getattr(args, "timeout", 3) or 3)
    healthz_path = cfg.get("listen", {}).get("healthz_path", "/healthz")
    # IPv6 literals need bracketing in a URL authority.
    host = f"[{bind}]" if ":" in bind else bind
    url = f"http://{host}:{port}{healthz_path}"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            body = resp.read(4096)
    except urllib.error.HTTPError as exc:
        # Reachable, but a non-2xx status. Report the code so the supervisor
        # exit-cause logger can record `healthz_status:<code>`.
        print(f"healthz_status:{exc.code}")
        return 4
    except (urllib.error.URLError, OSError, ValueError):
        # Connection refused / timed out / reset: pid alive but socket not
        # accepting (the wedged-serve case). Bucketed as a timeout reason.
        print("healthz_timeout")
        return 3

    if status != 200:
        print(f"healthz_status:{status}")
        return 4
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        payload = {}
    if payload.get("service") == "a2a-handoffd" and payload.get("ok") is True:
        print("healthy")
        return 0
    print("healthz_badbody")
    return 5


def _write_pidfile(path: str) -> None:
    """Record the calling process's pid to `path` (atomic replace)."""
    pid_path = Path(path)
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pid_path.with_suffix(pid_path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(f"{os.getpid()}\n", encoding="utf-8")
    os.replace(tmp, pid_path)


def _detach_into_own_session() -> None:
    """Reparent the current process into its own session + process group.

    After this returns, the process is a session leader detached from the
    launching shell's controlling terminal and process group, so it is NOT
    torn down when that shell / managed agent tool session exits. Uses the
    POSIX double-fork idiom, which is portable across macOS and Linux (no
    dependency on the `setsid` CLI, which macOS lacks). The socket is bound
    BEFORE this is called, so a fail-closed bind error is still surfaced
    synchronously to the launcher.
    """
    if os.fork() > 0:
        os._exit(0)  # original launcher process exits; shell regains control
    os.setsid()  # become session + process-group leader, drop controlling tty
    if os.fork() > 0:
        os._exit(0)  # intermediate exits so the daemon cannot reacquire a tty
    # Grandchild: detach stdin from the terminal; stdout/stderr stay pointed
    # at the caller-provided log redirection.
    try:
        devnull = os.open(os.devnull, os.O_RDONLY)
        os.dup2(devnull, 0)
        os.close(devnull)
    except OSError:
        pass


def cmd_serve(args: argparse.Namespace) -> int:
    try:
        cfg = a2a.load_config(Path(args.config) if args.config else None)
        # #1331: refuse to start the daemon if any peer has no secret —
        # the per-request `reject_no_secret` 403 path covers an empty
        # secret slipping past load, but a startup gate makes the
        # misconfiguration visible BEFORE the daemon starts accepting
        # untrusted remote traffic. The paired BRIDGE_A2A_DEV_INSECURE_BIND
        # + BRIDGE_A2A_ALLOW_TEST_BIND escape hatch is the only way to
        # silence the gate; we audit that bypass so it cannot be quiet.
        a2a.validate_config_peer_secrets(cfg, side="receiver")
        if a2a._allow_insecure_no_secret():
            audit("insecure_secret_bypass", side="receiver", phase="serve",
                  security=True)
        bind, port = resolve_bind(cfg)
    except a2a.A2AError as exc:
        log(f"FATAL: {exc} ({exc.code})")
        audit("startup_fail", code=exc.code, detail=str(exc)[:300])
        return 1

    a2a.ensure_handoff_dirs()
    config_path = Path(args.config) if args.config else None
    try:
        server = HandoffServer((bind, port), HandoffHandler, cfg)
    except OSError as exc:
        log(f"FATAL: cannot bind {bind}:{port}: {exc}")
        audit("bind_fail", address=bind, port=port, detail=str(exc))
        return 1
    # The peer-identity-update apply re-loads + rewrites this same file.
    server.config_path = config_path

    # Bind succeeded — fail-closed preflight is satisfied. Now (optionally)
    # detach into our own session so the receiver outlives the launching
    # shell / managed agent tool session. The double-fork happens AFTER the
    # bind so the launcher still sees a non-zero exit on a bad bind.
    if getattr(args, "detach", False):
        _detach_into_own_session()
    if getattr(args, "pidfile", None):
        # Written by whichever process owns the long-lived server (the
        # detached grandchild when --detach is set), so the recorded pid is
        # the durable listener, not a transient launcher pid.
        try:
            _write_pidfile(args.pidfile)
        except OSError as exc:
            log(f"FATAL: cannot write pidfile {args.pidfile}: {exc}")
            server.server_close()
            return 1

    audit("listening", address=bind, port=port,
          peers=len(cfg.get("peers", [])), pid=os.getpid())
    log(f"A2A receiver listening on {bind}:{port}")
    try:
        if args.once:
            # Single-request test mode: no reconcile supervisor (the smoke
            # drives reconcile_once directly).
            server.handle_request()
        else:
            serve_with_reconcile(server, config_path)
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.server_close()
        if getattr(args, "pidfile", None):
            try:
                pid_path = Path(args.pidfile)
                if pid_path.read_text(encoding="utf-8").strip() == str(os.getpid()):
                    pid_path.unlink()
            except (OSError, ValueError):
                pass
        audit("stopped")
    return 0


def serve_with_reconcile(server: "HandoffServer",
                         config_path: Optional[Path]) -> None:
    """Run the receiver with the periodic + SIGHUP self-heal reconcile.

    `serve_forever()` runs on a worker thread so the main thread can wake on
    the reconcile cadence (and on SIGHUP) to call `reconcile_once`. When a
    reconcile proves a NEW bind, the old listener is shut down and a fresh
    HandoffServer is created on the new (already-proven) address; the new
    server inherits the swapped config. A rebind that cannot bind the new
    socket keeps the old listener (fail-safe).
    """
    interval = _reconcile_interval()
    wake = threading.Event()

    # SIGHUP triggers an immediate reconcile (operator / wizard `kill -HUP`).
    # Only install the handler on the main thread (signals can only be set
    # from the main thread); the detached daemon's serve loop IS the main
    # thread here.
    def _on_sighup(_signum: int, _frame: Any) -> None:
        wake.set()
    try:
        signal.signal(signal.SIGHUP, _on_sighup)
    except (ValueError, OSError):
        # Not on the main thread or platform without SIGHUP — periodic timer
        # still works; just no signal trigger.
        pass

    # Hold the live server in a one-element list so the rebind can replace it
    # for both the worker thread and this loop.
    holder: list[HandoffServer] = [server]

    def _run_forever(srv: HandoffServer) -> None:
        try:
            srv.serve_forever()
        except Exception as exc:  # noqa: BLE001 - worker guard, surfaced via log
            log(f"serve_forever exited unexpectedly: {exc}")

    worker = threading.Thread(target=_run_forever, args=(server,),
                              name="a2a-serve", daemon=True)
    worker.start()

    if interval <= 0:
        log("reconcile timer disabled (BRIDGE_A2A_RECONCILE_INTERVAL=0); "
            "SIGHUP still triggers a reconcile")

    while True:
        # Wake on the interval OR an immediate SIGHUP. When the timer is
        # disabled, block until a SIGHUP sets the event.
        if interval > 0:
            wake.wait(timeout=interval)
        else:
            wake.wait()
        wake.clear()

        cur = holder[0]
        if not worker.is_alive():
            # The listener thread died (should not happen) — stop cleanly so
            # the supervisor (cron/launchd) can relaunch.
            log("serve worker is no longer alive; stopping reconcile loop")
            break

        result = reconcile_once(cur, config_path)
        if result.changed() or result.bind_error or result.config_error:
            audit("reconcile", summary=result.summary())
            log(f"reconcile: {result.summary()}")

        if not result.want_rebind:
            continue

        # --- perform the actual socket swap on the new (proven) bind ---
        old = holder[0]
        new_addr, new_port = result.new_bind, result.new_port
        try:
            new_server = HandoffServer((new_addr, new_port),
                                       old.RequestHandlerClass, old.cfg)
            # Carry the config path so the rebound server's identity-update
            # apply still rewrites the same on-disk config.
            new_server.config_path = old.config_path
        except OSError as exc:
            # New address not bindable yet (e.g. not plumbed) → KEEP the old
            # listener. We never end up unbound or on an unproven address.
            audit("rebind_fail", address=new_addr, port=new_port,
                  detail=str(exc)[:200], current_bind=old.bound_address,
                  security=True)
            log(f"rebind to {new_addr}:{new_port} failed ({exc}); "
                f"keeping current bind {old.bound_address}:{old.bound_port}")
            continue

        # Bring up the new listener BEFORE tearing the old one down so there is
        # no window with zero listeners.
        new_worker = threading.Thread(target=_run_forever, args=(new_server,),
                                      name="a2a-serve", daemon=True)
        new_worker.start()
        holder[0] = new_server
        worker = new_worker
        audit("rebind", old=f"{old.bound_address}:{old.bound_port}",
              new=f"{new_addr}:{new_port}")
        log(f"rebind old={old.bound_address}:{old.bound_port} "
            f"new={new_addr}:{new_port}")
        old.shutdown()
        old.server_close()

        # P-self-heal-3 (design §9.6): a rebind means THIS node's own
        # Tailscale IP changed — the single-flight trigger for the
        # peer-identity-update announce. Push the signed control message to
        # every configured peer so they auto-update OUR stored identity with
        # no manual edit+restart on their side (closes the bidirectional gap).
        # Best-effort + non-blocking: failures are logged, never crash the
        # daemon (each peer re-corroborates against its own view anyway, and
        # the per-request inbound resolver already self-heals identity-keyed
        # peers — the announce is a fast-convergence optimization).
        _announce_identity_after_rebind(config_path)


def _announce_identity_after_rebind(config_path: Optional[Path]) -> None:
    """Fire `bridge-a2a.py announce-identity` after a local-IP rebind so peers
    converge on this node's new identity without manual intervention.

    Runs the sender CLI as an argv array (never heredoc-stdin; footgun #11),
    fully detached + timeout-bounded so a slow/unreachable peer can never
    stall the reconcile loop. Best-effort: any failure is audited, not raised.
    """
    cli = Path(__file__).resolve().parent / "bridge-a2a.py"
    if not cli.is_file():  # noqa: raw-pathlib-controller-only
        return
    argv = [sys.executable, str(cli), "announce-identity", "--timeout", "10"]
    env = dict(os.environ)
    if config_path is not None:
        env["BRIDGE_A2A_CONFIG"] = str(config_path)
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=90, env=env,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        audit("identity_announce_failed", reason="invoke_error",
              detail=str(exc)[:200])
        return
    if proc.returncode != 0:
        audit("identity_announce_partial", rc=proc.returncode,
              detail=(proc.stderr or proc.stdout or "").strip()[-200:])
    else:
        audit("identity_announce_sent",
              detail=(proc.stdout or "").strip()[-200:])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bridge-handoffd.py",
        description="Agent Bridge A2A receiver daemon (tailnet-bound).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_serve = sub.add_parser("serve", help="run the receiver daemon")
    p_serve.add_argument("--config", default=None,
                         help="path to handoff.local.json")
    p_serve.add_argument("--once", action="store_true",
                         help="handle a single request then exit (test mode)")
    p_serve.add_argument("--detach", action="store_true",
                         help="double-fork into an own session after bind, so "
                              "the receiver outlives the launching shell")
    p_serve.add_argument("--pidfile", default=None,
                         help="write the durable listener's pid to this path")
    p_serve.set_defaults(func=cmd_serve)

    p_pre = sub.add_parser("preflight", help="validate bind + config, then exit")
    p_pre.add_argument("--config", default=None)
    p_pre.set_defaults(func=cmd_preflight)

    p_rec = sub.add_parser(
        "reconcile",
        help="preview one self-heal reconcile pass (resolve+prove bind, "
             "validate config) without touching a running daemon")
    p_rec.add_argument("--config", default=None)
    p_rec.set_defaults(func=cmd_reconcile)

    # #1405: read-only serve-liveness probe for the daemon supervisor. Reuses
    # resolve_bind (never binds/serves) and the receiver's existing read-only
    # GET /healthz endpoint. Exit 0 healthy / non-zero + reason word on stdout.
    p_health = sub.add_parser(
        "healthz",
        help="probe a running receiver's serve liveness via GET /healthz "
             "(read-only; exit 0 healthy / non-zero + reason word)")
    p_health.add_argument("--config", default=None)
    p_health.add_argument("--timeout", type=float, default=3.0,
                          help="connect/read timeout in seconds (default 3)")
    p_health.set_defaults(func=cmd_healthz)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
