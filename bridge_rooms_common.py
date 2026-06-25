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
import re
import secrets
import sqlite3
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

# --------------------------------------------------------------------------
# #2079 admin-signal (cross-server routing authz). TRI-STATE, never a bool.
# --------------------------------------------------------------------------
#
# A roster member carries a `bridge_admin` classification: is this member the
# CONFIGURED bridge-admin of ITS OWN node? The receiver/relay authz predicate
# (admin_cross_node_authz) uses it to enforce the operator rule "an admin-
# involved cross-node room delivery is allowed ONLY when BOTH endpoints are
# configured admins".
#
# It is deliberately TRI-STATE — `admin` / `non_admin` / `unknown` — NOT a
# bool with a false default. Codex r1 (design review): a bool that defaults to
# false on absent/legacy metadata is a SILENT DOWNGRADE — a real admin whose
# node has not yet broadcast a v2 roster would read as non-admin and a hostile
# `admin@B -> nonadmin@A` would slip through as "non-admin to non-admin". So an
# absent/malformed bit MUST stay `unknown` and fail-closed for any admin-
# involved cross-node delivery; only a KNOWN-non-admin pair (or unknown traffic
# during rollout, see ADMIN_AUTHZ_COMPAT_OPEN) is allowed.
#
# Wire/cache encoding (keeps the signed roster bytes backward compatible):
#   - known admin     -> member dict has "bridge_admin": true
#   - known non-admin -> member dict has "bridge_admin": false
#   - unknown         -> the "bridge_admin" key is ABSENT (a legacy/pre-#2079
#                        roster, or a node that could not classify the member)
# Encoding the unknown state as KEY-ABSENT (rather than null) means a roster
# from a node that predates #2079 deserializes to unknown automatically, and an
# all-known roster's bytes only grow by the explicit true/false members.
ADMIN_TRI_ADMIN = "admin"
ADMIN_TRI_NON_ADMIN = "non_admin"
ADMIN_TRI_UNKNOWN = "unknown"

# room_members.admin column encoding (tri-state in one INTEGER column):
#   1  -> known admin
#   0  -> known non-admin
#  -1  -> unknown (legacy row, or a cross-node member whose node did not attest)
# A column added by migration to an existing table defaults to -1 (unknown), so
# a pre-#2079 member row reads as unknown and fail-closes admin-involved cross-
# node traffic until a fresh roster reclassifies it.
ADMIN_COL_ADMIN = 1
ADMIN_COL_NON_ADMIN = 0
ADMIN_COL_UNKNOWN = -1


def admin_tri_from_col(val: Any) -> str:
    """Map a stored room_members.admin INTEGER to the tri-state string."""
    try:
        n = int(val)
    except (TypeError, ValueError):
        return ADMIN_TRI_UNKNOWN
    if n == ADMIN_COL_ADMIN:
        return ADMIN_TRI_ADMIN
    if n == ADMIN_COL_NON_ADMIN:
        return ADMIN_TRI_NON_ADMIN
    return ADMIN_TRI_UNKNOWN


def admin_col_from_bool(is_admin: Optional[bool]) -> int:
    """Map a known/unknown admin classification to the stored INTEGER.

    `None` (could-not-classify) stores as UNKNOWN, not non-admin — never let an
    indeterminate classification masquerade as a known-non-admin (the downgrade
    Codex r1 flagged).
    """
    if is_admin is None:
        return ADMIN_COL_UNKNOWN
    return ADMIN_COL_ADMIN if is_admin else ADMIN_COL_NON_ADMIN


def admin_col_from_tri(tri: str) -> int:
    """Map a tri-state string back to the stored INTEGER (round-trips _from_col)."""
    if tri == ADMIN_TRI_ADMIN:
        return ADMIN_COL_ADMIN
    if tri == ADMIN_TRI_NON_ADMIN:
        return ADMIN_COL_NON_ADMIN
    return ADMIN_COL_UNKNOWN


def admin_tri_from_member(m: dict) -> str:
    """The tri-state classification of a roster MEMBER DICT (wire/cache form).

    KEY-ABSENT -> unknown (legacy/pre-#2079 roster, or an unattested member).
    A present "bridge_admin" must be a real bool; anything else is unknown
    (never half-trusted into a known state).
    """
    if "bridge_admin" not in m:
        return ADMIN_TRI_UNKNOWN
    val = m.get("bridge_admin")
    if val is True:
        return ADMIN_TRI_ADMIN
    if val is False:
        return ADMIN_TRI_NON_ADMIN
    return ADMIN_TRI_UNKNOWN


def configured_admin_agent_id() -> str:
    """This node's CONFIGURED admin agent id (canonical NAME), or '' if unset.

    Source is `$BRIDGE_ADMIN_AGENT_ID` — the controller exports it into the
    launch env (see bridge-config.py admin_agent_id / bridge-run.sh). It is the
    canonical admin NAME for THIS node, NOT a trust signal on its own: it only
    classifies an agent on THIS node as admin/non-admin so the cross-node authz
    predicate can apply the symmetric admin↔admin rule. A renamed admin works
    because the comparison is against the configured id, never the literal
    `patch`.
    """
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


class AdminIdResolveError(Exception):
    """A configured roster file EXISTS but could not be read/decoded.

    #2081 r2 review F1: this is DISTINCT from "the roster has no admin line"
    (which returns ''). A read/parse failure on an existing roster must NOT be
    silently downgraded to "no admin configured" — that would re-open the very
    fail-open this fix closes (a real local admin would classify UNKNOWN and a
    non-admin@remote -> admin@local delivery would be allowed). The caller MUST
    fail-closed (refuse to serve) rather than serve with the admin boundary
    silently disabled.
    """


# A configured admin agent id is the canonical agent NAME — the same restricted
# charset agent creation enforces (alnum, dot, underscore, hyphen). #2081 r3
# review F1: we use this to REJECT a malformed/truncated roster value (e.g. an
# unbalanced-quote `BRIDGE_ADMIN_AGENT_ID="padmin` partial write) rather than
# export garbage that would misclassify the real admin and fall open.
_ADMIN_ID_VALID_RE = re.compile(r'^[A-Za-z0-9._-]+$')


def _parse_admin_id_from_roster(path: Path) -> tuple[bool, str]:
    """Extract `BRIDGE_ADMIN_AGENT_ID` from an on-disk roster file.

    Returns a tri-state `(found, value)`:
      - (False, "") : the file has NO BRIDGE_ADMIN_AGENT_ID assignment — the
                      caller continues to the next roster (this is NOT this
                      file's admin).
      - (True, "")  : the file's effective assignment is EMPTY (`...=` or `=""`)
                      — #2081 r3 review F2: bash `source` would leave the var
                      empty here, so the caller must STOP and treat the node as
                      "no admin configured" rather than fall through to a stale
                      higher-precedence-but-earlier-sourced roster.
      - (True, id)  : the effective configured admin NAME.

    Reads the SAME line `bridge-setup.sh` (`bridge_setup_write_local_scalar`)
    writes — `BRIDGE_ADMIN_AGENT_ID="<value>"` — tolerating an optional leading
    `export ` and trailing comment. We grep rather than `source` the roster
    because it references bridge-lib arrays / functions not loaded in the
    receiver's bare process, so a `source` would error out.

    #2081 r2 review F2: a roster can carry MORE THAN ONE assignment (a stale
    `export BRIDGE_ADMIN_AGENT_ID="old"` above setup's later canonical line).
    Bash `source` keeps the LAST assignment, so we take the LAST match.

    #2081 r3 review F1: a malformed quoted value (unbalanced quotes from a
    truncated/partial write) is a corruption, NOT a valid id — we RAISE
    ValueError so the caller fail-closes (refuses to serve) instead of exporting
    a garbage value that misclassifies the real admin and re-opens the fail-open.
    An EMPTY value is valid (it means no admin); a non-empty value must match the
    restricted agent-id charset.

    Raises FileNotFoundError if the file is absent (the caller treats absence as
    "not a candidate"); raises any OTHER OSError / UnicodeDecodeError to the
    caller (an EXISTING-but-unreadable roster — review F1 fail-closed signal).
    """
    # #2081 r5-round5 review: decode the RAW bytes WITHOUT universal-newline
    # translation. `Path.read_text()` (newline=None) rewrites a lone `\r` (and
    # `\r\n`) to `\n`, which would SPLIT a `"padmin"\r#evil` line at the `\r` and
    # make the regex capture just `"padmin"` — diverging from bash, which sees the
    # literal `\r` as part of the value (CR is not IFS word-whitespace). Reading
    # the undecoded bytes keeps us byte-faithful to what bash sources. A decode
    # error raises UnicodeDecodeError to the caller (existing-but-unreadable →
    # fail-closed), same as before.
    text = path.read_bytes().decode("utf-8")  # may raise to the caller
    # Match a plain `=` OR a `+=` append (#2081 r5 review). We do NOT honor `+=`
    # as a true append against a prior value — a roster admin id is a single
    # canonical name, and an append into it is a corruption/tamper signal — but
    # we MUST match the line so it cannot be silently ignored (which would make
    # us fall through to a stale earlier roster). The `+=` form is handled below.
    # `(?m)$` matches before `\n` ONLY (not before a bare `\r`), and `.` excludes
    # `\n` but KEEPS `\r`, so a `\r` stays in the captured RHS as bash sees it.
    pat = re.compile(
        r'^[ \t]*(?:export[ \t]+)?BRIDGE_ADMIN_AGENT_ID(\+?=)(.*)$', re.MULTILINE)
    matches = pat.findall(text)
    if not matches:
        return False, ""
    # LAST assignment wins (bash source semantics). The capture starts RIGHT
    # after `=` and includes any leading whitespace — and #2081 r3-round4 review
    # F1: in a bash assignment `KEY= padmin`, whitespace immediately after `=`
    # makes the VALUE EMPTY (the rest is a separate command/word, not the value).
    # So we must NOT lstrip the RHS before parsing; a leading-whitespace (or
    # empty) RHS is an empty value, not `padmin`.
    op, raw = matches[-1]
    if op == "+=":
        # A `+=` on this var is not a shape setup ever writes; refuse rather than
        # guess the appended value (fail closed → caller refuses to serve).
        raise ValueError(
            "BRIDGE_ADMIN_AGENT_ID uses '+=' (append) — unsupported / malformed")
    value = _unquote_roster_value(raw)  # raises ValueError on malformed quoting
    if value and not _ADMIN_ID_VALID_RE.match(value):
        raise ValueError(
            f"BRIDGE_ADMIN_AGENT_ID has an invalid agent-id value {value!r}")
    return True, value


def _unquote_roster_value(raw: str) -> str:
    """Decode the RHS of a roster `KEY=<raw>` assignment to its bash value.

    `raw` is the text RIGHT after `=`, with leading whitespace PRESERVED (the
    caller does not lstrip it). Validates the COMPLETE RHS grammar so a malformed
    value cannot be silently TRUNCATED to a valid-looking id and exported:

      * #2081 r3-round4 review F1: LEADING whitespace after `=` means the bash
        VALUE IS EMPTY (`KEY= padmin` assigns `KEY=""` and runs `padmin` as a
        separate word). So a raw that is empty OR begins with whitespace yields
        '' (no admin) — NOT the trailing word.
      * Double/single-quoted: `"value"` / `'value'`, then ONLY optional trailing
        whitespace + an optional `# comment`. Junk fused to the closing quote
        (`"padmin"evil`) is malformed (bash would concatenate to `padminevil` —
        we refuse to honor that and RAISE rather than truncate to `padmin`). An
        unterminated quote (`"padmin`, a partial write) is malformed.
      * Bare token: a run of non-whitespace; a `#` is a comment delimiter ONLY
        when whitespace-separated (`padmin # c`), exactly as bash word-splitting
        treats it — so `padmin#evil` is the LITERAL token `padmin#evil`, NOT
        `padmin`. The token then faces the restricted agent-id charset check in
        the caller, so `padmin#evil` fail-closes (raises) instead of truncating.

    Raises ValueError on any malformed RHS; the caller maps it to
    AdminIdResolveError so the receiver refuses to serve rather than serve with a
    wrong/garbage admin id.
    """
    # Leading whitespace (or an all-whitespace / empty RHS) → empty value: bash
    # assigns `KEY=""` and treats the rest as a separate command/word.
    if raw == "" or raw[:1] in (" ", "\t"):
        return ""
    if raw[:1] in ('"', "'"):
        q = raw[0]
        end = raw.find(q, 1)
        if end == -1:
            raise ValueError(
                "BRIDGE_ADMIN_AGENT_ID has an unbalanced quote (malformed / "
                "truncated roster line)")
        value = raw[1:end]
        rest = raw[end + 1:]
        # #2081 r5 review: ONLY whitespace + an optional `# comment` may follow
        # the closing quote. Anything ELSE fused to the close quote is bash
        # CONCATENATION (`"padmin"evil` -> padminevil, `"padmin"#evil` ->
        # padmin#evil — a `#` with no preceding whitespace is NOT a comment). We
        # refuse to honor concatenation (it never appears in a real admin id) and
        # RAISE rather than silently truncate to `padmin`. A `# comment` is a
        # comment ONLY when whitespace-separated from the closing quote.
        if rest and rest[:1] not in (" ", "\t"):
            raise ValueError(
                "BRIDGE_ADMIN_AGENT_ID has junk/concatenation fused to the "
                f"closing quote ({rest!r}) — malformed")
        rest_stripped = rest.lstrip(" \t")
        if rest_stripped and not rest_stripped.startswith("#"):
            raise ValueError(
                "BRIDGE_ADMIN_AGENT_ID has trailing junk after the closing "
                f"quote ({rest_stripped!r}) — malformed")
        return value
    # Bare token. A `#` is a comment ONLY when word-whitespace-separated (bash
    # word splitting), so a `#` fused into the token stays part of it. #2081
    # r5-round5 review: bash IFS word-whitespace is ONLY space/tab/newline — NOT
    # vertical-tab/form-feed/carriage-return — so we split on space/tab ONLY
    # (`[ \t]`), never Python's `str.split()` (which also splits on \v\f\r and
    # would diverge from bash). A VT/FF/CR therefore stays IN the token and is
    # rejected by the caller's strict agent-id charset, exactly as a fused `#` /
    # quote / `$` is — never silently truncated to a valid prefix.
    no_comment = re.split(r'[ \t]#', raw, maxsplit=1)[0]
    fields = [f for f in re.split(r'[ \t]+', no_comment) if f]
    if not fields:
        return ""
    if len(fields) > 1:
        # `padmin extra` — bash would assign only `padmin`, but extra bare words
        # on an assignment line are a corruption signal here; refuse rather than
        # silently keep the first field.
        raise ValueError(
            "BRIDGE_ADMIN_AGENT_ID has unexpected trailing words "
            f"({fields[1:]!r}) — malformed")
    return fields[0]


def resolve_admin_agent_id() -> str:
    """The configured admin id, env-first then resolved from the on-disk roster.

    SECURITY (#2081 fail-open fix). The cross-node admin↔admin authz predicate
    recomputes a LOCAL endpoint's admin status from `$BRIDGE_ADMIN_AGENT_ID`
    (`classify_local_admin`). But the receiver LAUNCH paths do NOT all export it:
    `agent-bridge` skips the parent roster-load for `a2a`, `bridge_a2a_receiver_
    start` sources only `agent-env.local.sh`, and the systemd handoffd unit runs
    with only `BRIDGE_HOME` in its environment. With the var absent a LOCAL admin
    classifies as UNKNOWN, so a `non-admin@remote -> admin@local` cross-node
    delivery flips from the intended DENY (`sender_not_admin`) to ALLOW
    (`not_admin_involved`) — a fail-OPEN of the admin boundary.

    The fix is to make the configured admin id AVAILABLE on the launch path, NOT
    to blanket-fail-closed on a local UNKNOWN: a node that legitimately has no
    configured admin (or whose two endpoints are both non-admins — the common
    case) must keep delivering non-admin↔non-admin room traffic. Blanket-unknown-
    deny would break exactly that traffic. So we resolve the admin NAME the same
    way setup persists it (the roster file) and let `classify_local_admin` make
    the correct admin/non-admin call.

    Precedence: an already-exported env value WINS (the normal managed-agent
    launch via bridge-run.sh, and the controller's own ambient env). Only when
    env is empty do we read `$BRIDGE_HOME/agent-roster.local.sh` then
    `agent-roster.sh`.

    Returns '' ONLY for a node with no configured admin in any READABLE roster
    (correctly leaves every local endpoint UNKNOWN, which keeps non-admin traffic
    open and fail-closes only an admin-claimed counterpart). #2081 r2 review F1:
    if a roster file EXISTS but cannot be read/decoded — or carries a malformed
    (unbalanced-quote / invalid-charset) value (#2081 r3 review F1) — we RAISE
    AdminIdResolveError rather than return '' or a garbage value. The caller
    fail-closes (refuses to serve) rather than serve with a wrong/absent admin id.

    #2081 r3 review F2: the LOCAL roster has precedence over the shared roster
    because bash sources the shared roster FIRST and the local roster LAST, so
    the local last-assignment is the effective value. A local assignment that is
    PRESENT-BUT-EMPTY (`BRIDGE_ADMIN_AGENT_ID=`) therefore means "no admin" and
    must STOP the search — NOT fall through to a stale `="admin"` in the shared
    roster, which bash would have overwritten.
    """
    env_val = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()
    if env_val:
        return env_val
    # Honor the explicit roster-path overrides (set by bridge-lib.sh and by the
    # isolated-smoke harness) the same way the shell side does, else derive from
    # BRIDGE_HOME exactly as setup persists it. Local roster wins over the shared
    # roster (bash sources shared first, local last → local is effective).
    home = bridge_home()
    candidates: list[Path] = []
    local_override = os.environ.get("BRIDGE_ROSTER_LOCAL_FILE", "").strip()
    if local_override:
        candidates.append(Path(local_override))
    candidates.append(home / "agent-roster.local.sh")
    shared_override = os.environ.get("BRIDGE_ROSTER_FILE", "").strip()
    if shared_override:
        candidates.append(Path(shared_override))
    candidates.append(home / "agent-roster.sh")
    seen: set[str] = set()
    for path in candidates:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        try:
            found, value = _parse_admin_id_from_roster(path)
        except FileNotFoundError:
            # Not a candidate on this node — not an error; try the next.
            continue
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            # The file EXISTS but could not be read/decoded (perms, partial
            # write, binary garbage) OR carries a malformed/invalid value. Do
            # NOT silently downgrade to "no admin" / export garbage — fail closed
            # so the caller refuses to serve fail-open (F1).
            raise AdminIdResolveError(
                f"roster {path} has an unreadable/invalid admin id: {exc}") from exc
        if found:
            # The first roster (in bash-effective precedence) that ASSIGNS the
            # var is authoritative — even if it assigns EMPTY (F2). Do not fall
            # through to a stale earlier-sourced roster.
            return value
    return ""


def ensure_admin_agent_id_in_env() -> str:
    """Resolve the configured admin id and stamp it into `os.environ` if unset.

    Called at receiver STARTUP (`bridge-handoffd.py serve`) so the admin↔admin
    authz predicate can classify a LOCAL admin correctly for the lifetime of the
    serve, regardless of which launch path (systemd unit / `agb a2a daemon
    start` / direct daemon start) reached us. Idempotent and side-effect-free
    when the env already carries the value. Returns the resolved id ('' if none).

    Propagates AdminIdResolveError (review F1) when an existing roster is
    unreadable, so the serve entrypoint can fail closed rather than start with
    the admin boundary silently disabled.
    """
    resolved = resolve_admin_agent_id()
    if resolved and not os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip():
        os.environ["BRIDGE_ADMIN_AGENT_ID"] = resolved
    return resolved


def classify_local_admin(agent: str) -> Optional[bool]:
    """KNOWN admin/non-admin classification of a LOCAL agent, or None if unknown.

    Returns:
      - True  : `agent` is this node's configured admin.
      - False : this node HAS a configured admin and `agent` is not it.
      - None  : this node has NO configured admin id (cannot classify) -> the
                caller stores/treats this as UNKNOWN, never as non-admin (the
                downgrade Codex r1 flagged). A node that never configured an
                admin id has no admins to protect, but we refuse to silently
                assert non-admin for an endpoint we cannot actually classify.
    """
    admin_id = configured_admin_agent_id()
    if not admin_id:
        return None
    return str(agent) == admin_id

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

# Lane 4 (#1695) SK-1: default lifetime (seconds) of a v2 SIGNED invite LINK —
# distinct from the room invite TOKEN's own server-side TTL (rooms.invite_token_ttl,
# 0 == none). The signed link carries `iat`/`ttl` in its token-signed canonical
# and the joiner enforces `iat + ttl < now → invite_expired` BEFORE first contact,
# so a stale/leaked link stops being usable even while the underlying token is
# still server-valid. 24h is a sane default for a hand-distributed invite.
DEFAULT_SIGNED_INVITE_LINK_TTL_SECONDS = 86400


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
    """Gate for the rooms actor-auth TEST overrides — structurally prod-inert.

    Three conditions, ALL required:
      1. BOTH `BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1` AND `BRIDGE_A2A_ALLOW_TEST_
         BIND=1` (paired flag; a single stray var cannot relax the contract).
      2. The current process uid OWNS the rooms DB, OR the rooms DB does not
         exist yet. This is the STRUCTURAL prod-inert gate (codex Phase-4 r2
         finding 2): the test overrides (`BRIDGE_ROOMS_TEST_ISO_USER`,
         `_CONTROLLER_UID`, `_HOST_HAS_ISO`) directly override the security
         decision, so flags alone (which a managed agent CAN set) are not
         enough. In a real iso-v2 deployment the rooms DB is controller-owned
         and a managed agent (`agent-bridge-<a>`, a different uid) does NOT own
         it → this returns False → the test overrides are IGNORED → the agent
         falls through to the real, un-spoofable OS-fact checks. In the smoke
         the test runner owns the DB it created, so the overrides are honored.
    A non-existent DB allows the overrides so the smoke can drive the
    pre-create / create paths; an attacker pointing at a self-owned fake DB to
    pass this gate gains nothing — it can only override decisions about a fake
    DB that has zero effect on any real room.
    """
    if (os.environ.get("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP") != "1"
            or os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") != "1"):
        return False
    try:
        return os.stat(str(rooms_db_path())).st_uid == os.getuid()  # noqa: raw-pathlib-controller-only
    except OSError:
        # DB absent → allow (pre-create/create test paths); a real managed
        # agent on an iso host with an existing controller-owned DB is gated out
        # by the ownership check above.
        return True


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


def process_os_user() -> str:
    """The process's ACTUAL OS username (a passwd fact) — un-spoofable.

    The leader-auth comparison anchor: `require_leader_actor` compares this
    against `default_os_user_slug(room.leader_agent)`. A paired-flag test
    override (`BRIDGE_ROOMS_TEST_ISO_USER`) lets the smoke simulate the
    process OS user; NEVER honored in production.
    """
    if _test_uid_map_allowed():
        forced = os.environ.get("BRIDGE_ROOMS_TEST_ISO_USER")
        if forced is not None:
            return forced.strip()
    if pwd is None:
        return ""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError):
        return ""


def _host_has_iso_users() -> bool:
    """True iff ANY `agent-bridge-*` user exists in the passwd database.

    An UN-SPOOFABLE host fact (the passwd DB, not env/roster/subprocess) used
    to tell a genuine shared-mode install (no iso users -> advisory) apart
    from an iso host where a stray non-iso non-controller process must fail
    CLOSED. A paired-flag `BRIDGE_ROOMS_TEST_HOST_HAS_ISO` override lets the
    smoke drive both sides; NEVER honored in production.
    """
    if _test_uid_map_allowed():
        forced = os.environ.get("BRIDGE_ROOMS_TEST_HOST_HAS_ISO", "").strip()
        if forced in ("0", "1"):
            return forced == "1"
    if pwd is None:
        return False
    try:
        for entry in pwd.getpwall():
            if entry.pw_name.startswith(ISO_OS_USER_PREFIX):
                return True
    except (KeyError, OSError):
        return False
    return False


def _controller_uid() -> Optional[int]:
    """The controller/operator uid — the OWNER OF THE ACTUAL rooms DB.

    Anchored to `os.stat(rooms_db_path()).st_uid`, NOT to `bridge_home()`
    (codex Phase-4 r2 BLOCK). Rationale: to affect a real room you MUST operate
    on the real rooms.db, which in iso-v2 lives under `state/handoff/` and is
    controller-owned (a non-root managed agent cannot chown it). A managed
    agent that forges `BRIDGE_HOME` to a self-owned dir while pinning the real
    DB via `BRIDGE_A2A_ROOMS_DB`/`BRIDGE_STATE_DIR` no longer passes this check
    (the real DB is not theirs); and if it instead points the DB at a self-
    owned fake, it becomes "controller" of a DB that has ZERO effect on the
    real room. Either way the BRIDGE_HOME spoof is dead. A genuine operator who
    owns the real DB still gets the controller bypass.

    Deliberately does NOT trust `BRIDGE_CONTROLLER_UID` from env (caller-set).
    Returns None when the DB does not exist or cannot be stat'd → the
    controller bypass is then unavailable (fail-closed safe default). A
    `BRIDGE_ROOMS_TEST_CONTROLLER_UID` override exists ONLY behind the paired
    test flag — NEVER honored in production.
    """
    if _test_uid_map_allowed():
        raw = os.environ.get("BRIDGE_ROOMS_TEST_CONTROLLER_UID", "").strip()
        if raw.lstrip("-").isdigit():
            return int(raw)
    db = rooms_db_path()
    try:
        return os.stat(str(db)).st_uid  # noqa: raw-pathlib-controller-only
    except OSError:
        # DB absent (e.g. first `create`) or unreadable → no controller bypass.
        return None


def host_has_iso_users() -> bool:
    """Public: True iff the host has any `agent-bridge-*` OS user (an iso-v2 host).

    An un-spoofable passwd fact (wraps `_host_has_iso_users`). Used by the queue
    gate to tell a genuine iso-v2 host (a hard team boundary exists) from a
    shared-mode install (no iso users → no OS separation → ACL is advisory).
    On a shared-mode host the gateway never legitimately runs, so even a forged
    gateway-child env must be treated as advisory (§14 R1: shared-mode stays
    advisory either way), never a hard block.
    """
    return _host_has_iso_users()


def is_controller_process() -> bool:
    """True iff THIS process runs as the controller (the rooms.db OWNER uid).

    The un-forgeable anchor for "was this process spawned BY the controller?"
    (P1b r2): the queue gateway runs as the controller and spawns the queue
    child IN-PROCESS (no uid drop), so a gateway-spawned `bridge-queue.py` has
    `os.getuid() == _controller_uid()`. A DIRECT managed-agent invocation runs
    as the agent uid (`agent-bridge-<a>`), which is NOT the controller — so it
    CANNOT forge gateway-child status by merely exporting
    `BRIDGE_QUEUE_GATEWAY_SERVER`/`BRIDGE_QUEUE_GATEWAY_ACTOR`. The controller
    identity is anchored to the rooms.db owner (`_controller_uid`), the same
    un-spoofable anchor P1a uses (a managed agent cannot chown the controller-
    owned rooms.db).

    Returns False when the controller uid cannot be established (no rooms.db)
    — a fail-closed default: an un-anchored process is never treated as the
    controller.
    """
    controller = _controller_uid()
    return controller is not None and os.getuid() == controller


def default_os_user_slug(agent: str) -> str:
    """The default iso OS-user for `agent` — `agent-bridge-<slug>`.

    Byte-for-byte reproduction of lib/bridge-agents.sh `bridge_agent_default_
    os_user` (lowercase, `[^a-z0-9_-]+`→`-`, strip dashes, prefix, truncate to
    32). This is a PURE function of the (trusted, in-db) leader_agent, so the
    leader-auth check needs NO roster/probe/env — it compares the process's
    actual OS username (a passwd fact) against this expected value, structurally
    eliminating the roster-injection / TOCTOU class (codex Phase-4 r5/r6).
    """
    import re

    slug = re.sub(r"[^a-z0-9_-]+", "-", agent.strip().lower()).strip("-") or "agent"
    keep = max(1, 32 - len(ISO_OS_USER_PREFIX))
    return ISO_OS_USER_PREFIX + slug[:keep]


def resolve_os_actor(requested: Optional[str] = None) -> ActorAuth:
    """Resolve the trusted control-plane actor from the PROCESS OS identity.

    `requested` is the caller-supplied agent (`--as`/env). It is honored ONLY
    in the regimes that explicitly permit it (CONTROLLER, SHARED_ADVISORY) and
    is IGNORED for the leader-auth decision under ISO_ENFORCED.

    The decision is ANCHORED on the un-spoofable OS username (`_process_iso_
    user`), NOT on any roster probe / env, so a managed iso agent cannot
    sabotage or redirect a probe to spoof or downgrade its identity (codex
    Phase-4 r4-r6). For an iso agent the `agent` field carries the slug derived
    from the OS username; leader-auth (`require_leader_actor`) compares the
    process's OS username against `default_os_user_slug(room.leader_agent)`, so
    NO roster lookup is on the security path. See the section header.
    """
    uid = os.getuid()
    iso_user = _process_iso_user()

    if iso_user is not None:
        # We ARE an iso agent (passwd fact). The trusted identity is our OS
        # username's slug (prefix stripped). Leader-auth compares the FULL OS
        # username against the expected user for the room leader
        # (`default_os_user_slug`), so NO roster lookup is on the security path
        # — the slug here is an advisory display/audit value.
        slug = iso_user[len(ISO_OS_USER_PREFIX):]
        return ActorAuth(agent=slug, regime=ACTOR_ISO_ENFORCED,
                         uid=uid, hard=True)

    # NOT an iso OS user. The CONTROLLER check is now anchored to the owner of
    # the ACTUAL rooms DB (`_controller_uid` -> stat(rooms_db_path)), which a
    # managed agent cannot forge: to affect a real room you must operate on the
    # real (controller-owned) DB; a self-owned fake DB mutates nothing real
    # (codex Phase-4 r2). So the controller grant is un-spoofable here even
    # though BRIDGE_HOME is env-derived — the old forged-BRIDGE_HOME bypass is
    # dead. We check it FIRST so a genuine operator (who owns the real DB) is
    # recognized regardless of the iso-host classification.
    controller = _controller_uid()
    if controller is not None and uid == controller:
        agent = (requested
                 or os.environ.get("BRIDGE_AGENT_ID")
                 or os.environ.get("USER")
                 or "")
        return ActorAuth(agent=str(agent).strip(), regime=ACTOR_CONTROLLER,
                         uid=uid, hard=False)

    # Not the DB owner. On an ISO HOST (any `agent-bridge-*` user exists in the
    # passwd DB — an un-spoofable fact), a non-iso non-DB-owner process is
    # anomalous → FAIL CLOSED (UNRESOLVED); it must not fall to advisory (which
    # honors --as with only a warning). _host_has_iso_users() failing safe to
    # False on a passwd error is now acceptable because the controller grant
    # above already requires owning the real DB — a passwd-error downgrade can
    # at most reach the advisory path below, never a false controller ALLOW.
    if _host_has_iso_users():
        return ActorAuth(agent="", regime=ACTOR_UNRESOLVED, uid=uid, hard=True)

    # No iso users on the host → a genuine shared-mode / single-user install,
    # which has NO hard team boundary anyway → advisory (warn, never block).
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


def _path_is_within(child: Path, parent: Path) -> bool:
    """True iff `child` resolves to `parent` or a descendant of it.

    Pure lexical containment on the *resolved* (symlink-collapsed, absolute)
    forms — no filesystem write, safe to call before any dir exists. Parallels
    the A2A-common helper of the same name (this module duplicates
    `bridge_home`/`state_dir`/`handoff_dir` rather than import-coupling to the
    lower layer at module load).
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

    The rooms-side mirror of `bridge_a2a_common.guard_test_bind_state_path`
    (issue #1728). `BRIDGE_A2A_ALLOW_TEST_BIND=1` is TEST-ONLY — production
    never sets it — so this guard cannot affect a production install. When the
    flag is set AND the resolved rooms/handoff state dir is NOT under the
    active `BRIDGE_HOME` (a `BRIDGE_STATE_DIR` override pointing at the live
    state tree), refuse with a clear message so a throwaway test mesh cannot
    silently clobber the live rooms.db / reconcile.db.

    NOTE (#1728 r2): the state-dir check alone misses the explicit
    `BRIDGE_A2A_ROOMS_DB` override, which bypasses `state_dir()` entirely. The
    db-path containment is enforced at the `_connect()` choke point via
    `guard_test_bind_db_path()` — this entry stays for callers that guard on the
    state dir directly.
    """
    guard_test_bind_db_path(state_dir(), what="rooms state dir")


def guard_test_bind_db_path(path: Path, *, what: str = "rooms db path") -> None:
    """Fail closed when a test-bind mesh would write `path` into a live tree.

    The db-path-aware core of the #1728 rooms guard, mirroring
    `bridge_a2a_common.guard_test_bind_db_path`. `_connect()` calls it with the
    FINAL resolved rooms.db path — which includes any explicit
    `BRIDGE_A2A_ROOMS_DB` override that bypasses `state_dir()`. Under the
    test-bind flag, ANY resolved write path outside the active `BRIDGE_HOME`
    fails closed. No-op when the flag is unset (prod) or the path is under home
    (a correctly isolated mesh, including an override pointed UNDER the test
    home).
    """
    if os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") != "1":  # noqa: iso-helper-boundary - env var, not a .env file
        return
    home = bridge_home()
    if _path_is_within(path, home):
        return
    raise RoomsError(
        f"BRIDGE_A2A_ALLOW_TEST_BIND=1 (test mode) but the {what} "
        f"{str(path)!r} is outside BRIDGE_HOME {str(home)!r} — a "
        "test mesh would clobber the live rooms.db / reconcile.db. Set "
        "BRIDGE_STATE_DIR (and, if overridden, BRIDGE_A2A_ROOMS_DB / "
        "BRIDGE_A2A_RECONCILE_DB) under your test BRIDGE_HOME so test state "
        "cannot reach the live state tree.",
        code="test_bind_state_outside_home",
    )


def rooms_db_path() -> Path:
    override = os.environ.get("BRIDGE_A2A_ROOMS_DB")
    if override:
        return Path(override)
    return handoff_dir() / "rooms.db"


def canonical_rooms_db_path() -> Path:
    """The CANONICAL rooms.db location — `state/handoff/rooms.db` under the
    real bridge home, IGNORING the caller-redirectable `BRIDGE_A2A_ROOMS_DB`.

    This is the ONLY path the controller-bootstrap (`maybe_bootstrap_rooms_db`)
    is permitted to create. `rooms_db_path()` honors `BRIDGE_A2A_ROOMS_DB` so a
    managed agent could point it at a self-owned dir; the bootstrap must NOT
    follow that override (else a managed agent could seed a self-owned rooms.db
    and become "controller" — the P1b bypass class). It still resolves
    `BRIDGE_STATE_DIR`/`BRIDGE_HOME` (the legitimate isolated-install knobs),
    consistent with the `_controller_uid` r2 model: a managed agent that forges
    those to a self-owned tree only ever owns a FAKE db that mutates no real
    room (and on a real iso-v2 host it cannot own the controller-owned state
    dir at all → the ownership gate below fails closed).
    """
    return handoff_dir() / "rooms.db"


def _caller_owns_canonical_controller_location() -> bool:
    """True iff THIS process's uid owns the CANONICAL controller location.

    The un-spoofable bootstrap gate: on a fresh host (no rooms.db yet,
    `_controller_uid()` cannot anchor) we still need to know whether the caller
    is the genuine controller before seeding the controller-owned rooms.db. The
    proof is OS-derived: `os.getuid()` must own the nearest EXISTING ancestor of
    the canonical rooms.db (the handoff dir, else the state dir, else the bridge
    home). In iso-v2 those dirs are controller-owned (a managed `agent-bridge-*`
    UID cannot own/create them), so a managed agent fails this check and STILL
    fails closed — it cannot bootstrap a self-owned db to become controller. In
    shared-mode the single user owns the whole tree, so the check passes for
    that user (consistent with the shared-mode-advisory regime).

    The positive (ALLOW) proof is STRICTLY OS-derived — there is NO env seam
    that can force it open. A paired-flag test override
    (`BRIDGE_ROOMS_TEST_OWNS_CANON=0`) may only force-DENY (to drive the
    managed-agent fail-closed leg on a host where the real uid would otherwise
    own the temp tree); a `1` is IGNORED and falls through to the real stat, so
    no env can ever GRANT this gate. Never honored in production (the paired
    flags are unset there).
    """
    if _test_uid_map_allowed():
        forced = os.environ.get("BRIDGE_ROOMS_TEST_OWNS_CANON", "").strip()
        if forced == "0":
            # Force-DENY only — used by the smoke to simulate a managed agent
            # that does NOT own the controller-owned canonical state dir. A
            # value of "1" is deliberately NOT honored: the ALLOW path must stay
            # OS-derived so the bootstrap gate cannot be opened by env.
            return False
    canon = canonical_rooms_db_path()
    me = os.getuid()
    # Walk up from the canonical db's parent to the first ancestor that exists
    # and stat its owner. The bootstrap creates the db (and any missing parent
    # dirs) under that ancestor, so owning it is the right "can I write here as
    # the controller" proof.
    probe = canon.parent
    for _ in range(64):  # bounded; canonical paths are shallow
        try:
            return os.stat(str(probe)).st_uid == me  # noqa: raw-pathlib-controller-only
        except OSError:
            parent = probe.parent
            if parent == probe:  # reached filesystem root
                return False
            probe = parent
    return False


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
  -- P4.1 (§14 R3): TTL in seconds for the current invite token. 0 == no
  -- expiry (the P1 default, back-compat: an existing room created before
  -- this column simply gets 0 and never expires). verify_invite_token
  -- enforces `invite_token_ts + invite_token_ttl >= now` when ttl > 0.
  invite_token_ttl   INTEGER NOT NULL DEFAULT 0,
  -- Lane 4 (#1695): secret-equivalent HKDF key SEED derived from the raw
  -- invite token at create/rotate time (NOT the wire-visible sha256 verifier).
  -- The leader derives the per-pair node-link key from this seed when a
  -- token-bootstrapped join arrives. NULL/'' == no seed (a P1/P4.1 room that
  -- predates token-bootstrap, or a burned/rotated-away invite). Domain-
  -- separated from invite_token_sha256 so the wire hash can never become a key.
  invite_key_seed    TEXT,
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
  -- #2079 admin-signal TRI-STATE: 1 known admin / 0 known non-admin /
  -- -1 unknown. A migrated pre-#2079 row defaults to -1 (unknown), so it
  -- fail-closes admin-involved cross-node delivery until a fresh roster
  -- reclassifies it. See ADMIN_COL_* + admin_tri_from_col.
  admin      INTEGER NOT NULL DEFAULT -1,
  PRIMARY KEY (room_id, agent, node)
);
CREATE INDEX IF NOT EXISTS idx_room_members_agent ON room_members(agent, node);

CREATE TABLE IF NOT EXISTS room_join_requests (
  room_id      TEXT NOT NULL,
  agent        TEXT NOT NULL,
  node         TEXT NOT NULL DEFAULT '',
  requested_ts INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  -- P4.1 (§11, §14 R3) cross-node forward-contract columns. They carry ONLY
  -- verified METADATA, NEVER the reusable token hash (contract 5: the hash is
  -- bearer-equivalent and is never persisted in any row):
  --   verified  : 1 when this pending row was created by the receiver AFTER
  --               the node-link HMAC + token-hash + TTL/revocation verification
  --               passed. A future cross-node `approve` (P4.2) REQUIRES a row
  --               with verified=1 (the local leader-initiated add path stays
  --               separate and does NOT claim this gate — contract 6).
  --   via_node  : the HMAC-authenticated node-link peer the request arrived
  --               over (the joiner's node, bound to the authenticated sender
  --               bridge — never a wire-asserted node).
  --   ttl_expiry: absolute unix ts after which this pending request is stale.
  --               0 == no expiry. Forward-contract for P4.2 cleanup.
  -- Existing P1 rows get verified=0 / via_node='' / ttl_expiry=0 on migration,
  -- which correctly reads as "a local single-node request, not a verified
  -- cross-node one".
  verified     INTEGER NOT NULL DEFAULT 0,
  via_node     TEXT NOT NULL DEFAULT '',
  ttl_expiry   INTEGER NOT NULL DEFAULT 0,
  -- #2079 admin-signal: the joiner node's ATTESTATION of whether the joining
  -- agent is that node's configured bridge-admin (1 admin / 0 non-admin /
  -- -1 unknown). NODE-ATTESTED, not independently verifiable — it protects
  -- against non-admin agents on an HONEST paired node, not against a malicious
  -- node lying about its own endpoint (that node already controls every agent
  -- it runs). Persisted on the pending row because cross-node approval is
  -- DEFERRED (the leader approves later), so the bit must survive from the join
  -- request to the membership add. Legacy/local rows default to -1 (unknown).
  joiner_admin INTEGER NOT NULL DEFAULT -1,
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

-- P4.1 (codex r2): cross-node room-join-request dedupe ledger. It lives in
-- rooms.db (NOT the A2A inbox.db) so the dedupe reservation and the
-- room_join_requests pending row commit in ONE transaction — "a dedupe row
-- exists" is then ATOMIC with "a pending row exists", closing the window where
-- a reservation could survive a failed pending write and let a replay return a
-- bogus idempotent-200 with no pending row. message_id is the idempotency key;
-- body_sha256 distinguishes an exact replay (duplicate) from id-reuse
-- (conflict). It carries NO token / token-hash (contract 5).
CREATE TABLE IF NOT EXISTS room_join_dedupe (
  message_id   TEXT NOT NULL,
  peer         TEXT NOT NULL DEFAULT '',
  body_sha256  TEXT NOT NULL,
  created_ts   INTEGER NOT NULL,
  -- codex P4.1 Phase-4: dedupe is scoped to the AUTHENTICATED peer. A
  -- composite (peer, message_id) PK means one authenticated peer cannot
  -- consume/block another peer's join id by reusing a message_id (the
  -- earlier message_id-only PK let nodeC pre-reserve nodeB's id).
  PRIMARY KEY (peer, message_id)
);

-- Lane 4 (#1695) SK-1: JOINER-side replay ledger for v2 signed invite links.
-- Each signed invite carries a per-issue `nonce`; the joiner records (room_id,
-- nonce) once and rejects a second presentation, so a replayed signed link
-- (e.g. an attacker re-sending an old, since-superseded link) cannot drive a
-- fresh first-contact bootstrap. Carries NO token / token-hash. Local to the
-- joiner node; the leader's server-side TTL/revocation is the orthogonal gate.
CREATE TABLE IF NOT EXISTS invite_nonce_seen (
  room_id    TEXT NOT NULL,
  nonce      TEXT NOT NULL,
  seen_ts    INTEGER NOT NULL,
  PRIMARY KEY (room_id, nonce)
);

-- Lane 5 (#1695-P2 gotcha F): LEADER-side DURABLE roster-broadcast outbox. Every
-- membership change (approve / kick / leave / deny) enqueues ONE pending row per
-- remote member node naming the room + the epoch to converge it to. The CLI
-- attempts an immediate best-effort delivery; a row that is NOT acked (member
-- node offline) survives so the periodic `roster_epoch_reconcile` heartbeat
-- re-broadcasts it until the member converges (anti-entropy — design §6/§14 R2).
-- This carries ONLY room control-plane targeting (room_id, member_node, epoch) —
-- NEVER a token / secret / roster body (the body is rebuilt from the leader's
-- authoritative rooms.db at send time, so the outbox can never go stale on a
-- later epoch bump and never persists secret material). It is keyed by
-- (room_id, member_node): one outstanding convergence target per member node,
-- the `epoch` column carrying the HIGHEST epoch that node still needs — a newer
-- membership change simply RAISES the target epoch on the existing row
-- (idempotent; epoch monotonic, never lowered). `status` is 'pending' until the
-- member acks at >= this epoch, then 'done'.
CREATE TABLE IF NOT EXISTS room_roster_outbox (
  room_id       TEXT NOT NULL,
  member_node   TEXT NOT NULL,
  epoch         INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'pending',
  attempts      INTEGER NOT NULL DEFAULT 0,
  last_error    TEXT NOT NULL DEFAULT '',
  created_ts    INTEGER NOT NULL,
  updated_ts    INTEGER NOT NULL,
  PRIMARY KEY (room_id, member_node)
);
CREATE INDEX IF NOT EXISTS idx_roster_outbox_status
  ON room_roster_outbox(status, updated_ts);
"""


def now_ts() -> int:
    return int(time.time())


def _table_has_column(conn: sqlite3.Connection, table: str, column: str) -> bool:
    """True iff `table` already has `column` (PRAGMA table_info precheck).

    A read-only probe used to decide whether an ADD COLUMN migration still needs
    to run. `PRAGMA table_info` takes no write lock, so the precheck itself can't
    be the operation that contends with the daemon's WAL writer during an upgrade
    window — only the ALTER for a genuinely-absent column does, and that lock now
    SURFACES (re-raises) instead of being swallowed (#2109 gap 1).
    """
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    for r in rows:
        # row[1] is the column name across both tuple- and Row-factory results.
        if str(r[1]) == column:
            return True
    return False


def _migrate_schema(conn: sqlite3.Connection) -> None:
    """Idempotently add columns introduced AFTER P1 to an existing rooms.db.

    `CREATE TABLE IF NOT EXISTS` never alters an existing table, so a rooms.db
    created by P1 lacks the P4.1 columns (rooms.invite_token_ttl,
    room_join_requests.{verified,via_node,ttl_expiry}). We add them with the
    same defaults the schema declares, so a migrated P1 row reads identically to
    a freshly-created one. ALTER TABLE ADD COLUMN is cheap + non-rewriting in
    SQLite. NEVER drops/rewrites data.

    Robustness (#2109 gap 1): we PRECHECK each (table, column) with
    `PRAGMA table_info` and only run the ALTER when the column is actually
    absent, so a re-run is a no-op WITHOUT relying on the engine to raise. The
    ALTER is still wrapped, but the wrapper swallows ONLY the idempotent
    "duplicate column name" race (a concurrent connection added it between our
    precheck and our ALTER) — every OTHER `OperationalError` (database is
    locked / readonly / no such table / disk full) RE-RAISES so the open fails
    and the next CLI/daemon retry re-runs the migration, rather than silently
    leaving a half-migrated schema whose next `SELECT admin` crashes.
    """
    # (table, column, ALTER statement). The ALTER's column name must match the
    # column we precheck so the precheck actually gates the right statement.
    migrations = (
        ("rooms", "invite_token_ttl",
         "ALTER TABLE rooms ADD COLUMN invite_token_ttl INTEGER NOT NULL DEFAULT 0"),
        ("room_join_requests", "verified",
         "ALTER TABLE room_join_requests ADD COLUMN verified INTEGER NOT NULL DEFAULT 0"),
        ("room_join_requests", "via_node",
         "ALTER TABLE room_join_requests ADD COLUMN via_node TEXT NOT NULL DEFAULT ''"),
        ("room_join_requests", "ttl_expiry",
         "ALTER TABLE room_join_requests ADD COLUMN ttl_expiry INTEGER NOT NULL DEFAULT 0"),
        # Lane 4 (#1695): token-bootstrap key seed. Nullable (no NOT NULL) so a
        # migrated P1/P4.1 row reads NULL == "no seed" rather than a fake value.
        ("rooms", "invite_key_seed",
         "ALTER TABLE rooms ADD COLUMN invite_key_seed TEXT"),
        # #2079 admin-signal: existing member rows predate the classification, so
        # default to -1 (unknown) — they fail-close admin-involved cross-node
        # delivery until the leader rebroadcasts a v2 roster that reclassifies
        # them. Existing join-request rows likewise carry no attested admin bit.
        ("room_members", "admin",
         "ALTER TABLE room_members ADD COLUMN admin INTEGER NOT NULL DEFAULT -1"),
        ("room_join_requests", "joiner_admin",
         "ALTER TABLE room_join_requests ADD COLUMN joiner_admin INTEGER NOT NULL DEFAULT -1"),
    )
    for table, column, stmt in migrations:
        if _table_has_column(conn, table, column):
            continue
        try:
            conn.execute(stmt)
        except sqlite3.OperationalError as exc:
            # Swallow ONLY the idempotent duplicate-column race (a concurrent
            # connection added the column between our precheck and this ALTER).
            # A lock / readonly / no-such-table / disk error must propagate so
            # the open fails and the next retry re-runs the migration instead of
            # silently leaving the column missing (#2109 gap 1).
            if "duplicate column name" not in str(exc).lower():
                raise
    conn.commit()


def _connect(path: Path, schema: str) -> sqlite3.Connection:
    # #1728 r2: guard the ACTUAL resolved db path (which may be a
    # BRIDGE_A2A_ROOMS_DB override that bypasses state_dir()) — fail closed
    # before creating/opening it if a test-bind mesh would land it on a live
    # tree outside its BRIDGE_HOME. No-op when the flag is unset (prod) or the
    # path is under home (correctly isolated mesh).
    guard_test_bind_db_path(path, what="rooms db path")
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(schema)
    _migrate_schema(conn)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return conn


def open_rooms() -> sqlite3.Connection:
    """Open (creating if absent) the rooms.db at 0600 with the frozen schema."""
    return _connect(rooms_db_path(), _ROOMS_SCHEMA)


def maybe_bootstrap_rooms_db() -> bool:
    """Controller-only auto-bootstrap of the CANONICAL rooms.db on first use.

    Closes the fresh-iso chicken-and-egg (#1517): the controller anchor
    (`_controller_uid`) stats the rooms.db OWNER, but on a brand-new install the
    db does not exist yet, so even the genuine controller's first
    `agb room create` resolves to ACTOR_UNRESOLVED (`actor_unresolved`) and is
    denied — there is no db to anchor to. This seeds the controller-owned db the
    controller then anchors to, so the very first `create` succeeds.

    Returns True iff it created the canonical db on this call (False when the db
    already exists or the caller is not the proven controller of the canonical
    location). Idempotent: a present db is left untouched (no re-bootstrap /
    clobber).

    SECURITY (the load-bearing invariant — do NOT weaken):
      - The db is created ONLY at the CANONICAL path (`canonical_rooms_db_path`,
        which ignores `BRIDGE_A2A_ROOMS_DB`). A caller cannot redirect the
        bootstrap to a self-owned location via that env override.
      - The bootstrap runs ONLY when `os.getuid()` owns the canonical controller
        location (`_caller_owns_canonical_controller_location`). On an iso-v2
        host the canonical `state/handoff` tree is controller-owned, so a
        managed `agent-bridge-*` UID does NOT own it → the bootstrap is refused
        and the agent STILL fails closed (it can never seed a self-owned db at
        the canonical path to become "controller"). In shared-mode the single
        owning user passes (consistent with shared-mode-advisory).
      - This NEVER relaxes a control-plane decision: `resolve_os_actor` still
        derives the regime from un-spoofable OS facts AFTER the (now-present) db
        anchors `_controller_uid`. A managed agent that somehow reached here on
        a fresh host gains nothing — it cannot pass the ownership gate, and even
        a forged `BRIDGE_STATE_DIR` self-owned tree yields a FAKE db that
        mutates no real room (the `_controller_uid` r2 model).
    """
    canon = canonical_rooms_db_path()
    # Only bootstrap for the path this invocation will actually anchor to: when
    # a caller redirects `BRIDGE_A2A_ROOMS_DB` elsewhere, `open_rooms()` /
    # `_controller_uid()` already use THAT path (the existing isolated-install /
    # r2 model — `_connect` creates it, the owner anchors the controller). We do
    # NOT seed a stray canonical db in that case; bootstrap is strictly for the
    # canonical first-use path.
    if rooms_db_path() != canon:
        return False
    try:
        if canon.exists():  # noqa: raw-pathlib-controller-only
            return False
    except OSError:
        return False
    if not _caller_owns_canonical_controller_location():
        # NOT the canonical controller (e.g. a managed iso agent) → refuse to
        # seed. The caller stays fail-closed (UNRESOLVED) exactly as before.
        return False
    # Create the canonical, controller-owned rooms.db (frozen schema, 0600).
    # We pin _connect to the CANONICAL path (not rooms_db_path()) so a
    # caller-supplied BRIDGE_A2A_ROOMS_DB cannot relocate the bootstrap.
    conn = _connect(canon, _ROOMS_SCHEMA)
    conn.close()
    return True


def open_rooms_readonly(
    db_path: Optional[Path] = None,
) -> Optional[sqlite3.Connection]:
    """Open an EXISTING rooms.db read-only; return None when it is absent.

    Used by read paths (the receiver seam, P1b's membership lookup) that must
    DEGRADE gracefully when no rooms have ever been defined — they must not
    create the db as a side effect of a lookup. A present-but-unreadable db
    raises RoomsError so a real fault is never silently treated as "no rooms".

    `db_path` lets a SECURITY-sensitive caller pin the EXACT rooms.db to read
    (P1b r3): the queue gate derives a CANONICAL rooms.db from the real task-DB
    home and passes it here, so a caller-supplied `BRIDGE_A2A_ROOMS_DB` override
    cannot point the enforcement lookup at a self-owned fake. When omitted, the
    env-derived `rooms_db_path()` is used (the back-compat default).
    """
    path = db_path if db_path is not None else rooms_db_path()
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


# Lane 4 (#1695): the token-bootstrap key SEED. This MUST stay byte-identical to
# `bridge_a2a_common.room_pair_key_seed` (RFC 5869 HKDF-Extract, HMAC-SHA256,
# salt="a2a-room-pair-seed-v1") so the leader (which stores the seed) and the
# joiner (which re-derives it from the raw token via a2a) agree on the per-pair
# key. We compute it locally rather than import a2a so rooms_common keeps no hard
# dependency on the A2A module (it is imported by single-node-only surfaces too).
_INVITE_KEY_SEED_SALT = b"a2a-room-pair-seed-v1"


def _invite_key_seed_for(token: str) -> str:
    """HKDF-Extract(salt, raw_token) → hex. Secret-equivalent; stored only in
    controller-owned rooms.db while the invite is valid."""
    import hmac as _hmac

    return _hmac.new(_INVITE_KEY_SEED_SALT, token.encode("utf-8"),
                     hashlib.sha256).hexdigest()


# The signed-invite locator (`reach=`) parameters carried in a v2 link, Lane 4
# (#1695). They are bound into a token-signed canonical (the `s=` param). SK-1
# honesty: the signing key is token-derived (the `t=` bearer in the SAME link),
# so the signature proves integrity only vs a BLIND on-path tamperer — it is NOT
# relay-resistance (a relayer holds the token). The real enforced freshness
# guarantees are the LINK `iat`/`ttl` expiry + the single-use `nonce`, both
# applied joiner-side (see bridge-rooms.py). The signing/verification (which
# needs the raw token) lives in the CLI where `bridge_a2a_common` is imported;
# these helpers stay pure URL builders/parsers so single-node-only surfaces keep
# no a2a dependency.
_SIGNED_INVITE_KEYS = ("v", "lb", "reach", "iat", "ttl", "nonce", "s")


def make_invite_link(room_id: str, leader_node: str, token: str,
                     reach: str = "", *, signed: Optional[dict[str, str]] = None
                     ) -> str:
    """Build the `agbroom://join?...` link the leader hands out ONCE.

    The raw token is in the link, never stored. `reach` is an optional
    transport hint. `signed` (Lane 4) carries the v2 signed-invite params
    (`v`, `lb`, `iat`, `ttl`, `nonce`, `s`); when present the link is a signed
    v2 invite whose `reach`/identity locator a joiner verifies against the raw
    token before trusting it.
    """
    from urllib.parse import urlencode

    params = {"room": room_id, "leader": leader_node, "t": token}
    if reach:
        params["reach"] = reach
    if signed:
        for k in _SIGNED_INVITE_KEYS:
            if k in signed and signed[k] != "":
                params[k] = signed[k]
    return f"{INVITE_LINK_SCHEME}://join?" + urlencode(params)


def parse_invite_link(link: str) -> dict[str, str]:
    """Parse an `agbroom://join?...` link into {room, leader, t, reach, ...}.

    Accepts either a full link or a bare room_id (the CLI lets `join` take
    `<link|room_id>`). A bare room_id yields {"room": <id>} with no token. A v2
    signed invite additionally surfaces {v, lb, iat, ttl, nonce, s} for the
    CLI's token-bound canonical verification.
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
    for key in ("room", "leader", "t", "reach") + _SIGNED_INVITE_KEYS:
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
                once: bool = False, ttl: int = 0) -> str:
    """Create a room led by `leader_agent@leader_node`; seed leader member row.

    `epoch` starts at 0. The leader row is role='leader'. Only the token HASH
    is stored. `ttl` (seconds, P4.1) is the invite-token lifetime; 0 == no
    expiry (the P1 default). Returns the minted room_id. The caller is
    responsible for printing the one-time invite link (it holds the raw token).
    """
    room_id = mint_room_id()
    ts = now_ts()
    # Lane 4 (#1695): store the token-bootstrap key seed (HKDF-Extract of the raw
    # token) alongside the verifier hash. The seed is secret-equivalent material
    # the leader uses to derive a per-pair node-link key for a token-bootstrapped
    # join; it is domain-separated from invite_token_sha256.
    key_seed = _invite_key_seed_for(token)
    conn.execute(
        "INSERT INTO rooms (room_id, name, leader_agent, leader_node, epoch, "
        "invite_token_sha256, invite_token_ts, invite_token_ttl, "
        "invite_key_seed, invite_once, status, created_ts, updated_ts) "
        "VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)",
        (room_id, name, leader_agent, leader_node, hash_token(token), ts,
         max(0, int(ttl)), key_seed, 1 if once else 0, ROOM_ACTIVE, ts, ts),
    )
    # #2079: the leader is local to THIS (creating) node — classify it from
    # this node's configured admin id (the authoritative local source).
    leader_admin = admin_col_from_bool(classify_local_admin(leader_agent))
    conn.execute(
        "INSERT INTO room_members (room_id, agent, node, role, joined_ts, admin) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (room_id, leader_agent, leader_node, ROLE_LEADER, ts, leader_admin),
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
                     once: bool = False, ttl: int = 0) -> None:
    """Store a fresh token hash, INVALIDATING any prior token for the room.

    `ttl` (seconds, P4.1 §14 R3) is the lifetime of THIS token; 0 == no expiry
    (the P1 default). Setting/rotating a token resets `invite_token_ts` to now,
    so the TTL clock restarts on every rotate — and because the prior hash is
    overwritten, a rotate also REVOKES the old token (verify hash-compares the
    new one). `ttl` is stored alongside so verify_invite_token can enforce
    `invite_token_ts + ttl >= now`.
    """
    ts = now_ts()
    # Lane 4 (#1695): rotate the key seed in lockstep with the verifier hash, so
    # the OLD token's seed is overwritten (revoking its bootstrap derivation) and
    # the new token's seed is what the leader derives pair keys from.
    key_seed = _invite_key_seed_for(token)
    conn.execute(
        "UPDATE rooms SET invite_token_sha256=?, invite_token_ts=?, "
        "invite_token_ttl=?, invite_key_seed=?, invite_once=?, updated_ts=? "
        "WHERE room_id=?",
        (hash_token(token), ts, max(0, int(ttl)), key_seed, 1 if once else 0,
         ts, room_id),
    )
    # A rotated token invalidates prior rate-counters too (fresh budget).
    conn.execute(
        "DELETE FROM room_join_rate WHERE token_sha256 NOT IN "
        "(SELECT invite_token_sha256 FROM rooms WHERE invite_token_sha256 IS NOT NULL)"
    )
    conn.commit()


# Stable outcome codes for the token check (audit-safe — never carry the token).
TOKEN_OK = "ok"
TOKEN_MISMATCH = "mismatch"       # hash does not match (wrong/forged token)
TOKEN_REVOKED = "revoked"         # no token set (rotated/burned away)
TOKEN_EXPIRED = "expired"         # hash matches but TTL elapsed


def verify_invite_token_outcome(room: sqlite3.Row, token: str,
                                now: Optional[int] = None) -> str:
    """Verify the invite token against the room, enforcing TTL + revocation.

    Returns one of the TOKEN_* codes (NEVER the token itself, so the caller can
    audit the outcome safely — contract 5). The order is:
      1. revocation — a NULL/empty stored hash means the token was rotated or
         burned away → TOKEN_REVOKED (nothing to match).
      2. hash compare — constant-time `sha256(token)` vs the stored hash. A
         mismatch is TOKEN_MISMATCH (wrong/forged token). We compare BEFORE the
         TTL check so an attacker presenting a garbage token cannot learn the
         room's TTL state via a timing/branch difference.
      3. TTL (§14 R3) — when `invite_token_ttl` > 0, the token is valid only
         while `invite_token_ts + ttl >= now`; past that it is TOKEN_EXPIRED.
         A ttl of 0 means no expiry (P1 back-compat).
    """
    import hmac as _hmac

    stored = room["invite_token_sha256"]
    if not stored:
        return TOKEN_REVOKED
    if not _hmac.compare_digest(str(stored), hash_token(token)):
        return TOKEN_MISMATCH
    # Hash matched — now enforce TTL. Use a defensive getattr-style read so a
    # row from an unmigrated/partial source (no ttl column) is treated as "no
    # expiry" rather than raising.
    try:
        ttl = int(room["invite_token_ttl"])
    except (KeyError, IndexError, TypeError, ValueError):
        ttl = 0
    if ttl > 0:
        try:
            issued = int(room["invite_token_ts"])
        except (KeyError, IndexError, TypeError, ValueError):
            issued = 0
        if now is None:
            now = now_ts()
        if issued + ttl < int(now):
            return TOKEN_EXPIRED
    return TOKEN_OK


def verify_invite_token(room: sqlite3.Row, token: str,
                        now: Optional[int] = None) -> bool:
    """Boolean form of `verify_invite_token_outcome` (True iff TOKEN_OK).

    Now enforces TTL + revocation in addition to the hash compare, so every
    existing caller (single-node `cmd_join`, the smokes) transparently gains the
    P4.1 expiry/revocation gate without a signature change.
    """
    return verify_invite_token_outcome(room, token, now=now) == TOKEN_OK


def burn_invite_token(conn: sqlite3.Connection, room_id: str) -> None:
    """Clear the token after a `--once` single-use join is approved."""
    # Lane 4 (#1695): drop the key seed in lockstep — a burned invite can no
    # longer bootstrap a new pair key (the seed is secret-equivalent material we
    # keep ONLY while the invite is valid).
    conn.execute(
        "UPDATE rooms SET invite_token_sha256=NULL, invite_key_seed=NULL, "
        "invite_once=0, updated_ts=? WHERE room_id=?",
        (now_ts(), room_id),
    )
    conn.commit()


def record_invite_nonce(conn: sqlite3.Connection, room_id: str,
                        nonce: str) -> bool:
    """JOINER-side single-use guard for a v2 signed invite link (Lane 4 SK-1).

    Records `(room_id, nonce)` once. Returns True the FIRST time it is seen and
    False on any replay (the row already exists). The caller rejects a False as
    a replayed link. Empty `nonce` is treated as non-recordable → returns True
    (a legacy/unsigned link carries no nonce and must not be blocked).

    The store is local to the joiner node; it is orthogonal to (and does not
    replace) the leader's server-side token TTL/revocation. Carries NO token.
    """
    if not nonce:
        return True
    cur = conn.execute(
        "INSERT OR IGNORE INTO invite_nonce_seen (room_id, nonce, seen_ts) "
        "VALUES (?, ?, ?)",
        (room_id, nonce, now_ts()),
    )
    conn.commit()
    # rowcount == 1 → freshly inserted (first sight); 0 → PK collision (replay).
    return cur.rowcount == 1


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

def bump_epoch(conn: sqlite3.Connection, room_id: str,
               *, commit: bool = True) -> int:
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

    `commit=False` lets a caller fold this epoch bump into a LARGER transaction
    it commits itself (e.g. the #2109 admin backfill, which must make the bit
    UPDATE + the bump + the outbox enqueue durable atomically — see
    `reclassify_and_rebroadcast_local_admin`). The default `commit=True`
    preserves every existing membership-change caller.
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
    # commit, then commit both writes atomically (unless the caller defers).
    _recompute_roster_cache(conn, room_id, commit=False)
    if commit:
        conn.commit()
    return int(row["epoch"])


def is_member(conn: sqlite3.Connection, room_id: str, agent: str,
              node: str = "") -> bool:
    row = conn.execute(
        "SELECT 1 FROM room_members WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    return row is not None


def member_nodes_for_agent(conn: sqlite3.Connection, room_id: str,
                           agent: str) -> list[str]:
    """The node(s) on which `agent` is an AUTHORITATIVE member of `room_id`.

    Lane 5 (#1695-P2 gotcha E) leader-relay support: read from the leader's
    authoritative `room_members` (NEVER a body claim) so the relay can resolve a
    target member agent to its node. Deterministically sorted. An agent absent
    from the room returns []. Normally one node per (room, agent), but the schema
    permits an agent name on multiple nodes — all are returned so the caller can
    fail closed on ambiguity.
    """
    rows = conn.execute(
        "SELECT DISTINCT node FROM room_members WHERE room_id=? AND agent=? "
        "ORDER BY node",
        (room_id, agent),
    ).fetchall()
    return [str(r["node"] or "") for r in rows]


def add_member(conn: sqlite3.Connection, room_id: str, agent: str,
               node: str = "", role: str = ROLE_MEMBER,
               admin: int = ADMIN_COL_UNKNOWN) -> None:
    """Admit a member with a tri-state #2079 admin classification.

    `admin` is the stored INTEGER tri-state (ADMIN_COL_ADMIN / _NON_ADMIN /
    _UNKNOWN). Default UNKNOWN: a caller that omits it (e.g. a pre-#2079 path)
    records an unattested member that fail-closes admin-involved cross-node
    delivery until reclassified. Local admits set it from this node's configured
    admin id; cross-node admits set it from the joiner node's attestation.
    """
    conn.execute(
        "INSERT OR REPLACE INTO room_members (room_id, agent, node, role, "
        "joined_ts, admin) VALUES (?, ?, ?, ?, ?, ?)",
        (room_id, agent, node, role, now_ts(), int(admin)),
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
    """Persist a LOCAL (single-node P1) pending join request.

    verified stays 0 / via_node='' (this is not a node-link-attested cross-node
    request). INSERT OR REPLACE re-affirms a re-requested pending row.
    """
    conn.execute(
        "INSERT OR REPLACE INTO room_join_requests (room_id, agent, node, "
        "requested_ts, status, verified, via_node, ttl_expiry) "
        "VALUES (?, ?, ?, ?, ?, 0, '', 0)",
        (room_id, agent, node, now_ts(), JOIN_PENDING),
    )
    conn.commit()


def record_verified_cross_node_join_request(
    conn: sqlite3.Connection, room_id: str, agent: str, node: str,
    *, via_node: str, ttl_expiry: int = 0,
    joiner_admin: int = ADMIN_COL_UNKNOWN,
) -> None:
    """Persist a VERIFIED cross-node (P4.1) pending join request.

    Called by the leader-node receiver ONLY after the node-link HMAC +
    token-hash + TTL/revocation verification has passed (contract 4). The row
    carries verified METADATA — the joiner `agent@node`, the verified flag, the
    HMAC-authenticated node-link peer (`via_node`), and an optional `ttl_expiry`
    — but NEVER the reusable token hash (contract 5: the hash is bearer-
    equivalent and is never persisted in any row). NO membership is added and NO
    leader task is created here: admission is a separate P4.2 `approve` that
    REQUIRES a verified row (contract 6).

    `node` is the joiner's node as bound by the receiver to the authenticated
    sender bridge (NEVER a wire-asserted value). INSERT OR REPLACE keyed on
    (room_id, agent, node) makes a duplicate request idempotent (refresh ts).

    NOTE: prefer `record_verified_cross_node_join_request_atomic` on the receiver
    path — it commits the dedupe reservation + this pending row in ONE
    transaction. This bare helper is retained for the local/test path that does
    not need the dedupe ledger.
    """
    conn.execute(
        "INSERT OR REPLACE INTO room_join_requests (room_id, agent, node, "
        "requested_ts, status, verified, via_node, ttl_expiry, joiner_admin) "
        "VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)",
        (room_id, agent, node, now_ts(), JOIN_PENDING, via_node,
         max(0, int(ttl_expiry)), int(joiner_admin)),
    )
    conn.commit()


# Stable outcomes for the atomic cross-node dedupe+persist (audit-safe codes).
JOIN_DEDUPE_RESERVED = "reserved"   # new id → dedupe row + pending row committed
JOIN_DEDUPE_DUPLICATE = "duplicate"  # same id + same body → already-accepted
JOIN_DEDUPE_CONFLICT = "conflict"    # same id + different body → id reuse


def room_join_dedupe_lookup(conn: sqlite3.Connection, peer: str,
                            message_id: str, body_sha256: str) -> str:
    """READ-ONLY dedupe check against rooms.db. Returns one of:
    'new' (no row), JOIN_DEDUPE_DUPLICATE (same id+body), JOIN_DEDUPE_CONFLICT
    (same id, different body). A row exists ONLY for a PREVIOUSLY-ACCEPTED
    cross-node join (the reservation is atomic with the pending row), so a hit
    here means the request was already accepted. Never writes.

    On an UPGRADED P1 rooms.db the `room_join_dedupe` table may not exist yet
    when this read-only path runs (codex P4.1 r3 #2): `open_rooms_readonly`
    deliberately does NOT run schema creation, and the migrating RW `open_rooms`
    happens later on the accept path. A missing table therefore means "no
    prior accepted request" → 'new'; the RW open on the accept path creates the
    table before the reservation. Any OTHER operational error propagates.
    """
    try:
        row = conn.execute(
            "SELECT body_sha256 FROM room_join_dedupe "
            "WHERE peer=? AND message_id=?",
            (peer, message_id),
        ).fetchone()
    except sqlite3.OperationalError as exc:
        if "no such table" in str(exc).lower():
            return "new"
        raise
    if row is None:
        return "new"
    return (JOIN_DEDUPE_DUPLICATE if row["body_sha256"] == body_sha256
            else JOIN_DEDUPE_CONFLICT)


def record_verified_cross_node_join_request_atomic(
    conn: sqlite3.Connection, *, message_id: str, body_sha256: str, peer: str,
    room_id: str, agent: str, node: str, via_node: str, ttl_expiry: int = 0,
    joiner_admin: int = ADMIN_COL_UNKNOWN,
) -> str:
    """ATOMICALLY reserve the dedupe row AND persist the verified pending row.

    The whole operation commits in ONE transaction (codex P4.1 r2): "a dedupe row
    exists" is therefore equivalent to "a pending row exists", closing the window
    where a surviving reservation could let a replay return a bogus idempotent
    200 with no pending row. Returns:
      - JOIN_DEDUPE_DUPLICATE : the message_id was already accepted with the SAME
        body → idempotent, NOTHING re-written.
      - JOIN_DEDUPE_CONFLICT  : the message_id was already used with a DIFFERENT
        body → id reuse, NOTHING written.
      - JOIN_DEDUPE_RESERVED  : a NEW id → the dedupe row + the pending row are
        BOTH committed together.

    The dedupe + pending writes are issued WITHOUT an intermediate commit, then a
    single `conn.commit()` makes them durable atomically; a failure before the
    commit (e.g. the pending INSERT raises) rolls BOTH back, so no orphan dedupe
    row survives. Carries NO token / token-hash (contract 5).
    """
    # Re-check inside this call (the caller's read-only lookup may have raced).
    # Scoped to the authenticated peer (codex P4.1 Phase-4 — composite PK).
    existing = conn.execute(
        "SELECT body_sha256 FROM room_join_dedupe "
        "WHERE peer=? AND message_id=?",
        (peer, message_id),
    ).fetchone()
    if existing is not None:
        # A concurrent accept reserved first → resolve to the same outcome the
        # lookup would have produced. No write (the pending row is already there
        # from the first accept).
        return (JOIN_DEDUPE_DUPLICATE if existing["body_sha256"] == body_sha256
                else JOIN_DEDUPE_CONFLICT)
    ts = now_ts()
    try:
        conn.execute(
            "INSERT INTO room_join_dedupe (message_id, peer, body_sha256, "
            "created_ts) VALUES (?, ?, ?, ?)",
            (message_id, peer, body_sha256, ts),
        )
        conn.execute(
            "INSERT OR REPLACE INTO room_join_requests (room_id, agent, node, "
            "requested_ts, status, verified, via_node, ttl_expiry, joiner_admin) "
            "VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)",
            (room_id, agent, node, ts, JOIN_PENDING, via_node,
             max(0, int(ttl_expiry)), int(joiner_admin)),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        # CONCURRENCY (codex P4.1 r3 #1): two handlers both passed the pre-check
        # SELECT before either committed; this one lost the message_id PK race.
        # The dedupe row's PRIMARY KEY is the serialization point — roll back our
        # partial write and re-query the winner's row, returning the SAME
        # idempotent/conflict outcome the pre-check would have. The loser thus
        # gets a clean duplicate/conflict, never a 500. (No orphan row: our
        # INSERT was rolled back; the pending row, if any, belongs to the winner.)
        conn.rollback()
        winner = conn.execute(
            "SELECT body_sha256 FROM room_join_dedupe "
            "WHERE peer=? AND message_id=?",
            (peer, message_id),
        ).fetchone()
        if winner is not None:
            return (JOIN_DEDUPE_DUPLICATE
                    if winner["body_sha256"] == body_sha256
                    else JOIN_DEDUPE_CONFLICT)
        # The PK violation came from somewhere other than a concurrent winner
        # (should not happen) — surface it rather than silently swallow.
        raise
    except Exception:
        # Roll BOTH writes back so a failed pending insert never leaves an
        # orphan dedupe reservation (the r2 atomicity contract).
        conn.rollback()
        raise
    return JOIN_DEDUPE_RESERVED


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
                    room_id: str) -> list[dict[str, Any]]:
    """Members of a room, deterministically sorted by (agent, node).

    The sort is the CANONICAL ordering — P4 signs over exactly this byte
    sequence so any verifier recomputes the same MAC. Never reorder.

    #2079: each member also carries an OPTIONAL "bridge_admin" bool — present
    only when this node KNOWS the member's admin classification (true/false);
    omitted (== unknown) for legacy/unattested members. Adding the key changes
    the SIGNED roster bytes only for members with a known classification, so a
    cross-node mesh where every node has materialized admin metadata produces a
    larger but still deterministic signed roster; a legacy node's roster is
    byte-identical to pre-#2079.
    """
    rows = conn.execute(
        "SELECT agent, node, role, admin FROM room_members WHERE room_id=? "
        "ORDER BY agent, node",
        (room_id,),
    ).fetchall()
    out: list[dict[str, Any]] = []
    for r in rows:
        member: dict[str, Any] = {
            "agent": r["agent"], "node": r["node"] or "", "role": r["role"]}
        # #2079: materialize the admin bit ONLY when KNOWN (true/false). An
        # unknown classification omits the key, so a legacy/unattested member
        # serializes to "unknown" at every verifier (key-absent == unknown).
        tri = admin_tri_from_col(r["admin"])
        if tri == ADMIN_TRI_ADMIN:
            member["bridge_admin"] = True
        elif tri == ADMIN_TRI_NON_ADMIN:
            member["bridge_admin"] = False
        out.append(member)
    return out


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
    # #2079: the LOCAL admit path admits an agent on the leader's OWN node, so
    # classify it from THIS node's configured admin id (the authoritative
    # source for a local endpoint). None (no configured admin) -> UNKNOWN.
    admin_col = admin_col_from_bool(classify_local_admin(agent))
    add_member(conn, room_id, agent, node, role=ROLE_MEMBER, admin=admin_col)
    set_join_request_status(conn, room_id, agent, node, JOIN_APPROVED)
    # bump_epoch re-persists room_roster_cache atomically (centralized in F2),
    # so no explicit _recompute_roster_cache call is needed here.
    return bump_epoch(conn, room_id)


def has_verified_pending_request(conn: sqlite3.Connection, room_id: str,
                                 agent: str, node: str) -> bool:
    """True iff a VERIFIED, still-pending cross-node join row exists (P4.2).

    The two-factor gate for a CROSS-NODE approve (contract 1): admitting a
    REMOTE agent (one whose node != this leader node) REQUIRES a
    `room_join_requests` row with `verified=1` AND `status='pending'` —
    i.e. a row the receiver (P4.1) created only AFTER the node-link HMAC +
    token-hash + TTL/revocation verification passed. A row that is denied/
    approved/absent does NOT satisfy the gate. The LOCAL leader-initiated add
    path (a leader admitting an agent on its OWN node) is a SEPARATE path that
    does NOT consult this gate — see `approve_cross_node` vs `approve_join`.
    """
    row = conn.execute(
        "SELECT verified, status FROM room_join_requests "
        "WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    if row is None:
        return False
    try:
        verified = int(row["verified"])
    except (KeyError, IndexError, TypeError, ValueError):
        verified = 0
    return verified == 1 and str(row["status"]) == JOIN_PENDING


def approve_cross_node(conn: sqlite3.Connection, room_id: str, agent: str,
                       node: str) -> int:
    """Admit a REMOTE (cross-node) member — REQUIRES a verified pending row.

    The P4.2 cross-node admission path (contract 1). Unlike `approve_join` (the
    P1 local path that admits a local agent with no pending-row requirement),
    this REFUSES to add a remote member unless a P4.1 verified pending row
    exists (`has_verified_pending_request`). This is the anti-forgery gate: a
    leader cannot be tricked into broadcasting a roster that admits a remote
    agent who never completed the node-link-authenticated, token-verified join.

    Raises RoomsError(code='no_verified_request') when the gate is unmet (NO
    membership add, NO epoch bump). On success: add member, mark the request
    approved, bump the epoch (which re-persists the leader's authoritative
    roster cache atomically). Returns the new epoch.
    """
    require_room(conn, room_id)
    if not has_verified_pending_request(conn, room_id, agent, node):
        raise RoomsError(
            f"cross-node approve of {agent}@{node} on {room_id} requires a "
            "verified pending join request (none found) — a remote agent must "
            "complete the node-link-authenticated, token-verified join first",
            code="no_verified_request",
        )
    # #2079: a REMOTE member's admin classification is the joiner NODE's
    # attestation, carried on the verified pending row (joiner_admin). The
    # leader cannot independently verify a remote node's admin config, so it
    # trusts the node-attested bit (node-attested, not independently
    # verifiable — see the join-request schema comment). A pre-#2079 pending
    # row (or one with no attestation) reads -1 (unknown) and fail-closes
    # admin-involved cross-node delivery for this member until reclassified.
    prow = conn.execute(
        "SELECT joiner_admin FROM room_join_requests "
        "WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    # The stored joiner_admin is ALREADY the tri-state INTEGER (1/0/-1); carry
    # it onto the member row verbatim (unknown stays unknown).
    admin_col = ADMIN_COL_UNKNOWN
    if prow is not None:
        admin_col = admin_col_from_tri(admin_tri_from_col(prow["joiner_admin"]))
    add_member(conn, room_id, agent, node, role=ROLE_MEMBER, admin=admin_col)
    set_join_request_status(conn, room_id, agent, node, JOIN_APPROVED)
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
# Lane 5 (#1695-P2 gotcha F): DURABLE roster-broadcast outbox (leader-side)
# --------------------------------------------------------------------------
#
# A membership change on the leader (approve / kick / leave / deny) must reach
# every REMOTE member node so its leader-MAC'd roster cache converges. The prior
# approve path did a best-effort synchronous broadcast only — a member node that
# was momentarily offline simply missed the update (the kick/leave/deny paths did
# not broadcast at all). This durable outbox closes both gaps: the membership
# change records a pending convergence target per remote member node, the CLI
# tries an immediate delivery, and the periodic `roster_epoch_reconcile`
# heartbeat re-broadcasts any row a member has not yet acked.
#
# SECURITY: the outbox stores ONLY (room_id, member_node, epoch) — never a token,
# secret, or roster body. The actual broadcast body is rebuilt from the leader's
# AUTHORITATIVE rooms.db at send time (`roster_for`), so a queued row can never
# carry a stale roster and never persists secret material. Membership/target are
# always read from rooms.db, never a body claim.

# Bounded retry budget (codex P2 r2): a pending outbox row that fails this many
# delivery attempts WITHOUT an ack is RETIRED so a permanently-gone member (e.g. a
# kicked node that never returns) cannot leave a zombie row the heartbeat retries
# forever. A later membership change re-arms the node (UPSERT resets status +
# attempts), so a node that comes back still converges on the next real change.
ROSTER_OUTBOX_MAX_ATTEMPTS = 12


def _target_member_nodes(conn: sqlite3.Connection, room_id: str,
                         leader_node: str) -> list[str]:
    """The DISTINCT remote member nodes that should receive a roster broadcast.

    Read from the authoritative rooms.db `room_members` (NEVER a body claim).
    Excludes the leader's own node (the leader already holds the authoritative
    rooms.db — no node-link hop) and the empty node (a local single-node member).
    Deterministically sorted for reproducible enqueue/broadcast order.
    """
    rows = conn.execute(
        "SELECT DISTINCT node FROM room_members WHERE room_id=?",
        (room_id,),
    ).fetchall()
    nodes: set[str] = set()
    for r in rows:
        n = str(r["node"] or "")
        if n and n != leader_node:
            nodes.add(n)
    return sorted(nodes)


def enqueue_roster_broadcast(conn: sqlite3.Connection, room_id: str,
                             epoch: int, leader_node: str,
                             extra_nodes: Optional[list[str]] = None,
                             *, commit: bool = True
                             ) -> list[str]:
    """Record a durable convergence target for every remote member node (F).

    Called by the leader-side membership-change broadcast after the epoch bump.
    For each remote member node, UPSERTs a `room_roster_outbox` row at the new
    epoch (raising the target epoch monotonically on any existing row — a queued
    row is never lowered, and a re-pending RESETS attempts so an already-given-up
    row re-converges on the next change). Returns the list of member nodes that
    now have a pending convergence target. Membership is read from rooms.db.

    `extra_nodes` (codex P2 — kick/leave convergence): a just-REMOVED node is no
    longer in room_members, so the new roster (in which it is absent) would never
    be delivered to it and its local cache would stay stale indefinitely. A
    kick/leave caller passes the removed node here so it ALSO gets a one-shot
    convergence target — it receives the higher-epoch roster that drops it and
    locally converges (drops the room). The removed node is enqueued only if it is
    a distinct REMOTE node (not the leader's own node). A subsequent successful
    ack clears the row; if it never acks it ages out under the heartbeat's bounded
    retries (no permanent zombie — it is not re-enqueued on later changes since it
    is no longer a member).

    `commit=False` lets a caller fold the outbox enqueue into a LARGER atomic
    transaction it commits itself (the #2109 admin backfill folds the bit
    UPDATE + epoch bump + this enqueue into ONE commit so a failed enqueue rolls
    back the bit change too — see `reclassify_and_rebroadcast_local_admin`). The
    default `commit=True` preserves every existing membership-change caller.
    """
    targets = _target_member_nodes(conn, room_id, leader_node)
    seen = set(targets)
    for node in (extra_nodes or []):
        node = str(node or "")
        if node and node != leader_node and node not in seen:
            targets.append(node)
            seen.add(node)
    ts = now_ts()
    for node in targets:
        # UPSERT: raise the epoch monotonically (MAX of existing/new), reset the
        # row to pending + attempts=0 so a change re-arms a previously-done or
        # backed-off target. epoch is clamped to never go below the existing.
        conn.execute(
            "INSERT INTO room_roster_outbox "
            "(room_id, member_node, epoch, status, attempts, last_error, "
            " created_ts, updated_ts) "
            "VALUES (?, ?, ?, 'pending', 0, '', ?, ?) "
            "ON CONFLICT(room_id, member_node) DO UPDATE SET "
            "  epoch=MAX(room_roster_outbox.epoch, excluded.epoch), "
            "  status='pending', attempts=0, last_error='', updated_ts=excluded.updated_ts",
            (room_id, node, int(epoch), ts, ts),
        )
    if commit:
        conn.commit()
    return targets


def backfill_local_admin(conn: sqlite3.Connection, local_node: str,
                         *, commit: bool = True) -> set[str]:
    """Reclassify THIS node's `admin` bits from the local configured admin id.

    The #2109 (durable) half of the #2079 fix. The `room_members.admin` /
    `room_join_requests.joiner_admin` columns are added by `_migrate_schema` at
    DEFAULT -1 (unknown), which correctly fail-closes admin-involved cross-node
    delivery — but on a STABLE room (no join/leave to bump the epoch) those rows
    stay -1 forever, so an existing admin member's cross-node room delivery is
    permanently fail-closed. This backfill recomputes the admin bit for the
    rows we have LOCAL AUTHORITY over and returns the rooms whose
    `room_members.admin` actually changed (so the caller can leader-rebroadcast).

    Authority boundary (SECURITY — do NOT widen):
      - Only rows where `node == local_node` are touched. `local_node` is THIS
        node's `bridge_id` (`''` for a single-node install, where local member
        rows carry `node=''`). A row on ANY OTHER node is left exactly as it is
        (its own node attests its admin via a verified roster broadcast; we
        NEVER infer a remote endpoint's admin from local config or agent name).
      - The local admin id comes ONLY from `resolve_admin_agent_id()`
        (`$BRIDGE_ADMIN_AGENT_ID` env-first, then the on-disk roster) — the same
        source `classify_local_admin` uses. We never trust an agent NAME.
      - If the local admin id is empty/unresolved, we leave EVERY row at -1
        (unknown) and change nothing — unknown is safer than asserting "no
        admins" (writing 0 would be a false non-admin downgrade). We recompute
        only when we actually know the local admin id.
      - When known, we recompute ALL local rows (not just the -1 ones) so a
        STALE classification (e.g. the admin id was reconfigured) self-corrects:
        `admin=1` where `agent == admin_id`, `admin=0` for every other local
        member. This only ever REDUCES unknowns to a known bit for the local
        node; it never flips a genuine non-admin into an admin.

    `commit=False` leaves the writes uncommitted so the caller can fold them
    into a LARGER atomic transaction (the #2109 leader path commits the bit
    UPDATE together with the epoch bump + outbox enqueue). On `commit=True`
    (the default) the backfill is self-contained.

    Raises AdminIdResolveError (propagated from `resolve_admin_agent_id`) when an
    existing roster is unreadable/malformed — the caller fail-closes (does NOT
    rebroadcast) rather than backfill with a wrong/absent admin id.
    """
    admin_id = resolve_admin_agent_id()
    if not admin_id:
        # No locally-configured admin → cannot classify any local endpoint as
        # admin/non-admin. Leave every row UNKNOWN (-1); never write 0.
        return set()

    node = str(local_node or "")
    # Rooms whose room_members.admin actually changes (drives the rebroadcast).
    changed_member_rooms: set[str] = set()
    member_rows = conn.execute(
        "SELECT room_id, agent, admin FROM room_members WHERE node=?",
        (node,),
    ).fetchall()
    for r in member_rows:
        want = ADMIN_COL_ADMIN if str(r["agent"]) == admin_id else ADMIN_COL_NON_ADMIN
        if int(r["admin"]) != want:
            conn.execute(
                "UPDATE room_members SET admin=? WHERE room_id=? AND agent=? AND node=?",
                (want, r["room_id"], r["agent"], node),
            )
            changed_member_rooms.add(str(r["room_id"]))

    # room_join_requests.joiner_admin: same local-only backfill for this node's
    # PENDING rows. A remote pending row stays -1 (its own node attests on the
    # verified cross-node join). This does not drive a rebroadcast (a pending
    # request is not a roster member yet), so it is not collected.
    join_rows = conn.execute(
        "SELECT room_id, agent, joiner_admin FROM room_join_requests "
        "WHERE node=? AND status=?",
        (node, JOIN_PENDING),
    ).fetchall()
    for r in join_rows:
        want = ADMIN_COL_ADMIN if str(r["agent"]) == admin_id else ADMIN_COL_NON_ADMIN
        if int(r["joiner_admin"]) != want:
            conn.execute(
                "UPDATE room_join_requests SET joiner_admin=? "
                "WHERE room_id=? AND agent=? AND node=? AND status=?",
                (want, r["room_id"], r["agent"], node, JOIN_PENDING),
            )

    if commit:
        conn.commit()
    return changed_member_rooms


def _backfill_room_member_admin(conn: sqlite3.Connection, room_id: str,
                                node: str, admin_id: str) -> bool:
    """Recompute room_members.admin for ONE (room, local-node) — no commit.

    Returns True iff at least one row's bit actually changed. The per-room slice
    of `backfill_local_admin` so the #2109 leader path can apply the bit change,
    bump the epoch, and enqueue the broadcast for THIS room inside a single
    transaction it commits atomically (so a failed enqueue rolls the bit change
    back and the next tick re-detects + retries it).
    """
    changed = False
    rows = conn.execute(
        "SELECT agent, admin FROM room_members WHERE room_id=? AND node=?",
        (room_id, node),
    ).fetchall()
    for r in rows:
        want = ADMIN_COL_ADMIN if str(r["agent"]) == admin_id else ADMIN_COL_NON_ADMIN
        if int(r["admin"]) != want:
            conn.execute(
                "UPDATE room_members SET admin=? WHERE room_id=? AND agent=? AND node=?",
                (want, room_id, r["agent"], node),
            )
            changed = True
    return changed


def reclassify_and_rebroadcast_local_admin(
        cfg: dict, conn: sqlite3.Connection) -> dict[str, int]:
    """Backfill local admin bits, then leader-rebroadcast the changed rooms.

    The durable convergence entry point for #2109: recompute THIS node's local
    admin bits and, for each room whose `room_members` admin bits actually
    changed AND which THIS node leads, bump the epoch and enqueue a durable
    roster re-broadcast so remote members materialize the corrected admin bits
    (recovering admin-member cross-node delivery). Reuses ONLY the existing
    signed-v2-roster durable path (`bump_epoch` + `enqueue_roster_broadcast` →
    `heartbeat_rebroadcast_rosters`); it builds no new sender and preserves the
    pairwise-HMAC roster contract.

    ATOMICITY (codex r1): for a LEADER-led changed room, the bit UPDATE + the
    epoch bump + the outbox enqueue are folded into ONE transaction committed
    together. If the bump or enqueue raises, the bit change ROLLS BACK with it —
    so the room's bits stay at their old (e.g. -1) value and the NEXT tick
    re-detects the change and retries the whole sequence. Committing the bit
    change before the enqueue is durable would lose the rebroadcast forever (the
    next tick would see the bits already correct and never re-enqueue).

    Leader-only (SECURITY): a non-leader MUST NOT forge a roster broadcast, so a
    changed room is rebroadcast ONLY when `rooms.leader_node == local_node`. A
    non-leader still backfills its OWN local member bits (correct for its local
    reads) but does not bump/enqueue — its leader owns the authoritative roster
    and will rebroadcast the corrected bits from ITS side.

    Returns {"backfilled_rooms": n, "rebroadcast_rooms": m} for the caller's
    step result. Idempotent: a second call with no further config/membership
    change backfills nothing and rebroadcasts nothing.
    """
    local_node = str(cfg.get("bridge_id", "") or "").strip()
    admin_id = resolve_admin_agent_id()
    if not admin_id:
        # No locally-configured admin → cannot classify any local endpoint.
        # Leave every row UNKNOWN (-1); never write 0, never rebroadcast.
        return {"backfilled_rooms": 0, "rebroadcast_rooms": 0}

    node = str(local_node or "")
    # The set of rooms that have ANY local member row needing reclassification.
    # We slice the work per room so each leader rebroadcast is atomic with its
    # bit change. (Read-only probe; the writes happen per room below.)
    candidate_rooms = sorted({
        str(r["room_id"]) for r in conn.execute(
            "SELECT DISTINCT room_id FROM room_members WHERE node=?", (node,)
        ).fetchall()
    })

    backfilled = 0
    rebroadcast = 0
    # Roll any uncommitted state forward atomically per room: each iteration
    # ends in exactly one commit (the leader bump/enqueue path) or one rollback
    # (a raise), never a partial. Start clean.
    conn.commit()
    for room_id in candidate_rooms:
        room = get_room(conn, room_id)
        if room is None:
            continue
        is_leader = str(room["leader_node"] or "") == node and bool(node)
        try:
            changed = _backfill_room_member_admin(conn, room_id, node, admin_id)
            if not changed:
                # Nothing to write for this room; discard the (no-op) txn.
                conn.rollback()
                continue
            if is_leader:
                # Fold the bit change + epoch bump + outbox enqueue into ONE
                # commit so a failed enqueue rolls the bit change back too.
                epoch = bump_epoch(conn, room_id, commit=False)
                enqueue_roster_broadcast(conn, room_id, epoch, node, commit=False)
                conn.commit()
                rebroadcast += 1
            else:
                # Non-leader: persist only the local bit change (no forging).
                conn.commit()
            backfilled += 1
        except Exception:
            # Any failure (e.g. a transient enqueue/db error) rolls THIS room's
            # bit change back so the next tick re-detects + retries it. Re-raise
            # so the reconcile step records a paced error (it never crashes the
            # tick — the caller's last-resort guard contains it).
            conn.rollback()
            raise

    # room_join_requests.joiner_admin backfill for this node's PENDING rows. It
    # does not drive a rebroadcast (a pending request is not a roster member
    # yet), so it is a self-contained commit, separate from the per-room loop.
    _backfill_local_join_request_admin(conn, node, admin_id)

    return {"backfilled_rooms": backfilled, "rebroadcast_rooms": rebroadcast}


def _backfill_local_join_request_admin(conn: sqlite3.Connection, node: str,
                                       admin_id: str) -> None:
    """Recompute joiner_admin for THIS node's PENDING join requests (own commit).

    Local-only: a remote pending row (node != local) stays -1 (its own node
    attests on the verified cross-node join). Never drives a rebroadcast.
    """
    rows = conn.execute(
        "SELECT room_id, agent, joiner_admin FROM room_join_requests "
        "WHERE node=? AND status=?",
        (node, JOIN_PENDING),
    ).fetchall()
    for r in rows:
        want = ADMIN_COL_ADMIN if str(r["agent"]) == admin_id else ADMIN_COL_NON_ADMIN
        if int(r["joiner_admin"]) != want:
            conn.execute(
                "UPDATE room_join_requests SET joiner_admin=? "
                "WHERE room_id=? AND agent=? AND node=? AND status=?",
                (want, r["room_id"], r["agent"], node, JOIN_PENDING),
            )
    conn.commit()


def pending_roster_outbox(conn: sqlite3.Connection,
                          room_id: str = "") -> list[sqlite3.Row]:
    """The pending durable roster-broadcast targets (optionally one room).

    Read by the reconcile heartbeat + the CLI immediate-send. Ordered by
    updated_ts so the oldest unconverged target is retried first.
    """
    if room_id:
        return conn.execute(
            "SELECT room_id, member_node, epoch, attempts FROM room_roster_outbox "
            "WHERE status='pending' AND room_id=? ORDER BY updated_ts",
            (room_id,),
        ).fetchall()
    return conn.execute(
        "SELECT room_id, member_node, epoch, attempts FROM room_roster_outbox "
        "WHERE status='pending' ORDER BY updated_ts",
    ).fetchall()


def mark_roster_outbox_done(conn: sqlite3.Connection, room_id: str,
                            member_node: str, epoch: int) -> None:
    """Mark a member node converged at >= `epoch` (delivery acked).

    Only clears the row if the queued target epoch is NOT newer than the acked
    epoch — a row whose target was raised by a concurrent membership change after
    this send began stays pending (it must re-broadcast the newer roster). This
    keeps the outbox monotonic: an ack never masks a still-needed higher epoch.
    """
    conn.execute(
        "UPDATE room_roster_outbox SET status='done', last_error='', "
        "updated_ts=? WHERE room_id=? AND member_node=? AND epoch<=?",
        (now_ts(), room_id, member_node, int(epoch)),
    )
    conn.commit()


def record_roster_outbox_failure(conn: sqlite3.Connection, room_id: str,
                                 member_node: str, error: str) -> None:
    """Record a delivery failure on a pending row (stays pending for retry).

    Bumps the attempt counter + stores a SHORT non-secret error string. The row
    remains pending so the reconcile heartbeat re-attempts it (bounded by the
    reconcile.db backoff gate, not a per-row sleep). NEVER stores a secret.

    RETIREMENT (codex P2 r2): once a row has failed `ROSTER_OUTBOX_MAX_ATTEMPTS`
    times WITHOUT being acked, it is RETIRED (status='retired') so a member that
    is permanently gone (e.g. a kicked node that never comes back) cannot leave a
    zombie pending row that the heartbeat re-attempts forever. A retirement is
    NOT a delivery — a LATER membership change re-arms the node via
    `enqueue_roster_broadcast` (which resets status='pending' + attempts=0 on the
    UPSERT), so a node that returns still converges on the next real change. A
    retired row is also re-armed if the SAME node is re-added later.
    """
    conn.execute(
        "UPDATE room_roster_outbox SET attempts=attempts+1, last_error=?, "
        "updated_ts=? WHERE room_id=? AND member_node=? AND status='pending'",
        (str(error)[:200], now_ts(), room_id, member_node),
    )
    # Retire a row that has exhausted its bounded retry budget (no zombie).
    conn.execute(
        "UPDATE room_roster_outbox SET status='retired', updated_ts=? "
        "WHERE room_id=? AND member_node=? AND status='pending' AND attempts>=?",
        (now_ts(), room_id, member_node, ROSTER_OUTBOX_MAX_ATTEMPTS),
    )
    conn.commit()


# --------------------------------------------------------------------------
# Lane 5 (#1695-P2 gotcha F): shared roster-broadcast SENDER + reconcile heartbeat
# --------------------------------------------------------------------------
#
# The SINGLE signed-broadcast send path, importable by both the CLI (immediate
# best-effort delivery on a membership change) and the reconcile daemon heartbeat
# (anti-entropy re-broadcast of any un-acked durable outbox row). Keeping ONE
# sender means the canonical string / signature / protocol tag never diverge
# between the two callers. The pairwise leader↔member node-link HMAC is the auth;
# membership is rebuilt from the leader's authoritative rooms.db, never the body.


def _roster_test_post_hook_allowed() -> bool:
    """Paired-flag gate for the cross-node POST test seam (prod-inert).

    Mirrors bridge-rooms.py `_test_post_hook_allowed` so the reconcile heartbeat
    SENDER replays through the same smoke capture hook. BOTH insecure-test flags
    AND the hook path must be set — a single stale env var cannot fire it in
    production.
    """
    return (os.environ.get("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and bool(os.environ.get("BRIDGE_ROOMS_TEST_POST_HOOK")))  # noqa: iso-helper-boundary - env var, not a .env file


def send_roster_broadcast(cfg: dict, *, member_node: str, room_id: str,
                          room_epoch: int, members: list,
                          leader_node: str, timeout: float = 30.0,
                          ) -> tuple[int, bytes]:
    """Sign + POST ONE leader-signed roster broadcast to one member node.

    The shared SENDER (CLI immediate + reconcile heartbeat). Signs the canonical
    roster with the leader-node↔member-node PAIRWISE node-link HMAC (the existing
    per-peer secret — NEVER a token, never the original sender's signature). The
    PATH is in the canonical string so a roster signature cannot be replayed
    against the enqueue/join endpoints. Returns (http_status, response_body).
    Honors the BRIDGE_ROOMS_TEST_POST_HOOK paired test seam (prod-inert) so the
    smoke can capture + replay the signed request through the real receiver.

    `members` is the canonical sorted roster (rebuilt from rooms.db by the
    caller); `leader_node` is THIS leader's node id. Raises RoomsError on a
    config / peer / secret fault (the caller records it as a delivery failure).
    """
    import bridge_a2a_common as a2a  # local import: a2a is the lower layer

    local_bridge_id = str(cfg.get("bridge_id", "") or "").strip()
    if not local_bridge_id:
        raise RoomsError(
            "config has no 'bridge_id' — cannot identify this leader node for a "
            "roster broadcast", code="no_bridge_id")
    peer = a2a.find_peer(cfg, member_node)
    secret = a2a.peer_send_secret(peer)
    body = a2a.build_room_roster_broadcast(
        room_id=room_id, room_epoch=int(room_epoch), members=members,
        leader_node=leader_node)
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    message_id = a2a.new_message_id(local_bridge_id)
    path = peer.get("room_roster_path", a2a.ROOM_ROSTER_PATH)
    timestamp = str(a2a.now_ts())
    body_hash = a2a.body_sha256(body_bytes)
    canonical = a2a.canonical_string(
        "POST", path, local_bridge_id, message_id, timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    headers = {
        "Content-Type": "application/json",
        "X-AGB-Protocol": a2a.ROOM_ROSTER_PROTOCOL_VERSION,
        "X-AGB-Peer": local_bridge_id,
        "X-AGB-Message-Id": message_id,
        "X-AGB-Timestamp": timestamp,
        "X-AGB-Body-SHA256": body_hash,
        "X-AGB-Signature": signature,
    }

    if _roster_test_post_hook_allowed():
        import subprocess
        hook = os.environ["BRIDGE_ROOMS_TEST_POST_HOOK"]  # noqa: iso-helper-boundary - env var, not a .env file
        payload = {"path": path, "headers": headers,
                   "body": body_bytes.decode("utf-8")}
        try:
            proc = subprocess.run([hook, json.dumps(payload)],
                                  capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            raise RoomsError(f"test post hook failed: {exc}",
                             code="test_hook_error")
        if proc.returncode != 0:
            return 503, (proc.stderr or "test hook non-zero").encode("utf-8")
        return 200, (proc.stdout or "").encode("utf-8")

    address = a2a.resolve_peer_address_for_transport(
        a2a.transport_kind(cfg), peer)
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    if not address:
        raise RoomsError(
            f"member node {member_node!r} has no resolvable address",
            code="no_member_address")
    import urllib.error
    import urllib.request
    url = f"http://{address}:{port}{path}"
    req = urllib.request.Request(url, data=body_bytes, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:  # type: ignore[attr-defined]
        return exc.code, (exc.read() or b"")


def heartbeat_rebroadcast_rosters(cfg: dict, conn: sqlite3.Connection,
                                  *, max_sends: int = 64) -> dict[str, int]:
    """Re-broadcast every un-acked durable roster outbox row for THIS leader.

    The reconcile heartbeat side of gotcha F (anti-entropy). For each pending
    `room_roster_outbox` row whose room is led by THIS node (leader_node ==
    cfg.bridge_id — read from rooms.db, NEVER a body claim), rebuild the
    authoritative roster, send it, and clear/keep the durable row on ack/failure.
    Bounded by `max_sends` per tick (the reconcile.db backoff gate paces the
    whole step; this cap just bounds one tick's fan-out). Returns
    {"sent": n_delivered, "failed": n_failed, "pending": n_remaining} so the
    adapter can map it to step_converged / step_changed / step_error.

    A row whose room this node does NOT lead is a stale artifact (e.g. leadership
    moved) — it is marked done WITHOUT a send (never broadcast a roster we are not
    the authoritative leader of). Membership/epoch always from rooms.db.
    """
    local_node = str(cfg.get("bridge_id", "") or "").strip()
    sent = 0
    failed = 0
    rows = pending_roster_outbox(conn)
    for row in rows[:max_sends]:
        room_id = str(row["room_id"])
        member_node = str(row["member_node"])
        room = get_room(conn, room_id)
        # Only the AUTHORITATIVE leader re-broadcasts. A row for a room we do not
        # lead (or that no longer exists) is retired without a send (fail-closed:
        # never sign a roster for a room we are not the leader of).
        if room is None or str(room["leader_node"] or "") != local_node or not local_node:
            mark_roster_outbox_done(conn, room_id, member_node,
                                    int(row["epoch"]))
            continue
        # Rebuild the CURRENT authoritative roster (never the queued snapshot —
        # the outbox carries only the target epoch, not a body).
        roster = roster_for(conn, room_id)
        try:
            status, _resp = send_roster_broadcast(
                cfg, member_node=member_node, room_id=room_id,
                room_epoch=int(roster["epoch"]), members=roster["members"],
                leader_node=local_node)
        except RoomsError as exc:
            record_roster_outbox_failure(conn, room_id, member_node, str(exc))
            failed += 1
            continue
        except Exception as exc:  # noqa: BLE001 - transport/config failure
            record_roster_outbox_failure(conn, room_id, member_node,
                                         f"rebroadcast failed: {exc}")
            failed += 1
            continue
        if 200 <= status < 300:
            mark_roster_outbox_done(conn, room_id, member_node,
                                    int(roster["epoch"]))
            sent += 1
        else:
            record_roster_outbox_failure(conn, room_id, member_node,
                                         f"status={status}")
            failed += 1
    remaining = len(pending_roster_outbox(conn))
    return {"sent": sent, "failed": failed, "pending": remaining}


# --------------------------------------------------------------------------
# Member-side roster broadcast acceptance (A2A Rooms P4.2, design §6/§14 R2)
# --------------------------------------------------------------------------
#
# The leader (node A) signs the canonical roster with the leader↔member pairwise
# HMAC and POSTs it to each member node. The member node verifies the node-link
# HMAC (the receiver auth preamble does this) and then runs THIS acceptance
# logic, which encodes the anti-spoof / anti-rogue-leader / monotonic-epoch
# contracts. It writes the member-local `room_roster_cache` (the cache that lets
# comms survive a leader outage — design §6 "Roster cache").
#
# Stable, audit-safe acceptance outcome codes (no secret/token ever in them).
ROSTER_ACCEPTED = "accepted"            # cache written (first bind or higher epoch)
ROSTER_DUPLICATE = "duplicate"          # byte-identical idempotent re-broadcast
ROSTER_STALE_EPOCH = "stale_epoch"      # lower-or-same epoch (not a dup) → ignored
ROSTER_NOT_LEADER = "not_leader"        # peer != body.leader_node → rejected
ROSTER_NO_LOCAL_BINDING = "no_local_binding"  # first roster w/o local join state
ROSTER_LEADER_MISMATCH = "leader_mismatch"  # peer != the ESTABLISHED cached leader
ROSTER_DEDUPE_CONFLICT = "dedupe_conflict"  # same (peer,message_id), DIFFERENT body


def _local_join_binding_for(conn: sqlite3.Connection, room_id: str,
                            expected_leader_node: str) -> bool:
    """True iff this node holds LOCAL outbound join state for `room_id` that
    names `expected_leader_node` as the leader (the FIRST-ROSTER binding anchor).

    The anti-rogue-leader contract (codex #9622 contract 2, brief contract 3c): a
    member accepts its FIRST roster for a room ONLY if it already initiated a
    join to THIS room naming THIS leader node. The member's own `room join`
    (P4.2) records a LOCAL `room_join_requests` row (status pending/approved)
    whose `via_node` is the leader node it posted to — that row is the proof the
    member chose this room+leader, so an inbound roster claiming
    `leader_node=<some configured peer>` cannot MINT a brand-new room cache out
    of thin air (which would let any configured peer shape future room-scoped
    allow decisions).

    The binding requires:
      - a `room_join_requests` row for `room_id`,
      - status pending OR approved (a denied request is not a live intent),
      - `via_node` == `expected_leader_node` (the member posted its join to THIS
        leader node — an un-spoofable record of the member's own outbound choice,
        NOT a wire-asserted value).
    """
    rows = conn.execute(
        "SELECT status, via_node FROM room_join_requests WHERE room_id=?",
        (room_id,),
    ).fetchall()
    for r in rows:
        if str(r["status"]) not in (JOIN_PENDING, JOIN_APPROVED):
            continue
        if str(r["via_node"] or "") == expected_leader_node:
            return True
    return False


def record_local_join_intent(conn: sqlite3.Connection, room_id: str, agent: str,
                             node: str, *, leader_node: str) -> None:
    """Record the member's OWN outbound cross-node join intent locally (P4.2).

    Called on the MEMBER/sender node when it posts a cross-node `room join`, so
    the member has a LOCAL record that it chose `room_id` with leader
    `leader_node`. This row is the FIRST-ROSTER binding anchor
    (`_local_join_binding_for`): it lets the member later accept the leader's
    first roster broadcast for this room, while refusing a roster for a room it
    never tried to join (the rogue-leader-minting defense).

    `via_node` carries the leader node the member posted to (its own choice).
    `verified` stays 0 — this is the member's local view, NOT the leader-side
    receiver-verified row (that lives on the leader's node). INSERT OR REPLACE
    keyed on (room_id, agent, node) re-affirms a re-issued join.
    """
    conn.execute(
        "INSERT OR REPLACE INTO room_join_requests (room_id, agent, node, "
        "requested_ts, status, verified, via_node, ttl_expiry) "
        "VALUES (?, ?, ?, ?, ?, 0, ?, 0)",
        (room_id, agent, node, now_ts(), JOIN_PENDING, leader_node),
    )
    conn.commit()


def get_roster_cache(conn: sqlite3.Connection,
                     room_id: str) -> Optional[sqlite3.Row]:
    """The member-local cached roster row for a room (or None)."""
    return conn.execute(
        "SELECT room_id, epoch, members_json, from_node, mac, fetched_ts "
        "FROM room_roster_cache WHERE room_id=?",
        (room_id,),
    ).fetchone()


def list_roster_cache(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """All member-local cached roster rows (every room this node has joined).

    The read-only counterpart to `get_roster_cache` for `agb room list` on a
    NON-leader node: a member node holds a `room_roster_cache` row per room it
    was admitted into (written by P4.2), but no `rooms` row (it does not LEAD
    them). `list_rooms` only sees led rooms; this surfaces the joined-but-not-led
    ones so they are visible alongside. Ordered by room_id for a stable view.
    """
    return conn.execute(
        "SELECT room_id, epoch, members_json, from_node, mac, fetched_ts "
        "FROM room_roster_cache ORDER BY room_id"
    ).fetchall()


def cached_roster_members(row: sqlite3.Row) -> Optional[list[dict[str, str]]]:
    """Parse a roster-cache row's `members_json` for DISPLAY (keeps `role`).

    Unlike `_cached_members` (the talk gate, which deliberately drops `role`
    so the membership comparison only keys on agent+node), this preserves the
    cached `role` so `room show`/`room list` can render a member-side view that
    matches what a leader node shows. Returns None on a corrupt cache (caller
    surfaces that read-only, never fabricates).
    """
    try:
        parsed = json.loads(str(row["members_json"] or "[]"))
    except (ValueError, json.JSONDecodeError):
        return None
    if not isinstance(parsed, list):
        return None
    out: list[dict[str, Any]] = []
    for m in parsed:
        if not isinstance(m, dict):
            return None
        entry: dict[str, Any] = {
            "agent": str(m.get("agent", "")),
            "node": str(m.get("node", "")),
            "role": str(m.get("role", "member")) or "member",
        }
        # #2079: preserve the OPTIONAL known admin bit for `room show`/`room
        # list` rendering (key-absent == unknown).
        tri = admin_tri_from_member(m)
        if tri == ADMIN_TRI_ADMIN:
            entry["bridge_admin"] = True
        elif tri == ADMIN_TRI_NON_ADMIN:
            entry["bridge_admin"] = False
        out.append(entry)
    return out


def cached_leader(row: sqlite3.Row) -> str:
    """Best-effort `leader_agent@leader_node` from a roster-cache row.

    The cache stores the leader's NODE (`from_node`) but not the leader agent
    name as a top-level field — so the leader agent is recovered from the cached
    member whose `role == 'leader'` (the leader is always a roster member). If no
    leader member is present (corrupt/partial cache), only the node is shown —
    we never invent a leader agent the cache does not actually contain.
    """
    members = cached_roster_members(row)
    leader_node = str(row["from_node"] or "")
    if members:
        for m in members:
            if m["role"] == "leader":
                node = m["node"] or leader_node
                return f"{m['agent']}@{node}" if node else m["agent"]
    return f"?@{leader_node}" if leader_node else "?"


# --------------------------------------------------------------------------
# Member-side room-scoped TALK gate (A2A Rooms P4.3, design §11)
# --------------------------------------------------------------------------
#
# Once a member node holds a leader-MAC'd roster in `room_roster_cache` (written
# by P4.2's `accept_roster_broadcast` after a pairwise-HMAC verify FROM the
# leader), members on DIFFERENT nodes can exchange room-scoped messages WITHOUT
# the leader being online — because each member validates membership against its
# OWN local cache, never a live leader call. A room-scoped message carries
# `room_id` + `room_epoch`; the receiver fail-closed-checks both the sender and
# the local target against the locally-cached roster for that `room_id` at that
# exact `room_epoch`. The receiver MUST NOT trust any membership claim inside the
# inbound message — it consults ONLY this cache (the one P4.2 verified).

# Stable, audit-safe room-talk membership outcome codes (contract 8: no
# secret/token ever appears in them).
ROOM_TALK_OK = "members_ok"
ROOM_TALK_NO_CACHE = "no_roster_cache"        # no leader-MAC roster for this room
ROOM_TALK_BAD_CACHE = "roster_cache_corrupt"  # cached members_json unparseable
ROOM_TALK_EPOCH_MISMATCH = "epoch_mismatch"   # envelope epoch != cached epoch
ROOM_TALK_SENDER_NOT_MEMBER = "sender_not_member"
ROOM_TALK_TARGET_NOT_MEMBER = "target_not_member"


def _cached_members(row: sqlite3.Row) -> Optional[list[dict[str, Any]]]:
    """Parse the cached `members_json` into a list of {agent,node[,bridge_admin]}.

    Returns None if the stored JSON is not a list of objects (corrupt cache —
    the caller fails closed). Each entry is normalized to plain strings so the
    membership comparison never trips on a non-string node/agent.

    #2079: the OPTIONAL "bridge_admin" bool is preserved (present only when the
    cached roster carried a real bool == known; omitted == unknown) so the
    cross-node admin-authz predicate can classify the sender/target from the
    SAME verified leader-MAC cache the membership check reads. Membership
    comparison still keys ONLY on (agent, node) — the admin bit is metadata the
    authz predicate consumes, not part of the identity tuple.
    """
    try:
        parsed = json.loads(str(row["members_json"] or "[]"))
    except (ValueError, json.JSONDecodeError):
        return None
    if not isinstance(parsed, list):
        return None
    out: list[dict[str, Any]] = []
    for m in parsed:
        if not isinstance(m, dict):
            return None
        entry: dict[str, Any] = {
            "agent": str(m.get("agent", "")),
            "node": str(m.get("node", "")),
        }
        tri = admin_tri_from_member(m)
        if tri == ADMIN_TRI_ADMIN:
            entry["bridge_admin"] = True
        elif tri == ADMIN_TRI_NON_ADMIN:
            entry["bridge_admin"] = False
        out.append(entry)
    return out


def roster_cache_membership_check(
    conn: sqlite3.Connection, *, room_id: str, room_epoch: int,
    sender_agent: str, sender_node: str, target_agent: str, target_node: str,
) -> str:
    """Fail-closed room-talk membership gate against the LOCAL roster cache (P4.3).

    The member-side heart of P4.3 (brief contracts 2-4). The CALLER (the
    receiver) has ALREADY run the full node-link auth preamble, so `sender_node`
    is the node-link-AUTHENTICATED peer (un-spoofable) and `target_node` is THIS
    receiver's own node id. This function applies the remaining room-scoped
    delivery contracts and returns a ROOM_TALK_* code; the receiver delivers ONLY
    on ROOM_TALK_OK.

    Contracts enforced here (NEVER trusts any membership claim in the inbound
    message — it reads ONLY the locally-cached leader-MAC roster):
      - NO local roster cache for `room_id` → ROOM_TALK_NO_CACHE (contract 2: a
        room with no leader-verified roster cannot validate membership → deny,
        no delivery). A plain non-room send never reaches here, so it can NEITHER
        be gated by this nor seed a cache.
      - `room_epoch` must EQUAL the cached epoch (contract 3, fail-closed BOTH
        ways): an envelope epoch lower OR higher than the cache → ROOM_TALK_
        EPOCH_MISMATCH. We refuse to deliver against a roster we cannot confirm
        the sender belongs to AT THAT EPOCH (roster refresh on mismatch is P4.x,
        deliberately out of scope — just fail closed).
      - The authenticated SENDER `(sender_agent, sender_node)` MUST appear in the
        cached roster (contract 2/4). Identity is OS-actor + node anchored: the
        node is the un-spoofable authenticated peer, and a hostile wire
        `sender_agent` can at most name an agent the leader ACTUALLY admitted on
        that node — it cannot conjure a NON-member into the cache → ROOM_TALK_
        SENDER_NOT_MEMBER otherwise.
      - The local TARGET `(target_agent, target_node)` MUST also be a cached
        member (you only deliver a room message to a local agent who is itself in
        the room) → ROOM_TALK_TARGET_NOT_MEMBER otherwise.
    """
    row = get_roster_cache(conn, room_id)
    if row is None:
        return ROOM_TALK_NO_CACHE
    if int(room_epoch) != int(row["epoch"]):
        return ROOM_TALK_EPOCH_MISMATCH
    members = _cached_members(row)
    if members is None:
        return ROOM_TALK_BAD_CACHE
    sender_pair = (str(sender_agent), str(sender_node))
    target_pair = (str(target_agent), str(target_node))
    member_pairs = {(m["agent"], m["node"]) for m in members}
    if sender_pair not in member_pairs:
        return ROOM_TALK_SENDER_NOT_MEMBER
    if target_pair not in member_pairs:
        return ROOM_TALK_TARGET_NOT_MEMBER
    return ROOM_TALK_OK


# --------------------------------------------------------------------------
# #2079 cross-server routing authz — the admin↔admin predicate
# --------------------------------------------------------------------------
#
# Stable audit reason codes (no secret/identity-oracle ever appears on the
# wire — these are AUDIT-ONLY; the receiver/relay collapse every reject to a
# single generic 403). They name WHICH leg of the symmetric rule failed so an
# operator can debug from the audit log without a reason-bearing wire response.
ADMIN_AUTHZ_OK = "admin_authz_ok"
ADMIN_AUTHZ_NOT_ADMIN_INVOLVED = "not_admin_involved"  # ok, no admin endpoint
ADMIN_AUTHZ_PAIR_REQUIRED = "admin_pair_required"      # one admin, other not
ADMIN_AUTHZ_SENDER_NOT_ADMIN = "sender_not_admin"      # target admin, sender not
ADMIN_AUTHZ_TARGET_NOT_ADMIN = "target_not_admin"      # sender admin, target not
ADMIN_AUTHZ_METADATA_MISSING = "admin_metadata_missing"  # unknown + admin side

# Rollout compatibility: when NEITHER endpoint is a KNOWN admin but at least
# one is UNKNOWN, the delivery is non-admin traffic as far as we can tell, so it
# stays open (the brief: "missing/old admin metadata fail-closes admin-involved
# cross-node, NOT non-admin"). This is an explicit COMPAT FAIL-OPEN for legacy
# rosters, NOT fail-closed — documented honestly per Codex r1. The teeth are:
# the moment EITHER side is a KNOWN admin, an unknown counterpart fail-CLOSES.


def _member_admin_tri(members: list[dict[str, Any]],
                      pair: tuple[str, str]) -> str:
    """Tri-state admin classification of (agent,node) from a cached roster list.

    Absent member, or member without a known bit -> UNKNOWN (never non_admin).
    """
    for m in members:
        if (str(m.get("agent", "")), str(m.get("node", ""))) == pair:
            return admin_tri_from_member(m)
    return ADMIN_TRI_UNKNOWN


def admin_cross_node_authz(
    *, sender_tri: str, target_tri: str,
) -> tuple[bool, str]:
    """The symmetric admin↔admin cross-node delivery rule (#2079).

    Inputs are the TRI-STATE classifications of the two endpoints, already
    resolved by the caller (with the LOCAL endpoint RECOMPUTED from this node's
    configured admin id, never trusted from the cache/wire — see the receiver/
    relay call sites). Returns (allowed, reason):

      - Neither endpoint KNOWN-admin: allow (ADMIN_AUTHZ_NOT_ADMIN_INVOLVED).
        Covers known-non-admin↔known-non-admin AND the rollout compat case
        (unknown↔unknown / unknown↔known-non-admin) — non-admin traffic stays
        open.
      - Both endpoints KNOWN-admin: allow (ADMIN_AUTHZ_OK). The only admin-
        involved delivery permitted.
      - Exactly one endpoint KNOWN-admin, the other KNOWN-non-admin: DENY
        (sender_not_admin / target_not_admin) — a non-admin must not reach an
        admin, nor an admin a non-admin, across nodes.
      - One endpoint KNOWN-admin, the other UNKNOWN: DENY
        (admin_metadata_missing) — FAIL CLOSED. We refuse to deliver an admin-
        involved leg against an endpoint whose admin status we cannot confirm
        (the downgrade Codex r1 flagged: an unknown counterpart MUST NOT be
        treated as non-admin and let through).

    Purely functional (no db, no env) so both the receiver and the leader relay
    apply the IDENTICAL decision, and the test harness can mutation-prove every
    branch.
    """
    s_admin = sender_tri == ADMIN_TRI_ADMIN
    t_admin = target_tri == ADMIN_TRI_ADMIN
    if not s_admin and not t_admin:
        # No KNOWN admin endpoint — non-admin traffic (or rollout-unknown),
        # stays open. The symmetric rule only engages once a side is admin.
        return True, ADMIN_AUTHZ_NOT_ADMIN_INVOLVED
    if s_admin and t_admin:
        return True, ADMIN_AUTHZ_OK
    # Exactly one side is a KNOWN admin → require the OTHER side to be a KNOWN
    # admin too. An unknown other side fail-closes (metadata_missing); a known-
    # non-admin other side is the precise pair violation.
    other_tri = target_tri if s_admin else sender_tri
    if other_tri == ADMIN_TRI_UNKNOWN:
        return False, ADMIN_AUTHZ_METADATA_MISSING
    # other side is KNOWN non-admin
    return False, (ADMIN_AUTHZ_TARGET_NOT_ADMIN if s_admin
                   else ADMIN_AUTHZ_SENDER_NOT_ADMIN)


def _resolve_admin_tri(members: list[dict[str, Any]], *, agent: str, node: str,
                       this_node: str) -> str:
    """Resolve an endpoint's admin tri-state for the authz predicate.

    LOCAL OVERLAY (Codex r1 §E): if the endpoint's node IS this node, RECOMPUTE
    its classification from this node's CONFIGURED admin id (`classify_local_
    admin`) instead of trusting the cached/wire bit — the local node is the
    authority on its own admin, and a cache can be stale or a remote-signed
    roster could carry a wrong bit for a local member. For a REMOTE endpoint we
    must trust the verified leader-MAC roster (we have no other source). A local
    node with NO configured admin id yields None -> UNKNOWN (never non_admin).
    """
    if node and node == this_node:
        local = classify_local_admin(agent)
        if local is None:
            return ADMIN_TRI_UNKNOWN
        return ADMIN_TRI_ADMIN if local else ADMIN_TRI_NON_ADMIN
    return _member_admin_tri(members, (str(agent), str(node)))


def room_admin_authz_check(
    conn: sqlite3.Connection, *, room_id: str, room_epoch: int,
    sender_agent: str, sender_node: str, target_agent: str, target_node: str,
    this_node: str,
) -> tuple[bool, str]:
    """Receiver-side #2079 admin-authz over the VERIFIED leader-MAC roster cache.

    Runs AFTER `roster_cache_membership_check` has already confirmed both
    endpoints are cached members at the cached epoch (so the cache row exists,
    parses, and the epoch matches). Resolves each endpoint's admin tri-state
    (recomputing the LOCAL endpoint from this node's configured admin id) and
    applies `admin_cross_node_authz`. Returns (allowed, audit_reason). The
    caller collapses any deny to the single generic 403; the reason is AUDIT-
    ONLY (no reason-bearing wire response).

    Defensive: if the cache is unexpectedly missing/corrupt at this point, fail
    OPEN-to-membership is wrong — return (False, metadata_missing) so an admin-
    involved delivery cannot slip through on a torn cache. A non-room / non-
    admin path never reaches here.
    """
    row = get_roster_cache(conn, room_id)
    if row is None or int(room_epoch) != int(row["epoch"]):
        return False, ADMIN_AUTHZ_METADATA_MISSING
    members = _cached_members(row)
    if members is None:
        return False, ADMIN_AUTHZ_METADATA_MISSING
    sender_tri = _resolve_admin_tri(
        members, agent=sender_agent, node=sender_node, this_node=this_node)
    target_tri = _resolve_admin_tri(
        members, agent=target_agent, node=target_node, this_node=this_node)
    return admin_cross_node_authz(sender_tri=sender_tri, target_tri=target_tri)


def _authoritative_member_admin_tri(
    conn: sqlite3.Connection, *, room_id: str, agent: str, node: str,
    this_node: str,
) -> str:
    """Endpoint admin tri-state from the leader's AUTHORITATIVE room_members.

    Used by the leader relay (`_relay_resolve`): the leader holds the canonical
    membership, so it reads `room_members.admin` directly rather than a cache.
    LOCAL OVERLAY (Codex r1 §E): a member on the LEADER's OWN node is
    reclassified from this node's configured admin id, never the stored bit.
    A member absent from the room -> UNKNOWN.
    """
    if node and node == this_node:
        local = classify_local_admin(agent)
        if local is None:
            return ADMIN_TRI_UNKNOWN
        return ADMIN_TRI_ADMIN if local else ADMIN_TRI_NON_ADMIN
    row = conn.execute(
        "SELECT admin FROM room_members WHERE room_id=? AND agent=? AND node=?",
        (room_id, agent, node),
    ).fetchone()
    if row is None:
        return ADMIN_TRI_UNKNOWN
    return admin_tri_from_col(row["admin"])


def relay_admin_authz_check(
    conn: sqlite3.Connection, *, room_id: str,
    sender_agent: str, sender_node: str, target_agent: str, target_node: str,
    this_node: str,
) -> tuple[bool, str]:
    """Leader-relay #2079 admin-authz over the AUTHORITATIVE room_members.

    The leader applies the SAME `admin_cross_node_authz` rule BEFORE forwarding
    a relayed room message, reading the canonical `room_members.admin` (with the
    leader's own node recomputed locally). A deny collapses to the same generic
    403 the receiver returns. Returns (allowed, audit_reason).
    """
    sender_tri = _authoritative_member_admin_tri(
        conn, room_id=room_id, agent=sender_agent, node=sender_node,
        this_node=this_node)
    target_tri = _authoritative_member_admin_tri(
        conn, room_id=room_id, agent=target_agent, node=target_node,
        this_node=this_node)
    return admin_cross_node_authz(sender_tri=sender_tri, target_tri=target_tri)


def accept_roster_broadcast(
    conn: sqlite3.Connection, *, room_id: str, room_epoch: int,
    members: list[dict[str, Any]], leader_node: str, peer_id: str,
    message_id: str, body_sha256: str, mac: str = "",
) -> str:
    """Apply a verified leader roster broadcast to the member-local cache.

    The member-side heart of P4.2. The CALLER (the receiver) has ALREADY verified
    the node-link pairwise HMAC over the canonical request (so `peer_id` is the
    authenticated sender node and the body is intact). This function encodes the
    remaining security contracts and performs the ATOMIC dedupe-reserve + cache
    write. Returns a ROSTER_* outcome code; raises RoomsError only on an
    unexpected DB fault.

    Contracts enforced here (brief §3):
      a. LEADER-AUTHORITY (3a): accept ONLY when `peer_id == leader_node`. A
         roster whose body `leader_node` != the authenticated sender →
         ROSTER_NOT_LEADER, persists NOTHING. (The pairwise-HMAC verify in 3b is
         the caller's job; a bad HMAC never reaches here.)
      a'. LEADER PINNING (codex P4.2 r1 BLOCKING — close the rogue-leader
         TAKEOVER of an EXISTING room): once a cache exists, the room's leader is
         PINNED to the cached `from_node`. A DIFFERENT configured peer that
         self-claims `leader_node=<itself>` + signs a higher epoch must NOT
         overwrite the cache → ROSTER_LEADER_MISMATCH, persists NOTHING. Without
         this, contract 3a alone (`peer_id == leader_node`) is trivially
         satisfied by any peer naming itself leader, so the first-roster binding
         would only protect the FIRST roster, not subsequent updates.
      c. FIRST-ROSTER BINDING (3c): if NO cache row exists yet for this room, the
         member accepts the first roster ONLY if it holds LOCAL outbound join
         state for THIS room naming THIS leader_node
         (`_local_join_binding_for`). Otherwise → ROSTER_NO_LOCAL_BINDING,
         persists NOTHING. NEVER mint a room cache purely from an inbound roster.
      d. MONOTONIC EPOCH (3d): with an existing cache (from the PINNED leader), a
         STRICTLY-higher epoch updates; a lower-or-same epoch is IGNORED
         (ROSTER_STALE_EPOCH) UNLESS the incoming roster is BYTE-IDENTICAL to the
         cached one at the SAME epoch (ROSTER_DUPLICATE — idempotent, no write).
      e. ATOMIC dedupe + update (3e + codex P4.2 r3 BLOCKING — close the TOCTOU
         race): for any outcome that WRITES the cache (ACCEPTED), the peer-scoped
         dedupe RESERVATION and the room_roster_cache WRITE commit in ONE
         transaction (single serialization point). The dedupe reservation is the
         `room_join_dedupe` PRIMARY KEY (peer, message_id), so:
           - a fresh (peer, message_id) → reserve + write cache + commit together.
           - a same (peer, message_id) with a DIFFERENT body_sha256 →
             ROSTER_DEDUPE_CONFLICT, write NOTHING (rolled back). The receiver
             answers 409. This holds EVEN under a check-then-write race: two
             concurrent same-id deliveries cannot both pass + both write — the PK
             serializes them and the loser is re-classified (IntegrityError →
             re-query → conflict/duplicate), never a partial cache mutation.
           - a same (peer, message_id) with the SAME body_sha256 →
             ROSTER_DUPLICATE (idempotent — the cache already reflects it; no
             double-apply).
         A contract REJECT (not_leader / leader_mismatch / no_binding /
         stale_epoch) reserves NO dedupe row, so a replay re-evaluates the
         contracts (the stale/not-leader teeth hold on replay).

    `members` MUST be the canonical sorted roster (the bytes the leader signed);
    we re-canonicalize on store so the cached `members_json` is reproducible.
    `mac` is the presented per-link signature (stored for audit/debug; the real
    auth is the receiver's HMAC verify, already done). `message_id`/`body_sha256`
    are the dedupe key (peer-scoped) the receiver carries from the wire headers.
    """
    # --- 3a: leader-authority binding — the authenticated sender must be the
    # node the body names as leader. (peer_id is the un-spoofable HMAC-authed
    # X-AGB-Peer; leader_node is the body's claim.) ---
    if peer_id != leader_node:
        return ROSTER_NOT_LEADER

    incoming_members = _canonical_member_list(members)
    incoming_json = json.dumps(incoming_members, separators=(",", ":"))
    epoch = int(room_epoch)

    existing = get_roster_cache(conn, room_id)
    if existing is None:
        # --- 3c: FIRST-ROSTER binding — never mint a cache from an inbound
        # roster alone; the member must have chosen this room+leader locally. ---
        if not _local_join_binding_for(conn, room_id, leader_node):
            return ROSTER_NO_LOCAL_BINDING
        # WRITE path → atomic dedupe-reserve + cache write (3e).
        return _reserve_and_write_roster_cache(
            conn, peer=peer_id, message_id=message_id, body_sha256=body_sha256,
            room_id=room_id, epoch=epoch, members_json=incoming_json,
            from_node=leader_node, mac=mac)

    # --- 3a': LEADER PINNING — an existing cache fixes the room's leader to its
    # established `from_node`. A roster signed by a DIFFERENT peer is a TAKEOVER
    # attempt → reject, persist nothing (even at a higher epoch). The legitimate
    # leader always signs with its own node id == the cached from_node, so this
    # never blocks a genuine update from the real leader.
    #
    # The comparison is UNGUARDED by truthiness (codex P4.2 r2 BLOCKING): an
    # existing cache whose `from_node` is "" is a SINGLE-NODE/local room (P1a
    # seeds `from_node=leader_node`, which is "" when local_node() is empty). A
    # remote peer arriving over a node-link ALWAYS has a non-empty authenticated
    # `peer_id == leader_node`, so for any such inbound roster `leader_node !=
    # "" == cached_from_node` → rejected. A remote node can therefore NEVER claim
    # leadership of a local/single-node room via a roster broadcast. ---
    cached_leader = str(existing["from_node"] or "")
    if leader_node != cached_leader:
        return ROSTER_LEADER_MISMATCH

    # --- 3d: monotonic epoch (existing cache present, leader pinned) ---
    cached_epoch = int(existing["epoch"])
    if epoch > cached_epoch:
        # WRITE path → atomic dedupe-reserve + cache write (3e).
        return _reserve_and_write_roster_cache(
            conn, peer=peer_id, message_id=message_id, body_sha256=body_sha256,
            room_id=room_id, epoch=epoch, members_json=incoming_json,
            from_node=leader_node, mac=mac)
    # epoch <= cached_epoch: accept ONLY a byte-identical idempotent duplicate
    # (same epoch AND same canonical members AND same leader node). Everything
    # else (a lower epoch, or a same-epoch roster with DIFFERENT contents — a
    # replay/forge attempt) is ignored without a write.
    if (epoch == cached_epoch
            and str(existing["members_json"]) == incoming_json
            and str(existing["from_node"] or "") == leader_node):
        # A byte-identical re-broadcast does NOT need a cache write (the cache
        # already reflects it), but it MUST still BURN the (peer, message_id) in
        # the dedupe ledger (codex P4.2 r3 BLOCKING): a terminal ROSTER_DUPLICATE
        # that did not reserve the id would let a LATER (peer, SAME id, DIFFERENT
        # body, higher epoch) reuse be treated as fresh and ACCEPTED. The
        # reserve-only path records the id (or re-classifies a same-id/different-
        # body reuse to ROSTER_DEDUPE_CONFLICT) WITHOUT touching the cache.
        return _reserve_roster_dedupe_only(
            conn, peer=peer_id, message_id=message_id, body_sha256=body_sha256)
    return ROSTER_STALE_EPOCH


def _reserve_and_write_roster_cache(
    conn: sqlite3.Connection, *, peer: str, message_id: str, body_sha256: str,
    room_id: str, epoch: int, members_json: str, from_node: str, mac: str,
) -> str:
    """ATOMICALLY reserve the peer-scoped dedupe row AND write the roster cache.

    The single serialization point that closes the TOCTOU dedupe/cache race
    (codex P4.2 r3 BLOCKING). Mirrors P4.1's
    `record_verified_cross_node_join_request_atomic`: a pre-check + an
    IntegrityError-on-PK fallback re-query, so two concurrent same-id deliveries
    cannot both pass + both write. Both the `room_join_dedupe` reservation and
    the `room_roster_cache` write are issued WITHOUT an intermediate commit, then
    ONE commit makes them durable together; any failure before the commit rolls
    BOTH back (no orphan dedupe row, no partial cache).

    Returns:
      - ROSTER_DEDUPE_CONFLICT : (peer, message_id) already used with a DIFFERENT
        body → write NOTHING.
      - ROSTER_DUPLICATE       : (peer, message_id) already reserved with the
        SAME body → idempotent, write NOTHING (the cache already reflects it).
      - ROSTER_ACCEPTED        : fresh id → dedupe row + cache row committed
        together.
    """
    # Pre-check inside this call (the caller did no read-only dedupe check on the
    # write path). Scoped to the authenticated peer (composite PK).
    existing = conn.execute(
        "SELECT body_sha256 FROM room_join_dedupe WHERE peer=? AND message_id=?",
        (peer, message_id),
    ).fetchone()
    if existing is not None:
        return (ROSTER_DUPLICATE if existing["body_sha256"] == body_sha256
                else ROSTER_DEDUPE_CONFLICT)
    try:
        conn.execute(
            "INSERT INTO room_join_dedupe (message_id, peer, body_sha256, "
            "created_ts) VALUES (?, ?, ?, ?)",
            (message_id, peer, body_sha256, now_ts()),
        )
        conn.execute(
            "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
            "members_json, from_node, mac, fetched_ts) VALUES (?, ?, ?, ?, ?, ?)",
            (room_id, epoch, members_json, from_node, mac, now_ts()),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        # Lost a concurrent (peer, message_id) PK race — roll BOTH writes back and
        # re-query the winner's row, returning the SAME idempotent/conflict
        # outcome the pre-check would have. The loser thus gets a clean
        # duplicate/conflict (never a partial cache mutation, never a 500).
        conn.rollback()
        winner = conn.execute(
            "SELECT body_sha256 FROM room_join_dedupe "
            "WHERE peer=? AND message_id=?",
            (peer, message_id),
        ).fetchone()
        if winner is not None:
            return (ROSTER_DUPLICATE if winner["body_sha256"] == body_sha256
                    else ROSTER_DEDUPE_CONFLICT)
        # PK violation from somewhere other than a concurrent winner (should not
        # happen) — surface it rather than silently swallow.
        raise
    except Exception:
        # Roll BOTH writes back so a failed cache insert never leaves an orphan
        # dedupe reservation (the atomicity contract).
        conn.rollback()
        raise
    return ROSTER_ACCEPTED


def _reserve_roster_dedupe_only(
    conn: sqlite3.Connection, *, peer: str, message_id: str, body_sha256: str,
) -> str:
    """BURN a (peer, message_id) in the dedupe ledger WITHOUT writing the cache.

    The reserve-only sibling of `_reserve_and_write_roster_cache` (codex P4.2 r3
    BLOCKING — close the duplicate-branch id-reuse hole). Used by the byte-
    identical-existing-cache ROSTER_DUPLICATE branch: the cache already reflects
    the roster (no write needed), but the id MUST still be recorded so a LATER
    same-(peer, message_id)/DIFFERENT-body reuse is a CONFLICT rather than a
    fresh accept. Returns:
      - ROSTER_DEDUPE_CONFLICT : (peer, message_id) already used with a DIFFERENT
        body → caller answers 409.
      - ROSTER_DUPLICATE       : a fresh reservation OR a same-body re-reservation
        (idempotent) → the id is now burned, no cache change.
    Uses the same IntegrityError-rollback-and-requery guard as the write helper
    so a concurrent same-id duplicate cannot double-insert (the PK serializes).
    """
    existing = conn.execute(
        "SELECT body_sha256 FROM room_join_dedupe WHERE peer=? AND message_id=?",
        (peer, message_id),
    ).fetchone()
    if existing is not None:
        return (ROSTER_DUPLICATE if existing["body_sha256"] == body_sha256
                else ROSTER_DEDUPE_CONFLICT)
    try:
        conn.execute(
            "INSERT INTO room_join_dedupe (message_id, peer, body_sha256, "
            "created_ts) VALUES (?, ?, ?, ?)",
            (message_id, peer, body_sha256, now_ts()),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        # Lost a concurrent (peer, message_id) PK race — roll back + re-query the
        # winner, returning the SAME idempotent/conflict outcome the pre-check
        # would have (never a raise, never a cache mutation — there is none here).
        conn.rollback()
        winner = conn.execute(
            "SELECT body_sha256 FROM room_join_dedupe "
            "WHERE peer=? AND message_id=?",
            (peer, message_id),
        ).fetchone()
        if winner is not None:
            return (ROSTER_DUPLICATE if winner["body_sha256"] == body_sha256
                    else ROSTER_DEDUPE_CONFLICT)
        raise
    return ROSTER_DUPLICATE


def _canonical_member_list(members: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Re-sort + normalize a roster member list to the canonical (agent,node)
    ordering, so the stored cache bytes are reproducible regardless of the
    wire order (defensive — the leader already sorts, but a verifier must not
    depend on the sender's ordering for its stored canonical form).

    #2079: the OPTIONAL "bridge_admin" bool is preserved EXACTLY — present only
    when the inbound member carried a real bool (known), omitted otherwise
    (unknown). We must NOT default it to false here: that would forge a known-
    non-admin classification for a legacy/unattested member (the downgrade
    Codex r1 flagged). Key-absent stays key-absent through canonicalization, so
    the re-canonicalized bytes a verifier stores match the leader-signed bytes.
    """
    norm: list[dict[str, Any]] = []
    for m in members:
        entry: dict[str, Any] = {
            "agent": str(m.get("agent", "")),
            "node": str(m.get("node", "")),
            "role": str(m.get("role", "")),
        }
        tri = admin_tri_from_member(m)
        if tri == ADMIN_TRI_ADMIN:
            entry["bridge_admin"] = True
        elif tri == ADMIN_TRI_NON_ADMIN:
            entry["bridge_admin"] = False
        norm.append(entry)
    norm.sort(key=lambda m: (m["agent"], m["node"]))
    return norm


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


def rooms_acl_mode_strict(db_path: Optional[Path] = None) -> str:
    """Return the rooms_acl mode, but RAISE on a present-but-unreadable db.

    The lenient `rooms_acl_mode()` collapses every fault to ACL_OFF (back-compat
    for read paths that must degrade). That is a FAIL-OPEN for the P1b queue gate:
    a previously-enforced rooms.db that becomes unreadable/corrupt would read
    'off' and silently drop enforcement (codex r1 BLOCKING). This strict variant
    distinguishes:
      - db ABSENT (no rooms ever defined) -> ACL_OFF (legitimate back-compat).
      - db present + readable             -> the stored mode.
      - db present + UNREADABLE/corrupt   -> raises RoomsError so the queue gate
                                             can fail CLOSED for a real iso actor.

    `db_path` pins the EXACT rooms.db (P1b r3): the queue gate passes the CANONICAL
    rooms.db derived from the real task-DB home so a caller-redirected
    `BRIDGE_A2A_ROOMS_DB` cannot point the mode read at a self-owned fake.
    """
    conn = open_rooms_readonly(db_path)  # raises RoomsError on present-but-unreadable
    if conn is None:
        return ACL_OFF  # no db at all -> no rooms -> off (back-compat)
    try:
        row = conn.execute(
            "SELECT v FROM rooms_acl_config WHERE k=?", (_ACL_CONFIG_KEY,)
        ).fetchone()
    except sqlite3.Error as exc:
        # db opened read-only but the query failed (corrupt schema/page) -> a real
        # fault, NOT "no rooms". Surface it so the gate fails closed.
        raise RoomsError(
            f"rooms.db present but rooms_acl_config is unreadable: {exc}",
            code="rooms_acl_unreadable",
        ) from exc
    finally:
        conn.close()
    if row is None:
        return ACL_OFF
    val = str(row["v"]).strip().lower()
    return val if val in (ACL_OFF, ACL_ENFORCE) else ACL_OFF


# --------------------------------------------------------------------------
# P1b — internal-queue rooms ACL decision (design §7 / §14 R1)
# --------------------------------------------------------------------------
#
# This is the SINGLE source of truth for "may sender S create a durable queue
# task addressed to recipient R?". It is consumed at the two real create
# paths so the security logic lives in ONE tested place:
#
#   1. The iso-v2 queue GATEWAY (bridge-queue-gateway.py:authorize_and_rewrite)
#      — the PRIMARY, OS-enforced gate. There `actor` is the SO_PEERCRED
#      uid->agent (un-spoofable); the client-supplied --from/BRIDGE_AGENT_ID
#      have already been rewritten away. regime = ACTOR_ISO_ENFORCED.
#   2. bridge-queue.py:cmd_create — defense-in-depth + the NON-gateway paths
#      (controller/daemon/cron creates that run as the controller UID; genuine
#      shared-mode single-UID installs). There the actor + regime come from
#      resolve_os_actor() (the OS identity), NEVER from a client flag.
#
# The decision is a PURE function of (mode, regime, actor, target, rooms.db).
# It performs NO env/roster probing on the security path beyond the membership
# lookup against the controller-owned rooms.db.

# Audit reason codes (stable, public-safe — surfaced in gateway/queue logs).
ACL_ALLOW_MODE_OFF = "acl_off"                  # default no-op pass
ACL_ALLOW_CONTROLLER = "acl_controller_bypass"  # operator/daemon/cron/receiver
ACL_ALLOW_SELF = "acl_self_message"             # actor == target
ACL_ALLOW_NO_ROOMS = "acl_no_rooms"             # enforce but no rooms exist
ACL_ALLOW_TARGET_UNROOMED = "acl_target_unroomed"  # target in no enforced room
ACL_ALLOW_SHARED_ROOM = "acl_shared_room"       # actor+target co-inhabit a room
ACL_DENY_CROSS_ROOM = "acl_denied"              # no shared room (hard block)
ACL_DENY_FAIL_CLOSED = "acl_fail_closed"        # actor un-establishable / db fault
ACL_ADVISORY_CROSS_ROOM = "acl_advisory_cross_room"  # shared-mode: warn, no block


class AclDecision(NamedTuple):
    """The rooms-ACL verdict for one `create --to <target>`.

    `outcome` is one of "allow" | "deny" | "advisory":
      - "allow"    : let the create proceed.
      - "deny"     : HARD block (fail-closed) — only ever returned for a real,
                     OS-enforced sender (ISO_ENFORCED) or an un-establishable
                     trusted actor under enforce. Never returned in shared mode.
      - "advisory" : shared-mode cross-room — audit/warn, but DO NOT block
                     (same-UID agents are not OS-separable, §14 R1).
    `reason` is one of the ACL_* codes above (audit + stderr). `shared` carries
    the room ids actor+target co-inhabit (for the allow audit line).
    """

    outcome: str
    reason: str
    shared: list[str]


def acl_create_decision(
    *,
    mode: str,
    regime: str,
    actor: str,
    target: str,
    node: str = "",
    conn: Optional[sqlite3.Connection] = None,
) -> AclDecision:
    """Decide whether sender `actor` may `create --to target` under the rooms ACL.

    Pure decision (design §14 R1). The caller MUST pass an OS-derived `actor` +
    `regime` (resolve_os_actor / the gateway SO_PEERCRED peer). A client-supplied
    --from/BRIDGE_AGENT_ID is NEVER an input here — that is the whole point.

      - mode == off                  -> allow (true no-op; zero behavior change).
      - regime == ACTOR_CONTROLLER   -> allow (operator/daemon/cron/receiver run
                                        as the controller UID; non-spoofable —
                                        this is the system/daemon exemption).
      - regime == ACTOR_UNRESOLVED   -> deny, fail-closed (iso host but the actor
                                        could not be OS-established).
      - actor == target              -> allow (self-message).
      - no enforced room exists      -> allow (back-compat; adopt-all is the
                                        operator's migration to make this engage).
      - target is in NO enforced room-> allow + audit (target is a non-room
                                        participant; the gate is roster↔roster).
      - actor+target share a room    -> allow.
      - otherwise (cross-room):
          * ISO_ENFORCED             -> deny (the hard team boundary).
          * SHARED_ADVISORY          -> advisory (warn + audit, NO block).

    `rooms.db` unreadable/absent under enforce for a real roster-agent actor
    (ISO_ENFORCED) -> fail CLOSED (deny). For shared mode a db fault degrades to
    advisory (no hard boundary is claimed there anyway).
    """
    if mode != ACL_ENFORCE:
        return AclDecision("allow", ACL_ALLOW_MODE_OFF, [])

    # Exemption 1: the controller / daemon / cron / receiver. All of these run
    # as the controller OS UID (they own the rooms.db), so ACTOR_CONTROLLER is
    # an OS fact, NOT a `--from daemon`/`cron:x` string a managed agent could
    # type. This is the system/daemon/operator exemption, kept minimal + non-
    # spoofable by construction (§14 R1 trusted-call-path bypass).
    if regime == ACTOR_CONTROLLER:
        return AclDecision("allow", ACL_ALLOW_CONTROLLER, [])

    # Fail-closed: an iso host where the actor could not be OS-established. We
    # must NOT fall back to a client-supplied id (that would be the spoof).
    if regime == ACTOR_UNRESOLVED or not actor:
        return AclDecision("deny", ACL_DENY_FAIL_CLOSED, [])

    # Self-message is always fine (an agent talking to itself is not cross-team).
    if actor == target:
        return AclDecision("allow", ACL_ALLOW_SELF, [])

    advisory = (regime == ACTOR_SHARED_ADVISORY)

    own = False
    if conn is None:
        try:
            conn = open_rooms_readonly()
        except RoomsError:
            # rooms.db present but unreadable -> a real fault. For an OS-enforced
            # roster agent under enforce, fail CLOSED (never fall open). Shared
            # mode has no hard boundary -> degrade to advisory.
            if advisory:
                return AclDecision("advisory", ACL_DENY_FAIL_CLOSED, [])
            return AclDecision("deny", ACL_DENY_FAIL_CLOSED, [])
        if conn is None:
            # No rooms.db at all -> no rooms ever defined -> back-compat open.
            return AclDecision("allow", ACL_ALLOW_NO_ROOMS, [])
        own = True
    try:
        actor_rooms = members_for(conn, actor, node)
        if not actor_rooms:
            # The actor belongs to NO enforced room. With ≥1 room defined this
            # is an operator-config gap (the actor was never adopted). Under
            # enforce that is a loud config error for a real roster agent, not a
            # silent allow: a room-less iso agent must not freely reach roomed
            # agents. Shared mode stays advisory.
            target_rooms_chk = members_for(conn, target, node)
            if not target_rooms_chk:
                # Neither party is in any room — the whole install has no rooms
                # touching this pair -> back-compat open (nothing to enforce).
                return AclDecision("allow", ACL_ALLOW_NO_ROOMS, [])
            if advisory:
                return AclDecision(
                    "advisory", ACL_ADVISORY_CROSS_ROOM, [])
            return AclDecision("deny", ACL_DENY_CROSS_ROOM, [])
        target_rooms = members_for(conn, target, node)
        if not target_rooms:
            # The target participates in NO room (e.g. a system/admin agent that
            # was never adopted). The gate is roster-agent <-> roster-agent; a
            # non-room target is not a team peer to be walled off -> allow but
            # audit so an operator can spot an un-adopted recipient.
            return AclDecision("allow", ACL_ALLOW_TARGET_UNROOMED, [])
        shared = sorted(set(actor_rooms) & set(target_rooms))
        if shared:
            return AclDecision("allow", ACL_ALLOW_SHARED_ROOM, shared)
        if advisory:
            return AclDecision("advisory", ACL_ADVISORY_CROSS_ROOM, [])
        return AclDecision("deny", ACL_DENY_CROSS_ROOM, [])
    except sqlite3.Error:
        if advisory:
            return AclDecision("advisory", ACL_DENY_FAIL_CLOSED, [])
        return AclDecision("deny", ACL_DENY_FAIL_CLOSED, [])
    finally:
        if own and conn is not None:
            conn.close()
