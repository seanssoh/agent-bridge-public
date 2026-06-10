#!/usr/bin/env python3
"""Shared helpers for Agent Bridge cross-bridge task handoff (A2A).

This module is the single source of truth for the A2A wire protocol, the
HMAC signing scheme, the data-only peer config loader, and the durable
SQLite outbox / inbox-dedupe schemas. It is imported by both the CLI
(`bridge-a2a.py`) and the receiver daemon (`bridge-handoffd.py`); it never
runs anything on import and has no third-party dependencies.

Design contract (see docs/a2a-cross-bridge.md):
- Network substrate is Tailscale; the receiver binds to a tailnet IP only.
- Auth is an HMAC-signed request keyed by an ordered-pair secret. The
  secret is never placed in a header or logged — only the signature is.
- Protocol is symmetric fire-and-forget enqueue. No correlation IDs.
"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Optional

try:
    import fcntl  # POSIX advisory file lock (TOCTOU guard on peer auto-register)
except ImportError:  # pragma: no cover - non-POSIX; A2A is POSIX-only in practice
    fcntl = None  # type: ignore[assignment]

PROTOCOL_VERSION = "a2a-enqueue-v1"
ENVELOPE_PROTOCOL = "agent-bridge.a2a.enqueue.v1"
SIGNATURE_PREFIX = "v1="

# P-self-heal-3 (design §9.6): the signed `peer-identity-update` control
# message. A node whose reconcile (P-self-heal-1) detects its OWN Tailscale
# IP changed pushes this to every configured peer so the peer auto-updates
# THIS node's stored identity/address — closing the bidirectional-sync gap
# (today an IP change needs a manual edit+restart on BOTH sides).
#
# It is DELIBERATELY a distinct protocol from the enqueue path so the
# receiver routes it to a SEPARATE handler with its own fail-closed stack
# (it never reaches the enqueue/allowlist/queue boundary). The receiver
# NEVER trusts the wire-asserted IP: it re-resolves the claim against its
# OWN `tailscale status --json` view, and only updates an ALREADY-PAIRED
# peer — this is NOT a discovery/trust-bootstrap channel.
IDENTITY_UPDATE_PROTOCOL_VERSION = "a2a-identity-update-v1"
IDENTITY_UPDATE_ENVELOPE_PROTOCOL = "agent-bridge.a2a.identity-update.v1"
# The receiver path for the control message — distinct from the enqueue
# path so a misrouted enqueue can never land in the identity-update handler
# and vice versa.
IDENTITY_UPDATE_PATH = "/peer-identity-update"

# A2A Rooms P4.1 (design §11 / §14 R3): the signed cross-node `room-join-request`
# control message. A member on node B posts this to the leader's node A over the
# EXISTING node-link so node A can verify the invite token + persist a PENDING
# join request. Like the identity-update message it is a DISTINCT protocol routed
# to a SEPARATE handler with its own fail-closed stack — it NEVER reaches the
# enqueue/allowlist/queue boundary, NEVER carries a queue task, and NEVER
# auto-admits. The wire carries `sha256(join_token)` ONLY (never the raw token,
# §14 R3) and the joiner *agent* claim; the joiner *node* is bound by the
# receiver to the HMAC-authenticated sender bridge (never wire-asserted).
ROOM_JOIN_PROTOCOL_VERSION = "a2a-room-join-v1"
ROOM_JOIN_ENVELOPE_PROTOCOL = "agent-bridge.a2a.room-join.v1"
ROOM_JOIN_PATH = "/room-join-request"

# A2A Rooms P4.2 (design §6 / §11 / §14 R2): the signed cross-node
# `room-roster-broadcast` control message. After the leader (on node A) approves
# a member it bumps the room epoch and broadcasts the canonical, leader-signed
# roster to EACH member node over THAT node's existing node-link, MAC'd with the
# leader-node↔member-node ordered-pair secret (one signed POST per member-link —
# §14 R2 "Member X knows only the leader↔X secret, never leader↔Z, so X cannot
# forge a roster node Z would accept"). Like the join-request it is a DISTINCT
# protocol routed to a SEPARATE handler with the SAME fail-closed auth preamble
# (remote_addr -> HMAC -> skew -> dedupe); its terminal action is a member-local
# room_roster_cache write — it NEVER reaches the enqueue/allowlist/queue
# boundary, carries no queue task, and admits nothing. The pairwise HMAC IS the
# leader signature: the X-AGB-Signature header is computed over the canonical
# request string (which binds method+path+peer+message_id+timestamp+body-hash)
# with the leader↔member secret, so a member cannot forge a roster for a peer
# whose secret it does not hold. The body carries ONLY the canonical roster
# (room_id, room_epoch, sorted members, leader_node) — no token, no secret.
ROOM_ROSTER_PROTOCOL_VERSION = "a2a-room-roster-v1"
ROOM_ROSTER_ENVELOPE_PROTOCOL = "agent-bridge.a2a.room-roster.v1"
ROOM_ROSTER_PATH = "/room-roster-broadcast"

# Default per-peer caps. Receiver config may override per peer.
DEFAULT_MAX_BODY_BYTES = 256 * 1024
DEFAULT_MAX_TITLE_BYTES = 1024
DEFAULT_TIMESTAMP_SKEW_SECONDS = 300

# v0.14.5-beta5-2 Lane λ (#1326): timestamps within (skew, grace_skew] are
# treated as transient clock drift — the receiver responds with 503 +
# Retry-After so the sender retries after the operator clock-syncs. Beyond
# grace_skew the timestamp is too old to be drift; the request is rejected
# with 401 (likely replay of a stale captured payload). Default grace =
# 1 hour, configurable via top-level `timestamp_skew_grace_seconds`.
DEFAULT_TIMESTAMP_SKEW_GRACE_SECONDS = 3600

# Sender outbox caps — fail new sends locally instead of growing unbounded.
DEFAULT_OUTBOX_MAX_TOTAL_BYTES = 64 * 1024 * 1024
DEFAULT_OUTBOX_MAX_PENDING_PER_PEER = 500
DEFAULT_INBOX_DEDUPE_GC_MAX_AGE_SECONDS = 86400 * 60
DEFAULT_INBOX_DEDUPE_MAX_ROWS_PER_PEER = 10000

# Sender outbox retry timing caps. The exponential backoff ceiling bounds our
# own recovery dormancy; Retry-After uses a separate cap so peer backpressure can
# remain a hard floor without letting an untrusted HTTP response sleep us
# indefinitely.
DEFAULT_DELIVERY_BACKOFF_CEILING_SECONDS = 120
MIN_DELIVERY_BACKOFF_CEILING_SECONDS = 15
DEFAULT_DELIVERY_MAX_RETRY_AFTER_SECONDS = 600
MIN_DELIVERY_MAX_RETRY_AFTER_SECONDS = 1
DEFAULT_DELIVERY_TRUSTED_RETRY_AFTER_SANITY_CAP_SECONDS = 3600

VALID_PRIORITIES = ("low", "normal", "high", "urgent")
TERMINAL_OUTBOX_STATUSES = ("acked", "dead")
PENDING_OUTBOX_STATUSES = ("pending", "sending", "retry")

# HTTP statuses that are permanent failures (no retry → dead-letter).
PERMANENT_FAIL_STATUSES = (400, 401, 403, 404, 409, 413, 422)

# #1732 transient-peer resilience (codex design-consensus #11698). A2A peers
# are frequently personal laptops — connect/disconnect is NORMAL, not a fault.
# A peer's `class` controls how the outbox treats a RETRYABLE (transport /
# resolve / timeout / 5xx / 429) failure once `delivery_max_attempts` is hit
# and whether the daemon raises the `[A2A] outbox stuck` admin alarm:
#   - "persistent" (DEFAULT — no behavior change for existing installs): the
#     classic server-class behavior. Max-attempts → terminal `dead`; the
#     outbox-stuck alarm fires at `high` priority.
#   - "transient" (explicit per-peer opt-in): a retryable failure NEVER
#     terminally dead-letters just because max-attempts was reached — the row
#     PARKS (stays `retry`, backoff capped so an offline laptop cannot hot-loop)
#     and is woken on the #1707 peer-reachability UP transition. PERMANENT
#     failures (missing config/secret/address/body, auth/HMAC, the
#     PERMANENT_FAIL_STATUSES set) STILL go `dead` immediately for ANY class.
#     Bounded: a parked row that has lived past the transient-retention TTL is
#     expired to `dead(expired-transient-retention)` so GC reclaims it.
DEFAULT_PEER_CLASS = "persistent"
VALID_PEER_CLASSES = ("persistent", "transient")
# Generous default retention for a transient peer's parked rows (7 days) — an
# overnight/weekend-asleep laptop still receives its messages when it wakes,
# without unbounded growth. Per-peer (`caps.transient_retention_seconds`) or
# top-level (`transient_retention_seconds`) override; floored so a misconfig
# cannot make retention effectively zero (which would re-introduce the drop).
DEFAULT_TRANSIENT_RETENTION_SECONDS = 7 * 86400
MIN_TRANSIENT_RETENTION_SECONDS = 3600


class A2AError(Exception):
    """Generic A2A failure with an optional machine-readable code."""

    def __init__(self, message: str, code: str = "a2a_error") -> None:
        super().__init__(message)
        self.code = code


class TailscaleUnavailable(A2AError):
    """The local Tailscale CLI / status could not be queried.

    Distinct from "Tailscale is up but reports no matching node" — every
    caller MUST fail closed when this is raised (we cannot prove anything
    about the tailnet). The receiver's bind proof in particular treats
    this as "refuse to serve", never "guess from a CIDR shape".
    """

    def __init__(self, message: str) -> None:
        super().__init__(message, code="tailscale_unavailable")


class CloudflareWarpUnavailable(A2AError):
    """The local Cloudflare WARP CLI / status could not be queried.

    The Cloudflare-One / WARP-Mesh transport analogue of
    `TailscaleUnavailable`: when the WARP connection/enrollment state cannot
    be determined (CLI missing, status query failed, not registered, not
    connected) the receiver bind proof MUST fail closed — it never guesses
    "connected" from a CIDR shape or a bare interface address. Distinct from
    "WARP is up but the bind IP is not on a local interface", which is a
    plain A2AError (`bind_not_warp_local`).
    """

    def __init__(self, message: str) -> None:
        super().__init__(message, code="warp_unavailable")


# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

def bridge_home() -> Path:
    return Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))


def state_dir() -> Path:
    explicit = os.environ.get("BRIDGE_STATE_DIR")
    if explicit:
        return Path(explicit)
    return bridge_home() / "state"


def handoff_dir() -> Path:
    """`$BRIDGE_STATE_DIR/handoff` — durable A2A working directory."""
    return state_dir() / "handoff"


def _path_is_within(child: Path, parent: Path) -> bool:
    """True iff `child` resolves to `parent` or a descendant of it.

    Pure lexical containment on the *resolved* (symlink-collapsed, absolute)
    forms — no filesystem write, safe to call before any dir exists. Used by
    the test-bind state-path guard to decide whether a `BRIDGE_STATE_DIR`
    override still lands the A2A state tree under the active `BRIDGE_HOME`.
    """
    try:
        child_r = child.resolve()
        parent_r = parent.resolve()
    except (OSError, RuntimeError):
        # resolve() can raise on a symlink loop; treat "cannot prove within" as
        # NOT within so the guard fails closed rather than silently allowing.
        return False
    if child_r == parent_r:
        return True
    return parent_r in child_r.parents


def guard_test_bind_state_path() -> None:
    """Fail closed when a test-bind mesh would write into a live state tree.

    Symmetric to the `BRIDGE_A2A_ALLOW_TEST_BIND=1` loopback bind escape hatch
    (`resolve_bind` in `bridge-handoffd.py`): that flag is TEST-ONLY — production
    never sets it — so a guard keyed on it can never affect a production install.

    The footgun (issue #1728): a throwaway test mesh that overrides only
    per-node `BRIDGE_HOME` but inherits a live `BRIDGE_STATE_DIR` (normal on a
    configured host) resolves `handoff_dir()` — and therefore rooms.db /
    reconcile.db / outbox / inbox — to the LIVE state dir, silently clobbering
    real room membership. The socket bind is gated by the test flag; the
    state-path was not.

    When `BRIDGE_A2A_ALLOW_TEST_BIND=1` AND the resolved handoff state dir is
    NOT under the active `BRIDGE_HOME` (i.e. an override points it at a
    live / out-of-home location), refuse the operation with a clear message
    pointing at the override knobs. Production (flag unset) and a correctly
    isolated test mesh (state dir under the test home) are unaffected.

    NOTE (#1728 r2): this state-dir check is necessary but NOT sufficient. The
    explicit per-store DB overrides (`BRIDGE_A2A_OUTBOX_DB` / `_INBOX_DB` /
    `BRIDGE_A2A_ROOMS_DB` / `_RECONCILE_DB`) bypass `state_dir()` entirely, so a
    mesh can keep `BRIDGE_STATE_DIR` under home (passing here) yet still point a
    db at a live tree. The db-path containment is enforced at each `_connect()`
    choke point via `guard_test_bind_db_path()` — this entry stays for the early
    `ensure_handoff_dirs()` / `cmd_serve` phase=config refuse-to-serve.
    """
    guard_test_bind_db_path(state_dir(), what="A2A state dir")


def guard_test_bind_db_path(path: Path, *, what: str = "A2A db path") -> None:
    """Fail closed when a test-bind mesh would write `path` into a live tree.

    The db-path-aware core of the #1728 guard. `guard_test_bind_state_path()`
    delegates here for the resolved state dir; each `_connect()` choke point
    calls it with the FINAL resolved db path — which includes any explicit
    `BRIDGE_A2A_OUTBOX_DB` / `_INBOX_DB` / `BRIDGE_A2A_ROOMS_DB` /
    `_RECONCILE_DB` override that bypasses `state_dir()`. Under the test-bind
    flag, ANY resolved write path outside the active `BRIDGE_HOME` fails closed,
    so a throwaway test mesh can never clobber the live state tree no matter
    which knob redirected it.

    No-op when `BRIDGE_A2A_ALLOW_TEST_BIND` is unset (production) and when the
    resolved path is under the active `BRIDGE_HOME` (a correctly isolated mesh,
    including an override pointed UNDER the test home).
    """
    if os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") != "1":  # noqa: iso-helper-boundary - env var, not a .env file
        return
    home = bridge_home()
    if _path_is_within(path, home):
        return
    raise A2AError(
        f"BRIDGE_A2A_ALLOW_TEST_BIND=1 (test mode) but the {what} "
        f"{str(path)!r} is outside BRIDGE_HOME {str(home)!r} — a "
        "test mesh would clobber the live rooms.db / reconcile.db / "
        "outbox / inbox. Set BRIDGE_STATE_DIR (and, if overridden, "
        "BRIDGE_A2A_ROOMS_DB / BRIDGE_A2A_RECONCILE_DB / "
        "BRIDGE_A2A_OUTBOX_DB / BRIDGE_A2A_INBOX_DB) under your test "
        "BRIDGE_HOME so test state cannot reach the live state tree.",
        code="test_bind_state_outside_home",
    )


def outbox_db_path() -> Path:
    override = os.environ.get("BRIDGE_A2A_OUTBOX_DB")
    if override:
        return Path(override)
    return handoff_dir() / "outbox.db"


def inbox_db_path() -> Path:
    override = os.environ.get("BRIDGE_A2A_INBOX_DB")
    if override:
        return Path(override)
    return handoff_dir() / "inbox.db"


def incoming_dir() -> Path:
    return handoff_dir() / "incoming"


def outgoing_dir() -> Path:
    return handoff_dir() / "outgoing"


def config_path() -> Path:
    override = os.environ.get("BRIDGE_A2A_CONFIG")
    if override:
        return Path(override)
    return bridge_home() / "handoff.local.json"


def ensure_handoff_dirs() -> None:
    # #1728: before creating/writing the handoff tree, fail closed if a
    # test-bind mesh (BRIDGE_A2A_ALLOW_TEST_BIND=1) would land it on a live
    # state dir outside its BRIDGE_HOME. No-op when the flag is unset (prod).
    guard_test_bind_state_path()
    for path in (handoff_dir(), incoming_dir(), outgoing_dir()):
        path.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass


# --------------------------------------------------------------------------
# Config — data-only JSON, never a sourced shell file
# --------------------------------------------------------------------------

def load_config(path: Optional[Path] = None) -> dict[str, Any]:
    """Load the data-only A2A config.

    The config is JSON only — it is parsed, never executed, because it is
    consulted while handling untrusted remote traffic. Refuses a file that
    is group/world readable (mode must be 0600-ish) because it carries
    peer-pair secrets.
    """
    cfg_path = path or config_path()
    if not cfg_path.exists():
        raise A2AError(
            f"A2A config not found: {cfg_path}\n"
            "Copy handoff.local.example.json to that path and edit it "
            "(chmod 0600).",
            code="config_missing",
        )
    try:
        mode = cfg_path.stat().st_mode & 0o777
    except OSError as exc:
        raise A2AError(f"cannot stat A2A config: {exc}", code="config_stat") from exc
    if mode & 0o077:
        raise A2AError(
            f"A2A config {cfg_path} is mode {mode:04o}; it carries peer "
            "secrets and must be 0600. Run: chmod 0600 "
            f"{cfg_path}",
            code="config_perms",
        )
    try:
        raw = cfg_path.read_text(encoding="utf-8")
        cfg = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise A2AError(f"cannot parse A2A config {cfg_path}: {exc}", code="config_parse") from exc
    if not isinstance(cfg, dict):
        raise A2AError("A2A config root must be a JSON object", code="config_shape")
    cfg.setdefault("bridge_id", "")
    cfg.setdefault("listen", {})
    cfg.setdefault("peers", [])
    cfg.setdefault("delivery_max_retry_after_seconds",
                   DEFAULT_DELIVERY_MAX_RETRY_AFTER_SECONDS)
    if not isinstance(cfg["peers"], list):
        raise A2AError("A2A config 'peers' must be a list", code="config_shape")
    return cfg


def find_peer(cfg: dict[str, Any], peer_id: str) -> dict[str, Any]:
    for peer in cfg.get("peers", []):
        if isinstance(peer, dict) and peer.get("id") == peer_id:
            return peer
    raise A2AError(f"peer not configured: {peer_id}", code="peer_unknown")


def peer_secrets(peer: dict[str, Any]) -> list[str]:
    """Return the accepted HMAC keys for a peer (current + optional next)."""
    secrets: list[str] = []
    primary = peer.get("secret")
    if isinstance(primary, str) and primary:
        secrets.append(primary)
    nxt = peer.get("secret_next")
    if isinstance(nxt, str) and nxt:
        secrets.append(nxt)
    # Legacy/explicit list form.
    extra = peer.get("secrets")
    if isinstance(extra, list):
        for item in extra:
            if isinstance(item, str) and item and item not in secrets:
                secrets.append(item)
    return secrets


def peer_send_secret(peer: dict[str, Any]) -> str:
    """The single key the sender signs with (the current secret)."""
    secrets = peer_secrets(peer)
    if not secrets:
        raise A2AError(f"peer {peer.get('id')} has no secret configured", code="peer_no_secret")
    return secrets[0]


def _allow_insecure_no_secret() -> bool:
    """v0.14.5-beta5-2 Lane λ (#1331): paired flag to allow empty peer secrets.

    Both env vars must be set to "1" — this is deliberately a *paired* flag
    so a single env-var leak (e.g. a stale shell profile) cannot silently
    relax the secret-validation contract in production. Mirrors the existing
    `BRIDGE_A2A_ALLOW_TEST_BIND` pattern (loopback bind escape hatch) and is
    only intended for the smoke harness, never for real deployments.
    """
    return (
        os.environ.get("BRIDGE_A2A_DEV_INSECURE_BIND") == "1"
        and os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1"
    )


def validate_config_peer_secrets(
    cfg: dict[str, Any], *, side: str = "receiver",
) -> None:
    """Refuse a config that carries any peer with an empty/missing secret.

    `side` is "receiver" or "sender" — used only in the error message so
    operators see which boot path tripped the check. Auditing of insecure
    test-mode bypass is the caller's job (it has access to the audit
    sink); this helper just enforces the contract.

    Note: bridges that have *no* peers configured at all are allowed —
    that is the early-install / probe state and we don't want to wedge
    `handoffd preflight` on a fresh checkout. The fail-closed contract
    fires only when at least one peer entry exists with no usable key.
    """
    peers = cfg.get("peers", [])
    if not isinstance(peers, list):
        return
    insecure: list[str] = []
    for peer in peers:
        if not isinstance(peer, dict):
            continue
        if not peer_secrets(peer):
            insecure.append(str(peer.get("id") or "(missing id)"))
    if not insecure:
        return
    if _allow_insecure_no_secret():
        return
    raise A2AError(
        f"A2A {side} refuses to start: peer(s) {', '.join(insecure)} "
        "have no 'secret' configured. Set a long random shared secret "
        "(>=32 random bytes) for each peer in handoff.local.json under "
        "peers[].secret. For loopback test runs only, set BOTH "
        "BRIDGE_A2A_DEV_INSECURE_BIND=1 and BRIDGE_A2A_ALLOW_TEST_BIND=1.",
        code="peer_no_secret",
    )


def peer_cap(peer: dict[str, Any], key: str, default: Any) -> Any:
    caps = peer.get("caps")
    if isinstance(caps, dict) and key in caps:
        return caps[key]
    return default


def peer_class(peer: dict[str, Any]) -> str:
    """Resolve a peer's transience class — `persistent` (default) | `transient`.

    #1732. The class is read from the top-level `class` key on the peer entry.
    DEFAULT is `persistent` (existing installs and any peer that does not opt in
    behave EXACTLY as before — the server-class drop-after-max-attempts + high
    alarm). An unrecognized/non-string value FAILS SAFE to `persistent` (we never
    silently treat an unknown class as the no-drop/quiet transient policy).
    """
    raw = peer.get("class")
    if isinstance(raw, str) and raw.strip().lower() in VALID_PEER_CLASSES:
        return raw.strip().lower()
    return DEFAULT_PEER_CLASS


def peer_is_transient(peer: dict[str, Any]) -> bool:
    """True iff the operator marked this peer expected-transient (#1732)."""
    return peer_class(peer) == "transient"


def peer_alarm_on_unreachable(peer: dict[str, Any]) -> bool:
    """Should the daemon raise the `[A2A] outbox stuck` admin alarm for this peer?

    #1732. Class-keyed default: `persistent` → True (today's behavior unchanged),
    `transient` → False (expected disconnects are not incidents — stay quiet). An
    explicit per-peer `alarm_on_unreachable` boolean overrides the class default
    either way (e.g. a transient laptop the operator still wants alarmed, or a
    persistent peer deliberately silenced).
    """
    explicit = peer.get("alarm_on_unreachable")
    if isinstance(explicit, bool):
        return explicit
    return not peer_is_transient(peer)


def peer_transient_retention_seconds(cfg: dict[str, Any],
                                     peer: dict[str, Any]) -> int:
    """Resolve a transient peer's parked-row retention TTL in seconds (#1732).

    Precedence: per-peer `caps.transient_retention_seconds` → top-level
    `transient_retention_seconds` → DEFAULT_TRANSIENT_RETENTION_SECONDS. Floored
    at MIN_TRANSIENT_RETENTION_SECONDS so a misconfigured tiny/zero value cannot
    silently re-introduce the drop the no-drop guarantee is meant to remove.
    """
    raw = peer_cap(peer, "transient_retention_seconds", None)
    if raw is None:
        raw = cfg.get("transient_retention_seconds",
                      DEFAULT_TRANSIENT_RETENTION_SECONDS)
    return _int_with_floor(
        raw,
        DEFAULT_TRANSIENT_RETENTION_SECONDS,
        MIN_TRANSIENT_RETENTION_SECONDS,
    )


def peer_stuck_alert_secs(cfg: dict[str, Any],
                          peer: dict[str, Any]) -> Optional[int]:
    """Resolve a per-peer override for the outbox-stuck alarm grace window (#1732).

    Returns the per-peer `caps.stuck_alert_secs` (a longer grace window an
    operator may set for a flaky-but-alarmed peer), or None to mean "use the
    daemon's global `BRIDGE_A2A_STUCK_ALERT_SECS` default". A non-positive /
    unparseable override is ignored (None). This is independent of
    `alarm_on_unreachable`: a transient peer with the alarm suppressed never
    reaches the grace-window check at all.
    """
    raw = peer_cap(peer, "stuck_alert_secs", None)
    if raw is None:
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def write_config_atomic(path: Path, cfg: dict[str, Any], mode: int = 0o600) -> None:
    """Write `cfg` as pretty JSON to `path` atomically, at mode `mode`.

    The config carries peer-pair HMAC secrets, so the temp file is created
    at 0o600 FROM THE START via os.open (never the umask default) so the
    secret-bearing JSON is never group/world-readable during the write+fsync
    window. `mode` (default 0o600) is re-applied to the temp before the
    atomic replace, so the final file preserves the caller's intended mode
    while the worst case during the window is tighter, never wider.

    Single source of the 0600-atomic write for the sender CLI
    (`bridge-a2a.py migrate-identity`) and the receiver
    (`bridge-handoffd.py` peer-identity-update apply) so the two paths can
    never diverge on the secret-on-disk guarantee.
    """
    tmp = path.with_name(path.name + ".tmp")  # noqa: raw-pathlib-controller-only
    text = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
    except BaseException:
        try:
            os.unlink(tmp)  # noqa: raw-pathlib-controller-only
        except OSError:
            pass
        raise
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)  # noqa: raw-pathlib-controller-only


# --------------------------------------------------------------------------
# Tailscale identity resolution (P0 — runtime resolve, no stored IP)
# --------------------------------------------------------------------------
#
# A peer (and `listen`) MAY carry an optional Tailscale identity in addition
# to the legacy raw `address`:
#   - `tailscale_name`: a MagicDNS hostname or short HostName.
#   - `node_id`:        a Tailscale StableID (the `ID` field in `tailscale
#                       status --json`).
# At use-time the identity is resolved to the node's CURRENT TailscaleIP via
# `tailscale status --json`. There is no stored resolved IP, so an IP change
# after a tailnet re-login is picked up transparently on the next send/bind —
# the stale-IP class simply cannot occur when keyed on an identity. If no
# identity is present, `resolve_peer_address` falls back to the literal
# `address` (full back-compat with today's raw-IP configs).
#
# Security note: this only PRODUCES a candidate address. The receiver bind
# proof (`tailscale ip` membership check in bridge-handoffd.py) is unchanged
# and still independently proves the resolved candidate is a real local
# Tailscale interface before binding.

# Well-known absolute locations for the `tailscale` CLI, probed when it is
# not on PATH. A receiver/sender invoked from cron / launchd / systemd often
# has a minimal PATH that omits /opt/homebrew/bin, so PATH-only discovery
# would fail on a macOS host that DOES have Tailscale installed (e.g. via
# Homebrew). Probing these does not weaken any proof — the resolved binary's
# output is still the only thing trusted.
_TAILSCALE_FALLBACK_PATHS = (
    "/opt/homebrew/bin/tailscale",                            # Homebrew (Apple Silicon)
    "/usr/local/bin/tailscale",                               # Homebrew (Intel) / manual
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",   # macOS App Store app
    "/usr/bin/tailscale",                                     # Linux package
    "/usr/sbin/tailscale",
)


def resolve_tailscale_cli() -> Optional[str]:
    """Locate the `tailscale` CLI: PATH first, then well-known locations.

    `BRIDGE_A2A_TAILSCALE_CLI` overrides discovery entirely (an explicit
    path for non-standard installs; also lets the smoke exercise the
    genuinely-absent path deterministically). Returns the resolved path,
    or None when no candidate exists — the caller fails closed on None.

    This is the single source of truth for CLI location; bridge-handoffd.py
    imports it so the sender + receiver never diverge on where Tailscale is.
    """
    override = os.environ.get("BRIDGE_A2A_TAILSCALE_CLI")
    if override:
        return override
    found = shutil.which("tailscale")
    if found:
        return found
    for cand in _TAILSCALE_FALLBACK_PATHS:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def tailscale_status_json() -> dict[str, Any]:
    """Return the parsed `tailscale status --json` document.

    Raises TailscaleUnavailable if the CLI cannot be located, the call
    fails, exits non-zero, or the output is not a JSON object — callers
    MUST fail closed in those cases rather than guessing.
    """
    cli = resolve_tailscale_cli()
    if cli is None:
        raise TailscaleUnavailable(
            "the 'tailscale' CLI was not found on PATH or in any standard "
            "install location (/opt/homebrew/bin, /usr/local/bin, "
            "/Applications/Tailscale.app/Contents/MacOS, /usr/bin) — cannot "
            "resolve a Tailscale identity to its current IP. Install "
            "Tailscale or set BRIDGE_A2A_TAILSCALE_CLI to its path."
        )
    try:
        out = subprocess.run(
            [cli, "status", "--json"],
            capture_output=True, text=True, timeout=10,
        )
    except FileNotFoundError as exc:
        raise TailscaleUnavailable(
            f"the 'tailscale' CLI path {cli!r} does not exist or is not "
            "executable — cannot resolve a Tailscale identity."
        ) from exc
    except (subprocess.SubprocessError, OSError) as exc:
        raise TailscaleUnavailable(
            f"'tailscale status --json' failed to run: {exc}"
        ) from exc
    if out.returncode != 0:
        raise TailscaleUnavailable(
            f"'tailscale status --json' exited {out.returncode}: "
            f"{(out.stderr or '').strip()[:200]}"
        )
    try:
        doc = json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise TailscaleUnavailable(
            f"'tailscale status --json' produced non-JSON output: {exc}"
        ) from exc
    if not isinstance(doc, dict):
        raise TailscaleUnavailable(
            "'tailscale status --json' root is not a JSON object"
        )
    return doc


def _status_nodes(status: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten the Self + Peer node records from a status document."""
    nodes: list[dict[str, Any]] = []
    self_node = status.get("Self")
    if isinstance(self_node, dict):
        nodes.append(self_node)
    peers = status.get("Peer")
    if isinstance(peers, dict):
        for node in peers.values():
            if isinstance(node, dict):
                nodes.append(node)
    return nodes


def _node_first_ip(node: dict[str, Any]) -> Optional[str]:
    """Return a node's first TailscaleIP (IPv4 is listed first by Tailscale)."""
    ips = node.get("TailscaleIPs")
    if isinstance(ips, list):
        for ip in ips:
            if isinstance(ip, str) and ip.strip():
                return ip.strip()
    return None


def _name_matches(node: dict[str, Any], name: str) -> bool:
    """True if `name` matches a node's HostName or (DNS/Magic)DNSName.

    Matches are case-insensitive. `DNSName` in status output is the fully
    qualified MagicDNS name with a trailing dot (e.g.
    `host.tailnet.ts.net.`); we accept the FQDN with or without the trailing
    dot, and the bare short label (the leftmost component) so a config can
    carry either the short HostName or the full MagicDNS name.
    """
    want = name.strip().rstrip(".").lower()
    if not want:
        return False
    hostname = str(node.get("HostName", "")).strip().rstrip(".").lower()
    if hostname and want == hostname:
        return True
    dns = str(node.get("DNSName", "")).strip().rstrip(".").lower()
    if dns:
        if want == dns:
            return True
        # Allow the short label of the FQDN to match a short config value.
        if want == dns.split(".", 1)[0]:
            return True
    return False


def resolve_peer_address(entry: dict[str, Any]) -> str:
    """Resolve a peer or `listen` dict to a current Tailscale IP (or literal).

    Precedence (matches the design §8):
      1. `node_id`  (Tailscale StableID) → match on a node's `ID`.
      2. `tailscale_name` (MagicDNS/HostName) → match on HostName / DNSName.
      3. legacy `address` → returned verbatim (full back-compat).

    When an identity (`node_id` / `tailscale_name`) is present it is resolved
    live via `tailscale status --json`; a failure to resolve is a HARD error
    (TailscaleUnavailable if Tailscale cannot be queried at all, otherwise
    A2AError) — we deliberately do NOT silently fall back to a possibly-stale
    `address`, because the whole point of keying on an identity is to avoid
    trusting a stored IP.
    """
    if not isinstance(entry, dict):
        raise A2AError("address entry must be an object", code="resolve_shape")

    node_id = entry.get("node_id")
    ts_name = entry.get("tailscale_name")
    has_node_id = isinstance(node_id, str) and node_id.strip()
    has_ts_name = isinstance(ts_name, str) and ts_name.strip()

    if not has_node_id and not has_ts_name:
        # Legacy raw-IP path — no identity to resolve, return the literal.
        address = entry.get("address", "")
        if not isinstance(address, str):
            raise A2AError("'address' must be a string", code="resolve_shape")
        return address.strip()

    # An identity is present → resolve live. Any query failure propagates
    # (TailscaleUnavailable) so the caller fails closed.
    status = tailscale_status_json()
    nodes = _status_nodes(status)

    if has_node_id:
        want = node_id.strip()
        for node in nodes:
            if str(node.get("ID", "")).strip() == want:
                ip = _node_first_ip(node)
                if ip:
                    return ip
                raise A2AError(
                    f"Tailscale node_id {want!r} resolved to a node with no "
                    "TailscaleIP — refusing to fall back to a stored address.",
                    code="resolve_no_ip",
                )
        raise A2AError(
            f"Tailscale node_id {want!r} not found in 'tailscale status "
            "--json' (Self/Peer) — refusing to fall back to a possibly-stale "
            "'address'. Re-check the StableID or peer connectivity.",
            code="resolve_node_id_unknown",
        )

    # tailscale_name path.
    want = ts_name.strip()
    for node in nodes:
        if _name_matches(node, want):
            ip = _node_first_ip(node)
            if ip:
                return ip
            raise A2AError(
                f"Tailscale name {want!r} resolved to a node with no "
                "TailscaleIP — refusing to fall back to a stored address.",
                code="resolve_no_ip",
            )
    raise A2AError(
        f"Tailscale name {want!r} not found in 'tailscale status --json' "
        "(HostName/DNSName of Self/Peer) — refusing to fall back to a "
        "possibly-stale 'address'. Re-check the MagicDNS name or peer "
        "connectivity.",
        code="resolve_name_unknown",
    )


# --------------------------------------------------------------------------
# Transport selection (#1595 — Tailscale | cloudflare-warp-mesh)
# --------------------------------------------------------------------------
#
# A2A is transport-pluggable. The transport decides ONE thing: how the
# receiver PROVES that a candidate bind IP is a real, currently-up local
# interface on the private network substrate (and, for the sender, how a
# peer's target IP is resolved). Everything above the transport — the
# HMAC-signed wire protocol, dedupe, allowlist/caps/backpressure,
# room_scoped_check, room epoch, the `remote_addr == resolved-peer`
# source check — is transport-AGNOSTIC and unchanged.
#
# Two kinds today:
#   - "tailscale"            (default; legacy back-compat): proof is
#                            membership in `tailscale ip`'s set. A config
#                            with NO `transport` key behaves EXACTLY as
#                            before — `transport_kind` returns "tailscale".
#   - "cloudflare-warp-mesh" (#1595): proof is (a) the candidate IP is
#                            assigned to a real local interface AND (b) WARP
#                            is connected + registered/enrolled. CIDR shape
#                            alone is NOT proof. Fail CLOSED on any
#                            uncertainty (CLI missing, WARP disconnected,
#                            IP not on a local interface).
#
# This is Mesh / WARP-to-WARP PRIVATE-IP connectivity (TCP/UDP by device
# IP) — NOT the Cloudflare Tunnel + Access hostname model. The two are
# distinct substrates; only the private-IP one is implemented here.

TRANSPORT_TAILSCALE = "tailscale"
TRANSPORT_CLOUDFLARE_WARP_MESH = "cloudflare-warp-mesh"
SUPPORTED_TRANSPORTS = (TRANSPORT_TAILSCALE, TRANSPORT_CLOUDFLARE_WARP_MESH)


def transport_kind(cfg: dict[str, Any]) -> str:
    """Return the configured A2A transport kind, defaulting to "tailscale".

    Back-compat: a config with no `transport` block (every config shipped
    before #1595) resolves to "tailscale" and the legacy bind/source proof
    runs unchanged. An explicit `transport.kind` must be one of
    SUPPORTED_TRANSPORTS — an unknown kind is a HARD error (fail closed)
    rather than a silent fallback to a weaker proof.
    """
    if not isinstance(cfg, dict):
        raise A2AError("config must be an object", code="transport_config")
    transport = cfg.get("transport")
    if transport is None:
        return TRANSPORT_TAILSCALE
    if not isinstance(transport, dict):
        raise A2AError(
            "config 'transport' must be an object", code="transport_config")
    kind = transport.get("kind", TRANSPORT_TAILSCALE)
    if not isinstance(kind, str) or not kind.strip():
        raise A2AError(
            "config 'transport.kind' must be a non-empty string",
            code="transport_config")
    kind = kind.strip()
    if kind not in SUPPORTED_TRANSPORTS:
        raise A2AError(
            f"unknown transport.kind {kind!r}; supported: "
            f"{', '.join(SUPPORTED_TRANSPORTS)}",
            code="transport_unknown")
    return kind


# --------------------------------------------------------------------------
# Cloudflare One / WARP-Mesh local proof (#1595)
# --------------------------------------------------------------------------
#
# The WARP analogue of `tailscale_addresses()` + `is_tailnet_address()`.
# It proves TWO independent facts before the receiver will bind:
#   1. WARP is connected AND registered/enrolled (queried from the WARP CLI
#      — `warp-cli status` + `warp-cli --accept-tos registration show` /
#      `account`), and
#   2. the candidate bind IP is assigned to a REAL local interface right now
#      (enumerated from the OS, not inferred from a CIDR).
# Either fact unknowable -> CloudflareWarpUnavailable / A2AError -> the
# caller fails closed. There is deliberately no CIDR-shape fallback, exactly
# mirroring the Tailscale posture.

# Well-known absolute locations for the WARP CLI, probed when it is not on
# PATH. A receiver invoked from cron / launchd / systemd often has a minimal
# PATH that omits the GUI app's bundled CLI dir. Probing these does not
# weaken any proof — the resolved binary's output is still the only thing
# trusted.
_WARP_CLI_FALLBACK_PATHS = (
    "/opt/homebrew/bin/warp-cli",                              # Homebrew (Apple Silicon)
    "/usr/local/bin/warp-cli",                                 # Homebrew (Intel) / manual
    "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli",  # macOS app bundle
    "/usr/bin/warp-cli",                                       # Linux package
    "/usr/sbin/warp-cli",
)


def resolve_warp_cli() -> Optional[str]:
    """Locate the `warp-cli` binary: PATH first, then well-known locations.

    `BRIDGE_A2A_WARP_CLI` overrides discovery entirely (an explicit path for
    non-standard installs; it also lets the smoke point at a mock CLI that
    simulates connected/disconnected WARP without a real WARP install).
    Returns the resolved path, or None when no candidate exists — the caller
    fails closed on None.

    Single source of truth for the WARP CLI location so the sender +
    receiver never diverge on where WARP is.
    """
    override = os.environ.get("BRIDGE_A2A_WARP_CLI")
    if override:
        return override
    found = shutil.which("warp-cli")
    if found:
        return found
    for cand in _WARP_CLI_FALLBACK_PATHS:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _run_warp_cli(cli: str, args: list[str]) -> str:
    """Run `warp-cli <args>` and return stdout; raise CloudflareWarpUnavailable.

    A non-zero exit, a missing binary, or any OS error is "WARP state is
    unknowable" -> fail closed. stdout is returned verbatim (callers parse
    it case-insensitively).
    """
    try:
        out = subprocess.run(
            [cli, *args],
            capture_output=True, text=True, timeout=10,
        )
    except FileNotFoundError as exc:
        raise CloudflareWarpUnavailable(
            f"the 'warp-cli' path {cli!r} does not exist or is not "
            "executable — cannot prove WARP is connected/enrolled."
        ) from exc
    except (subprocess.SubprocessError, OSError) as exc:
        raise CloudflareWarpUnavailable(
            f"'warp-cli {' '.join(args)}' failed to run: {exc}"
        ) from exc
    if out.returncode != 0:
        raise CloudflareWarpUnavailable(
            f"'warp-cli {' '.join(args)}' exited {out.returncode}: "
            f"{(out.stderr or out.stdout or '').strip()[:200]}"
        )
    return out.stdout or ""


def _warp_cli_capture(cli: str, args: list[str]) -> tuple[bool, str, int]:
    """Run `warp-cli <args>` and return (ran, raw_output, returncode).

    `ran` is False ONLY when the binary could not be executed at all (missing
    / not executable / OS error) — a truly unknowable state. Otherwise `ran`
    is True and `raw_output` is the COMBINED stdout+stderr verbatim
    REGARDLESS of exit code — deliberately NOT wrapped in any
    `'warp-cli ... exited N:'` framing, so the registration classifier always
    parses CLEAN CLI output (a non-zero exit that prints `Account type: false`
    on stderr must be classifiable as a negative, not hidden behind a
    wrapper-prefixed line — codex r7). This is the runner the enrollment proof
    uses; the `status` query keeps `_run_warp_cli` (raise-on-nonzero) because
    an unreadable status is itself a fail-closed "not connected".

    `returncode` is returned alongside so the enrollment proof can FAIL CLOSED
    on a POSITIVE-looking label that actually came from a FAILED query: a
    nonzero exit may only ever confirm an explicit NEGATIVE (parsed from the
    verbatim output), never prove enrollment (#1595 patch-dev re-review). It is
    -1 when the binary could not be executed (`ran` False).
    """
    try:
        out = subprocess.run(
            [cli, *args],
            capture_output=True, text=True, timeout=10,
        )
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return False, "", -1
    combined = (out.stdout or "")
    if out.stderr:
        combined = (combined + "\n" + out.stderr) if combined else out.stderr
    return True, combined, out.returncode


# Negative status/enrollment tokens that must NEVER be misread as "up". These
# are substrings whose presence in a `Status update:` value or an enrollment
# line forces a fail-closed refusal even if a positive word also appears
# (e.g. "Not Connected", "Connected: false", "Device unregistered").
_WARP_STATUS_NEGATIVE = (
    "not connected", "disconnect", "connecting", "unable",
    "no network", "false", "off", "error", "pause", "stopped", "down",
)
_WARP_REG_NEGATIVE = (
    "unregister", "not registered", "missing registration",
    "registration missing", "no registration", "none", "not enrolled",
    # Non-active registration states: a revoked/inactive/etc registration is
    # NOT enrollment even if a concrete identity field is also printed. These
    # are scanned as substrings over the whole blob, so a `Status: Revoked`
    # line forces a fail-closed refusal regardless of any Device ID line.
    "revoked", "inactive", "deleted", "expired", "suspended", "disabled",
)
# Positive enrollment tokens: a real `warp-cli registration show` /
# `warp-cli account` prints at least one of these CONCRETE identity field
# labels with a non-empty value when the device is enrolled in an org. We
# deliberately do NOT treat a generic `Registration:`/`Registered:` summary
# label as positive — those carry free-form values (e.g. `Registration:
# Missing`, `Registered: false`) that a label-only check would false-pass.
_WARP_REG_POSITIVE_LABELS = (
    "account type", "organization", "account id", "device id",
)
# A value under a positive label that is itself one of these is NOT
# enrollment (e.g. `Account type: none`, `Organization: false`). Matched as
# the WHOLE trimmed value (exact) so a real org name containing the word
# "no" (e.g. "Nordic") is not rejected.
_WARP_REG_NEGATIVE_VALUES = frozenset((
    "none", "false", "no", "0", "off", "unknown", "missing",
    "unregistered", "not registered", "n/a", "null", "-",
))
# Summary status labels whose VALUE can be a negative signal (e.g.
# `Registration: false`, `Registered: no`, `Status: revoked`). These are read
# ONLY as a negative signal (never positive enrollment proof) — a free-form
# summary value is not a concrete enrolled identity.
_WARP_REG_SUMMARY_LABELS = (
    "registration", "registered", "status", "state", "enrolled",
)


def _warp_status_is_connected(raw: str) -> bool:
    """Strict positive parse of `warp-cli status` -> True only if Connected.

    Fail-closed: requires an EXACT `Connected` state. The real CLI prints
    `Status update: <STATE>` (e.g. `Connected`, `Disconnected`, `Connecting`,
    `Unable to connect`, `Not Connected`). We read the value after the last
    `Status update:` (or, lacking that label, the whole text), refuse if it
    carries ANY negative token, and then require the bare token `connected`.
    Anything unrecognized is refused — an unknown status is NOT "up".
    """
    text = raw or ""
    value = ""
    for line in text.splitlines():
        low_line = line.strip().lower()
        if low_line.startswith("status update:"):
            value = low_line.split(":", 1)[1].strip()
        elif low_line.startswith("status:"):
            value = low_line.split(":", 1)[1].strip()
    if not value:
        # No explicit status line: fall back to the whole blob, but still
        # require the strict positive + no-negative rule below.
        value = text.strip().lower()
    if not value:
        return False
    for neg in _WARP_STATUS_NEGATIVE:
        if neg in value:
            return False
    # Require the exact connected token. Accept `connected` possibly followed
    # by punctuation/whitespace, but reject e.g. `connected: false` (already
    # caught by the negative scan above).
    tok = value.strip().strip(".").strip()
    return tok == "connected" or tok.startswith("connected ") \
        or tok.startswith("connected.")


# Tri-state classification of a registration/account probe.
_WARP_REG_ENROLLED = "enrolled"
_WARP_REG_NOT_ENROLLED = "not_enrolled"   # EXPLICIT negative — terminal
_WARP_REG_UNKNOWN = "unknown"             # uninformative — may try fallback


def _warp_registration_state(raw: str) -> str:
    """Tri-state parse of registration/account output (fail-closed).

    Returns one of:
      - `_WARP_REG_ENROLLED`     a concrete identity label carries a
                                 non-empty, non-negative value AND no negative
                                 token is present anywhere.
      - `_WARP_REG_NOT_ENROLLED` an EXPLICIT negative token is present
                                 (`Device unregistered`, `Status: Revoked`,
                                 `Missing registration`, …). This is a
                                 definitive "not enrolled" and is TERMINAL —
                                 the caller must NOT let a later fallback probe
                                 override it.
      - `_WARP_REG_UNKNOWN`      empty / CLI-error / no recognizable token. The
                                 modern verb may be unavailable on an old
                                 client — the caller MAY try the legacy
                                 `account` verb in this case only.

    Non-empty output alone is never enrollment.
    """
    text = (raw or "").strip()
    if not text:
        return _WARP_REG_UNKNOWN
    low = text.lower()
    # An explicit negative anywhere in the blob is definitive + terminal.
    for neg in _WARP_REG_NEGATIVE:
        if neg in low:
            return _WARP_REG_NOT_ENROLLED
    # A summary status/registration label carrying a negative value (e.g.
    # `Registration: false`, `Registered: no`, `Status: <neg>`) is an EXPLICIT
    # not-enrolled signal — terminal, so a later `account` fallback cannot
    # override it. These summary labels are NOT in _WARP_REG_POSITIVE_LABELS
    # (their values are free-form, not a concrete identity), so they are only
    # ever read as a negative signal here, never as positive proof.
    for line in low.splitlines():
        line = line.strip()
        for slabel in _WARP_REG_SUMMARY_LABELS:
            if line.startswith(slabel) and ":" in line:
                sval = line.split(":", 1)[1].strip()
                snorm = sval.strip().strip(".,;:!?)(]['\" ").strip()
                if (not snorm) or (snorm in _WARP_REG_NEGATIVE_VALUES):
                    return _WARP_REG_NOT_ENROLLED
    saw_concrete_label = False
    for line in low.splitlines():
        line = line.strip()
        for label in _WARP_REG_POSITIVE_LABELS:
            if line.startswith(label):
                # A concrete identity label MUST carry a `label: <value>`
                # where <value> is non-empty AND is not itself a negative
                # token. `Account type:` (empty) / `Organization: none` /
                # `Device id: false` are NOT enrollment.
                if ":" not in line:
                    continue
                saw_concrete_label = True
                val = line.split(":", 1)[1].strip()
                # Normalize terminal punctuation before the negative-value
                # match so `false.` / `n/a.` / `-.` cannot slip past the
                # exact-token compare. Internal characters are preserved so a
                # real value is not mangled.
                norm = val.strip().strip(".,;:!?)(]['\" ").strip()
                if norm and norm not in _WARP_REG_NEGATIVE_VALUES:
                    return _WARP_REG_ENROLLED
    # A CONCRETE identity label appeared but every occurrence carried an empty
    # or negative value (e.g. `Account type: false`, `Device ID: -`). That is
    # an EXPLICIT not-enrolled signal — terminal, never "uninformative" — so a
    # later `account` fallback cannot override it (codex r6 fail-open).
    if saw_concrete_label:
        return _WARP_REG_NOT_ENROLLED
    # No concrete enrollment field and no explicit negative → uninformative
    # (e.g. an old client whose modern verb is unsupported).
    return _WARP_REG_UNKNOWN


def _warp_registration_is_enrolled(raw: str) -> bool:
    """Convenience bool wrapper over `_warp_registration_state` — True only on
    a definitive ENROLLED classification."""
    return _warp_registration_state(raw) == _WARP_REG_ENROLLED


def warp_connected_and_enrolled() -> None:
    """Prove WARP is currently CONNECTED and REGISTERED/ENROLLED.

    Returns None on proof; raises CloudflareWarpUnavailable otherwise. This
    is the WARP analogue of "Tailscale is up and this node is in the
    tailnet". It runs two independent WARP CLI queries:

      1. `warp-cli status` must report a Connected status. A disconnected /
         connecting / unable-to-connect status is a HARD refusal — we never
         bind a Mesh IP while WARP is down (the IP would be stranded /
         spoofable on the local segment).
      2. `warp-cli --accept-tos registration show` (modern) or
         `warp-cli account` (older) must show a registration/account, i.e.
         the device is enrolled in the org. An unregistered device is
         refused — an un-enrolled WARP install is not a trusted Mesh member.

    `BRIDGE_A2A_WARP_CLI` (set by the smoke) points these at a mock CLI so
    connected/disconnected can be simulated without a real WARP install. An
    empirical probe blocked by "WARP not installed" (resolve_warp_cli()
    returns None) fails closed here, it does NOT pass.
    """
    cli = resolve_warp_cli()
    if cli is None:
        raise CloudflareWarpUnavailable(
            "the 'warp-cli' CLI was not found on PATH or in any standard "
            "install location — cannot prove WARP is connected/enrolled. "
            "Install the Cloudflare One client, set BRIDGE_A2A_WARP_CLI to "
            "the warp-cli path, or use the Tailscale transport."
        )

    status = _run_warp_cli(cli, ["status"])
    if not _warp_status_is_connected(status):
        raise CloudflareWarpUnavailable(
            "WARP is not connected ('warp-cli status' did not report an "
            "exact Connected state) — refusing to bind a Mesh IP while the "
            "WARP tunnel is down (fail-closed)."
        )

    # Registration/enrollment proof. Try the modern verb first; the legacy
    # `account` verb is a fallback ONLY when the modern verb is UNINFORMATIVE
    # (old client / CLI error / unrecognized output). An EXPLICIT negative
    # from the modern verb ("Device unregistered", "Status: Revoked", …) is
    # DEFINITIVE and TERMINAL — we must not let a contradictory `account`
    # fallback override a proven-not-enrolled result (fail-closed on
    # contradictory probes). Proof is a POSITIVE enrollment token, never
    # merely "non-empty output".
    # Classify the RAW CLI output (stdout+stderr) regardless of exit code via
    # _warp_cli_capture — never a wrapper-prefixed exception string — so an
    # explicit negative printed on a NON-ZERO exit (e.g. "Account type: false"
    # / "Device unregistered" on stderr) is classified as a TERMINAL
    # not-enrolled, not hidden behind a `'warp-cli ... exited N:' ` prefix that
    # the line-anchored classifier would miss (codex r5/r7 fail-open). The
    # legacy `account` fallback runs ONLY when the modern verb is genuinely
    # UNINFORMATIVE: the binary could not run (`ran` False), or it ran but
    # produced no concrete/negative enrollment signal (e.g. an old client's
    # "unrecognized subcommand").
    ran, reg, rc = _warp_cli_capture(cli, ["--accept-tos", "registration", "show"])
    state = _warp_registration_state(reg) if ran else _WARP_REG_UNKNOWN
    # Fail-closed rc gate (#1595 patch-dev re-review): a POSITIVE enrollment
    # conclusion REQUIRES the probe to have EXITED 0. A nonzero exit that still
    # prints a positive-looking label (e.g. exit 17 + "Organization: …" while
    # stderr reports the registration service is unavailable) must NOT prove
    # enrollment — downgrade it to UNKNOWN so we fall back to the legacy verb
    # and, failing a clean positive there, fail closed. An explicit NEGATIVE on
    # a nonzero exit stays TERMINAL (handled in _warp_registration_state), and
    # rc==0 positives are honored exactly as before.
    if state == _WARP_REG_ENROLLED and rc != 0:
        state = _WARP_REG_UNKNOWN
    if state == _WARP_REG_UNKNOWN:
        # Modern verb uninformative — try the legacy `account` verb.
        ran, reg, rc = _warp_cli_capture(cli, ["account"])
        state = _warp_registration_state(reg) if ran else _WARP_REG_UNKNOWN
        if state == _WARP_REG_ENROLLED and rc != 0:
            state = _WARP_REG_UNKNOWN
    if state != _WARP_REG_ENROLLED:
        raise CloudflareWarpUnavailable(
            "WARP device is not registered/enrolled (no positive enrollment "
            "token shown by 'warp-cli registration show' / 'warp-cli "
            "account') — an un-enrolled device is not a trusted Mesh member "
            "(fail-closed)."
        )


# The WARP CLI subcommand whose output carries the live MASQUE handshake age.
# On a real client the `Time since last handshake: <N>s` line is printed by
# `warp-cli tunnel stats` (NOT `warp-cli status`, which only shows a coarse
# Connected/Network line and can falsely report `Connected` while the tunnel is
# silently stale — the #1706 failure mode). We probe `tunnel stats` for the age
# and scan its WHOLE output so a client that prints the line under `status`
# instead is still handled.
_WARP_HANDSHAKE_LABEL = "time since last handshake"


def _parse_warp_handshake_age(text: str) -> Optional[int]:
    """Parse `Time since last handshake: <N>s` -> N (seconds), or None.

    Scans every line for the handshake-age label (case-insensitive) and reads
    the leading integer-seconds value after the colon (tolerating a trailing
    `s` / `sec` / `seconds` unit and surrounding whitespace). Returns None when
    no parseable age line is present (an UNKNOWABLE age — the caller fails
    closed without bouncing). Never raises.
    """
    for line in (text or "").splitlines():
        low = line.strip().lower()
        if not low.startswith(_WARP_HANDSHAKE_LABEL):
            continue
        if ":" not in low:
            continue
        raw = low.split(":", 1)[1].strip()
        # Keep the leading run of digits ("3153s" -> "3153"); a non-digit (the
        # unit, a space, punctuation) terminates the value. A line with no
        # leading digit (e.g. "Time since last handshake: never") yields None.
        digits = ""
        for ch in raw:
            if ch.isdigit():
                digits += ch
            else:
                break
        if digits:
            try:
                return int(digits)
            except ValueError:
                return None
    return None


def warp_tunnel_handshake_age() -> Optional[int]:
    """Return the WARP MASQUE tunnel handshake age in seconds, or None.

    Runs `warp-cli tunnel stats` (read-only) and parses the
    `Time since last handshake: <N>s` line. This is the freshness signal that
    distinguishes a genuinely-live tunnel from the #1706 silent-stale failure
    mode where `warp-cli status` keeps reporting `Connected` while established
    sessions RST (handshake age e.g. 3153s) after a network change.

    Returns:
      - the integer handshake age in seconds when the line is present,
      - None when the age could not be determined (CLI missing/errored, or the
        output carried no parseable handshake line) — an UNKNOWABLE age. The
        caller treats None as NOT-fresh (fail-closed) but MUST NOT auto-bounce
        on a None (a probe-parse failure is not a proven stale handshake).

    Read-only: never mutates WARP state. `BRIDGE_A2A_WARP_CLI` (set by the
    smoke) points this at a mock CLI so a fresh/stale tunnel can be simulated
    without a real WARP install.
    """
    cli = resolve_warp_cli()
    if cli is None:
        return None
    try:
        ran, raw, rc = _warp_cli_capture(cli, ["tunnel", "stats"])
    except Exception:  # noqa: BLE001 - a freshness probe never raises into the reconcile tick
        return None
    if not ran:
        return None
    # Fail-closed rc gate (mirrors the #1595 enrollment rc gate): a PROVEN
    # handshake age REQUIRES the probe to have EXITED 0. A non-zero exit whose
    # output still happens to carry a `Time since last handshake: <N>s` line
    # (a failed/partial `tunnel stats` printing a stale leftover) must NOT be
    # trusted as a proven age — it is UNKNOWABLE. Returning None here keeps the
    # adapter fail-safe: an unknowable age re-probes WITHOUT auto-bouncing (only
    # a proven stale handshake from a successful probe may bounce).
    if rc != 0:
        return None
    return _parse_warp_handshake_age(raw)


def _parse_ifconfig_addresses(text: str) -> list[str]:
    """Pull every `inet`/`inet6` address out of `ifconfig -a` output.

    Cross-platform over the macOS and Linux ifconfig formats:
      macOS: `\tinet 100.96.0.5 netmask 0xff000000 ...`
      Linux: `        inet 100.96.0.5  netmask 255.0.0.0 ...`
    IPv6 addresses may carry a `%scope` zone suffix which is stripped.
    """
    addrs: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not (line.startswith("inet ") or line.startswith("inet6 ")):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        cand = parts[1].split("%", 1)[0]
        addrs.append(cand)
    return addrs


def _parse_ip_addr_addresses(text: str) -> list[str]:
    """Pull addresses out of `ip -o addr show` output (Linux).

    Each line looks like:
      `3: warp0    inet 100.96.0.5/32 scope global warp0\\       ...`
    We take the token after `inet`/`inet6` and strip the prefix length.
    """
    addrs: list[str] = []
    for raw_line in text.splitlines():
        toks = raw_line.split()
        for i, tok in enumerate(toks):
            if tok in ("inet", "inet6") and i + 1 < len(toks):
                cand = toks[i + 1].split("/", 1)[0].split("%", 1)[0]
                addrs.append(cand)
    return addrs


def local_interface_addresses() -> list[str]:
    """Return every IP currently assigned to a local interface on THIS host.

    Used by the Cloudflare/WARP bind proof to confirm a candidate bind IP is
    actually present on a real local interface (not merely CIDR-shaped). The
    enumeration shells out to the OS so it reflects live kernel state:
      - `ip -o addr show` (Linux iproute2), else
      - `ifconfig -a`     (macOS + BSD + older Linux).

    `BRIDGE_A2A_IFACE_ADDRS` overrides enumeration entirely with a
    comma/whitespace-separated list — this lets the smoke simulate "the Mesh
    IP IS / IS NOT on a local interface" without touching real interfaces.
    Raises A2AError (code `iface_enum_failed`) when the address set cannot be
    determined at all — the caller fails closed rather than guessing.
    """
    override = os.environ.get("BRIDGE_A2A_IFACE_ADDRS")
    if override is not None:
        out: list[str] = []
        for tok in override.replace(",", " ").split():
            tok = tok.split("%", 1)[0].split("/", 1)[0].strip()
            if tok:
                out.append(tok)
        return out

    # Prefer iproute2 on Linux; fall back to ifconfig (macOS/BSD/old Linux).
    ip_cli = shutil.which("ip")
    if ip_cli:
        try:
            res = subprocess.run(
                [ip_cli, "-o", "addr", "show"],
                capture_output=True, text=True, timeout=5,
            )
            if res.returncode == 0 and res.stdout.strip():
                return _parse_ip_addr_addresses(res.stdout)
        except (subprocess.SubprocessError, OSError):
            pass
    ifconfig_cli = shutil.which("ifconfig") or "/sbin/ifconfig"
    try:
        res = subprocess.run(
            [ifconfig_cli, "-a"],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise A2AError(
            f"cannot enumerate local interface addresses (no usable 'ip' or "
            f"'ifconfig'): {exc}",
            code="iface_enum_failed",
        ) from exc
    if res.returncode != 0:
        raise A2AError(
            f"'ifconfig -a' exited {res.returncode}: "
            f"{(res.stderr or '').strip()[:200]} — cannot enumerate local "
            "interface addresses.",
            code="iface_enum_failed",
        )
    return _parse_ifconfig_addresses(res.stdout)


def is_local_interface_address(addr: str, local_addrs: list[str]) -> bool:
    """True only if `addr` is assigned to one of this host's interfaces.

    `local_addrs` is the exact output of `local_interface_addresses()`.
    Comparison is by normalized `ipaddress` value (so `::1` == `0:0:0:0:0:0:0:1`
    and a zero-padded IPv4 still matches). There is deliberately NO
    CIDR-shape fallback: being inside a Mesh CIDR does not prove the IP is on
    a local interface.
    """
    try:
        want = ipaddress.ip_address(addr.strip())
    except ValueError:
        return False
    for cand in local_addrs:
        try:
            if ipaddress.ip_address(cand.strip()) == want:
                return True
        except ValueError:
            continue
    return False


def prove_warp_mesh_local_bind(candidate: str) -> None:
    """Fail-closed proof that `candidate` is a bindable WARP-Mesh local IP.

    Raises A2AError / CloudflareWarpUnavailable on ANY uncertainty; returns
    None only when BOTH:
      1. the candidate is assigned to a real local interface right now, AND
      2. WARP is connected + registered/enrolled.

    Refuses (by virtue of the checks layered in `resolve_bind` plus this
    function): wildcard, loopback, an IP not on any local interface, WARP
    disconnected, WARP unregistered, or a CIDR-only guess. This is the WARP
    counterpart to the Tailscale `is_tailnet_address(bind, tailscale ip)`
    membership proof and must reach the REAL probe (interfaces + WARP CLI),
    never a shape check.
    """
    # (1) interface assignment — proven from live OS state.
    local_addrs = local_interface_addresses()
    if not is_local_interface_address(candidate, local_addrs):
        raise A2AError(
            f"bind address {candidate!r} is not assigned to any local "
            f"interface ({local_addrs or 'none'}). A WARP-Mesh bind must be "
            "a real local Mesh/device IP, not a CIDR-shaped guess "
            "(fail-closed).",
            code="bind_not_warp_local",
        )
    # (2) WARP connected + enrolled — proven from the WARP CLI.
    warp_connected_and_enrolled()


# --------------------------------------------------------------------------
# Stable substrate-address detection (#1705 — the reconcile stable-addr seam)
# --------------------------------------------------------------------------
#
# The reconcile control-loop's `stable-addr` step (bridge_reconcile_common.py:
# stable_local_addr) calls one of these per-transport detectors to discover the
# node's STABLE listen address — the address that does NOT drift as the host
# moves networks (the live drift `en0 10.11.10.211 → 172.20.10.3` that #1705
# automates away). These are DETECTORS only: they NEVER bind. `resolve_bind()`
# in bridge-handoffd.py stays the single bind oracle; the reconcile step uses
# the detected address purely to PROPOSE a desired `listen.address`.
#
# Both detectors are FAIL-CLOSED and mirror the receiver bind-proof posture:
# they return ONLY an address that is real for the substrate right now (a
# Tailscale IP from `tailscale ip`, or a WARP Mesh IP that is BOTH in the
# Cloudflare CGNAT block AND assigned to a live local interface). There is no
# CIDR-shape / bare-text guess: the WARP path reuses `local_interface_addresses`
# (hardened OS inspection) exactly as the bind proof does. On ANY uncertainty
# they raise (TailscaleUnavailable / A2AError) so the caller fails closed.

# Cloudflare WARP-Mesh assigns each enrolled device a stable IPv4 in the
# Cloudflare CGNAT block 10.128.0.0/16 (the utun/Mesh address), plus a
# point-to-point IPv6 in 2606:4700::/32. The IPv4 utun address is the PRIMARY
# stable locator (it hit all 5 live CRM_DEV nodes); the IPv6 is accepted as a
# documented secondary. These ranges are used ONLY to FILTER the live
# interface-address set — membership in the range is necessary but NOT
# sufficient (the address must also be on a real local interface), exactly
# mirroring `prove_warp_mesh_local_bind`'s "CIDR shape is not proof" rule.
WARP_MESH_CGNAT_CIDR_V4 = "10.128.0.0/16"
WARP_MESH_CLOUDFLARE_CIDR_V6 = "2606:4700::/32"


def tailscale_local_addresses() -> list[str]:
    """Return THIS node's own Tailscale IPs (the stable, identity-keyed set).

    Runs `tailscale ip` via the shared `resolve_tailscale_cli()` discovery so
    the reconcile stable-addr detector reads the SAME address set the receiver
    bind proof binds against (bridge-handoffd.py:tailscale_addresses /
    is_tailnet_address). A Tailscale node is identity-keyed, so this set is
    stable by construction — the detector just SURFACES it.

    Raises TailscaleUnavailable when the CLI cannot be located or the query
    fails (the caller fails closed rather than guessing from a CIDR shape). An
    empty list (CLI ran fine but the node has no Tailscale address yet) is
    returned as `[]`.
    """
    cli = resolve_tailscale_cli()
    if cli is None:
        raise TailscaleUnavailable(
            "the 'tailscale' CLI was not found on PATH or in any standard "
            "install location — cannot surface the node's stable Tailscale "
            "address. Install Tailscale or set BRIDGE_A2A_TAILSCALE_CLI."
        )
    try:
        out = subprocess.run(
            [cli, "ip"],
            capture_output=True, text=True, timeout=5,
        )
    except FileNotFoundError as exc:
        raise TailscaleUnavailable(
            f"the 'tailscale' CLI path {cli!r} does not exist or is not "
            "executable — cannot surface the node's stable Tailscale address."
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


def tailscale_stable_addr() -> str:
    """Surface the node's stable Tailscale IPv4 (fail-closed).

    Returns the first IPv4 in `tailscale_local_addresses()` — the legacy/raw
    `listen.address` form the receiver binds against. Falls back to the first
    address of any family only if no IPv4 is present (an IPv6-only tailnet).
    Raises TailscaleUnavailable when the CLI is unavailable; raises A2AError
    (`stable_addr_none`) when the CLI ran fine but the node has NO Tailscale
    address yet (fail-closed — never invent one).
    """
    addrs = tailscale_local_addresses()
    for addr in addrs:
        try:
            if isinstance(ipaddress.ip_address(addr), ipaddress.IPv4Address):
                return addr
        except ValueError:
            continue
    # No IPv4 — accept the first valid address of any family (IPv6-only node).
    for addr in addrs:
        try:
            ipaddress.ip_address(addr)
            return addr
        except ValueError:
            continue
    raise A2AError(
        "'tailscale ip' returned no usable address — the node has no stable "
        "Tailscale address yet (fail-closed; never invent one).",
        code="stable_addr_none",
    )


def warp_mesh_stable_addr() -> str:
    """Detect the node's stable WARP-Mesh local address (fail-closed).

    Enumerates the LIVE local interface set via `local_interface_addresses()`
    (hardened OS inspection — `ip`/`ifconfig`, never a bare awk/text guess) and
    returns the first address that is BOTH (a) inside the Cloudflare CGNAT
    block 10.128.0.0/16 (the utun/Mesh IPv4) AND (b) assigned to a real local
    interface right now. The Cloudflare point-to-point IPv6 (2606:4700::/32) is
    accepted as a documented secondary only when no IPv4 utun address exists.

    Membership in the CIDR is NECESSARY but NOT SUFFICIENT — the address is
    only returned because it appears in the live interface set, exactly
    mirroring `prove_warp_mesh_local_bind`'s "CIDR shape is not proof" rule. So
    the returned address is ALWAYS one actually present on a local interface.

    Raises A2AError (`iface_enum_failed`) when the interface set cannot be
    determined at all, or (`stable_addr_none`) when no WARP-Mesh address is
    present on any local interface (fail-closed — never synthesize one).
    """
    local_addrs = local_interface_addresses()
    v4_net = ipaddress.ip_network(WARP_MESH_CGNAT_CIDR_V4)
    v6_net = ipaddress.ip_network(WARP_MESH_CLOUDFLARE_CIDR_V6)

    # Primary: a utun/Mesh IPv4 in the Cloudflare CGNAT block that is on a real
    # local interface. Preserve interface-enumeration order for determinism.
    for cand in local_addrs:
        try:
            ip = ipaddress.ip_address(cand.strip())
        except ValueError:
            continue
        if isinstance(ip, ipaddress.IPv4Address) and ip in v4_net:
            return str(ip)
    # Secondary: the Cloudflare point-to-point IPv6, only if no IPv4 utun exists.
    for cand in local_addrs:
        try:
            ip = ipaddress.ip_address(cand.strip())
        except ValueError:
            continue
        if isinstance(ip, ipaddress.IPv6Address) and ip in v6_net:
            return str(ip)
    raise A2AError(
        "no WARP-Mesh stable address is present on any local interface "
        f"(local set: {local_addrs or 'none'}). A WARP node's stable address "
        "is its utun/Mesh IP in 10.128.0.0/16 (or the Cloudflare 2606:4700::/32 "
        "IPv6); refusing to synthesize one from a CIDR shape (fail-closed).",
        code="stable_addr_none",
    )


def resolve_peer_address_for_transport(
    kind: str, entry: dict[str, Any]) -> str:
    """Transport-aware peer/`listen` address resolution.

    The single seam the sender target resolution AND the receiver source
    proof go through so they never diverge on how an address is produced
    per transport:

      - "tailscale" (default): delegates to `resolve_peer_address` UNCHANGED
        (node_id / tailscale_name live-resolve, else literal `address`).
      - "cloudflare-warp-mesh": the peer is keyed on its raw Mesh/device IP
        in `address`. Tailscale identity keys (`node_id`/`tailscale_name`)
        are a MISCONFIGURATION for this transport and are rejected (we never
        silently run `tailscale status` for a WARP peer). The returned
        address is validated as a real IP literal — that literal is then
        compared against `remote_addr` by the receiver's existing
        source-address check, exactly as for a legacy raw-IP Tailscale peer.

    This does NOT replace any app-layer auth: HMAC, dedupe, allowlist, skew
    and room_scoped_check remain layered on top of (never instead of) this
    address check.
    """
    if not isinstance(entry, dict):
        raise A2AError("address entry must be an object", code="resolve_shape")
    if kind == TRANSPORT_CLOUDFLARE_WARP_MESH:
        node_id = entry.get("node_id")
        ts_name = entry.get("tailscale_name")
        if (isinstance(node_id, str) and node_id.strip()) or (
                isinstance(ts_name, str) and ts_name.strip()):
            raise A2AError(
                "a cloudflare-warp-mesh peer/listen entry must key on a raw "
                "Mesh/device 'address', not a Tailscale node_id/"
                "tailscale_name. Remove the Tailscale identity keys.",
                code="warp_identity_misconfig",
            )
        address = entry.get("address", "")
        if not isinstance(address, str):
            raise A2AError("'address' must be a string", code="resolve_shape")
        address = address.strip()
        if address:
            try:
                ipaddress.ip_address(address)
            except ValueError as exc:
                raise A2AError(
                    f"cloudflare-warp-mesh 'address' {address!r} is not an "
                    f"IP literal: {exc}",
                    code="resolve_not_ip",
                ) from exc
        return address
    # Default: the unchanged Tailscale resolver (raw-IP back-compat included).
    return resolve_peer_address(entry)


# --------------------------------------------------------------------------
# Reverse resolution: a raw Tailscale IP -> the node that owns it.
# --------------------------------------------------------------------------
#
# The forward resolver (`resolve_peer_address`) maps a stored identity to the
# live IP. The MIGRATION direction is the inverse: given a config entry that
# still carries only a raw `address`, find the Tailscale node whose
# `TailscaleIPs` contains that literal IP, so we can record its stable
# identity (StableID + HostName/MagicDNS name). This shares the SAME
# `tailscale status --json` parse as the forward resolver so sender, receiver,
# and migrate never diverge on how the tailnet is read.


def _node_owns_ip(node: dict[str, Any], ip: str) -> bool:
    """True if `ip` is one of the node's TailscaleIPs (exact, trimmed match)."""
    want = ip.strip()
    if not want:
        return False
    ips = node.get("TailscaleIPs")
    if isinstance(ips, list):
        for cand in ips:
            if isinstance(cand, str) and cand.strip() == want:
                return True
    return False


def node_name(node: dict[str, Any]) -> str:
    """Best human/MagicDNS name for a node: full DNSName, else short HostName.

    Returns the MagicDNS FQDN with any trailing dot stripped (so it round-trips
    cleanly through `_name_matches`), falling back to the short HostName. Empty
    string if neither is present.
    """
    dns = str(node.get("DNSName", "")).strip().rstrip(".")
    if dns:
        return dns
    return str(node.get("HostName", "")).strip().rstrip(".")


def nodes_owning_ip(status: dict[str, Any], ip: str) -> list[dict[str, Any]]:
    """All Self/Peer nodes from a status doc whose TailscaleIPs contain `ip`.

    Returns 0, 1, or >1 nodes. The migration treats:
      - 0 matches  -> stale/offline IP, leave untouched (do NOT guess);
      - 1 match    -> unambiguous, safe to identity-key;
      - >1 matches -> ambiguous, leave untouched (do NOT guess).
    Pure parse over the caller-supplied status document — performs no
    subprocess of its own, so a single `tailscale_status_json()` call can be
    reused across every peer + the listen entry.
    """
    return [node for node in _status_nodes(status) if _node_owns_ip(node, ip)]


def reverse_resolve_ip(
    status: dict[str, Any], ip: str,
) -> Optional[tuple[str, str]]:
    """Map a raw Tailscale IP to (node_id, node_name) iff exactly one node owns it.

    Returns None on zero matches OR multiple matches (the ambiguous case) —
    the caller MUST treat None as "leave the entry untouched, do not guess".
    `node_name` may be "" if the matched node has no HostName/DNSName; the
    caller can still record `node_id` (the StableID) in that case.
    """
    matches = nodes_owning_ip(status, ip)
    if len(matches) != 1:
        return None
    node = matches[0]
    node_id = str(node.get("ID", "")).strip()
    return node_id, node_name(node)


# --------------------------------------------------------------------------
# HMAC signing
# --------------------------------------------------------------------------

def body_sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def canonical_string(
    method: str,
    path: str,
    peer_id: str,
    message_id: str,
    timestamp: str,
    body_hash: str,
) -> str:
    """Newline-delimited canonical request string fed to HMAC."""
    return "\n".join([method.upper(), path, peer_id, message_id, timestamp, body_hash])


def sign(secret: str, canonical: str) -> str:
    digest = hmac.new(secret.encode("utf-8"), canonical.encode("utf-8"), hashlib.sha256)
    return SIGNATURE_PREFIX + digest.hexdigest()


def verify_signature(
    secrets: list[str],
    canonical: str,
    presented: str,
) -> bool:
    """Constant-time verify against any accepted secret (current/next)."""
    if not presented.startswith(SIGNATURE_PREFIX):
        return False
    for secret in secrets:
        expected = sign(secret, canonical)
        if hmac.compare_digest(expected, presented):
            return True
    return False


def new_message_id(sender_bridge: str) -> str:
    return f"{sender_bridge}:{uuid.uuid4()}"


def now_ts() -> int:
    return int(time.time())


# --------------------------------------------------------------------------
# Room-join token-bootstrap key derivation (A2A Rooms v0.16.5 Lane 4, #1695)
# --------------------------------------------------------------------------
#
# The zero-touch room-join path derives a UNIQUE per-pair node-link HMAC key
# from the room invite token, with strict DOMAIN SEPARATION so the wire-visible
# token verifier (`sha256(token)`, transmitted in the join body) can NEVER be
# turned into the HMAC key:
#
#   key_seed = HKDF-Extract(salt="a2a-room-pair-seed-v1", ikm=raw_invite_token)
#   pair_key = HKDF-Expand(key_seed, info="a2a-room-pair-key-v1\n<room>\n
#                          <leader_node>\n<joiner_node>", L=32)
#
# The JOINER holds the raw invite token (it is in the invite link) → derives the
# key_seed → derives the pair_key. The LEADER never holds the raw token (the
# wire carries only sha256(token)); it persists the key_seed in controller-owned
# rooms state at invite-creation time and derives the SAME pair_key from the
# stored seed. Because Extract is one-way (HMAC), the wire-visible token HASH
# (sha256) is NOT the seed and cannot reconstruct it — that is the domain
# separation the adversarial test "token-hash-as-key rejected" proves.
#
# RFC 5869 (HKDF) instantiated with HMAC-SHA256: Extract puts the domain label
# in the salt position; Expand binds the room/leader/joiner identity in `info`
# so a pair key is unique per (room, leader, joiner) ordered triple and cannot
# be replayed against a different room or peer.

_ROOM_PAIR_SEED_SALT = b"a2a-room-pair-seed-v1"
_ROOM_PAIR_KEY_INFO = b"a2a-room-pair-key-v1"
_ROOM_INVITE_SIG_SALT = b"a2a-room-invite-sig-v1"


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    """RFC 5869 HKDF-Extract (HMAC-SHA256). Returns the 32-byte PRK."""
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 HKDF-Expand (HMAC-SHA256). `length` <= 32 (one block)."""
    if length > hashlib.sha256().digest_size:
        raise A2AError("hkdf_expand length exceeds one HMAC-SHA256 block",
                       code="hkdf_length")
    t = hmac.new(prk, info + b"\x01", hashlib.sha256).digest()
    return t[:length]


def room_pair_key_seed(raw_token: str) -> str:
    """Derive the secret-equivalent key SEED from the raw invite token.

    This is the controller-owned, leader-stored material (NOT the wire-visible
    `sha256(token)` verifier). Returned as a hex string for JSON-safe storage in
    rooms.db invite state while the invite is valid.
    """
    seed = hkdf_extract(_ROOM_PAIR_SEED_SALT, raw_token.encode("utf-8"))
    return seed.hex()


def room_pair_key_from_seed(key_seed_hex: str, *, room_id: str,
                            leader_node: str, joiner_node: str) -> str:
    """Derive the per-pair node-link HMAC key from the stored key SEED.

    Both sides call this with the SAME seed (the leader reads it from rooms
    state; the joiner re-derives it from the raw token via `room_pair_key_seed`)
    and the SAME (room, leader_node, joiner_node) triple, so they agree on the
    key. The returned hex string is what gets persisted as the peer `secret`.
    """
    prk = bytes.fromhex(key_seed_hex)
    info = b"\n".join([
        _ROOM_PAIR_KEY_INFO,
        room_id.encode("utf-8"),
        leader_node.encode("utf-8"),
        joiner_node.encode("utf-8"),
    ])
    return hkdf_expand(prk, info, 32).hex()


def room_pair_key_from_token(raw_token: str, *, room_id: str,
                             leader_node: str, joiner_node: str) -> str:
    """Joiner-side convenience: raw token → seed → per-pair key (hex)."""
    return room_pair_key_from_seed(
        room_pair_key_seed(raw_token), room_id=room_id,
        leader_node=leader_node, joiner_node=joiner_node)


# --------------------------------------------------------------------------
# Signed invite locator (reach=) — A2A Rooms v0.16.5 Lane 4, agenda 6
# --------------------------------------------------------------------------
#
# The invite link embeds a `reach=` transport locator so a joiner with NO
# pre-existing node-link can direct its first room-join request at the leader.
# `reach=` carries NO secret — only {kind, address, port}. The leader binds
# `reach=` (and the leader/room/token identity + an `iat`/`ttl`/`nonce` freshness
# tuple) into a SIGNED CANONICAL whose MAC key is derived from the RAW TOKEN.
#
# Integrity scope — be honest (SK-1): the signing key is derived from the raw
# token, which is the `t=` bearer in the SAME link. So the signature proves
# integrity ONLY against a BLIND on-path tamperer who does NOT hold the token.
# It does NOT provide relay-resistance: any party that RELAYS or OBSERVES the
# link already holds the token and could re-sign a tampered `reach=`. The
# concrete, enforced guarantees a joiner gets are therefore the LINK TTL
# (`iat + ttl < now → reject`) and the single-use `nonce` (recorded + replay-
# rejected joiner-side) — NOT relay-resistance. Crucially, NONE of this is an
# admission gate: the leader re-runs token TTL/revocation + `client_ip` ==
# registered-addr + per-pair HMAC + leader-approval regardless of `reach=`, so a
# `reach=` forgery is at worst a first-contact transport redirect (phishing/DoS),
# never a room-admission bypass. (Future hardening for true relay-resistance:
# sign the locator with the leader's node-link identity key, which a relayer
# does not hold — tracked as a follow-up, not solved here.)

def invite_canonical(*, version: str, room_id: str, leader_node: str,
                     leader_bridge: str, reach: dict[str, Any],
                     token_sha256: str, issued_ts: int, ttl: int,
                     nonce: str) -> str:
    """Deterministic JSON canonical of the signed invite payload.

    NO secret rides here — `reach` is {kind, address, port}; the bearer token
    itself is represented only by its verifier hash (`token_sha256`). Keys are
    sorted so the leader and every joiner recompute byte-identical bytes. See
    the section header for the (deliberately narrow) integrity scope: token-keyed
    integrity vs a blind tamperer, NOT relay-resistance.
    """
    payload = {
        "v": version,
        "room_id": room_id,
        "leader_node": leader_node,
        "leader_bridge": leader_bridge,
        "reach": {
            "kind": str(reach.get("kind", "")),
            "address": str(reach.get("address", "")),
            "port": int(reach.get("port", 0) or 0),
        },
        "token_sha256": token_sha256,
        "issued_ts": int(issued_ts),
        "ttl": int(ttl),
        "nonce": nonce,
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def invite_sig_key(raw_token: str) -> bytes:
    """Derive the invite-canonical MAC key from the raw token (domain-separated
    from the pair key so the two derivations never collide)."""
    return hkdf_extract(_ROOM_INVITE_SIG_SALT, raw_token.encode("utf-8"))


def sign_invite_canonical(raw_token: str, canonical: str) -> str:
    digest = hmac.new(invite_sig_key(raw_token), canonical.encode("utf-8"),
                      hashlib.sha256)
    return SIGNATURE_PREFIX + digest.hexdigest()


def verify_invite_canonical(raw_token: str, canonical: str,
                            presented: str) -> bool:
    """Constant-time verify of a signed invite canonical against the raw token."""
    if not presented.startswith(SIGNATURE_PREFIX):
        return False
    expected = sign_invite_canonical(raw_token, canonical)
    return hmac.compare_digest(expected, presented)


# --------------------------------------------------------------------------
# TOCTOU-locked peer auto-register (A2A Rooms v0.16.5 Lane 4, #1695)
# --------------------------------------------------------------------------

def auto_register_room_peer_locked(
    cfg_path: Optional[Path], *, peer_id: str, address: str, port: int,
    secret: str, inbound_allowlist: list[str], transport: str,
) -> tuple[bool, str]:
    """Atomically add a reverse node-link peer for a token-bootstrapped room
    join, under an exclusive advisory FILE LOCK (closes the concurrent-join
    TOCTOU race a bare in-memory check + atomic rename would lose).

    The flow inside the lock mirrors `_identity_update_apply`'s safe-write
    contract but adds the lock:
      1. acquire `<cfg>.lock` (flock LOCK_EX) so concurrent unknown-peer joins
         from the same node serialize on the disk write.
      2. RELOAD the on-disk config (never the live cached one).
      3. re-check idempotence: if the peer already exists with the SAME secret,
         it is a no-op success; if it exists with a DIFFERENT secret, refuse
         (a re-derivation mismatch / conflict — never silently overwrite a key).
      4. validate the about-to-be-written config's secret gate.
      5. write atomic 0600.
    Returns (changed, code). Fail-closed: any error returns (False, code) and
    changes nothing. The daemon's reconcile/hot-reload then picks up the peer.

    NEVER trusts a wire-asserted address: the caller passes the SOCKET
    remote_addr (`client_ip`) as `address`, not a body field.
    """
    if not peer_id or not secret:
        return False, "missing_peer_or_secret"
    target_path = cfg_path or config_path()
    lock_path = target_path.with_name(target_path.name + ".lock")  # noqa: raw-pathlib-controller-only
    lock_fd = -1
    try:
        lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as exc:
        return False, f"lock_open_failed:{exc}"[:64]
    try:
        if fcntl is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
            except OSError as exc:
                return False, f"lock_acquire_failed:{exc}"[:64]
        # SK-3: when `fcntl is None` (non-POSIX), the advisory flock degrades to
        # a NO-OP — concurrent writers from the same node could then race the
        # read-modify-write below. The atomic `os.replace` still leaves a VALID
        # single-entry config (no corruption/partial write); the only loss is the
        # cross-process serialization that prevents a last-writer-wins overwrite.
        # A2A is POSIX-only in practice (Linux/macOS), so `fcntl` is always
        # present on a real deployment and this branch is a defensive fallback.
        # 2. reload from disk under the lock.
        try:
            disk_cfg = load_config(target_path)
        except A2AError as exc:
            return False, getattr(exc, "code", "config_load_failed")
        peers = disk_cfg.get("peers")
        if not isinstance(peers, list):
            return False, "config_shape"
        # 3. idempotence / conflict re-check.
        for p in peers:
            if isinstance(p, dict) and p.get("id") == peer_id:
                existing = peer_secrets(p)
                if secret in existing:
                    return False, "noop"  # already provisioned (idempotent)
                return False, "peer_conflict"  # different secret — never clobber
        entry: dict[str, Any] = {
            "id": peer_id,
            "address": address,
            "secret": secret,
            "inbound_allowlist": list(inbound_allowlist),
        }
        if port:
            entry["port"] = int(port)
        peers.append(entry)
        # 4. re-validate the secret gate before writing.
        try:
            validate_config_peer_secrets(disk_cfg, side="receiver")
        except A2AError as exc:
            return False, getattr(exc, "code", "secret_gate")
        try:
            orig_mode = target_path.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only
        except OSError:
            orig_mode = 0o600
        # 5. atomic 0600 write.
        try:
            write_config_atomic(target_path, disk_cfg, orig_mode)
        except OSError as exc:
            return False, f"write_failed:{exc}"[:64]
        return True, "registered"
    finally:
        if lock_fd >= 0:
            try:
                if fcntl is not None:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(lock_fd)
            except OSError:
                pass


# --------------------------------------------------------------------------
# Envelope
# --------------------------------------------------------------------------

def build_envelope(
    *,
    message_id: str,
    sender_bridge: str,
    sender_agent: str,
    target_agent: str,
    priority: str,
    title: str,
    body: str,
    reply_peer: str = "",
    reply_agent: str = "",
    room_id: str = "",
    room_epoch: Optional[int] = None,
    relayed_via: str = "",
    relayed_from_agent: str = "",
    relayed_from_node: str = "",
) -> dict[str, Any]:
    """Build the A2A enqueue envelope.

    A2A rooms P1a (design §14 R2/R6): `room_id` + `room_epoch` are OPTIONAL
    room-scope markers. They are emitted ONLY when the message is room-scoped
    (a non-empty `room_id` is supplied); a non-room message omits both fields
    entirely so a v1 envelope is byte-for-byte unchanged (back-compat). When
    present, `room_epoch` is the sender's view of the room epoch the receiver
    seam (P4) validates against the leader-MAC'd roster. P1a builds + parses
    them but does not yet enforce on the cross-node path.

    A2A rooms Lane 5 (#1695-P2 gotcha E): the leader-relay leg markers. When the
    LEADER forwards a member→member room message it builds a FRESH envelope whose
    AUTHENTICATED sender (`sender.bridge`) is the LEADER node (re-signed with the
    leader↔target pair key — so the target's `reject_sender_mismatch` passes and
    the target verifies the LEADER, never the original member). The ORIGINAL
    sender — the member the leader VOUCHES for after verifying its member→leader
    HMAC + membership — is carried as `relayed_from` {agent, node}; the target's
    room-membership gate validates THAT original sender against its cached roster
    (not the leader, who is also a member but is not the message author).
    `relayed_via=<leader_node>` is the loop-guard marker: the receiver REFUSES to
    re-relay any message already carrying it (M links, not M²). All three are
    emitted ONLY on a room-scoped relayed leg; a normal send omits them
    (byte-for-byte v1 unchanged).
    """
    env: dict[str, Any] = {
        "protocol": ENVELOPE_PROTOCOL,
        "message_id": message_id,
        "sender": {"bridge": sender_bridge, "agent": sender_agent},
        "target_agent": target_agent,
        "priority": priority,
        "title": title,
        "body": body,
        "reply_to": {
            "peer": reply_peer or sender_bridge,
            "agent": reply_agent or sender_agent,
        },
    }
    if room_id:
        env["room_id"] = room_id
        # room_epoch defaults to 0 when room-scoped but unspecified — the
        # receiver treats epoch 0 as "stale, refresh before deciding" (P4).
        env["room_epoch"] = int(room_epoch) if room_epoch is not None else 0
        if relayed_via:
            env["relayed_via"] = str(relayed_via)
            # The leader-vouched original author (a leg without an author is not a
            # valid relay; the receiver fail-closes on a missing relayed_from).
            env["relayed_from"] = {
                "agent": str(relayed_from_agent),
                "node": str(relayed_from_node),
            }
    return env


def envelope_is_relayed(env: dict[str, Any]) -> bool:
    """True iff the envelope carries the leader-relay loop-guard marker (Lane 5).

    The single predicate the relay decision keys its no-re-relay contract on, so
    the leader (which stamps it) and the relay gate (which refuses to re-relay a
    stamped message) never diverge. A non-relayed message omits the field.
    """
    rv = env.get("relayed_via")
    return isinstance(rv, str) and bool(rv)


def relayed_from(env: dict[str, Any]) -> tuple[str, str]:
    """The leader-vouched ORIGINAL (agent, node) of a relayed message (Lane 5).

    Returns ("", "") when the envelope is not a relay leg or carries a malformed
    `relayed_from`. The receiver validates THIS identity (the original author the
    leader vouched for) against its cached roster — never the relaying leader's.
    """
    rf = env.get("relayed_from")
    if not isinstance(rf, dict):
        return "", ""
    return str(rf.get("agent") or ""), str(rf.get("node") or "")


def envelope_is_room_scoped(env: dict[str, Any]) -> bool:
    """True iff the envelope carries a non-empty `room_id` (room-scoped).

    The single predicate the receiver seam keys its room-scoped fail-closed
    contract on, so the sender (build) and receiver (check) never diverge on
    what "room-scoped" means.
    """
    rid = env.get("room_id")
    return isinstance(rid, str) and bool(rid)


def parse_envelope(raw: bytes) -> dict[str, Any]:
    try:
        env = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise A2AError(f"envelope is not valid JSON: {exc}", code="bad_envelope") from exc
    if not isinstance(env, dict):
        raise A2AError("envelope root must be a JSON object", code="bad_envelope")
    if env.get("protocol") != ENVELOPE_PROTOCOL:
        raise A2AError(
            f"unsupported envelope protocol: {env.get('protocol')!r}",
            code="bad_protocol",
        )
    for field in ("message_id", "target_agent", "title", "body"):
        if not isinstance(env.get(field), str) or not env.get(field):
            raise A2AError(f"envelope missing required string field: {field}", code="bad_envelope")
    sender = env.get("sender")
    if not isinstance(sender, dict) or not sender.get("bridge") or not sender.get("agent"):
        raise A2AError("envelope.sender must carry bridge + agent", code="bad_envelope")
    priority = env.get("priority", "normal")
    if priority not in VALID_PRIORITIES:
        raise A2AError(f"invalid priority: {priority!r}", code="bad_priority")
    # A2A rooms P1a (design §14 R2/R6): OPTIONAL room scope. A v1 envelope
    # carries NEITHER field and parses unchanged (back-compat). When
    # room-scoped, `room_id` must be a non-empty string and `room_epoch` a
    # non-negative int — both validated here so a malformed room marker is
    # rejected at the wire boundary, never half-trusted downstream. Presence
    # of one without the other is a malformed envelope.
    has_room_id = "room_id" in env
    has_room_epoch = "room_epoch" in env
    if has_room_id or has_room_epoch:
        rid = env.get("room_id")
        if not isinstance(rid, str) or not rid:
            raise A2AError(
                "room-scoped envelope requires a non-empty string room_id",
                code="bad_room_scope",
            )
        if not has_room_epoch:
            raise A2AError(
                "room-scoped envelope (room_id present) requires room_epoch",
                code="bad_room_scope",
            )
        epoch = env.get("room_epoch")
        # Reject bool explicitly (bool is an int subclass) and any non-int.
        if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 0:
            raise A2AError(
                "room_epoch must be a non-negative integer",
                code="bad_room_scope",
            )
    return env


# --------------------------------------------------------------------------
# peer-identity-update control message (P-self-heal-3, design §9.6)
# --------------------------------------------------------------------------
#
# The body the sender signs + the receiver re-corroborates. It carries the
# SENDER's own identity claim (bridge_id + node StableID + MagicDNS name +
# the new TailscaleIP it believes it now has). The receiver treats EVERY
# field as untrusted — the claim only PROMPTS a re-resolution the receiver
# independently verifies against its OWN `tailscale status --json`. The
# wire-asserted `tailscale_ip` is informational/audit only; it is NEVER
# written to the peer table on the strength of the wire alone.


def build_identity_update(
    *,
    bridge_id: str,
    node_id: str = "",
    tailscale_name: str = "",
    tailscale_ip: str = "",
) -> dict[str, Any]:
    """Build the peer-identity-update control body.

    `bridge_id` is REQUIRED — it is the authenticated sender identity (what
    the receiver looks up in its peer table; it must match the signed
    X-AGB-Peer header). The identity fields (`node_id` / `tailscale_name` /
    `tailscale_ip`) are the sender's CLAIM about its own node; the receiver
    corroborates them against its own Tailscale view before applying.
    """
    return {
        "protocol": IDENTITY_UPDATE_ENVELOPE_PROTOCOL,
        "bridge_id": bridge_id,
        "node_id": node_id,
        "tailscale_name": tailscale_name,
        "tailscale_ip": tailscale_ip,
    }


def parse_identity_update(raw: bytes) -> dict[str, Any]:
    """Parse + shape-validate a peer-identity-update control body.

    Validates only the WIRE shape (it is a JSON object with the right
    protocol tag and a non-empty `bridge_id`); it does NOT trust any
    identity field — corroboration against the receiver's own tailnet view
    is the caller's job. At least one of `node_id` / `tailscale_name` must
    be present (an update with neither has nothing for the receiver to
    corroborate and would be a no-op at best).
    """
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise A2AError(
            f"identity-update is not valid JSON: {exc}", code="bad_identity_update",
        ) from exc
    if not isinstance(body, dict):
        raise A2AError(
            "identity-update root must be a JSON object", code="bad_identity_update",
        )
    if body.get("protocol") != IDENTITY_UPDATE_ENVELOPE_PROTOCOL:
        raise A2AError(
            f"unsupported identity-update protocol: {body.get('protocol')!r}",
            code="bad_identity_update_protocol",
        )
    bridge_id = body.get("bridge_id")
    if not isinstance(bridge_id, str) or not bridge_id:
        raise A2AError(
            "identity-update missing required string field: bridge_id",
            code="bad_identity_update",
        )
    node_id = body.get("node_id", "")
    ts_name = body.get("tailscale_name", "")
    ts_ip = body.get("tailscale_ip", "")
    for field, val in (("node_id", node_id),
                       ("tailscale_name", ts_name),
                       ("tailscale_ip", ts_ip)):
        if not isinstance(val, str):
            raise A2AError(
                f"identity-update field {field} must be a string",
                code="bad_identity_update",
            )
    if not node_id.strip() and not ts_name.strip():
        # Nothing to corroborate / apply — refuse rather than silently no-op.
        raise A2AError(
            "identity-update must carry at least one of node_id / "
            "tailscale_name",
            code="bad_identity_update",
        )
    return body


# --------------------------------------------------------------------------
# Cross-node room-join-request control message (A2A Rooms P4.1, design §11)
# --------------------------------------------------------------------------
#
# The body a node-B member signs (over the node-link HMAC) + the leader's node A
# receiver re-validates. It carries:
#   - room_id:          the room the joiner wants into.
#   - join_token_sha256: sha256(raw_token) — the HASH ONLY. The raw token NEVER
#                        crosses the wire (§14 R3); the leader hash-compares it
#                        against the stored `invite_token_sha256`.
#   - joiner_agent:      the joiner's agent id as attested by node B. CRITICAL
#                        (contract 2): node B MUST derive this from its local
#                        OS-actor / gateway-credential regime (resolve_os_actor),
#                        NEVER from --from / BRIDGE_AGENT_ID / USER. The node-link
#                        HMAC authenticates the NODE; the leader binds the joiner
#                        *node* to the authenticated sender bridge (NOT to any
#                        wire-asserted node field) and accepts `joiner_agent` only
#                        as that authenticated node's OS-actor-anchored attestation.
# There is deliberately NO `joiner_node` field: a wire-asserted node would be
# spoofable, so the receiver uses the HMAC-authenticated `X-AGB-Peer` as the node.


def build_room_join_request(
    *,
    room_id: str,
    join_token_sha256: str,
    joiner_agent: str,
) -> dict[str, Any]:
    """Build the cross-node room-join-request control body.

    `join_token_sha256` MUST already be the hash (the caller hashes the raw
    token with `bridge_rooms_common.hash_token` before this is built) — the raw
    token must never reach this function or the wire. `joiner_agent` MUST be the
    OS-actor-anchored agent id (see the section header), never a caller flag.
    """
    return {
        "protocol": ROOM_JOIN_ENVELOPE_PROTOCOL,
        "room_id": room_id,
        "join_token_sha256": join_token_sha256,
        "joiner_agent": joiner_agent,
    }


def parse_room_join_request(raw: bytes) -> dict[str, Any]:
    """Parse + shape-validate a cross-node room-join-request control body.

    Validates only the WIRE shape: a JSON object with the right protocol tag and
    non-empty string `room_id`, `join_token_sha256`, `joiner_agent`. The token
    hash must look like a sha256 hex digest (64 lowercase hex chars) so a
    malformed/garbage value is refused at the boundary, never half-trusted. It
    does NOT verify the token (the leader hash-compares + TTL/revocation-checks
    against rooms.db) and does NOT trust the joiner identity beyond the
    node-link auth the receiver already enforced.
    """
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise A2AError(
            f"room-join-request is not valid JSON: {exc}", code="bad_room_join",
        ) from exc
    if not isinstance(body, dict):
        raise A2AError(
            "room-join-request root must be a JSON object", code="bad_room_join",
        )
    if body.get("protocol") != ROOM_JOIN_ENVELOPE_PROTOCOL:
        raise A2AError(
            f"unsupported room-join-request protocol: {body.get('protocol')!r}",
            code="bad_room_join_protocol",
        )
    for field in ("room_id", "join_token_sha256", "joiner_agent"):
        val = body.get(field)
        if not isinstance(val, str) or not val:
            raise A2AError(
                f"room-join-request missing required string field: {field}",
                code="bad_room_join",
            )
    th = body["join_token_sha256"]
    if len(th) != 64 or any(c not in "0123456789abcdef" for c in th):
        raise A2AError(
            "room-join-request join_token_sha256 must be a sha256 hex digest",
            code="bad_room_join",
        )
    return body


# --------------------------------------------------------------------------
# Cross-node room-roster-broadcast control message (A2A Rooms P4.2, design §6/§14 R2)
# --------------------------------------------------------------------------
#
# The body a leader's node A signs (over the per-member node-link HMAC) + each
# member node re-validates. It carries the CANONICAL, leader-authoritative
# roster for one room:
#   - room_id:     the room.
#   - room_epoch:  the monotonic epoch the broadcast carries (the freshness /
#                  split-brain tiebreaker; a member ignores a lower-or-same epoch
#                  unless it is a byte-identical idempotent duplicate).
#   - members:     the roster, CANONICALLY sorted by (agent, node) — the exact
#                  bytes the leader signed; any verifier recomputes the same MAC
#                  string. Each entry is {agent, node, role}.
#   - leader_node: the node that leads the room. CRITICAL (contract 3a): the
#                  member accepts a roster ONLY when the authenticated X-AGB-Peer
#                  (the node-link sender) EQUALS this leader_node — a roster from
#                  any non-leader authenticated peer is rejected, persisting
#                  nothing. There is deliberately NO leader_agent-on-the-wire
#                  trust beyond what the roster members list itself carries.
# The leader's signature is the node-link HMAC header (X-AGB-Signature) over the
# canonical request string — the body carries no separate `sig` field because
# the pairwise HMAC over the body hash IS the per-member signature (§14 R2: one
# signature per member-link). No token, no secret ever crosses this wire.


def build_room_roster_broadcast(
    *,
    room_id: str,
    room_epoch: int,
    members: list[dict[str, Any]],
    leader_node: str,
) -> dict[str, Any]:
    """Build the cross-node room-roster-broadcast control body.

    `members` MUST already be the CANONICAL sorted roster (sorted by (agent,
    node) — `bridge_rooms_common._sorted_members` / `roster_for`). The caller
    signs the resulting body bytes with the leader-node↔member-node pairwise
    HMAC (the node-link secret) for EACH member node it broadcasts to, so a
    member cannot forge a roster for a peer whose secret it does not hold. The
    body carries NO `sig` field — the X-AGB-Signature header IS the per-link
    signature (§14 R2).
    """
    return {
        "protocol": ROOM_ROSTER_ENVELOPE_PROTOCOL,
        "room_id": room_id,
        "room_epoch": int(room_epoch),
        "members": members,
        "leader_node": leader_node,
    }


def parse_room_roster_broadcast(raw: bytes) -> dict[str, Any]:
    """Parse + shape-validate a cross-node room-roster-broadcast control body.

    Validates only the WIRE shape: a JSON object with the right protocol tag,
    non-empty string `room_id` + `leader_node`, a non-negative int `room_epoch`,
    and a `members` LIST whose every entry is an object with non-empty string
    `agent` + string `node` (+ optional string `role`). A malformed/garbage
    value is refused at the boundary, never half-trusted. It does NOT verify the
    leader-authority binding (the receiver checks the authenticated peer ==
    leader_node and the pairwise HMAC) and does NOT trust the roster beyond the
    node-link auth the receiver already enforced.
    """
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise A2AError(
            f"room-roster-broadcast is not valid JSON: {exc}",
            code="bad_room_roster",
        ) from exc
    if not isinstance(body, dict):
        raise A2AError(
            "room-roster-broadcast root must be a JSON object",
            code="bad_room_roster",
        )
    if body.get("protocol") != ROOM_ROSTER_ENVELOPE_PROTOCOL:
        raise A2AError(
            f"unsupported room-roster-broadcast protocol: {body.get('protocol')!r}",
            code="bad_room_roster_protocol",
        )
    for field in ("room_id", "leader_node"):
        val = body.get(field)
        if not isinstance(val, str) or not val:
            raise A2AError(
                f"room-roster-broadcast missing required string field: {field}",
                code="bad_room_roster",
            )
    epoch = body.get("room_epoch")
    # bool is an int subclass — reject it explicitly so `true`/`false` cannot
    # masquerade as an epoch.
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise A2AError(
            "room-roster-broadcast room_epoch must be a non-negative integer",
            code="bad_room_roster",
        )
    members = body.get("members")
    if not isinstance(members, list):
        raise A2AError(
            "room-roster-broadcast members must be a list", code="bad_room_roster",
        )
    for entry in members:
        if not isinstance(entry, dict):
            raise A2AError(
                "room-roster-broadcast member entries must be objects",
                code="bad_room_roster",
            )
        agent = entry.get("agent")
        node = entry.get("node", "")
        role = entry.get("role", "")
        if not isinstance(agent, str) or not agent:
            raise A2AError(
                "room-roster-broadcast member missing string 'agent'",
                code="bad_room_roster",
            )
        if not isinstance(node, str):
            raise A2AError(
                "room-roster-broadcast member 'node' must be a string",
                code="bad_room_roster",
            )
        if not isinstance(role, str):
            raise A2AError(
                "room-roster-broadcast member 'role' must be a string",
                code="bad_room_roster",
            )
    return body


# --------------------------------------------------------------------------
# Outbox (sender side) — durable SQLite
# --------------------------------------------------------------------------

_OUTBOX_SCHEMA = """
CREATE TABLE IF NOT EXISTS outbox (
  message_id          TEXT PRIMARY KEY,
  peer                TEXT NOT NULL,
  target_agent        TEXT NOT NULL,
  priority            TEXT NOT NULL DEFAULT 'normal',
  title               TEXT NOT NULL,
  body_path           TEXT NOT NULL,
  body_sha256         TEXT NOT NULL,
  body_bytes          INTEGER NOT NULL DEFAULT 0,
  status              TEXT NOT NULL DEFAULT 'pending',
  attempts            INTEGER NOT NULL DEFAULT 0,
  next_attempt_ts     INTEGER NOT NULL DEFAULT 0,
  lease_owner         TEXT,
  lease_expires_ts    INTEGER NOT NULL DEFAULT 0,
  last_error          TEXT,
  acked_remote_task_id TEXT,
  created_ts          INTEGER NOT NULL,
  updated_ts          INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_outbox_status ON outbox(status, next_attempt_ts);
CREATE INDEX IF NOT EXISTS idx_outbox_peer ON outbox(peer, status);
"""

# A2A Rooms P4.3 (codex review): the inbox dedupe ledger is scoped to the
# AUTHENTICATED peer via a COMPOSITE (peer, message_id) PRIMARY KEY — mirrors
# P4.1's room_join_dedupe fix. `message_id` is sender-chosen (the `<bridge>:uuid`
# convention is NOT enforced on the wire), so a message_id-ONLY PK let one
# authenticated peer pre-seed / block another peer's message_id (a fresh row
# with that id, or a same-id/different-body row → the victim's later legitimate
# message is mis-classified as a 409 conflict and suppressed). The composite PK
# isolates each peer's dedupe namespace: a (peerB, "nodeA:uuid") row can never
# collide with (peerA, "nodeA:uuid"). Room-talk rides this same /enqueue dedupe,
# so contract 6 (peer-scoped dedupe + replay protection) is satisfied here for
# room messages too — without a separate ledger.
_INBOX_SCHEMA = """
CREATE TABLE IF NOT EXISTS inbox_dedupe (
  message_id      TEXT NOT NULL,
  peer            TEXT NOT NULL,
  body_sha256     TEXT NOT NULL,
  created_task_id TEXT,
  first_seen_ts   INTEGER NOT NULL,
  last_seen_ts    INTEGER NOT NULL,
  delivery_count  INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (peer, message_id)
);
CREATE INDEX IF NOT EXISTS idx_inbox_peer ON inbox_dedupe(peer, first_seen_ts);
"""


def _migrate_inbox_schema(conn: sqlite3.Connection) -> None:
    """Idempotently rebuild a legacy single-column-PK inbox_dedupe to the
    composite (peer, message_id) PK (A2A Rooms P4.3, codex review).

    `CREATE TABLE IF NOT EXISTS` never alters an existing table, so an inbox.db
    created before this change keeps `message_id TEXT PRIMARY KEY`. SQLite cannot
    `ALTER TABLE ... ADD PRIMARY KEY`, so we detect the old shape (the
    `message_id` column declared `pk=1` while `peer` is not part of the PK) and
    rebuild: create the new table, copy rows (collapsing any pre-existing
    cross-peer id collisions to the FIRST-seen row per (peer, message_id) — which
    the old global PK could not even have stored, so there is nothing to lose in
    practice), swap, reindex. The whole rebuild is one transaction; on any error
    it rolls back and leaves the legacy table intact (fail-safe — dedupe still
    works, just globally, until the next open retries the migration). NEVER drops
    rows for a peer.
    """
    try:
        cols = conn.execute("PRAGMA table_info(inbox_dedupe)").fetchall()
    except sqlite3.Error:
        return
    if not cols:
        return
    # Map column name -> pk position (0 = not part of pk).
    pk_of = {row[1]: int(row[5]) for row in cols}
    # Legacy shape: message_id is the sole PK (pk==1) and peer is NOT in the PK.
    legacy = pk_of.get("message_id", 0) == 1 and pk_of.get("peer", 0) == 0
    if not legacy:
        return
    try:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("""
            CREATE TABLE inbox_dedupe_p43 (
              message_id      TEXT NOT NULL,
              peer            TEXT NOT NULL,
              body_sha256     TEXT NOT NULL,
              created_task_id TEXT,
              first_seen_ts   INTEGER NOT NULL,
              last_seen_ts    INTEGER NOT NULL,
              delivery_count  INTEGER NOT NULL DEFAULT 1,
              PRIMARY KEY (peer, message_id)
            )
        """)
        # INSERT OR IGNORE collapses to one row per (peer, message_id); with a
        # global PK there can be at most one row per message_id anyway, so this
        # is a faithful 1:1 copy. Order by first_seen_ts so the earliest wins.
        conn.execute("""
            INSERT OR IGNORE INTO inbox_dedupe_p43
              (message_id, peer, body_sha256, created_task_id, first_seen_ts,
               last_seen_ts, delivery_count)
            SELECT message_id, peer, body_sha256, created_task_id, first_seen_ts,
                   last_seen_ts, delivery_count
            FROM inbox_dedupe ORDER BY first_seen_ts
        """)
        conn.execute("DROP TABLE inbox_dedupe")
        conn.execute("ALTER TABLE inbox_dedupe_p43 RENAME TO inbox_dedupe")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_inbox_peer "
            "ON inbox_dedupe(peer, first_seen_ts)")
        conn.commit()
    except sqlite3.Error:
        # Leave the legacy table intact (no row loss) and roll back the partial
        # rebuild. The CALLER (open_inbox) re-verifies the PK shape and FAILS
        # CLOSED if the table is still legacy (codex P4.3 r2) — it must NOT hand
        # back a connection on which a cross-peer same-id message could pass the
        # peer-scoped lookup yet collide only at the post-enqueue INSERT (which
        # would let a task be staged against a global-PK ledger).
        conn.rollback()


def _inbox_pk_is_composite(conn: sqlite3.Connection) -> bool:
    """True iff inbox_dedupe carries the composite (peer, message_id) PK.

    The post-migration verification gate (codex P4.3 r2). Reads PRAGMA
    table_info: both `peer` and `message_id` must be part of the PRIMARY KEY (pk
    position > 0). A legacy single-column-PK table (message_id pk=1, peer pk=0)
    returns False so open_inbox can fail closed rather than serve cross-peer
    dedupe on a global-PK ledger.
    """
    try:
        cols = conn.execute("PRAGMA table_info(inbox_dedupe)").fetchall()
    except sqlite3.Error:
        return False
    if not cols:
        return False
    pk_of = {row[1]: int(row[5]) for row in cols}
    return pk_of.get("peer", 0) > 0 and pk_of.get("message_id", 0) > 0


def _connect(path: Path, schema: str) -> sqlite3.Connection:
    # #1728 r2: guard the ACTUAL resolved db path (which may be a
    # BRIDGE_A2A_OUTBOX_DB / _INBOX_DB override that bypasses state_dir()) —
    # fail closed before creating/opening it if a test-bind mesh would land it
    # outside its BRIDGE_HOME. No-op when the flag is unset (prod) or the path
    # is under home (correctly isolated mesh).
    guard_test_bind_db_path(path, what="A2A db path")
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(schema)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return conn


def open_outbox() -> sqlite3.Connection:
    return _connect(outbox_db_path(), _OUTBOX_SCHEMA)


def open_inbox() -> sqlite3.Connection:
    conn = _connect(inbox_db_path(), _INBOX_SCHEMA)
    _migrate_inbox_schema(conn)
    # FAIL CLOSED if the dedupe ledger is still the legacy global-PK shape
    # (a fresh db is created composite; an upgraded db is migrated above; only a
    # FAILED migration leaves it legacy). Returning a legacy-PK connection would
    # let a cross-peer same-message_id request pass the peer-scoped lookup and
    # reach enqueue, then collide only at the post-enqueue INSERT — so we refuse
    # to serve dedupe on it. The caller's try/except turns this into a 500
    # BEFORE any staging/enqueue (codex P4.3 r2).
    if not _inbox_pk_is_composite(conn):
        conn.close()
        raise A2AError(
            "inbox_dedupe is still the legacy global-PK shape after migration — "
            "refusing to serve peer-scoped dedupe on it (retry after the rebuild "
            "succeeds)",
            code="inbox_dedupe_legacy_pk",
        )
    return conn


def prune_inbox_dedupe(
    conn: sqlite3.Connection,
    *,
    max_age: int = DEFAULT_INBOX_DEDUPE_GC_MAX_AGE_SECONDS,
    max_rows_per_peer: int = DEFAULT_INBOX_DEDUPE_MAX_ROWS_PER_PEER,
) -> tuple[int, int]:
    """Prune receiver dedupe rows by age and per-peer total-row ceiling.

    Age-based pruning already existed as a manual CLI path. The per-peer cap is
    deliberately independent of max_open_tasks so NULL control/pending rows and
    hash-conflict delivery_count bumps cannot grow forever on an authenticated
    peer that stays below the open-task quota.
    """
    now = now_ts()
    age_removed = 0
    cap_removed = 0
    if max_age > 0:
        cur = conn.execute(
            "DELETE FROM inbox_dedupe WHERE last_seen_ts < ?",
            (now - max_age,),
        )
        age_removed = int(cur.rowcount or 0)

    if max_rows_per_peer > 0:
        rows = conn.execute(
            """
            SELECT peer, COUNT(*) AS n
              FROM inbox_dedupe
             GROUP BY peer
            HAVING n > ?
            """,
            (max_rows_per_peer,),
        ).fetchall()
        for row in rows:
            excess = int(row["n"] or 0) - max_rows_per_peer
            if excess <= 0:
                continue
            cur = conn.execute(
                """
                DELETE FROM inbox_dedupe
                 WHERE rowid IN (
                       SELECT rowid
                         FROM inbox_dedupe
                        WHERE peer = ?
                        ORDER BY last_seen_ts ASC, first_seen_ts ASC, message_id ASC
                        LIMIT ?
                 )
                """,
                (row["peer"], excess),
            )
            cap_removed += int(cur.rowcount or 0)
    conn.commit()
    return age_removed, cap_removed


def wake_peer_outbox_for_resume(conn: sqlite3.Connection, peer_id: str,
                                now: Optional[int] = None) -> int:
    """Re-arm a peer's backoff-waiting / parked outbox rows for immediate send.

    #1732 reconnect flush (seamless resume). On a peer's #1707 peer-reachability
    UP transition the daemon wakes ONLY that peer's eligible `status='retry'`
    rows — including the parked transient rows that sit at the backoff cap —
    back to `status='pending'`, `next_attempt_ts=0`, leases cleared, so the
    daemon's NORMAL deliver loop picks them up on the very next tick. This covers
    room messages too: rooms ride the SAME classic per-peer outbox.

    Scope is deliberately narrow and side-effect-free beyond the row re-arm:
      - `status='retry'` ONLY — never disturbs `pending` (already due),
        `sending`/leased (mid-attempt), or `acked`/`dead` (terminal) rows.
      - This function NEVER delivers inline; it only flips the rows to due. The
        reconcile step that calls it must NOT POST anything — keeping the bind /
        receiver-admission boundary untouched (the reconcile no-bind invariant).

    Returns the number of rows re-armed (0 when the peer has none waiting).
    `conn` is the OUTBOX connection (open_outbox), NOT the reconcile.db handle.
    """
    if now is None:
        now = now_ts()
    cur = conn.execute(
        "UPDATE outbox SET status='pending', next_attempt_ts=0, "
        "lease_owner=NULL, lease_expires_ts=0, updated_ts=? "
        "WHERE peer=? AND status='retry'",
        (now, peer_id),
    )
    conn.commit()
    return int(cur.rowcount or 0)


def outbox_total_bytes(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT COALESCE(SUM(body_bytes), 0) AS total FROM outbox "
        "WHERE status IN ('pending', 'sending', 'retry')"
    ).fetchone()
    return int(row["total"] or 0)


def outbox_pending_for_peer(conn: sqlite3.Connection, peer: str) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM outbox WHERE peer = ? AND status IN "
        "('pending', 'sending', 'retry')",
        (peer,),
    ).fetchone()
    return int(row["n"] or 0)


def outbox_insert(
    conn: sqlite3.Connection,
    *,
    message_id: str,
    peer: str,
    target_agent: str,
    priority: str,
    title: str,
    body_path: str,
    body_sha256_hex: str,
    body_bytes: int,
) -> None:
    ts = now_ts()
    conn.execute(
        "INSERT INTO outbox (message_id, peer, target_agent, priority, title, "
        "body_path, body_sha256, body_bytes, status, attempts, next_attempt_ts, "
        "created_ts, updated_ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)",
        (
            message_id,
            peer,
            target_agent,
            priority,
            title,
            body_path,
            body_sha256_hex,
            body_bytes,
            ts,
            ts,
            ts,
        ),
    )
    conn.commit()


def backoff_seconds(attempts: int, base: int = 15,
                    ceiling: int = DEFAULT_DELIVERY_BACKOFF_CEILING_SECONDS) -> int:
    """Exponential backoff with a ceiling; jitter is added by the caller."""
    delay = base * (2 ** max(0, attempts - 1))
    return min(delay, ceiling)


def _int_with_floor(raw: Any, default: int, floor: int) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = default
    return max(floor, value)


def delivery_backoff_ceiling(cfg: dict[str, Any]) -> int:
    """Resolve the exponential outbox retry backoff ceiling in seconds."""
    raw: Any = os.environ.get("BRIDGE_A2A_BACKOFF_CEILING_SECONDS")
    if raw is None or str(raw).strip() == "":
        raw = cfg.get("delivery_backoff_ceiling_seconds",
                      DEFAULT_DELIVERY_BACKOFF_CEILING_SECONDS)
    return _int_with_floor(
        raw,
        DEFAULT_DELIVERY_BACKOFF_CEILING_SECONDS,
        MIN_DELIVERY_BACKOFF_CEILING_SECONDS,
    )


def delivery_max_retry_after_seconds(cfg: dict[str, Any]) -> int:
    """Resolve the untrusted peer Retry-After floor cap in seconds."""
    return _int_with_floor(
        cfg.get("delivery_max_retry_after_seconds",
                DEFAULT_DELIVERY_MAX_RETRY_AFTER_SECONDS),
        DEFAULT_DELIVERY_MAX_RETRY_AFTER_SECONDS,
        MIN_DELIVERY_MAX_RETRY_AFTER_SECONDS,
    )
