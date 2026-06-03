#!/usr/bin/env python3
"""Shared helpers for Agent Bridge A2A *rooms* (the control plane).

This module is the single source of truth for the rooms SQLite schema, the
leader-authoritative membership model, the monotonic per-room `epoch`, and
the canonical (sorted-members) roster a leader signs per-node in P4. It is
imported by the `agb room` CLI (`bridge-rooms.py`), by the receiver daemon's
room-scoped check seam (`bridge-handoffd.py`), and — in P1b — by the queue
membership gate. It NEVER runs anything on import and has no third-party
dependencies.

Design contract (see docs/design/a2a-rooms-design.md §6, §14 R2/R6):
- A ROOM has a LEADER (`agent@node`), a ROSTER (member `agent@node` list),
  and a monotonic `epoch` that bumps on EVERY membership change
  (join-approve / leave / kick). The epoch is the split-brain tiebreaker
  and the freshness signal the receiver seam (P4) enforces.
- Invite tokens are stored as `sha256(token)` ONLY. The raw token rides in
  the `agbroom://` link; verification hashes-and-compares. The raw token is
  NEVER persisted.
- `roster_for(room_id)` is the canonical roster: `{room_id, epoch, members}`
  with members deterministically sorted by `(agent, node)`. P1a computes it;
  P4 signs it with the leader-node↔member-node pairwise HMAC and broadcasts.
- The db is 0600 (it indexes who-can-talk-to-whom + invite-token hashes),
  WAL-journaled, and lives next to the A2A outbox/inbox under state/handoff/.

Scope (P1a): SINGLE NODE. Leader-authorized mutations assume caller-agent ==
`leader_agent` (cross-node leader-auth over the node-link is P4). The schema,
the epoch contract, and the canonical roster shape are FROZEN here so P1b–P4
add behavior without a schema rewrite.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any, NamedTuple, Optional

try:
    import pwd  # POSIX-only; used for the un-spoofable iso OS-user check.
except ImportError:  # pragma: no cover - non-POSIX (Windows); not a target host
    pwd = None  # type: ignore[assignment]

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

# Membership roles. A room has exactly one leader row (role='leader'); every
# admitted member is role='member'.
ROLE_LEADER = "leader"
ROLE_MEMBER = "member"

# Join-request lifecycle.
JOIN_PENDING = "pending"
JOIN_APPROVED = "approved"
JOIN_DENIED = "denied"

# Room status. `active` is the only status P1a sets; the column is frozen so a
# future `archived`/`disbanded` lifecycle (Phase-2 backlog) needs no rewrite.
ROOM_ACTIVE = "active"

# rooms_acl mode (design §7 / R1). Default off — P1a does NOT enforce; P1b
# reads this through `rooms_acl_mode()`.
ACL_OFF = "off"
ACL_ENFORCE = "enforce"
_ACL_CONFIG_KEY = "rooms_acl"

# The invite-link scheme. The link carries the RAW token; the db stores only
# its sha256. Leader approval is the real admission gate (token => request).
INVITE_LINK_SCHEME = "agbroom"

# Per-token join rate limit (design §14 R3): a leaked reusable token must not
# let a source spam pending rows. P1a enforces a simple per-token attempt
# counter; the window is advisory (single-node, no clock-coupled reset).
DEFAULT_JOIN_RATE_LIMIT_PER_TOKEN = 50


class RoomsError(Exception):
    """A rooms control-plane failure with a machine-readable code."""

    def __init__(self, message: str, code: str = "rooms_error") -> None:
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------
# Actor-auth boundary (design §14 R1) — the trusted, OS-derived ACL actor
# --------------------------------------------------------------------------
#
# Leader-authorized control-plane mutations (approve/deny/kick/invite/
# rotate-invite) MUST NOT trust a client-supplied agent id. `--as` and
# `BRIDGE_AGENT_ID` are env/flag values a managed process can set freely, so
# basing leader-auth on them is forgeable (codex Phase-4 F1: a process whose
# env agent was `mallory` passed `--as alice` and approved a member). The
# trusted actor is derived from the PROCESS's OS identity (`os.getuid()`),
# mapped to a roster agent the SAME way bridge-queue-gateway.py does — never
# from caller-set env.
#
# Whether THIS process runs under linux-user isolation is decided
# UN-SPOOFABLY from the process's OS *username* (`pwd.getpwuid(os.getuid())`):
# an iso agent runs as `agent-bridge-<slug>`, a passwd-database fact the agent
# cannot change via env. This is the anti-DOWNGRADE anchor (codex Phase-4 r4):
# a managed iso agent must NOT be able to break/empty the roster probe (e.g.
# `BRIDGE_BASH_BIN=/bin/false`, or redirecting the roster file) to fall back
# into the advisory regime where `--as <leader>` is honored. If the OS user
# says we are an iso agent, we are NEVER advisory — we either resolve the
# trusted agent or FAIL CLOSED.
#
# Four enforcement regimes, per design §14 R1:
#   - ISO_ENFORCED  : the process OS user is `agent-bridge-<slug>` AND the
#       (hardened) roster probe maps this uid to an agent. That uid-derived
#       agent IS the trusted actor; leader-auth is HARD and `--as`/env are
#       ignored. An iso agent cannot act as another uid, so it cannot
#       impersonate another agent.
#   - CONTROLLER    : the process is NOT an iso OS user AND `os.getuid()` owns
#       the bridge home → a proven operator shell. `--as` is honored as an
#       explicit operator override.
#   - SHARED_ADVISORY: the process is NOT an iso OS user AND is not the
#       controller → a shared-mode install (agents share one uid). The OS
#       cannot distinguish agents, so a hard team boundary is not a real
#       control. Leader-auth is ADVISORY: honor the best-effort agent id but
#       WARN + audit, never hard-block. (§14 R1 "default = audit/warn".)
#   - UNRESOLVED    : the process IS an iso OS user but the trusted agent
#       cannot be established (probe failed/empty/this uid unmapped), OR a
#       per-agent uid map exists but this uid is unmapped and not the
#       controller → the trusted actor cannot be established → FAILS CLOSED.
#       Critically, an iso OS user with a broken probe lands HERE, not in
#       SHARED_ADVISORY, closing the downgrade attack.

ACTOR_ISO_ENFORCED = "iso-enforced"
ACTOR_CONTROLLER = "controller"
ACTOR_SHARED_ADVISORY = "shared-advisory"
ACTOR_UNRESOLVED = "unresolved"

# The OS-user prefix an iso agent runs as. A build constant (NOT read from
# env) so a managed agent cannot change the iso-active determination by
# clearing/altering `BRIDGE_AGENT_OS_USER_PREFIX`. Mirrors the install default
# (lib/bridge-agents.sh `agent-bridge-` / bridge_agent_default_os_user).
ISO_OS_USER_PREFIX = "agent-bridge-"


class ActorAuth(NamedTuple):
    """The resolved control-plane actor + how its leader-auth is enforced.

    `agent` is the trusted actor for ISO_ENFORCED (uid-derived). For
    CONTROLLER / SHARED_ADVISORY it is the best-effort caller-supplied agent
    (an override the regime explicitly permits). For UNRESOLVED it is "".
    `regime` is one of the ACTOR_* constants. `uid` is the process uid.
    `hard` is True only when leader-auth is a real security control
    (ISO_ENFORCED) — callers use it to decide block vs warn.
    """

    agent: str
    regime: str
    uid: int
    hard: bool


def _test_uid_map_allowed() -> bool:
    """Paired test-only flag gating the BRIDGE_ROOMS_UID_MAP env seam.

    BOTH `BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1` AND `BRIDGE_A2A_ALLOW_TEST_BIND=1`
    must be set. Mirrors the existing paired-flag escape hatches
    (`_allow_insecure_no_secret`, `BRIDGE_A2A_ALLOW_TEST_BIND`) so a single
    stray env var cannot relax the contract. The smoke sets both; production
    sets neither, so the env map is NEVER consulted in a real deployment and a
    managed agent cannot spoof its identity through it (codex Phase-4 r3 F1).
    """
    return (
        os.environ.get("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP") == "1"
        and os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1"
    )


def _process_iso_user() -> Optional[str]:
    """Return THIS process's iso OS-user name iff it is `agent-bridge-<slug>`.

    Un-spoofable: derived from `pwd.getpwuid(os.getuid())` (the passwd
    database), NOT from env. A managed iso agent runs as `agent-bridge-<slug>`
    and cannot change its own username, so this is the anti-downgrade anchor —
    a broken/empty roster probe can no longer make an iso agent look like a
    shared-mode (advisory) caller.

    Returns the username when it has the iso prefix, else None (not an iso OS
    user → controller or shared-mode). A paired-flag test override
    (`BRIDGE_ROOMS_TEST_ISO_USER`) lets the smoke simulate an iso OS user; it
    is NEVER honored in production.
    """
    if _test_uid_map_allowed():
        forced = os.environ.get("BRIDGE_ROOMS_TEST_ISO_USER", "").strip()
        if forced:
            return forced if forced.startswith(ISO_OS_USER_PREFIX) else None
        # An explicit empty override means "force NOT an iso user" for tests
        # that need the controller/shared path; fall through only if unset.
        if "BRIDGE_ROOMS_TEST_ISO_USER" in os.environ:
            return None
    if pwd is None:
        return None
    try:
        name = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError):
        return None
    return name if name.startswith(ISO_OS_USER_PREFIX) else None


# Caller-controllable env vars that could redirect/sabotage the roster probe
# (point the roster at an agent-written file, or break the shell). They are
# stripped from the hardened probe environment so a managed agent cannot
# inject a forged uid->agent row or force the probe empty (codex Phase-4 r4).
_PROBE_ENV_STRIP = (
    "BRIDGE_ROSTER_FILE",
    "BRIDGE_ROSTER_LOCAL_FILE",
    "BRIDGE_AGENT_ENV_FILE",
    "BRIDGE_AGENT_ID",
    "BRIDGE_BASH_BIN",
    "BASH_ENV",
    "ENV",
)


def _uid_agent_map() -> dict[int, str]:
    """uid -> iso agent map from a TRUSTED source (never client env).

    The AUTHORITATIVE source is the roster probe (`_uid_agent_map_from_roster`,
    the SAME mapping bridge-queue-gateway.py derives from `bridge_agent_os_user`
    — controller-owned roster data a managed agent cannot forge). The
    `BRIDGE_ROOMS_UID_MAP` env CSV is a TEST-ONLY seam consulted ONLY behind the
    paired `_test_uid_map_allowed()` flag; in production it is ignored, so a
    managed agent cannot set `BRIDGE_ROOMS_UID_MAP="$(id -u):<leader>"` to
    impersonate the leader (the original r2 hole codex caught).

    An empty map means "no per-agent uid isolation" => shared-mode.
    """
    if _test_uid_map_allowed():
        raw = os.environ.get("BRIDGE_ROOMS_UID_MAP", "").strip()
        if raw:
            out: dict[int, str] = {}
            for item in raw.split(","):
                item = item.strip()
                if not item or ":" not in item:
                    continue
                uid_s, agent = item.split(":", 1)
                uid_s, agent = uid_s.strip(), agent.strip()
                if uid_s.isdigit() and agent:
                    out[int(uid_s)] = agent
            return out
    return _uid_agent_map_from_roster()


def _probe_bash_bin() -> str:
    """A FIXED bash for the probe — never the caller's `BRIDGE_BASH_BIN`.

    A managed agent setting `BRIDGE_BASH_BIN=/bin/false` (or a shim) could
    force the probe empty → downgrade to advisory. We pick a trusted absolute
    bash from well-known locations, falling back to PATH `bash` only if none
    exist. (The empty-probe-as-downgrade hole is independently closed by the
    iso-OS-user anchor in resolve_os_actor, but using a fixed bash removes the
    easiest sabotage lever too.)
    """
    for cand in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash",
                 "/bin/bash", "/usr/bin/bash"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return "bash"


def _uid_agent_map_from_roster() -> dict[int, str]:
    """Probe the roster for uid->agent over linux-user-isolated agents.

    Mirrors bridge-queue-gateway.py `_peer_map_from_roster` so rooms leader-
    auth and the queue gateway never diverge on the trusted mapping. The probe
    runs with a HARDENED environment (codex Phase-4 r4): caller-controllable
    roster-redirect / shell-injection vars (`BRIDGE_ROSTER_LOCAL_FILE`,
    `BRIDGE_AGENT_ENV_FILE`, `BRIDGE_AGENT_ID`, `BRIDGE_BASH_BIN`, `BASH_ENV`,
    …) are stripped so a managed agent cannot inject a forged uid->agent row or
    break the probe. A probe failure yields an EMPTY map; the empty map is only
    treated as shared-mode when the caller is NOT an iso OS user (see
    resolve_os_actor) — an iso agent with a failed probe fails CLOSED.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    lib = os.path.join(here, "bridge-lib.sh")
    if not os.path.isfile(lib):
        return {}
    bash = _probe_bash_bin()
    # The probe emits the resolved roster file paths (prefixed `ROSTER\t`) so
    # the PARENT can verify they are controller-owned (codex Phase-4 r5 BLOCK):
    # a managed iso agent could otherwise point BRIDGE_HOME at an agent-
    # writable fake home with a FORGED roster mapping its own uid -> <leader>.
    # We trust a uid->agent row ONLY if every roster file it could have come
    # from is owned by a uid OTHER than the calling (agent) uid — a forged
    # roster the agent wrote is owned by the agent's own uid and is rejected,
    # collapsing the map to empty → an iso user then FAILS CLOSED.
    probe = (
        'source "$1/bridge-lib.sh"\n'
        'bridge_load_roster 2>/dev/null || exit 0\n'
        'for f in "${BRIDGE_ROSTER_FILE:-}" "${BRIDGE_ROSTER_LOCAL_FILE:-}"; do\n'
        '  [ -n "$f" ] && printf "ROSTER\\t%s\\n" "$f"\n'
        'done\n'
        'for agent in "${BRIDGE_AGENT_IDS[@]}"; do\n'
        '  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null '
        '|| continue\n'
        '  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"\n'
        '  [ -n "$os_user" ] || continue\n'
        '  uid="$(id -u "$os_user" 2>/dev/null || true)"\n'
        '  [ -n "$uid" ] || continue\n'
        '  printf "MAP\\t%s\\t%s\\n" "$uid" "$agent"\n'
        'done\n'
    )
    probe_env = {k: v for k, v in os.environ.items()
                 if k not in _PROBE_ENV_STRIP}
    try:
        proc = subprocess.run(
            [bash, "-c", probe, "probe", here],
            text=True, capture_output=True, timeout=30, check=False,
            env=probe_env,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if proc.returncode != 0:
        return {}
    my_uid = os.getuid()
    roster_files: list[str] = []
    raw_map: dict[int, str] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if parts[0] == "ROSTER" and len(parts) == 2 and parts[1].strip():
            roster_files.append(parts[1].strip())
        elif parts[0] == "MAP" and len(parts) == 3 \
                and parts[1].strip().isdigit() and parts[2].strip():
            raw_map[int(parts[1].strip())] = parts[2].strip()
    # Ownership gate: every roster file that fed the map must be owned by a uid
    # OTHER than ours (the agent's). A roster owned by the calling agent (or
    # unstattable) is untrusted → reject the whole map (fail closed for an iso
    # user). root- or controller-owned rosters pass.
    for rf in roster_files:
        try:
            owner = os.stat(rf).st_uid  # noqa: raw-pathlib-controller-only
        except OSError:
            return {}
        if owner == my_uid:
            # A roster the calling agent could have written — do NOT trust it.
            return {}
    return raw_map


def _controller_uid() -> Optional[int]:
    """The controller/operator uid — the bridge-home OWNER (a filesystem fact).

    Deliberately does NOT trust `BRIDGE_CONTROLLER_UID` from the process env:
    that is caller-settable, so honoring it would let an unmapped managed agent
    set `BRIDGE_CONTROLLER_UID="$(id -u)"` to enter the controller regime where
    `--as` is honored (the r2->r3 hole codex caught). The bridge home is owned
    by the controller/operator and a non-root managed agent cannot chown it, so
    its owner uid is an unforgeable controller identity. Returns None when it
    cannot be stat'd → the controller bypass is then simply unavailable
    (fail-closed for an unmapped uid, which is the safe default).

    A `BRIDGE_ROOMS_TEST_CONTROLLER_UID` override exists ONLY behind the paired
    test flag (`_test_uid_map_allowed()`), so a smoke can force a
    non-controller context to exercise the UNRESOLVED fail-closed path. It is
    NEVER honored in production (no flag) — identical gating to the test uid
    map.
    """
    if _test_uid_map_allowed():
        raw = os.environ.get("BRIDGE_ROOMS_TEST_CONTROLLER_UID", "").strip()
        if raw.lstrip("-").isdigit():
            return int(raw)
    try:
        return os.stat(str(bridge_home())).st_uid  # noqa: raw-pathlib-controller-only
    except OSError:
        return None


def resolve_os_actor(requested: Optional[str] = None) -> ActorAuth:
    """Resolve the trusted control-plane actor from the PROCESS OS identity.

    `requested` is the caller-supplied agent (`--as`/env). It is honored ONLY
    in the regimes that explicitly permit it (CONTROLLER, SHARED_ADVISORY) and
    is IGNORED for the leader-auth decision under ISO_ENFORCED.

    The decision is ANCHORED on the un-spoofable OS username (`_process_iso_
    user`), NOT on the roster probe's success, so a managed iso agent cannot
    sabotage the probe (`BRIDGE_BASH_BIN`, roster redirect) to downgrade itself
    into the advisory regime (codex Phase-4 r4). See the section header for the
    four regimes.
    """
    uid = os.getuid()
    iso_user = _process_iso_user()

    if iso_user is not None:
        # We ARE an iso agent (passwd fact). The trusted actor is THIS uid's
        # mapped agent from the hardened probe. If the probe cannot map this
        # uid (broken/sabotaged/empty), we FAIL CLOSED — never advisory.
        mapped = _uid_agent_map().get(uid)
        if mapped:
            return ActorAuth(agent=mapped, regime=ACTOR_ISO_ENFORCED,
                             uid=uid, hard=True)
        return ActorAuth(agent="", regime=ACTOR_UNRESOLVED, uid=uid, hard=True)

    # NOT an iso OS user → either the controller/operator or a shared-mode
    # install. The bridge-home owner (a filesystem fact) is the controller.
    controller = _controller_uid()
    if controller is not None and uid == controller:
        agent = (requested
                 or os.environ.get("BRIDGE_AGENT_ID")
                 or os.environ.get("USER")
                 or "")
        return ActorAuth(agent=str(agent).strip(), regime=ACTOR_CONTROLLER,
                         uid=uid, hard=False)

    # Not an iso OS user and not the controller. If a per-agent uid map exists
    # (other iso agents on the host) and this uid is unmapped, we still cannot
    # establish a trusted actor for a leader-only action → fail closed. With NO
    # uid map at all this is a genuine shared-mode install → advisory.
    if _uid_agent_map():
        return ActorAuth(agent="", regime=ACTOR_UNRESOLVED, uid=uid, hard=True)
    agent = (requested
             or os.environ.get("BRIDGE_AGENT_ID")
             or os.environ.get("USER")
             or "")
    return ActorAuth(agent=str(agent).strip(), regime=ACTOR_SHARED_ADVISORY,
                     uid=uid, hard=False)


# --------------------------------------------------------------------------
# Paths — reuse the A2A handoff dir so rooms.db sits beside outbox/inbox.db
# --------------------------------------------------------------------------

def bridge_home() -> Path:
    return Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))


def state_dir() -> Path:
    explicit = os.environ.get("BRIDGE_STATE_DIR")
    if explicit:
        return Path(explicit)
    return bridge_home() / "state"


def handoff_dir() -> Path:
    """`$BRIDGE_STATE_DIR/handoff` — shared with the A2A outbox/inbox."""
    return state_dir() / "handoff"


def rooms_db_path() -> Path:
    override = os.environ.get("BRIDGE_A2A_ROOMS_DB")
    if override:
        return Path(override)
    return handoff_dir() / "rooms.db"


# --------------------------------------------------------------------------
# Schema (FROZEN — design §14 R2/R6)
# --------------------------------------------------------------------------

_ROOMS_SCHEMA = """
CREATE TABLE IF NOT EXISTS rooms (
  room_id            TEXT PRIMARY KEY,
  name               TEXT NOT NULL DEFAULT '',
  leader_agent       TEXT NOT NULL,
  leader_node        TEXT NOT NULL DEFAULT '',
  epoch              INTEGER NOT NULL DEFAULT 0,
  invite_token_sha256 TEXT,
  invite_token_ts    INTEGER NOT NULL DEFAULT 0,
  invite_once        INTEGER NOT NULL DEFAULT 0,
  status             TEXT NOT NULL DEFAULT 'active',
  created_ts         INTEGER NOT NULL,
  updated_ts         INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS room_members (
  room_id    TEXT NOT NULL,
  agent      TEXT NOT NULL,
  node       TEXT NOT NULL DEFAULT '',
  role       TEXT NOT NULL DEFAULT 'member',
  joined_ts  INTEGER NOT NULL,
  PRIMARY KEY (room_id, agent, node)
);
CREATE INDEX IF NOT EXISTS idx_room_members_agent ON room_members(agent, node);

CREATE TABLE IF NOT EXISTS room_join_requests (
  room_id      TEXT NOT NULL,
  agent        TEXT NOT NULL,
  node         TEXT NOT NULL DEFAULT '',
  requested_ts INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  PRIMARY KEY (room_id, agent, node)
);

CREATE TABLE IF NOT EXISTS room_roster_cache (
  room_id      TEXT PRIMARY KEY,
  epoch        INTEGER NOT NULL DEFAULT 0,
  members_json TEXT NOT NULL DEFAULT '[]',
  from_node    TEXT NOT NULL DEFAULT '',
  mac          TEXT NOT NULL DEFAULT '',
  fetched_ts   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS rooms_acl_config (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);

-- Per-(token-hash, source) join attempt counter. A leaked reusable token
-- cannot spam the leader's pending queue beyond the configured ceiling.
CREATE TABLE IF NOT EXISTS room_join_rate (
  token_sha256 TEXT NOT NULL,
  source       TEXT NOT NULL DEFAULT '',
  attempts     INTEGER NOT NULL DEFAULT 0,
  first_ts     INTEGER NOT NULL,
  last_ts      INTEGER NOT NULL,
  PRIMARY KEY (token_sha256, source)
);
"""


def now_ts() -> int:
    return int(time.time())


def _connect(path: Path, schema: str) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(schema)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return conn


def open_rooms() -> sqlite3.Connection:
    """Open (creating if absent) the rooms.db at 0600 with the frozen schema."""
    return _connect(rooms_db_path(), _ROOMS_SCHEMA)


def open_rooms_readonly() -> Optional[sqlite3.Connection]:
    """Open an EXISTING rooms.db read-only; return None when it is absent.

    Used by read paths (the receiver seam, P1b's membership lookup) that must
    DEGRADE gracefully when no rooms have ever been defined — they must not
    create the db as a side effect of a lookup. A present-but-unreadable db
    raises RoomsError so a real fault is never silently treated as "no rooms".
    """
    path = rooms_db_path()
    if not path.exists():
        return None
    try:
        conn = sqlite3.connect(
            f"file:{path}?mode=ro", uri=True, timeout=30.0,
        )
    except sqlite3.Error as exc:
        raise RoomsError(
            f"rooms.db present but cannot be opened: {exc}", code="rooms_db_unreadable",
        ) from exc
    conn.row_factory = sqlite3.Row
    return conn


# --------------------------------------------------------------------------
# Identity helpers
# --------------------------------------------------------------------------

def mint_room_id() -> str:
    """`room-<short-rand>` — globally-unique-enough for invite links."""
    return "room-" + secrets.token_hex(5)


def mint_invite_token() -> str:
    """A fresh, URL-safe room invite token (the raw secret in the link)."""
    return secrets.token_urlsafe(24)


def hash_token(token: str) -> str:
    """sha256 of the raw token — the ONLY form persisted in rooms.db."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def make_invite_link(room_id: str, leader_node: str, token: str,
                     reach: str = "") -> str:
    """Build the `agbroom://join?...` link the leader hands out ONCE.

    The raw token is in the link, never stored. `reach` is an optional
    transport hint (P2+); empty in single-node P1a.
    """
    from urllib.parse import urlencode

    params = {"room": room_id, "leader": leader_node, "t": token}
    if reach:
        params["reach"] = reach
    return f"{INVITE_LINK_SCHEME}://join?" + urlencode(params)


def parse_invite_link(link: str) -> dict[str, str]:
    """Parse an `agbroom://join?...` link into {room, leader, t, reach}.

    Accepts either a full link or a bare room_id (the CLI lets `join` take
    `<link|room_id>`). A bare room_id yields {"room": <id>} with no token.
    """
    from urllib.parse import parse_qs, urlsplit

    if not link.startswith(f"{INVITE_LINK_SCHEME}://"):
        # Treat as a bare room id — no token carried.
        return {"room": link.strip()}
    parts = urlsplit(link)
    if parts.netloc and parts.netloc != "join":
        # `agbroom://join?...` puts `join` in netloc; tolerate `agbroom://?...`
        # too, but reject a different host so a malformed link fails loud.
        raise RoomsError(
            f"unsupported invite link host: {parts.netloc!r} "
            f"(expected '{INVITE_LINK_SCHEME}://join?...')",
            code="bad_invite_link",
        )
    q = parse_qs(parts.query)
    out: dict[str, str] = {}
    for key in ("room", "leader", "t", "reach"):
        vals = q.get(key)
        if vals:
            out[key] = vals[0]
    if "room" not in out:
        raise RoomsError(
            "invite link missing required 'room' parameter", code="bad_invite_link",
        )
    return out


# --------------------------------------------------------------------------
# Room CRUD
# --------------------------------------------------------------------------

def get_room(conn: sqlite3.Connection, room_id: str) -> Optional[sqlite3.Row]:
    return conn.execute(
        "SELECT * FROM rooms WHERE room_id=?", (room_id,)
    ).fetchone()


def require_room(conn: sqlite3.Connection, room_id: str) -> sqlite3.Row:
    row = get_room(conn, room_id)
    if row is None:
        raise RoomsError(f"room not found: {room_id}", code="room_unknown")
    return row


def list_rooms(conn: sqlite3.Connection,
               owned_node: Optional[str] = None) -> list[sqlite3.Row]:
    """All rooms, or only rooms whose `leader_node` == `owned_node`.

    `list --owned` is the leader-node's registry view (design §6 "관리용
    방 목록"): rooms this node leads.
    """
    if owned_node is not None:
        return conn.execute(
            "SELECT * FROM rooms WHERE leader_node=? ORDER BY created_ts",
            (owned_node,),
        ).fetchall()
    return conn.execute(
        "SELECT * FROM rooms ORDER BY created_ts"
    ).fetchall()


def create_room(conn: sqlite3.Connection, *, name: str, leader_agent: str,
                leader_node: str, token: str,
                once: bool = False) -> str:
    """Create a room led by `leader_agent@leader_node`; seed leader member row.

    `epoch` starts at 0. The leader row is role='leader'. Only the token HASH
    is stored. Returns the minted room_id. The caller is responsible for
    printing the one-time invite link (it holds the raw token).
    """
    room_id = mint_room_id()
    ts = now_ts()
    conn.execute(
        "INSERT INTO rooms (room_id, name, leader_agent, leader_node, epoch, "
        "invite_token_sha256, invite_token_ts, invite_once, status, "
        "created_ts, updated_ts) "
        "VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)",
        (room_id, name, leader_agent, leader_node, hash_token(token), ts,
         1 if once else 0, ROOM_ACTIVE, ts, ts),
    )
    conn.execute(
        "INSERT INTO room_members (room_id, agent, node, role, joined_ts) "
        "VALUES (?, ?, ?, ?, ?)",
        (room_id, leader_agent, leader_node, ROLE_LEADER, ts),
    )
    # Seed the epoch-0 roster cache in the SAME transaction as the room +
    # leader rows so a reader never sees a room with no cache row.
    _recompute_roster_cache(conn, room_id, commit=False)
    conn.commit()
    return room_id


def is_leader(room: sqlite3.Row, caller_agent: str,
              caller_node: Optional[str] = None) -> bool:
    """Single-node leader-auth (P1a): caller_agent == room.leader_agent.

    `caller_node`, when supplied, must also match `leader_node` — this keeps
    the predicate correct the moment P4 makes node meaningful, without a
    later signature change. In single-node P1a `caller_node` is usually the
    local node so the node check is a no-op.
    """
    if caller_agent != room["leader_agent"]:
        return False
    if caller_node is not None and room["leader_node"]:
        return caller_node == room["leader_node"]
    return True


def require_leader(room: sqlite3.Row, caller_agent: str,
                   caller_node: Optional[str] = None) -> None:
    if not is_leader(room, caller_agent, caller_node):
        raise RoomsError(
            f"leader-only action on room {room['room_id']}: caller "
            f"{caller_agent!r} is not the leader ({room['leader_agent']!r})",
            code="not_leader",
        )


# --------------------------------------------------------------------------
# Invite tokens
# --------------------------------------------------------------------------

def set_invite_token(conn: sqlite3.Connection, room_id: str, token: str,
                     once: bool = False) -> None:
    """Store a fresh token hash, INVALIDATING any prior token for the room."""
    ts = now_ts()
    conn.execute(
        "UPDATE rooms SET invite_token_sha256=?, invite_token_ts=?, "
        "invite_once=?, updated_ts=? WHERE room_id=?",
        (hash_token(token), ts, 1 if once else 0, ts, room_id),
    )
    # A rotated token invalidates prior rate-counters too (fresh budget).
    conn.execute(
        "DELETE FROM room_join_rate WHERE token_sha256 NOT IN "
        "(SELECT invite_token_sha256 FROM rooms WHERE invite_token_sha256 IS NOT NULL)"
    )
    conn.commit()


def verify_invite_token(room: sqlite3.Row, token: str) -> bool:
    """Constant-time compare of `sha256(token)` against the room's stored hash."""
    stored = room["invite_token_sha256"]
    if not stored:
        return False
    import hmac as _hmac

    return _hmac.compare_digest(stored, hash_token(token))


def burn_invite_token(conn: sqlite3.Connection, room_id: str) -> None:
    """Clear the token after a `--once` single-use join is approved."""
    conn.execute(
        "UPDATE rooms SET invite_token_sha256=NULL, invite_once=0, "
        "updated_ts=? WHERE room_id=?",
        (now_ts(), room_id),
    )
    conn.commit()


def record_join_attempt(conn: sqlite3.Connection, token: str, source: str,
                        limit: int = DEFAULT_JOIN_RATE_LIMIT_PER_TOKEN) -> int:
    """Increment + return the per-(token-hash, source) attempt count.

    Raises RoomsError(code='rate_limited') once the count exceeds `limit`.
    Single-node P1a uses the joining agent id as `source`; P4 uses the
    source node. The counter is keyed on the token HASH so a rotate (which
    deletes stale counters) resets the budget.
    """
    th = hash_token(token)
    ts = now_ts()
    row = conn.execute(
        "SELECT attempts FROM room_join_rate WHERE token_sha256=? AND source=?",
        (th, source),
    ).fetchone()
    attempts = (int(row["attempts"]) if row else 0) + 1
    if row:
        conn.execute(
            "UPDATE room_join_rate SET attempts=?, last_ts=? "
            "WHERE token_sha256=? AND source=?",
            (attempts, ts, th, source),
        )
    else:
        conn.execute(
            "INSERT INTO room_join_rate (token_sha256, source, attempts, "
            "first_ts, last_ts) VALUES (?, ?, ?, ?, ?)",
            (th, source, attempts, ts, ts),
        )
    conn.commit()
    if attempts > limit:
        raise RoomsError(
            f"join rate limit exceeded for this invite token "
            f"(source={source!r}, {attempts} attempts > {limit})",
            code="rate_limited",
        )
    return attempts


# --------------------------------------------------------------------------
# Membership + join requests + epoch
# --------------------------------------------------------------------------

def bump_epoch(conn: sqlite3.Connection, room_id: str) -> int:
    """Monotonically increment a room's epoch + RE-PERSIST the roster cache.

    Called on EVERY membership change (join-approve / leave / kick). This is
    the freshness signal the P4 receiver seam enforces and the split-brain
    tiebreaker — never reset, never reused.

    The roster-cache recompute is CENTRALIZED here (codex Phase-4 F2): every
    mutation that changes membership MUST go through bump_epoch, and bump_epoch
    atomically re-writes `room_roster_cache` to the new (epoch, canonical
    sorted members) so no caller can leave the cache stale. The frozen
    roster-cache contract P4 consumes (epoch == rooms.epoch, members == the
    canonical sorted roster) thus holds after every verb, not just the ones
    that happened to call `_recompute_roster_cache` explicitly.
    """
    require_room(conn, room_id)
    # Single transaction: the epoch UPDATE and the room_roster_cache write
    # commit together (codex Phase-4 r3 F2 nit) so a reader/crash can never
    # observe a bumped rooms.epoch with a stale cache row, nor vice versa.
    conn.execute(
        "UPDATE rooms SET epoch = epoch + 1, updated_ts=? WHERE room_id=?",
        (now_ts(), room_id),
    )
    row = conn.execute(
        "SELECT epoch FROM rooms WHERE room_id=?", (room_id,)
    ).fetchone()
    # Recompute against the POST-bump membership + epoch WITHOUT an intermediate
    # commit, then commit both writes atomically.
    _recompute_roster_cache(conn, room_id, commit=False)
    conn.commit()
    return int(row["epoch"])


def is_member(conn: sqlite3.Connection, room_id: str, agent: str,
              node: str = "") -> bool:
    row = conn.execute(
        "SELECT 1 FROM room_members WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    return row is not None


def add_member(conn: sqlite3.Connection, room_id: str, agent: str,
               node: str = "", role: str = ROLE_MEMBER) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO room_members (room_id, agent, node, role, "
        "joined_ts) VALUES (?, ?, ?, ?, ?)",
        (room_id, agent, node, role, now_ts()),
    )
    conn.commit()


def remove_member(conn: sqlite3.Connection, room_id: str, agent: str,
                  node: str = "") -> bool:
    """Remove a member; return True if a row was deleted.

    The leader row cannot be removed (leave/kick of the leader is out of
    scope for P1a — a room without a leader has no control plane).
    """
    room = require_room(conn, room_id)
    if agent == room["leader_agent"] and node == (room["leader_node"] or ""):
        raise RoomsError(
            f"cannot remove the leader ({agent}@{node}) from room {room_id}",
            code="cannot_remove_leader",
        )
    cur = conn.execute(
        "DELETE FROM room_members WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    )
    conn.commit()
    return cur.rowcount > 0


def members_for(conn: sqlite3.Connection, agent: str,
                node: str = "") -> list[str]:
    """Every room_id `agent@node` is a member of (for P1b uid->agent lookup)."""
    rows = conn.execute(
        "SELECT room_id FROM room_members WHERE agent=? AND node=? "
        "ORDER BY room_id",
        (agent, node),
    ).fetchall()
    return [r["room_id"] for r in rows]


# Back-compat alias spelled the way the brief named it.
def room_members_for(conn: sqlite3.Connection, agent: str,
                     node: str = "") -> list[str]:
    return members_for(conn, agent, node)


def shared_rooms(conn: sqlite3.Connection, agent1: str, node1: str,
                 agent2: str, node2: str) -> list[str]:
    """Room ids that BOTH `agent1@node1` and `agent2@node2` belong to.

    This is the predicate P1b's queue ACL gates `create --to` on (a create
    is allowed iff actor and target share at least one room). Frozen here so
    P1b consumes it without a schema rewrite.
    """
    a = set(members_for(conn, agent1, node1))
    b = set(members_for(conn, agent2, node2))
    return sorted(a & b)


def post_join_request(conn: sqlite3.Connection, room_id: str, agent: str,
                      node: str = "") -> None:
    conn.execute(
        "INSERT OR REPLACE INTO room_join_requests (room_id, agent, node, "
        "requested_ts, status) VALUES (?, ?, ?, ?, ?)",
        (room_id, agent, node, now_ts(), JOIN_PENDING),
    )
    conn.commit()


def list_join_requests(conn: sqlite3.Connection, room_id: str,
                       status: Optional[str] = None) -> list[sqlite3.Row]:
    if status is not None:
        return conn.execute(
            "SELECT * FROM room_join_requests WHERE room_id=? AND status=? "
            "ORDER BY requested_ts",
            (room_id, status),
        ).fetchall()
    return conn.execute(
        "SELECT * FROM room_join_requests WHERE room_id=? ORDER BY requested_ts",
        (room_id,),
    ).fetchall()


def set_join_request_status(conn: sqlite3.Connection, room_id: str, agent: str,
                            node: str, status: str) -> bool:
    cur = conn.execute(
        "UPDATE room_join_requests SET status=? WHERE room_id=? AND agent=? "
        "AND node=?",
        (status, room_id, agent, node),
    )
    conn.commit()
    return cur.rowcount > 0


# --------------------------------------------------------------------------
# Canonical roster (the thing a leader MACs per-node in P4)
# --------------------------------------------------------------------------

def _sorted_members(conn: sqlite3.Connection,
                    room_id: str) -> list[dict[str, str]]:
    """Members of a room, deterministically sorted by (agent, node).

    The sort is the CANONICAL ordering — P4 signs over exactly this byte
    sequence so any verifier recomputes the same MAC. Never reorder.
    """
    rows = conn.execute(
        "SELECT agent, node, role FROM room_members WHERE room_id=? "
        "ORDER BY agent, node",
        (room_id,),
    ).fetchall()
    return [
        {"agent": r["agent"], "node": r["node"] or "", "role": r["role"]}
        for r in rows
    ]


def roster_for(conn: sqlite3.Connection, room_id: str) -> dict[str, Any]:
    """The canonical roster: {room_id, epoch, members(sorted)}.

    P1a computes it (for `agb room show`, the receiver seam, P1b lookups).
    P4 signs this exact structure with the leader-node↔member-node pairwise
    HMAC and broadcasts it. The `members` list is canonically sorted so the
    signed bytes are reproducible.
    """
    room = require_room(conn, room_id)
    return {
        "room_id": room_id,
        "epoch": int(room["epoch"]),
        "members": _sorted_members(conn, room_id),
    }


def canonical_roster_bytes(roster: dict[str, Any]) -> bytes:
    """Deterministic JSON encoding of a roster — the P4 MAC input.

    Frozen here (sorted keys, no spaces) so the sender that signs and the
    receiver that verifies in P4 never diverge on the byte sequence.
    """
    return json.dumps(roster, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _recompute_roster_cache(conn: sqlite3.Connection, room_id: str,
                            commit: bool = True) -> None:
    """Refresh the local roster cache row for a room from current membership.

    Single-node P1a writes the leader's own authoritative view (from_node =
    leader_node, mac empty — there is no cross-node link to sign with yet).
    P4 replaces this with the leader-MAC'd roster received over the node-link.

    `commit=False` lets bump_epoch fold the cache write into the SAME
    transaction as the epoch increment (atomic — codex Phase-4 r3 F2 nit). The
    create_room path keeps commit=True (it is a standalone epoch-0 cache seed).
    """
    roster = roster_for(conn, room_id)
    room = require_room(conn, room_id)
    conn.execute(
        "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
        "members_json, from_node, mac, fetched_ts) VALUES (?, ?, ?, ?, ?, ?)",
        (
            room_id,
            roster["epoch"],
            json.dumps(roster["members"], separators=(",", ":")),
            room["leader_node"] or "",
            "",
            now_ts(),
        ),
    )
    if commit:
        conn.commit()


def approve_join(conn: sqlite3.Connection, room_id: str, agent: str,
                 node: str = "") -> int:
    """Admit a member: add row, bump epoch, recompute roster. Returns new epoch.

    The leader-auth check is the CLI's responsibility (it has the caller
    identity); this helper performs the state transition atomically once
    authorized.
    """
    require_room(conn, room_id)
    add_member(conn, room_id, agent, node, role=ROLE_MEMBER)
    set_join_request_status(conn, room_id, agent, node, JOIN_APPROVED)
    # bump_epoch re-persists room_roster_cache atomically (centralized in F2),
    # so no explicit _recompute_roster_cache call is needed here.
    return bump_epoch(conn, room_id)


def remove_and_bump(conn: sqlite3.Connection, room_id: str, agent: str,
                    node: str = "") -> int:
    """Remove a member (leave/kick), bump epoch, recompute roster.

    Returns the new epoch. Raises RoomsError(code='not_member') if the
    target was not a member (so leave/kick of a non-member is loud, not a
    silent epoch bump).
    """
    require_room(conn, room_id)
    removed = remove_member(conn, room_id, agent, node)
    if not removed:
        raise RoomsError(
            f"{agent}@{node} is not a member of {room_id}", code="not_member",
        )
    # bump_epoch re-persists room_roster_cache atomically (centralized in F2).
    return bump_epoch(conn, room_id)


# --------------------------------------------------------------------------
# rooms_acl config (P1a parses + exposes; P1b enforces)
# --------------------------------------------------------------------------

def set_acl_mode(conn: sqlite3.Connection, mode: str) -> None:
    if mode not in (ACL_OFF, ACL_ENFORCE):
        raise RoomsError(
            f"invalid rooms_acl mode: {mode!r} (expected off|enforce)",
            code="bad_acl_mode",
        )
    conn.execute(
        "INSERT OR REPLACE INTO rooms_acl_config (k, v) VALUES (?, ?)",
        (_ACL_CONFIG_KEY, mode),
    )
    conn.commit()


def rooms_acl_mode(conn: Optional[sqlite3.Connection] = None) -> str:
    """Return the configured rooms_acl mode (default 'off').

    P1a never enforces — this is the read-only accessor P1b's queue gate
    consumes. When no db exists (no rooms ever defined) the mode is 'off'
    (back-compat: the ACL only engages once an operator opts in).
    """
    own = False
    if conn is None:
        conn = open_rooms_readonly()
        if conn is None:
            return ACL_OFF
        own = True
    try:
        row = conn.execute(
            "SELECT v FROM rooms_acl_config WHERE k=?", (_ACL_CONFIG_KEY,)
        ).fetchone()
    except sqlite3.Error:
        return ACL_OFF
    finally:
        if own:
            conn.close()
    if row is None:
        return ACL_OFF
    val = str(row["v"]).strip().lower()
    return val if val in (ACL_OFF, ACL_ENFORCE) else ACL_OFF
