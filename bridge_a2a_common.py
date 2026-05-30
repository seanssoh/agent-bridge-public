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
import json
import os
import shutil
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Optional

PROTOCOL_VERSION = "a2a-enqueue-v1"
ENVELOPE_PROTOCOL = "agent-bridge.a2a.enqueue.v1"
SIGNATURE_PREFIX = "v1="

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

VALID_PRIORITIES = ("low", "normal", "high", "urgent")
TERMINAL_OUTBOX_STATUSES = ("acked", "dead")
PENDING_OUTBOX_STATUSES = ("pending", "sending", "retry")

# HTTP statuses that are permanent failures (no retry → dead-letter).
PERMANENT_FAIL_STATUSES = (400, 401, 403, 404, 409, 413, 422)


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
) -> dict[str, Any]:
    return {
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
    return env


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

_INBOX_SCHEMA = """
CREATE TABLE IF NOT EXISTS inbox_dedupe (
  message_id      TEXT PRIMARY KEY,
  peer            TEXT NOT NULL,
  body_sha256     TEXT NOT NULL,
  created_task_id TEXT,
  first_seen_ts   INTEGER NOT NULL,
  last_seen_ts    INTEGER NOT NULL,
  delivery_count  INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_inbox_peer ON inbox_dedupe(peer, first_seen_ts);
"""


def _connect(path: Path, schema: str) -> sqlite3.Connection:
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
    return _connect(inbox_db_path(), _INBOX_SCHEMA)


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


def backoff_seconds(attempts: int, base: int = 15, ceiling: int = 3600) -> int:
    """Exponential backoff with a ceiling; jitter is added by the caller."""
    delay = base * (2 ** max(0, attempts - 1))
    return min(delay, ceiling)
