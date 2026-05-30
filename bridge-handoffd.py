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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

import bridge_a2a_common as a2a

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
    ]
    # NOTE: --skip-companion-validate is deliberately NOT passed — remote
    # peers must not bypass companion-review validation.
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
    try:
        server = HandoffServer((bind, port), HandoffHandler, cfg)
    except OSError as exc:
        log(f"FATAL: cannot bind {bind}:{port}: {exc}")
        audit("bind_fail", address=bind, port=port, detail=str(exc))
        return 1

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
    config_path = Path(args.config) if args.config else None
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

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
