#!/usr/bin/env python3
"""a2a-receiver-staleness.py — destination-side A2A receiver staleness decider.

Issue #1685 (bootstrap gap, #1612 follow-up): #1612 made the upgrader restart
the A2A receiver (``bridge-handoffd.py``) so receiver-side code is reloaded on
upgrade — but that restart block lives in the v0.16.1+ (DESTINATION) upgrader,
while an upgrade is RUN BY the source (old-version) upgrader. So the FIRST
upgrade from a pre-v0.16.1 source runs an old ``bridge-upgrade.sh`` with no
receiver-restart block → the receiver keeps running STALE code (pre-#1623
backpressure) → cross-bridge A2A silently 429s (choi-mac repro). The only
source-version-independent place to catch this is the DESTINATION daemon tick,
because the daemon runs the installed target code.

This helper is the JSON/ISO-date brain for that detector. The daemon supervise
tick (``process_a2a_receiver_supervise_tick`` in bridge-daemon.sh) cannot parse
JSON or ISO-8601 dates in pure Bash, so it hands the relevant file paths to this
helper as argv (footgun #11: NO heredoc-stdin / here-string to a captured
subprocess — file-as-argv only) and reads back a single one-line TSV decision.

The helper is a PURE DECIDER plus an optional one-shot attempt-state record.
It NEVER touches the live receiver, its socket, its config, or its pidfile.
The only file it ever WRITES is the staleness attempt-state file, and ONLY when
invoked with the ``record`` subcommand after the daemon decided to act. It is
fully FAIL-SAFE: any malformed/unreadable/unparseable/unsafe input yields a
``noop`` decision (never a spurious restart, never a crash) so a bad marker can
never break the daemon tick.

Subcommands (argv[1]):

  decide  <last_upgrade_json> <boot_marker_json> <attempt_state_json> \
          <receiver_running> <verified_pid>
      Emit ONE TSV line on stdout:
          <decision>\t<upgrade_key>\t<reason>\t<marker_source_head>\t<marker_version>
      decision ∈ {noop, stale} — `stale` means: the running receiver is on
      pre-upgrade code (or lacks the new boot marker for this upgrade identity)
      AND this upgrade key has NOT been attempted yet → the daemon may perform
      exactly ONE guarded restart for this upgrade key.
      upgrade_key is the stable identity (source_head|updated_at|version) the
      daemon persists via `record` so it never re-attempts the same upgrade.
      Always exits 0 (a non-zero exit would be read by the tick as a hard error;
      the contract is a clean `noop` line on every failure mode).

  record  <attempt_state_json> <upgrade_key> <result> [detail]
      Persist a one-shot attempt record (atomic, mode 0600) so the SAME upgrade
      key is never restarted twice. result ∈ {restarted, restart_failed,
      preflight_failed, systemd_warn_only}. Always exits 0; a write failure is
      swallowed (worst case the next tick re-decides `stale` and the
      preflight-before-stop guard still protects a working receiver — but the
      record write is best-effort durable).
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


def _eprint(msg: str) -> None:
    sys.stderr.write(f"[a2a-receiver-staleness] {msg}\n")


# _load_json status sentinels. The caller MUST distinguish a genuinely ABSENT
# file (a valid signal — e.g. a receiver started by an old build that predates
# the boot marker, which is the bootstrap-stale case we want to catch) from a
# file that EXISTS but is malformed/unreadable/empty (an AMBIGUOUS state that
# must FAIL SAFE — never drive a restart of a possibly-working receiver, and
# never re-arm an already-claimed one-shot). Collapsing the two (codex r1
# finding) let a corrupt receiver-boot.json trigger a restart and let a corrupt
# attempt-state re-attempt the same upgrade key.
_LJ_ABSENT = "absent"        # path empty/missing — file does not exist
_LJ_MALFORMED = "malformed"  # exists but unreadable / empty / bad-JSON / non-object
_LJ_OK = "ok"                # parsed to a dict

# Terminal one-shot results — only these mean "this upgrade identity was fully
# attempted; never re-arm". A bare `claimed` (the in-progress marker) is NOT
# terminal: if the daemon died mid-action, a later tick must re-attempt.
_TERMINAL_RESULTS = frozenset({
    "restarted", "restart_failed", "preflight_failed", "systemd_warn_only",
})


def _load_json(path_str: str) -> tuple[str, Optional[dict]]:
    """Three-state JSON object load.

    Returns one of:
      (_LJ_ABSENT, None)    — no path given, or the file does not exist.
      (_LJ_MALFORMED, None) — the file EXISTS but is unreadable, empty,
                              not valid JSON, or not a JSON object.
      (_LJ_OK, dict)        — parsed successfully to a dict.

    Never raises.
    """
    if not path_str:
        return (_LJ_ABSENT, None)
    p = Path(path_str)
    try:
        # noqa: raw-pathlib-controller-only — controller-owned $BRIDGE_STATE_DIR
        # state (last-upgrade / handoff markers); never an isolated-agent tree.
        text = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return (_LJ_ABSENT, None)
    except OSError:
        # Exists but unreadable (perms / IO) — ambiguous, fail safe.
        return (_LJ_MALFORMED, None)
    text = text.strip()
    if not text:
        return (_LJ_MALFORMED, None)
    try:
        obj = json.loads(text)
    except (ValueError, TypeError):
        return (_LJ_MALFORMED, None)
    if not isinstance(obj, dict):
        return (_LJ_MALFORMED, None)
    return (_LJ_OK, obj)


def _iso_to_epoch(value: Any) -> Optional[int]:
    """Parse an ISO-8601 timestamp (last-upgrade.json `updated_at`) to epoch.

    bridge-upgrade.py writes local-time-with-offset, e.g.
    ``2026-06-08T12:34:56+09:00``. We also tolerate a trailing ``Z`` (UTC) and a
    naive timestamp (assumed UTC). Returns None on any parse failure (fail-safe).
    """
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    # Python's fromisoformat does not accept a trailing 'Z' before 3.11.
    if raw.endswith("Z") or raw.endswith("z"):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        # Naive — assume UTC rather than local so the cutoff is reproducible.
        dt = dt.replace(tzinfo=timezone.utc)
    try:
        return int(dt.timestamp())
    except (OverflowError, OSError, ValueError):
        return None


def _as_int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _str(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def _upgrade_key(last_upgrade: dict) -> str:
    """Stable upgrade identity used to gate the one-shot restart.

    Keyed on source_head + updated_at + version — all written by
    cmd_write_state BEFORE the receiver could be restarted. Pipe-joined; a
    missing field degrades to its empty string so two upgrades can never share
    a key unless they are genuinely the same upgrade.
    """
    return "|".join(
        (
            _str(last_upgrade.get("source_head")),
            _str(last_upgrade.get("updated_at")),
            _str(last_upgrade.get("version")),
        )
    )


def _emit(decision: str, upgrade_key: str, reason: str,
          marker_source_head: str = "", marker_version: str = "") -> int:
    """Emit the single TSV decision line and ALWAYS exit 0.

    A bad field is scrubbed of tabs/newlines so the daemon's `IFS=$'\\t' read`
    can never be desynced by a control char that slipped through.
    """
    def clean(s: str) -> str:
        return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")

    sys.stdout.write(
        "\t".join(
            (
                clean(decision),
                clean(upgrade_key),
                clean(reason),
                clean(marker_source_head),
                clean(marker_version),
            )
        )
        + "\n"
    )
    return 0


def cmd_decide(argv: list[str]) -> int:
    # decide <last_upgrade_json> <boot_marker_json> <attempt_state_json>
    #        <receiver_running> <verified_pid>
    if len(argv) < 5:
        return _emit("noop", "", "bad_args")
    last_upgrade_path, boot_marker_path, attempt_state_path, \
        receiver_running_raw, verified_pid_raw = argv[:5]

    receiver_running = receiver_running_raw.strip() in ("1", "true", "yes")
    verified_pid = _as_int(verified_pid_raw)

    # No-op #1: receiver not running. Normal supervision (dead/crash-loop)
    # owns a down receiver — we ONLY catch a RUNNING-but-stale one.
    if not receiver_running or verified_pid is None or verified_pid <= 0:
        return _emit("noop", "", "receiver_not_running")

    # No-op #2: no last-upgrade.json (never upgraded on this install) → no
    # cutoff boundary, nothing to compare against. A MALFORMED last-upgrade is
    # also a no-op (we cannot prove staleness without a trustworthy cutoff).
    lu_status, last_upgrade = _load_json(last_upgrade_path)
    if lu_status == _LJ_ABSENT:
        return _emit("noop", "", "no_last_upgrade")
    if lu_status != _LJ_OK or last_upgrade is None:
        return _emit("noop", "", "last_upgrade_malformed")

    cutoff_epoch = _iso_to_epoch(last_upgrade.get("updated_at"))
    if cutoff_epoch is None:
        # Malformed/absent cutoff timestamp → cannot prove staleness → FAIL SAFE.
        return _emit("noop", "", "no_upgrade_cutoff")

    upgrade_key = _upgrade_key(last_upgrade)

    # No-op #3: this exact upgrade key was already attempted. NEVER loop — once
    # we have tried for an upgrade identity, normal supervision handles any
    # subsequent death/crash-loop. (Also keeps us from fighting #1612: a
    # v0.16.1+ source already restarted the receiver post-write-state.)
    # codex r1 finding: a MALFORMED/unreadable attempt-state must NOT be read as
    # "never attempted" (that would re-arm the one-shot and could re-restart the
    # same upgrade). Treat a present-but-unparseable attempt file as "claimed" →
    # FAIL SAFE no-op. Only a genuinely ABSENT attempt file means "not yet
    # attempted".
    #
    # NOTE: `decide` is ADVISORY — the authoritative one-shot guard is the
    # PER-UPGRADE-KEY O_EXCL lock taken by `claim` (cmd_claim) before any
    # restart. So this same-key `already_attempted` short-circuit is only a
    # log-noise optimization; the lock still prevents a double restart even if
    # this check is skipped. That is why a MALFORMED status file does NOT noop
    # here: noop-ing would permanently block a LATER upgrade identity's
    # self-heal on a corrupt status file (the same class of permanent-block bug
    # codex r2 flagged for a shared lock). On malformed status we fall through to
    # the boot-marker check and let the per-key claim lock be the real guard.
    as_status, attempt_state = _load_json(attempt_state_path)
    if as_status == _LJ_OK and attempt_state is not None:
        same_key = (_str(attempt_state.get("upgrade_key")) == upgrade_key
                    and bool(upgrade_key))
        # Only a TERMINAL result is a permanent one-shot. A bare `claimed`
        # status (the in-progress marker written at claim time) must NOT short
        # this out (codex r3): if the daemon died after claiming but before the
        # restart, a later tick must be free to re-attempt — the stale-lock
        # reclaim in `claim` then lets it through.
        if same_key and _str(attempt_state.get("result")) in _TERMINAL_RESULTS:
            return _emit("noop", upgrade_key, "already_attempted")

    # Inspect the receiver-owned boot marker.
    bm_status, boot_marker = _load_json(boot_marker_path)
    marker_source_head = ""
    marker_version = ""
    if bm_status == _LJ_OK and boot_marker is not None:
        marker_source_head = _str(boot_marker.get("source_head"))
        marker_version = _str(boot_marker.get("version"))

    # codex r1 finding: a boot marker that EXISTS but is malformed/unreadable is
    # AMBIGUOUS — it must NOT drive a restart of a possibly-working receiver.
    # Only a genuinely ABSENT marker is the bootstrap-stale signal (an old build
    # that predates the marker). FAIL SAFE on malformed.
    if bm_status == _LJ_MALFORMED:
        return _emit("noop", upgrade_key, "boot_marker_malformed")

    # Bootstrap nuance: the STALE receiver we must catch was started by an OLD
    # build that never wrote this marker. So a running receiver with NO marker
    # (or a marker whose pid != the current verified pid) is `stale_unknown_
    # boot_marker` → eligible for ONE guarded restart for this upgrade key.
    if bm_status == _LJ_ABSENT or boot_marker is None:
        return _emit("stale", upgrade_key, "stale_unknown_boot_marker",
                     marker_source_head, marker_version)

    marker_pid = _as_int(boot_marker.get("pid"))
    if marker_pid is None or marker_pid != verified_pid:
        # The marker does not describe the CURRENT running receiver (left over
        # from a prior process / pid reuse) → treat as unknown boot marker.
        return _emit("stale", upgrade_key, "stale_unknown_boot_marker",
                     marker_source_head, marker_version)

    marker_started_epoch = _as_int(boot_marker.get("started_at_epoch"))
    if marker_started_epoch is None:
        # Marker matches the pid but carries no usable start time → we cannot
        # prove it is fresh, but it DOES match the live pid. Be conservative:
        # the cutoff comparison is the discriminator, and without a start time
        # we cannot place it before/after the cutoff → FAIL SAFE (no-op). A
        # working receiver must not be recycled on an ambiguous marker.
        return _emit("noop", upgrade_key, "marker_no_started_at",
                     marker_source_head, marker_version)

    # The crux: a receiver whose boot PRECEDES the "new code installed" cutoff
    # (last-upgrade updated_at) is running pre-upgrade code → stale. A receiver
    # that booted AT/AFTER the cutoff already runs the new code (this is the
    # #1612 fresh-post-upgrade receiver) → no-op, no double restart.
    if marker_started_epoch < cutoff_epoch:
        return _emit("stale", upgrade_key, "boot_before_upgrade_cutoff",
                     marker_source_head, marker_version)

    return _emit("noop", upgrade_key, "marker_fresh",
                 marker_source_head, marker_version)


def cmd_record(argv: list[str]) -> int:
    # record <attempt_state_json> <upgrade_key> <result> [detail]
    if len(argv) < 3:
        _eprint("record: bad args")
        return 0
    attempt_state_path = argv[0]
    upgrade_key = argv[1]
    result = argv[2]
    detail = argv[3] if len(argv) > 3 else ""
    if not attempt_state_path:
        return 0
    record = {
        "upgrade_key": upgrade_key,
        "result": result,
        "detail": detail[:300],
        "attempted_at_epoch": int(datetime.now(timezone.utc).timestamp()),
    }
    try:
        p = Path(attempt_state_path)
        # noqa: raw-pathlib-controller-only — controller-owned $BRIDGE_STATE_DIR
        # handoff state; never an isolated-agent tree.
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False) + "\n",
                       encoding="utf-8")
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        os.replace(tmp, p)
    except OSError as exc:
        # Best-effort: a write failure must NOT break the tick. Next tick may
        # re-decide stale, but the preflight-before-stop guard still protects a
        # working receiver, and the boot marker the restart wrote will then read
        # fresh (> cutoff) so the loop self-terminates.
        _eprint(f"record: write failed: {exc}")
    return 0


def _claim_lock_path(attempt_state_path: str, upgrade_key: str) -> Path:
    """PER-UPGRADE-KEY claim lock path beside the attempt-state file.

    A single shared lock file would let the FIRST upgrade's claim permanently
    block every LATER upgrade identity's self-heal (codex r2 finding). Keying
    the O_EXCL lock to a hash of the upgrade identity makes each distinct
    upgrade independent: concurrent ticks for the SAME key serialize on the same
    lock, while a NEW key (a later upgrade) gets its own lock and is never
    blocked by a stale one.
    """
    p = Path(attempt_state_path)
    digest = hashlib.sha256((upgrade_key or "").encode("utf-8")).hexdigest()[:16]
    # `<attempt-state-stem>.<keyhash>.lock` — e.g.
    # receiver-staleness.<hash>.lock, beside receiver-staleness.json.
    return p.with_name(f"{p.stem}.{digest}.lock")


# A claim lock older than this (seconds) is treated as ABANDONED — the daemon
# that took it died after `claim` but before writing a terminal `record` (codex
# r3 finding: claim-before-action could otherwise permanently consume the
# one-shot while leaving a stale receiver running). The window is far longer than
# any plausible preflight+restart, so it never reclaims a lock a live tick still
# holds. Tunable for the smoke.
_CLAIM_LOCK_STALE_SECONDS = int(
    os.environ.get("BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS", "600") or "600"  # noqa: iso-helper-boundary — process-local env read (os.environ), never a controller->iso boundary RW
)


def _lock_is_stale(lock_path: Path) -> bool:
    """True iff the lock exists and its mtime is older than the stale window.

    A missing lock is NOT stale (caller should try a fresh create instead). Any
    stat error is treated as not-stale (fail safe: do not reclaim what we cannot
    measure).
    """
    try:
        age = (int(datetime.now(timezone.utc).timestamp())
               - int(lock_path.stat().st_mtime))
    except OSError:
        return False
    return age >= _CLAIM_LOCK_STALE_SECONDS


def _try_create_lock(lock_path: Path, upgrade_key: str) -> bool:
    """O_CREAT|O_EXCL the per-key lock; write key+epoch. True iff we created it."""
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    except OSError as exc:
        _eprint(f"claim: lock open failed: {exc}")
        return False
    try:
        os.write(fd, (upgrade_key + "\n"
                      + str(int(datetime.now(timezone.utc).timestamp()))
                      + "\n").encode("utf-8"))
    except OSError:
        pass
    finally:
        os.close(fd)
    return True


def cmd_claim(argv: list[str]) -> int:
    # claim <attempt_state_json> <upgrade_key>
    # ATOMICALLY claim the one-shot for THIS upgrade identity BEFORE the daemon
    # performs any restart. This closes the concurrent-tick double-restart race
    # (codex r1 finding): `bridge-daemon.sh sync` (manual) and the background
    # daemon tick can both pass `decide` before either records an attempt.
    #
    # The lock is PER UPGRADE KEY (codex r2 finding): a single shared lock would
    # let the first-ever upgrade's claim permanently block every later upgrade
    # identity. We O_CREAT|O_EXCL a `<stem>.<keyhash>.lock` derived from the
    # upgrade identity — EXACTLY ONE caller wins the create FOR THAT KEY; a
    # different (later) upgrade key uses a different lock and is never blocked.
    #
    # The lock is a SHORT-LIVED serializer, NOT the permanent one-shot (codex r3
    # finding): the daemon tick `release`s it after a terminal record, and the
    # PERMANENT one-shot is the terminal status file keyed by upgrade_key (which
    # `decide` reads as `already_attempted`). If the daemon DIES after claiming
    # but before recording a terminal result, the lock is left behind WITHOUT a
    # terminal status — so a later tick reclaims it once it is older than
    # `_CLAIM_LOCK_STALE_SECONDS` (the prior holder is provably gone), and the
    # self-heal is retried instead of being permanently skipped.
    #
    # Prints `claimed` (this caller may proceed to restart) or `not_claimed`
    # (another LIVE caller holds THIS key's lock, or it could not be taken
    # safely). Always exits 0.
    if len(argv) < 2:
        sys.stdout.write("not_claimed\n")
        return 0
    attempt_state_path, upgrade_key = argv[0], argv[1]
    if not attempt_state_path:
        sys.stdout.write("not_claimed\n")
        return 0
    p = Path(attempt_state_path)
    try:
        # noqa: raw-pathlib-controller-only — controller-owned $BRIDGE_STATE_DIR
        # handoff state; never an isolated-agent tree.
        p.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        # Cannot even create the parent — fail safe: do NOT proceed to a restart
        # we cannot guard.
        _eprint(f"claim: parent mkdir failed: {exc}")
        sys.stdout.write("not_claimed\n")
        return 0
    lock_path = _claim_lock_path(attempt_state_path, upgrade_key)
    if not _try_create_lock(lock_path, upgrade_key):
        # The lock exists. Reclaim it ONLY if it is provably abandoned (older
        # than the stale window — the holder died before recording a terminal
        # result). A fresh lock means a live tick still holds it → back off.
        #
        # codex r4 finding: a naive unlink()+create reclaim is RACEABLE — two
        # reclaimers could both observe the stale lock, and the second could
        # unlink the FIRST reclaimer's freshly-created lock and recreate it, so
        # both return `claimed`. O_EXCL on the final create does not help because
        # the loser's unlink targets the SAME pathname the winner just created.
        #
        # Serialize the reclaim itself behind a SEPARATE O_EXCL reclaim-lock:
        # exactly one caller wins the right to perform the unlink+recreate; the
        # others back off. The reclaim-lock is held only for the microscopic
        # unlink+recreate window and removed in `finally`, so it cannot itself
        # become a durable block.
        if not _lock_is_stale(lock_path):
            sys.stdout.write("not_claimed\n")
            return 0
        reclaim_lock = lock_path.with_name(lock_path.name + ".reclaiming")
        try:
            rfd = os.open(str(reclaim_lock),
                          os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except (FileExistsError, OSError):
            # Another caller is already reclaiming (or we cannot serialize) →
            # back off; never two concurrent reclaimers.
            sys.stdout.write("not_claimed\n")
            return 0
        try:
            # Re-check staleness UNDER the reclaim-lock: the winning reclaimer
            # may have already replaced the lock with a fresh one since our first
            # observation, in which case it is no longer stale and we back off.
            if not _lock_is_stale(lock_path):
                sys.stdout.write("not_claimed\n")
                return 0
            try:
                lock_path.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                sys.stdout.write("not_claimed\n")
                return 0
            if not _try_create_lock(lock_path, upgrade_key):
                sys.stdout.write("not_claimed\n")
                return 0
        finally:
            try:
                os.close(rfd)
            except OSError:
                pass
            try:
                reclaim_lock.unlink()
            except OSError:
                pass
    # Won the claim for this key. Write the human-readable attempt-state status
    # (overwrites any prior key's status — keyed in-content by upgrade_key).
    record = {
        "upgrade_key": upgrade_key,
        "result": "claimed",
        "detail": "",
        "attempted_at_epoch": int(datetime.now(timezone.utc).timestamp()),
    }
    try:
        tmp = p.with_name(p.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False) + "\n",
                       encoding="utf-8")
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        os.replace(tmp, p)
    except OSError as exc:
        # Status-write failure is non-fatal: the per-key LOCK already serializes
        # the one-shot; the status file is observability only.
        _eprint(f"claim: status write failed: {exc}")
    sys.stdout.write("claimed\n")
    return 0


def cmd_release(argv: list[str]) -> int:
    # release <attempt_state_json> <upgrade_key>
    # Remove the per-key claim lock after the daemon tick has written a TERMINAL
    # `record` for this upgrade identity. The permanent one-shot is then held by
    # the terminal status file (read by `decide` as `already_attempted`); the
    # lock was only the short-lived concurrency serializer. Releasing it keeps
    # the handoff dir tidy and means the stale-lock reclaim path is only ever
    # needed for a genuinely-dead-mid-action daemon. Best-effort; always 0.
    if len(argv) < 2:
        return 0
    attempt_state_path, upgrade_key = argv[0], argv[1]
    if not attempt_state_path:
        return 0
    try:
        _claim_lock_path(attempt_state_path, upgrade_key).unlink()
    except OSError:
        pass
    return 0


def cmd_status(argv: list[str]) -> int:
    # status <attempt_state_json>
    # Print `result<TAB>detail` for the recorded one-shot attempt, or nothing
    # when the file is absent/malformed. Read-only; always exits 0. Used by the
    # `agb a2a daemon status` surface (no heredoc-stdin in the shell caller).
    if not argv:
        return 0
    status, state = _load_json(argv[0])
    if status != _LJ_OK or state is None:
        return 0
    result = _str(state.get("result"))
    detail = _str(state.get("detail"))
    if not result:
        return 0
    sys.stdout.write(
        result.replace("\t", " ").replace("\n", " ")
        + "\t"
        + detail.replace("\t", " ").replace("\n", " ")
        + "\n"
    )
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if not args:
        return _emit("noop", "", "no_subcommand")
    sub = args[0]
    rest = args[1:]
    if sub == "decide":
        return cmd_decide(rest)
    if sub == "claim":
        return cmd_claim(rest)
    if sub == "release":
        return cmd_release(rest)
    if sub == "record":
        return cmd_record(rest)
    if sub == "status":
        return cmd_status(rest)
    # Unknown subcommand → fail safe with a noop decision line so a misinvocation
    # from the tick never becomes a spurious restart.
    return _emit("noop", "", "unknown_subcommand")


if __name__ == "__main__":
    sys.exit(main())
