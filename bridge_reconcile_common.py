#!/usr/bin/env python3
"""Reconcile control-loop framework for the A2A mesh (v0.16.5 Lane 0).

This module is the FOUNDATION for the zero-touch transport-agnostic mesh: it
implements the declarative desired-state + reconcile control-loop that the
handoff daemon tick (`bridge-handoffd.py:reconcile_once`) drives every cadence
and on SIGHUP. It owns three things and ONLY three things:

  1. A durable per-step backoff store — `state/handoff/reconcile.db` (SQLite,
     WAL, 0600). One row per reconcile step records the last attempt, the
     attempt count, the last result, and the `next_eligible_ts` computed with
     exponential backoff + jitter (capped). Durable so a daemon restart cannot
     storm-retry every step the instant the process comes back.
  2. An ordered, idempotent reconcile step sequence. Each step computes
     desired-vs-observed and no-ops when converged; a step that raises is
     caught, recorded as `error`, and NEVER crashes the daemon tick (fail-safe,
     same spirit as the #1685 staleness detector).
  3. The adapter SEAMS (stubs with fixed signatures) the staged recovery lanes
     fill WITHOUT re-touching `reconcile_once`: `stable_local_addr`,
     `tunnel_health`, `peer_reachability_step`, `roster_epoch_reconcile`.

Security boundary (design SSOT §7 / 5 self-healing invariants):
- `resolve_bind()` in `bridge-handoffd.py` remains the ONLY bind oracle. The
  `stable-addr` step here may RECORD desired-vs-observed drift, but it NEVER
  binds — the actual rebind decision stays in `reconcile_once`'s existing
  `resolve_bind()` path (which fails closed).
- This module never touches the receiver admission path (HMAC / allowlist /
  dedupe / `remote_addr`). It is daemon-side control-loop only.
- The status snapshot surface (`reconcile_status_snapshot`) carries observable
  state ONLY — step name, status, attempt count, timestamps. No secrets, no
  addresses asserted by a remote peer, no peer keys.

It never runs anything on import and has no third-party dependencies. It is
importable by both `bridge-handoffd.py` (the daemon) and the Lane-0 smoke.
"""

from __future__ import annotations

import os
import random
import sqlite3
from pathlib import Path
from typing import Any, Callable, Optional

import bridge_a2a_common as a2a

# --------------------------------------------------------------------------
# Backoff tunables (bounded invariant — design SSOT 5.4)
# --------------------------------------------------------------------------
#
# Every mutating/recovery step is BOUNDED: on a non-converged or error result
# the step's `next_eligible_ts` is pushed out by an exponential backoff with
# jitter, capped at `DEFAULT_BACKOFF_CAP_SECONDS`. On a converged/ok result the
# attempt counter resets and the step is immediately eligible again. The stubs
# shipped in Lane 0 do not mutate yet, but the bounded gate is already wired so
# the stage-lane implementers INHERIT it (they only fill the adapter body).
DEFAULT_BACKOFF_BASE_SECONDS = 2.0
DEFAULT_BACKOFF_CAP_SECONDS = 300.0
DEFAULT_BACKOFF_JITTER_FRAC = 0.20

# The ordered reconcile step identifiers. The sequence ORDER is defined by the
# orchestrator in `bridge-handoffd.py:reconcile_once`; this tuple is the
# canonical id set so the status snapshot and the smoke can enumerate every
# step even before its first attempt has been recorded.
STEP_STABLE_ADDR = "stable-addr"
STEP_BIND_REPROVE = "bind-reprove"
STEP_TUNNEL_HEALTH = "tunnel-health"
STEP_PEER_REACHABILITY = "peer-reachability"
STEP_ROSTER_EPOCH = "roster-epoch"

RECONCILE_STEPS = (
    STEP_STABLE_ADDR,
    STEP_BIND_REPROVE,
    STEP_TUNNEL_HEALTH,
    STEP_PEER_REACHABILITY,
    STEP_ROSTER_EPOCH,
)

# Canonical step-result statuses. A "converged"/"noop"/"ok" outcome resets the
# backoff; a "changed" outcome means the step applied a desired-state update
# this tick (still treated as progress → reset); "error" / any other
# non-converged status engages the bounded backoff.
RESULT_CONVERGED = "converged"
RESULT_CHANGED = "changed"
RESULT_NOOP = "noop"
RESULT_ERROR = "error"
_RESET_RESULTS = frozenset({RESULT_CONVERGED, RESULT_CHANGED, RESULT_NOOP, "ok"})


# --------------------------------------------------------------------------
# Typed step result — the contract the adapter stubs (and L1/L2/L3) return
# --------------------------------------------------------------------------


class ReconcileStepResult:
    """Outcome of one reconcile STEP (one adapter call).

    `status` is one of "converged" | "changed" | "error" | "noop":
      - "converged": desired == observed; nothing to do (resets backoff).
      - "changed":   the step applied a desired-state update this tick
                     (resets backoff — progress was made).
      - "noop":      the step did nothing this tick (e.g. an unimplemented
                     adapter stub, or a step skipped because it was not yet
                     eligible). Treated as non-failing (resets backoff).
      - "error":     the step could not converge (engages bounded backoff).

    `detail` is a short human string for logs / net-status (NEVER a secret).
    `fields` is an optional dict of observable, non-secret structured facts
    (e.g. {"observed": "...", "desired": "..."}) for net-status v2 (#1708).
    """

    __slots__ = ("status", "detail", "fields")

    def __init__(self, status: str, detail: str = "",
                 fields: Optional[dict[str, Any]] = None) -> None:
        self.status = status
        self.detail = detail
        self.fields = dict(fields) if fields else {}

    @property
    def is_progress(self) -> bool:
        """True when this result RESETS the backoff (converged/changed/noop)."""
        return self.status in _RESET_RESULTS

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return (f"ReconcileStepResult(status={self.status!r}, "
                f"detail={self.detail!r})")


def step_converged(detail: str = "",
                   fields: Optional[dict[str, Any]] = None) -> ReconcileStepResult:
    return ReconcileStepResult(RESULT_CONVERGED, detail, fields)


def step_changed(detail: str = "",
                 fields: Optional[dict[str, Any]] = None) -> ReconcileStepResult:
    return ReconcileStepResult(RESULT_CHANGED, detail, fields)


def step_noop(detail: str = "",
              fields: Optional[dict[str, Any]] = None) -> ReconcileStepResult:
    return ReconcileStepResult(RESULT_NOOP, detail, fields)


def step_error(detail: str = "",
               fields: Optional[dict[str, Any]] = None) -> ReconcileStepResult:
    return ReconcileStepResult(RESULT_ERROR, detail, fields)


# --------------------------------------------------------------------------
# Durable reconcile state store — state/handoff/reconcile.db
# --------------------------------------------------------------------------

_RECONCILE_SCHEMA = """
CREATE TABLE IF NOT EXISTS reconcile_step (
    step             TEXT PRIMARY KEY,
    last_attempt_ts  REAL,
    attempt_count    INTEGER NOT NULL DEFAULT 0,
    last_result      TEXT,
    next_eligible_ts REAL,
    updated_ts       REAL
);
"""


def reconcile_db_path(state_dir: Optional[Path] = None) -> Path:
    """Resolve the reconcile.db path.

    Honors `BRIDGE_A2A_RECONCILE_DB` (test override) first, then sits beside
    the other durable A2A state in `<state_dir>/handoff/reconcile.db`.
    """
    override = os.environ.get("BRIDGE_A2A_RECONCILE_DB")  # noqa: iso-helper-boundary
    if override:
        return Path(override)
    base = Path(state_dir) if state_dir is not None else a2a.handoff_dir()
    # Accept either a state_dir root (…/state) or the handoff dir directly.
    if base.name == "handoff":
        return base / "reconcile.db"
    return base / "handoff" / "reconcile.db"


def open_reconcile_db(state_dir: Optional[Path] = None) -> sqlite3.Connection:
    """Open (creating lazily) the durable reconcile state store.

    WAL journal, 0600 perms — mirrors the outbox/inbox `_connect` convention in
    bridge_a2a_common.py so the file ownership/journaling story is identical.
    """
    path = reconcile_db_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(_RECONCILE_SCHEMA)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return conn


def step_is_eligible(conn: sqlite3.Connection, step: str,
                     now: Optional[float] = None) -> bool:
    """Is `step` eligible to attempt right now?

    Eligible when there is no row yet (never attempted) OR `now` has reached
    the persisted `next_eligible_ts`. This is the bounded gate every mutating
    step is wrapped in — a backed-off step is SKIPPED (not attempted) until its
    cooldown elapses, so a flapping substrate cannot storm.
    """
    now = a2a.now_ts() if now is None else now
    row = conn.execute(
        "SELECT next_eligible_ts FROM reconcile_step WHERE step = ?",
        (step,),
    ).fetchone()
    if row is None:
        return True
    next_eligible = row["next_eligible_ts"]
    if next_eligible is None:
        return True
    return now >= float(next_eligible)


def _compute_next_eligible(attempt_count: int, now: float, *,
                           backoff_base: float, backoff_cap: float,
                           jitter_frac: float) -> float:
    """Exponential backoff + jitter, capped at `backoff_cap`.

    `attempt_count` is the NEW (post-increment) consecutive non-converged
    count. The raw delay is `backoff_base * 2**(attempt_count - 1)` capped at
    `backoff_cap`, then a symmetric jitter of ±`jitter_frac` is applied (and
    re-capped) so a fleet of daemons that all lost the same substrate at once
    do not retry in lockstep. `random.uniform` is fine here — this is
    production runtime code, not a workflow script.
    """
    exp = max(0, attempt_count - 1)
    # Guard the shift against an unbounded exponent (cap first in log space).
    try:
        raw = backoff_base * (2.0 ** exp)
    except OverflowError:
        raw = backoff_cap
    delay = min(raw, backoff_cap)
    if jitter_frac > 0.0:
        spread = delay * jitter_frac
        delay = delay + random.uniform(-spread, spread)
    # Re-clamp AFTER jitter so the cap is a HARD ceiling: jitter must never push
    # the delay above backoff_cap (the bounded invariant), and never below 0
    # (never schedule in the past).
    delay = max(0.0, min(delay, backoff_cap))
    return now + delay


def record_attempt(conn: sqlite3.Connection, step: str, result: str,
                   now: Optional[float] = None, *,
                   backoff_base: float = DEFAULT_BACKOFF_BASE_SECONDS,
                   backoff_cap: float = DEFAULT_BACKOFF_CAP_SECONDS,
                   jitter_frac: float = DEFAULT_BACKOFF_JITTER_FRAC) -> dict[str, Any]:
    """Record one step attempt and (re)compute its `next_eligible_ts`.

    THE bounded invariant lives here:
      - On a progress result (converged / changed / noop / ok): reset
        `attempt_count` → 0 and `next_eligible_ts` → now (immediately eligible).
      - On any other result (error / non-converged): increment `attempt_count`
        and push `next_eligible_ts` out by an exponential backoff + jitter,
        capped at `backoff_cap`.

    Returns the persisted row as a dict (for the status snapshot / logging).
    """
    now = a2a.now_ts() if now is None else now
    row = conn.execute(
        "SELECT attempt_count FROM reconcile_step WHERE step = ?",
        (step,),
    ).fetchone()
    prev_count = int(row["attempt_count"]) if row is not None else 0

    is_progress = result in _RESET_RESULTS
    if is_progress:
        attempt_count = 0
        next_eligible_ts = now
    else:
        attempt_count = prev_count + 1
        next_eligible_ts = _compute_next_eligible(
            attempt_count, now,
            backoff_base=backoff_base, backoff_cap=backoff_cap,
            jitter_frac=jitter_frac)

    conn.execute(
        """
        INSERT INTO reconcile_step
            (step, last_attempt_ts, attempt_count, last_result,
             next_eligible_ts, updated_ts)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(step) DO UPDATE SET
            last_attempt_ts  = excluded.last_attempt_ts,
            attempt_count    = excluded.attempt_count,
            last_result      = excluded.last_result,
            next_eligible_ts = excluded.next_eligible_ts,
            updated_ts       = excluded.updated_ts
        """,
        (step, now, attempt_count, result, next_eligible_ts, now),
    )
    conn.commit()
    return {
        "step": step,
        "last_attempt_ts": now,
        "attempt_count": attempt_count,
        "last_result": result,
        "next_eligible_ts": next_eligible_ts,
        "updated_ts": now,
    }


def step_status(conn: sqlite3.Connection, step: str) -> dict[str, Any]:
    """Return the persisted status for one step (observable, no secrets).

    A step that has never attempted returns a zero-state dict with status
    "unknown" so net-status can always enumerate the full step set.
    """
    row = conn.execute(
        """
        SELECT step, last_attempt_ts, attempt_count, last_result,
               next_eligible_ts, updated_ts
        FROM reconcile_step WHERE step = ?
        """,
        (step,),
    ).fetchone()
    if row is None:
        return {
            "step": step,
            "status": "unknown",
            "last_result": None,
            "attempt_count": 0,
            "last_attempt_ts": None,
            "next_eligible_ts": None,
            "updated_ts": None,
        }
    return {
        "step": row["step"],
        "status": row["last_result"] or "unknown",
        "last_result": row["last_result"],
        "attempt_count": int(row["attempt_count"]),
        "last_attempt_ts": row["last_attempt_ts"],
        "next_eligible_ts": row["next_eligible_ts"],
        "updated_ts": row["updated_ts"],
    }


def all_step_status(conn: sqlite3.Connection) -> dict[str, dict[str, Any]]:
    """Return the status of every canonical reconcile step (full enumeration).

    Steps that have never attempted are included with status "unknown" so the
    net-status surface is stable-shaped (always all 5 steps) before the first
    tick.
    """
    return {step: step_status(conn, step) for step in RECONCILE_STEPS}


# --------------------------------------------------------------------------
# Adapter SEAMS (STUBS — fixed signatures the staged lanes fill)
# --------------------------------------------------------------------------
#
# Each adapter returns a ReconcileStepResult. The Lane-0 stub body returns a
# `noop` ("adapter not yet implemented") so the orchestrated loop is SAFE
# before the real adapter lands. The stage lanes implement AGAINST THESE EXACT
# SIGNATURES and must NOT change the call shape (the orchestrator in
# `reconcile_once` is wired to these arguments).
#
# Invariant the implementers inherit: each adapter must compute desired-vs-
# observed and NO-OP when converged (idempotent), must NEVER raise for an
# operational failure (return step_error(...) instead — though the orchestrator
# also catches a stray raise as a final fail-safe), and must NEVER bind a
# socket or mutate the receiver admission path. Desired-state writes go to
# config; the actual bind stays behind resolve_bind() in bridge-handoffd.py.


def stable_local_addr(transport: str, cfg: dict[str, Any]) -> ReconcileStepResult:
    """STUB (#1705 fills) — detect the stable substrate listen address.

    Detect the stable address the receiver SHOULD listen on for `transport`
    (Tailscale: `tailscale ip -4` / existing proof; WARP: a real utun/Mesh
    address in 10.128.0.0/16 via hardened OS/interface inspection — NEVER a
    bare text/awk CIDR guess). Compares the OBSERVED stable address against the
    DESIRED listen address in `cfg`; returns:
      - step_converged() when they already agree,
      - step_changed(fields={"observed": <addr>, "desired": <addr>}) when the
        adapter UPDATED desired config (the actual rebind still goes through
        resolve_bind() in reconcile_once — this step only proposes config),
      - step_error() when the stable address could not be proven.

    Lane 0 ships a no-op stub: the address detection is not implemented yet, so
    the bind self-heal continues to run exclusively through the existing
    resolve_bind() path. `resolve_bind()` stays the only bind oracle.
    """
    return step_noop("stable_local_addr adapter not yet implemented (#1705)")


def tunnel_health(transport: str, cfg: dict[str, Any]) -> ReconcileStepResult:
    """STUB (#1706 fills) — per-transport tunnel/substrate liveness.

    Probe ONLY the configured `transport`'s substrate (a WARP install must
    never shell `tailscale`, and vice-versa) and report tunnel liveness.
    Returns step_converged() when the tunnel is healthy, or a result whose
    `fields` carries a `transport_degraded` boolean (True when the substrate is
    down/degraded) plus any non-secret health detail. On a degraded substrate
    the step returns step_error() so the bounded backoff paces re-probes.

    Lane 0 ships a no-op stub.
    """
    return step_noop("tunnel_health adapter not yet implemented (#1706)")


def peer_reachability_step(cfg: dict[str, Any],
                           conn: sqlite3.Connection) -> ReconcileStepResult:
    """STUB (#1707 fills) — advance the per-peer UP/SUSPECT/DOWN state machine.

    For each configured peer, compute observed reachability and advance its
    UP→SUSPECT→DOWN (and recovery) state machine, persisting per-peer backoff
    in `conn` (the same reconcile.db connection — peer rows are namespaced by
    the implementer, e.g. step ids like "peer-reachability:<peer_id>", so they
    inherit the bounded gate). An IP-drift that needs a rebind RECORDS the
    desired change; the rebind itself still routes through resolve_bind().
    Returns step_converged() when all peers are UP, step_changed() when a peer
    state advanced, or step_error() on a probe failure.

    Lane 0 ships a no-op stub.
    """
    return step_noop("peer_reachability_step adapter not yet implemented (#1707)")


def roster_epoch_reconcile(cfg: dict[str, Any],
                           conn: sqlite3.Connection) -> ReconcileStepResult:
    """STUB (#1695-P2 fills) — roster epoch anti-entropy.

    Compare this node's observed roster/membership epoch against the desired
    (leader-authored) epoch derived from rooms.db, and converge: pull a newer
    roster, or re-broadcast continuity, bounded by the backoff gate in `conn`.
    Membership is read from rooms.db / the roster cache — NEVER from a body-
    asserted claim. Returns step_converged() at the matching epoch,
    step_changed() when the roster advanced, or step_error() on a sync failure.

    Lane 0 ships a no-op stub.
    """
    return step_noop("roster_epoch_reconcile adapter not yet implemented (#1695-P2)")


# --------------------------------------------------------------------------
# Step orchestration — run one adapter through the bounded/eligible gate
# --------------------------------------------------------------------------


def run_step(conn: sqlite3.Connection, step: str,
             adapter: Callable[[], ReconcileStepResult],
             now: Optional[float] = None, *,
             backoff_base: float = DEFAULT_BACKOFF_BASE_SECONDS,
             backoff_cap: float = DEFAULT_BACKOFF_CAP_SECONDS,
             jitter_frac: float = DEFAULT_BACKOFF_JITTER_FRAC,
             on_event: Optional[Callable[[str, ReconcileStepResult], None]] = None,
             ) -> ReconcileStepResult:
    """Run ONE reconcile step through the eligible→attempt→record→emit pipeline.

    1. If the step is not yet eligible (backed off), SKIP it — return a noop
       WITHOUT touching the store (a skip is not an attempt). This is the
       bounded gate: a backed-off step is paced, never storms.
    2. Otherwise call `adapter()`. A stray RAISE is caught here and recorded as
       an `error` — it never propagates out of the tick (fail-safe). The
       adapter is also expected to return step_error() for an operational
       failure, but the catch is the final backstop.
    3. Record the outcome (resetting or backing off per `record_attempt`).
    4. Emit a structured per-step event via `on_event(step, result)` if given.

    Returns the ReconcileStepResult that was recorded (or the skip noop).
    """
    now = a2a.now_ts() if now is None else now

    if not step_is_eligible(conn, step, now):
        skipped = step_noop("backed off; not yet eligible")
        if on_event is not None:
            on_event(step, skipped)
        return skipped

    try:
        result = adapter()
        if not isinstance(result, ReconcileStepResult):
            # An adapter that returns the wrong type is a programming error,
            # not an operational one — degrade to error (bounded) rather than
            # crash the tick.
            result = step_error(
                f"adapter returned {type(result).__name__}, "
                "expected ReconcileStepResult")
    except Exception as exc:  # noqa: BLE001 - fail-safe: a step never crashes the tick
        result = step_error(f"adapter raised: {type(exc).__name__}: {exc}"[:200])

    record_attempt(conn, step, result.status, now,
                   backoff_base=backoff_base, backoff_cap=backoff_cap,
                   jitter_frac=jitter_frac)
    if on_event is not None:
        on_event(step, result)
    return result


# --------------------------------------------------------------------------
# Status snapshot surface (read-only; consumed by net-status v2 / #1708)
# --------------------------------------------------------------------------


def reconcile_status_snapshot(state_dir: Optional[Path] = None,
                              interval: Optional[int] = None) -> dict[str, Any]:
    """Read-only per-tick reconcile status for net-status v2 (#1708).

    Returns the STABLE shape:

        {
          "last_tick_ts": <float|None>,   # most-recent step updated_ts
          "interval": <int|None>,         # configured reconcile cadence (s)
          "steps": {
            "<step>": {
              "status": ..., "detail": ...(absent — see note),
              "attempt_count": ..., "next_eligible_ts": ...,
              "updated_ts": ..., "last_result": ..., "last_attempt_ts": ...
            }, ... (always all 5 canonical steps)
          }
        }

    NO SECRETS: the snapshot carries step ids, statuses, attempt counts and
    timestamps only — never a peer key, listen secret, or remote-asserted
    address. The reconcile.db is the source of truth; this is a pure read.
    On a missing/unopenable store the snapshot still returns the stable shape
    with every step "unknown" (degrade safe — never raise).
    """
    def _all_unknown() -> dict[str, dict[str, Any]]:
        return {step: {
            "step": step, "status": "unknown", "last_result": None,
            "attempt_count": 0, "last_attempt_ts": None,
            "next_eligible_ts": None, "updated_ts": None,
        } for step in RECONCILE_STEPS}

    steps: dict[str, dict[str, Any]] = {}
    last_tick_ts: Optional[float] = None

    # ★ Pure read surface (#1708): this MUST NOT create the store. A status
    # call before the daemon has ever reconciled returns the stable
    # all-unknown shape WITHOUT materializing reconcile.db (open_reconcile_db
    # would mkdir + WAL + schema, mutating state from a viewer/status path —
    # violating the observable-not-operable invariant). reconcile_db_path() is
    # pure (no I/O); only the daemon's attempt path creates the store.
    path = reconcile_db_path(state_dir)
    if not path.exists():
        steps = _all_unknown()
    else:
        conn: Optional[sqlite3.Connection] = None
        try:
            # Read-only URI open: no mkdir, no WAL/schema setup, no creation.
            # Fails closed (OSError/sqlite3.Error) on a vanished/locked/corrupt
            # store or a not-yet-schema'd db → degrade to the unknown shape.
            conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30.0)
            conn.row_factory = sqlite3.Row
            steps = all_step_status(conn)
            for entry in steps.values():
                ts = entry.get("updated_ts")
                if ts is not None and (last_tick_ts is None or ts > last_tick_ts):
                    last_tick_ts = ts
        except (sqlite3.Error, OSError):
            steps = _all_unknown()
        finally:
            if conn is not None:
                try:
                    conn.close()
                except sqlite3.Error:
                    pass

    return {
        "last_tick_ts": last_tick_ts,
        "interval": interval,
        "steps": steps,
    }
