#!/usr/bin/env python3
"""bridge-rooms.py — Agent Bridge A2A *rooms* control-plane CLI.

Surfaced through `agent-bridge room ...` / `agb room ...`. Manages the
rooms.db control plane (design docs/design/a2a-rooms-design.md §6, §14
R2/R6) on a SINGLE node:

  create        Mint a room (leader row, epoch=0), print the one-time
                invite link ONCE (only the token hash is stored).
  list          List rooms (`--owned` = rooms this node leads).
  show          Show a room's roster + epoch + pending join requests.
  invite        Mint/replace the invite token (`--once` = single-use).
  rotate-invite Rotate the token, invalidating the old one.
  join          Post a pending join-request (validates the token hash,
                rate-limits per token+source). Single-node: joiner + leader
                share this node.
  approve/deny  Leader-only: approve => add member + bump epoch + recompute
                roster; deny => mark the request denied.
  kick/leave    Remove a member + bump epoch (leader-only kick; self leave).
  adopt-all     Create a default room containing every current roster agent
                (the migration that lets P1b's `enforce` strand nothing).
  acl           Show / set the rooms_acl mode (off|enforce). P1a does NOT
                enforce — this only records the mode P1b reads.

Leader-authorized mutations in P1a check caller-agent == leader_agent
(single node). Cross-node leader-auth over the node-link is P4. The schema,
epoch contract, and canonical roster shape are FROZEN in bridge_rooms_common.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Optional

import bridge_rooms_common as rooms

try:  # A2A config is the source of the local node id; optional in single-node.
    import bridge_a2a_common as a2a
except ImportError:  # pragma: no cover - a2a module always ships beside this
    a2a = None  # type: ignore[assignment]


# --------------------------------------------------------------------------
# small output helpers
# --------------------------------------------------------------------------

def err(msg: str) -> None:
    print(f"[rooms][error] {msg}", file=sys.stderr)


def info(msg: str) -> None:
    print(f"[rooms] {msg}", file=sys.stderr)


def out(msg: str) -> None:
    print(msg)


def die(msg: str, code: int = 1) -> int:
    err(msg)
    return code


# --------------------------------------------------------------------------
# identity resolution (single-node P1a)
# --------------------------------------------------------------------------

def local_node() -> str:
    """The local node id — the A2A config `bridge_id`, or '' in single-node.

    Empty is fine for single-node P1a: the leader_node column tolerates ''
    and `is_leader` only checks node when the room carries a non-empty
    leader_node. P4 makes the node meaningful via the node-link.
    """
    if a2a is None:
        return ""
    try:
        cfg = a2a.load_config()
    except Exception:  # noqa: BLE001 - config may be absent in single-node
        return ""
    return str(cfg.get("bridge_id", "") or "").strip()


def resolve_actor(args: argparse.Namespace) -> rooms.ActorAuth:
    """Resolve the trusted acting agent from the PROCESS OS identity (§14 R1).

    The acting identity is NEVER taken from `--as`/`BRIDGE_AGENT_ID` for an
    iso agent — it is derived from `os.getuid()`. `--as` is passed through as
    the `requested` override that only the CONTROLLER / SHARED_ADVISORY
    regimes honor (an iso agent's `--as` is ignored for the decision).
    """
    requested = getattr(args, "as_agent", None)
    return rooms.resolve_os_actor(requested)


def caller_agent(args: argparse.Namespace) -> str:
    """The trusted acting agent id for self-service verbs (create/join/leave).

    Used as the identity a self-service verb records (the join requester, the
    leaver, the room creator) and as the audit actor. It is the OS-derived
    trusted actor (see resolve_actor):
      - ISO_ENFORCED   : the uid-derived agent (unspoofable).
      - CONTROLLER     : the proven operator's `--as`/best-effort id.
      - SHARED_ADVISORY: the best-effort caller id (advisory mode).
      - UNRESOLVED     : iso is active but this uid maps to no agent and is not
                         the controller → there is NO legitimate identity, so
                         we FAIL CLOSED rather than fall back to a
                         caller-controlled `$USER` (which would let a spoofed
                         join/leave identity through — codex Phase-4 r3 F1 #3).
    """
    actor = resolve_actor(args)
    if actor.regime == rooms.ACTOR_UNRESOLVED:
        raise rooms.RoomsError(
            f"cannot establish a trusted actor for uid {actor.uid}: "
            "linux-user isolation is active but this uid maps to no agent and "
            "is not the controller — refusing to act under an untrusted "
            "identity",
            code="actor_unresolved",
        )
    if actor.agent:
        return actor.agent
    # ISO/CONTROLLER/SHARED with an empty best-effort id (e.g. no $USER): refuse
    # rather than invent "unknown" — a mutation needs a real actor.
    raise rooms.RoomsError(
        "could not resolve an acting agent id (no OS-trusted actor and no "
        "best-effort identity available)", code="actor_unresolved",
    )


def require_leader_actor(args: argparse.Namespace, room: Any) -> str:
    """Enforce leader-auth on a control-plane mutation per the §14 R1 regime.

    Returns the resolved actor agent on success. Raises RoomsError on a hard
    denial. Regimes:
      - ISO_ENFORCED  : HARD — the process's ACTUAL OS username (a passwd fact)
                        MUST equal the expected iso OS user for the room's
                        leader (`default_os_user_slug(leader_agent)`). This is a
                        pure comparison with NO roster/probe/env on the security
                        path, so a managed agent cannot influence it (codex
                        Phase-4 r5/r6 closed the roster-injection class by
                        removing the probe entirely).
      - UNRESOLVED    : HARD fail-closed — no trusted actor could be derived
                        (iso active on host but this process is neither an iso
                        agent nor the controller).
      - CONTROLLER    : a proven operator shell — allowed (operator override),
                        honoring `--as` for the recorded leader identity.
      - SHARED_ADVISORY: the OS cannot separate agents → ADVISORY. If the
                        best-effort actor is not the leader, WARN + audit but
                        DO NOT hard-block (per §14 R1).
    """
    actor = resolve_actor(args)
    if actor.regime == rooms.ACTOR_ISO_ENFORCED:
        my_os_user = rooms.process_os_user()
        expected = rooms.default_os_user_slug(str(room["leader_agent"]))
        if my_os_user != expected:
            raise rooms.RoomsError(
                f"leader-only action on room {room['room_id']}: this process's "
                f"OS user {my_os_user!r} (uid {actor.uid}) is not the leader's "
                f"OS user {expected!r} (leader {room['leader_agent']!r}); --as "
                "is ignored under iso enforcement",
                code="not_leader",
            )
        return str(room["leader_agent"])
    if actor.regime == rooms.ACTOR_UNRESOLVED:
        raise rooms.RoomsError(
            f"leader-only action on room {room['room_id']}: could not establish "
            f"a trusted OS actor for uid {actor.uid} (linux-user isolation is "
            "active on this host but this process is neither an iso agent nor "
            "the controller) — failing closed",
            code="actor_unresolved",
        )
    if actor.regime == rooms.ACTOR_CONTROLLER:
        # Proven operator shell: honor --as as the leader identity override.
        return actor.agent or room["leader_agent"]
    # SHARED_ADVISORY: advisory only — warn but allow.
    if not rooms.is_leader(room, actor.agent, caller_node=local_node()):
        info(f"WARNING (advisory): shared-mode install cannot OS-authenticate "
             f"the actor; '{actor.agent}' is not the recorded leader "
             f"('{room['leader_agent']}') of {room['room_id']}. Leader-auth is "
             "ADVISORY in shared mode (no per-agent OS uid). For a hard team "
             "boundary, run agents under linux-user isolation (iso v2).")
    return actor.agent


def split_agent_node(spec: str, default_node: str) -> tuple[str, str]:
    """Parse an `agent@node` target; bare `agent` uses `default_node`."""
    spec = spec.strip()
    if "@" in spec:
        agent, _, node = spec.partition("@")
        return agent.strip(), node.strip()
    return spec, default_node


# --------------------------------------------------------------------------
# roster agent enumeration (for adopt-all)
# --------------------------------------------------------------------------

def _roster_agents() -> list[str]:
    """Every current roster agent id, via `agent-bridge agent list --json`.

    adopt-all seeds a default room with the live roster so flipping P1b's
    `enforce` strands nothing. We consume the STRUCTURED `agent list --json`
    envelope (each record carries an "agent" key) rather than parse the
    human table (locale-dependent) or re-read the roster .sh files
    (controller-owned, possibly unreadable from an iso UID).
    """
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [os.path.join(here, "agent-bridge"), os.path.join(here, "agb")]
    cli = next((c for c in candidates if os.path.isfile(c)), None)
    if cli is None:
        return []
    import subprocess

    try:
        proc = subprocess.run(
            [cli, "agent", "list", "--json"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    try:
        doc = json.loads(proc.stdout)
    except (ValueError, json.JSONDecodeError):
        return []
    # The envelope may be a bare list of records OR an object wrapping a
    # list under a records/agents key — accept both shapes.
    records: list[Any]
    if isinstance(doc, list):
        records = doc
    elif isinstance(doc, dict):
        records = (doc.get("agents") or doc.get("records") or [])
        if not isinstance(records, list):
            records = []
    else:
        records = []
    agents: list[str] = []
    for rec in records:
        if isinstance(rec, dict):
            agent = str(rec.get("agent") or rec.get("id") or "").strip()
        elif isinstance(rec, str):
            agent = rec.strip()
        else:
            agent = ""
        if agent and agent not in agents:
            agents.append(agent)
    return agents


# --------------------------------------------------------------------------
# Signed invite link (reach=) — A2A Rooms v0.16.5 Lane 4, #1695
# --------------------------------------------------------------------------

_INVITE_LINK_VERSION = "2"


def _leader_reach_from_cfg(cfg: dict[str, Any]) -> dict[str, Any]:
    """Build the leader's transport reach locator {kind, address, port} from the
    local A2A config's `listen` block. NO secret rides here."""
    listen = cfg.get("listen", {}) if isinstance(cfg, dict) else {}
    try:
        kind = a2a.transport_kind(cfg)
    except Exception:  # noqa: BLE001 - default tailscale on any shape error
        kind = a2a.TRANSPORT_TAILSCALE if a2a is not None else "tailscale"
    address = str(listen.get("address", "") or "").strip()
    try:
        port = int(listen.get("port", 8787) or 8787)
    except (TypeError, ValueError):
        port = 8787
    return {"kind": kind, "address": address, "port": port}


def _make_invite_link_for(node: str, token: str, room_id: str,
                          link_ttl: Optional[int] = None) -> str:
    """Build the invite link the leader hands out. When the local A2A config is
    available, emit a v2 SIGNED invite that carries the leader's `reach=`
    transport locator plus a freshness tuple (`iat`/`ttl`/`nonce`) bound into a
    token-signed canonical. Falls back to the legacy unsigned link (single-node /
    no a2a / no reachable address).

    Integrity scope (SK-1, honest): the canonical signature is keyed on a value
    derived from the raw token (the `t=` bearer in the SAME link), so it proves
    integrity against a BLIND on-path tamperer who does NOT hold the token — it
    does NOT defend against a party that relays or observes the link (that party
    holds the token and could re-sign). The `iat`/`ttl` LINK expiry + the
    single-use `nonce` are the real, enforced freshness/replay guarantees the
    joiner applies; true relay-resistance (signing with the leader's node-link
    identity key) is a future hardening."""
    if a2a is None:
        return rooms.make_invite_link(room_id, node, token)
    try:
        cfg = a2a.load_config()
    except Exception:  # noqa: BLE001 - single-node has no config
        return rooms.make_invite_link(room_id, node, token)
    reach = _leader_reach_from_cfg(cfg)
    if not reach["address"]:
        # No reachable address to advertise → keep the legacy unsigned link
        # (Tailscale node_id/MagicDNS resolvable peers do not need reach=).
        return rooms.make_invite_link(room_id, node, token)
    leader_bridge = str(cfg.get("bridge_id", "") or "").strip() or node
    issued_ts = a2a.now_ts()
    # A real, enforced LINK TTL (SK-1): a stale/leaked signed link stops working
    # after this window even while the underlying token is still server-valid.
    ttl = (rooms.DEFAULT_SIGNED_INVITE_LINK_TTL_SECONDS
           if link_ttl is None else max(0, int(link_ttl)))
    nonce = a2a.new_message_id(leader_bridge).split(":", 1)[-1]
    token_sha = rooms.hash_token(token)
    reach_param = f"{reach['kind']}:{reach['address']}:{reach['port']}"
    canonical = a2a.invite_canonical(
        version=_INVITE_LINK_VERSION, room_id=room_id, leader_node=node,
        leader_bridge=leader_bridge, reach=reach, token_sha256=token_sha,
        issued_ts=issued_ts, ttl=ttl, nonce=nonce)
    sig = a2a.sign_invite_canonical(token, canonical)
    signed = {
        "v": _INVITE_LINK_VERSION,
        "lb": leader_bridge,
        "reach": reach_param,
        "iat": str(issued_ts),
        "ttl": str(ttl),
        "nonce": nonce,
        "s": sig,
    }
    return rooms.make_invite_link(room_id, node, token, signed=signed)


def _verify_and_extract_reach(parsed: dict[str, str], token: str
                              ) -> Optional[dict[str, Any]]:
    """Joiner-side: verify a v2 signed invite's token-bound canonical and return
    {"reach": {kind,address,port}, "nonce": <str>} for the caller to act on (the
    caller records the nonce for single-use replay rejection). Returns None for a
    legacy/unsigned link (no `s=`).

    RAISES rooms.RoomsError (fail closed) on:
      - a malformed reach=/iat/ttl,
      - a SIGNATURE MISMATCH (the canonical was tampered with by a party that
        does NOT hold the token, or the link was forged),
      - an EXPIRED link (`iat + ttl < now`) — a real, enforced freshness gate.

    Integrity scope (SK-1, honest): the signature key is derived from the raw
    token carried in the SAME link, so verification proves integrity ONLY
    against a blind on-path tamperer who lacks the token. A relayer/observer who
    holds the token could re-sign a tampered reach=, so this is NOT relay-
    resistance. The enforced LINK TTL + single-use nonce (recorded by the caller)
    are the concrete guarantees; admission is unaffected either way (the leader
    re-runs token TTL/revocation + client_ip==registered-addr + per-pair HMAC +
    leader approval regardless of reach=)."""
    if a2a is None or not parsed.get("s"):
        return None
    reach_param = parsed.get("reach", "")
    # reach_param == "<kind>:<address>:<port>". Split from the RIGHT so an IPv6
    # address (which contains ':') survives — split off port, then kind.
    kind, address, port = "", "", 0
    if reach_param:
        try:
            head, port_s = reach_param.rsplit(":", 1)
            kind, address = head.split(":", 1)
            port = int(port_s)
        except (ValueError, IndexError):
            raise rooms.RoomsError(
                "invite link reach= is malformed", code="bad_invite_reach")
    reach = {"kind": kind, "address": address, "port": port}
    nonce = parsed.get("nonce", "")
    try:
        issued_ts = int(parsed.get("iat", "0") or "0")
        ttl = int(parsed.get("ttl", "0") or "0")
    except ValueError:
        raise rooms.RoomsError("invite link iat/ttl malformed",
                               code="bad_invite_link")
    canonical = a2a.invite_canonical(
        version=parsed.get("v", _INVITE_LINK_VERSION),
        room_id=parsed.get("room", ""), leader_node=parsed.get("leader", ""),
        leader_bridge=parsed.get("lb", ""), reach=reach,
        token_sha256=rooms.hash_token(token), issued_ts=issued_ts, ttl=ttl,
        nonce=nonce)
    if not a2a.verify_invite_canonical(token, canonical, parsed.get("s", "")):
        raise rooms.RoomsError(
            "invite link signature verification failed — the reach=/identity "
            "locator was tampered with or the link was forged (refusing first "
            "contact)", code="invite_sig_mismatch")
    # Enforce the signed LINK TTL (SK-1): a real expiry, not a decorative field.
    if ttl > 0 and issued_ts + ttl < a2a.now_ts():
        raise rooms.RoomsError(
            "invite link has expired — ask the leader to re-issue it with "
            "`agb room invite`", code="invite_expired")
    return {"reach": reach, "nonce": nonce}


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_create(args: argparse.Namespace) -> int:
    # #1517: on a fresh iso host the canonical rooms.db does not exist yet, so
    # the controller anchor (`_controller_uid` = stat(rooms.db).st_uid) has
    # nothing to anchor to and even the genuine controller's first `create`
    # would resolve to ACTOR_UNRESOLVED. Controller-only auto-bootstrap seeds
    # the canonical controller-owned db FIRST (no-op if it already exists or if
    # the caller is not the proven controller of the canonical location), so the
    # actor resolution below anchors to it. A managed iso agent does NOT own the
    # canonical state dir → bootstrap is refused → it STILL fails closed (the
    # P1b invariant is preserved). The bootstrap never honors a caller-redirected
    # BRIDGE_A2A_ROOMS_DB (canonical path only).
    rooms.maybe_bootstrap_rooms_db()
    node = local_node()
    leader = caller_agent(args)
    token = rooms.mint_invite_token()
    ttl = max(0, int(getattr(args, "ttl", 0) or 0))
    conn = rooms.open_rooms()
    try:
        room_id = rooms.create_room(
            conn, name=args.name or "", leader_agent=leader,
            leader_node=node, token=token, once=False, ttl=ttl,
        )
    finally:
        conn.close()
    link = _make_invite_link_for(node, token, room_id)
    if args.json:
        out(json.dumps({
            "room_id": room_id, "name": args.name or "",
            "leader": f"{leader}@{node}", "epoch": 0, "invite_link": link,
        }))
    else:
        info(f"created room {room_id} (leader {leader}@{node}, epoch 0)")
        out("Invite link (shown ONCE — store it now, only its hash is kept):")
        out(link)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    conn = rooms.open_rooms_readonly()
    if conn is None:
        if args.json:
            out("[]")
        else:
            info("no rooms defined")
        return 0
    try:
        owned = local_node() if args.owned else None
        rows = rooms.list_rooms(conn, owned_node=owned)
        led_ids = {r["room_id"] for r in rows}
        items = [
            {
                "room_id": r["room_id"], "name": r["name"],
                "leader": f"{r['leader_agent']}@{r['leader_node']}",
                "epoch": int(r["epoch"]), "status": r["status"],
                "role": "leader", "source": "rooms",
            }
            for r in rows
        ]
        # Member-side fallback (P4.5): include rooms this node JOINED but does
        # not LEAD. They have a `room_roster_cache` row (the applied leader-MAC
        # roster) but no `rooms` row, so `list_rooms` misses them. `--owned`
        # asks specifically for led rooms, so the cache is excluded there.
        if not args.owned:
            for cr in rooms.list_roster_cache(conn):
                rid = str(cr["room_id"])
                if rid in led_ids:
                    continue
                items.append({
                    "room_id": rid, "name": None,
                    "leader": rooms.cached_leader(cr),
                    "epoch": int(cr["epoch"]), "status": None,
                    "role": "member", "source": "roster-cache",
                })
    finally:
        conn.close()
    if args.json:
        out(json.dumps(items))
        return 0
    if not items:
        info("no rooms" + (" owned by this node" if args.owned else ""))
        return 0
    for it in items:
        if it["source"] == "roster-cache":
            out(f"{it['room_id']}  epoch={it['epoch']}  leader={it['leader']}  "
                f"role=member (cached)")
        else:
            out(f"{it['room_id']}  epoch={it['epoch']}  leader={it['leader']}  "
                f"name={it['name']!r}  status={it['status']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    conn = rooms.open_rooms_readonly()
    if conn is None:
        return die(f"no rooms defined (room {args.room_id} not found)",
                   code=1)
    try:
        room = rooms.get_room(conn, args.room_id)
        if room is None:
            # Member-side fallback (P4.5): this node does not LEAD the room, but
            # may have JOINED it — in which case `room_roster_cache` holds the
            # applied leader-MAC roster (the same cache `room talk` reads). Show
            # that cached view read-only, clearly marked role=member /
            # source=roster-cache, rather than the misleading "not found".
            cache_row = rooms.get_roster_cache(conn, args.room_id)
            if cache_row is None:
                return die(f"room not found: {args.room_id}", code=1)
            return _show_cached_room(args, cache_row)
        roster = rooms.roster_for(conn, args.room_id)
        pending = [
            {"agent": r["agent"], "node": r["node"], "status": r["status"]}
            for r in rooms.list_join_requests(conn, args.room_id,
                                              status=rooms.JOIN_PENDING)
        ]
    finally:
        conn.close()
    payload = {
        "room_id": roster["room_id"],
        "name": room["name"],
        "leader": f"{room['leader_agent']}@{room['leader_node']}",
        "epoch": roster["epoch"],
        "status": room["status"],
        "members": roster["members"],
        "pending_join_requests": pending,
        "role": "leader",
        "source": "rooms",
    }
    if args.json:
        out(json.dumps(payload))
        return 0
    info(f"room {payload['room_id']} (epoch {payload['epoch']}, "
         f"leader {payload['leader']})")
    out("members:")
    for m in payload["members"]:
        out(f"  - {m['agent']}@{m['node']} ({m['role']})")
    if pending:
        out("pending join requests:")
        for p in pending:
            out(f"  - {p['agent']}@{p['node']}")
    return 0


def _show_cached_room(args: argparse.Namespace,
                      cache_row: Any) -> int:
    """Render a member-side cached room view (P4.5) read-only.

    The cache holds what the leader broadcast and this node verified+applied:
    members (with role), epoch, and the leader node. It does NOT hold leader-only
    fields (room name, status, the live pending-join queue) — those live only in
    the leader's `rooms`/`room_join_requests` tables — so we surface ONLY what
    the cache actually contains and never fabricate the rest.
    """
    members = rooms.cached_roster_members(cache_row)
    if members is None:
        return die(f"local roster cache for room {args.room_id} is corrupt",
                   code=1)
    payload = {
        "room_id": str(cache_row["room_id"]),
        "leader": rooms.cached_leader(cache_row),
        "epoch": int(cache_row["epoch"]),
        "members": members,
        "role": "member",
        "source": "roster-cache",
    }
    if args.json:
        out(json.dumps(payload))
        return 0
    info(f"room {payload['room_id']} (epoch {payload['epoch']}, "
         f"leader {payload['leader']}) [member-side cached view]")
    out("members:")
    for m in payload["members"]:
        out(f"  - {m['agent']}@{m['node']} ({m['role']})")
    return 0


def _require_leader_conn(conn: Any, room_id: str,
                         args: argparse.Namespace) -> Any:
    """Load a room + enforce leader-auth via the trusted OS actor (§14 R1).

    Leader-auth is derived from the PROCESS OS identity, NOT from `--as`/env —
    so a managed iso agent cannot pass `--as <leader>` to satisfy it. See
    require_leader_actor for the per-regime contract.
    """
    room = rooms.require_room(conn, room_id)
    require_leader_actor(args, room)
    return room


def cmd_invite(args: argparse.Namespace) -> int:
    node = local_node()
    ttl = max(0, int(getattr(args, "ttl", 0) or 0))
    conn = rooms.open_rooms()
    try:
        _require_leader_conn(conn, args.room_id, args)
        token = rooms.mint_invite_token()
        rooms.set_invite_token(conn, args.room_id, token, once=args.once, ttl=ttl)
    finally:
        conn.close()
    link = _make_invite_link_for(node, token, args.room_id)
    if args.json:
        out(json.dumps({"room_id": args.room_id, "invite_link": link,
                        "once": bool(args.once)}))
    else:
        kind = "single-use" if args.once else "reusable"
        info(f"minted {kind} invite for {args.room_id} "
             "(old token invalidated)")
        out(link)
    return 0


def cmd_rotate_invite(args: argparse.Namespace) -> int:
    # rotate-invite is `invite` without --once (always reusable rotation).
    args.once = False
    return cmd_invite(args)


def _have_leader_peer(leader_node: str) -> bool:
    """True iff the local A2A config already has a node-link peer for the leader
    (i.e. this is a re-join by an already-paired peer, NOT a first contact). Used
    to gate the signed-invite reach=/freshness checks to the bootstrap path."""
    if a2a is None or not leader_node:
        return False
    try:
        cfg = a2a.load_config()
        a2a.find_peer(cfg, leader_node)
        return True
    except Exception:  # noqa: BLE001 - missing config / unknown peer → not paired
        return False


def _joiner_bootstrap_leader_peer(
    cfg: dict[str, Any], *, leader_node: str, room_id: str, token: str,
    bootstrap_reach: Optional[dict[str, Any]], local_bridge_id: str,
) -> dict[str, Any]:
    """Self-register a local node-link peer for the leader so a first-contact
    join can sign with the DERIVED per-pair key (Lane 4 zero-touch join).

    The peer `secret` is `room_pair_key_from_token(raw_token, room, leader,
    joiner=local_bridge_id)` — the SAME key the leader derives from the stored
    seed. The `address` is the reach= address from the signed canonical (SK-1
    honesty: that signature catches a BLIND tamperer + an EXPIRED/replayed link,
    but is token-keyed so it is NOT relay-resistance; either way a forged reach=
    only redirects first-contact TRANSPORT, never admission — the leader re-runs
    token-TTL/revocation + client_ip==registered-addr + per-pair HMAC + approval).
    Writes atomically under the same TOCTOU lock the receiver uses, then updates
    the live in-mem cfg so the immediate send resolves the peer. RAISES
    rooms.RoomsError when there is no reach to bootstrap from.
    """
    if not bootstrap_reach or not bootstrap_reach.get("address"):
        raise rooms.RoomsError(
            f"no local node-link to leader {leader_node!r} and the invite link "
            "carries no signed reach= locator to bootstrap one — re-issue the "
            "invite with `agb room invite` from a node that has a reachable "
            "listen address", code="no_leader_peer_no_reach")
    pair_key = a2a.room_pair_key_from_token(
        token, room_id=room_id, leader_node=leader_node,
        joiner_node=local_bridge_id)
    address = str(bootstrap_reach.get("address", "")).strip()
    try:
        port = int(bootstrap_reach.get("port", 0) or 0)
    except (TypeError, ValueError):
        port = 0
    try:
        transport = a2a.transport_kind(cfg)
    except a2a.A2AError:
        transport = ""
    changed, code = a2a.auto_register_room_peer_locked(
        None, peer_id=leader_node, address=address, port=port,
        secret=pair_key, inbound_allowlist=[], transport=transport)
    if code == "peer_conflict":
        raise rooms.RoomsError(
            f"a local peer {leader_node!r} already exists with a different "
            "secret — refusing to overwrite it (rotate/clear it first)",
            code="leader_peer_conflict")
    if not changed and code not in ("noop",):
        raise rooms.RoomsError(
            f"could not bootstrap a local node-link to {leader_node!r}: {code}",
            code="bootstrap_register_failed")
    peer_entry: dict[str, Any] = {
        "id": leader_node, "address": address, "secret": pair_key,
        "inbound_allowlist": [],
    }
    if port:
        peer_entry["port"] = port
    peers = cfg.setdefault("peers", [])
    if isinstance(peers, list):
        replaced = False
        for i, p in enumerate(peers):
            if isinstance(p, dict) and p.get("id") == leader_node:
                peers[i] = peer_entry
                replaced = True
                break
        if not replaced:
            peers.append(peer_entry)
    return peer_entry


def _post_room_join_request(*, leader_node: str, room_id: str, token: str,
                            joiner_agent: str, timeout: float = 30.0,
                            bootstrap_reach: Optional[dict[str, Any]] = None,
                            ) -> tuple[int, bytes]:
    """POST a signed cross-node room-join-request to the leader's node (P4.1).

    The leader's node id (`leader_node`) names the A2A peer to deliver to. We
    resolve that peer from the local A2A config, sign the body with the node-link
    HMAC secret, and POST to the leader's `room_join_path`. The wire carries
    sha256(token) ONLY (hash_token) — the raw token never leaves this process.
    `joiner_agent` is the OS-actor-anchored agent id (resolved by the CALLER via
    caller_agent / resolve_os_actor) — NEVER a --from/env value. Returns
    (http_status, response_body).

    Lane 4 (#1695): when there is NO local node-link to the leader yet AND a
    VERIFIED `bootstrap_reach` (the token-signed reach= locator) is supplied, the
    joiner self-bootstraps a local leader peer entry under a TOCTOU lock — its
    `secret` is the per-pair key DERIVED from the raw token (HKDF, the SAME key
    the leader derives from the stored seed), its `address` is the verified
    reach= address (never an out-of-band hand-carried IP). The join request then
    signs with that derived key; the leader's receiver derives the matching key
    and the HMAC check passes. This is the zero-touch first-contact path.

    A test seam (BRIDGE_ROOMS_TEST_POST_HOOK, gated by the paired
    BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1 + BRIDGE_A2A_ALLOW_TEST_BIND=1 flags) lets
    the smoke capture the signed request + stub the transport so no real
    Tailscale / live receiver is needed. It is NEVER honored in production (the
    paired flags are unset there).
    """
    if a2a is None:  # pragma: no cover - a2a always ships beside this
        raise rooms.RoomsError(
            "cross-node join requires the A2A module + node-link config",
            code="a2a_unavailable",
        )
    cfg = a2a.load_config()
    local_bridge_id = str(cfg.get("bridge_id", "") or "").strip()
    if not local_bridge_id:
        raise rooms.RoomsError(
            "config has no 'bridge_id' — cannot identify this node for a "
            "cross-node join", code="no_bridge_id",
        )
    try:
        peer = a2a.find_peer(cfg, leader_node)
    except a2a.A2AError:
        # No local node-link to the leader yet — self-bootstrap one from the
        # token-signed reach= locator (Lane 4 zero-touch first contact).
        peer = _joiner_bootstrap_leader_peer(
            cfg, leader_node=leader_node, room_id=room_id, token=token,
            bootstrap_reach=bootstrap_reach, local_bridge_id=local_bridge_id)
    secret = a2a.peer_send_secret(peer)
    token_hash = rooms.hash_token(token)
    body = a2a.build_room_join_request(
        room_id=room_id, join_token_sha256=token_hash, joiner_agent=joiner_agent,
    )
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    message_id = a2a.new_message_id(local_bridge_id)
    path = peer.get("room_join_path", a2a.ROOM_JOIN_PATH)
    timestamp = str(a2a.now_ts())
    body_hash = a2a.body_sha256(body_bytes)
    canonical = a2a.canonical_string(
        "POST", path, local_bridge_id, message_id, timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    headers = {
        "Content-Type": "application/json",
        "X-AGB-Protocol": a2a.ROOM_JOIN_PROTOCOL_VERSION,
        "X-AGB-Peer": local_bridge_id,
        "X-AGB-Message-Id": message_id,
        "X-AGB-Timestamp": timestamp,
        "X-AGB-Body-SHA256": body_hash,
        "X-AGB-Signature": signature,
    }

    # Test seam: capture the fully-signed request + return a stubbed response,
    # so the smoke exercises the real sender (signing, OS-actor joiner id, hash-
    # only body) against the real receiver WITHOUT a live socket / Tailscale.
    if _test_post_hook_allowed():
        return _invoke_test_post_hook(path=path, headers=headers,
                                      body_bytes=body_bytes)

    # Transport-aware target resolution (#1595): Tailscale identity
    # live-resolve or WARP-Mesh raw device IP. Back-compat for legacy
    # raw-IP configs is preserved (literal `address` returned verbatim).
    address = a2a.resolve_peer_address_for_transport(
        a2a.transport_kind(cfg), peer)
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    if not address:
        raise rooms.RoomsError(
            f"leader node {leader_node!r} has no resolvable address",
            code="no_leader_address",
        )
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


def _test_post_hook_allowed() -> bool:
    """Paired-flag gate for the cross-node POST test seam (prod-inert)."""
    # noqa markers: these are plain env-VAR reads (test-seam gating), NOT
    # isolated `.env` FILE access — the iso-helper-ratchet pattern matches the
    # `.env` substring inside `os.environ`, a false positive here.
    return (os.environ.get("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and bool(os.environ.get("BRIDGE_ROOMS_TEST_POST_HOOK")))  # noqa: iso-helper-boundary - env var, not a .env file


def _invoke_test_post_hook(*, path: str, headers: dict,
                           body_bytes: bytes) -> tuple[int, bytes]:
    """Write the signed request to the hook file + return a stubbed 200.

    The hook value is a file path the smoke reads to assert on the signed
    request (it can then replay it against the real receiver handler). Returns a
    synthetic 200 so the CLI reports the pending post as sent.
    """
    import subprocess

    hook = os.environ["BRIDGE_ROOMS_TEST_POST_HOOK"]  # noqa: iso-helper-boundary - env var, not a .env file
    payload = {
        "path": path, "headers": headers,
        "body": body_bytes.decode("utf-8"),
    }
    # The hook is a script invoked with the JSON payload on argv (file-as-argv,
    # never stdin — footgun #11 hygiene). Its stdout (if any) is the stubbed
    # response body; a non-zero exit surfaces as a 503 to the caller.
    try:
        proc = subprocess.run(
            [hook, json.dumps(payload)], capture_output=True, text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise rooms.RoomsError(f"test post hook failed: {exc}",
                               code="test_hook_error")
    if proc.returncode != 0:
        return 503, (proc.stderr or "test hook non-zero").encode("utf-8")
    return 200, (proc.stdout or "").encode("utf-8")


def _test_local_hook_allowed() -> bool:
    """Paired-flag gate for the LOCAL-queue fan-out test seam (prod-inert).

    Mirrors `_test_post_hook_allowed` for the same-node local leg (#1594): the
    smoke captures the would-be `bridge-task.sh create` invocation instead of
    shelling out to a live queue. Same paired insecure-test flags so it can
    NEVER fire in production.
    """
    return (os.environ.get("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and os.environ.get("BRIDGE_A2A_ALLOW_TEST_BIND") == "1"  # noqa: iso-helper-boundary - env var, not a .env file
            and bool(os.environ.get("BRIDGE_ROOMS_TEST_LOCAL_HOOK")))  # noqa: iso-helper-boundary - env var, not a .env file


def _invoke_test_local_hook(*, target_agent: str, sender_agent: str,
                            sender_node: str, room_id: str, room_epoch: int,
                            title: str, priority: str,
                            body: str) -> tuple[bool, str]:
    """Write the would-be local-queue create to the hook file; return ok.

    The hook value is a script invoked with a JSON payload on argv (file-as-argv,
    never stdin — footgun #11 hygiene). A non-zero exit is reported as a local
    delivery failure so the smoke can exercise the partial-failure path.
    """
    import subprocess

    hook = os.environ["BRIDGE_ROOMS_TEST_LOCAL_HOOK"]  # noqa: iso-helper-boundary - env var, not a .env file
    payload = {
        "target_agent": target_agent, "from": f"room:{room_id}:{sender_agent}",
        "sender": f"{sender_agent}@{sender_node}", "room_id": room_id,
        "room_epoch": int(room_epoch), "title": title, "priority": priority,
        "body": body,
    }
    try:
        proc = subprocess.run(
            [hook, json.dumps(payload)], capture_output=True, text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"test local hook failed: {exc}"
    if proc.returncode != 0:
        return False, (proc.stderr or proc.stdout or "test local hook "
                       "non-zero").strip()[-300:]
    return True, (proc.stdout or "").strip()


def _post_room_roster_broadcast(*, member_node: str, room_id: str,
                                room_epoch: int, members: list,
                                leader_node: str, timeout: float = 30.0,
                                ) -> tuple[int, bytes]:
    """POST the leader-signed roster broadcast to ONE member node (P4.2).

    `member_node` names the A2A peer to deliver to; the body is signed with the
    leader-node↔member-node PAIRWISE node-link HMAC (the existing per-peer
    secret), so the member can verify the roster came from the leader and a
    member that lacks the leader↔Z secret cannot forge a roster node Z accepts
    (§14 R2). `members` MUST be the canonical sorted roster. `leader_node` is the
    local node (this leader's node id). Returns (http_status, response_body).

    Delegates to the SHARED `rooms.send_roster_broadcast` (Lane 5) so the CLI
    immediate send and the reconcile heartbeat re-broadcast use ONE signing path
    (the canonical string / signature / protocol tag never diverge). That shared
    sender reuses the SAME paired-flag test seam (BRIDGE_ROOMS_TEST_POST_HOOK) —
    the hook captures the signed request; the smoke replays it through the real
    member-side receiver handler. NEVER honored in production.
    """
    if a2a is None:  # pragma: no cover - a2a always ships beside this
        raise rooms.RoomsError(
            "roster broadcast requires the A2A module + node-link config",
            code="a2a_unavailable",
        )
    cfg = a2a.load_config()
    return rooms.send_roster_broadcast(
        cfg, member_node=member_node, room_id=room_id, room_epoch=room_epoch,
        members=members, leader_node=leader_node, timeout=timeout)


# --------------------------------------------------------------------------
# Lane 5 (#1695-P2 gotcha F): shared membership-change broadcast (durable)
# --------------------------------------------------------------------------

def _send_one_roster_broadcast(member_node: str, room_id: str, roster: dict,
                               leader_node: str) -> tuple[bool, str]:
    """Deliver ONE leader-signed roster broadcast to one member node.

    Returns (ok, detail). `ok` is True only on a 2xx ack. Used by both the
    immediate CLI send and the reconcile heartbeat re-broadcast so the signing /
    error handling stays identical on every leg. NEVER raises — a transport /
    config error becomes (False, "<short non-secret reason>").
    """
    try:
        status, _resp = _post_room_roster_broadcast(
            member_node=member_node, room_id=room_id,
            room_epoch=int(roster["epoch"]), members=roster["members"],
            leader_node=leader_node,
        )
    except rooms.RoomsError as exc:
        return False, str(exc)[:200]
    except Exception as exc:  # noqa: BLE001 - transport/config failure
        return False, f"broadcast failed: {exc}"[:200]
    if 200 <= status < 300:
        return True, f"status={status}"
    return False, f"status={status}"


def _broadcast_membership_change(conn, room_id: str, epoch: int,
                                 leader_node: str,
                                 removed_node: str = "") -> dict:
    """The SINGLE membership-change → roster-broadcast path (approve/kick/leave/deny).

    Generalizes the prior approve-only best-effort broadcast (gotcha F). The
    leader's rooms.db is already mutated + epoch-bumped (the caller did that and
    holds `conn`). This function:
      1. ENQUEUES a DURABLE convergence target per remote member node
         (`enqueue_roster_broadcast`) so a member offline NOW still converges
         later via the reconcile heartbeat (no fire-and-forget).
      2. Attempts an IMMEDIATE best-effort delivery to each pending target; a
         2xx ack clears the durable row, a failure leaves it pending (the
         heartbeat retries it, bounded by the reconcile backoff gate).

    `removed_node` (codex P2): on a kick/leave the just-removed node is no longer
    a member, so it would never receive the roster that drops it — pass it here so
    it ALSO gets a one-shot convergence target and locally drops the room.

    The roster body is rebuilt from the leader's AUTHORITATIVE rooms.db
    (`roster_for`) — membership is never a body claim; epoch is the just-bumped
    monotonic value. Returns {delivered:[...], failed:[{node, ...}], queued:[...]}
    so the CLI can report partial outcomes. A delivery failure is NEVER fatal to
    the already-committed local membership change.
    """
    # Snapshot the authoritative roster (post-change) for the body we sign.
    roster = rooms.roster_for(conn, room_id)
    # Durably record every remote member node that must converge to this epoch,
    # plus the just-removed node (so a kicked/left node drops the room).
    extra = [removed_node] if removed_node else None
    queued = rooms.enqueue_roster_broadcast(conn, room_id, epoch, leader_node,
                                            extra_nodes=extra)
    delivered: list = []
    failed: list = []
    # Immediate best-effort send to each pending target (the heartbeat covers
    # any that fail now). Read the pending set back from the durable outbox so a
    # row whose epoch a concurrent change raised is sent at the CURRENT roster.
    for row in rooms.pending_roster_outbox(conn, room_id):
        mnode = str(row["member_node"])
        ok, detail = _send_one_roster_broadcast(mnode, room_id, roster, leader_node)
        if ok:
            rooms.mark_roster_outbox_done(conn, room_id, mnode, int(roster["epoch"]))
            delivered.append(mnode)
        else:
            rooms.record_roster_outbox_failure(conn, room_id, mnode, detail)
            failed.append({"node": mnode, "error": detail})
    return {"delivered": delivered, "failed": failed, "queued": queued}


# --------------------------------------------------------------------------
# room talk — room-scoped cross-node member messaging (A2A Rooms P4.3, §11)
# --------------------------------------------------------------------------

def _post_room_talk(*, member_node: str, room_id: str, room_epoch: int,
                    sender_agent: str, target_agent: str, title: str,
                    body: str, priority: str, timeout: float = 30.0,
                    ) -> tuple[int, bytes]:
    """POST a ROOM-SCOPED A2A enqueue message to ONE other member node (P4.3).

    Routes over the EXISTING `/enqueue` A2A path (NOT a new endpoint) so the
    receiver's full auth preamble + durable dedupe run unchanged; the room-scope
    is carried in the envelope (`room_id` + `room_epoch`), and the receiver's
    fail-closed `room_scoped_check` (the P4.3 leader-MAC roster-cache gate)
    decides delivery. The body is signed with the SAME per-peer node-link HMAC
    secret every other A2A send uses — membership is NOT asserted on the wire,
    it is proven by the receiver against its OWN cached leader-MAC roster.

    `sender_agent` is the OS-actor-anchored agent id (the CALLER resolved it via
    `caller_agent`/`resolve_os_actor`) — NEVER a `--from`/env value. `room_epoch`
    is the sender's LOCALLY-cached epoch for the room (the caller read it from
    its own `room_roster_cache`); a hostile epoch cannot be conjured because the
    receiver requires it to EQUAL its own cached epoch. Returns
    (http_status, response_body).

    Reuses the SAME paired-flag test seam (BRIDGE_ROOMS_TEST_POST_HOOK) the join
    / roster-broadcast senders use — the hook captures the signed request; the
    smoke replays it through the real receiver. NEVER honored in production.
    """
    if a2a is None:  # pragma: no cover - a2a always ships beside this
        raise rooms.RoomsError(
            "room talk requires the A2A module + node-link config",
            code="a2a_unavailable",
        )
    cfg = a2a.load_config()
    local_bridge_id = str(cfg.get("bridge_id", "") or "").strip()
    if not local_bridge_id:
        raise rooms.RoomsError(
            "config has no 'bridge_id' — cannot identify this node for a "
            "room-scoped send", code="no_bridge_id",
        )
    peer = a2a.find_peer(cfg, member_node)
    secret = a2a.peer_send_secret(peer)
    message_id = a2a.new_message_id(local_bridge_id)
    envelope = a2a.build_envelope(
        message_id=message_id,
        sender_bridge=local_bridge_id,
        sender_agent=sender_agent,
        target_agent=target_agent,
        priority=priority,
        title=title,
        body=body,
        reply_peer=local_bridge_id,
        reply_agent=sender_agent,
        room_id=room_id,
        room_epoch=int(room_epoch),
    )
    body_bytes = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    path = peer.get("enqueue_path",
                    cfg.get("listen", {}).get("enqueue_path", "/enqueue"))
    timestamp = str(a2a.now_ts())
    body_hash = a2a.body_sha256(body_bytes)
    canonical = a2a.canonical_string(
        "POST", path, local_bridge_id, message_id, timestamp, body_hash)
    signature = a2a.sign(secret, canonical)
    headers = {
        "Content-Type": "application/json",
        "X-AGB-Protocol": a2a.PROTOCOL_VERSION,
        "X-AGB-Peer": local_bridge_id,
        "X-AGB-Message-Id": message_id,
        "X-AGB-Timestamp": timestamp,
        "X-AGB-Body-SHA256": body_hash,
        "X-AGB-Signature": signature,
    }

    if _test_post_hook_allowed():
        return _invoke_test_post_hook(path=path, headers=headers,
                                      body_bytes=body_bytes)

    # Transport-aware target resolution (#1595): Tailscale identity
    # live-resolve or WARP-Mesh raw device IP. Back-compat for legacy
    # raw-IP configs is preserved (literal `address` returned verbatim).
    address = a2a.resolve_peer_address_for_transport(
        a2a.transport_kind(cfg), peer)
    port = int(peer.get("port", cfg.get("listen", {}).get("port", 8787)))
    if not address:
        raise rooms.RoomsError(
            f"member node {member_node!r} has no resolvable address",
            code="no_member_address",
        )
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


def _talk_target_pairs(members: list, sender_agent: str,
                       sender_node: str, local_node_id: str,
                       only_to: str = "") -> list:
    """The (agent, node) pairs a room-talk send targets, from the CACHED roster.

    Every cached member EXCEPT the sender itself, on a node that is NOT this
    sender's own node (a same-node member is reachable through the local queue,
    not a node-link hop — P4.3 is cross-node messaging). `only_to`
    (`agent` or `agent@node`) narrows to a single recipient. Deterministically
    ordered for reproducible sends.
    """
    want_agent, _, want_node = (only_to or "").partition("@")
    want_agent = want_agent.strip()
    want_node = want_node.strip()
    pairs: list = []
    for m in members:
        magent = str(m.get("agent", "") or "")
        mnode = str(m.get("node", "") or "")
        if magent == sender_agent and mnode == sender_node:
            continue  # never send to self
        if not mnode or mnode == local_node_id:
            continue  # same node → local queue, not a cross-node room-talk hop
        if only_to:
            if magent != want_agent:
                continue
            if want_node and mnode != want_node:
                continue
        pair = (magent, mnode)
        if pair not in pairs:
            pairs.append(pair)
    return sorted(pairs)


def _local_target_pairs(members: list, sender_agent: str,
                        sender_node: str, local_node_id: str,
                        only_to: str = "") -> list:
    """The SAME-NODE (agent, node) pairs a whole-room fan-out targets locally.

    The complement of `_talk_target_pairs`: every cached member on THIS sender's
    own node (or, when the node ids are empty as in single-node P1a, a member
    whose node matches the sender's empty node), EXCEPT the sender itself. These
    recipients are reachable through the LOCAL queue (`bridge-task.sh create`),
    not a cross-node node-link hop — so `a2a send --room` delivers to them via
    the same durable internal-queue boundary every inter-agent task uses, while
    `_talk_target_pairs` handles the remote leg. `only_to` (`agent`/`agent@node`)
    narrows to a single recipient. Deterministically ordered.

    The membership source is the SAME cached/authoritative roster the remote leg
    reads — a recipient is only addressed because it is already a proven member
    of this room, never because the caller named it.
    """
    want_agent, _, want_node = (only_to or "").partition("@")
    want_agent = want_agent.strip()
    want_node = want_node.strip()
    pairs: list = []
    for m in members:
        magent = str(m.get("agent", "") or "")
        mnode = str(m.get("node", "") or "")
        if magent == sender_agent and mnode == sender_node:
            continue  # never send to self
        if mnode and mnode != local_node_id:
            continue  # other node → remote room-talk hop, not the local queue
        if only_to:
            if magent != want_agent:
                continue
            if want_node and mnode != want_node and want_node != local_node_id:
                continue
        pair = (magent, mnode)
        if pair not in pairs:
            pairs.append(pair)
    return sorted(pairs)


def _post_room_local(*, target_agent: str, sender_agent: str, sender_node: str,
                     room_id: str, room_epoch: int, title: str, body: str,
                     priority: str, timeout: float = 120.0) -> tuple[bool, str]:
    """Deliver a room fan-out message to a SAME-NODE member via the local queue.

    Routes through the EXISTING `bridge-task.sh create` boundary (the same
    durable internal-queue path the A2A receiver uses for inbound mail, and the
    same one every inter-agent task takes) — NOT a new transport, and NOT a
    direct queue-db write. The `--from` is stamped as `room:<room_id>:<sender>`
    so the recipient (and the audit log) can see this arrived as a room fan-out,
    parallel to the receiver's `a2a:<bridge>:<agent>` provenance for remote mail.

    `sender_agent` is the OS-actor-anchored caller (the fan-out already proved it
    is a member of `room_id` before calling here); the local target was selected
    from the SAME proven roster. The room epoch is carried in the provenance
    header for the recipient's context — local delivery does not need the wire
    room-scoped gate because there is no untrusted network hop: the internal
    queue is already the controller-owned, in-host boundary, and the membership
    was proven locally. Returns (ok, detail).
    """
    if _test_local_hook_allowed():
        return _invoke_test_local_hook(
            target_agent=target_agent, sender_agent=sender_agent,
            sender_node=sender_node, room_id=room_id, room_epoch=room_epoch,
            title=title, priority=priority, body=body)

    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "bridge-task.sh")
    if not os.path.isfile(script):
        return False, f"bridge-task.sh not found beside {here}"
    bash = os.environ.get("BRIDGE_BASH_BIN", "bash")  # noqa: iso-helper-boundary - os.environ read, not a .env file
    provenance = (
        "<!-- A2A room fan-out — provenance -->\n"
        f"room id   : {room_id}\n"
        f"room epoch: {int(room_epoch)}\n"
        f"from      : {sender_agent}@{sender_node}\n"
        "\n---\n\n"
    )
    full_body = provenance + body
    import subprocess
    import tempfile

    # Stage the body to a temp file so a multi-line / large body crosses the
    # bridge-task.sh boundary intact (mirrors the receiver's --body-file path).
    fd, body_path = tempfile.mkstemp(prefix="room-fanout-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(full_body)
        argv = [
            bash, script, "create",
            "--to", target_agent,
            "--from", f"room:{room_id}:{sender_agent}",
            "--priority", priority,
            "--title", title,
            "--body-file", body_path,
        ]
        try:
            proc = subprocess.run(
                argv, capture_output=True, text=True, timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return False, f"bridge-task.sh invocation failed: {exc}"
    finally:
        try:
            os.unlink(body_path)  # noqa: raw-pathlib-controller-only - our own mkstemp temp, not an iso-metadata path
        except OSError:
            pass
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[-300:]
        return False, detail or f"bridge-task.sh exited {proc.returncode}"
    return True, (proc.stdout or "").strip()


def cmd_talk(args: argparse.Namespace) -> int:
    """Send a ROOM-SCOPED message to the room's OTHER member nodes (P4.3).

    The sender identity is the OS-actor-anchored trusted agent (NEVER
    --from/env). The send stamps the room_id + the sender's LOCALLY-cached epoch
    and routes a room-scoped A2A enqueue to each other member node over the
    node-link. Membership is enforced by the RECEIVER against its own leader-MAC
    roster cache — this command only sends to members the sender's OWN cache
    already knows, and refuses to send at all if the sender is not itself a
    cached member (fail-closed symmetry with the receiver gate).
    """
    room_id = args.room_id
    agent = caller_agent(args)
    node = local_node()

    # Resolve body from --body / --body-file / stdin.
    if args.body is not None and args.body_file is not None:
        return die("pass only one of --body / --body-file", code=1)
    if args.body_file is not None:
        body_src = args.body_file
        if not os.path.isfile(body_src):
            return die(f"--body-file not found: {body_src}", code=1)
        try:
            with open(body_src, encoding="utf-8") as fh:
                body_text = fh.read()
        except OSError as exc:
            return die(f"--body-file unreadable: {body_src}: {exc}", code=1)
    elif args.body is not None:
        body_text = args.body
    else:
        body_text = sys.stdin.read() if not sys.stdin.isatty() else ""

    if not args.title:
        return die("--title is required", code=1)
    if not body_text and not args.allow_empty_body:
        return die("body is empty; pass --body/--body-file or "
                   "--allow-empty-body", code=1)
    priority = args.priority
    if a2a is not None and priority not in a2a.VALID_PRIORITIES:
        return die(f"invalid --priority: {priority}", code=1)

    # Read the sender's OWN locally-cached leader-MAC roster for this room. A
    # room-talk send is only meaningful once this node holds a verified roster
    # cache (from a P4.2 broadcast) — and the sender must itself be a cached
    # member, else there is nothing it is authorized to address.
    conn = rooms.open_rooms_readonly()
    if conn is None:
        return die(f"no local roster cache for room {room_id} — join the room "
                   "and wait for the leader's roster broadcast first", code=1)
    try:
        row = rooms.get_roster_cache(conn, room_id)
    finally:
        conn.close()
    if row is None:
        return die(f"no local roster cache for room {room_id} — join the room "
                   "and wait for the leader's roster broadcast first", code=1)
    cached_epoch = int(row["epoch"])
    members = rooms._cached_members(row)
    if members is None:
        return die(f"local roster cache for room {room_id} is corrupt", code=1)
    member_pairs = {(m["agent"], m["node"]) for m in members}
    if (agent, node) not in member_pairs:
        return die(f"{agent}@{node} is not a member of room {room_id} per the "
                   "local roster cache — refusing to send", code=1)

    only_to = getattr(args, "to", "") or ""
    fanout = bool(getattr(args, "fanout", False))
    remote_targets = _talk_target_pairs(members, agent, node, node,
                                        only_to=only_to)
    # The local (same-node) leg is the whole-room fan-out addition (#1594) and
    # fires ONLY under fan-out (`a2a send --room` / `room send` /
    # `room talk --fanout`). Bare `room talk` stays a strictly cross-node verb
    # (back-compat): it never touches the local queue, even with `--to` naming a
    # same-node member (that path keeps its prior "no cross-node recipients"
    # behavior). `--to` still narrows the fan-out's local leg to one member.
    local_targets = (
        _local_target_pairs(members, agent, node, node, only_to=only_to)
        if fanout else []
    )
    if not remote_targets and not local_targets:
        return die(f"no other members to send to in room {room_id} "
                   "(roster has no recipients matching the filter)", code=1)

    delivered: list = []
    failed: list = []
    used_remote = False
    used_local = False

    for tagent, tnode in remote_targets:
        used_remote = True
        try:
            status, resp = _post_room_talk(
                member_node=tnode, room_id=room_id, room_epoch=cached_epoch,
                sender_agent=agent, target_agent=tagent, title=args.title,
                body=body_text, priority=priority,
            )
        except rooms.RoomsError as exc:
            failed.append({"agent": tagent, "node": tnode, "leg": "remote",
                           "error": str(exc)})
            continue
        except Exception as exc:  # noqa: BLE001 - transport/config failure
            failed.append({"agent": tagent, "node": tnode, "leg": "remote",
                           "error": f"room talk failed: {exc}"})
            continue
        if 200 <= status < 300:
            delivered.append({"agent": tagent, "node": tnode, "leg": "remote"})
        else:
            detail = ""
            try:
                detail = resp.decode("utf-8", "replace")[:200]
            except Exception:  # noqa: BLE001
                detail = ""
            failed.append({"agent": tagent, "node": tnode, "leg": "remote",
                           "status": status, "detail": detail})

    for tagent, tnode in local_targets:
        used_local = True
        try:
            ok, detail = _post_room_local(
                target_agent=tagent, sender_agent=agent, sender_node=node,
                room_id=room_id, room_epoch=cached_epoch, title=args.title,
                body=body_text, priority=priority,
            )
        except Exception as exc:  # noqa: BLE001 - local enqueue failure
            failed.append({"agent": tagent, "node": tnode, "leg": "local",
                           "error": f"local enqueue failed: {exc}"})
            continue
        if ok:
            delivered.append({"agent": tagent, "node": tnode, "leg": "local"})
        else:
            failed.append({"agent": tagent, "node": tnode, "leg": "local",
                           "detail": detail})

    payload = {
        "room_id": room_id, "epoch": cached_epoch,
        "sender": f"{agent}@{node}",
        "from": f"{agent}@{node}",  # back-compat alias for the prior field name
        "delivered": delivered, "failed": failed,
        "legs": {"local": used_local, "remote": used_remote},
    }
    if args.json:
        out(json.dumps(payload))
    else:
        info(f"room send on {room_id} (epoch {cached_epoch}) from {agent}@{node}: "
             f"{len(delivered)} delivered, {len(failed)} failed "
             f"(local={used_local}, remote={used_remote})")
        for f in failed:
            info(f"  FAILED {f['agent']}@{f['node']} [{f.get('leg', '?')}]: "
                 f"{f.get('error') or f.get('detail') or f.get('status')}")
    # A partial failure is a non-zero exit so callers/cron notice, but a fully
    # delivered send (or an all-targets dry filter) returns 0.
    return 0 if not failed else 2


def cmd_join(args: argparse.Namespace) -> int:
    parsed = rooms.parse_invite_link(args.link)
    room_id = parsed.get("room", "")
    token = parsed.get("t", "")
    leader_node = parsed.get("leader", "")
    # THE joiner identity (contract 2): the OS-actor-anchored trusted agent
    # (resolve_os_actor / pwd.getpwuid), NEVER --from / BRIDGE_AGENT_ID / USER.
    # The SAME anchor single-node uses — so a hostile --from/env cannot change
    # the recorded joiner on either path.
    agent = caller_agent(args)
    node = local_node()
    if not token:
        return die("invite link carries no token (t=...) — a join needs "
                   "the token-bearing link, not a bare room id", code=1)

    # Cross-node (P4.1): the link names a leader node that is NOT this node.
    # Post the join-request to the leader's node over the node-link; the leader
    # verifies + persists the pending row (no local rooms.db write here — this
    # node is not the leader's node and has no authority over the room).
    if leader_node and leader_node != node:
        # Lane 4 (#1695): the signed-invite reach=/freshness gates apply ONLY to
        # a FIRST-CONTACT bootstrap (no local node-link to the leader yet). A
        # re-join by an already-paired peer takes the ordinary node-link and
        # neither needs the reach= nor is bound by the single-use nonce (it is not
        # a fresh first contact). Decide bootstrap-vs-known here.
        bootstrap_reach: Optional[dict[str, Any]] = None
        if not _have_leader_peer(leader_node):
            # Verify the v2 signed canonical FIRST and extract the reach= locator.
            # A tampered-by-blind-tamperer / forged / EXPIRED link raises here
            # (fail closed). `bootstrap_reach` lets `_post_room_join_request`
            # self-register a local node-link.
            try:
                verified = _verify_and_extract_reach(parsed, token)
            except rooms.RoomsError as exc:
                return die(str(exc), code=1)
            if verified is not None:
                bootstrap_reach = verified.get("reach")
                # SK-1 single-use guard: record the signed invite's per-issue
                # nonce so a REPLAYED signed link (re-sent later to drive a fresh
                # first-contact bootstrap) is rejected. Recorded in the joiner's
                # own rooms.db; orthogonal to the leader's server-side token TTL.
                nonce = str(verified.get("nonce") or "")
                if nonce:
                    try:
                        nconn = rooms.open_rooms()
                        try:
                            fresh = rooms.record_invite_nonce(
                                nconn, room_id, nonce)
                        finally:
                            nconn.close()
                    except rooms.RoomsError as exc:
                        return die(f"cannot record invite nonce: {exc}", code=1)
                    if not fresh:
                        return die(
                            "this signed invite link was already used on this "
                            "node (replay refused) — ask the leader to issue a "
                            "fresh invite with `agb room invite`", code=1)
        try:
            status, resp = _post_room_join_request(
                leader_node=leader_node, room_id=room_id, token=token,
                joiner_agent=agent, bootstrap_reach=bootstrap_reach,
            )
        except rooms.RoomsError as exc:
            return die(str(exc), code=1)
        except Exception as exc:  # noqa: BLE001 - transport/config failure
            return die(f"cross-node join failed: {exc}", code=1)
        if not (200 <= status < 300):
            detail = ""
            try:
                detail = resp.decode("utf-8", "replace")[:200]
            except Exception:  # noqa: BLE001
                detail = ""
            return die(f"leader node rejected the join (HTTP {status}): {detail}",
                       code=1)
        # P4.2 FIRST-ROSTER binding anchor: record the member's OWN outbound
        # join intent locally (room_id + the leader_node it posted to). This is
        # the un-spoofable proof that THIS node chose THIS room+leader, so the
        # member can later accept the leader's FIRST roster broadcast for this
        # room — and REFUSE a roster for a room it never tried to join (the
        # anti-rogue-leader-minting defense, accept_roster_broadcast contract
        # 3c). We record ONLY when the leader's 2xx response CONFIRMS it
        # persisted a pending row (`status==pending`) or already had one
        # (`duplicate==true`) — a bare 200 with no such confirmation does NOT
        # mint a local binding (so a non-committal/stub response cannot seed a
        # spurious intent).
        leader_confirmed_pending = False
        try:
            ack = json.loads(resp.decode("utf-8", "replace") or "{}")
            if isinstance(ack, dict):
                leader_confirmed_pending = (
                    ack.get("status") == rooms.JOIN_PENDING
                    or ack.get("duplicate") is True)
        except (ValueError, json.JSONDecodeError):
            leader_confirmed_pending = False
        if leader_confirmed_pending:
            try:
                mconn = rooms.open_rooms()
                try:
                    rooms.record_local_join_intent(
                        mconn, room_id, agent, node, leader_node=leader_node)
                finally:
                    mconn.close()
            except rooms.RoomsError as exc:
                # The leader already accepted the join; failing to record the
                # local binding is non-fatal but means the first roster will be
                # refused until re-joined. Surface it without unwinding the
                # accepted join.
                info(f"WARNING: cross-node join accepted but local binding not "
                     f"recorded ({exc}); the first roster broadcast may be "
                     "refused until you re-run join")
        if args.json:
            out(json.dumps({"room_id": room_id,
                            "agent": f"{agent}@{node}",
                            "leader_node": leader_node,
                            "status": rooms.JOIN_PENDING, "cross_node": True}))
        else:
            info(f"cross-node join request posted for {agent}@{node} on "
                 f"{room_id} to leader node {leader_node} (pending approval)")
        return 0

    # Single-node (P1) path: joiner + leader share this node.
    conn = rooms.open_rooms()
    try:
        room = rooms.get_room(conn, room_id)
        if room is None:
            return die(f"room not found: {room_id}", code=1)
        # Rate-limit per token + source BEFORE the hash compare so a brute
        # force on the token is bounded, then verify the token hash.
        try:
            rooms.record_join_attempt(conn, token, source=f"{agent}@{node}")
        except rooms.RoomsError as exc:
            return die(str(exc), code=1)
        if not rooms.verify_invite_token(room, token):
            return die("invalid invite token for this room (hash mismatch, "
                       "expired, or revoked)", code=1)
        rooms.post_join_request(conn, room_id, agent, node)
    finally:
        conn.close()
    if args.json:
        out(json.dumps({"room_id": room_id, "agent": f"{agent}@{node}",
                        "status": rooms.JOIN_PENDING}))
    else:
        info(f"join request posted for {agent}@{node} on {room_id} "
             "(pending leader approval)")
    return 0


def cmd_approve(args: argparse.Namespace) -> int:
    node = local_node()
    agent, anode = split_agent_node(args.target, node)
    conn = rooms.open_rooms()
    try:
        room = _require_leader_conn(conn, args.room_id, args)
        leader_node = str(room["leader_node"] or "")
        # P4.2 contract 1/6: a CROSS-NODE approve (admitting a REMOTE agent whose
        # node != this leader node) REQUIRES a P4.1 verified pending row — the
        # receiver only creates that AFTER the node-link HMAC + token + TTL/
        # revocation verification passed. The LOCAL leader-add path (admitting an
        # agent on this leader's OWN node) stays a SEPARATE path that does NOT
        # claim that token/two-factor gate. The two paths are kept distinct here.
        is_cross_node = bool(anode) and bool(leader_node) and anode != leader_node
        if is_cross_node:
            epoch = rooms.approve_cross_node(conn, args.room_id, agent, anode)
        else:
            # P1 local path: a leader-initiated add of a local agent (no verified-
            # pending-row requirement — the leader is OS-authenticated and the
            # agent shares this node).
            epoch = rooms.approve_join(conn, args.room_id, agent, anode)
        if room["invite_once"]:
            rooms.burn_invite_token(conn, args.room_id)
            burned = True
        else:
            burned = False
        # Broadcast the leader-signed canonical roster to every REMOTE member node
        # over the node-link (§14 R2), via the SHARED durable membership-change
        # path (Lane 5 gotcha F): it durably queues a convergence target per
        # member node (so an offline member converges later via the reconcile
        # heartbeat) AND attempts an immediate best-effort send. The local approve
        # is already committed + authoritative; a member-node delivery failure is
        # reported, never fatal. No-op when there are no remote member nodes.
        broadcast = {"delivered": [], "failed": [], "queued": []}
        if leader_node:
            broadcast = _broadcast_membership_change(
                conn, args.room_id, int(epoch), leader_node)
    except rooms.RoomsError as exc:
        conn.close()
        return die(str(exc), code=1)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    if args.json:
        out(json.dumps({"room_id": args.room_id, "approved": f"{agent}@{anode}",
                        "epoch": epoch, "invite_burned": burned,
                        "cross_node": is_cross_node,
                        "roster_broadcast": broadcast}))
    else:
        info(f"approved {agent}@{anode} into {args.room_id} (epoch {epoch})"
             + (" — single-use invite burned" if burned else ""))
        if broadcast["delivered"]:
            info(f"roster broadcast delivered to: "
                 f"{', '.join(broadcast['delivered'])}")
        if broadcast["failed"]:
            info(f"WARNING: roster broadcast failed for: "
                 f"{broadcast['failed']} (durable/retryable — the local approve "
                 "is committed)")
    return 0


def cmd_deny(args: argparse.Namespace) -> int:
    node = local_node()
    agent, anode = split_agent_node(args.target, node)
    conn = rooms.open_rooms()
    broadcast = {"delivered": [], "failed": [], "queued": []}
    ok = False
    try:
        room = _require_leader_conn(conn, args.room_id, args)
        leader_node = str(room["leader_node"] or "")
        ok = rooms.set_join_request_status(
            conn, args.room_id, agent, anode, rooms.JOIN_DENIED,
        )
        # Lane 5 gotcha F: deny does NOT change membership (the denied agent was
        # never admitted) and so does NOT bump the epoch — the canonical roster is
        # unchanged. We still route it through the SHARED broadcast path (one
        # internal fn for approve/kick/leave/deny) which RE-AFFIRMS the current
        # roster to remaining member nodes: an idempotent convergence nudge that
        # cannot re-admit the denied agent (it is not in room_members, so it never
        # enters the broadcast roster), and lets a member that missed a prior
        # broadcast catch up. No-op on a single-node room (no remote members).
        if ok and leader_node:
            broadcast = _broadcast_membership_change(
                conn, args.room_id, int(room["epoch"]), leader_node)
    except rooms.RoomsError as exc:
        conn.close()
        return die(str(exc), code=1)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    if not ok:
        return die(f"no join request from {agent}@{anode} on {args.room_id}",
                   code=1)
    if args.json:
        out(json.dumps({"room_id": args.room_id, "denied": f"{agent}@{anode}",
                        "roster_broadcast": broadcast}))
    else:
        info(f"denied {agent}@{anode} on {args.room_id}")
        if broadcast["failed"]:
            info(f"WARNING: roster broadcast failed for: {broadcast['failed']} "
                 "(durable/retryable — the deny is committed)")
    return 0


def cmd_kick(args: argparse.Namespace) -> int:
    node = local_node()
    agent, anode = split_agent_node(args.target, node)
    conn = rooms.open_rooms()
    broadcast = {"delivered": [], "failed": [], "queued": []}
    try:
        room = _require_leader_conn(conn, args.room_id, args)
        leader_node = str(room["leader_node"] or "")
        epoch = rooms.remove_and_bump(conn, args.room_id, agent, anode)
        # Lane 5 gotcha F: a kick MUST broadcast the new roster so the REMAINING
        # member nodes drop the kicked member (the prior code did NOT broadcast on
        # kick). Same shared durable path as approve: queue per-member + immediate
        # best-effort + reconcile-heartbeat retry. `removed_node=anode` ALSO queues
        # the just-kicked node (codex P2) so it receives the higher-epoch roster in
        # which it is absent and locally drops the room — it is no longer a member,
        # so it would otherwise never converge.
        if leader_node:
            broadcast = _broadcast_membership_change(
                conn, args.room_id, int(epoch), leader_node, removed_node=anode)
    except rooms.RoomsError as exc:
        conn.close()
        return die(str(exc), code=1)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    if args.json:
        out(json.dumps({"room_id": args.room_id, "kicked": f"{agent}@{anode}",
                        "epoch": epoch, "roster_broadcast": broadcast}))
    else:
        info(f"kicked {agent}@{anode} from {args.room_id} (epoch {epoch})")
        if broadcast["delivered"]:
            info(f"roster broadcast delivered to: "
                 f"{', '.join(broadcast['delivered'])}")
        if broadcast["failed"]:
            info(f"WARNING: roster broadcast failed for: {broadcast['failed']} "
                 "(durable/retryable — the kick is committed)")
    return 0


def cmd_leave(args: argparse.Namespace) -> int:
    node = local_node()
    agent = caller_agent(args)
    conn = rooms.open_rooms()
    broadcast = {"delivered": [], "failed": [], "queued": []}
    try:
        room = rooms.require_room(conn, args.room_id)
        leader_node = str(room["leader_node"] or "")
        epoch = rooms.remove_and_bump(conn, args.room_id, agent, node)
        # Lane 5 gotcha F: a leave bumps the epoch + must propagate the new roster
        # so the OTHER member nodes drop the departed member. The roster broadcast
        # is signed with the leader↔member pair keys, which ONLY the leader node
        # holds — so we broadcast ONLY when THIS node IS the leader node (a member
        # leaving on its own node mutates its local rooms.db view but cannot sign
        # for the leader; the leader's own reconcile heartbeat + the next
        # leader-side change converge the authoritative roster). This mirrors the
        # leader-authoritative model: the leader's rooms.db is the source of truth.
        if leader_node and node == leader_node:
            broadcast = _broadcast_membership_change(
                conn, args.room_id, int(epoch), leader_node)
    except rooms.RoomsError as exc:
        conn.close()
        return die(str(exc), code=1)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    if args.json:
        out(json.dumps({"room_id": args.room_id, "left": f"{agent}@{node}",
                        "epoch": epoch, "roster_broadcast": broadcast}))
    else:
        info(f"{agent}@{node} left {args.room_id} (epoch {epoch})")
        if broadcast["delivered"]:
            info(f"roster broadcast delivered to: "
                 f"{', '.join(broadcast['delivered'])}")
        if broadcast["failed"]:
            info(f"WARNING: roster broadcast failed for: {broadcast['failed']} "
                 "(durable/retryable — the leave is committed)")
    return 0


def cmd_adopt_all(args: argparse.Namespace) -> int:
    # #1517: adopt-all is also a first-use room-minting path — apply the same
    # controller-only canonical bootstrap so the very first `adopt-all` on a
    # fresh iso host does not fail closed with actor_unresolved. Same invariant:
    # a managed iso agent cannot self-bootstrap (canonical state dir is
    # controller-owned), and the bootstrap never follows BRIDGE_A2A_ROOMS_DB.
    rooms.maybe_bootstrap_rooms_db()
    node = local_node()
    leader = caller_agent(args)
    agents = _roster_agents()
    if leader not in agents:
        agents.append(leader)
    token = rooms.mint_invite_token()
    conn = rooms.open_rooms()
    try:
        room_id = rooms.create_room(
            conn, name=args.name, leader_agent=leader, leader_node=node,
            token=token, once=False,
        )
        added = 0
        for ag in agents:
            if ag == leader:
                continue  # already the leader row
            rooms.add_member(conn, room_id, ag, node, role=rooms.ROLE_MEMBER)
            added += 1
        # bump_epoch re-persists room_roster_cache at the new epoch with the
        # full member set (F2). When no members were added beyond the leader,
        # create_room already wrote the epoch-0 cache, so the cache is fresh
        # either way.
        if added:
            rooms.bump_epoch(conn, room_id)
        roster = rooms.roster_for(conn, room_id)
    finally:
        conn.close()
    if args.json:
        out(json.dumps({"room_id": room_id, "name": args.name,
                        "epoch": roster["epoch"],
                        "members": roster["members"]}))
    else:
        info(f"adopted {len(roster['members'])} agent(s) into default room "
             f"{room_id} (epoch {roster['epoch']})")
        for m in roster["members"]:
            out(f"  - {m['agent']}@{m['node']} ({m['role']})")
    return 0


def require_controller_actor(args: argparse.Namespace, action: str) -> None:
    """Gate a config mutation (acl flip) to a proven controller/operator shell.

    Flipping rooms_acl is an OPERATOR control-plane action, not an agent one
    (design §14 R1 deliverable 5: only the controller/leader may flip it). The
    actor-auth follows the same regime model as leader-auth:
      - ISO_ENFORCED   : a managed iso agent is NOT the operator -> HARD deny
                         (it must not be able to turn enforcement off/on).
      - UNRESOLVED     : iso host, no trusted actor -> HARD deny (fail closed).
      - CONTROLLER     : the proven operator shell (owns the rooms db) -> allow.
      - SHARED_ADVISORY: no OS boundary exists anyway -> allow (the install has
                         no hard agent separation to protect).
    """
    actor = rooms.resolve_os_actor(getattr(args, "as_agent", None))
    if actor.regime == rooms.ACTOR_ISO_ENFORCED:
        raise rooms.RoomsError(
            f"{action} is an operator action: a managed iso agent "
            f"(uid {actor.uid}) cannot change the rooms_acl mode — run it from "
            "the controller/operator shell",
            code="not_controller",
        )
    if actor.regime == rooms.ACTOR_UNRESOLVED:
        raise rooms.RoomsError(
            f"{action}: could not establish a trusted controller actor for uid "
            f"{actor.uid} (linux-user isolation is active but this process is "
            "neither an iso agent nor the controller) — failing closed",
            code="actor_unresolved",
        )
    # CONTROLLER (proven operator) or SHARED_ADVISORY (no OS boundary) -> allow.


def cmd_acl(args: argparse.Namespace) -> int:
    if args.mode is None:
        mode = rooms.rooms_acl_mode()
        if args.json:
            out(json.dumps({"rooms_acl": mode}))
        else:
            info(f"rooms_acl mode: {mode} "
                 "(enforced by the queue gate in P1b)")
        return 0
    try:
        require_controller_actor(args, "setting rooms_acl")
    except rooms.RoomsError as exc:
        return die(str(exc), code=1)
    # Migration safety (design §14 R1 / deliverable 4): flipping to enforce with
    # NO rooms defined would silently wall every inter-agent create. That is an
    # operator-config error, not a valid state — refuse loudly and point at
    # adopt-all, unless --force is given (an operator who really wants a fully
    # locked-down install with only controller/daemon traffic).
    if args.mode == rooms.ACL_ENFORCE and not getattr(args, "force", False):
        ro = rooms.open_rooms_readonly()
        has_room = False
        if ro is not None:
            try:
                has_room = ro.execute("SELECT 1 FROM rooms LIMIT 1").fetchone() is not None
            except Exception:  # noqa: BLE001
                has_room = False
            finally:
                ro.close()
        if not has_room:
            return die(
                "refusing to set rooms_acl=enforce with NO rooms defined: this "
                "would block every inter-agent create. Run `agb room adopt-all` "
                "first (creates a default room with every roster agent so no "
                "agent is stranded), or pass --force to lock down anyway "
                "(controller/daemon traffic still flows).",
                code=1,
            )
    conn = rooms.open_rooms()
    try:
        rooms.set_acl_mode(conn, args.mode)
    except rooms.RoomsError as exc:
        conn.close()
        return die(str(exc), code=1)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    if args.json:
        out(json.dumps({"rooms_acl": args.mode}))
    else:
        info(f"rooms_acl set to {args.mode} "
             "(enforced by the queue gate: same-room creates allowed, "
             "cross-room blocked under iso v2 / advisory in shared mode)")
    return 0


# --------------------------------------------------------------------------
# parser
# --------------------------------------------------------------------------

def _add_common(p: argparse.ArgumentParser, *, with_as: bool = True) -> None:
    p.add_argument("--json", action="store_true",
                   help="machine-readable JSON output")
    if with_as:
        p.add_argument(
            "--as", dest="as_agent", default=None,
            help="operator override for the acting agent id. Honored ONLY "
                 "from a proven controller/operator shell or in shared-mode "
                 "(advisory). Under linux-user isolation (iso v2) the acting "
                 "agent is derived from the process OS uid and --as is IGNORED "
                 "for leader-auth — it cannot be used to impersonate the "
                 "leader.",
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent-bridge room",
        description="A2A rooms control plane (single-node P1a).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_create = sub.add_parser("create", help="create a room (you are leader)")
    p_create.add_argument("--name", default="", help="human room name")
    p_create.add_argument(
        "--ttl", type=int, default=0,
        help="invite-token lifetime in seconds (0 = no expiry, the default). "
             "A cross-node join (P4.1) with an expired token is refused.")
    _add_common(p_create)
    p_create.set_defaults(func=cmd_create)

    p_list = sub.add_parser("list", help="list rooms")
    p_list.add_argument("--owned", action="store_true",
                        help="only rooms this node leads")
    _add_common(p_list, with_as=False)
    p_list.set_defaults(func=cmd_list)

    p_show = sub.add_parser("show", help="show a room's roster + epoch")
    p_show.add_argument("room_id")
    _add_common(p_show, with_as=False)
    p_show.set_defaults(func=cmd_show)

    p_invite = sub.add_parser("invite", help="mint a fresh invite token")
    p_invite.add_argument("room_id")
    p_invite.add_argument("--once", action="store_true",
                          help="single-use token (burned after one approval)")
    p_invite.add_argument(
        "--ttl", type=int, default=0,
        help="invite-token lifetime in seconds (0 = no expiry, the default).")
    _add_common(p_invite)
    p_invite.set_defaults(func=cmd_invite)

    p_rot = sub.add_parser("rotate-invite",
                           help="rotate the invite token (invalidate the old)")
    p_rot.add_argument("room_id")
    _add_common(p_rot)
    p_rot.set_defaults(func=cmd_rotate_invite)

    p_join = sub.add_parser("join", help="post a join request (token-bearing link)")
    p_join.add_argument("link", help="agbroom:// link (carries the token)")
    _add_common(p_join)
    p_join.set_defaults(func=cmd_join)

    p_approve = sub.add_parser("approve", help="leader: approve a join request")
    p_approve.add_argument("room_id")
    p_approve.add_argument("target", help="agent or agent@node")
    _add_common(p_approve)
    p_approve.set_defaults(func=cmd_approve)

    p_deny = sub.add_parser("deny", help="leader: deny a join request")
    p_deny.add_argument("room_id")
    p_deny.add_argument("target", help="agent or agent@node")
    _add_common(p_deny)
    p_deny.set_defaults(func=cmd_deny)

    p_kick = sub.add_parser("kick", help="leader: remove a member")
    p_kick.add_argument("room_id")
    p_kick.add_argument("target", help="agent or agent@node")
    _add_common(p_kick)
    p_kick.set_defaults(func=cmd_kick)

    p_leave = sub.add_parser("leave", help="leave a room you are in")
    p_leave.add_argument("room_id")
    _add_common(p_leave)
    p_leave.set_defaults(func=cmd_leave)

    p_talk = sub.add_parser(
        "talk",
        help="send a room-scoped message to the room's other member nodes")
    p_talk.add_argument("room_id")
    p_talk.add_argument("--title", required=True)
    p_talk.add_argument("--body", default=None)
    p_talk.add_argument("--body-file", dest="body_file", default=None)
    p_talk.add_argument("--to", default="",
                        help="narrow to one recipient (agent or agent@node); "
                             "default = every other-node member")
    p_talk.add_argument("--priority", default="normal")
    p_talk.add_argument("--allow-empty-body", action="store_true",
                        dest="allow_empty_body")
    p_talk.add_argument("--fanout", action="store_true", dest="fanout",
                        help="ALSO deliver to same-node members via the local "
                             "queue (whole-room fan-out); default = cross-node "
                             "members only")
    _add_common(p_talk)
    p_talk.set_defaults(func=cmd_talk)

    # `send` is the canonical whole-room fan-out alias (#1594): same machinery as
    # `talk` but fan-out ON by default (every OTHER member — local same-node via
    # the queue + remote member-nodes via room-scoped A2A — self excluded). It is
    # what `agent-bridge a2a send --room <room_id>` routes to. `talk` stays for
    # back-compat (cross-node only unless --fanout). The receiver-side gate is
    # unchanged and still independently enforces membership on every remote hop.
    p_fan = sub.add_parser(
        "send",
        help="whole-room fan-out: deliver to EVERY other room member "
             "(local via the queue + remote via room-scoped A2A)")
    p_fan.add_argument("room_id")
    p_fan.add_argument("--title", required=True)
    p_fan.add_argument("--body", default=None)
    p_fan.add_argument("--body-file", dest="body_file", default=None)
    p_fan.add_argument("--to", default="",
                       help="narrow to one recipient (agent or agent@node); "
                            "default = every other member, local and remote")
    p_fan.add_argument("--priority", default="normal")
    p_fan.add_argument("--allow-empty-body", action="store_true",
                       dest="allow_empty_body")
    _add_common(p_fan)
    p_fan.set_defaults(func=cmd_talk, fanout=True)

    p_adopt = sub.add_parser(
        "adopt-all",
        help="create a default room with every current roster agent",
    )
    p_adopt.add_argument("--name", default="default", help="room name")
    _add_common(p_adopt)
    p_adopt.set_defaults(func=cmd_adopt_all)

    p_acl = sub.add_parser("acl", help="show/set rooms_acl mode (off|enforce)")
    p_acl.add_argument("mode", nargs="?", choices=[rooms.ACL_OFF, rooms.ACL_ENFORCE],
                       default=None, help="set the mode; omit to show")
    p_acl.add_argument(
        "--force", action="store_true",
        help="allow setting enforce with no rooms defined (locks down all "
             "inter-agent creates; controller/daemon traffic still flows)")
    _add_common(p_acl)  # --as: honored only for controller/shared (iso ignored)
    p_acl.set_defaults(func=cmd_acl)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return args.func(args)
    except rooms.RoomsError as exc:
        return die(f"{exc} ({exc.code})")
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
