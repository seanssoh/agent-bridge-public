#!/usr/bin/env python3
"""SQLite-backed task queue for Agent Bridge."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# Operator-home SSOT (issue #1497 P2). This script lives at the repo root (and
# `~/.agent-bridge/` root in the deployed runtime), so the canonical resolver is
# `<this>/lib/operator_home.py`. Load it by its EXACT path via importlib — NOT
# through sys.path — so a same-named `operator_home` module elsewhere on the path
# can never shadow it and redirect the queue DB / runtime home (#1507 r2: a bare
# `from operator_home import` does NOT raise when lib/ is absent if some other
# operator_home is importable). When the exact file is absent (partial deploy /
# test overlay) the inline fallback is byte-identical to operator_home().
_OPERATOR_HOME_PY = Path(__file__).resolve().parent / "lib" / "operator_home.py"
operator_home = None
if _OPERATOR_HOME_PY.is_file():  # noqa: raw-pathlib-controller-only — import-time exact-file probe
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location("_agb_operator_home", str(_OPERATOR_HOME_PY))
    if _spec is not None and _spec.loader is not None:
        _mod = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        operator_home = getattr(_mod, "operator_home", None)
if not callable(operator_home):  # exact file absent — byte-identical inline SSOT
    def operator_home() -> Path:
        explicit = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; BRIDGE_HOME is the operator runtime root, not an isolated artifact
        if explicit:
            return Path(explicit).expanduser()
        return Path.home() / ".agent-bridge"


OPEN_STATUSES = ("queued", "claimed", "blocked")
PRIORITY_CHOICES = ("low", "normal", "high", "urgent")
STATUS_CHOICES = ("queued", "claimed", "blocked", "done", "cancelled")
OPEN_STATUS_ALIASES = {
    "in_progress": "claimed",
    "in-progress": "claimed",
    "progress": "claimed",
    "working": "claimed",
}
UPDATE_STATUS_CHOICES = (*OPEN_STATUSES, *OPEN_STATUS_ALIASES.keys())
FAMILY_RULES = (
    "memory-daily",
    "monthly-highlights",
    "morning-briefing",
    "evening-digest",
    "event-reminder",
    "weekly-review",
)

BLOCKED_REMINDER_TITLE_PREFIX = "[blocked-aging] task #"
BLOCKED_ESCALATION_TITLE_PREFIX = "[blocked-escalation] task #"

UNEXPANDED_SHELL_VAR_RE = re.compile(r"(?<!\\)(\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)")


def now_ts() -> int:
    return int(time.time())


def isoformat_ts(value: int | None) -> str:
    if not value:
        return "-"
    return datetime.fromtimestamp(int(value), tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def get_db_path() -> Path:
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    db_path = Path(os.environ.get("BRIDGE_TASK_DB", str(state_dir / "tasks.db")))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return db_path


def fresh_arrival_dir() -> Path:
    """`$BRIDGE_STATE_DIR/queue/fresh-arrival` — one-shot daemon scan-now markers.

    Issue #1630 (audit R3, root cause of #10561): the A2A receiver writes a
    marker file named `<task_id>` here right after a successful enqueue (see
    `post_fresh_arrival_marker` in bridge-handoffd.py). The daemon nudge_scan
    step (`cmd_daemon_step`) reads these markers and exempts the named task ids
    from ONLY the redelivery-AGE gate for that tick — never any auth/dedupe/
    queue/idle/cooldown check — then deletes the consumed marker (one-shot).
    Resolution mirrors `get_db_path` so the receiver (writer) and the daemon
    (reader) agree on one path regardless of $BRIDGE_STATE_DIR override.
    """
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    return state_dir / "queue" / "fresh-arrival"


# Fresh-arrival markers older than this are swept as stale even if their task is
# still queued — a generous ceiling so a marker only ever shaves the age-gate
# latency once and never accumulates. Far larger than both the ~60s redelivery
# window and a single daemon tick, so a legitimately-fresh task is never swept
# before the daemon has a chance to nudge it.
FRESH_ARRIVAL_MARKER_MAX_AGE_SECONDS = 3600


def consume_fresh_arrival_markers() -> set[int]:
    """Claim-by-delete the one-shot fresh-arrival markers, return their task ids.

    One-shot by contract (#1630): a task id is returned ONLY when this call
    successfully unlinks its marker — claim-by-delete. The id is added AFTER the
    unlink succeeds, not before (codex R1 [P1]): otherwise two overlapping
    daemon-step consumers could both list and return the same id, and a
    readable-but-not-deletable marker (e.g. a numeric *directory*, or a perms
    glitch) would keep exempting its task across every tick — defeating the
    one-shot guarantee and reopening a perpetual age-gate bypass. With
    claim-by-delete, exactly one caller wins the unlink and exempts the task for
    AT MOST one tick; a lost race or failed unlink simply leaves the task to
    wait out the ~60s age gate as before.

    Stray non-id files (e.g. an orphaned writer `<id>.tmp`) older than the
    ceiling are swept here too so the dir never accumulates. Best-effort: any fs
    error is swallowed — a marker that cannot be read/claimed simply leaves the
    pre-fix ~60s latency in place, never a crash in the daemon loop and never a
    security relaxation.
    """
    ids: set[int] = set()
    marker_dir = fresh_arrival_dir()
    try:
        entries = list(marker_dir.iterdir())
    except OSError:
        return ids
    now = now_ts()
    for entry in entries:
        name = entry.name
        # Ignore (but eventually sweep) the writer's in-flight `<id>.tmp` files
        # and any other stray non-id files.
        if not name.isdigit():
            try:
                # noqa markers: $BRIDGE_STATE_DIR/queue/fresh-arrival is
                # controller-owned queue state, never an isolated-agent tree.
                if entry.is_file() and (now - int(entry.stat().st_mtime)) > FRESH_ARRIVAL_MARKER_MAX_AGE_SECONDS:  # noqa: raw-pathlib-controller-only
                    entry.unlink()  # noqa: raw-pathlib-controller-only
            except OSError:
                pass
            continue
        try:
            task_id = int(name)
        except ValueError:
            continue
        # Claim-by-delete: only exempt the task if WE removed its marker. A
        # failed unlink (lost race, perms, a numeric directory) does not claim
        # the id, so the marker can never exempt the same task on more than one
        # tick and a never-deletable marker can never perpetually bypass the gate.
        try:
            entry.unlink()  # noqa: raw-pathlib-controller-only — controller-owned fresh-arrival marker
        except OSError:
            continue
        ids.add(task_id)
    return ids


def get_queue_gateway_root() -> Path:
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    layout = os.environ.get("BRIDGE_LAYOUT", "").strip()
    agent_root_v2 = os.environ.get("BRIDGE_AGENT_ROOT_V2", "").strip()
    if layout == "v2" and agent_root_v2:
        return Path(agent_root_v2).expanduser()
    return state_dir / "queue-gateway"


def queue_gateway_proxy_agent() -> str:
    if os.environ.get("BRIDGE_QUEUE_GATEWAY_SERVER", "") == "1":
        return ""
    if os.environ.get("BRIDGE_GATEWAY_PROXY", "") != "1":
        return ""
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


def _running_under_queue_gateway_server() -> bool:
    """True when this bridge-queue.py invocation is the gateway-server child.

    The gateway socket-server sets BRIDGE_QUEUE_GATEWAY_SERVER=1 before
    spawning bridge-queue.py (see run_queue() in bridge-queue-gateway.py).
    Any direct handler that mutates a task can use this flag to demand a
    second-line ownership check, even if the gateway authorizer was wrong
    or future-bypassed (defense-in-depth, finding 2b r2 review).
    """
    return os.environ.get("BRIDGE_QUEUE_GATEWAY_SERVER", "") == "1"


def _gateway_server_authorize(task: sqlite3.Row, actor: str, op: str) -> None:
    """Server-side ownership re-check for cancel/update/handoff.

    The gateway authorizer (bridge-queue-gateway.py:authorize_and_rewrite)
    is the primary gate. This is a *second* gate: if the gateway parser
    is ever wrong (e.g. the round-1 argv-rewriting bypass that misread
    `done --note 60 12` as task 60), the server should still refuse to
    mutate a task whose ownership the actor cannot prove.

    Allow when actor is one of {assigned_to, created_by, claimed_by}.
    Deny otherwise with a recognizable error so smoke tests / audits can
    fingerprint the second-line refusal.
    """
    if not actor:
        raise SystemExit(f"queue gateway server denied {op}: empty actor")
    owners = {
        str(task["assigned_to"] or ""),
        str(task["created_by"] or ""),
        str(task["claimed_by"] or ""),
    }
    owners.discard("")
    if actor not in owners:
        raise SystemExit(
            f"queue gateway server denied {op}: actor {actor!r} is not an owner of "
            f"task #{task['id']}"
        )


def _load_rooms_common():
    """Import bridge_rooms_common from this script's dir (lazy, optional).

    Returns the module or None. Loaded by EXACT path via importlib (mirroring
    the operator_home SSOT loader) so a same-named module on sys.path cannot
    shadow it. None when the rooms control plane is absent (pre-P1a / stripped
    deploy) — the ACL gate then degrades to a no-op pass.
    """
    path = Path(__file__).resolve().parent / "bridge_rooms_common.py"
    if not path.is_file():  # noqa: raw-pathlib-controller-only — exact-file import probe
        return None
    import importlib.util as _ilu

    try:
        spec = _ilu.spec_from_file_location("_agb_rooms_common", str(path))
        if spec is None or spec.loader is None:
            return None
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001 - any fault -> no-op (pre-P1b behavior)
        return None


def _canonical_rooms_db_path() -> Path:
    """The rooms.db CANONICALLY co-located with the REAL task DB being written.

    SECURITY (P1b r3): the rooms ACL enforcement DB must be derived from the SAME
    home as the task DB this create actually mutates — NOT from an independent,
    caller-redirectable `BRIDGE_A2A_ROOMS_DB`. Otherwise a managed agent could
    keep the task-DB env REAL while pointing the rooms-DB env at a self-owned fake
    (seeded so it shares a room with the target) and drive the real queue past the
    gate. By pinning the enforcement rooms.db to `<task_db_dir>/handoff/rooms.db`
    (the layout `rooms_db_path()` uses for the default home), a fake rooms-DB env
    can never be paired with a real task DB. Mirrors the live layout: the task DB
    lives at `<state>/tasks.db` and rooms.db at `<state>/handoff/rooms.db`.
    """
    return get_db_path().parent / "handoff" / "rooms.db"


def _rooms_acl_mode_or_fail_closed(rooms, hard: bool, db_path: Path) -> str:
    """Read the rooms_acl mode from `db_path`; on unreadable, fail closed iff hard.

    `hard` is True for an OS-enforced (iso) or unresolved actor — for those, a
    present-but-unreadable rooms.db must be treated as ENFORCE (fail closed), NOT
    silently 'off' (the BLOCKING fail-open codex r1 flagged). For controller/
    shared regimes (no hard boundary) a db fault degrades to 'off' (controller is
    exempt anyway; shared is advisory). A genuinely ABSENT db is 'off' for all.
    `db_path` is the CANONICAL rooms.db (r3) — never a caller-redirected one.
    """
    try:
        return rooms.rooms_acl_mode_strict(db_path)
    except Exception:  # noqa: BLE001 - present-but-unreadable rooms.db
        return rooms.ACL_ENFORCE if hard else rooms.ACL_OFF


def _queue_is_controller_process() -> bool:
    """True iff this process OWNS the REAL task DB being written (the controller).

    SECURITY ANCHOR (P1b r3): the un-forgeable proof that the queue child was
    spawned BY the controller-run gateway. The thing a queue create MUTATES is the
    TASK DB, so the controller proof is anchored to the owner of THAT db
    (`os.stat(get_db_path()).st_uid`), NOT the rooms.db (which is selectable via
    `BRIDGE_A2A_ROOMS_DB` — the codex r3 bypass). The gateway runs as the
    controller and spawns the queue child in-process (no uid drop), so a genuine
    child owns the controller's task DB. A direct managed agent runs as the agent
    uid and CANNOT chown the controller-owned task DB; pointing `BRIDGE_TASK_DB`
    at a self-owned fake makes it "controller" of a fake queue with ZERO real
    effect (the P1a invariant applied to the db actually being mutated).

    Fails CLOSED (False) on any stat fault — an un-anchored process is never the
    controller.

    When the task DB does not yet exist (first create on a fresh install), anchor
    to the owner of the directory it WILL be created in: the create writes the db
    there, so its owner is the effective controller for this queue. A managed
    agent cannot write into the controller-owned `<state>/` dir, so it cannot
    satisfy this for the real task DB; pointing BRIDGE_TASK_DB at a self-owned dir
    yields a fake queue with zero real effect.

    TEST SEAM (structurally prod-inert): on a single-uid test host the smoke
    cannot create a foreign-owned task DB, so a paired-flag override
    (BRIDGE_QUEUE_TEST_NOT_CONTROLLER=1) lets it simulate a NON-controller managed
    agent. It is honored ONLY behind the same proven-inert paired-flag gate the
    rooms actor-auth seams use (rooms._test_uid_map_allowed: BRIDGE_ROOMS_ALLOW_
    TEST_UID_MAP=1 AND BRIDGE_A2A_ALLOW_TEST_BIND=1 AND the process owns the
    rooms.db) — production sets none of these, so it is never honored there.
    """
    if os.environ.get("BRIDGE_QUEUE_TEST_NOT_CONTROLLER") == "1":
        rooms = _load_rooms_common()
        if rooms is not None:
            try:
                if rooms._test_uid_map_allowed():
                    return False
            except Exception:  # noqa: BLE001 - missing helper -> ignore the test override
                pass
    me = os.getuid()
    db = get_db_path()
    try:
        return os.stat(str(db)).st_uid == me  # noqa: raw-pathlib-controller-only — controller anchor: owner of the REAL task DB being mutated
    except OSError:
        pass
    try:
        return os.stat(str(db.parent)).st_uid == me  # noqa: raw-pathlib-controller-only — task DB absent: anchor to the dir it will be created in
    except OSError:
        return False


def _rooms_host_has_iso_users(rooms) -> bool:
    """True iff the host has iso OS users (a genuine iso-v2 host, hard boundary).

    Wraps rooms.host_has_iso_users(). On a fault / missing helper, fail CLOSED to
    True (treat as a hard iso host): a hard regime under enforce denies cross-room
    rather than silently advising — the safe default for the gateway path. (The
    gateway only runs for iso agents, so True is also the common-case correct
    answer.)
    """
    try:
        return bool(rooms.host_has_iso_users())
    except Exception:  # noqa: BLE001 - missing helper / passwd fault -> assume iso host (fail closed)
        return True


def _rooms_acl_check_create(actor: str, target: str) -> None:
    """Rooms ACL (P1b) defense-in-depth + non-gateway gate for cmd_create.

    The PRIMARY iso-v2 gate is the queue gateway (it derives the actor from
    SO_PEERCRED and re-checks there). This function is the SECOND line + the
    gate for the create paths that do NOT traverse the gateway:

      - The gateway-server child (BRIDGE_QUEUE_GATEWAY_SERVER=1): `actor` is the
        gateway-rewritten --from (the OS-trusted iso agent). We re-decide under
        ISO_ENFORCED so a future gateway-authorizer bypass still cannot land a
        cross-room create (mirrors _gateway_server_authorize for cancel/update).
      - Direct creates (controller/daemon/cron, genuine shared-mode single-UID):
        the OS actor + regime come from resolve_os_actor() — controller/daemon
        creates are CONTROLLER (bypass), shared-mode is ADVISORY (warn, never
        block), an un-establishable actor on an iso host is UNRESOLVED (deny).

    Raises SystemExit on a HARD deny (cross-room under iso enforcement, or
    fail-closed). Emits an advisory warning (no block) for shared-mode cross-
    room. A no-op when rooms_acl is off / no rooms exist / the module is absent.
    """
    rooms = _load_rooms_common()
    if rooms is None:
        return

    # The CANONICAL enforcement rooms.db, derived from the REAL task-DB home — NOT
    # a caller-redirectable BRIDGE_A2A_ROOMS_DB (codex r3): a managed agent could
    # otherwise pair a real task DB with a self-owned fake rooms DB (seeded so it
    # shares a room with the target) and drive the real queue past the gate. Every
    # security read below (mode + membership) reads THIS db, never the env one.
    canonical_rooms_db = _canonical_rooms_db_path()

    # Resolve the OS-enforced actor + regime FIRST (before the mode read), so a
    # present-but-unreadable rooms.db can fail CLOSED for a real iso actor rather
    # than silently reading 'off' (codex r1). The actor source is NEVER the client
    # --from.
    # CRITICAL (P1b r2+r3): the gateway-child env signal is only TRUSTWORTHY when
    # THIS process is the controller, anchored to the owner of the REAL TASK DB
    # being written (the thing a queue create mutates) — NOT the rooms.db owner
    # (which is selectable via BRIDGE_A2A_ROOMS_DB; that was the r3 bypass). The
    # gateway runs as the controller and spawns the queue child in-process (no uid
    # drop), so a genuine child owns the controller's task DB. A direct managed
    # agent runs as the AGENT uid, cannot chown the controller-owned task DB, and
    # so fails this anchor → falls to resolve_os_actor() = its REAL OS identity →
    # cannot impersonate. Pointing BRIDGE_TASK_DB at a self-owned fake makes it
    # "controller" of a fake queue with zero real effect (the P1a invariant).
    under_gateway = (
        _running_under_queue_gateway_server() and _queue_is_controller_process()
    )
    if under_gateway:
        # We ARE the controller (own the real task DB) AND the gateway flag is set,
        # so the gateway authenticated the actor (socket: SO_PEERCRED; file:
        # request-file owner uid) and passed it in BRIDGE_QUEUE_GATEWAY_ACTOR (its
        # own child env). Use it as the actor, NEVER the client --from (args.actor).
        # The REGIME is the host's OS-separation fact: a genuine iso-v2 host
        # (un-spoofable passwd users) -> ISO_ENFORCED (hard); a shared-mode host
        # (no iso users, where the gateway never legitimately runs) ->
        # SHARED_ADVISORY, so even a controller-uid process with a forged gateway
        # env cannot hard-block cross-team traffic (§14 R1: advisory either way).
        gateway_hard = _rooms_host_has_iso_users(rooms)
        gateway_actor = os.environ.get("BRIDGE_QUEUE_GATEWAY_ACTOR", "").strip()  # noqa: iso-helper-boundary — gateway-server child env (controller-anchored), not an isolated-agent artifact
        if not gateway_actor:
            # Under the gateway server but NO authenticated actor was established
            # (e.g. the file transport could not map the request-file owner to an
            # iso agent). Do NOT fall back to the client --from. On an iso host
            # this fails CLOSED under enforce; on a shared-mode host there is no
            # hard boundary, so it is a no-op pass (advisory regime never blocks).
            if gateway_hard:
                mode = _rooms_acl_mode_or_fail_closed(rooms, hard=True, db_path=canonical_rooms_db)
                if mode == rooms.ACL_ENFORCE:
                    raise SystemExit(
                        "rooms ACL: create denied (gateway could not establish a "
                        "trusted OS actor for this request — failing closed) "
                        "[rooms_acl=enforce]"
                    )
            return
        regime = rooms.ACTOR_ISO_ENFORCED if gateway_hard else rooms.ACTOR_SHARED_ADVISORY
        decision_actor = gateway_actor
    else:
        # Not behind the gateway: resolve the actor from the PROCESS OS identity
        # (never from --from / BRIDGE_AGENT_ID). Controller/daemon -> bypass;
        # shared-mode -> advisory; iso-host-unresolved -> fail closed.
        try:
            auth = rooms.resolve_os_actor(actor or None)
        except Exception:  # noqa: BLE001 - resolver fault -> no-op (avoid breaking direct creates)
            return
        regime = auth.regime
        decision_actor = auth.agent
        # SECURITY (P1b r4): resolve_os_actor()'s CONTROLLER verdict anchors to the
        # owner of the ENV-selected rooms.db (`_controller_uid` -> stat(rooms_db_
        # path())), which honors BRIDGE_A2A_ROOMS_DB. A managed agent could point
        # that env at a SELF-OWNED/absent fake rooms.db so resolve_os_actor returns
        # CONTROLLER (with agent == the caller-supplied --from), and
        # acl_create_decision short-circuits to allow BEFORE any canonical
        # membership read (the codex r4 bypass). Re-anchor the controller exemption
        # to the REAL TASK DB owner (the db this create mutates, NOT env-selectable):
        # the genuine controller (daemon/operator) owns the real task DB; a managed
        # agent does not. If the CONTROLLER verdict is NOT backed by task-DB
        # ownership it is forged — discard it AND the caller-supplied agent
        # (auth.agent carried the requested --from), and decide by the REAL OS facts:
        #   - iso host  -> the create can only be a managed iso agent or an
        #                  unresolved process. Re-resolve with requested=None so no
        #                  --from override leaks in; an iso agent is then decided by
        #                  its real (OS-derived) membership, anything else is
        #                  UNRESOLVED -> fail closed. Never a controller bypass.
        #   - shared host-> SHARED_ADVISORY (no OS boundary; warn, never block).
        if regime == rooms.ACTOR_CONTROLLER and not _queue_is_controller_process():
            if _rooms_host_has_iso_users(rooms):
                try:
                    reauth = rooms.resolve_os_actor(None)  # NO requested override
                except Exception:  # noqa: BLE001 - resolver fault -> fail closed below
                    reauth = None
                if reauth is not None and reauth.regime == rooms.ACTOR_ISO_ENFORCED:
                    regime = rooms.ACTOR_ISO_ENFORCED
                    decision_actor = reauth.agent  # the real OS-derived slug, not --from
                else:
                    regime = rooms.ACTOR_UNRESOLVED
                    decision_actor = ""
            else:
                regime = rooms.ACTOR_SHARED_ADVISORY

    # A hard regime (iso/unresolved) demands a fail-closed mode read: a present-
    # but-unreadable rooms.db must NOT degrade to 'off'. Controller/shared regimes
    # have no hard boundary, so a db fault there degrades to a no-op (controller
    # is exempt anyway; shared is advisory). Read the CANONICAL db (r3).
    hard = regime in (rooms.ACTOR_ISO_ENFORCED, rooms.ACTOR_UNRESOLVED)
    mode = _rooms_acl_mode_or_fail_closed(rooms, hard=hard, db_path=canonical_rooms_db)
    if mode != rooms.ACL_ENFORCE:
        return

    # The membership lookup reads the CANONICAL rooms.db (r3), opened here and
    # passed explicitly so acl_create_decision cannot fall back to the env path.
    try:
        conn = rooms.open_rooms_readonly(canonical_rooms_db)
    except Exception:  # noqa: BLE001 - present-but-unreadable canonical db
        conn = None
        if hard:
            raise SystemExit(
                "rooms ACL: create denied (canonical rooms.db unreadable under "
                "enforce — failing closed) [rooms_acl=enforce]"
            )
        return
    if conn is None:
        # No canonical rooms.db -> no rooms in the REAL home -> back-compat allow.
        return
    try:
        decision = rooms.acl_create_decision(
            mode=mode,
            regime=regime,
            actor=decision_actor,
            target=(target or "").strip(),
            node="",
            conn=conn,
        )
    except Exception:  # noqa: BLE001 - decision fault: fail closed only on a hard path
        if regime in (rooms.ACTOR_ISO_ENFORCED, rooms.ACTOR_UNRESOLVED):
            raise SystemExit(
                "rooms ACL: create denied (rooms control plane unavailable "
                "under enforce — failing closed)"
            )
        return
    finally:
        try:
            if conn is not None:
                conn.close()
        except Exception:  # noqa: BLE001
            pass

    if decision.outcome == "deny":
        if decision.reason == rooms.ACL_DENY_FAIL_CLOSED:
            raise SystemExit(
                f"rooms ACL: create --to {target!r} denied ({decision.reason}): "
                f"could not read the rooms membership for sender "
                f"{decision_actor!r} under enforce (rooms.db unreadable / actor "
                f"un-establishable) — failing closed. [rooms_acl=enforce]"
            )
        raise SystemExit(
            f"rooms ACL: create --to {target!r} denied ({decision.reason}): "
            f"sender {decision_actor!r} shares no enforced room with the "
            f"recipient. Join a shared room (agb room) or have the operator "
            f"run `agb room adopt-all`. [rooms_acl=enforce]"
        )
    if decision.outcome == "advisory":
        print(
            f"warning (rooms ACL advisory): create --to {target!r} from "
            f"{decision_actor!r} crosses rooms; shared-mode installs cannot "
            f"OS-authenticate the sender so this is NOT blocked. Run agents "
            f"under linux-user isolation (iso v2) for a hard team boundary. "
            f"[{decision.reason}]",
            file=sys.stderr,
        )


def queue_gateway_float_env(name: str, default: str) -> str:
    raw = os.environ.get(name, default).strip()
    try:
        value = float(raw)
    except ValueError:
        return default
    if value <= 0:
        return default
    return raw


def queue_gateway_transport() -> str:
    transport = os.environ.get("BRIDGE_GATEWAY_TRANSPORT", "file").strip().lower()
    if transport not in {"file", "socket"}:
        return "file"
    return transport


def should_proxy_via_queue_gateway(argv: list[str]) -> bool:
    if not argv:
        return False
    if argv[0] in {"-h", "--help"}:
        return False
    if len(argv) == 2 and argv[1] in {"-h", "--help"}:
        return False
    return bool(queue_gateway_proxy_agent())


def proxy_via_queue_gateway(argv: list[str]) -> int:
    agent = queue_gateway_proxy_agent()
    if not agent:
        return 1
    gateway_script = Path(__file__).resolve().with_name("bridge-queue-gateway.py")
    if queue_gateway_transport() == "socket":
        command = [
            sys.executable,
            str(gateway_script),
            "socket-client",
            "--bridge-home",
            str(operator_home()),
            "--timeout",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS", "5"),
            *argv,
        ]
    else:
        command = [
            sys.executable,
            str(gateway_script),
            "client",
            "--root",
            str(get_queue_gateway_root()),
            "--agent",
            agent,
            "--timeout",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS", "45"),
            "--poll",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_POLL_SECONDS", "0.2"),
            *argv,
        ]
    return int(subprocess.run(command, check=False).returncode)


def get_cron_state_dir() -> Path:
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    cron_dir = Path(os.environ.get("BRIDGE_CRON_STATE_DIR", str(state_dir / "cron")))
    cron_dir.mkdir(parents=True, exist_ok=True)
    return cron_dir


def classify_family(name: str) -> str:
    for rule in FAMILY_RULES:
        if name.startswith(rule) or rule in name:
            return rule
    return name


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    with conn:
      conn.execute("PRAGMA journal_mode=WAL")
      conn.execute("PRAGMA foreign_keys=ON")
    init_db(conn)
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    with conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              assigned_to TEXT NOT NULL,
              created_by TEXT NOT NULL,
              priority TEXT NOT NULL DEFAULT 'normal',
              status TEXT NOT NULL DEFAULT 'queued',
              created_ts INTEGER NOT NULL,
              updated_ts INTEGER NOT NULL,
              body_text TEXT,
              body_path TEXT,
              claimed_by TEXT,
              claimed_ts INTEGER,
              lease_until_ts INTEGER,
              closed_ts INTEGER
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS task_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              event_type TEXT NOT NULL,
              actor TEXT NOT NULL,
              created_ts INTEGER NOT NULL,
              note_text TEXT,
              note_path TEXT,
              from_agent TEXT,
              to_agent TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_state (
              agent TEXT PRIMARY KEY,
              engine TEXT,
              session TEXT,
              workdir TEXT,
              active INTEGER NOT NULL DEFAULT 0,
              last_seen_ts INTEGER,
              last_heartbeat_ts INTEGER,
              session_activity_ts INTEGER,
              last_nudge_ts INTEGER,
              last_nudge_key TEXT,
              nudge_fail_count INTEGER NOT NULL DEFAULT 0,
              zombie INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        ensure_column(conn, "agent_state", "last_nudge_key", "TEXT")
        ensure_column(conn, "agent_state", "nudge_fail_count", "INTEGER NOT NULL DEFAULT 0")
        ensure_column(conn, "agent_state", "zombie", "INTEGER NOT NULL DEFAULT 0")
        # Issue #589: prompt-ready latch columns. The daemon writes these
        # via cmd_daemon_step from the session snapshot. The auto-stop
        # idle anchor in print_summary uses prompt_ready_ts in preference
        # to session_activity_ts so the boot window is not counted as
        # idle time.
        ensure_column(conn, "agent_state", "prompt_ready_ts", "INTEGER")
        ensure_column(conn, "agent_state", "prompt_ready_session", "TEXT")
        ensure_column(conn, "agent_state", "prompt_ready_source", "TEXT")
        # Issue #1792: attribution stamp for the creating context. Additive,
        # nullable — absent on legacy rows, never rewritten. `cron:<run_id>`
        # for cron-dispatched children (BRIDGE_CRON_RUN_ID), `session:<id>`
        # when an interactive engine session id is visible. NOT an auth
        # mechanism (the queue still trusts --from); pure metadata.
        ensure_column(conn, "tasks", "origin", "TEXT")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_assigned_status ON tasks(assigned_to, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_claimed_status ON tasks(claimed_by, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_lease ON tasks(status, lease_until_ts)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, created_ts)")


def ensure_column(conn: sqlite3.Connection, table: str, column: str, spec: str) -> None:
    existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column in existing:
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {spec}")


def normalize_path(path_value: str | None) -> str | None:
    if not path_value:
        return None
    path = Path(path_value).expanduser()
    if not path.exists():
        raise SystemExit(f"file not found: {path_value}")
    return str(path.resolve())


SYSTEM_TMP_PREFIXES: tuple[str, ...] = (
    "/tmp",
    "/var/tmp",
    "/var/folders",
    "/private/tmp",
    "/private/var/tmp",
    "/private/var/folders",
)

MAX_INLINE_BODY_BYTES = 1 * 1024 * 1024


def get_queue_bodies_dir() -> Path:
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    bodies_dir = state_dir / "queue" / "bodies"
    bodies_dir.mkdir(parents=True, exist_ok=True)
    return bodies_dir


def bridge_managed_roots() -> list[Path]:
    bridge_home = operator_home()
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    shared_dir = Path(os.environ.get("BRIDGE_SHARED_DIR", str(bridge_home / "shared")))
    roots: list[Path] = []
    for candidate in (bridge_home, state_dir, shared_dir):
        try:
            roots.append(candidate.resolve())
        except Exception:
            continue
    return roots


def ephemeral_tmp_roots() -> list[Path]:
    roots: list[Path] = []
    tmpdir_env = os.environ.get("TMPDIR", "").strip()
    if tmpdir_env:
        try:
            roots.append(Path(tmpdir_env).resolve())
        except Exception:
            pass
    for prefix in SYSTEM_TMP_PREFIXES:
        roots.append(Path(prefix))
    return roots


def is_ephemeral_body_path(path: Path) -> bool:
    try:
        resolved = path.resolve()
    except Exception:
        return False
    for root in bridge_managed_roots():
        try:
            resolved.relative_to(root)
            return False
        except ValueError:
            continue
    for root in ephemeral_tmp_roots():
        try:
            resolved.relative_to(root)
            return True
        except ValueError:
            continue
    return False


def _audit_body_file_sudo_fallback(
    body_path: Path,
    iso_uid: str,
    success: bool,
    rc: int | None,
    call_site: str,
    exception: BaseException | None = None,
) -> None:
    """Emit a ``body_file_sudo_fallback`` audit row (Lane J r2 SHOULD-FIX
    + r3 schema alignment).

    OPERATIONS.md §"Iso v2 agent troubleshooting" promises operators
    that the sudo-fallback path is observable via
    ``grep body_file_sudo_fallback state/audit.jsonl``. Before this
    commit the read path was silent; the runbook claim was a
    docs/impl mismatch (codex r1 SHOULD-FIX on PR #1293). We emit
    here so a follow-up "but did the fallback actually run?"
    question has a structured answer.

    Lane J r3 (codex r2 SHOULD-FIX): align the row schema with the
    brief — the per-agent OS user field is named ``iso_uid`` (not
    ``owner``) and exception branches log ``exception`` +
    ``exception_type`` so the operator sees WHY the fallback failed,
    not just an empty ``rc``.

    Best-effort: any failure to emit (missing bridge-audit.py, missing
    python interpreter, locked log file) is swallowed silently. The
    caller path is not gated on audit success — surfacing the audit
    write as an error would defeat the resilience the fallback is
    trying to provide in the first place.
    """
    audit_path = (
        os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
        or os.path.expanduser(os.path.join(
            os.environ.get("BRIDGE_HOME", "").strip() or "~/.agent-bridge",
            "logs",
            "audit.jsonl",
        ))
    )
    detail = {
        "file_path": str(body_path),
        "iso_uid": iso_uid,
        "fallback_method": "sudo-read",
        "success": success,
        "rc": rc if rc is not None else "",
        "call_site": call_site,
    }
    if exception is not None:
        detail["exception"] = str(exception)
        detail["exception_type"] = type(exception).__name__
    audit_script = Path(__file__).resolve().with_name("bridge-audit.py")
    if not audit_script.is_file():
        return
    cmd = [
        sys.executable,
        str(audit_script),
        "write",
        "--file",
        audit_path,
        "--actor",
        "bridge-queue",
        "--action",
        "body_file_sudo_fallback",
        "--target",
        str(body_path),
        "--detail-json",
        json.dumps(detail, ensure_ascii=True, sort_keys=True),
    ]
    try:
        Path(audit_path).expanduser().parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    try:
        subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def _sudo_read_body_file(path: Path) -> bytes | None:
    """v0.15.0-beta4 Lane J (#1280): sudo-fallback body-file reader.

    On iso v2 hosts the body file may be owned by an isolated UID
    (``agent-bridge-<a>``, mode 0660 ``ab-agent-<a>``) while the
    controller's bridge-queue.py process runs as the controller UID
    without group membership. Direct ``source.read_bytes()`` then
    raises ``PermissionError``. The pre-existing controller<->iso
    boundary is ``sudo -n -u <owner> cat <path>`` (see
    ``lib/bridge-isolation-helpers.sh``): the controller has
    passwordless sudo to drop to ``agent-bridge-*`` for read-only
    helper ops on iso v2 hosts.

    Returns the file bytes on success, ``None`` on any failure
    (sudo missing, file owner not in the ``agent-bridge-*`` namespace,
    stat refuses, subprocess errors). Caller falls back to the original
    ``PermissionError`` surface so the operator sees a clear failure
    rather than a silent empty body.
    """
    try:
        st = path.stat()
    except OSError:
        return None
    try:
        import pwd as _pwd  # POSIX only; not present on Windows
        ent = _pwd.getpwuid(st.st_uid)
    except (KeyError, ImportError, OSError):
        return None
    owner = ent.pw_name
    # Only attempt the fallback when the owner is an isolated agent UID.
    # The prefix is configurable via BRIDGE_AGENT_OS_USER_PREFIX but
    # defaults to ``agent-bridge-`` everywhere else in the codebase.
    prefix = os.environ.get("BRIDGE_AGENT_OS_USER_PREFIX", "agent-bridge-")
    if not owner.startswith(prefix):
        return None
    # Refuse to attempt sudo when we already are that UID — direct read
    # should have worked; if it didn't, sudo will not save us.
    try:
        if os.geteuid() == st.st_uid:
            return None
    except OSError:
        return None
    # Resolve sudo via PATH first so smoke harnesses can stub the binary
    # without permission to write under /usr/bin. Falls back to the
    # canonical /usr/bin/sudo when PATH lookup fails (e.g. cron context
    # with a minimal PATH).
    import shutil
    sudo_bin = shutil.which("sudo") or "/usr/bin/sudo"
    if not Path(sudo_bin).is_file():
        return None
    try:
        result = subprocess.run(
            [sudo_bin, "-n", "-u", owner, "cat", "--", str(path)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _audit_body_file_sudo_fallback(
            path, owner, success=False, rc=None,
            call_site="bridge-queue.stabilize_body_file",
            exception=exc,
        )
        return None
    if result.returncode != 0:
        _audit_body_file_sudo_fallback(
            path, owner, success=False, rc=result.returncode,
            call_site="bridge-queue.stabilize_body_file",
        )
        return None
    _audit_body_file_sudo_fallback(
        path, owner, success=True, rc=0,
        call_site="bridge-queue.stabilize_body_file",
    )
    return result.stdout


def stabilize_body_file(original: str | None) -> tuple[str | None, str | None]:
    if not original:
        return None, None

    source = Path(original)
    try:
        raw = source.read_bytes()
    except FileNotFoundError as exc:
        raise SystemExit(f"body file disappeared before read: {original}") from exc
    except PermissionError as exc:
        # Issue #1280 (v0.15.0-beta4 Lane J): iso UID-owned body file
        # at mode 0660 cannot be read directly by the controller
        # because group membership is not enough on some POSIX hosts
        # (the controller UID is in ``ab-agent-<a>`` for some agents
        # but not all). Try the sudo-as-owner fallback before failing.
        fallback = _sudo_read_body_file(source)
        if fallback is None:
            raise SystemExit(
                f"failed to read body file {original}: {exc} "
                f"(iso UID may own this file; chmod 0644 or run "
                f"`sudo -u <owner> cat {original}` to verify access)"
            ) from exc
        raw = fallback
    except OSError as exc:
        raise SystemExit(f"failed to read body file {original}: {exc}") from exc

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")

    inline_text: str | None = text if len(raw) <= MAX_INLINE_BODY_BYTES else None
    if not is_ephemeral_body_path(source):
        return inline_text, original

    bodies_dir = get_queue_bodies_dir()
    stem = source.stem or "body"
    suffix = source.suffix or ".md"
    target = bodies_dir / f"{now_ts()}-{os.getpid()}-{stem}{suffix}"
    counter = 0
    while target.exists():
        counter += 1
        target = bodies_dir / f"{now_ts()}-{os.getpid()}-{counter}-{stem}{suffix}"
    target.write_bytes(raw)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass
    return inline_text, str(target)


def normalize_open_status(status: str | None) -> str | None:
    if status is None:
        return None
    normalized = OPEN_STATUS_ALIASES.get(status, status)
    if normalized not in OPEN_STATUSES:
        raise SystemExit(
            f"invalid open task status: {status} "
            f"(choose from {', '.join(OPEN_STATUSES)}; alias in_progress maps to claimed)"
        )
    return normalized


def detect_unexpanded_shell_variable(body_text: str | None) -> str | None:
    if body_text is None:
        return None
    match = UNEXPANDED_SHELL_VAR_RE.search(body_text)
    if not match:
        return None
    return match.group(1)


def emit_event(
    conn: sqlite3.Connection,
    task_id: int,
    *,
    event_type: str,
    actor: str,
    created_ts: int,
    note_text: str | None = None,
    note_path: str | None = None,
    from_agent: str | None = None,
    to_agent: str | None = None,
) -> None:
    conn.execute(
        """
        INSERT INTO task_events (
          task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent),
    )


def touch_agent_activity(conn: sqlite3.Connection, agent: str, activity_ts: int) -> None:
    conn.execute(
        """
        INSERT INTO agent_state (agent, last_seen_ts, session_activity_ts, nudge_fail_count, zombie)
        VALUES (?, ?, ?, 0, 0)
        ON CONFLICT(agent) DO UPDATE SET
          last_seen_ts = CASE
            WHEN agent_state.last_seen_ts IS NULL OR agent_state.last_seen_ts < excluded.last_seen_ts THEN excluded.last_seen_ts
            ELSE agent_state.last_seen_ts
          END,
          session_activity_ts = CASE
            WHEN agent_state.session_activity_ts IS NULL OR agent_state.session_activity_ts < excluded.session_activity_ts THEN excluded.session_activity_ts
            ELSE agent_state.session_activity_ts
          END,
          nudge_fail_count = 0,
          zombie = 0
        """,
        (agent, activity_ts, activity_ts),
    )


def require_task(conn: sqlite3.Connection, task_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        raise SystemExit(f"task not found: {task_id}")
    return row


def task_origin(task: sqlite3.Row) -> str | None:
    """Read the #1792 origin stamp from a task row, tolerating its absence.

    The column is always present after init_db(), but a row materialized from a
    legacy connection (or an explicit column-list SELECT that omits it) would
    raise IndexError on `task["origin"]`; treat that as "no origin".
    """
    try:
        value = task["origin"]
    except (IndexError, KeyError):
        return None
    text = str(value or "").strip()
    return text or None


def priority_sort_sql() -> str:
    return """
      CASE priority
        WHEN 'urgent' THEN 0
        WHEN 'high' THEN 1
        WHEN 'normal' THEN 2
        WHEN 'low' THEN 3
        ELSE 4
      END
    """


def agent_summary_rows(conn: sqlite3.Connection, agents: Iterable[str] | None) -> list[sqlite3.Row]:
    names = [name for name in agents or [] if name]
    params: list[object] = []
    if names:
        values_sql = " UNION ALL ".join(["SELECT ? AS agent"] * len(names))
        params.extend(names)
        base_sql = f"WITH requested AS ({values_sql}) SELECT agent FROM requested"
    else:
        base_sql = """
            SELECT agent FROM agent_state
            UNION
            SELECT assigned_to AS agent FROM tasks
            UNION
            SELECT claimed_by AS agent FROM tasks WHERE claimed_by IS NOT NULL
        """

    sql = f"""
        WITH agent_names AS (
          {base_sql}
        ),
        assigned AS (
          SELECT
            assigned_to AS agent,
            SUM(CASE WHEN status = 'queued' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS queued_count,
            SUM(CASE WHEN status = 'blocked' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS blocked_count
          FROM tasks
          GROUP BY assigned_to
        ),
        claimed AS (
          SELECT claimed_by AS agent, COUNT(*) AS claimed_count
          FROM tasks
          WHERE status = 'claimed' AND claimed_by IS NOT NULL
          GROUP BY claimed_by
        )
        SELECT
          agent_names.agent,
          COALESCE(assigned.queued_count, 0) AS queued_count,
          COALESCE(assigned.blocked_count, 0) AS blocked_count,
          COALESCE(claimed.claimed_count, 0) AS claimed_count,
          COALESCE(agent_state.active, 0) AS active,
          agent_state.last_seen_ts,
          agent_state.last_heartbeat_ts,
          agent_state.session_activity_ts,
          agent_state.last_nudge_ts,
          agent_state.nudge_fail_count,
          agent_state.zombie,
          COALESCE(agent_state.session, '') AS session,
          COALESCE(agent_state.engine, '') AS engine,
          COALESCE(agent_state.workdir, '') AS workdir,
          agent_state.prompt_ready_ts,
          COALESCE(agent_state.prompt_ready_session, '') AS prompt_ready_session,
          COALESCE(agent_state.prompt_ready_source, '') AS prompt_ready_source
        FROM agent_names
        LEFT JOIN assigned ON assigned.agent = agent_names.agent
        LEFT JOIN claimed ON claimed.agent = agent_names.agent
        LEFT JOIN agent_state ON agent_state.agent = agent_names.agent
        ORDER BY agent_names.agent
    """
    return conn.execute(sql, params).fetchall()


def _row_get(row: sqlite3.Row, key: str, default: object = None) -> object:
    """Tolerantly read a column from a sqlite3.Row.

    Older rows (or rows from queries that pre-date a column add) may not
    expose newly added columns. Returning a default keeps the summary path
    backward-compatible during the rolling upgrade.
    """
    try:
        return row[key]
    except (IndexError, KeyError):
        return default


def _latched_idle_seconds(row: sqlite3.Row, current_ts: int) -> int:
    """Compute auto-stop idle seconds with the prompt-ready latch (issue #589).

    Effective anchor = max(session_activity_ts, prompt_ready_ts).
    When no latch has fired yet AND the boot window is still within the
    grace ceiling, idle is reported as 0 — the agent is still booting,
    so it has no pending idle time. Past the grace window without a
    latch, fall back to the legacy session_activity_ts anchor so a
    misconfigured or stuck agent still ages out instead of staying alive
    forever (worst-plausible-regression safety net per spec part D).

    Operators can disable the latch entirely with
    BRIDGE_DAEMON_IDLE_LATCH_DISABLED=1; in that case idle reverts to the
    legacy session_activity_ts anchor.
    """
    activity_ts = int(_row_get(row, "session_activity_ts", 0) or 0)
    last_seen_ts = int(_row_get(row, "last_seen_ts", 0) or 0)
    legacy_anchor = activity_ts or last_seen_ts or 0

    if os.environ.get("BRIDGE_DAEMON_IDLE_LATCH_DISABLED", "0") == "1":
        if not legacy_anchor:
            return -1
        return max(0, current_ts - legacy_anchor)

    prompt_ready_ts = int(_row_get(row, "prompt_ready_ts", 0) or 0)

    try:
        grace = int(os.environ.get("BRIDGE_IDLE_LATCH_GRACE_SECONDS", "3600"))
    except ValueError:
        grace = 3600
    if grace < 0:
        grace = 3600

    if prompt_ready_ts:
        # Latch already fired — anchor on whichever is newer (real activity
        # post-prompt-ready, or the latch itself).
        effective_anchor = max(legacy_anchor, prompt_ready_ts)
        return max(0, current_ts - effective_anchor)

    # No latch yet. If we're still within the boot grace window, suppress
    # idle accumulation — the agent is booting, not idling.
    if legacy_anchor and current_ts - legacy_anchor < grace:
        return 0
    if not legacy_anchor:
        return -1
    # Past the grace window without a latch. Fall back to legacy behavior
    # so a stuck agent eventually times out.
    return max(0, current_ts - legacy_anchor)


def print_summary(rows: list[sqlite3.Row], fmt: str) -> None:
    current_ts = now_ts()
    if fmt == "json":
        payload = []
        for row in rows:
            idle_seconds = _latched_idle_seconds(row, current_ts)
            payload.append(
                {
                    "agent": str(row["agent"] or ""),
                    "queued_count": int(row["queued_count"] or 0),
                    "claimed_count": int(row["claimed_count"] or 0),
                    "blocked_count": int(row["blocked_count"] or 0),
                    "active": int(row["active"] or 0),
                    "idle_seconds": int(idle_seconds),
                    "last_seen_ts": int(row["last_seen_ts"] or 0),
                    "last_nudge_ts": int(row["last_nudge_ts"] or 0),
                    "session": str(row["session"] or ""),
                    "engine": str(row["engine"] or ""),
                    "workdir": str(row["workdir"] or ""),
                    "prompt_ready_ts": int(_row_get(row, "prompt_ready_ts", 0) or 0),
                    "prompt_ready_source": str(_row_get(row, "prompt_ready_source", "") or ""),
                }
            )
        print(json.dumps(payload, ensure_ascii=False))
        return

    if fmt == "tsv":
        for row in rows:
            idle_seconds = _latched_idle_seconds(row, current_ts)
            fields = [
                row["agent"],
                str(row["queued_count"]),
                str(row["claimed_count"]),
                str(row["blocked_count"]),
                str(row["active"]),
                str(idle_seconds),
                str(row["last_seen_ts"] or 0),
                str(row["last_nudge_ts"] or 0),
                row["session"],
                row["engine"],
                row["workdir"],
            ]
            print("\t".join(fields))
        return

    if not rows:
        print("(agent summary empty)")
        return

    print("agent       queued  claimed  blocked  active  idle  session")
    for row in rows:
        idle_seconds = _latched_idle_seconds(row, current_ts)
        idle_label = "-" if idle_seconds < 0 else f"{idle_seconds}s"
        print(
            f"{row['agent']:<10} {row['queued_count']:>6}  {row['claimed_count']:>7}  "
            f"{row['blocked_count']:>7}  {row['active']:>6}  {idle_label:>5}  {row['session'] or '-'}"
        )


def maybe_cancel_cron_run(task: sqlite3.Row, current_ts: int) -> None:
    title = str(task["title"] or "")
    body_path_text = str(task["body_path"] or "").strip()
    if "[cron-dispatch]" not in title and "cron-dispatch" not in body_path_text:
        return

    run_id = Path(body_path_text).stem
    if not run_id:
        return

    run_dir = get_cron_state_dir() / "runs" / run_id
    request_path = run_dir / "request.json"
    result_path = run_dir / "result.json"
    status_path = run_dir / "status.json"

    request: dict[str, object] = {}
    status: dict[str, object] = {}
    if request_path.is_file():
        try:
            request = json.loads(request_path.read_text(encoding="utf-8"))
        except Exception:
            request = {}
    if status_path.is_file():
        try:
            status = json.loads(status_path.read_text(encoding="utf-8"))
        except Exception:
            status = {}

    payload = {
        "run_id": run_id,
        "state": "cancelled",
        "engine": str(status.get("engine") or request.get("target_engine") or ""),
        "updated_at": datetime.fromtimestamp(current_ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
        "request_file": str(status.get("request_file") or request.get("request_file") or request_path),
        "result_file": str(status.get("result_file") or request.get("result_file") or result_path),
        "error": "cancelled via task queue",
    }

    status_path.parent.mkdir(parents=True, exist_ok=True)
    status_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def _safe_run_id(value: str) -> bool:
    # A run_id is a SINGLE directory name under runs/, so it must not traverse
    # out of it. Allow [A-Za-z0-9._-] but explicitly reject the dot-only
    # segments `.` / `..` (which pass the char allowlist yet are path
    # traversal). Mirrors bridge-cron-runner._safe_agent_id + adds the dot guard.
    if not value or value in (".", ".."):
        return False
    return all(ch.isalnum() or ch in "._-" for ch in value)


def _trusted_cron_state_dir() -> Path:
    """Resolve the cron state dir from a TRUSTED anchor, not caller env (#1792).

    The state dir of the runtime being written is the parent of the actual task
    DB (`get_db_path().parent`) — a spoofer who redirects that is writing into a
    queue they already own. The cron state dir is normally `<state>/cron`, but
    an operator can legitimately relocate it; `lib/bridge-cron.sh` records the
    authoritative path in `<state>/cron-state-dir-anchor.txt`. We read that
    anchor from the DB's own dir (NOT via the caller-settable
    BRIDGE_CRON_STATE_DIR / BRIDGE_STATE_DIR env), so a legit relocated install
    still verifies while a caller cannot redirect the lookup. Fall back to
    `<state>/cron` when no anchor is present.
    """
    state_dir = get_db_path().parent
    anchor_file = state_dir / "cron-state-dir-anchor.txt"
    try:
        recorded = anchor_file.read_text(encoding="utf-8").splitlines()[0].strip()
    except (OSError, IndexError):
        recorded = ""
    if recorded:
        return Path(recorded).expanduser()
    return state_dir / "cron"


def verified_cron_run_id(claimed_run_id: str) -> str | None:
    """Return the claimed cron run id ONLY if it maps to a live run record.

    #1792 P1: BRIDGE_CRON_RUN_ID is a process-env value. On the direct path any
    process can set it; on the gateway path a non-cron client can forward its
    own env value. Either way the queue must not stamp `cron:<id>` on a caller's
    say-so — that would let any process impersonate a cron child in the
    attribution trail.

    We re-derive provenance from the cron runtime's own ground truth:
    `<state>/cron/runs/<run_id>/status.json` must exist, name the same run id,
    and report a live `state` (`running`).

    The state root is anchored to the directory of the ACTUAL task DB being
    written (`get_db_path().parent`), NOT to the separately-overridable
    `BRIDGE_CRON_STATE_DIR` / `BRIDGE_STATE_DIR` env (codex P2): otherwise a
    caller could set `BRIDGE_CRON_RUN_ID` AND point the cron-state env at a
    self-owned dir holding a fake running record and verify its own spoof. By
    tying the lookup to the same DB the create lands in, a spoofer who
    redirects the DB is only writing into a queue they already fully own (the
    attribution stays internally consistent), and one who keeps the real DB can
    no longer relocate the ground-truth lookup.

    The realistic spoof this closes: a non-cron caller (direct or via a gateway
    client forwarding its own env) cannot point the lookup at a fake record (the
    anchor is trusted) and cannot fabricate a `running` record under the
    controller-owned cron run tree (mode 0700 run dirs the caller's UID cannot
    write on the multi-user/iso hosts where this matters). A residual remains
    for a caller that can already READ the controller's run dir to learn a
    currently-`running` run id — but that read is exactly what the 0700 boundary
    denies, and origin is attribution metadata, NOT authorization (the queue
    still trusts `--from`), so we deliberately do not escalate to a per-dispatch
    secret (a secret can only reach the child via env, and the iso sudo/shell
    launch serializes env into world-readable argv — exposing the secret would
    be a net regression). See the PR follow-up note.

    Anything indeterminate — bad/dotted shape, missing record, unreadable dir,
    non-running state, run-id mismatch — returns None (the conservative branch:
    drop the cron stamp, fall back to session/legacy origin). Attribution
    metadata only; never gates the create.
    """
    claimed = (claimed_run_id or "").strip()
    if not claimed or not _safe_run_id(claimed):
        return None
    cron_dir = _trusted_cron_state_dir()
    status_file = cron_dir / "runs" / claimed / "status.json"
    # Defense in depth: the resolved path must stay strictly under runs/ even if
    # a future change loosens _safe_run_id (no escape via symlink/.. residue).
    runs_root = (cron_dir / "runs").resolve()
    try:
        resolved = status_file.resolve()
        resolved.relative_to(runs_root)
    except (OSError, ValueError):
        return None
    try:
        payload = json.loads(status_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    # The record's own run_id must match the claim so a symlinked/renamed dir
    # cannot launder a different run's liveness onto this id.
    if str(payload.get("run_id") or "").strip() != claimed:
        return None
    if str(payload.get("state") or "").strip() != "running":
        return None
    return claimed


def resolve_origin() -> str | None:
    """Attribution stamp for a freshly-created task (Issue #1792).

    Returns a short, prefixed marker of the creating context — or None when no
    origin signal is visible (legacy shape; the column stays NULL). This is
    metadata only: it is recorded alongside the caller-asserted `created_by`
    but never used for authorization.

    - `cron:<run_id>` — a cron-dispatched child, but ONLY when the claimed
      BRIDGE_CRON_RUN_ID is proven against the cron runtime's ground truth
      (verified_cron_run_id). An unverifiable claim is NOT stamped as cron —
      it falls through to the session check, so a non-cron process that set
      BRIDGE_CRON_RUN_ID in its own env cannot mint a cron origin (#1792 P1).
    - `session:<id>` — an interactive engine session whose id is visible in the
      environment (CLAUDE_CODE_SESSION_ID etc.). Cron children never reach this
      branch: the runner scrubs those vars before dispatch.
    """
    claimed_run_id = os.environ.get("BRIDGE_CRON_RUN_ID", "").strip()
    verified = verified_cron_run_id(claimed_run_id)
    if verified:
        return f"cron:{verified}"
    if claimed_run_id:
        # A claim was present but could not be proven against the cron runtime
        # ground truth — surface it for operator triage (the spoof signal),
        # then fall through to the conservative session/legacy origin.
        print(
            f"queue audit=warn reason_code=rejected_unverifiable_cron_run_id "
            f"claimed_run_id={claimed_run_id}",
            file=sys.stderr,
        )
    for key in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "ANTHROPIC_SESSION_ID"):
        session_id = os.environ.get(key, "").strip()
        if session_id:
            return f"session:{session_id}"
    return None


def cmd_create(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    # Rooms ACL (P1b): gate the inter-agent create on shared-room membership
    # when rooms_acl=enforce. No-op when off / no rooms / exempt (default-off
    # is a true no-op). The actor used for the decision is OS-derived (the
    # gateway-rewritten --from under the gateway-server, else resolve_os_actor)
    # — never a raw client --from/BRIDGE_AGENT_ID.
    _rooms_acl_check_create(actor, args.assigned_to)
    body_path = normalize_path(args.body_file)
    body_text = args.body
    created_ts = now_ts()

    if body_text is not None:
        shell_var = detect_unexpanded_shell_variable(body_text)
        if shell_var:
            print(
                f'warning: --body contains unexpanded shell variable "{shell_var}" - '
                "did you forget to export it, or should you use --body-file?",
                file=sys.stderr,
            )
        if not args.allow_empty_body and not body_text.strip():
            raise SystemExit(
                "empty --body after trimming whitespace; omit --body, use --body-file, "
                "or pass --allow-empty-body"
            )

    if body_path is not None:
        inline_text, body_path = stabilize_body_file(body_path)
        if body_text is None:
            body_text = inline_text

    origin = resolve_origin()

    with closing(connect()) as conn, conn:
        cursor = conn.execute(
            """
            INSERT INTO tasks (
              title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path, origin
            ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)
            """,
            (
                args.title.strip(),
                args.assigned_to,
                actor,
                args.priority,
                created_ts,
                created_ts,
                body_text,
                body_path,
                origin,
            ),
        )
        task_id = int(cursor.lastrowid)
        emit_event(
            conn,
            task_id,
            event_type="created",
            actor=actor,
            created_ts=created_ts,
            note_text=body_text,
            note_path=body_path,
            to_agent=args.assigned_to,
        )

    if args.format == "shell":
        fields = {
            "TASK_ID": task_id,
            "TASK_TITLE": args.title.strip(),
            "TASK_ASSIGNED_TO": args.assigned_to,
            "TASK_CREATED_BY": actor,
            "TASK_PRIORITY": args.priority,
            "TASK_BODY_PATH": body_path or "",
            "TASK_BODY_TEXT": body_text or "",
            "TASK_ORIGIN": origin or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"created task #{task_id} for {args.assigned_to} [{args.priority}] {args.title.strip()}")
    return 0


def cmd_upsert_open(args: argparse.Namespace) -> int:
    # Issue #1408: atomic refresh-or-create for daemon-generated recurring
    # alerts (A2A outbox-stuck, unclaimed-task escalation). A shell
    # find-open-then-update/create sequence races between daemon ticks and
    # bypasses the single-writer contract; this routes both families through
    # the same upsert_open_task() the blocked-aging family uses.
    #
    # DEDUPE CONTRACT (#1425): the re-bind is via find_open_task_by_prefix(),
    # which matches OPEN statuses only (queued/claimed/blocked). `claim`
    # HOLDS dedupe — a claimed row still matches the prefix lookup, so the
    # next scan refreshes it instead of minting a new id. `done` RELEASES it
    # — a closed row drops out of the lookup, so if the underlying condition
    # is still live the next scan mints a FRESH task-id and re-nudges. For a
    # genuinely-stuck peer, `claim` (or leave the row open) rather than `done`
    # until the condition is actually resolved. See KNOWN_ISSUES.md §30.
    #
    # ATOMICITY (codex r1 BLOCKING): upsert_open_task() does a SELECT
    # (find_open_task_by_prefix) and only then an INSERT-or-UPDATE. Python's
    # sqlite3 in its default isolation mode does NOT take a write lock before a
    # SELECT, and WAL allows concurrent readers, so two simultaneous ticks
    # could both miss the row and both INSERT — the exact race we are closing.
    # There is no unique-key on the open-alert prefix in the shared `tasks`
    # schema (adding one is a riskier migration). So we acquire the RESERVED
    # write lock with an explicit `BEGIN IMMEDIATE` BEFORE the SELECT, which
    # serializes concurrent upserts against this and every other queue writer.
    # `busy_timeout` makes a contending writer wait rather than fail, and we
    # retry a bounded number of times on the rare residual "database is locked".
    actor = args.actor or os.environ.get("USER", "unknown")  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; not an isolated-artifact reference
    body_text = args.body
    if args.body_file is not None:
        inline_text, _stable_path = stabilize_body_file(normalize_path(args.body_file))
        body_text = inline_text
    if body_text is None:
        body_text = ""

    attempts = 0
    max_attempts = 5
    while True:
        attempts += 1
        current_ts = now_ts()
        with closing(connect()) as conn:
            conn.execute("PRAGMA busy_timeout=5000")
            try:
                # BEGIN IMMEDIATE is inside the try so a lock timeout while
                # ACQUIRING the RESERVED lock is also covered by the retry
                # ladder (codex r2 nit), not just contention during the write.
                conn.execute("BEGIN IMMEDIATE")
                task_id, created = upsert_open_task(
                    conn,
                    agent=args.assigned_to,
                    title_prefix=args.title_prefix,
                    title=args.title.strip(),
                    priority=args.priority,
                    actor=actor,
                    body_text=body_text,
                    current_ts=current_ts,
                    refresh_note=args.refresh_note or "daemon refreshed recurring alert",
                )
                conn.commit()
            except sqlite3.OperationalError as exc:
                conn.rollback()
                if "locked" in str(exc).lower() and attempts < max_attempts:
                    continue
                raise
            except BaseException:
                conn.rollback()
                raise
        break

    if args.format == "shell":
        print(f"TASK_ID={shlex.quote(str(task_id))}")
        print(f"TASK_CREATED={shlex.quote('1' if created else '0')}")
        return 0

    verb = "created" if created else "refreshed"
    print(f"{verb} task #{task_id} for {args.assigned_to} [{args.priority}] {args.title.strip()}")
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    statuses = list(args.status or [])
    if args.all:
        statuses = list(STATUS_CHOICES)
    if not statuses:
        statuses = list(OPEN_STATUSES)

    placeholders = ",".join(["?"] * len(statuses))
    params: list[object] = [args.agent, *statuses]
    sql = f"""
        SELECT id, status, priority, title, updated_ts, created_by, claimed_by, body_path
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
        ORDER BY {priority_sort_sql()}, CASE status WHEN 'claimed' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, id
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, params).fetchall()

    if not rows:
        print(f"(inbox empty for {args.agent})")
        return 0

    print(f"inbox: {args.agent}")
    print("id  status   priority  owner      title")
    for row in rows:
        owner = row["claimed_by"] or row["created_by"]
        print(f"{row['id']:<3} {row['status']:<8} {row['priority']:<8} {owner:<10} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        task = require_task(conn, args.task_id)
        events = conn.execute(
            """
            SELECT event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
            FROM task_events
            WHERE task_id = ?
            ORDER BY id
            """,
            (args.task_id,),
        ).fetchall()

    origin = task_origin(task)

    if args.format == "shell":
        fields = {
            "TASK_ID": task["id"],
            "TASK_TITLE": task["title"],
            "TASK_STATUS": task["status"],
            "TASK_ASSIGNED_TO": task["assigned_to"],
            "TASK_CREATED_BY": task["created_by"],
            "TASK_PRIORITY": task["priority"],
            "TASK_CLAIMED_BY": task["claimed_by"] or "",
            "TASK_BODY_PATH": task["body_path"] or "",
            "TASK_ORIGIN": origin or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"task #{task['id']}: {task['title']}")
    print(f"status: {task['status']}")
    print(f"assigned_to: {task['assigned_to']}")
    print(f"created_by: {task['created_by']}")
    if origin:
        print(f"origin: {origin}")
    print(f"priority: {task['priority']}")
    print(f"created_at: {isoformat_ts(task['created_ts'])}")
    print(f"updated_at: {isoformat_ts(task['updated_ts'])}")
    print(f"claimed_by: {task['claimed_by'] or '-'}")
    print(f"lease_until: {isoformat_ts(task['lease_until_ts'])}")
    if task["body_text"]:
        print("body:")
        print(task["body_text"])
    if task["body_path"]:
        print(f"body_file: {task['body_path']}")
    print("")
    print("events:")
    for event in events:
        transfer = ""
        if event["from_agent"] or event["to_agent"]:
            transfer = f" ({event['from_agent'] or '-'} -> {event['to_agent'] or '-'})"
        print(f"- {isoformat_ts(event['created_ts'])} {event['event_type']} by {event['actor']}{transfer}")
        if event["note_text"]:
            print(f"  note: {event['note_text']}")
        if event["note_path"]:
            print(f"  file: {event['note_path']}")
    return 0


def cmd_find_open(args: argparse.Namespace) -> int:
    # PR1.7 — `--mode` selector for the cron-followup dedupe contract.
    #   refresh-by-job (default): the existing prefix-match behavior. Used
    #     by `delivery_intent=main_session_only` so consecutive runs
    #     refresh a single open task ("current state of this monitor").
    #   per-run: always returns nothing. Used by
    #     `delivery_intent=forward_to_user` so each distinct human-facing
    #     alert gets its own task and never overwrites an unread one.
    mode = getattr(args, "mode", "refresh-by-job") or "refresh-by-job"
    if mode == "per-run":
        if getattr(args, "all", False):
            print(json.dumps([], ensure_ascii=False))
        return 1

    # Issue #1199: default open set is queued|claimed|blocked (back-compat).
    # --status-filter narrows it so the ACTION REQUIRED "Highest priority"
    # line can be restricted to genuinely-queued tasks. De-dup while
    # preserving caller order; fall back to the full open set when omitted.
    status_filter = getattr(args, "status_filter", None)
    if status_filter:
        seen: set[str] = set()
        statuses = [s for s in status_filter if not (s in seen or seen.add(s))]
    else:
        statuses = ["queued", "claimed", "blocked"]

    params: list[object] = [args.agent]
    placeholders = ", ".join("?" for _ in statuses)
    sql = f"""
        SELECT *
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
    """
    params.extend(statuses)
    if args.title_prefix:
        sql += " AND title LIKE ?"
        params.append(f"{args.title_prefix}%")
    for excluded_prefix in getattr(args, "exclude_title_prefix", []) or []:
        if excluded_prefix:
            sql += " AND title NOT LIKE ?"
            params.append(f"{excluded_prefix}%")
    sql += """
        ORDER BY
          CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high'   THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low'    THEN 3
            ELSE 4
          END,
          id
    """
    if not getattr(args, "all", False):
        sql += " LIMIT 1"

    with closing(connect()) as conn:
        rows = conn.execute(sql, params).fetchall()

    if getattr(args, "all", False):
        payload = [
            {
                "id": int(r["id"]),
                "title": str(r["title"] or ""),
                "status": str(r["status"] or ""),
                "assigned_to": str(r["assigned_to"] or ""),
                "created_by": str(r["created_by"] or ""),
                "priority": str(r["priority"] or ""),
                "claimed_by": str(r["claimed_by"] or ""),
                "body_path": str(r["body_path"] or ""),
                "created_ts": int(r["created_ts"] or 0),
                "updated_ts": int(r["updated_ts"] or 0),
            }
            for r in rows
        ]
        print(json.dumps(payload, ensure_ascii=False))
        return 0 if payload else 1

    row = rows[0] if rows else None
    if row is None:
        return 1

    if args.format == "json":
        print(
            json.dumps(
                {
                    "id": int(row["id"]),
                    "title": str(row["title"] or ""),
                    "status": str(row["status"] or ""),
                    "assigned_to": str(row["assigned_to"] or ""),
                    "created_by": str(row["created_by"] or ""),
                    "priority": str(row["priority"] or ""),
                    "claimed_by": str(row["claimed_by"] or ""),
                    "body_path": str(row["body_path"] or ""),
                    # #9780: surface updated_ts on the single-row JSON so the
                    # Stop inbox-drain loop guard can key on id+status+updated_ts
                    # (a status/timestamp change resets the guard).
                    "updated_ts": int(row["updated_ts"] or 0),
                },
                ensure_ascii=False,
            )
        )
        return 0

    if args.format == "shell":
        fields = {
            "TASK_ID": row["id"],
            "TASK_TITLE": row["title"],
            "TASK_STATUS": row["status"],
            "TASK_ASSIGNED_TO": row["assigned_to"],
            "TASK_CREATED_BY": row["created_by"],
            "TASK_PRIORITY": row["priority"],
            "TASK_CLAIMED_BY": row["claimed_by"] or "",
            "TASK_BODY_PATH": row["body_path"] or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    if args.format == "id":
        print(row["id"])
        return 0

    print(f"task #{row['id']}: {row['title']}")
    print(f"status: {row['status']}")
    print(f"assigned_to: {row['assigned_to']}")
    print(f"priority: {row['priority']}")
    if row["body_path"]:
        print(f"body_file: {row['body_path']}")
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    agent = args.agent
    lease_seconds = int(args.lease_seconds)
    current_ts = now_ts()
    lease_until_ts = current_ts + lease_seconds
    # Issue #1253 — optional --note / --note-file mirror `done` / `update`
    # so claim-time audit context lands in the task_events log alongside
    # the canonical `event_type=claimed` row.
    note_text = getattr(args, "note", None)
    note_path = normalize_path(getattr(args, "note_file", None))

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "claimed" and task["claimed_by"] == agent:
            conn.execute(
                "UPDATE tasks SET lease_until_ts = ? WHERE id = ?",
                (lease_until_ts, args.task_id),
            )
            touch_agent_activity(conn, agent, current_ts)
            print(f"task #{args.task_id} already claimed by {agent}; lease extended")
            return 0

        if task["status"] != "queued":
            raise SystemExit(f"task #{args.task_id} is not claimable (status={task['status']})")
        if task["assigned_to"] != agent:
            raise SystemExit(f"task #{args.task_id} is assigned to {task['assigned_to']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'claimed',
                claimed_by = ?,
                claimed_ts = ?,
                lease_until_ts = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (agent, current_ts, lease_until_ts, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="claimed",
            actor=agent,
            created_ts=current_ts,
            note_text=note_text,
            note_path=note_path,
            to_agent=agent,
        )
        touch_agent_activity(conn, agent, current_ts)

    # Echo a short `claim_note=<n-chars>` summary on stdout so scripts /
    # operator-readable transcripts can confirm the note actually landed
    # in the event log (per #1253 acceptance criteria).
    note_summary = ""
    if note_text is not None:
        note_summary = f" claim_note={len(note_text)}c"
    elif note_path:
        note_summary = f" claim_note=file:{note_path}"
    print(f"claimed task #{args.task_id} as {agent} (lease={lease_seconds}s){note_summary}")
    return 0


def cmd_done(args: argparse.Namespace) -> int:
    agent = args.agent
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "done":
            print(f"task #{args.task_id} already done")
            return 0
        if task["assigned_to"] != agent and task["claimed_by"] not in (None, agent):
            raise SystemExit(f"task #{args.task_id} is owned by {task['claimed_by']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'done',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?,
                closed_ts = ?
            WHERE id = ?
            """,
            (current_ts, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="done",
            actor=agent,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=agent,
            to_agent=task["assigned_to"],
        )
        touch_agent_activity(conn, agent, current_ts)

    print(f"completed task #{args.task_id} as {agent}")
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: even if the gateway authorizer is wrong,
            # the server refuses to cancel a task the actor does not own.
            _gateway_server_authorize(task, actor, "cancel")
        if task["status"] == "cancelled":
            print(f"task #{args.task_id} already cancelled")
            return 0
        if task["status"] == "done":
            raise SystemExit(f"task #{args.task_id} is already closed (status=done)")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'cancelled',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?,
                closed_ts = ?
            WHERE id = ?
            """,
            (current_ts, current_ts, args.task_id),
        )
        maybe_cancel_cron_run(task, current_ts)
        emit_event(
            conn,
            args.task_id,
            event_type="cancelled",
            actor=actor,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=task["claimed_by"] or task["assigned_to"],
            to_agent=task["assigned_to"],
        )

    print(f"cancelled task #{args.task_id} as {actor}")
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.body_file)
    stabilized_text: str | None = None
    if note_path is not None:
        stabilized_text, note_path = stabilize_body_file(note_path)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: refuse to mutate a task the actor does
            # not own, even if the gateway authorizer was wrong.
            _gateway_server_authorize(task, actor, "update")
        if task["status"] in ("done", "cancelled"):
            raise SystemExit(f"task #{args.task_id} is already closed (status={task['status']})")

        title = args.title.strip() if args.title is not None else task["title"]
        priority = args.priority or task["priority"]
        status = normalize_open_status(args.status) or task["status"]
        body_text = task["body_text"]
        body_path = task["body_path"]

        if args.body is not None:
            body_text = args.body
            body_path = None
        elif args.body_file is not None:
            body_text = stabilized_text
            body_path = note_path

        conn.execute(
            """
            UPDATE tasks
            SET title = ?,
                priority = ?,
                status = ?,
                body_text = ?,
                body_path = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (title, priority, status, body_text, body_path, current_ts, args.task_id),
        )
        event_note = args.body or args.note
        emit_event(
            conn,
            args.task_id,
            event_type="updated",
            actor=actor,
            created_ts=current_ts,
            note_text=event_note,
            note_path=note_path,
            to_agent=task["assigned_to"],
        )

    print(f"updated task #{args.task_id}")
    return 0


def cmd_handoff(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: refuse to hand off a task the actor does
            # not own. The gateway only allows assigned_to/claimed_by to
            # hand off; this re-check accepts created_by too because the
            # task creator can also redirect their own work — narrower
            # than the gateway's policy is fine, broader is not.
            owners = {
                str(task["assigned_to"] or ""),
                str(task["claimed_by"] or ""),
            }
            owners.discard("")
            if actor not in owners:
                raise SystemExit(
                    f"queue gateway server denied handoff: actor {actor!r} is not "
                    f"the assignee or claimer of task #{task['id']}"
                )
        if task["status"] in ("done", "cancelled"):
            raise SystemExit(f"task #{args.task_id} is already closed (status={task['status']})")

        conn.execute(
            """
            UPDATE tasks
            SET assigned_to = ?,
                status = 'queued',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?
            WHERE id = ?
            """,
            (args.assigned_to, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="handoff",
            actor=actor,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=task["assigned_to"],
            to_agent=args.assigned_to,
        )

    print(f"handed off task #{args.task_id} to {args.assigned_to}")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        rows = agent_summary_rows(conn, args.agent)
    print_summary(rows, args.format)
    return 0


_COMPANION_FOCUS_HEADINGS = (
    "## focus checklist",
    "## focus list",
    "## focus",
    "### focus",
    "focus checklist:",
    "focus list:",
)
_COMPANION_OUTPUT_TOKENS = (
    "plan-ok",
    "implement-ok",
    "needs-more",
    "expected output",
)


def companion_title_prefix_match(title: str) -> bool:
    """Return True iff the title's first bracket matches a companion-role prefix.

    Matches `[plan]`, `[review]`, `[review r2]`, `[review r3]`, etc. Anything
    after the first whitespace following the bracket is the subject and is
    ignored. Case-insensitive.
    """
    stripped = (title or "").strip().lower()
    if not stripped.startswith("["):
        return False
    end = stripped.find("]")
    if end <= 0:
        return False
    inner = stripped[1:end].strip()
    if not inner:
        return False
    head = inner.split(None, 1)[0]
    return head in {"plan", "review"}


def companion_body_missing_sections(body_text: str) -> list[str]:
    """Return the list of missing companion-role brief sections.

    A companion-role review brief must contain (a) a focus checklist (or
    focus list / focus heading) AND (b) an explicit expected-output mention
    naming `plan-ok`, `implement-ok`, `needs-more`, or "expected output".
    Returns an empty list if both are present, otherwise the missing names.
    """
    missing: list[str] = []
    haystack = (body_text or "").lower()
    if not any(token in haystack for token in _COMPANION_FOCUS_HEADINGS):
        missing.append("focus checklist")
    if not any(token in haystack for token in _COMPANION_OUTPUT_TOKENS):
        missing.append("expected output shape")
    return missing


def cmd_validate_companion_body(args: argparse.Namespace) -> int:
    """Pure validator helper: prefix + body → OK or structured missing-list.

    Roster awareness lives in the shell caller (`bridge-task.sh cmd_create`),
    which knows the recipient engine/class. This helper is engine-agnostic
    and can be invoked from smoke tests directly.

    Exit codes:
      0 — body validates (or title prefix is not a companion-role prefix)
      2 — body is missing required sections
      1 — usage / IO error
    """
    title = args.title or ""
    body_text = ""
    if args.body_file:
        try:
            body_text = Path(args.body_file).expanduser().read_text(encoding="utf-8")
        except OSError as exc:
            print(f"error: cannot read body file: {exc}", file=sys.stderr)
            return 1
    elif args.body is not None:
        body_text = args.body
    else:
        body_text = sys.stdin.read() if not sys.stdin.isatty() else ""

    if not companion_title_prefix_match(title):
        if args.format == "json":
            print(json.dumps({"status": "skip", "reason": "title-not-companion-prefix"}))
        else:
            print("skip: title prefix is not a companion-role prefix")
        return 0

    missing = companion_body_missing_sections(body_text)
    if not missing:
        if args.format == "json":
            print(json.dumps({"status": "ok"}))
        else:
            print("ok")
        return 0

    payload = {
        "status": "missing",
        "missing": missing,
        "title": title.strip(),
    }
    if args.format == "json":
        print(json.dumps(payload))
    else:
        print(f"missing: {', '.join(missing)}", file=sys.stderr)
    return 2


def cmd_cron_ready(args: argparse.Namespace) -> int:
    limit = max(0, int(args.limit))
    scan_limit = max(limit, int(args.scan_limit))
    if limit <= 0:
        return 0

    # SQL LIMIT used to be the worker-slot count. That let one deferred
    # memory-daily row hide later runnable cron-dispatch rows when the daemon
    # was configured with BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1.
    sql = """
        SELECT id, assigned_to, priority, title, body_path, created_ts
        FROM tasks
        WHERE status = 'queued'
          AND title LIKE '[cron-dispatch]%'
        ORDER BY id
        LIMIT ?
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, (scan_limit,)).fetchall()

    status_by_agent = load_roster_status(args.status_snapshot) if args.status_snapshot else {}
    defer_seconds = max(0, int(args.memory_daily_defer_seconds))
    current_ts = now_ts()
    ranked_rows = []
    for row in rows:
        family = dispatch_task_family(row)
        agent_state = status_by_agent.get(str(row["assigned_to"]), {})
        active = str(agent_state.get("active") or "0") == "1"
        activity_state = str(agent_state.get("activity_state") or ("idle" if not active else "working")).strip() or (
            "idle" if not active else "working"
        )
        created_ts = int(row["created_ts"] or current_ts)
        age_seconds = max(0, current_ts - created_ts)

        if family == "memory-daily" and active and activity_state == "working" and age_seconds < defer_seconds:
            continue

        rank = 1
        if family == "memory-daily":
            rank = 0 if (not active or activity_state != "working") else 2
        ranked_rows.append((rank, int(row["id"]), row))

    rows = [row for _, _, row in sorted(ranked_rows, key=lambda item: (item[0], item[1]))][:limit]

    if args.format == "tsv":
        for row in rows:
            print(
                "\t".join(
                    [
                        str(row["id"]),
                        str(row["assigned_to"]),
                        str(row["priority"]),
                        str(row["title"]),
                        str(row["body_path"] or ""),
                    ]
                )
            )
        return 0

    if not rows:
        print("(no queued cron-dispatch tasks)")
        return 0

    print("id  assigned_to  priority  title")
    for row in rows:
        print(f"{row['id']:<3} {row['assigned_to']:<11} {row['priority']:<8} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def load_snapshot(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("agent"):
                rows.append(row)
    return rows


def load_roster_status(path: str) -> dict[str, dict[str, str]]:
    rows: dict[str, dict[str, str]] = {}
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            agent = str(row.get("agent") or "").strip()
            if agent:
                rows[agent] = row
    return rows


def cmd_cron_backlog_snapshot(args: argparse.Namespace) -> int:
    # Issue #1459 — queue-GLOBAL oldest queued [cron-dispatch] row + count.
    #
    # The daemon's cron-dispatch backlog sweep needs the oldest queued cron
    # row across ALL agents (cron rows can be assigned to any agent), which
    # `find-open --agent <a>` cannot express. `cron-ready` is global but
    # ranks/defers and drops created_ts. This single-purpose read returns
    # exactly the backlog snapshot fields the sweep audits on, with no
    # ranking/deferral (a backlog audit must see the true oldest row).
    sql = """
        SELECT id, assigned_to, priority, title, created_ts
        FROM tasks
        WHERE status = 'queued'
          AND title LIKE '[cron-dispatch]%'
        ORDER BY created_ts, id
    """
    with closing(connect()) as conn:
        rows = conn.execute(sql).fetchall()

    current_ts = now_ts()
    queued_count = len(rows)
    payload: dict[str, object] = {
        "queued_count": queued_count,
        "oldest_task_id": 0,
        "oldest_age_seconds": 0,
        "oldest_agent": "",
        "oldest_title": "",
        "oldest_family": "",
    }
    if rows:
        oldest = rows[0]
        created = int(oldest["created_ts"] or current_ts)
        payload.update(
            {
                "oldest_task_id": int(oldest["id"]),
                "oldest_age_seconds": max(0, current_ts - created),
                "oldest_agent": str(oldest["assigned_to"] or ""),
                "oldest_title": str(oldest["title"] or ""),
                "oldest_family": classify_family(str(oldest["title"] or "")),
            }
        )

    if getattr(args, "format", "json") == "tsv":
        print(
            "\t".join(
                [
                    str(payload["oldest_task_id"]),
                    str(payload["oldest_age_seconds"]),
                    str(payload["queued_count"]),
                    str(payload["oldest_title"]),
                    str(payload["oldest_family"]),
                    str(payload["oldest_agent"]),
                ]
            )
        )
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


def dispatch_task_family(row: sqlite3.Row) -> str:
    body_path = str(row["body_path"] or "").strip()
    if body_path and os.path.isfile(body_path):
        try:
            with open(body_path, "r", encoding="utf-8", errors="replace") as handle:
                for _index, line in enumerate(handle):
                    if _index > 40:
                        break
                    if line.startswith("- family:"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return classify_family(str(row["title"] or ""))


def latest_event_ts(conn: sqlite3.Connection, task_id: int, event_type: str) -> int:
    row = conn.execute(
        """
        SELECT MAX(created_ts) AS created_ts
        FROM task_events
        WHERE task_id = ? AND event_type = ?
        """,
        (task_id, event_type),
    ).fetchone()
    if not row:
        return 0
    value = row["created_ts"]
    return int(value or 0)


def find_open_task_by_prefix(conn: sqlite3.Connection, agent: str, title_prefix: str) -> sqlite3.Row | None:
    # Dedupe lookup for recurring daemon alerts (upsert-open) and the
    # blocked-aging reminder/escalation upserts. Matches OPEN_STATUSES only
    # (queued/claimed/blocked) — a `done` row is intentionally NOT matched.
    # Consequence (#1425): `claim` holds dedupe (the row still matches, so the
    # next scan re-binds the same task-id); `done` releases it (a fresh id is
    # minted on the next scan if the condition is still live). Do NOT widen
    # this to a recent-`done` window here — it is shared by the blocked-aging
    # upserts, so that would change close semantics outside daemon alerts.
    # See KNOWN_ISSUES.md §30.
    placeholders = ",".join(["?"] * len(OPEN_STATUSES))
    params: list[object] = [agent, *OPEN_STATUSES, f"{title_prefix}%"]
    return conn.execute(
        f"""
        SELECT *
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
          AND title LIKE ?
        ORDER BY
          CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high'   THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low'    THEN 3
            ELSE 4
          END,
          id
        LIMIT 1
        """,
        params,
    ).fetchone()


def create_queue_task(
    conn: sqlite3.Connection,
    *,
    title: str,
    assigned_to: str,
    actor: str,
    priority: str,
    created_ts: int,
    body_text: str | None = None,
    body_path: str | None = None,
) -> int:
    cursor = conn.execute(
        """
        INSERT INTO tasks (
          title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path
        ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?)
        """,
        (
            title,
            assigned_to,
            actor,
            priority,
            created_ts,
            created_ts,
            body_text,
            body_path,
        ),
    )
    task_id = int(cursor.lastrowid)
    emit_event(
        conn,
        task_id,
        event_type="created",
        actor=actor,
        created_ts=created_ts,
        note_text=body_text,
        note_path=body_path,
        to_agent=assigned_to,
    )
    return task_id


def refresh_queue_task(
    conn: sqlite3.Connection,
    *,
    task_id: int,
    title: str,
    priority: str,
    actor: str,
    updated_ts: int,
    body_text: str | None,
    note_text: str,
) -> None:
    conn.execute(
        """
        UPDATE tasks
        SET title = ?,
            priority = ?,
            body_text = ?,
            body_path = NULL,
            updated_ts = ?
        WHERE id = ?
        """,
        (title, priority, body_text, updated_ts, task_id),
    )
    emit_event(
        conn,
        task_id,
        event_type="updated",
        actor=actor,
        created_ts=updated_ts,
        note_text=note_text,
    )


def upsert_open_task(
    conn: sqlite3.Connection,
    *,
    agent: str,
    title_prefix: str,
    title: str,
    priority: str,
    actor: str,
    body_text: str,
    current_ts: int,
    refresh_note: str,
) -> tuple[int, bool]:
    existing = find_open_task_by_prefix(conn, agent, title_prefix)
    if existing:
        refresh_queue_task(
            conn,
            task_id=int(existing["id"]),
            title=title,
            priority=priority,
            actor=actor,
            updated_ts=current_ts,
            body_text=body_text,
            note_text=refresh_note,
        )
        return int(existing["id"]), False

    task_id = create_queue_task(
        conn,
        title=title,
        assigned_to=agent,
        actor=actor,
        priority=priority,
        created_ts=current_ts,
        body_text=body_text,
    )
    return task_id, True


def format_task_age(seconds: int) -> str:
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def blocked_reminder_title(task_id: int) -> str:
    return f"{BLOCKED_REMINDER_TITLE_PREFIX}{task_id} needs status refresh"


def blocked_escalation_title(task_id: int) -> str:
    return f"{BLOCKED_ESCALATION_TITLE_PREFIX}{task_id} needs admin review"


def blocked_task_reminder_body(task: sqlite3.Row, age_seconds: int, reminder_seconds: int) -> str:
    task_id = int(task["id"])
    title = str(task["title"] or "").strip()
    assigned_to = str(task["assigned_to"] or "").strip()
    claimed_by = str(task["claimed_by"] or "").strip()
    body_path = str(task["body_path"] or "").strip()
    lines = [
        "# Blocked Task Reminder",
        "",
        f"- original_task_id: {task_id}",
        f"- original_title: {title}",
        f"- assigned_to: {assigned_to}",
        f"- claimed_by: {claimed_by or '-'}",
        f"- blocked_age: {format_task_age(age_seconds)}",
        f"- last_updated_at: {isoformat_ts(int(task['updated_ts'] or 0))}",
        f"- reminder_interval: {format_task_age(reminder_seconds)}",
    ]
    if body_path:
        lines.append(f"- original_body_file: {body_path}")
    lines.extend(
        [
            "",
            "This task has stayed blocked without a status refresh.",
            "",
            "## Self-Cleanup Decision Tree",
            "",
            "(admin contract; see CLAUDE.md `## Admin Self-Cleanup of Own Queue`)",
            "",
            "Apply (a)-(f) in order, ruling each one out in writing in your refresh note "
            "before reaching `refresh blocked`. Refresh is the exception, not the equilibrium.",
            "",
            "(a) original premise satisfied / invalidated by later events",
            f"    → `agb done {task_id} --agent {assigned_to} --note \"stale: <why>\"`",
            "(b) source agent moved on / closed its driving cycle",
            f"    → `agb done {task_id} --agent {assigned_to} --note \"source moved on\"`",
            "(c) another active task already covers this work",
            f"    → `agb handoff {task_id} --to <agent> --note \"<cross-ref>\"`"
            f" OR `agb done {task_id} --agent {assigned_to} --note \"duplicate of #<id>\"`",
            "(d) doable in <15 minutes by you alone",
            "    → unblock and do it now; do NOT defer as `tech debt`",
            "(e) operator decision required AND obtainable on the shared channel today",
            "    → escalate via Discord/Telegram, then refresh blocked with deadline",
            "(f) none of the above",
            f"    → `agb update {task_id} --status blocked --note \"I will revisit when "
            "<verifiable trigger>. Decision tree: ruled out (a)-(e) because: <one line>.\"`",
            "",
            "The `note` on a refresh-blocked must include both the verifiable trigger AND "
            "the one-line summary of why (a)-(e) were ruled out. Empty notes and bare-refresh "
            "notes are rejected by the contract.",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def blocked_task_escalation_body(
    task: sqlite3.Row,
    age_seconds: int,
    reminder_seconds: int,
    escalation_seconds: int,
) -> str:
    task_id = int(task["id"])
    title = str(task["title"] or "").strip()
    assigned_to = str(task["assigned_to"] or "").strip()
    reminder_count = max(1, age_seconds // max(1, reminder_seconds))
    lines = [
        "# Blocked Task Escalation",
        "",
        f"- original_task_id: {task_id}",
        f"- original_title: {title}",
        f"- assigned_to: {assigned_to}",
        f"- blocked_age: {format_task_age(age_seconds)}",
        f"- escalation_threshold: {format_task_age(escalation_seconds)}",
        f"- last_updated_at: {isoformat_ts(int(task['updated_ts'] or 0))}",
        f"- reminder_cycles_elapsed: {reminder_count}",
        "",
        "This blocked task has gone stale past the escalation threshold.",
        "Please review whether the assignee needs intervention, handoff, or closure.",
        "",
        "## Self-Cleanup Decision Tree",
        "",
        "(admin contract; see CLAUDE.md `## Admin Self-Cleanup of Own Queue`)",
        "",
        "Apply (a)-(f) in order, ruling each one out in writing in your refresh note "
        "before reaching `refresh blocked`. Refresh is the exception, not the equilibrium.",
        "",
        "(a) original premise satisfied / invalidated by later events",
        f"    → `agb done {task_id} --agent {assigned_to} --note \"stale: <why>\"`",
        "(b) source agent moved on / closed its driving cycle",
        f"    → `agb done {task_id} --agent {assigned_to} --note \"source moved on\"`",
        "(c) another active task already covers this work",
        f"    → `agb handoff {task_id} --to <agent> --note \"<cross-ref>\"`"
        f" OR `agb done {task_id} --agent {assigned_to} --note \"duplicate of #<id>\"`",
        "(d) doable in <15 minutes by you alone",
        "    → unblock and do it now; do NOT defer as `tech debt`",
        "(e) operator decision required AND obtainable on the shared channel today",
        "    → escalate via Discord/Telegram, then refresh blocked with deadline",
        "(f) none of the above",
        f"    → `agb update {task_id} --status blocked --note \"I will revisit when "
        "<verifiable trigger>. Decision tree: ruled out (a)-(e) because: <one line>.\"`",
        "",
        "The `note` on a refresh-blocked must include both the verifiable trigger AND "
        "the one-line summary of why (a)-(e) were ruled out. Empty notes and bare-refresh "
        "notes are rejected by the contract.",
        "",
        "This is the second escalation cycle for this id. If you cannot reach (a)-(e) this "
        "round, the operator will be paged via the shared channel; do not bare-refresh.",
    ]
    return "\n".join(lines).rstrip() + "\n"


def resurface_open_alert(conn: sqlite3.Connection, *, agent: str, task_id: int) -> None:
    # #1986: make a re-bound daemon alert (blocked-aging reminder/escalation)
    # VISIBLE again on its cadence without re-minting a fresh id. `upsert_open_task`
    # re-binds the SAME open task (KNOWN_ISSUES §30: open re-binds, `done` re-mints)
    # via an in-place UPDATE that bumps body/priority but never re-enters the nudge
    # pool — so an agent who leaves the alert open (claimed/blocked, or queued but
    # already in `last_nudge_key`) gets a silent refresh and no new notification.
    # Re-surface the re-bound task through the EXISTING nudge machinery: (1) put it
    # back to `queued` so the maintain nudge-scan considers it, and (2) drop its id
    # from the assignee's `last_nudge_key` so the scan treats it as a fresh queued
    # trigger (`has_new_queue_ids` → re-nudge). This fires only on the cadence gate
    # the caller already enforces (`reminder_seconds` / `escalation_seconds`), never
    # per tick, and never re-mints — §30 dedupe ("one open alert per condition,
    # `done` re-mints") stays intact.
    conn.execute(
        "UPDATE tasks SET status = 'queued' WHERE id = ? AND status != 'queued'",
        (task_id,),
    )
    row = conn.execute(
        "SELECT last_nudge_key FROM agent_state WHERE agent = ?",
        (agent,),
    ).fetchone()
    if row is None:
        return
    current_key = str(row["last_nudge_key"] or "")
    if not current_key:
        return
    remaining = [item for item in current_key.split(",") if item and item != str(task_id)]
    new_key = ",".join(remaining)
    if new_key != current_key:
        conn.execute(
            "UPDATE agent_state SET last_nudge_key = ? WHERE agent = ?",
            (new_key, agent),
        )


def process_blocked_task_aging(
    conn: sqlite3.Connection,
    *,
    current_ts: int,
    reminder_seconds: int,
    escalation_seconds: int,
    admin_agent: str,
) -> None:
    if reminder_seconds <= 0:
        return

    blocked_rows = conn.execute(
        """
        SELECT id, title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path,
               claimed_by, claimed_ts, lease_until_ts, closed_ts
        FROM tasks
        WHERE status = 'blocked'
          AND updated_ts < ?
          AND title NOT LIKE '[blocked-aging]%'
          AND title NOT LIKE '[blocked-escalation]%'
        ORDER BY updated_ts ASC, id ASC
        """,
        (current_ts - reminder_seconds,),
    ).fetchall()

    for task in blocked_rows:
        task_id = int(task["id"])
        age_seconds = max(0, current_ts - int(task["updated_ts"] or current_ts))

        last_reminder_ts = latest_event_ts(conn, task_id, "blocked_reminder")
        if last_reminder_ts == 0 or current_ts - last_reminder_ts >= reminder_seconds:
            title_prefix = f"{BLOCKED_REMINDER_TITLE_PREFIX}{task_id} "
            reminder_task_id, created = upsert_open_task(
                conn,
                agent=str(task["assigned_to"]),
                title_prefix=title_prefix,
                title=blocked_reminder_title(task_id),
                priority="normal",
                actor="daemon",
                body_text=blocked_task_reminder_body(task, age_seconds, reminder_seconds),
                current_ts=current_ts,
                refresh_note="daemon refreshed blocked-aging reminder",
            )
            if not created:
                # #1986: a re-bound (existing-open) reminder would otherwise refresh
                # silently. On this cadence gate, re-surface it so the assignee gets a
                # fresh visible nudge instead of an invisible in-place refresh.
                resurface_open_alert(
                    conn, agent=str(task["assigned_to"]), task_id=reminder_task_id
                )
            emit_event(
                conn,
                task_id,
                event_type="blocked_reminder",
                actor="daemon",
                created_ts=current_ts,
                note_text=(
                    f"{'created' if created else 'refreshed'} reminder task #{reminder_task_id} "
                    f"for {task['assigned_to']}"
                ),
                to_agent=str(task["assigned_to"]),
            )

        if escalation_seconds <= 0 or age_seconds < escalation_seconds:
            continue
        if not admin_agent:
            continue

        # #1986 (b): relax the strict one-shot escalation to a BOUNDED periodic
        # re-escalation. Previously `last_escalated_ts != 0 → continue` meant a
        # long-blocked task escalated to admin exactly once, ever. Re-escalate at
        # most once per `escalation_seconds` (the same cadence-gate shape the
        # reminder uses), so a task that stays blocked re-surfaces to admin
        # periodically instead of silently. The cadence gate bounds it — no
        # per-tick churn — and §30 dedupe holds (we re-bind the SAME open
        # escalation task, never re-mint).
        last_escalated_ts = latest_event_ts(conn, task_id, "blocked_escalated")
        if last_escalated_ts != 0 and current_ts - last_escalated_ts < escalation_seconds:
            continue

        title_prefix = f"{BLOCKED_ESCALATION_TITLE_PREFIX}{task_id} "
        escalation_task_id, created = upsert_open_task(
            conn,
            agent=admin_agent,
            title_prefix=title_prefix,
            title=blocked_escalation_title(task_id),
            priority="high",
            actor="daemon",
            body_text=blocked_task_escalation_body(task, age_seconds, reminder_seconds, escalation_seconds),
            current_ts=current_ts,
            refresh_note="daemon refreshed blocked-aging escalation",
        )
        if not created:
            # Re-bound (existing-open) escalation → re-surface visibly to admin on
            # the escalation cadence instead of a silent in-place refresh.
            resurface_open_alert(conn, agent=admin_agent, task_id=escalation_task_id)
        emit_event(
            conn,
            task_id,
            event_type="blocked_escalated",
            actor="daemon",
            created_ts=current_ts,
            note_text=(
                f"{'created' if created else 'refreshed'} escalation task #{escalation_task_id} "
                f"for {admin_agent}"
            ),
            to_agent=admin_agent,
        )


def load_ready_agents(path: str | None) -> set[str]:
    if not path:
        return set()
    ready: set[str] = set()
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            agent = line.strip()
            if agent:
                ready.add(agent)
    return ready


def cmd_daemon_step(args: argparse.Namespace) -> int:
    snapshot_rows = load_snapshot(args.snapshot)
    # PR #952 r3 P2 #2: defer ready_agents load until the non-skip branch.
    # When the L4 fail-path calls us with --skip-nudges + a broken/blocking
    # ready-agents file (e.g. /dev/full, a fifo with no writer, an unreadable
    # path from a wedged write), the r2 form consumed the file at function
    # entry and would block/raise before maintenance ran. Maintenance ops
    # (lease extend/expire, cron de-dupe, stale-claim requeue, blocked-task
    # aging) do not need ready_agents — load only when nudge dispatch will
    # actually consume it.
    ready_agents: set[str] = set()
    current_ts = now_ts()
    lease_seconds = int(args.lease_seconds)
    heartbeat_window = int(args.heartbeat_window)
    idle_threshold = int(args.idle_threshold)
    nudge_cooldown = int(args.nudge_cooldown)
    blocked_reminder_seconds = max(0, int(args.blocked_reminder_seconds))
    blocked_escalate_seconds = max(0, int(args.blocked_escalate_seconds))
    admin_agent = str(args.admin_agent or "").strip()
    # Issue #1014 A: a freshly-queued task already triggered the task-arrival
    # push notification. The daemon idle-nudge measures agent-idle-duration, so
    # an agent parked idle past idle_threshold gets a redundant ACTION REQUIRED
    # nudge on the very next tick (~5s) for a task it is already acting on.
    # Gate the nudge on task-queued age: a queued task younger than the nudge
    # redelivery window does not count as a fresh nudge trigger. Once it ages
    # past the window without progress, the nudge fires normally.
    try:
        nudge_redelivery_seconds = int(
            os.environ.get("BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS", "60")
        )
    except (TypeError, ValueError):
        nudge_redelivery_seconds = 60
    if nudge_redelivery_seconds < 0:
        nudge_redelivery_seconds = 0
    queued_ids_by_agent: dict[str, list[int]] = {}
    queued_created_by_id: dict[int, int] = {}

    with closing(connect()) as conn, conn:
        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            # Issue #589: prompt-ready latch propagation. The bash side writes
            # marker files; bridge_write_agent_snapshot mirrors them into the
            # snapshot row so we can upsert here. None values keep the column
            # NULL when no marker exists — _latched_idle_seconds treats that
            # as "no latch yet" and falls through to the grace window logic.
            prompt_ready_ts = int(row.get("prompt_ready_ts") or 0)
            prompt_ready_session = str(row.get("prompt_ready_session") or "")
            prompt_ready_source = str(row.get("prompt_ready_source") or "")
            conn.execute(
                """
                INSERT INTO agent_state (
                  agent, engine, session, workdir, active, last_seen_ts, last_heartbeat_ts, session_activity_ts,
                  prompt_ready_ts, prompt_ready_session, prompt_ready_source
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent) DO UPDATE SET
                  engine = excluded.engine,
                  session = excluded.session,
                  workdir = excluded.workdir,
                  active = excluded.active,
                  last_seen_ts = excluded.last_seen_ts,
                  last_heartbeat_ts = excluded.last_heartbeat_ts,
                  session_activity_ts = excluded.session_activity_ts,
                  prompt_ready_ts = excluded.prompt_ready_ts,
                  prompt_ready_session = excluded.prompt_ready_session,
                  prompt_ready_source = excluded.prompt_ready_source
                """,
                (
                    row["agent"],
                    row.get("engine", ""),
                    row.get("session", ""),
                    row.get("workdir", ""),
                    active,
                    current_ts if active else None,
                    current_ts,
                    activity_ts or None,
                    prompt_ready_ts or None,
                    prompt_ready_session or None,
                    prompt_ready_source or None,
                ),
            )

        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            if not active or not activity_ts:
                continue
            if current_ts - activity_ts > heartbeat_window:
                continue
            conn.execute(
                """
                UPDATE tasks
                SET lease_until_ts = CASE
                  WHEN lease_until_ts IS NULL OR lease_until_ts < ? THEN ?
                  ELSE lease_until_ts
                END
                WHERE status = 'claimed' AND claimed_by = ?
                """,
                (current_ts + lease_seconds, current_ts + lease_seconds, row["agent"]),
            )

        expired = conn.execute(
            """
            SELECT id, claimed_by
            FROM tasks
            WHERE status = 'claimed'
              AND lease_until_ts IS NOT NULL
              AND lease_until_ts < ?
            """,
            (current_ts,),
        ).fetchall()
        for row in expired:
            conn.execute(
                """
                UPDATE tasks
                SET status = 'queued',
                    claimed_by = NULL,
                    claimed_ts = NULL,
                    lease_until_ts = NULL,
                    updated_ts = ?
                WHERE id = ?
                """,
                (current_ts, row["id"]),
            )
            emit_event(
                conn,
                int(row["id"]),
                event_type="lease_expired",
                actor="daemon",
                created_ts=current_ts,
                note_text="lease expired after missing heartbeat",
                from_agent=row["claimed_by"],
            )

        # --- Compute idle agents (used by both cron dedup and stale requeue) ---
        # Issue #1345 r2 (Lane κ v0.15.0-beta5-2, codex r1 BLOCKING):
        # exclude `picker_blocked` and `working` agents from the idle
        # set. Before the fix, the gate was active + session_activity_ts
        # age only. A picker_blocked agent (claude rate-limit / summary
        # picker) typically has tmux activity_ts aged past
        # --idle-threshold (the picker dialog itself does not refresh
        # the activity_ts), so the stale-claim requeue at :2242-2285
        # below wrongly requeued the agent's claimed task with the note
        # "claimed for >Ns by idle agent". The agent then re-claimed
        # the requeued task on its next wake — burning a tool turn for
        # nothing. The daemon-step snapshot writer
        # (lib/bridge-state.sh:bridge_write_agent_snapshot) now emits
        # `activity_state="picker_blocked"` for agents matching the
        # stall.env predicate. `working` is included defensively: it
        # is not currently emitted by the daemon-step writer (only
        # the roster/status writer computes it via a tmux capture),
        # but if a future change pulls the full classification into
        # the daemon path, the exclusion stays correct.
        #
        # Backwards compat: legacy snapshots without the
        # `activity_state` column return "" from .get(), which is not
        # in the exclusion set — preserves pre-fix idle classification
        # for the upgrade window between the bash + python halves.
        max_claim_age = int(getattr(args, "max_claim_age", 900))
        idle_agents = set()
        active_agents = set()
        _idle_excluded_states = {"picker_blocked", "working"}
        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            activity_state = str(row.get("activity_state") or "")
            if active:
                active_agents.add(str(row["agent"]))
            if (
                active
                and activity_ts
                and current_ts - activity_ts >= idle_threshold
                and activity_state not in _idle_excluded_states
            ):
                idle_agents.add(str(row["agent"]))

        # --- Cron-dispatch dedup ---
        # For each (agent, cron-job-name) combo, keep only the newest open
        # dispatch and cancel older duplicates.  The newest one stays queued
        # (or gets requeued if claimed by an idle agent) so it still runs.
        # Single dispatches (e.g. one evening-digest) are untouched here;
        # the stale-claim requeue below handles them if the agent is idle.
        import re as _re
        _cron_name_re = _re.compile(r"^\[cron-dispatch\]\s*(\S+)")
        cron_open = conn.execute(
            """
            SELECT id, title, assigned_to, status, claimed_by, created_ts
            FROM tasks
            WHERE status IN ('queued', 'claimed')
              AND title LIKE '[cron-dispatch]%'
            ORDER BY created_ts DESC
            """,
        ).fetchall()
        _cron_groups: dict[tuple[str, str], list[sqlite3.Row]] = {}
        for row in cron_open:
            m = _cron_name_re.match(row["title"])
            job_name = m.group(1) if m else row["title"]
            key = (str(row["assigned_to"]), job_name)
            _cron_groups.setdefault(key, []).append(row)
        # Issue #266: in recovery scenarios (worker pool backlog, daemon hang
        # recovery), the newest slot itself often has not been fired by the
        # time the next cron tick adds a still-newer slot. The previous logic
        # cancelled every non-newest open slot, which meant a high-frequency
        # cron with worker latency > cron interval never actually ran — every
        # fresh slot got superseded by the next before a worker could claim it
        # (cs-line-poll-5m: zero successful runs across 144 slots in 36h).
        # Two layered guards: (1) preserve any sibling that is still inside
        # the grace window (worker may still pick it up); (2) if the newest
        # slot has not itself been fired yet, leave older un-claimed siblings
        # in place so the worker can pick whichever it reaches first instead
        # of seeing an empty queue while a stuck cron quietly drops fires.
        try:
            _supersede_grace = int(os.environ.get("BRIDGE_CRON_SUPERSEDE_GRACE_SECONDS", "60"))
        except (TypeError, ValueError):
            _supersede_grace = 60
        if _supersede_grace < 0:
            _supersede_grace = 0
        for _key, group in _cron_groups.items():
            if len(group) < 2:
                continue
            newest = group[0]
            newest_fired = bool(newest["claimed_by"]) or newest["status"] == "claimed"
            for row in group[1:]:
                created_ts = row["created_ts"] or 0
                if (current_ts - created_ts) < _supersede_grace and not row["claimed_by"]:
                    continue
                if not newest_fired and not row["claimed_by"]:
                    continue
                conn.execute(
                    """
                    UPDATE tasks
                    SET status = 'cancelled',
                        claimed_by = NULL,
                        lease_until_ts = NULL,
                        updated_ts = ?
                    WHERE id = ?
                    """,
                    (current_ts, row["id"]),
                )
                emit_event(
                    conn,
                    int(row["id"]),
                    event_type="cron_dedup_cancelled",
                    actor="daemon",
                    created_ts=current_ts,
                    note_text=f"superseded by newer dispatch #{group[0]['id']}",
                    from_agent=row["claimed_by"] or row["assigned_to"],
                )

        # --- Idle agent claimed task requeue ---
        # ALL claimed tasks (cron or not) older than max_claim_age from idle
        # agents get requeued.  An idle agent is at the prompt and not working
        # on anything — its claimed tasks should be released.
        stale_claimed = conn.execute(
            """
            SELECT id, claimed_by
            FROM tasks
            WHERE status = 'claimed'
              AND claimed_ts IS NOT NULL
              AND claimed_ts < ?
            """,
            (current_ts - max_claim_age,),
        ).fetchall()
        for row in stale_claimed:
            agent_name = str(row["claimed_by"])
            note_text = ""
            if agent_name not in active_agents:
                note_text = f"claimed for >{max_claim_age}s by inactive agent"
            elif agent_name in idle_agents:
                note_text = f"claimed for >{max_claim_age}s by idle agent"
            else:
                continue
            conn.execute(
                """
                UPDATE tasks
                SET status = 'queued',
                    claimed_by = NULL,
                    claimed_ts = NULL,
                    lease_until_ts = NULL,
                    updated_ts = ?
                WHERE id = ?
                """,
                (current_ts, row["id"]),
            )
            emit_event(
                conn,
                int(row["id"]),
                event_type="stale_claim_requeued",
                actor="daemon",
                created_ts=current_ts,
                note_text=note_text,
                from_agent=agent_name,
            )

        process_blocked_task_aging(
            conn,
            current_ts=current_ts,
            reminder_seconds=blocked_reminder_seconds,
            escalation_seconds=blocked_escalate_seconds,
            admin_agent=admin_agent,
        )

        # Issue #946 L4 / PR #952 r2: maintenance is complete (lease extend
        # / expire, cron de-dupe, stale-claim requeue, blocked-task aging).
        # If the caller passed --skip-nudges (the bash daemon's L4 fail-path
        # uses this when bridge_write_idle_ready_agents failed) return now
        # without consuming the ready-agents file or emitting nudge rows.
        # Production-side proof: tests/smoke gating reads the audit log for
        # the maintenance side-effects regardless of the skip flag.
        if getattr(args, "skip_nudges", False):
            if args.format == "text":
                print("(maintenance-only; nudges skipped)")
            return 0

        # PR #952 r3 P2 #2: load ready-agents only here, after the skip
        # check — a broken or blocking ready-agents file must NOT be
        # consumed on the maintenance-only path.
        ready_agents = load_ready_agents(
            getattr(args, "ready_agents_file", None)
        )

        # Issue #1630 (audit R3, root cause of #10561): consume the one-shot
        # fresh-arrival markers ONLY on the nudge-dispatching path (after the
        # --skip-nudges short-circuit above), so the markers are never burned on
        # a maintenance-only tick that wouldn't dispatch the nudge anyway. These
        # ids are exempted from ONLY the redelivery-AGE gate below — every other
        # eligibility check (queued status, idle, cooldown, activity, last-nudge
        # key) still applies unchanged. A marker for a task that is no longer
        # queued is simply ignored (it won't appear in queued_ids_by_agent).
        fresh_arrival_ids = consume_fresh_arrival_markers()

        rows = conn.execute(
            """
            SELECT assigned_to, id, created_ts
            FROM tasks
            WHERE status = 'queued'
              AND title NOT LIKE '[cron-dispatch]%'
            ORDER BY assigned_to, id
            """
        ).fetchall()
        for row in rows:
            task_id = int(row["id"])
            queued_ids_by_agent.setdefault(str(row["assigned_to"]), []).append(task_id)
            queued_created_by_id[task_id] = int(row["created_ts"] or 0)

        rows = conn.execute(
            f"""
            WITH assigned AS (
              SELECT assigned_to AS agent, COUNT(*) AS queued_count
              FROM tasks
              WHERE status = 'queued'
                AND title NOT LIKE '[cron-dispatch]%'
              GROUP BY assigned_to
            ),
            claimed AS (
              SELECT claimed_by AS agent, COUNT(*) AS claimed_count
              FROM tasks
              WHERE status = 'claimed' AND claimed_by IS NOT NULL
              GROUP BY claimed_by
            )
            SELECT
              agent_state.agent,
              agent_state.session,
              COALESCE(assigned.queued_count, 0) AS queued_count,
              COALESCE(claimed.claimed_count, 0) AS claimed_count,
              agent_state.session_activity_ts,
              agent_state.last_seen_ts,
              agent_state.last_nudge_ts,
              agent_state.last_nudge_key,
              agent_state.nudge_fail_count,
              agent_state.zombie
            FROM agent_state
            LEFT JOIN assigned ON assigned.agent = agent_state.agent
            LEFT JOIN claimed ON claimed.agent = agent_state.agent
            WHERE agent_state.active = 1
              AND COALESCE(assigned.queued_count, 0) > 0
            ORDER BY agent_state.agent
            """
        ).fetchall()

    printed = False
    for row in rows:
        is_ready_agent = str(row["agent"]) in ready_agents
        activity_ts = row["session_activity_ts"] or row["last_seen_ts"] or 0
        if not activity_ts and not is_ready_agent:
            continue
        idle_seconds = max(0, current_ts - int(activity_ts)) if activity_ts else 0
        if not is_ready_agent and idle_seconds < idle_threshold:
            continue
        queue_ids = queued_ids_by_agent.get(str(row["agent"]), [])
        if not queue_ids:
            continue
        nudge_key = ",".join(str(task_id) for task_id in queue_ids)
        last_nudge_ts = int(row["last_nudge_ts"] or 0)
        last_nudge_key = row["last_nudge_key"] or ""
        zombie = int(row["zombie"] or 0)
        if zombie:
            continue
        last_nudged_ids = {item for item in last_nudge_key.split(",") if item}
        # Issue #1099 (#1014-A follow-up): widen PR #1019's nudge-redelivery
        # age gate from an agent-level invariant ("agent has no prior nudge
        # history") to a task-level invariant ("a queued task younger than
        # the redelivery window is not a fresh nudge trigger, period").
        #
        # Pre-fix, PR #1019 gated only the never-nudged path (`not
        # last_nudged_ids and not has_new_queue_ids`). Three guard paths
        # still let a fresh-only queue through for any agent with prior
        # nudge history: (1) `is_ready_agent` bypassing the idle gate at
        # line 2172, (2) the post-cooldown branch at line 2205, and (3)
        # the activity-advance branch at line 2209. Active dynamic agents
        # mid-claim got `idle_seconds=1` ACTION REQUIRED nudges seconds
        # after a task landed (issue #1099 evidence: task #5653 fired at
        # `idle_seconds:"1"` ~1s into the post-arrival grace window).
        #
        # Compute `eligible_queue_ids` on the FULL current queued set; the
        # eligibility set must precede the `last_nudged_ids` subtraction,
        # because the bug scenario is "entire queue is fresh and agent has
        # prior nudge history". If the gate is on and no queued task has
        # aged past the window, no candidate is emitted regardless of
        # last_nudge_key state — the task-arrival push already covered it.
        # nudge_redelivery_seconds <= 0 disables the gate entirely
        # (restores pre-#1019 behavior).
        #
        # Issue #1630 (audit R3, root cause of #10561): a task whose id carries a
        # one-shot fresh-arrival marker (posted by the A2A receiver right after
        # enqueue) is age-eligible THIS tick even when younger than the
        # redelivery window. This bypasses ONLY the age gate — the task must
        # still be queued (it is, or it wouldn't be in `queue_ids`), and every
        # downstream check (idle, cooldown, activity, last-nudge key) below runs
        # unchanged. Without the marker the task simply waits out the ~60s gate
        # as before. `fresh_arrival_ids` was already consumed (one-shot), so the
        # exemption applies for AT MOST this tick.
        if nudge_redelivery_seconds > 0:
            eligible_queue_ids = [
                task_id
                for task_id in queue_ids
                if task_id in fresh_arrival_ids
                or (current_ts - queued_created_by_id.get(task_id, 0))
                >= nudge_redelivery_seconds
            ]
        else:
            eligible_queue_ids = list(queue_ids)
        # Task-level invariant: fresh-only queue is never a daemon-nudge
        # candidate. Closes Paths 1/2/3 (ready-agent bypass, prior-history
        # guard, cooldown/activity-advance guards) in one place.
        if nudge_redelivery_seconds > 0 and not eligible_queue_ids:
            continue
        eligible_new_queue_ids = [
            task_id
            for task_id in eligible_queue_ids
            if str(task_id) not in last_nudged_ids
        ]
        has_new_queue_ids = bool(eligible_new_queue_ids)
        # PR #1019's original never-nudged-agent guard, now redundant with
        # the task-level eligibility check above on the gate-on path but
        # still required when the gate is disabled (preserves pre-#1019
        # behavior end-to-end for `BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0`).
        if not last_nudged_ids and not has_new_queue_ids:
            continue
        if last_nudge_ts and current_ts - last_nudge_ts < nudge_cooldown and not has_new_queue_ids:
            continue
        # Suppress repeats for the same queue until the session shows activity again,
        # but allow a fresh nudge when new queued task ids arrive.
        if last_nudge_ts and int(activity_ts) and last_nudge_ts >= int(activity_ts) and not has_new_queue_ids:
            continue
        printed = True
        print(
            "\t".join(
                [
                    row["agent"],
                    row["session"],
                    str(row["queued_count"]),
                    str(row["claimed_count"]),
                    str(idle_seconds),
                    nudge_key,
                ]
            )
        )

    if args.format == "text" and not printed:
        print("(no nudge candidates)")
    return 0


def cmd_note_nudge(args: argparse.Namespace) -> int:
    current_ts = now_ts()
    with closing(connect()) as conn, conn:
        conn.execute(
            """
            INSERT INTO agent_state (agent, last_nudge_ts, last_nudge_key, nudge_fail_count, zombie)
            VALUES (?, ?, ?, 1, 0)
            ON CONFLICT(agent) DO UPDATE SET
              last_nudge_ts = excluded.last_nudge_ts,
              last_nudge_key = excluded.last_nudge_key,
              nudge_fail_count = COALESCE(agent_state.nudge_fail_count, 0) + 1,
              zombie = CASE
                WHEN COALESCE(agent_state.nudge_fail_count, 0) + 1 >= ? THEN 1
                ELSE agent_state.zombie
              END
            """,
            (args.agent, current_ts, args.key, args.zombie_threshold),
        )
    print(f"recorded nudge for {args.agent}")
    return 0


def cmd_note_self_continue(args: argparse.Namespace) -> int:
    # #9780: a non-failure "attention delivered" stamp written when a Stop
    # inbox-drain auto-continues the agent on its own queued work. It mirrors
    # note-nudge's last_nudge_ts/last_nudge_key write so the daemon's nudge
    # cooldown/freshness gate suppresses a concurrent ACTION REQUIRED nudge for
    # the same queued set — but it MUST NOT increment nudge_fail_count or touch
    # zombie state (the agent IS attending to the queue; this is the opposite of
    # a failed/dropped nudge). Distinct verb so the failure-count semantics of
    # note-nudge can never leak into the self-continue path.
    current_ts = now_ts()
    with closing(connect()) as conn, conn:
        conn.execute(
            """
            INSERT INTO agent_state (agent, last_nudge_ts, last_nudge_key, nudge_fail_count, zombie)
            VALUES (?, ?, ?, 0, 0)
            ON CONFLICT(agent) DO UPDATE SET
              last_nudge_ts = excluded.last_nudge_ts,
              last_nudge_key = excluded.last_nudge_key
            """,
            (args.agent, current_ts, args.key or ""),
        )
    print(f"recorded self-continue for {args.agent}")
    return 0


def cmd_events(args: argparse.Namespace) -> int:
    import json as _json

    after_id = args.after_id
    limit = args.limit
    event_type = args.event_type

    with closing(connect()) as conn:
        query = """
            SELECT
                e.id, e.task_id, e.event_type, e.actor, e.created_ts,
                e.note_text, e.note_path, e.from_agent, e.to_agent,
                t.title AS task_title, t.body_text AS task_body,
                t.body_path AS task_body_path,
                t.assigned_to, t.created_by AS task_created_by
            FROM task_events e
            LEFT JOIN tasks t ON t.id = e.task_id
            WHERE e.id > ?
        """
        params: list = [after_id]
        if event_type:
            query += " AND e.event_type = ?"
            params.append(event_type)
        query += " ORDER BY e.id ASC LIMIT ?"
        params.append(limit)
        rows = conn.execute(query, params).fetchall()

    if args.format == "json":
        events = []
        for row in rows:
            note_file_content = None
            note_path = row["note_path"]
            if note_path and os.path.isfile(note_path):
                try:
                    note_file_content = Path(note_path).read_text(
                        encoding="utf-8", errors="replace"
                    )[:4000]
                except OSError:
                    pass
            # Resolve task body: prefer body_text, fall back to body_path file
            task_body = row["task_body"]
            if not task_body:
                body_path = row["task_body_path"]
                if body_path and os.path.isfile(body_path):
                    try:
                        task_body = Path(body_path).read_text(
                            encoding="utf-8", errors="replace"
                        )[:4000]
                    except OSError:
                        pass
            events.append(
                {
                    "event_id": row["id"],
                    "task_id": row["task_id"],
                    "event_type": row["event_type"],
                    "actor": row["actor"],
                    "created_ts": row["created_ts"],
                    "note_text": row["note_text"],
                    "note_path": row["note_path"],
                    "note_file_content": note_file_content,
                    "from_agent": row["from_agent"],
                    "to_agent": row["to_agent"],
                    "task_title": row["task_title"],
                    "task_body": task_body,
                    "assigned_to": row["assigned_to"],
                    "task_created_by": row["task_created_by"],
                }
            )
        print(_json.dumps(events, ensure_ascii=False))
    else:
        for row in rows:
            ts = datetime.fromtimestamp(
                int(row["created_ts"]), tz=timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%S%z")
            print(
                f"#{row['id']}  task={row['task_id']}  {row['event_type']}  "
                f"actor={row['actor']}  {ts}  {row['note_text'] or ''}"
            )
    return 0


def build_parser() -> argparse.ArgumentParser:
    # PR #571 r3 finding 2a: every parser disables argparse's default
    # prefix-abbreviation. The queue gateway authorizer (bridge-queue-gateway.py
    # _extract_positional_task_id) walks argv with a *fixed* per-subcommand
    # value-flag table; a long option that argparse would silently expand
    # (e.g. `--note-f` → `--note-file`) is unknown to that walker, which
    # then misreads the would-be value as the positional task id while
    # this parser executes against a different positional. allow_abbrev=False
    # forces clients to spell flags exactly so the gateway and the inner
    # parser see the same shape.
    parser = argparse.ArgumentParser(prog="bridge-queue.py", allow_abbrev=False)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init", allow_abbrev=False)

    create_parser = subparsers.add_parser("create", allow_abbrev=False)
    create_parser.add_argument("--to", dest="assigned_to", required=True)
    create_parser.add_argument("--title", required=True)
    create_parser.add_argument("--from", dest="actor")
    create_parser.add_argument("--priority", choices=PRIORITY_CHOICES, default="normal")
    create_parser.add_argument("--format", choices=("text", "shell"), default="text")
    create_parser.add_argument("--allow-empty-body", action="store_true")
    body_group = create_parser.add_mutually_exclusive_group()
    body_group.add_argument("--body")
    body_group.add_argument("--body-file")
    create_parser.set_defaults(handler=cmd_create)

    # Issue #1408: atomic refresh-or-create keyed by a stable title prefix.
    # Daemon-internal (controller-direct); used by the A2A outbox-stuck scan
    # and the unclaimed-task escalation to keep a SINGLE open admin task per
    # recurring condition instead of minting a new task each cooldown window.
    upsert_parser = subparsers.add_parser("upsert-open", allow_abbrev=False)
    upsert_parser.add_argument("--to", dest="assigned_to", required=True)
    upsert_parser.add_argument("--title-prefix", required=True)
    upsert_parser.add_argument("--title", required=True)
    upsert_parser.add_argument("--from", dest="actor")
    upsert_parser.add_argument("--priority", choices=PRIORITY_CHOICES, default="normal")
    upsert_parser.add_argument("--refresh-note")
    upsert_parser.add_argument("--format", choices=("text", "shell"), default="text")
    upsert_body_group = upsert_parser.add_mutually_exclusive_group()
    upsert_body_group.add_argument("--body")
    upsert_body_group.add_argument("--body-file")
    upsert_parser.set_defaults(handler=cmd_upsert_open)

    inbox_parser = subparsers.add_parser("inbox", allow_abbrev=False)
    inbox_parser.add_argument("--agent", required=True)
    inbox_parser.add_argument("--status", action="append", choices=STATUS_CHOICES)
    inbox_parser.add_argument("--all", action="store_true")
    inbox_parser.set_defaults(handler=cmd_inbox)

    show_parser = subparsers.add_parser("show", allow_abbrev=False)
    show_parser.add_argument("task_id", type=int)
    show_parser.add_argument("--format", choices=("text", "shell"), default="text")
    show_parser.set_defaults(handler=cmd_show)

    find_open_parser = subparsers.add_parser("find-open", allow_abbrev=False)
    find_open_parser.add_argument("--agent", required=True)
    find_open_parser.add_argument("--title-prefix")
    find_open_parser.add_argument(
        "--status-filter",
        choices=("queued", "claimed", "blocked"),
        action="append",
        default=None,
        help=(
            "Restrict the open-task search to the given status(es). Repeatable. "
            "Default (omitted) matches the legacy open set: queued, claimed, "
            "blocked. Issue #1199 uses --status-filter queued so the ACTION "
            "REQUIRED 'Highest priority' line never cites a claimed/blocked task."
        ),
    )
    find_open_parser.add_argument(
        "--exclude-title-prefix",
        action="append",
        default=[],
        help="exclude open tasks whose title starts with this prefix",
    )
    find_open_parser.add_argument("--format", choices=("id", "text", "shell", "json"), default="id")
    find_open_parser.add_argument(
        "--all",
        action="store_true",
        help="return all matching open tasks as a JSON array (forces JSON output with created_ts/updated_ts)",
    )
    find_open_parser.add_argument(
        "--mode",
        choices=("refresh-by-job", "per-run"),
        default="refresh-by-job",
        help=(
            "PR1.7 cron-followup dedupe selector. refresh-by-job (default) "
            "matches prior open task by title prefix; per-run always "
            "returns nothing so each distinct alert lands as a new task."
        ),
    )
    find_open_parser.set_defaults(handler=cmd_find_open)

    claim_parser = subparsers.add_parser("claim", allow_abbrev=False)
    claim_parser.add_argument("task_id", type=int)
    claim_parser.add_argument("--agent", required=True)
    claim_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    # Issue #1253 — symmetric with `done` / `update`. --note and --note-file
    # are mutually exclusive so the operator never accidentally double-
    # specifies the audit text.
    claim_note_group = claim_parser.add_mutually_exclusive_group()
    claim_note_group.add_argument("--note")
    claim_note_group.add_argument("--note-file")
    claim_parser.set_defaults(handler=cmd_claim)

    done_parser = subparsers.add_parser("done", allow_abbrev=False)
    done_parser.add_argument("task_id", type=int)
    done_parser.add_argument("--agent", required=True)
    note_group = done_parser.add_mutually_exclusive_group()
    note_group.add_argument("--note")
    note_group.add_argument("--note-file")
    done_parser.set_defaults(handler=cmd_done)

    cancel_parser = subparsers.add_parser("cancel", allow_abbrev=False)
    cancel_parser.add_argument("task_id", type=int)
    cancel_parser.add_argument("--actor")
    cancel_group = cancel_parser.add_mutually_exclusive_group()
    cancel_group.add_argument("--note")
    cancel_group.add_argument("--note-file")
    cancel_parser.set_defaults(handler=cmd_cancel)

    update_parser = subparsers.add_parser("update", allow_abbrev=False)
    update_parser.add_argument("task_id", type=int)
    update_parser.add_argument("--actor")
    update_parser.add_argument("--title")
    update_parser.add_argument("--status", choices=UPDATE_STATUS_CHOICES)
    update_parser.add_argument("--priority", choices=PRIORITY_CHOICES)
    update_parser.add_argument("--note")
    update_body_group = update_parser.add_mutually_exclusive_group()
    update_body_group.add_argument("--body")
    update_body_group.add_argument("--body-file")
    update_parser.set_defaults(handler=cmd_update)

    handoff_parser = subparsers.add_parser("handoff", allow_abbrev=False)
    handoff_parser.add_argument("task_id", type=int)
    handoff_parser.add_argument("--to", dest="assigned_to", required=True)
    handoff_parser.add_argument("--from", dest="actor")
    handoff_group = handoff_parser.add_mutually_exclusive_group()
    handoff_group.add_argument("--note")
    handoff_group.add_argument("--note-file")
    handoff_parser.set_defaults(handler=cmd_handoff)

    validate_companion_parser = subparsers.add_parser(
        "validate-companion-body",
        allow_abbrev=False,
        help="Validate a companion-role review brief body for required sections.",
    )
    validate_companion_parser.add_argument("--title", required=True)
    body_group = validate_companion_parser.add_mutually_exclusive_group()
    body_group.add_argument("--body")
    body_group.add_argument("--body-file")
    validate_companion_parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
    )
    validate_companion_parser.set_defaults(handler=cmd_validate_companion_body)

    summary_parser = subparsers.add_parser("summary", allow_abbrev=False)
    summary_parser.add_argument("--agent", action="append")
    summary_parser.add_argument("--format", choices=("text", "tsv", "json"), default="text")
    summary_parser.set_defaults(handler=cmd_summary)

    cron_ready_parser = subparsers.add_parser("cron-ready", allow_abbrev=False)
    cron_ready_parser.add_argument("--limit", type=int, default=50)
    cron_ready_parser.add_argument("--scan-limit", type=int, default=50)
    cron_ready_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    cron_ready_parser.add_argument("--status-snapshot")
    cron_ready_parser.add_argument("--memory-daily-defer-seconds", type=int, default=10800)
    cron_ready_parser.set_defaults(handler=cmd_cron_ready)

    # Issue #1459 — queue-global cron-dispatch backlog snapshot.
    cron_backlog_parser = subparsers.add_parser("cron-backlog-snapshot", allow_abbrev=False)
    cron_backlog_parser.add_argument("--format", choices=("json", "tsv"), default="json")
    cron_backlog_parser.set_defaults(handler=cmd_cron_backlog_snapshot)

    daemon_parser = subparsers.add_parser("daemon-step", allow_abbrev=False)
    daemon_parser.add_argument("--snapshot", required=True)
    daemon_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    daemon_parser.add_argument(
        "--heartbeat-window",
        default=os.environ.get("BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS", "300"),
    )
    daemon_parser.add_argument(
        "--idle-threshold",
        default=os.environ.get("BRIDGE_TASK_IDLE_NUDGE_SECONDS", "120"),
    )
    daemon_parser.add_argument(
        "--nudge-cooldown",
        default=os.environ.get("BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS", "900"),
    )
    daemon_parser.add_argument(
        "--zombie-threshold",
        type=int,
        default=int(os.environ.get("BRIDGE_ZOMBIE_NUDGE_THRESHOLD", "10")),
    )
    daemon_parser.add_argument(
        "--max-claim-age",
        default=os.environ.get("BRIDGE_TASK_MAX_CLAIM_AGE_SECONDS", "900"),
    )
    daemon_parser.add_argument(
        "--blocked-reminder-seconds",
        default=os.environ.get("BRIDGE_TASK_BLOCKED_REMINDER_SECONDS", "86400"),
    )
    daemon_parser.add_argument(
        "--blocked-escalate-seconds",
        default=os.environ.get("BRIDGE_TASK_BLOCKED_ESCALATE_SECONDS", str(7 * 86400)),
    )
    daemon_parser.add_argument(
        "--admin-agent",
        default=os.environ.get("BRIDGE_ADMIN_AGENT_ID", "patch"),
    )
    daemon_parser.add_argument("--ready-agents-file")
    # Issue #946 L4 / PR #952 r2: when the idle_ready writer fails the bash
    # caller still needs maintenance (lease extend/expire, cron de-dupe,
    # stale-claim requeue, blocked-task aging) to run; only the nudge
    # candidate enumeration depends on the ready-agents file. --skip-nudges
    # keeps the maintenance path intact and short-circuits before the
    # per-agent nudge selection loop, so the daemon never freezes queue
    # maintenance on a transient writer failure.
    daemon_parser.add_argument("--skip-nudges", action="store_true")
    daemon_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    daemon_parser.set_defaults(handler=cmd_daemon_step)

    nudge_parser = subparsers.add_parser("note-nudge", allow_abbrev=False)
    nudge_parser.add_argument("--agent", required=True)
    nudge_parser.add_argument("--key")
    nudge_parser.add_argument(
        "--zombie-threshold",
        type=int,
        default=int(os.environ.get("BRIDGE_ZOMBIE_NUDGE_THRESHOLD", "10")),
    )
    nudge_parser.set_defaults(handler=cmd_note_nudge)

    self_continue_parser = subparsers.add_parser("note-self-continue", allow_abbrev=False)
    self_continue_parser.add_argument("--agent", required=True)
    self_continue_parser.add_argument("--key")
    self_continue_parser.set_defaults(handler=cmd_note_self_continue)

    events_parser = subparsers.add_parser("events", allow_abbrev=False)
    events_parser.add_argument("--type", dest="event_type")
    events_parser.add_argument("--after-id", type=int, default=0)
    events_parser.add_argument("--limit", type=int, default=100)
    events_parser.add_argument("--format", choices=("text", "json"), default="text")
    events_parser.set_defaults(handler=cmd_events)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if should_proxy_via_queue_gateway(argv):
        return proxy_via_queue_gateway(argv)
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "init":
        with closing(connect()):
            pass
        print(f"initialized task db at {get_db_path()}")
        return 0
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
