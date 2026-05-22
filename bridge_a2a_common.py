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
import sqlite3
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


def peer_cap(peer: dict[str, Any], key: str, default: Any) -> Any:
    caps = peer.get("caps")
    if isinstance(caps, dict) and key in caps:
        return caps[key]
    return default


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
