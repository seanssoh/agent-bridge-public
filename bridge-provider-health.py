#!/usr/bin/env python3
"""Provider-health outage oracle (Issue #2066, v0.17 fallback feature — P1a).

This is the DETECTION oracle ONLY. It owns a single daemon-managed
``provider-health`` state file and the detector that sets it. **Nothing consumes
the DOWN state yet** — the cron fallback (P1b) and live-advisory (P3) are
separate, later tracks. P1a ships the oracle + a smoke proving it detects.

Design (from #2066 v2 + v3/v3.1, authoritative) — **1 prober, N readers**:

* **Zero steady-state cost.** The oracle does NO proactive probing. Detection
  rides agents' OWN real outage-class failures (a cron child's non-zero exit
  with 5xx/529/overloaded/connection-reset stderr, or a live pane's network
  stall). Those failure paths call ``report-outage`` — that is the only entry.
* **First failure → scoped (not ≥N).** On the FIRST outage-class report the
  daemon fires ONE authenticated synthetic Anthropic probe + ONE DNS/internet
  sanity check. Probe = outage-class AND DNS ok → ``DOWN-scoped:<agent>`` for the
  triggering agent (a single low-traffic/critical agent is never stranded
  waiting for a second). DNS FAIL → do NOT blame Anthropic (it is OUR network):
  stay ``UP``, audit. (v3.1 fix #1.)
* **N-of-M → fleet.** When ``BRIDGE_FALLBACK_OUTAGE_QUORUM`` (default 2) DISTINCT
  static agents report outage-class within ``BRIDGE_FALLBACK_OUTAGE_WINDOW_S``
  (default 120s) → promote to ``DOWN-fleet``.
* **Still-down re-probe.** While DOWN the single prober re-probes with
  exponential backoff (30s → 1m → 2m → 5m cap). ``status.anthropic.com`` is an
  advisory accelerator only (P1a does not poll it — left as a P2 hook).
* **Recovery hysteresis.** A backoff-probe SUCCESS + a 2nd confirmation
  (``BRIDGE_FALLBACK_RECOVERY_CONFIRMS``, default 2) → ``UP``. Prevents flap.

State file: ``$BRIDGE_STATE_DIR/daemon/provider-health`` (JSON). Written with an
O_NOFOLLOW atomic tmp+replace at mode 0644 — it is non-secret OBSERVATIONAL
state (no tokens), published cheaply for isolated agents to read directly
(mirrors ``bridge_write_agents_aggregate_state``). Never carries credentials.

Injection seams (so the smoke runs with ZERO live network / quota):
  * ``BRIDGE_FALLBACK_PROBE_CMD`` — a command run for the synthetic Anthropic
    probe. Exit 0 = reachable+ok; a special exit/stdout marks outage-class. The
    real default reuses the usage-probe's authenticated request machinery via
    ``bridge-usage.sh`` (no new credential path is invented). In tests this is
    pointed at a stub script.
  * ``BRIDGE_FALLBACK_DNS_CMD`` — a command run for the DNS/internet sanity
    check (default resolves a known host). Exit 0 = internet ok.
  * ``BRIDGE_FALLBACK_CLOCK`` — an integer epoch override for deterministic
    time in the smoke. Absent → ``time.time()``.

All daemon entry points are argv-only subcommands (file-as-argv; bridge-daemon.sh
heredoc ceiling is 0 — footgun #11).
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

try:
    import fcntl  # POSIX advisory lock (serializes read-modify-write transitions)
except ImportError:  # pragma: no cover — non-POSIX; the lock degrades to no-op
    fcntl = None  # type: ignore[assignment]

# --------------------------------------------------------------------------- #
# State states + tunables
# --------------------------------------------------------------------------- #
STATE_UP = "UP"
STATE_DOWN_SCOPED = "DOWN-scoped"  # stored as "DOWN-scoped:<agent>"
STATE_DOWN_FLEET = "DOWN-fleet"

STATE_BASENAME = "provider-health"
STATE_MODE = 0o644  # non-secret observational; cheap iso reads

# Exponential backoff schedule (seconds) for the still-down re-probe — one
# prober. Caps at the last value.
BACKOFF_SCHEDULE_SECONDS = (30, 60, 120, 300)

# A report older than this is ignored for fleet quorum (the window slides). The
# env override (BRIDGE_FALLBACK_OUTAGE_WINDOW_S) wins.
DEFAULT_OUTAGE_WINDOW_S = 120
DEFAULT_OUTAGE_QUORUM = 2
DEFAULT_RECOVERY_CONFIRMS = 2
# Reports retained in the rolling ledger (cap so the state file cannot grow).
MAX_REPORT_LEDGER = 64
# Per-field caps on caller-supplied strings (a bridge agent id / source label is
# short; bound them so the state file cannot be bloated through long values).
AGENT_FIELD_MAX_CHARS = 128
SOURCE_FIELD_MAX_CHARS = 32


# --------------------------------------------------------------------------- #
# Env knobs (P1a reads them; defaults are inert because nothing consumes DOWN)
# --------------------------------------------------------------------------- #
def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)  # noqa: iso-helper-boundary — controller env read, not a .env file
    if raw is None or not str(raw).strip():
        return default
    try:
        val = int(str(raw).strip())
    except (TypeError, ValueError):
        return default
    return val if val >= 0 else default


def _enabled() -> bool:
    """Master gate. Default OFF until the whole feature is complete (#2066)."""
    raw = os.environ.get("BRIDGE_FALLBACK_ENABLED", "0")  # noqa: iso-helper-boundary — controller env read
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def _quorum() -> int:
    return max(1, _env_int("BRIDGE_FALLBACK_OUTAGE_QUORUM", DEFAULT_OUTAGE_QUORUM))


def _window_s() -> int:
    return max(1, _env_int("BRIDGE_FALLBACK_OUTAGE_WINDOW_S", DEFAULT_OUTAGE_WINDOW_S))


def _recovery_confirms() -> int:
    return max(1, _env_int("BRIDGE_FALLBACK_RECOVERY_CONFIRMS", DEFAULT_RECOVERY_CONFIRMS))


# Fallback EXECUTION knobs — declared + read here so the env surface is complete
# and discoverable in P1a, but the detection oracle does NOT act on them: they
# drive the Codex fallback that P1b (cron) / P3 (live) will build. Surfaced via
# `read --execution-knobs` for the operator/consumers; defaults are the operator
# directive from #2066 ("일단은" gpt-5.5-xhigh). NOT used to detect an outage.
def _fallback_execution_knobs() -> dict[str, str]:
    return {
        # Operator default model for the Codex fallback (P1b/P3 consume this).
        "model": os.environ.get("BRIDGE_FALLBACK_MODEL", "gpt-5.5-xhigh"),  # noqa: iso-helper-boundary — controller env read
        # Reasoning effort for the fallback model (empty = engine default).
        "effort": os.environ.get("BRIDGE_FALLBACK_EFFORT", ""),  # noqa: iso-helper-boundary — controller env read
        # Cheap model for the synthetic Anthropic confirm-probe (so the probe
        # cannot burn meaningful quota). The real probe wiring (P1b) reuses the
        # usage-probe authenticated machinery; this names the minimal model.
        "probe_model": os.environ.get("BRIDGE_FALLBACK_PROBE_MODEL", "claude-3-5-haiku-latest"),  # noqa: iso-helper-boundary — controller env read
    }


def _now() -> float:
    override = os.environ.get("BRIDGE_FALLBACK_CLOCK")  # noqa: iso-helper-boundary — controller env read
    if override is not None and str(override).strip():
        try:
            return float(str(override).strip())
        except (TypeError, ValueError):
            pass
    return time.time()


# --------------------------------------------------------------------------- #
# State path + O_NOFOLLOW atomic write (mode 0644, non-secret observational)
# --------------------------------------------------------------------------- #
def _state_dir() -> Path:
    base = os.environ.get("BRIDGE_STATE_DIR")  # noqa: iso-helper-boundary — controller env read
    if base and str(base).strip():
        root = Path(str(base).strip())
    else:
        home = os.environ.get("BRIDGE_HOME") or os.path.expanduser("~/.agent-bridge")  # noqa: iso-helper-boundary — controller env read
        root = Path(home) / "state"
    return root / "daemon"


def state_path() -> Path:
    return _state_dir() / STATE_BASENAME


def _lock_path() -> Path:
    return _state_dir() / (STATE_BASENAME + ".lock")


# Lock tunables. Codex r4 (BLOCKING): the critical section is now ONLY a state
# read + mutate + atomic write (all local I/O, sub-millisecond) — the slow
# probe/DNS/static-check subprocesses run UNLOCKED (see report_outage_class_failure
# / probe_tick phasing). The stale threshold is set FAR above any conceivable
# locked critical-section duration (which no longer spans any subprocess), so a
# stale lock older than this is unambiguously a crashed/killed holder, never a
# slow-but-live one. A 120s margin dwarfs local-I/O latency on any real fs.
LOCK_STALE_SECONDS = 120
LOCK_SPIN_TIMEOUT_SECONDS = 10.0
LOCK_SPIN_SLEEP_SECONDS = 0.02


class _state_lock:
    """Exclusive lock serializing read-modify-write state transitions.

    Codex review (#2066 P1a) HIGH: the atomic O_EXCL-tmp + replace protects file
    INTEGRITY but not state CONSISTENCY — two concurrent `report-outage` calls
    from distinct agents each read the old state, mutate, and replace, so one
    overwrites the other and quorum evidence is lost (the fleet stays stuck on a
    single-agent DOWN-scoped, or even a stale UP). The PRIMARY mechanism is a
    portable ``O_CREAT|O_EXCL|O_NOFOLLOW`` lock FILE (separate from the state
    file): the create succeeds for exactly one holder and fails (EEXIST) for the
    rest, who spin with a bounded timeout + stale-break. This works on EVERY
    platform — it does NOT depend on fcntl. ``fcntl.flock`` is layered on as
    reinforcement when available.

    Codex r2 BLOCKING: an earlier version proceeded UNLOCKED when fcntl was
    absent or the lock leaf was a symlink (ELOOP) — reintroducing the exact RMW
    race in degraded environments. This version NEVER proceeds unlocked: the
    O_EXCL path is the primary lock (no fcntl needed), and a tampered lock leaf
    (ELOOP/ENXIO) is fail-CLOSED — the transition raises rather than write
    unserialized. The multi-process report path (independent cron-runner
    processes, #2066 §8) is exactly the case this must cover.
    """

    def __init__(self) -> None:
        self._fd: int | None = None
        self._path: Path | None = None

    def _try_create(self, lock_file: Path) -> int | None:
        try:
            return os.open(
                str(lock_file),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o644,
            )
        except FileExistsError:
            return None
        except OSError as exc:
            if exc.errno in (errno.ELOOP, errno.ENXIO):
                # A symlink / odd file is planted at the lock leaf — FAIL CLOSED.
                # Never proceed unserialized; a tampered lock path is a hard stop.
                raise RuntimeError(f"provider-health lock leaf is tampered: {lock_file}") from exc
            raise

    def _break_if_stale(self, lock_file: Path) -> bool:
        """RACE-FREE break of a STALE lock (crashed holder). Returns True if this
        process is the one that evicted the stale lock (and the caller should
        immediately retry the normal O_EXCL create).

        Codex r3 BLOCKING: the prior `os.replace`-and-verify steal was NOT
        exclusive — two stealers could each replace + read back their own nonce
        (the read of stealer A can land between A's replace and B's replace), so
        BOTH entered the critical section. The fix uses an atomic RENAME as the
        eviction primitive: ``os.rename(lock_file, graveyard)`` MOVES the stale
        inode; for a given source path the OS lets exactly ONE concurrent rename
        succeed — every other racer gets ENOENT (the source is already gone).
        Only the single winner evicts the stale lock; it does NOT itself become
        the lock holder — it returns True so the caller loops back to the normal
        ``O_EXCL`` create, where ordinary create-exclusivity then picks a single
        holder. A loser (ENOENT) returns False and the caller spins → re-tries
        the create. No path lets two processes hold the lock concurrently.

        Integration BLOCKING (v0.17 beta1 assembly): the bare stat→rename pair
        has a TOCTOU. Between this process observing a STALE inode at
        ``lock_file`` (year-old mtime) and its own ``os.rename``, the stale lock
        can be evicted by a faster racer AND a FRESH live lock recreated at the
        same path by the new holder mid-critical-section. ``os.rename`` then
        yanks that *live* lock (same path, new inode) and this process wrongly
        enters the critical section concurrently with the live holder → a lost
        report under heavy concurrency (reproduced ~2/20 trials under CPU load,
        12-way no-fcntl race). An "identity re-check after rename" alone is NOT
        sufficient: once a live lock has been renamed away, restoring it is
        itself racy (a third process can O_EXCL-create at the path before the
        restore), so the live holder is already disrupted.

        Fix: serialize the stale-break with a short-lived O_EXCL META-LOCK
        (``<lock>.break``). Only one process at a time runs stat→evict, so there
        is no concurrent-yank window. Staleness is re-evaluated UNDER the
        meta-lock (the decision is made under exclusion, not before it), so a
        lock that became fresh since the cheap pre-check is never evicted. A
        process that cannot get the meta-lock returns False and re-spins the
        normal O_EXCL create. The meta-lock is itself self-healing: a breaker
        that crashes holding it is reaped by mtime on the next pass.
        """
        # Cheap lock-free pre-check: only contend for the break meta-lock when
        # the lock currently LOOKS stale. A live lock never needs breaking.
        try:
            st = lock_file.stat()
        except OSError:
            return False
        if (time.time() - st.st_mtime) <= LOCK_STALE_SECONDS:
            return False

        break_lock = lock_file.parent / (STATE_BASENAME + ".lock.break")
        bfd = self._try_create(break_lock)
        if bfd is None:
            # Reap a crashed breaker's stale meta-lock once, then retry.
            try:
                bst = break_lock.stat()
                if (time.time() - bst.st_mtime) > LOCK_STALE_SECONDS:
                    grave = break_lock.parent / (
                        STATE_BASENAME + f".lock.break.dead.{os.getpid()}.{os.urandom(6).hex()}"
                    )
                    try:
                        os.rename(str(break_lock), str(grave))
                        os.unlink(str(grave))
                    except OSError:
                        pass
                    bfd = self._try_create(break_lock)
            except OSError:
                pass
        if bfd is None:
            # Another process owns the break — let it evict; we re-spin.
            return False

        try:
            # Re-evaluate staleness UNDER the meta-lock. The original holder may
            # have exited (lock gone) or a fresh holder may have recreated it;
            # in both cases the live lock is NOT stale and must not be evicted.
            try:
                st2 = lock_file.stat()
            except OSError:
                return False
            if (time.time() - st2.st_mtime) <= LOCK_STALE_SECONDS:
                return False
            graveyard = lock_file.parent / (
                STATE_BASENAME + f".lock.dead.{os.getpid()}.{os.urandom(6).hex()}"
            )
            try:
                os.rename(str(lock_file), str(graveyard))
            except OSError:
                # Vanished between the re-stat and the rename — not our eviction.
                return False
            try:
                os.unlink(str(graveyard))
            except OSError:
                pass
            return True
        finally:
            try:
                os.close(bfd)
            except OSError:
                pass
            try:
                os.unlink(str(break_lock))
            except OSError:
                pass

    def __enter__(self) -> "_state_lock":
        lock_file = _lock_path()
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        self._path = lock_file
        # The spin timeout is env-overridable (tests set it to 0 for a fast
        # fail-closed assertion; production keeps the 10s default).
        spin_timeout = LOCK_SPIN_TIMEOUT_SECONDS
        override = os.environ.get("BRIDGE_PROVIDER_HEALTH_LOCK_SPIN_TIMEOUT")  # noqa: iso-helper-boundary — controller env read
        if override is not None and str(override).strip():
            try:
                spin_timeout = max(0.0, float(str(override).strip()))
            except (TypeError, ValueError):
                pass
        deadline = time.monotonic() + spin_timeout
        while True:
            fd = self._try_create(lock_file)
            if fd is not None:
                self._fd = fd
                break
            # Held by someone else — if the lock is STALE (crashed holder), break
            # it RACE-FREE via an atomic rename (exactly one racer evicts it),
            # then loop back so the normal O_EXCL create selects a single holder.
            if self._break_if_stale(lock_file):
                continue
            if time.monotonic() >= deadline:
                # Could not acquire within the bound — FAIL CLOSED rather than
                # write unserialized. The caller's try/except in the CLI wrapper
                # degrades this to a clean audited error, never a racy write.
                raise RuntimeError("provider-health lock acquire timed out")
            time.sleep(LOCK_SPIN_SLEEP_SECONDS)
        # Reinforce with fcntl when available (harmless redundancy on POSIX).
        if fcntl is not None and self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX)
            except OSError:
                pass
        return self

    def __exit__(self, *_exc: Any) -> None:
        if self._fd is not None:
            if fcntl is not None:
                try:
                    fcntl.flock(self._fd, fcntl.LOCK_UN)
                except OSError:
                    pass
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None
        # Remove the lock leaf so the next holder's O_EXCL create succeeds.
        if self._path is not None:
            try:
                os.unlink(str(self._path))
            except OSError:
                pass
            self._path = None


def _evidence_digest(evidence: str) -> str:
    """A short SHA-256 prefix of the raw evidence — NO raw text persisted.

    Codex review (#2066 P1a) MEDIUM: the 0644 iso-readable state file must not
    carry caller-provided evidence verbatim (a future failure path could pass
    raw stderr / pane text containing paths, prompt fragments, or credential-
    like material). We persist only the OUTAGE/not classification + this
    irreversible digest, so an isolated reader sees no sensitive substring.
    """
    if not evidence:
        return ""
    return "sha256:" + hashlib.sha256(evidence.encode("utf-8", "replace")).hexdigest()[:16]


def _write_state_atomic(path: Path, payload: dict[str, Any]) -> None:
    """Atomic + symlink-safe write at mode 0644.

    A fresh random-named tmp in the same dir (``tempfile.mkstemp`` opens with
    ``O_CREAT|O_EXCL``, so it cannot land on or follow a pre-existing symlink) →
    fsync → chmod 0644 → ``os.replace``. ``os.replace`` is an atomic rename: if a
    symlink is planted at the FINAL target leaf, the rename swaps the inode
    (replacing the symlink itself) and never writes THROUGH it to clobber the
    symlink target. The daemon dir is controller-owned (not group-writable), so
    the leaf is not symlink-plantable by an iso UID in the first place — this is
    belt-and-suspenders in the spirit of the cron-runner output-leaf hardening
    (#1842). (Codex P1a g2: the O_EXCL temp leg, not an O_NOFOLLOW open, is what
    makes the tmp create symlink-safe — comment corrected to match the code.)
    """
    cache_dir = path.parent
    cache_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(cache_dir), prefix="." + STATE_BASENAME + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=True, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, STATE_MODE)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _default_state() -> dict[str, Any]:
    now = _now()
    return {
        "state": STATE_UP,
        "scoped_agent": "",
        "since_ts": now,
        "last_probe_ts": 0,
        "last_probe_result": "",
        "last_confirm_ts": 0,  # gate: reports newer than this are "pending"
        "triggering_agents": [],
        "reports": [],  # rolling ledger: [{agent, source, ts, evidence_digest}]
        "recovery_confirms": 0,
        "backoff_index": 0,
        "next_probe_ts": 0,
        "evidence": "",
    }


def read_state() -> dict[str, Any]:
    """Read the whole state dict; the UP default on any error/absence."""
    try:
        payload = json.loads(state_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return _default_state()
    except Exception:
        return _default_state()
    if not isinstance(payload, dict) or "state" not in payload:
        return _default_state()
    # Merge onto defaults so a forward-compat field is never KeyError.
    merged = _default_state()
    merged.update(payload)
    return merged


def _save_state(state: dict[str, Any]) -> None:
    _write_state_atomic(state_path(), state)


def is_down(state: dict[str, Any]) -> bool:
    return str(state.get("state", STATE_UP)) in (STATE_DOWN_SCOPED, STATE_DOWN_FLEET)


def _has_pending_unconfirmed_report(state: dict[str, Any]) -> bool:
    """A fresh outage report exists that has not yet driven a confirm decision.

    The daemon tick is a NO-OP unless state != UP OR there is a pending report,
    so this predicate (cheap, no probe) is what keeps steady-state cost at zero.

    Codex P1a a2/MEDIUM: a report is "pending" ONLY if it arrived AFTER the last
    confirm decision (ts > last_confirm_ts). Once `report_outage_class_failure`
    has run its probe/DNS confirm against the current reports, it stamps
    last_confirm_ts — so a report that stayed UP (DNS-fail, probe-ok,
    probe-inconclusive) does NOT keep should-tick returning `tick` forever. The
    reports remain in the window ledger for quorum accumulation; only a NEWER
    report re-arms the gate. This restores true zero-cost steady state.
    """
    if is_down(state):
        return False
    last_confirm = float(state.get("last_confirm_ts", 0) or 0)
    for r in state.get("reports", []):
        if isinstance(r, dict) and float(r.get("ts", 0) or 0) > last_confirm:
            return True
    return False


# --------------------------------------------------------------------------- #
# Synthetic Anthropic probe + DNS/internet sanity (injection seams)
# --------------------------------------------------------------------------- #
def _run_cmd(cmd_str: str, timeout: float) -> tuple[int, str]:
    """Run a configured probe/DNS command; (rc, combined-output-trimmed)."""
    if not cmd_str.strip():
        return (0, "")
    try:
        argv = shlex.split(cmd_str)
    except ValueError:
        return (2, "unparseable command")
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return (124, "timeout")
    except Exception as exc:  # noqa: BLE001 — a probe launch failure is a degrade, never a crash
        return (125, f"probe-launch-error: {type(exc).__name__}")
    out = ((proc.stdout or "") + (proc.stderr or "")).strip()
    return (proc.returncode, out[:200])


# Synthetic-probe outcomes. THREE-valued on purpose — an unconfigured / ambiguous
# probe is INCONCLUSIVE, which is distinct from "Anthropic is up". Codex review
# (#2066 P1a) HIGH: treating an absent probe command as `ok` was a silent
# false-negative — the oracle could NEVER enter DOWN in production (where the
# real authenticated probe is wired in P1b). Inconclusive keeps the oracle UP
# (we never blame Anthropic on no evidence) but audits a clear reason, so an
# operator/CI sees the probe is not yet wired rather than a fake healthy reading.
PROBE_OUTAGE = "outage"
PROBE_OK = "ok"
PROBE_INCONCLUSIVE = "inconclusive"


def synthetic_anthropic_probe() -> tuple[str, str]:
    """Fire ONE authenticated synthetic Anthropic probe (cheapest call).

    Returns (outcome, detail) where outcome is one of PROBE_OUTAGE / PROBE_OK /
    PROBE_INCONCLUSIVE.

    Seam: ``BRIDGE_FALLBACK_PROBE_CMD``. Convention —
      * exit 0 → ``PROBE_OK`` (reachable + Anthropic answered fine).
      * exit 64 OR stdout contains ``outage-class`` → ``PROBE_OUTAGE``.
      * NO command configured (and no real default wired yet — P1a) →
        ``PROBE_INCONCLUSIVE`` (NOT ``ok`` — the false-negative codex caught).
      * any other non-zero (launch/timeout/ambiguous) → ``PROBE_INCONCLUSIVE``.
    The production default (P1b) reuses the usage-probe's authenticated machinery
    — it does NOT invent a credential path and sends a minimal request so it
    cannot burn meaningful quota. Until that lands, an unconfigured probe is
    inconclusive, never a fabricated healthy reading.
    """
    cmd = os.environ.get("BRIDGE_FALLBACK_PROBE_CMD", "")  # noqa: iso-helper-boundary — controller env read
    if not cmd.strip():
        # No probe command AND no real authenticated default is wired in P1a.
        # Refuse to fabricate "Anthropic up" — report inconclusive + audit.
        return (PROBE_INCONCLUSIVE, "probe-unconfigured(no BRIDGE_FALLBACK_PROBE_CMD; real probe wired in P1b)")
    rc, out = _run_cmd(cmd, timeout=float(_env_int("BRIDGE_FALLBACK_PROBE_TIMEOUT_S", 15)))
    # Codex P1a f2: NEVER persist the probe's raw stdout/stderr — a future
    # authenticated probe could emit a token-bearing error line into the 0644
    # world-readable state file. The detail carries only rc + an irreversible
    # digest of the output; the marker scan happens on the in-memory `out`.
    out_digest = _evidence_digest(out) if out else ""
    if rc == 64 or "outage-class" in out.lower():
        return (PROBE_OUTAGE, f"probe-outage-class(rc={rc};{out_digest})")
    if rc == 0:
        return (PROBE_OK, "probe-ok")
    return (PROBE_INCONCLUSIVE, f"probe-inconclusive(rc={rc};{out_digest})")


def internet_dns_ok() -> tuple[bool, str]:
    """ONE DNS/internet sanity check. Returns (ok, detail).

    ``ok=True`` means our network/DNS is healthy (so an Anthropic probe failure
    really IS Anthropic, not us). ``ok=False`` means OUR network is the problem —
    we must NOT blame Anthropic (#2066 §3 [adv #4]).

    Seam: ``BRIDGE_FALLBACK_DNS_CMD`` — exit 0 = internet ok. Default resolves a
    well-known host.
    """
    cmd = os.environ.get("BRIDGE_FALLBACK_DNS_CMD", "")  # noqa: iso-helper-boundary — controller env read
    if not cmd.strip():
        cmd = _default_dns_cmd()
    rc, out = _run_cmd(cmd, timeout=float(_env_int("BRIDGE_FALLBACK_DNS_TIMEOUT_S", 8)))
    # Same f2 hardening: persist only rc + a digest, never raw DNS-cmd output.
    out_digest = _evidence_digest(out) if out else ""
    return (rc == 0, f"dns-rc={rc};{out_digest}" if out_digest else f"dns-rc={rc}")


def _default_dns_cmd() -> str:
    """A portable internet-sanity command (resolve a well-known host).

    Uses python's own resolver so we do not depend on dig/host/nslookup being
    installed. The host is a stable, neutral anchor (the resolver root) — NOT
    api.anthropic.com (an Anthropic DNS hiccup must not read as 'our network is
    down', which would suppress the outage signal).
    """
    py = shlex.quote(sys.executable or "python3")
    host = os.environ.get("BRIDGE_FALLBACK_DNS_HOST", "one.one.one.one")  # noqa: iso-helper-boundary — controller env read
    snippet = "import socket,sys; socket.getaddrinfo(sys.argv[1],443); print('dns-ok')"
    return py + " -c " + shlex.quote(snippet) + " " + shlex.quote(host)


# --------------------------------------------------------------------------- #
# Report → confirm → set state
# --------------------------------------------------------------------------- #
def _agent_is_static(agent: str) -> bool:
    """Validate that ``agent`` is a REGISTERED STATIC agent — quorum binding.

    Codex P1a d2/BLOCKING: the agent name is caller-supplied; without validation,
    one process reporting twice under two invented names reaches fleet quorum.
    Only DISTINCT static agents may corroborate a fleet outage (the brief's
    `bridge_agent_is_static` predicate, lib/bridge-agents.sh:771).

    The python oracle is roster-blind (iso-adjacent), so validation is a seam:
    ``BRIDGE_FALLBACK_STATIC_CHECK_CMD`` is a command template containing ``{agent}``
    (or receiving the agent as a final argv) that exits 0 iff the agent is a
    registered static agent. The controller-side shell report wrapper
    (lib/bridge-provider-health.sh, which HAS roster access) sets it to a
    `bridge_agent_is_static` check. When the seam is UNSET, validation is treated
    as "unknown" and the agent does NOT count toward FLEET quorum (fail-closed on
    promotion — a scoped DOWN still works on the single triggering agent; only
    the broader fleet claim requires validated corroboration).
    """
    if not agent:
        return False
    cmd_tmpl = os.environ.get("BRIDGE_FALLBACK_STATIC_CHECK_CMD", "")  # noqa: iso-helper-boundary — controller env read
    if not cmd_tmpl.strip():
        return False  # fail-closed: unvalidated names never satisfy fleet quorum
    if "{agent}" in cmd_tmpl:
        cmd = cmd_tmpl.replace("{agent}", shlex.quote(agent))
    else:
        cmd = cmd_tmpl + " " + shlex.quote(agent)
    rc, _out = _run_cmd(cmd, timeout=float(_env_int("BRIDGE_FALLBACK_STATIC_CHECK_TIMEOUT_S", 5)))
    return rc == 0


def _prune_reports(reports: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    window = _window_s()
    kept = [r for r in reports if isinstance(r, dict) and (now - float(r.get("ts", 0))) <= window]
    return kept[-MAX_REPORT_LEDGER:]


def _distinct_agents_in_window(reports: list[dict[str, Any]], now: float) -> list[str]:
    """DISTINCT STATIC-VALIDATED agents in the corroboration window.

    Only agents whose report carries ``static_validated == True`` count toward
    FLEET quorum (codex P1a d2). A report from an unvalidated / invented name
    still records (and still drives the scoped-on-first probe for ITS OWN agent),
    but it can never push the fleet claim over quorum.
    """
    window = _window_s()
    seen: list[str] = []
    for r in reports:
        if not isinstance(r, dict):
            continue
        if (now - float(r.get("ts", 0))) > window:
            continue
        if not bool(r.get("static_validated", False)):
            continue
        agent = str(r.get("agent", "")).strip()
        if agent and agent not in seen:
            seen.append(agent)
    return seen


def report_outage_class_failure(agent: str, source: str, evidence: str) -> dict[str, Any]:
    """Entry the failure paths call when a turn fails OUTAGE-class.

    Records the report, then (if currently UP) runs the FIRST-failure confirm:
    ONE synthetic Anthropic probe + ONE DNS sanity → set DOWN-scoped for this
    agent, OR (DNS fail / probe-ok / probe-inconclusive) stay UP + audit. If a
    quorum of DISTINCT static agents is already in-window, promote straight to
    DOWN-fleet.

    Codex r4 (BLOCKING): the lock is held ONLY for the fast state-file
    read-modify-write, NEVER across the slow probe/DNS/static-check subprocesses.
    Holding the lock across env-tunable subprocess timeouts could make the
    critical section exceed LOCK_STALE_SECONDS, letting a second process evict a
    LIVE holder and enter the RMW concurrently. The three subprocesses run
    UNLOCKED; the lock wraps only the two short state mutations. Each subprocess
    is a pure function of its inputs (probe/DNS observe Anthropic; static-check
    observes the roster), so running them outside the lock is safe — the locked
    re-read reconciles against any concurrent state change.

    The raw evidence is digested, never persisted verbatim into the 0644 state
    file (codex MEDIUM). P1a wires this entry + the detect loop; it does NOT
    change cron/live behavior on the DOWN result (that is P1b/P3).
    """
    # Bound caller strings (codex r2 non-blocking).
    agent = ((agent or "unknown").strip() or "unknown")[:AGENT_FIELD_MAX_CHARS]
    source = ((source or "unknown").strip() or "unknown")[:SOURCE_FIELD_MAX_CHARS]

    # --- Phase 0 (UNLOCKED): static validation subprocess for THIS agent. ---
    static_validated = _agent_is_static(agent)

    # --- Phase 1 (LOCKED, fast): append the report; short-circuit if DOWN. ---
    with _state_lock():
        state = read_state()
        now = _now()
        reports = _prune_reports(list(state.get("reports", [])), now)
        reports.append({
            "agent": agent,
            "source": source,
            "ts": now,
            "evidence_digest": _evidence_digest(evidence or ""),
            "static_validated": static_validated,
        })
        state["reports"] = reports
        if is_down(state):
            # Already DOWN — record + maybe promote scoped→fleet; no probe (the
            # backoff prober owns re-probing while down).
            state = _maybe_promote_fleet(state, now)
            state["last_confirm_ts"] = now
            _save_state(state)
            return {"action": "recorded-while-down", "state": _state_label(state)}
        # UP — PERSIST the appended report before releasing, so a concurrent
        # reporter (and our own phase 3 re-read) sees it. Then probe unlocked.
        _save_state(state)

    # --- Phase 2 (UNLOCKED): the slow probe + DNS subprocesses. ---
    outcome, probe_detail = synthetic_anthropic_probe()
    dns_ok, dns_detail = internet_dns_ok()

    # --- Phase 3 (LOCKED, fast): re-read + apply the probe result. ---
    with _state_lock():
        state = read_state()
        now = _now()
        state["last_probe_ts"] = now
        state["last_probe_result"] = f"{probe_detail} | {dns_detail}"
        # Mark the current reports confirmed (steady-state gate goes quiet).
        state["last_confirm_ts"] = now

        # State may have changed to DOWN while we probed (another reporter). If
        # so, just record our confirm and maybe promote — never downgrade a DOWN.
        if is_down(state):
            state = _maybe_promote_fleet(state, now)
            _save_state(state)
            return {"action": "recorded-while-down", "state": _state_label(state)}

        if not dns_ok:
            # OUR network is down — never blame Anthropic. Stay UP, audit.
            state["evidence"] = f"dns-fail:do-not-blame-anthropic | {dns_detail}"
            _save_state(state)
            return {"action": "dns-fail-stay-up", "state": STATE_UP, "detail": dns_detail}

        if outcome != PROBE_OUTAGE:
            # Probe reached Anthropic and it answered OK, or was INCONCLUSIVE.
            # A single agent's transient failure is not corroborated → stay UP.
            state["evidence"] = f"probe-{outcome}:stay-up | {probe_detail}"
            _save_state(state)
            action = "probe-ok-stay-up" if outcome == PROBE_OK else "probe-inconclusive-stay-up"
            return {"action": action, "state": STATE_UP, "outcome": outcome, "detail": probe_detail}

        # Probe = outage-class AND DNS ok → Anthropic really looks down. Re-derive
        # quorum from the CURRENT reports (fresh read — reflects any reports that
        # landed while we probed).
        distinct = _distinct_agents_in_window(list(state.get("reports", [])), now)
        if len(distinct) >= _quorum():
            state = _enter_down_fleet(state, now, distinct, probe_detail, dns_detail)
            _save_state(state)
            return {"action": "enter-down-fleet", "state": STATE_DOWN_FLEET, "agents": distinct}

        # First failure → scoped for this triggering agent (v3.1 #1).
        state = _enter_down_scoped(state, now, agent, probe_detail, dns_detail)
        _save_state(state)
        return {"action": "enter-down-scoped", "state": _state_label(state), "agent": agent}


def _enter_down_scoped(state, now, agent, probe_detail, dns_detail):
    state["state"] = STATE_DOWN_SCOPED
    state["scoped_agent"] = agent
    state["since_ts"] = now
    state["triggering_agents"] = [agent]
    state["recovery_confirms"] = 0
    state["backoff_index"] = 0
    state["next_probe_ts"] = now + BACKOFF_SCHEDULE_SECONDS[0]
    state["evidence"] = f"scoped:{agent} | {probe_detail} | {dns_detail}"
    return state


def _enter_down_fleet(state, now, distinct, probe_detail, dns_detail):
    state["state"] = STATE_DOWN_FLEET
    state["scoped_agent"] = ""
    state["since_ts"] = now
    state["triggering_agents"] = list(distinct)
    state["recovery_confirms"] = 0
    state["backoff_index"] = 0
    state["next_probe_ts"] = now + BACKOFF_SCHEDULE_SECONDS[0]
    state["evidence"] = f"fleet:{','.join(distinct)} | {probe_detail} | {dns_detail}"
    return state


def _maybe_promote_fleet(state, now):
    """A scoped DOWN promotes to fleet once a quorum of distinct agents reports."""
    if str(state.get("state")) != STATE_DOWN_SCOPED:
        return state
    distinct = _distinct_agents_in_window(list(state.get("reports", [])), now)
    if len(distinct) >= _quorum():
        state["state"] = STATE_DOWN_FLEET
        state["scoped_agent"] = ""
        state["triggering_agents"] = list(distinct)
        state["evidence"] = f"promoted-fleet:{','.join(distinct)}"
    return state


def _state_label(state) -> str:
    base = str(state.get("state", STATE_UP))
    if base == STATE_DOWN_SCOPED:
        return f"{STATE_DOWN_SCOPED}:{state.get('scoped_agent','')}"
    return base


# --------------------------------------------------------------------------- #
# Still-down backoff re-probe + recovery hysteresis (one prober — daemon tick)
# --------------------------------------------------------------------------- #
def probe_tick() -> dict[str, Any]:
    """The daemon's gated re-probe pass. NO-OP unless DOWN or a report pends.

    While DOWN: re-probe on the exponential-backoff schedule. A probe that is
    PROBE_OK (Anthropic answered fine) increments the recovery-confirm counter;
    once it reaches BRIDGE_FALLBACK_RECOVERY_CONFIRMS → recover to UP. A probe
    that is still PROBE_OUTAGE resets the confirm counter and advances the
    backoff. A PROBE_INCONCLUSIVE result (ambiguous / unconfigured) does NOT
    count toward recovery — we never declare recovery on no evidence; it just
    re-arms a short backoff.

    Codex r4 (BLOCKING): the probe subprocess runs UNLOCKED — the lock wraps
    only the fast gate-read (phase 1) and the fast apply (phase 3), so the
    critical section never spans the env-tunable probe timeout.
    """
    # --- Phase 1 (LOCKED, fast): gate on DOWN + backoff-due. ---
    with _state_lock():
        state = read_state()
        now = _now()
        if not is_down(state):
            return {"action": "noop-up", "state": STATE_UP}
        next_probe = float(state.get("next_probe_ts", 0))
        if now < next_probe:
            return {"action": "noop-backoff-wait", "state": _state_label(state),
                    "next_probe_in_s": round(next_probe - now, 1)}

    # --- Phase 2 (UNLOCKED): the slow probe subprocess. ---
    outcome, probe_detail = synthetic_anthropic_probe()

    # --- Phase 3 (LOCKED, fast): re-read + apply. ---
    with _state_lock():
        state = read_state()
        now = _now()
        # Recovered to UP while we probed (a concurrent recovery)? Nothing to do.
        if not is_down(state):
            return {"action": "noop-up", "state": STATE_UP}
        state["last_probe_ts"] = now
        state["last_probe_result"] = probe_detail

        if outcome == PROBE_OUTAGE:
            # Still down — reset confirms, advance backoff.
            state["recovery_confirms"] = 0
            idx = min(int(state.get("backoff_index", 0)) + 1, len(BACKOFF_SCHEDULE_SECONDS) - 1)
            state["backoff_index"] = idx
            state["next_probe_ts"] = now + BACKOFF_SCHEDULE_SECONDS[idx]
            _save_state(state)
            return {"action": "still-down", "state": _state_label(state),
                    "backoff_s": BACKOFF_SCHEDULE_SECONDS[idx]}

        if outcome != PROBE_OK:
            # INCONCLUSIVE — do NOT count toward recovery (no evidence Anthropic
            # is back). Reset the confirm streak and re-probe on a short backoff.
            state["recovery_confirms"] = 0
            state["next_probe_ts"] = now + BACKOFF_SCHEDULE_SECONDS[0]
            _save_state(state)
            return {"action": "probe-inconclusive-hold", "state": _state_label(state),
                    "outcome": outcome}

        # Probe = PROBE_OK → count toward recovery (hysteresis).
        confirms = int(state.get("recovery_confirms", 0)) + 1
        state["recovery_confirms"] = confirms
        needed = _recovery_confirms()
        if confirms >= needed:
            _recover_up(state, now, probe_detail)
            _save_state(state)
            return {"action": "recovered", "state": STATE_UP, "confirms": confirms}

        # One success, need a 2nd confirm — short re-probe.
        state["next_probe_ts"] = now + BACKOFF_SCHEDULE_SECONDS[0]
        _save_state(state)
        return {"action": "recovery-pending", "state": _state_label(state),
                "confirms": confirms, "needed": needed}


def _recover_up(state, now, probe_detail):
    state["state"] = STATE_UP
    state["scoped_agent"] = ""
    state["since_ts"] = now
    state["recovery_confirms"] = 0
    state["backoff_index"] = 0
    state["next_probe_ts"] = 0
    state["triggering_agents"] = []
    state["reports"] = []
    state["last_confirm_ts"] = now  # cleared ledger; gate is quiet
    state["evidence"] = f"recovered | {probe_detail}"
    return state


# --------------------------------------------------------------------------- #
# CLI (argv-only; the daemon calls these positionally — file-as-argv)
# --------------------------------------------------------------------------- #
def _emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, sort_keys=True) + "\n")


def cmd_read(args) -> int:
    enabled = _enabled()
    state = read_state()
    # Feature-gate (codex P1a): a disabled install reports UP regardless of any
    # stale state file — a leftover DOWN must never drive a fallback decision.
    label = _state_label(state) if enabled else STATE_UP
    raw = state.get("state") if enabled else STATE_UP
    out = {"state": label,
           "raw_state": raw,
           "scoped_agent": state.get("scoped_agent", "") if enabled else "",
           "since_ts": state.get("since_ts", 0),
           "last_probe_ts": state.get("last_probe_ts", 0),
           "last_probe_result": state.get("last_probe_result", ""),
           "enabled": enabled}
    if getattr(args, "execution_knobs", False):
        # The fallback EXECUTION knobs (model/effort/probe_model) — P1b/P3
        # consume these; surfaced here so the env surface is discoverable.
        out["execution_knobs"] = _fallback_execution_knobs()
    _emit(out)
    return 0


def cmd_report_outage(args) -> int:
    # Feature-gate (codex P1a): when the master gate is OFF, the report path is a
    # no-op — it does NOT record or detect, so a disabled production install
    # never writes provider-health state. The smoke sets BRIDGE_FALLBACK_ENABLED=1
    # to exercise the detector.
    if not _enabled():
        _emit({"action": "disabled-noop", "state": STATE_UP, "enabled": False})
        return 0
    try:
        result = report_outage_class_failure(args.agent, args.source, args.evidence or "")
    except RuntimeError as exc:
        # Codex r2: a lock acquire timeout / tampered lock leaf FAILS CLOSED —
        # we emit a clean audited error and never write unserialized state.
        _emit({"action": "lock-unavailable", "error": str(exc)})
        return 0
    _emit(result)
    return 0


def cmd_probe_tick(_args) -> int:
    try:
        _emit(probe_tick())
    except RuntimeError as exc:
        _emit({"action": "lock-unavailable", "error": str(exc)})
        return 0
    return 0


def cmd_should_tick(_args) -> int:
    """Cheap predicate the daemon checks BEFORE doing any oracle work.

    Prints ``tick`` (exit 0) when the oracle has work — state != UP OR a pending
    unconfirmed report — else ``skip`` (exit 0 with skip). The daemon only spends
    cycles on the probe path when this says tick. This is the zero-steady-state
    gate: with the feature off, or UP with no reports, it always says skip.
    """
    if not _enabled():
        _emit({"decision": "skip", "reason": "disabled"})
        return 0
    state = read_state()
    if is_down(state) or _has_pending_unconfirmed_report(state):
        _emit({"decision": "tick", "reason": "down" if is_down(state) else "pending-report",
               "state": _state_label(state)})
        return 0
    _emit({"decision": "skip", "reason": "up-no-reports"})
    return 0


def cmd_classify_text(args) -> int:
    """Thin CLI over the shared text classifier (delegates to bridge-usage-probe).

    Used by failure paths / the smoke to decide whether a cron stderr or pane
    text is outage-class before calling report-outage.
    """
    outage = _classify_outage_text(args.text or "")
    _emit({"outage_class": outage})
    return 0 if outage else 1


def _classify_outage_text(text: str) -> bool:
    """Import the canonical classifier from bridge-usage-probe (single source)."""
    here = Path(__file__).resolve().parent
    probe_path = here / "bridge-usage-probe.py"
    import importlib.util

    spec = importlib.util.spec_from_file_location("_bridge_usage_probe", probe_path)
    if spec is None or spec.loader is None:
        return False
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return bool(mod.classify_outage_class_text(text))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="provider-health outage oracle (#2066 P1a)")
    sub = p.add_subparsers(dest="cmd", required=True)

    rd = sub.add_parser("read", help="print the current provider-health state")
    rd.add_argument("--execution-knobs", action="store_true",
                    help="also print the fallback execution knobs (model/effort/probe_model)")
    rd.set_defaults(func=cmd_read)

    rp = sub.add_parser("report-outage", help="record an outage-class failure report")
    rp.add_argument("--agent", required=True)
    rp.add_argument("--source", required=True)
    rp.add_argument("--evidence", default="")
    rp.set_defaults(func=cmd_report_outage)

    sub.add_parser("probe-tick", help="run the still-down backoff re-probe / recovery").set_defaults(func=cmd_probe_tick)
    sub.add_parser("should-tick", help="cheap gate: does the oracle have work?").set_defaults(func=cmd_should_tick)

    ct = sub.add_parser("classify-text", help="is text outage-class?")
    ct.add_argument("--text", required=True)
    ct.set_defaults(func=cmd_classify_text)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
