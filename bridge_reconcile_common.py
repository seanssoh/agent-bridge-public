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

# The reconcile timer cadence (seconds). The daemon (bridge-handoffd.py) owns
# the live timer and carries its OWN copy of this default + resolver for the
# loop; this parallel read-only resolver lets the net-status v2 snapshot (#1708)
# surface the SAME configured cadence WITHOUT importing the heavyweight daemon
# module. Both read `BRIDGE_A2A_RECONCILE_INTERVAL`; keep the default in sync.
DEFAULT_RECONCILE_INTERVAL_SECONDS = 45


def reconcile_interval() -> int:
    """Resolve the configured reconcile cadence in seconds (read-only).

    Honors `BRIDGE_A2A_RECONCILE_INTERVAL` (the same knob the daemon timer
    reads); 0 means the periodic timer is disabled. A non-numeric override
    falls back to the default. This is a PURE env read with no I/O — the
    net-status snapshot calls it to report the cadence the daemon WOULD tick at,
    never to drive a timer.
    """
    raw = os.environ.get("BRIDGE_A2A_RECONCILE_INTERVAL", "")  # noqa: iso-helper-boundary
    if raw == "":
        return DEFAULT_RECONCILE_INTERVAL_SECONDS
    try:
        val = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_RECONCILE_INTERVAL_SECONDS
    return max(0, val)

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
    # #1728 r2: guard the ACTUAL resolved reconcile.db path. The r1 guard keyed
    # on the env-resolved state dir and SKIPPED entirely when BRIDGE_A2A_RECONCILE_DB
    # was set — so the override could still land reconcile.db on a live tree under
    # the test-bind flag (codex HIGH data-loss). Now resolve the final path first
    # (state_dir arg OR BRIDGE_A2A_RECONCILE_DB override OR default) and guard THAT
    # path. Reuses the a2a-common db-path guard (this module already imports `a2a`):
    # no-op when the flag is unset (prod) or the resolved path is under BRIDGE_HOME
    # (correctly isolated mesh, including an override / state_dir arg under home).
    path = reconcile_db_path(state_dir)
    a2a.guard_test_bind_db_path(path, what="reconcile db path")
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


def stable_local_addr(transport: str, cfg: dict[str, Any],
                      config_path: Optional[Path] = None) -> ReconcileStepResult:
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
        # Persist to the ACTIVE config the receiver loaded — `config_path` when
        # the daemon was started with `serve --config <path>`, else the default
        # (BRIDGE_A2A_CONFIG / bridge-home) resolved by a2a.config_path(). Without
        # this the writer would drift the DEFAULT file while the receiver keeps
        # reloading the unchanged custom file, re-proposing the same drift every
        # tick and never converging (integration review #11573, the cross-lane
        # L0×L1×L3 config_path seam).
        a2a.write_config_atomic(config_path or a2a.config_path(), cfg)
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


def _default_warp_soft_refresh() -> bool:
    """Soft-refresh the WARP tunnel: a NON-disruptive `warp-cli connect` nudge.

    The gentle FIRST step before a full disconnect/connect bounce (#1733): an
    idempotent `warp-cli connect` forces a fresh MASQUE handshake on an
    idle-but-live tunnel WITHOUT a `warp-cli disconnect` — so the `10.128.x`
    A2A mesh that RIDES this same tunnel is never torn down. A handshake that
    is merely idle (not broken) refreshes here, and the next tick sees a fresh
    age, so the full bounce is never reached.

    INVARIANT: this MUST NOT call `warp-cli disconnect` (that is the very
    self-severance #1733 is fixing). It only `connect`s. Returns True when the
    connect leg ran rc=0; False (never raises) when `warp-cli` is unavailable or
    the connect failed — a failed soft-refresh is recorded by the caller and the
    gate falls through to the (still gated) full bounce, it never crashes the
    tick. INJECTABLE via `_WARP_TUNNEL_SOFT_REFRESH` so the smoke can assert the
    soft-refresh ran (and that it never disconnects) without touching real WARP.
    """
    cli = a2a.resolve_warp_cli()
    if cli is None:
        return False
    try:
        # `connect` ONLY — never `disconnect`. `_warp_cli_capture` never raises;
        # a non-zero rc is just a failed nudge the caller records.
        c_ran, _c_out, c_rc = a2a._warp_cli_capture(cli, ["connect"])
    except Exception:  # noqa: BLE001 - a soft-refresh never raises into the reconcile tick
        return False
    return bool(c_ran and c_rc == 0)


# Injectable soft-refresh hook (module-level function reference). The daemon
# calls `_WARP_TUNNEL_SOFT_REFRESH()` BEFORE a full bounce once the stale +
# fresh-peer-loss + N-streak gate is satisfied. The smoke rebinds this to a spy
# so it can assert the soft-refresh ran first WITHOUT touching a real tunnel;
# production keeps `_default_warp_soft_refresh`. Mirrors the `_WARP_TUNNEL_BOUNCE`
# injection convention.
_WARP_TUNNEL_SOFT_REFRESH: Callable[[], bool] = _default_warp_soft_refresh


# --- #1733 bounce-gating tunables -----------------------------------------
#
# The #1706 adapter bounced the WHOLE WARP tunnel on handshake-idle ALONE (age
# > threshold), even when every peer was demonstrably UP — severing the very
# mesh that rides the tunnel. The fix (codex design-consensus #11698) gates the
# full disconnect/connect bounce on a CORRELATION of signals, never idle alone:
#   stale handshake AND >=N consecutive stale ticks AND >=1 FRESH peer down/
#   suspect AND a soft-refresh was tried first.
#
# Consecutive-stale streak required before the gate even considers a bounce.
# >=2 guarantees a single idle tick (the normal MASQUE-idle case) NEVER bounces.
# Env-overridable; a non-numeric / <2 override falls back to the default (a
# streak of 1 would defeat the "idle != broken" hysteresis — fail-safe).
DEFAULT_WARP_STALE_STREAK_THRESHOLD = 2

# Peer-FSM freshness window: a peer's persisted state only COUNTS toward the
# bounce decision when its `updated_ts` is within this many seconds of now. The
# peer-reachability step runs AFTER tunnel-health, so the state tunnel-health
# reads is one tick old — fine for a 120s+ decision, but a state STALER than a
# small multiple of the reconcile interval is treated as UNKNOWN (neither "all
# up" proof nor "loss" proof), so a never-probed / long-idle peer table can
# never be read as a reachability loss. Resolved as a multiple of the reconcile
# interval (default 45s * 4 = 180s) so it tracks the configured cadence.
DEFAULT_WARP_PEER_FRESHNESS_INTERVAL_MULTIPLE = 4


def warp_stale_streak_threshold() -> int:
    """Resolve the consecutive-stale streak required before a bounce (#1733).

    `BRIDGE_A2A_WARP_STALE_STREAK_THRESHOLD` overrides the default. A
    non-numeric / <2 override falls back to the default (a streak of 1 would
    bounce on a single idle tick — the exact #1733 over-aggression — fail-safe).
    """
    raw = os.environ.get("BRIDGE_A2A_WARP_STALE_STREAK_THRESHOLD")  # noqa: iso-helper-boundary
    if raw is None or str(raw).strip() == "":
        return DEFAULT_WARP_STALE_STREAK_THRESHOLD
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_WARP_STALE_STREAK_THRESHOLD
    return val if val >= 2 else DEFAULT_WARP_STALE_STREAK_THRESHOLD


def warp_peer_freshness_window() -> float:
    """Resolve the peer-FSM freshness window in seconds (#1733).

    A peer's persisted reachability state only counts toward the bounce decision
    when probed within this window. Derived from the reconcile cadence so it
    tracks the configured tick rate. `BRIDGE_A2A_WARP_PEER_FRESHNESS_SECONDS`
    overrides the derived value directly; a non-numeric / non-positive override
    falls back to the derived window (never 0 — a 0 window would make every
    state UNKNOWN and suppress every bounce — fail-safe toward not-bouncing,
    which is the safer direction for #1733).
    """
    raw = os.environ.get("BRIDGE_A2A_WARP_PEER_FRESHNESS_SECONDS")  # noqa: iso-helper-boundary
    if raw is not None and str(raw).strip() != "":
        try:
            val = float(str(raw).strip())
            if val > 0.0:
                return val
        except (TypeError, ValueError):
            pass
    interval = reconcile_interval()
    if interval <= 0:
        # Periodic timer disabled — fall back to the default cadence so the
        # window is still a sane, non-zero multiple rather than collapsing to 0.
        interval = DEFAULT_RECONCILE_INTERVAL_SECONDS
    return float(interval * DEFAULT_WARP_PEER_FRESHNESS_INTERVAL_MULTIPLE)


# Durable tunnel-health gate state (#1733): the consecutive-stale STREAK and the
# last observable bounce-suppressed reason, persisted in reconcile.db so the
# N-consecutive gate survives across ticks (and a daemon restart) and net-status
# v2 can surface WHY a stale tunnel was NOT bounced. Single row keyed by
# transport. Lives in the SAME reconcile.db as the backoff + peer FSM state.
_TUNNEL_HEALTH_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tunnel_health_state (
    transport               TEXT PRIMARY KEY,
    stale_streak            INTEGER NOT NULL DEFAULT 0,
    last_bounce_suppressed_reason TEXT,
    soft_refresh_attempted  INTEGER NOT NULL DEFAULT 0,
    updated_ts              REAL
);
"""

# Observable bounce-suppressed reasons (no secrets — fixed enum strings only).
BOUNCE_SUPPRESSED_ALL_PEERS_FRESH_UP = "all_peers_fresh_up"
BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN = "peer_state_unknown_or_stale"
BOUNCE_SUPPRESSED_STALE_STREAK_BELOW_N = "stale_streak_below_threshold"


def _ensure_tunnel_health_state_schema(conn: sqlite3.Connection) -> None:
    """Create the tunnel-health gate-state table if absent (idempotent)."""
    conn.executescript(_TUNNEL_HEALTH_STATE_SCHEMA)


def _tunnel_health_state_row(conn: sqlite3.Connection,
                             transport: str) -> tuple[int, Optional[str]]:
    """Return `(stale_streak, last_bounce_suppressed_reason)` for a transport.

    A never-seen transport starts at streak 0 / reason None (a fresh tunnel has
    no stale history). Read-only — never creates the row.
    """
    row = conn.execute(
        "SELECT stale_streak, last_bounce_suppressed_reason "
        "FROM tunnel_health_state WHERE transport = ?",
        (transport,),
    ).fetchone()
    if row is None:
        return 0, None
    return int(row["stale_streak"] or 0), row["last_bounce_suppressed_reason"]


def _write_tunnel_health_state(conn: sqlite3.Connection, transport: str,
                               stale_streak: int,
                               suppressed_reason: Optional[str],
                               soft_refresh_attempted: bool,
                               now: float) -> None:
    """Persist the tunnel-health gate state (no secrets — counters + enum only)."""
    conn.execute(
        """
        INSERT INTO tunnel_health_state
            (transport, stale_streak, last_bounce_suppressed_reason,
             soft_refresh_attempted, updated_ts)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(transport) DO UPDATE SET
            stale_streak                  = excluded.stale_streak,
            last_bounce_suppressed_reason = excluded.last_bounce_suppressed_reason,
            soft_refresh_attempted        = excluded.soft_refresh_attempted,
            updated_ts                    = excluded.updated_ts
        """,
        (transport, int(stale_streak), suppressed_reason,
         1 if soft_refresh_attempted else 0, now),
    )
    conn.commit()


def _fresh_peer_reachability_loss(conn: sqlite3.Connection, cfg: dict[str, Any],
                                  now: float) -> tuple[Optional[bool], dict[str, int]]:
    """Read the PRIOR-tick peer FSM and classify the mesh for the bounce gate.

    Returns `(loss, counts)`:
      - `loss is True`  → at least one FRESH peer FSM state is suspect/down AND
        every other fresh peer is accounted for — a PROVEN reachability loss the
        bounce gate may act on.
      - `loss is False` → every configured peer has a FRESH `up` state — the
        tunnel is demonstrably carrying traffic; NEVER bounce (the #1733 core).
      - `loss is None`  → the peer state is UNKNOWN/STALE (no peers configured,
        a peer never freshly probed, or every fresh state is up but some peers
        are stale) — NEITHER proof-of-up NOR proof-of-loss; do not bounce and
        let the later peer-reachability step refresh the state.

    A peer's state only COUNTS when its `updated_ts` is within
    `warp_peer_freshness_window()` of `now` (the peer-reachability step runs
    AFTER this one, so a one-tick-old state is expected and fine; a state staler
    than the window is treated as unknown). Pure read — never writes, never
    probes a socket (that is the peer-reachability step's job).
    """
    counts = {"total": 0, "fresh_up": 0, "fresh_down_suspect": 0,
              "stale_or_missing": 0}
    peers = cfg.get("peers")
    if not isinstance(peers, list):
        return None, counts
    # #1732 × #1733 cross-lane (codex integration review): the WARP bounce gate
    # acts ONLY on BOUNCE-RELEVANT (persistent / alarm-on) peers. A transient
    # (expected-disconnect, #1732) peer going suspect/down is NOT proof of
    # substrate loss — counting it would bounce the tunnel on an expected blip,
    # and a transient peer's stale state would even suppress a real persistent-
    # loss bounce. `peer_alarm_on_unreachable` is the SAME policy the stuck-outbox
    # admin alarm consumes (persistent default + explicit per-peer override).
    bounce_relevant = [p for p in peers
                       if isinstance(p, dict) and p.get("id")
                       and a2a.peer_alarm_on_unreachable(p)]
    counts["transient_excluded"] = sum(
        1 for p in peers
        if isinstance(p, dict) and p.get("id")
        and not a2a.peer_alarm_on_unreachable(p))
    peer_ids = [str(p.get("id")) for p in bounce_relevant]
    if not peer_ids:
        # No bounce-relevant peers configured (all transient / alarm-off) — we
        # can prove neither all-up nor a real loss; never bounce.
        return None, counts

    window = warp_peer_freshness_window()
    counts["total"] = len(peer_ids)
    fresh_loss = False
    for pid in peer_ids:
        row = conn.execute(
            "SELECT state, updated_ts FROM peer_reachability WHERE peer_id = ?",
            (pid,),
        ).fetchone()
        if row is None or row["updated_ts"] is None:
            counts["stale_or_missing"] += 1
            continue
        try:
            updated = float(row["updated_ts"])
        except (TypeError, ValueError):
            counts["stale_or_missing"] += 1
            continue
        if (now - updated) > window:
            # State is older than the freshness window — UNKNOWN, not a signal.
            counts["stale_or_missing"] += 1
            continue
        state = str(row["state"])
        if state == PEER_STATE_UP:
            counts["fresh_up"] += 1
        elif state in (PEER_STATE_SUSPECT, PEER_STATE_DOWN):
            counts["fresh_down_suspect"] += 1
            fresh_loss = True
        else:
            # Unrecognized label — treat as unknown, never as a loss.
            counts["stale_or_missing"] += 1

    if counts["stale_or_missing"] > 0:
        # ANY peer stale/missing/unknown → we can prove NEITHER all-up NOR a
        # real reachability loss (the stale peer might be up). A WARP bounce
        # severs the mesh's own substrate, so it must NOT fire on an incomplete
        # picture — even when another peer is freshly suspect/down. (codex P1
        # #11705: a mixed fresh-loss + stale set must suppress, not bounce.)
        return None, counts
    if fresh_loss:
        # Every configured peer has FRESH state and at least one is
        # suspect/down → a proven reachability loss → eligible to bounce.
        return True, counts
    if counts["fresh_up"] == counts["total"] and counts["total"] > 0:
        return False, counts
    # No fresh signal at all (shouldn't happen given the branches above, but
    # fail safe toward unknown rather than inventing a loss).
    return None, counts


def _tunnel_health_warp(conn: Optional[sqlite3.Connection] = None,
                        cfg: Optional[dict[str, Any]] = None) -> ReconcileStepResult:
    """WARP substrate freshness probe + GATED auto-bounce (#1706 / #1733).

    Reads the MASQUE handshake age (read-only `warp-cli tunnel stats`) and only
    ever bounces the WHOLE tunnel on a CORRELATION of failure signals, never on
    handshake-idle alone (the #1733 self-severance: the A2A mesh rides this same
    tunnel, so an idle-bounce flaps the mesh it is protecting):

      - age UNKNOWABLE (warp-cli absent / unparseable) -> step_error with
        transport_degraded=True but NO bounce (fail-closed re-probe; a parse
        failure is not a proven stale handshake). Resets the stale streak.
      - age <= threshold -> step_converged (healthy, idempotent no-op; never
        bounces a fresh tunnel). Resets the stale streak.
      - age  > threshold -> stale handshake. The FULL disconnect/connect bounce
        is gated on ALL of:
          (1) >= warp_stale_streak_threshold() CONSECUTIVE stale ticks
              (persisted streak — a single idle tick never bounces), AND
          (2) >= 1 FRESH peer FSM state suspect/down (prior-tick reachability,
              read from `conn`; a peer only counts when freshly probed), AND
          (3) a soft-refresh (`warp-cli connect`, NO disconnect) was tried first.
        HARD no-bounce overrides (regardless of age):
          - ALL peers FRESH-up -> the tunnel is demonstrably carrying traffic;
            `bounce_suppressed_reason=all_peers_fresh_up`.
          - peer state STALE/UNKNOWN -> neither all-up nor loss;
            `bounce_suppressed_reason=peer_state_unknown_or_stale` and let the
            later peer-reachability step refresh the state.
          - stale streak below N -> wait for confirmation;
            `bounce_suppressed_reason=stale_streak_below_threshold`.
        On a gated bounce, returns step_error (engages the backoff gate so the
        NEXT bounce is paced — no storm). All result fields are observable, no
        secrets. `conn` is optional so a pre-gate caller (or the legacy stub
        seam) still degrades to a no-bounce report on a stale tunnel — fail-safe
        toward NOT severing the mesh.
    """
    age = a2a.warp_tunnel_handshake_age()
    threshold = warp_handshake_stale_threshold()
    transport = a2a.TRANSPORT_CLOUDFLARE_WARP_MESH

    if age is None:
        # Unknowable freshness — fail closed (re-probe), but do NOT bounce: a
        # probe-parse failure is not a proven stale handshake. A non-proven tick
        # also breaks the stale streak (we only count PROVEN stale ticks).
        if conn is not None:
            try:
                _ensure_tunnel_health_state_schema(conn)
                _write_tunnel_health_state(conn, transport, 0, None, False,
                                           a2a.now_ts())
            except sqlite3.Error:
                pass
        return step_error(
            "warp tunnel handshake age unknowable (warp-cli absent or no "
            "handshake line) — fail-closed re-probe, no bounce",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_known": False})

    if age <= threshold:
        # Fresh tunnel — reset the stale streak (idle recovered or never stale).
        if conn is not None:
            try:
                _ensure_tunnel_health_state_schema(conn)
                _write_tunnel_health_state(conn, transport, 0, None, False,
                                           a2a.now_ts())
            except sqlite3.Error:
                pass
        return step_converged(
            f"warp tunnel fresh (handshake age {age}s <= {threshold}s)",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": False,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold})

    # ---- PROVEN stale handshake: gate the bounce (#1733) -----------------
    now = a2a.now_ts()
    streak = 1
    streak_threshold = warp_stale_streak_threshold()

    def _degraded_no_bounce(reason: str, detail: str,
                            extra: Optional[dict[str, Any]] = None,
                            *, soft_refresh_attempted: bool = False
                            ) -> ReconcileStepResult:
        if conn is not None:
            try:
                _write_tunnel_health_state(conn, transport, streak, reason,
                                           soft_refresh_attempted, now)
            except sqlite3.Error:
                pass
        fields = {"transport": "cloudflare-warp-mesh",
                  "transport_degraded": True,
                  "handshake_age_seconds": age,
                  "stale_threshold_seconds": threshold,
                  "stale_streak": streak,
                  "stale_streak_threshold": streak_threshold,
                  "bounced": False,
                  "bounce_suppressed_reason": reason,
                  "soft_refresh_attempted": soft_refresh_attempted}
        if extra:
            fields.update(extra)
        return step_error(detail, fields=fields)

    # No reconcile.db handle (pre-gate caller / legacy seam) — we CANNOT read the
    # peer FSM, so we MUST NOT bounce (fail-safe toward not severing the mesh).
    if conn is None:
        return step_error(
            f"warp tunnel stale (handshake age {age}s > {threshold}s); "
            "no reconcile.db handle — peer state unreadable, bounce suppressed",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold,
                    "bounced": False,
                    "bounce_suppressed_reason":
                        BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN})

    try:
        _ensure_tunnel_health_state_schema(conn)
        _ensure_peer_reachability_schema(conn)
        prev_streak, _prev_reason = _tunnel_health_state_row(conn, transport)
        streak = int(prev_streak) + 1
    except sqlite3.Error:
        # State store unreadable — degrade to a single-tick view, no bounce.
        streak = 1
        return step_error(
            f"warp tunnel stale (handshake age {age}s > {threshold}s); "
            "gate-state store unreadable, bounce suppressed",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold,
                    "bounced": False,
                    "bounce_suppressed_reason":
                        BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN})

    # Read the prior-tick peer reachability classification.
    peer_cfg = cfg if isinstance(cfg, dict) else {}
    try:
        loss, counts = _fresh_peer_reachability_loss(conn, peer_cfg, now)
    except sqlite3.Error:
        loss, counts = None, {"total": 0, "fresh_up": 0,
                              "fresh_down_suspect": 0, "stale_or_missing": 0}

    # HARD no-bounce: all peers FRESH-up -> tunnel demonstrably carrying traffic.
    if loss is False:
        return _degraded_no_bounce(
            BOUNCE_SUPPRESSED_ALL_PEERS_FRESH_UP,
            f"warp tunnel stale (handshake age {age}s > {threshold}s) but all "
            f"{counts['total']} peers FRESH-up — idle, not broken; no bounce",
            extra={"peer_counts": counts})

    # HARD no-bounce: peer state unknown/stale -> neither all-up nor loss.
    if loss is None:
        return _degraded_no_bounce(
            BOUNCE_SUPPRESSED_PEER_STATE_UNKNOWN,
            f"warp tunnel stale (handshake age {age}s > {threshold}s) but peer "
            "reachability state is unknown/stale — deferring to peer-"
            "reachability refresh; no bounce",
            extra={"peer_counts": counts})

    # loss is True here: >=1 FRESH peer suspect/down. Require the N-streak too.
    if streak < streak_threshold:
        return _degraded_no_bounce(
            BOUNCE_SUPPRESSED_STALE_STREAK_BELOW_N,
            f"warp tunnel stale (handshake age {age}s > {threshold}s) with "
            f"fresh peer loss, but stale streak {streak} < {streak_threshold} — "
            "awaiting confirmation; no bounce",
            extra={"peer_counts": counts})

    # Gate satisfied: stale + N-streak + fresh peer loss. SOFT-REFRESH FIRST —
    # a non-disruptive `warp-cli connect` nudge (NEVER disconnect) before any
    # full bounce, so an idle-but-live tunnel refreshes without tearing the mesh.
    try:
        soft_refreshed = bool(_WARP_TUNNEL_SOFT_REFRESH())
    except Exception:  # noqa: BLE001 - soft-refresh is best-effort; failure falls through to the bounce
        soft_refreshed = False

    # Full disconnect/connect bounce (the gate is satisfied AND soft-refresh was
    # attempted first). Bounded by the run_step backoff gate around this adapter.
    try:
        bounced = bool(_WARP_TUNNEL_BOUNCE())
    except Exception as exc:  # noqa: BLE001 - the bounce is best-effort; a failure is paced, not fatal
        try:
            _write_tunnel_health_state(conn, transport, streak, None, True, now)
        except sqlite3.Error:
            pass
        return step_error(
            f"warp tunnel stale (handshake age {age}s > {threshold}s); fresh "
            f"peer loss + streak {streak}; soft-refresh "
            f"{'ran' if soft_refreshed else 'unavailable'}; "
            f"auto-bounce raised {type(exc).__name__}",
            fields={"transport": "cloudflare-warp-mesh",
                    "transport_degraded": True,
                    "handshake_age_seconds": age,
                    "stale_threshold_seconds": threshold,
                    "stale_streak": streak,
                    "stale_streak_threshold": streak_threshold,
                    "soft_refresh_attempted": True,
                    "soft_refreshed": soft_refreshed,
                    "peer_counts": counts,
                    "bounced": False})

    # A successful bounce refreshes the tunnel — reset the stale streak so the
    # next stale episode starts its streak from scratch.
    try:
        _write_tunnel_health_state(conn, transport, 0 if bounced else streak,
                                   None, True, now)
    except sqlite3.Error:
        pass
    return step_error(
        f"warp tunnel stale (handshake age {age}s > {threshold}s); fresh peer "
        f"loss + streak {streak}/{streak_threshold}; soft-refresh "
        f"{'ran' if soft_refreshed else 'unavailable'}; "
        f"auto-bounce {'invoked' if bounced else 'attempted'}",
        fields={"transport": "cloudflare-warp-mesh",
                "transport_degraded": True,
                "handshake_age_seconds": age,
                "stale_threshold_seconds": threshold,
                "stale_streak": streak,
                "stale_streak_threshold": streak_threshold,
                "soft_refresh_attempted": True,
                "soft_refreshed": soft_refreshed,
                "peer_counts": counts,
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


def tunnel_health(transport: str, cfg: dict[str, Any],
                  conn: Optional[sqlite3.Connection] = None
                  ) -> ReconcileStepResult:
    """Per-transport tunnel/substrate liveness (#1706 / #1733).

    Probes ONLY the configured `transport`'s substrate — a WARP install never
    shells `tailscale`, and a Tailscale install never shells `warp-cli`. The
    common control loop branches here exactly once, on `transport`:

      - "cloudflare-warp-mesh": probe the MASQUE handshake AGE; on a PROVEN
        stale handshake the daemon may AUTO-bounce the tunnel via the injectable
        `_WARP_TUNNEL_BOUNCE` hook — but ONLY when the #1733 gate is satisfied
        (>=N consecutive stale ticks AND >=1 FRESH peer suspect/down read from
        the prior-tick FSM in `conn` AND a soft-refresh was tried first). A
        fresh tunnel — or a stale tunnel whose peers are all FRESH-up / whose
        peer state is unknown — is a no-bounce report (idempotent / suppressed).
      - "tailscale": surface `tailscale status` and detect tailnet-down /
        node-offline (no auto-bounce — Tailscale self-heals via keepalive/DERP).
      - anything else: converged no-op (no substrate-specific probe defined;
        never shell a foreign transport's CLI).

    `conn` is the reconcile.db handle (the SAME one the backoff store uses). It
    is threaded so the WARP path can read the prior-tick peer reachability FSM
    and persist the consecutive-stale streak. It is OPTIONAL: when absent (a
    pre-gate caller / a non-WARP transport), the WARP path degrades to a
    no-bounce report on a stale tunnel — fail-safe toward NOT severing the mesh.
    This step NEVER reorders the reconcile sequence and NEVER runs a second live
    reachability probe (it only READS the FSM the peer-reachability step writes).

    Returns step_converged() when the tunnel is healthy; on a degraded /
    unknowable substrate returns step_error() with `transport_degraded: True`
    plus non-secret health detail in `fields` (handshake age + status + FSM
    counts only — never tokens/keys), so the bounded backoff paces re-probes.
    Fail-safe: a probe error returns step_error() and NEVER raises into the tick.
    """
    if transport == a2a.TRANSPORT_CLOUDFLARE_WARP_MESH:
        return _tunnel_health_warp(conn, cfg)
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
                           conn: sqlite3.Connection,
                           config_path: Optional[Path] = None) -> ReconcileStepResult:
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

    Returns (probe outcomes classified into reachable / cleanly-unreachable /
    infra-error; infra-error takes precedence):
      - step_error() when ANY probe this tick was an INFRASTRUCTURE failure
        (resolver raised / address unresolvable / the probe hook itself raised)
        — the reachability is UNKNOWABLE, so the tick is fail-closed to error
        REGARDLESS of any FSM advance, and the bounded backoff paces re-probes.
        A clean ConnectionRefused/timeout is NOT an infra-error (that is a
        determined down). Also returned when the mesh is simply not fully
        reachable with no progress this tick.
      - step_changed() when a peer's STATE cleanly advanced this tick OR a
        desired rebind was recorded (and no infra-error occurred);
      - step_converged() when every peer is UP and there is no recorded drift
        (idempotent no-op — repeated ticks on an all-UP mesh do nothing).

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
    any_infra_error = False
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

        # Classify this peer's probe outcome into exactly one of three kinds —
        # the fail-closed distinction the aggregate result depends on:
        #   reachable           : the probe PROVED the peer up.
        #   cleanly-unreachable : the probe cleanly DETERMINED the peer is down
        #                         (ConnectionRefused / timeout / EHOSTUNREACH —
        #                         a real down signal). This is legit
        #                         down-detection: the FSM advances and the
        #                         aggregate may report `changed`.
        #   infra-error         : the probe could NOT complete its determination
        #                         (resolver raised / address unresolvable / the
        #                         probe HOOK itself raised). The reachability is
        #                         UNKNOWABLE — fail-closed, NOT a clean "down".
        #                         Any infra-error in the tick forces the
        #                         aggregate to `step_error` (below) so the
        #                         bounded backoff paces re-probes and we never
        #                         treat unknown as a determined down.
        #
        # `probe_err_code` is a CLOSED-SET classification token only (an
        # A2AError `.code`, or a fixed `probe_exception`/`unresolved_addr`) —
        # NEVER the free-text exception message, so no resolver/probe string can
        # leak into the result `fields` (no-secret contract: codes/states/
        # counts/timestamps only).
        probe_err_code = ""
        infra_error = False
        try:
            address = a2a.resolve_peer_address_for_transport(transport, peer)
        except a2a.A2AError as exc:
            # Resolver raised → the target address is UNKNOWABLE (infra-error,
            # not a clean down).
            address = ""
            probe_err_code = str(exc.code or "resolve_error")
            infra_error = True

        port = default_port
        try:
            if peer.get("port") is not None:
                port = int(peer["port"])
        except (TypeError, ValueError):
            port = default_port

        if infra_error:
            # Address unknowable → do not probe; reachability unknown (fail-closed).
            reachable = False
        elif address:
            try:
                reachable = bool(_PEER_REACHABILITY_PROBE(address, port, timeout))
            except Exception:  # noqa: BLE001 - a probe never raises into the tick
                # The probe HOOK itself raised → its determination did NOT
                # complete → UNKNOWABLE (infra-error), distinct from a clean
                # `False` (ConnectionRefused/timeout, handled inside the probe).
                reachable = False
                infra_error = True
                # Fixed token only — never the exception's str()/repr().
                probe_err_code = "probe_exception"
        else:
            # Resolver returned an EMPTY address with no exception — the address
            # could not be determined (operational, not a proven-down peer) →
            # UNKNOWABLE (infra-error), fail-closed.
            reachable = False
            infra_error = True
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

        # #1732 reconnect flush (seamless resume). On a TRANSITION to `up` for a
        # TRANSIENT peer, wake that peer's parked/backoff-waiting outbox rows so
        # the daemon's normal deliver loop resumes them on the next tick instead
        # of waiting on the slower (~5 min) diagnose-stuck path. This is a pure
        # row re-arm (status retry→pending, next_attempt_ts=0, leases cleared);
        # it NEVER delivers inline and NEVER binds — the reconcile no-bind /
        # no-receiver-admission invariant holds. Scoped to transient peers so a
        # persistent peer's recovery stays on its existing diagnose-stuck path
        # (byte-identical behavior for existing installs). Best-effort + fully
        # fail-safe: any error here is swallowed so a flush hiccup can never crash
        # the reconcile tick or mask the FSM advance (the deliver loop and
        # diagnose-stuck remain the durable fallback). Rooms ride the SAME
        # classic per-peer outbox, so this covers room messages too.
        if reachable and state_changed and new_state == PEER_STATE_UP \
                and a2a.peer_is_transient(peer):
            try:
                _ob = a2a.open_outbox()
                try:
                    a2a.wake_peer_outbox_for_resume(_ob, peer_id, now)
                finally:
                    _ob.close()
            except Exception:  # noqa: BLE001 - a flush failure never crashes the tick
                pass

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
        if infra_error:
            # An UNKNOWABLE probe this tick forces the aggregate to step_error
            # below (fail-closed: never let a state advance off an unknowable
            # probe report as progress).
            any_infra_error = True
        if state_changed:
            any_state_changed = True

        summary: dict[str, Any] = {
            "peer": peer_id, "state": new_state, "probed": True,
            "consecutive_fail": new_fail}
        if infra_error:
            # Observable, non-secret bool: distinguishes a clean down from an
            # unknowable probe for net-status.
            summary["infra_error"] = True
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
            # Thread the active config_path so the IP-drift rebind persists to the
            # SAME file the receiver loaded (not the default) — #11573 seam.
            drift_res = stable_local_addr(transport, cfg, config_path)
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
        "infra_error": any_infra_error,
    }

    # FAIL-CLOSED (highest precedence): if ANY probe this tick could not
    # complete its reachability determination (resolver raised / address
    # unresolvable / the probe hook raised), the tick is UNKNOWABLE. Return
    # step_error REGARDLESS of any FSM advance or recorded rebind — an
    # unknowable probe must never be reported as progress (it would otherwise
    # mask an infrastructure failure as a clean down-detection and skip the
    # bounded backoff that paces re-probes). Any FSM/config writes already
    # persisted stand; only the returned status is forced to error.
    if any_infra_error:
        return step_error(
            f"peer-reachability: probe infrastructure error this tick "
            f"({peers_up}/{len(peer_ids)} peer(s) up; reachability unknowable)"
            + (" + IP-drift rebind recorded" if rebind_recorded else ""),
            fields=fields)
    # A state advance (a peer transition or a recorded rebind) is PROGRESS this
    # tick → report step_changed even if the mesh is now fully up (a down→up
    # recovery must not be reported as a converged no-op — it advanced state).
    # Reached only when every probe CLEANLY determined reachability (no
    # infra-error), so a `changed` here is legit clean down/up-detection.
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
    """Roster epoch anti-entropy — re-broadcast un-acked leader rosters (#1695-P2 F).

    The heartbeat side of gotcha F: a membership change (approve/kick/leave/deny)
    durably queues a per-member-node convergence target (`room_roster_outbox`) and
    tries an immediate send; this periodic step re-broadcasts any row a member has
    not yet acked, so a member that was offline at the change eventually converges
    even across a transient outage. Membership/epoch ALWAYS read from the leader's
    authoritative `rooms.db` (`roster_for`), NEVER a body-asserted claim; the
    roster is signed with the per-pair leader↔member node-link HMAC. Bounded: this
    runs inside `run_step`'s backoff gate (a tick that fails is paced out), and the
    fan-out per tick is internally capped.

    Result mapping:
      - rooms module / rooms.db absent, or NO pending durable broadcast for any
        room this node leads → step_noop (nothing to anti-entropy; idempotent,
        resets backoff). This is also the deterministic outcome on the Lane-0
        fixture (no rooms.db), keeping the framework smoke green.
      - every pending row re-delivered (or retired) and none left → step_converged.
      - at least one row delivered this tick (progress) → step_changed.
      - rows remain pending and NONE delivered (all failed) → step_error (engages
        the bounded backoff so the re-broadcast is paced, not stormed).
    The `conn` arg is the reconcile.db backoff store (managed by run_step); the
    rooms.db is opened separately here and only when there is actual work.
    """
    # rooms module is optional in some minimal installs; fail-safe to noop.
    try:
        import bridge_rooms_common as rooms
    except Exception:  # noqa: BLE001 - a missing rooms module is "nothing to do"
        return step_noop("roster-epoch: rooms module unavailable")

    # Cheap EXISTENCE probe on a READ-ONLY handle first (never CREATE rooms.db
    # from the daemon tick — a fresh node with no rooms must no-op, and the
    # Lane-0 fixture has no rooms.db).
    try:
        ro = rooms.open_rooms_readonly()
    except Exception as exc:  # noqa: BLE001 - present-but-unreadable is an op error
        return step_error(f"roster-epoch: rooms.db unreadable ({exc})"[:200])
    if ro is None:
        return step_noop("roster-epoch: no rooms.db (nothing to anti-entropy)")
    ro.close()

    # The db EXISTS → open a WRITABLE handle. This runs `_migrate_schema`, so the
    # #2109 admin columns are ensured here (a lock during the upgrade window now
    # propagates instead of silently leaving a half-migrated schema). Any raise
    # is contained (fail-safe — never crash the tick).
    try:
        wconn = rooms.open_rooms()
    except Exception as exc:  # noqa: BLE001 - rooms.db open failure is an op error
        return step_error(f"roster-epoch: rooms.db open failed ({exc})"[:200])
    try:
        # #2109 durable reclassification: backfill THIS node's admin bits from
        # the local configured admin id and, as the leader, bump+enqueue a
        # roster rebroadcast for any room whose admin bits changed. This is what
        # converges a STABLE room's migrated -1 rows (no join/leave to bump the
        # epoch otherwise). Local-authority + leader-only enforced inside. A
        # raise here (e.g. AdminIdResolveError on an unreadable/malformed roster)
        # is FAIL-CLOSED: surface it as a paced step_error so the backoff gate
        # retries it, rather than backfilling/rebroadcasting with a wrong admin
        # id. No admin bit was written on that path (the resolve raises first).
        try:
            rooms.reclassify_and_rebroadcast_local_admin(cfg, wconn)
        except Exception as exc:  # noqa: BLE001 - fail-closed; do not write a wrong bit
            return step_error(
                f"roster-epoch: admin backfill failed ({exc})"[:200])

        try:
            pending = rooms.pending_roster_outbox(wconn)
        except sqlite3.OperationalError:
            # A rooms.db created BEFORE the outbox table existed has none yet;
            # the writable open above migrates it, so this is effectively "no
            # pending" — a clean no-op, not an error.
            return step_noop("roster-epoch: outbox table absent (no pending)")
        except Exception as exc:  # noqa: BLE001 - other schema/db read error
            return step_error(f"roster-epoch: outbox read failed ({exc})"[:200])
        if not pending:
            return step_noop("roster-epoch: no pending roster broadcasts")

        # There is real work → drain it through the shared sender (one signing
        # path with the CLI).
        summary = rooms.heartbeat_rebroadcast_rosters(cfg, wconn)
    except Exception as exc:  # noqa: BLE001 - last-resort guard (never crash tick)
        return step_error(f"roster-epoch: rebroadcast raised ({exc})"[:200])
    finally:
        try:
            wconn.close()
        except Exception:  # noqa: BLE001
            pass

    sent = int(summary.get("sent", 0))
    failed = int(summary.get("failed", 0))
    remaining = int(summary.get("pending", 0))
    detail = (f"roster-epoch: re-broadcast sent={sent} failed={failed} "
              f"pending={remaining}")
    fields = {"sent": sent, "failed": failed, "pending": remaining}
    if sent > 0:
        # Progress this tick (a member converged) — reset backoff.
        return step_changed(detail, fields=fields)
    if remaining == 0:
        # Nothing left pending and nothing sent (all rows retired as stale) —
        # converged no-op.
        return step_converged(detail, fields=fields)
    # Rows remain and none were delivered → pace via the bounded backoff.
    return step_error(detail, fields=fields)


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


def peer_reachability_snapshot(peer_ids: list[str],
                               state_dir: Optional[Path] = None,
                               ) -> dict[str, dict[str, Any]]:
    """Read-only per-peer FSM snapshot for net-status v2 (#1708 / #1707).

    For each configured peer id, returns the persisted UP/SUSPECT/DOWN state
    plus the no-secret observability the reviewer needs to confirm the mesh is
    converging:

        {
          "<peer_id>": {
            "state": "up"|"suspect"|"down"|"unknown",
            "consecutive_fail": <int>,
            "last_state_ts": <float|None>,   # when the state label last changed
            "updated_ts": <float|None>,      # last probe of this peer
            "last_attempt_ts": <float|None>, # from the per-peer backoff step row
            "next_eligible_ts": <float|None>,
            "attempt_count": <int>,
          }, ...
        }

    NO SECRETS: peer ids, FSM labels, counters and timestamps only — never a
    peer key, address, or remote-asserted material. A never-probed peer reports
    the optimistic-UP zero-state the live FSM uses (`_peer_state_row` returns
    UP/0 for an unseen peer), so the surface is stable-shaped before the first
    tick. A peer not present in `peer_ids` is never invented.

    ★ Pure read (mirrors reconcile_status_snapshot): this MUST NOT create the
    store. It `path.exists()`-guards and opens reconcile.db with a `?mode=ro`
    URI, so a status call before the daemon has ever reconciled returns the
    stable all-`unknown`/optimistic shape WITHOUT materializing reconcile.db.
    Degrade-safe: any sqlite/OS error degrades to the unknown shape, never
    raises.
    """
    def _unknown(peer_id: str) -> dict[str, Any]:
        # Before the store exists the live FSM treats an unseen peer as
        # optimistically UP/0 (see _peer_state_row). We report state="unknown"
        # here to distinguish "no reconcile.db / never probed" from a proven UP
        # written by a successful probe — the snapshot is observability, and an
        # un-probed peer is genuinely UNKNOWN, not asserted reachable.
        return {
            "state": "unknown", "consecutive_fail": 0,
            "last_state_ts": None, "updated_ts": None,
            "last_attempt_ts": None, "next_eligible_ts": None,
            "attempt_count": 0,
        }

    ids = [p for p in peer_ids if isinstance(p, str) and p.strip()]
    out: dict[str, dict[str, Any]] = {pid: _unknown(pid) for pid in ids}
    if not ids:
        return out

    path = reconcile_db_path(state_dir)
    if not path.exists():
        return out

    conn: Optional[sqlite3.Connection] = None
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30.0)
        conn.row_factory = sqlite3.Row
        for pid in ids:
            entry = out[pid]
            # FSM state row (peer_reachability table). A missing row keeps the
            # optimistic/unknown default — never invent a DOWN.
            try:
                frow = conn.execute(
                    "SELECT state, consecutive_fail, last_state_ts, updated_ts "
                    "FROM peer_reachability WHERE peer_id = ?", (pid,),
                ).fetchone()
            except sqlite3.Error:
                frow = None
            if frow is not None:
                entry["state"] = str(frow["state"])
                entry["consecutive_fail"] = int(frow["consecutive_fail"] or 0)
                entry["last_state_ts"] = frow["last_state_ts"]
                entry["updated_ts"] = frow["updated_ts"]
            # Per-peer backoff/attempt row (reconcile_step, namespaced id).
            try:
                srow = conn.execute(
                    "SELECT last_attempt_ts, attempt_count, next_eligible_ts "
                    "FROM reconcile_step WHERE step = ?", (_peer_step_id(pid),),
                ).fetchone()
            except sqlite3.Error:
                srow = None
            if srow is not None:
                entry["last_attempt_ts"] = srow["last_attempt_ts"]
                entry["next_eligible_ts"] = srow["next_eligible_ts"]
                entry["attempt_count"] = int(srow["attempt_count"] or 0)
    except (sqlite3.Error, OSError):
        # Whole-store failure (vanished/locked/corrupt/not-yet-schema'd) →
        # degrade every peer to the unknown shape (already pre-seeded).
        return {pid: _unknown(pid) for pid in ids}
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
    return out


def tunnel_health_gate_snapshot(transport: str,
                                state_dir: Optional[Path] = None,
                                ) -> dict[str, Any]:
    """Read-only #1733 bounce-gate state for net-status v2 (additive).

    Surfaces the consecutive-stale streak + the last observable bounce-
    suppressed reason for `transport` so an operator can see WHY a stale tunnel
    was (not) bounced — no secrets, just the streak counter, the enum reason,
    and whether a soft-refresh was attempted. Stable shape on a missing/
    not-yet-reconciled store:

        {
          "stale_streak": <int>,
          "last_bounce_suppressed_reason": <str|None>,
          "soft_refresh_attempted": <bool>,
          "updated_ts": <float|None>,
        }

    ★ Pure read (mirrors peer_reachability_snapshot): MUST NOT create the store.
    Opens reconcile.db with a `?mode=ro` URI behind a `path.exists()` guard, so
    a status call before the daemon has ever reconciled returns the stable
    zero-shape WITHOUT materializing reconcile.db. Degrade-safe: any sqlite/OS
    error degrades to the zero shape, never raises.
    """
    zero = {"stale_streak": 0, "last_bounce_suppressed_reason": None,
            "soft_refresh_attempted": False, "updated_ts": None}
    path = reconcile_db_path(state_dir)
    if not path.exists():
        return dict(zero)

    conn: Optional[sqlite3.Connection] = None
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30.0)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT stale_streak, last_bounce_suppressed_reason, "
            "soft_refresh_attempted, updated_ts "
            "FROM tunnel_health_state WHERE transport = ?",
            (transport,),
        ).fetchone()
        if row is None:
            return dict(zero)
        return {
            "stale_streak": int(row["stale_streak"] or 0),
            "last_bounce_suppressed_reason":
                row["last_bounce_suppressed_reason"],
            "soft_refresh_attempted": bool(row["soft_refresh_attempted"]),
            "updated_ts": row["updated_ts"],
        }
    except (sqlite3.Error, OSError):
        # Missing table (not-yet-schema'd) / locked / corrupt → zero shape.
        return dict(zero)
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
