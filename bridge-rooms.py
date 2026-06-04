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
    link = rooms.make_invite_link(room_id, node, token)
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
        items = [
            {
                "room_id": r["room_id"], "name": r["name"],
                "leader": f"{r['leader_agent']}@{r['leader_node']}",
                "epoch": int(r["epoch"]), "status": r["status"],
            }
            for r in rows
        ]
    finally:
        conn.close()
    if args.json:
        out(json.dumps(items))
        return 0
    if not items:
        info("no rooms" + (" owned by this node" if args.owned else ""))
        return 0
    for it in items:
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
            return die(f"room not found: {args.room_id}", code=1)
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
    link = rooms.make_invite_link(args.room_id, node, token)
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


def _post_room_join_request(*, leader_node: str, room_id: str, token: str,
                            joiner_agent: str, timeout: float = 30.0,
                            ) -> tuple[int, bytes]:
    """POST a signed cross-node room-join-request to the leader's node (P4.1).

    The leader's node id (`leader_node`) names the A2A peer to deliver to. We
    resolve that peer from the local A2A config, sign the body with the node-link
    HMAC secret, and POST to the leader's `room_join_path`. The wire carries
    sha256(token) ONLY (hash_token) — the raw token never leaves this process.
    `joiner_agent` is the OS-actor-anchored agent id (resolved by the CALLER via
    caller_agent / resolve_os_actor) — NEVER a --from/env value. Returns
    (http_status, response_body).

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
    peer = a2a.find_peer(cfg, leader_node)
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

    address = a2a.resolve_peer_address(peer)
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
        try:
            status, resp = _post_room_join_request(
                leader_node=leader_node, room_id=room_id, token=token,
                joiner_agent=agent,
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
        # A join must have been requested (the two-factor gate: token =>
        # request => leader approval). Approving an unrequested agent is a
        # leader-initiated add, which we allow but note.
        epoch = rooms.approve_join(conn, args.room_id, agent, anode)
        if room["invite_once"]:
            rooms.burn_invite_token(conn, args.room_id)
            burned = True
        else:
            burned = False
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
                        "epoch": epoch, "invite_burned": burned}))
    else:
        info(f"approved {agent}@{anode} into {args.room_id} (epoch {epoch})"
             + (" — single-use invite burned" if burned else ""))
    return 0


def cmd_deny(args: argparse.Namespace) -> int:
    node = local_node()
    agent, anode = split_agent_node(args.target, node)
    conn = rooms.open_rooms()
    try:
        _require_leader_conn(conn, args.room_id, args)
        ok = rooms.set_join_request_status(
            conn, args.room_id, agent, anode, rooms.JOIN_DENIED,
        )
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
        out(json.dumps({"room_id": args.room_id, "denied": f"{agent}@{anode}"}))
    else:
        info(f"denied {agent}@{anode} on {args.room_id}")
    return 0


def cmd_kick(args: argparse.Namespace) -> int:
    node = local_node()
    agent, anode = split_agent_node(args.target, node)
    conn = rooms.open_rooms()
    try:
        _require_leader_conn(conn, args.room_id, args)
        epoch = rooms.remove_and_bump(conn, args.room_id, agent, anode)
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
                        "epoch": epoch}))
    else:
        info(f"kicked {agent}@{anode} from {args.room_id} (epoch {epoch})")
    return 0


def cmd_leave(args: argparse.Namespace) -> int:
    node = local_node()
    agent = caller_agent(args)
    conn = rooms.open_rooms()
    try:
        rooms.require_room(conn, args.room_id)
        epoch = rooms.remove_and_bump(conn, args.room_id, agent, node)
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
                        "epoch": epoch}))
    else:
        info(f"{agent}@{node} left {args.room_id} (epoch {epoch})")
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
