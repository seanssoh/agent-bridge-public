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
import socket
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
    """Detect the stable substrate listen address and converge desired config (#1705).

    Detect the stable address the receiver SHOULD listen on for `transport`
    (Tailscale: the node's identity-keyed `tailscale ip` address — stable by
    construction; cloudflare-warp-mesh: a real utun/Mesh address in
    10.128.0.0/16 via hardened OS/interface inspection — NEVER a bare text/awk
    CIDR guess). Compares the OBSERVED stable address against the DESIRED
    `listen.address` in `cfg`, and returns:
      - step_converged() when they already agree (idempotent no-op),
      - step_changed(fields={"observed": <addr>, "desired": <addr>}) when this
        step UPDATED the desired config (the new `listen.address` is written via
        the atomic config writer; the ACTUAL rebind still goes through
        resolve_bind() in reconcile_once on the next tick — this step only
        proposes config),
      - step_error() when the stable address could not be PROVEN.

    Invariants (design SSOT agenda 5 / §7.1 / 5 self-healing invariants):
    - `resolve_bind()` stays the ONLY bind oracle. This step NEVER binds a
      socket; it only detects + writes desired config.
    - FAIL-CLOSED: the detectors return ONLY an address actually present on a
      live local interface / in the live `tailscale ip` set. On any uncertainty
      (CLI unavailable, no stable address yet, enumeration failure) we return
      step_error() — never a guessed/synthesized/configured-but-absent address.
    - ACTIVE-TRANSPORT-ONLY: a warp-mesh node never shells `tailscale` and a
      tailscale node never inspects WARP utun — the branch is on `transport`.
    - IDEMPOTENT: a no-op (step_converged) when desired already == observed.
    """
    # 0. RE-DERIVE + validate the transport from `cfg` itself (defense in depth,
    #    fail-closed). The orchestrator passes a `transport` arg, but on a
    #    MALFORMED/unknown `transport.kind` reconcile_once falls back to a GUESSED
    #    "tailscale" before calling this adapter. Detecting + persisting a stable
    #    address under a guessed transport would violate fail-closed AND
    #    active-transport-only, so we never trust the passed arg blindly: we
    #    re-derive the kind from `cfg` (which HARD-errors on a malformed/unknown
    #    transport block) and refuse if it raises or disagrees with `transport`.
    try:
        cfg_transport = a2a.transport_kind(cfg)
    except a2a.A2AError as exc:
        # Malformed/unknown transport.kind → do NOT guess, do NOT detect, do NOT
        # persist. Fail closed (the bind oracle surfaces the same config error).
        return step_error(
            f"stable-addr: refusing to detect under a malformed/unknown "
            f"transport config ({exc.code}): {exc}"[:200])
    if cfg_transport != transport:
        # The caller's arg disagrees with the config (e.g. a guessed fallback).
        # Trust the config-derived kind is the only safe move — but a mismatch
        # means the caller computed the wrong transport, so fail closed rather
        # than detect under either.
        return step_error(
            f"stable-addr: transport arg {transport!r} disagrees with config "
            f"transport {cfg_transport!r}; refusing to guess")

    # 1. Detect the proven stable address for the ACTIVE transport only. Any
    #    detector failure is an operational failure → step_error (bounded
    #    backoff), never a raise out of the adapter and never a bad address.
    try:
        if transport == a2a.TRANSPORT_TAILSCALE:
            observed = a2a.tailscale_stable_addr()
        elif transport == a2a.TRANSPORT_CLOUDFLARE_WARP_MESH:
            observed = a2a.warp_mesh_stable_addr()
        else:
            # Unknown/unsupported transport: do NOT guess. Fail closed. (Unreachable
            # after the transport_kind() validation above, which only returns a
            # SUPPORTED_TRANSPORTS member — kept as a belt-and-suspenders guard.)
            return step_error(
                f"stable-addr: unsupported transport {transport!r}")
    except a2a.A2AError as exc:
        # TailscaleUnavailable / CloudflareWarpUnavailable / stable_addr_none /
        # iface_enum_failed all land here — fail closed, pace via backoff.
        return step_error(f"stable-addr unprovable ({exc.code}): {exc}"[:200])

    observed = (observed or "").strip()
    if not observed:
        return step_error("stable-addr: detector returned an empty address")

    # 2. Compare against the DESIRED listen.address. A malformed `listen` block
    #    is a config error, not an address-drift — fail closed (the bind oracle
    #    will surface it too).
    listen = cfg.get("listen")
    if not isinstance(listen, dict):
        return step_error("stable-addr: config 'listen' is not an object")
    desired = listen.get("address")
    desired = desired.strip() if isinstance(desired, str) else ""

    # 3. Idempotent: already converged → no-op.
    if desired == observed:
        return step_converged(
            f"listen.address already at stable {transport} address",
            fields={"observed": observed, "desired": desired})

    # 4. Drift: PROPOSE the stable address as the new desired config, persisted
    #    atomically. The actual rebind still happens through resolve_bind() in
    #    reconcile_once on a subsequent tick — this step only proposes config.
    #    A persist failure is an operational failure → step_error (re-attempted
    #    under the bounded backoff), never a partial/torn write (the writer is
    #    atomic via os.replace).
    try:
        listen["address"] = observed
        cfg["listen"] = listen
        a2a.write_config_atomic(a2a.config_path(), cfg)
    except (OSError, a2a.A2AError) as exc:
        # Roll the in-memory desired back so a failed persist does not leave the
        # live cfg dict claiming a converged state it never wrote to disk.
        listen["address"] = desired
        cfg["listen"] = listen
        return step_error(
            f"stable-addr: failed to persist desired listen.address: {exc}"[:200])

    return step_changed(
        f"updated desired listen.address {desired or '(unset)'} -> {observed} "
        f"(stable {transport} address); rebind via resolve_bind() next tick",
        fields={"observed": observed, "desired": observed})


# --------------------------------------------------------------------------
# tunnel-health (#1706) — per-transport substrate freshness + WARP auto-bounce
# --------------------------------------------------------------------------
#
# The WARP MASQUE tunnel can silently go stale after a network change: the CLI
# keeps reporting `Connected` while the handshake ages out (live: 3153s) and
# established sessions RST even though a fresh SYN still passes. The steady-state
# recovery is the daemon's job (operator control-loop amendment / design SSOT 5.5
# "observable-not-operable"): on a PROVEN stale handshake the daemon auto-bounces
# the tunnel (`warp-cli disconnect` + `connect`), BOUNDED by the reconcile.db
# backoff gate `run_step` already applies (cap + exp backoff + jitter — no bounce
# storm). net-status only REPORTS freshness; it never bounces.

# How old (seconds) a WARP handshake may be before the tunnel is treated as
# degraded. Env-overridable; the live failure showed a 3153s handshake while
# `warp-cli status` still said `Connected`. 120s is comfortably above a healthy
# WARP keepalive cadence and well below the multi-minute stale window.
DEFAULT_WARP_HANDSHAKE_STALE_SECONDS = 120


def warp_handshake_stale_threshold() -> int:
    """Resolve the WARP handshake-age staleness threshold in seconds.

    `BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS` overrides the default. A
    non-numeric / non-positive override falls back to the default (a threshold
    of 0 would mark a fresh tunnel stale and bounce-storm — fail-safe).
    """
    raw = os.environ.get("BRIDGE_A2A_WARP_HANDSHAKE_STALE_SECONDS")  # noqa: iso-helper-boundary
    if raw is None or str(raw).strip() == "":
        return DEFAULT_WARP_HANDSHAKE_STALE_SECONDS
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_WARP_HANDSHAKE_STALE_SECONDS
    return val if val > 0 else DEFAULT_WARP_HANDSHAKE_STALE_SECONDS


def _default_warp_bounce() -> bool:
    """Bounce the WARP tunnel: `warp-cli disconnect` then `warp-cli connect`.

    The documented recovery for a stale MASQUE tunnel (forces a fresh
    handshake in seconds). Returns True when both legs ran; False (never
    raises) when `warp-cli` is unavailable or a leg failed — a failed bounce
    is recorded by the caller and re-paced by the backoff gate, it never
    crashes the tick. INJECTABLE via `_WARP_TUNNEL_BOUNCE` so the smoke can
    assert the bounce WAS invoked without touching a real host's WARP.
    """
    cli = a2a.resolve_warp_cli()
    if cli is None:
        return False
    try:
        # `_warp_cli_capture` returns (ran, output, rc) and never raises — a
        # disconnect/connect that fails is just a non-zero rc we treat as a
        # failed bounce (the backoff gate paces the retry).
        d_ran, _d_out, d_rc = a2a._warp_cli_capture(cli, ["disconnect"])
        c_ran, _c_out, c_rc = a2a._warp_cli_capture(cli, ["connect"])
    except Exception:  # noqa: BLE001 - a bounce never raises into the reconcile tick
        return False
    return bool(d_ran and c_ran and d_rc == 0 and c_rc == 0)


# Injectable bounce hook (module-level function reference). The daemon calls
# `_WARP_TUNNEL_BOUNCE()` on a proven-stale WARP tunnel. The smoke rebinds this
# to a spy so it can assert the bounce was invoked WITHOUT bouncing a real
# tunnel; production keeps `_default_warp_bounce`.
_WARP_TUNNEL_BOUNCE: Callable[[], bool] = _default_warp_bounce


def _tunnel_health_warp() -> ReconcileStepResult:
    """WARP substrate freshness probe + bounded auto-bounce (#1706).

    Reads the MASQUE handshake age (read-only `warp-cli tunnel stats`):
      - age UNKNOWABLE (warp-cli absent / unparseable) -> step_error with
        transport_degraded=True but NO bounce (fail-closed re-probe; a parse
        failure is not a proven stale handshake — never bounce on it).
      - age <= threshold -> step_converged (healthy, idempotent no-op; never
        bounces a fresh tunnel).
      - age  > threshold -> PROVEN stale: invoke the injectable bounce hook,
        return step_error with transport_degraded=True (engages the backoff
        gate so the NEXT bounce is paced — no storm). The bounce result is
        reported in fields for net-status (`bounced` bool), never a secret.
    """
    age = a2a.warp_tunnel_handshake_age()
    if age is None:
        # Unknowable freshness — fail closed (re-probe), but do NOT bounce: a
        # probe-parse failure is not a proven stale handshake.
        return step_error(
            "warp tunnel handshake age unknowable (warp-cli absent or no "
            "handshake line) — fail-closed re-probe, no bounce",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_known": False})

    threshold = warp_handshake_stale_threshold()
    if age <= threshold:
        return step_converged(
            f"warp tunnel fresh (handshake age {age}s <= {threshold}s)",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": False,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold})

    # PROVEN stale handshake -> auto-bounce (bounded by the run_step backoff
    # gate: this adapter only runs when the step is eligible, so a flapping
    # tunnel cannot bounce on every tick). The bounce hook never raises.
    try:
        bounced = bool(_WARP_TUNNEL_BOUNCE())
    except Exception as exc:  # noqa: BLE001 - the bounce is best-effort; a failure is paced, not fatal
        return step_error(
            f"warp tunnel stale (handshake age {age}s > {threshold}s); "
            f"auto-bounce raised {type(exc).__name__}",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold,
                    "bounced": False})
    return step_error(
        f"warp tunnel stale (handshake age {age}s > {threshold}s); "
        f"auto-bounce {'invoked' if bounced else 'attempted'}",
        fields={"transport": "cloudflare-warp-mesh",
                "transport_degraded": True,
                "handshake_age_seconds": age,
                "stale_threshold_seconds": threshold,
                "bounced": bounced})


def _tunnel_health_tailscale() -> ReconcileStepResult:
    """Tailscale substrate liveness probe (#1706).

    Surfaces `tailscale status --json` and detects tailnet-down / node-offline.
    Tailscale's own keepalive / DERP reconnect makes the WARP-style silent
    stale rare, so there is NO auto-bounce here — a down tailnet is reported
    (step_error, transport_degraded=True) and the bounded backoff paces the
    re-probe; recovery is Tailscale's own job. An unreachable CLI is itself a
    fail-closed degraded signal.
    """
    try:
        status = a2a.tailscale_status_json()
    except a2a.TailscaleUnavailable:
        return step_error(
            "tailscale status unavailable — fail-closed degraded",
            fields={"transport": "tailscale", "transport_degraded": True,
                    "backend_state": None, "self_online": None})
    backend = status.get("BackendState")
    self_node = status.get("Self")
    self_online = None
    if isinstance(self_node, dict):
        self_online = self_node.get("Online")
    # Healthy only when the backend is Running AND this node reports Online.
    # Anything else (NeedsLogin / Stopped / NoState / offline self) is a
    # degraded tailnet — report it, the backoff paces the re-check.
    degraded = not (backend == "Running" and self_online is True)
    if degraded:
        return step_error(
            f"tailscale degraded (BackendState={backend!r}, "
            f"Self.Online={self_online!r})",
            fields={"transport": "tailscale", "transport_degraded": True,
                    "backend_state": backend, "self_online": self_online})
    return step_converged(
        "tailscale up (BackendState=Running, Self.Online=True)",
        fields={"transport": "tailscale", "transport_degraded": False,
                "backend_state": backend, "self_online": self_online})


def tunnel_health(transport: str, cfg: dict[str, Any]) -> ReconcileStepResult:
    """Per-transport tunnel/substrate liveness (#1706).

    Probes ONLY the configured `transport`'s substrate — a WARP install never
    shells `tailscale`, and a Tailscale install never shells `warp-cli`. The
    common control loop branches here exactly once, on `transport`:

      - "cloudflare-warp-mesh": probe the MASQUE handshake AGE; on a PROVEN
        stale handshake (age > threshold, default 120s, env-overridable) the
        daemon AUTO-bounces the tunnel via the injectable `_WARP_TUNNEL_BOUNCE`
        hook (bounded by the run_step backoff gate so a flapping tunnel cannot
        storm). A fresh tunnel is a converged no-op (idempotent).
      - "tailscale": surface `tailscale status` and detect tailnet-down /
        node-offline (no auto-bounce — Tailscale self-heals via keepalive/DERP).
      - anything else: converged no-op (no substrate-specific probe defined;
        never shell a foreign transport's CLI).

    Returns step_converged() when the tunnel is healthy; on a degraded /
    unknowable substrate returns step_error() with `transport_degraded: True`
    plus non-secret health detail in `fields` (handshake age + status only —
    never tokens/keys), so the bounded backoff paces re-probes. Fail-safe: a
    probe error returns step_error() and NEVER raises into the tick; an
    unknowable state fails closed (treated as NOT-converged) but never triggers
    a bounce (only a proven stale handshake does).
    """
    if transport == a2a.TRANSPORT_CLOUDFLARE_WARP_MESH:
        return _tunnel_health_warp()
    if transport == a2a.TRANSPORT_TAILSCALE:
        return _tunnel_health_tailscale()
    # Unknown/unsupported transport: no substrate-specific probe. NO-OP rather
    # than error so an unrecognized kind does not engage the backoff gate or
    # shell a foreign CLI (active-transport-only).
    return step_noop(
        f"tunnel_health: no substrate probe for transport {transport!r}",
        fields={"transport": transport, "transport_degraded": False})


# --------------------------------------------------------------------------
# peer-reachability (#1707) — per-peer UP→SUSPECT→DOWN state machine + IP-drift
# --------------------------------------------------------------------------
#
# The daemon drives each configured peer through a hysteretic state machine so
# the mesh self-heals from a peer drop WITHOUT flapping on a single missed
# probe and WITHOUT a reconnect storm when the whole mesh loses a substrate at
# once (control-loop reframe / 5 self-healing invariants):
#
#   UP ──(miss)──▶ SUSPECT ──(N consecutive misses)──▶ DOWN ──(success)──▶ UP
#    ▲                │                                   │
#    └──── success ───┴──────────── success ─────────────┘
#
# Hysteresis: a SINGLE failed probe demotes UP→SUSPECT (not straight to DOWN);
# it takes `PEER_SUSPECT_THRESHOLD` consecutive misses to reach DOWN. A single
# success promotes any state back to UP (recovery is immediate once the path is
# proven live again). Bounded: the per-peer reconnect cadence rides the SAME
# reconcile.db backoff gate as every other step — each peer is namespaced as a
# step id `"peer-reachability:<peer_id>"`, so `step_is_eligible` /
# `record_attempt` apply the cap + exponential backoff + jitter per peer (a
# flapping peer cannot probe on every tick; a DOWN peer paces its reconnects).
#
# IP-drift (the live-discovered #1707 failure): when a peer is unreachable AND
# this node's own `listen.address` is no longer present on any local interface
# (the LAN IP vanished after a network move), we RECORD the desired rebind by
# delegating to `stable_local_addr()` (which proposes the corrected
# `listen.address` and persists it atomically). The ACTUAL rebind still routes
# through `resolve_bind()` in `reconcile_once` on a subsequent tick — this step
# NEVER binds. Fail-closed: `stable_local_addr` only ever proposes an address
# proven present on a live local interface; an unprovable address is never
# synthesized.

# Per-peer FSM states (persisted in reconcile.db `peer_reachability.state`).
PEER_STATE_UP = "up"
PEER_STATE_SUSPECT = "suspect"
PEER_STATE_DOWN = "down"

# How many CONSECUTIVE failed probes demote a peer all the way to DOWN. The
# first miss moves UP→SUSPECT; the `PEER_SUSPECT_THRESHOLD`-th consecutive miss
# moves SUSPECT→DOWN. >=2 guarantees a single dropped probe never flaps a
# healthy peer to DOWN (the hysteresis invariant). Env-overridable; a
# non-numeric / <2 override falls back to the default (a threshold of 1 would
# defeat hysteresis — fail-safe).
DEFAULT_PEER_SUSPECT_THRESHOLD = 3

# Short outbound-probe connect timeout (seconds). Mirrors the `peers test` /
# net-status `_a2a_tcp_probe` mechanic — a TCP connect only, no enqueue/auth.
# Kept small so a single unreachable peer cannot stall the reconcile tick.
DEFAULT_PEER_PROBE_TIMEOUT_SECONDS = 3.0


def peer_suspect_threshold() -> int:
    """Resolve the consecutive-miss threshold that demotes a peer to DOWN.

    `BRIDGE_A2A_PEER_SUSPECT_THRESHOLD` overrides the default. A non-numeric or
    <2 override falls back to the default (a threshold of 1 would defeat the
    hysteresis invariant by flapping a healthy peer to DOWN on one miss —
    fail-safe).
    """
    raw = os.environ.get("BRIDGE_A2A_PEER_SUSPECT_THRESHOLD")  # noqa: iso-helper-boundary
    if raw is None or str(raw).strip() == "":
        return DEFAULT_PEER_SUSPECT_THRESHOLD
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_PEER_SUSPECT_THRESHOLD
    return val if val >= 2 else DEFAULT_PEER_SUSPECT_THRESHOLD


def peer_probe_timeout() -> float:
    """Resolve the per-peer TCP-connect probe timeout in seconds.

    `BRIDGE_A2A_PEER_PROBE_TIMEOUT_SECONDS` overrides the default. A
    non-numeric / non-positive override falls back to the default (a timeout of
    0 would make every probe fail instantly and storm-demote the mesh —
    fail-safe).
    """
    raw = os.environ.get("BRIDGE_A2A_PEER_PROBE_TIMEOUT_SECONDS")  # noqa: iso-helper-boundary
    if raw is None or str(raw).strip() == "":
        return DEFAULT_PEER_PROBE_TIMEOUT_SECONDS
    try:
        val = float(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_PEER_PROBE_TIMEOUT_SECONDS
    return val if val > 0.0 else DEFAULT_PEER_PROBE_TIMEOUT_SECONDS


_PEER_REACHABILITY_SCHEMA = """
CREATE TABLE IF NOT EXISTS peer_reachability (
    peer_id           TEXT PRIMARY KEY,
    state             TEXT NOT NULL,
    consecutive_fail  INTEGER NOT NULL DEFAULT 0,
    last_state_ts     REAL,
    updated_ts        REAL
);
"""


def _ensure_peer_reachability_schema(conn: sqlite3.Connection) -> None:
    """Create the per-peer FSM table if absent (idempotent).

    Lives in the SAME reconcile.db `conn` the backoff store uses — peer FSM
    state is generic transport-recovery state, exactly what reconcile.db is
    for (design SSOT agenda 1: NOT rooms.db, which is room membership only).
    """
    conn.executescript(_PEER_REACHABILITY_SCHEMA)


def _peer_step_id(peer_id: str) -> str:
    """The reconcile-step id a peer's bounded backoff gate is namespaced under.

    Each peer inherits the cap + exp-backoff + jitter pacing of the shared
    `reconcile_step` store via this id (e.g. `peer-reachability:node-2`), so a
    DOWN peer's reconnect cadence is bounded exactly like every other step.
    """
    return f"{STEP_PEER_REACHABILITY}:{peer_id}"


def _peer_state_row(conn: sqlite3.Connection, peer_id: str) -> tuple[str, int]:
    """Return `(state, consecutive_fail)` for a peer (UP/0 when unseen).

    A never-probed peer starts optimistically UP with 0 consecutive failures —
    the first probe result is what drives it off UP, and a healthy peer that
    has never failed is correctly reported UP (idempotent no-op).
    """
    row = conn.execute(
        "SELECT state, consecutive_fail FROM peer_reachability WHERE peer_id = ?",
        (peer_id,),
    ).fetchone()
    if row is None:
        return PEER_STATE_UP, 0
    return str(row["state"]), int(row["consecutive_fail"])


def _write_peer_state(conn: sqlite3.Connection, peer_id: str, state: str,
                      consecutive_fail: int, now: float,
                      *, state_changed: bool) -> None:
    """Persist a peer's FSM state (no secrets — peer id + state + counters only).

    `last_state_ts` only advances when the STATE label actually changed, so the
    observable surface can report "how long in this state". `updated_ts` always
    advances (every probe touches the row).
    """
    if state_changed:
        conn.execute(
            """
            INSERT INTO peer_reachability
                (peer_id, state, consecutive_fail, last_state_ts, updated_ts)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(peer_id) DO UPDATE SET
                state            = excluded.state,
                consecutive_fail = excluded.consecutive_fail,
                last_state_ts    = excluded.last_state_ts,
                updated_ts       = excluded.updated_ts
            """,
            (peer_id, state, consecutive_fail, now, now),
        )
    else:
        conn.execute(
            """
            INSERT INTO peer_reachability
                (peer_id, state, consecutive_fail, last_state_ts, updated_ts)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(peer_id) DO UPDATE SET
                state            = excluded.state,
                consecutive_fail = excluded.consecutive_fail,
                updated_ts       = excluded.updated_ts
            """,
            (peer_id, state, consecutive_fail, now, now),
        )
    conn.commit()


def _default_peer_probe(address: str, port: int, timeout: float) -> bool:
    """Lightweight outbound reachability probe: a TCP connect to address:port.

    The A2A reachability ORACLE, identical to the `peers test` / net-status
    `_a2a_tcp_probe` mechanic — `socket.create_connection`, NO enqueue, NO
    auth, NO `tailscale ping` (a disco-protocol echo is not a receiver-up
    signal). Returns True iff the TCP handshake completed; False on ANY OSError
    (connection refused / timeout / host unreachable). Never raises — an
    unreachable peer is a normal state-machine input, not an exception.

    INJECTABLE via `_PEER_REACHABILITY_PROBE` so the smoke can drive the FSM
    deterministically without touching a real network.
    """
    if not address:
        return False
    try:
        with socket.create_connection((address, port), timeout=timeout):
            return True
    except OSError:
        return False


# Injectable probe hook (module-level function reference). The daemon calls
# `_PEER_REACHABILITY_PROBE(address, port, timeout)` per peer. The smoke
# rebinds this to a spy/scripted function so it can drive UP/SUSPECT/DOWN/
# recovery transitions WITHOUT a real socket; production keeps the real TCP
# probe. Mirrors the L2 `_WARP_TUNNEL_BOUNCE` injection convention.
_PEER_REACHABILITY_PROBE: Callable[[str, int, float], bool] = _default_peer_probe


def _local_listen_address_drifted(transport: str,
                                  cfg: dict[str, Any]) -> Optional[bool]:
    """Is this node's OWN `listen.address` no longer on any local interface?

    The IP-drift signal: a `listen.address` that was a LAN IP can vanish from
    every interface after a network move, so the receiver can no longer bind it
    (`bind_not_warp_local`). Returns:
      - True  — a non-empty `listen.address` is configured but absent from the
                live interface set (drift → a rebind should be RECORDED),
      - False — the address is present (no drift), or none is configured yet,
      - None  — the interface set is UNKNOWABLE (enumeration failed). Fail
                closed: an unknowable interface set is NOT treated as drift
                (we never propose a rebind we cannot prove is needed; the
                stable-addr step itself fails closed on the same uncertainty).

    Active-transport-only: only the WARP raw-IP path actually drifts this way;
    a Tailscale node is identity-keyed and its bind address does not vanish on a
    move, so we skip the check entirely for non-WARP transports (returning False
    = no drift) rather than enumerate interfaces for a transport that cannot
    exhibit the failure.
    """
    if transport != a2a.TRANSPORT_CLOUDFLARE_WARP_MESH:
        return False
    listen = cfg.get("listen")
    if not isinstance(listen, dict):
        return False
    addr = listen.get("address")
    addr = addr.strip() if isinstance(addr, str) else ""
    if not addr:
        # No configured listen address to drift away from yet.
        return False
    try:
        local_addrs = a2a.local_interface_addresses()
    except a2a.A2AError:
        # Interface enumeration failed — UNKNOWABLE. Fail closed: do not claim
        # drift we cannot prove (and do not propose a rebind on a guess).
        return None
    return not a2a.is_local_interface_address(addr, local_addrs)


def peer_reachability_step(cfg: dict[str, Any],
                           conn: sqlite3.Connection) -> ReconcileStepResult:
    """Advance the per-peer UP→SUSPECT→DOWN→(recovery)→UP state machine (#1707).

    For each configured peer this step probes reachability via a lightweight
    INJECTABLE outbound TCP connect (`_PEER_REACHABILITY_PROBE`, default a real
    `socket.create_connection` to the peer's transport-resolved `address:port`)
    and advances a HYSTERETIC state machine persisted per-peer in `conn` (the
    reconcile.db connection):

      - a probe SUCCESS promotes any state straight back to `up` (recovery is
        immediate once the path is proven live, resets the failure counter);
      - a probe MISS demotes `up` → `suspect` on the FIRST miss and only reaches
        `down` after `peer_suspect_threshold()` CONSECUTIVE misses (hysteresis —
        one dropped probe never flaps a healthy peer to DOWN).

    Bounded: each peer's probe/reconnect cadence rides the SAME reconcile.db
    backoff gate as every step — namespaced as the step id
    `peer-reachability:<peer_id>` — so a non-UP peer is SKIPPED (paced) until
    its per-peer cooldown elapses (cap + exponential backoff + jitter). A peer
    that is UP/converged resets its backoff and is immediately re-eligible.

    IP-drift LAN→WARP rebind: when at least one peer is unreachable AND this
    node's own `listen.address` is no longer present on any local interface
    (the LAN IP vanished after a network move), the desired rebind is RECORDED
    by delegating to `stable_local_addr(transport, cfg)` — which PROPOSES the
    corrected stable `listen.address` (persisted atomically). The ACTUAL rebind
    still routes through `resolve_bind()` in `reconcile_once`; this step never
    binds a socket.

    Returns:
      - step_converged() when every peer is UP and there is no recorded drift
        (idempotent no-op — repeated ticks on an all-UP mesh do nothing);
      - step_changed() when a peer's STATE advanced this tick OR a desired
        rebind was recorded;
      - step_error() on a probe-infrastructure failure (config malformed,
        address unresolvable) — fail-closed: an unknowable reachability is NOT
        treated as UP.

    Invariants (design SSOT §7 / 5 self-healing invariants):
    - NEVER binds a socket and NEVER touches the receiver admission path
      (HMAC / allowlist / dedupe / remote_addr); `resolve_bind()` stays the
      only bind oracle and IP-drift only RECORDS desired config.
    - ACTIVE-TRANSPORT-ONLY: peer addresses resolve through the configured
      transport's resolver; no cross-shelling.
    - NO SECRETS: persisted rows and result `fields` carry peer ids + states +
      counts + timestamps only — never a peer key / HMAC secret / token.
    - FAIL-SAFE: an operational failure returns step_error() (the run_step
      backstop also catches a stray raise); it never crashes the tick.
    """
    # Derive the active transport from cfg itself (fail-closed on a malformed
    # transport block — same defense as stable_local_addr). A bad config is an
    # operational error → step_error (bounded), never a guessed probe.
    try:
        transport = a2a.transport_kind(cfg)
    except a2a.A2AError as exc:
        return step_error(
            f"peer-reachability: malformed/unknown transport "
            f"({exc.code}): {exc}"[:200])

    peers = cfg.get("peers")
    if not isinstance(peers, list):
        return step_error("peer-reachability: config 'peers' is not a list")

    # No peers configured (early-install / probe state) → converged no-op.
    peer_ids = [str(p.get("id")) for p in peers
                if isinstance(p, dict) and p.get("id")]
    if not peer_ids:
        return step_converged("peer-reachability: no peers configured",
                              fields={"peers_total": 0, "peers_up": 0})

    _ensure_peer_reachability_schema(conn)

    threshold = peer_suspect_threshold()
    timeout = peer_probe_timeout()
    now = a2a.now_ts()
    listen = cfg.get("listen") if isinstance(cfg.get("listen"), dict) else {}
    default_port = int(listen.get("port", 8787) or 8787)

    any_state_changed = False
    any_unreachable = False
    peers_up = 0
    peer_summaries: list[dict[str, Any]] = []

    for peer in peers:
        if not isinstance(peer, dict) or not peer.get("id"):
            continue
        peer_id = str(peer["id"])
        step_id = _peer_step_id(peer_id)
        prev_state, prev_fail = _peer_state_row(conn, peer_id)

        # Bounded gate: a non-eligible (backed-off) peer is SKIPPED this tick —
        # we do NOT probe it (paces reconnects; a DOWN peer cannot probe every
        # tick). Its persisted state stands; report it as-is.
        if not step_is_eligible(conn, step_id, now):
            if prev_state == PEER_STATE_UP:
                peers_up += 1
            else:
                any_unreachable = True
            peer_summaries.append(
                {"peer": peer_id, "state": prev_state, "probed": False,
                 "consecutive_fail": prev_fail})
            continue

        # Resolve the peer's CURRENT target address through the configured
        # transport's resolver. A resolve failure is an operational error for
        # THIS peer (record an attempt so the backoff paces it) but never an
        # uncaught raise — we treat it as unreachable (fail-closed: unknowable
        # ≠ UP). `probe_err_code` is a CLOSED-SET classification token only
        # (an A2AError `.code`, or a fixed `probe_exception`/`unresolved_addr`)
        # — NEVER the free-text exception message, so no resolver/probe string
        # can leak into the result `fields` (no-secret contract: codes/states/
        # counts/timestamps only).
        probe_err_code = ""
        try:
            address = a2a.resolve_peer_address_for_transport(transport, peer)
        except a2a.A2AError as exc:
            address = ""
            probe_err_code = str(exc.code or "resolve_error")

        port = default_port
        try:
            if peer.get("port") is not None:
                port = int(peer["port"])
        except (TypeError, ValueError):
            port = default_port

        if address:
            try:
                reachable = bool(_PEER_REACHABILITY_PROBE(address, port, timeout))
            except Exception:  # noqa: BLE001 - a probe never raises into the tick
                reachable = False
                # Fixed token only — never the exception's str()/repr().
                probe_err_code = "probe_exception"
        else:
            # No resolvable address → unreachable (fail-closed, never UP).
            reachable = False
            if not probe_err_code:
                probe_err_code = "unresolved_addr"

        # Drive the hysteretic FSM.
        if reachable:
            new_state = PEER_STATE_UP
            new_fail = 0
        else:
            new_fail = prev_fail + 1
            if new_fail >= threshold:
                new_state = PEER_STATE_DOWN
            else:
                # First miss (and any miss below threshold) → SUSPECT, never
                # straight to DOWN (hysteresis).
                new_state = PEER_STATE_SUSPECT

        state_changed = new_state != prev_state
        _write_peer_state(conn, peer_id, new_state, new_fail, now,
                          state_changed=state_changed)

        # Record this probe against the peer's bounded backoff gate: a reachable
        # peer is "converged" (resets backoff, immediately re-eligible); an
        # unreachable peer is "error" (engages cap + exp backoff + jitter so its
        # next probe/reconnect is paced).
        record_attempt(conn, step_id,
                       RESULT_CONVERGED if reachable else RESULT_ERROR, now)

        if reachable:
            peers_up += 1
        else:
            any_unreachable = True
        if state_changed:
            any_state_changed = True

        summary: dict[str, Any] = {
            "peer": peer_id, "state": new_state, "probed": True,
            "consecutive_fail": new_fail}
        if probe_err_code:
            # A CLOSED-SET classification code ONLY (resolver A2AError code /
            # probe_exception / unresolved_addr) — never a free-text message,
            # so no resolver/probe string can ride into net-status fields.
            summary["probe_err_code"] = probe_err_code
        peer_summaries.append(summary)

    # IP-drift LAN→WARP rebind: only when at least one peer is unreachable AND
    # this node's own listen.address has vanished from every local interface.
    # We RECORD the desired rebind via stable_local_addr (which proposes +
    # persists the corrected address atomically); the actual bind still happens
    # through resolve_bind() in reconcile_once. We NEVER bind here.
    rebind_recorded = False
    if any_unreachable:
        drifted = _local_listen_address_drifted(transport, cfg)
        if drifted is True:
            drift_res = stable_local_addr(transport, cfg)
            # stable_local_addr returns step_changed when it actually updated
            # the desired listen.address (the rebind we want recorded). A
            # converged/error result means there was nothing to (or it could
            # not) record — we do not force a change in that case.
            if drift_res.status == RESULT_CHANGED:
                rebind_recorded = True
                any_state_changed = True

    fields: dict[str, Any] = {
        "transport": transport,
        "peers_total": len(peer_ids),
        "peers_up": peers_up,
        "peers": peer_summaries,
        "ip_drift_rebind_recorded": rebind_recorded,
    }

    # A state advance (a peer transition or a recorded rebind) is PROGRESS this
    # tick → report step_changed even if the mesh is now fully up (a down→up
    # recovery must not be reported as a converged no-op — it advanced state).
    if any_state_changed:
        return step_changed(
            f"{peers_up}/{len(peer_ids)} peer(s) up"
            + (" + IP-drift rebind recorded" if rebind_recorded else ""),
            fields=fields)
    # All peers UP, nothing advanced, no recorded drift → converged
    # (idempotent no-op — repeated ticks on a steady all-up mesh do nothing).
    if peers_up == len(peer_ids) and not rebind_recorded:
        return step_converged(
            f"all {peers_up} peer(s) up", fields=fields)
    # Some peers are non-UP but no state advanced this tick (e.g. a DOWN peer
    # still down, or paced-out peers) — not converged, but no progress. Report
    # as error so the step's OWN backoff paces the aggregate re-evaluation
    # (fail-closed: a not-all-up mesh is not "converged").
    return step_error(
        f"{peers_up}/{len(peer_ids)} peer(s) up (mesh not fully reachable)",
        fields=fields)


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
